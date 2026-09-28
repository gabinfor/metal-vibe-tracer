// Graph-driven OpenPBR emission (MaterialX emission_color / emission_luminance and
// UsdPreviewSurface emissiveColor): compiler roots and defaults, textured radiance at
// hits and at light samples, strategy agreement on a graph-emissive quad, and the ASWF
// Standard Shader Ball importing with no material fallbacks.
@MainActor func fixShaderballEmissionChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("shaderball-emission", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  func parse(_ body: String) throws -> MaterialXImport {
    try MaterialXImporter.read(
      Data(("<materialx version=\"1.39\">" + body + "</materialx>").utf8), baseURL: folder, source: "Emission.mtlx")
  }
  // 4 x 2 linear texture: the left half (u < 0.5) and the right half hold one color each.
  let left = SIMD3<Float>(1, 128.0 / 255, 64.0 / 255), right = SIMD3<Float>(51.0 / 255, 102.0 / 255, 1)
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
  for y in 0..<2 { for x in 0..<4 {
    let bytes: [UInt8] = x < 2 ? [255, 128, 64, 255] : [51, 102, 255, 255]
    for c in 0..<4 { bitmap.bitmapData![y * 16 + x * 4 + c] = bytes[c] }
  }}
  try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("glow.png"))

  // Compiler: unauthored emission adds nothing; constant and connected emission become one
  // color x luminance register; a file-less image is its default; clamp addressing is kept.
  let plain = try parse("<open_pbr_surface name=\"Plain\" type=\"surfaceshader\"/>")
  require(plain.materials.count == 1 && plain.materials[0].emission == nil && plain.materials[0].emissionWeight == 0,
    "unauthored OpenPBR emission compiles to no emission register")
  let constant = try parse("""
    <open_pbr_surface name="Lamp" type="surfaceshader">
      <input name="emission_luminance" type="float" value="10"/>
      <input name="emission_color" type="color3" value="1, 0.5, 0.25"/>
    </open_pbr_surface>
    """)
  let lamp = constant.materials.first
  let lampWeight = 10 * (0.2126 + 0.7152 * 0.5 + 0.0722 * 0.25)
  require(lamp?.emission != nil && abs((lamp?.emissionWeight ?? 0) - lampWeight) < 1e-4 * lampWeight
      && lamp?.parameters.contains(where: { $0.name == "Lamp/emission_luminance" && $0.components == 1 }) == true
      && lamp?.parameters.contains(where: { $0.name == "Lamp/emission_color" && $0.components == 3 }) == true,
    "constant emission compiles to an editable color x luminance register (\(constant.report))")
  let onlyLuminance = try parse("<open_pbr_surface name=\"White\" type=\"surfaceshader\"><input name=\"emission_luminance\" type=\"float\" value=\"4\"/></open_pbr_surface>")
  require(abs((onlyLuminance.materials.first?.emissionWeight ?? 0) - 4) < 1e-4,
    "emission_color defaults to white (MaterialX v1.39.5 open_pbr_surface)")
  let textured = try parse("""
    <image name="glow" type="color3"><input name="file" type="filename" value="glow.png"/>
      <input name="uaddressmode" type="string" value="clamp"/></image>
    <open_pbr_surface name="Screen" type="surfaceshader">
      <input name="emission_luminance" type="float" value="3"/>
      <input name="emission_color" type="color3" nodename="glow"/>
    </open_pbr_surface>
    """)
  let screen = textured.materials.first
  let image = screen?.instructions.first(where: { $0.code.x == 2 })
  require(screen?.emission != nil && screen?.images.count == 1 && abs((screen?.emissionWeight ?? 0) - 3) < 1e-4
      && image?.value.z == 1 && image?.value.w == 0,
    "connected emission_color compiles with per-axis clamp addressing (\(textured.report))")
  let blank = try parse("""
    <image name="blank" type="vector3"><input name="uaddressmode" type="string" value="clamp"/>
      <input name="vaddressmode" type="string" value="clamp"/></image>
    <extract name="strength" type="float"><input name="in" type="vector3" nodename="blank"/></extract>
    <convert name="tint" type="color3"><input name="in" type="vector3" nodename="blank"/></convert>
    <open_pbr_surface name="Neutral" type="surfaceshader">
      <input name="emission_luminance" type="float" nodename="strength"/>
      <input name="emission_color" type="color3" nodename="tint"/>
    </open_pbr_surface>
    """)
  require(blank.materials.count == 1 && blank.materials[0].emission != nil && blank.materials[0].emissionWeight == 0
      && blank.materials[0].images.isEmpty && blank.report.contains(where: { $0.contains("evaluates to its default") }),
    "an image without a file evaluates to its default (zero), as in the ASWF neutral material (\(blank.report))")
  let mirrored = try parse("""
    <image name="glow" type="color3"><input name="file" type="filename" value="glow.png"/>
      <input name="uaddressmode" type="string" value="mirror"/></image>
    <open_pbr_surface name="Bad" type="surfaceshader"><input name="emission_color" type="color3" nodename="glow"/></open_pbr_surface>
    """)
  require(mirrored.materials.isEmpty && mirrored.report.joined().contains("periodic or clamp"),
    "unsupported image address modes are still reported")
  var invalid = screen!
  invalid.emission = Int32(invalid.instructions.count)
  do { try invalid.validate(); require(false, "out-of-range emission register rejected") } catch {}
  let decoded = try JSONDecoder().decode(MaterialXProgram.self, from: JSONEncoder().encode(screen!))
  require(decoded.emission == screen!.emission && decoded.sameProgram(as: screen!) && !plain.materials[0].sameProgram(as: screen!),
    "emission registers persist in projects and presets")
  print("PASS: fix-shaderball-emission MaterialX emission roots, defaults, file-less images and clamp addressing")

  // A USD stage: a floor lit only by a 1 x 1 m graph-emissive quad 1 m above it, facing down.
  // Its emission_color is the clamped texture (u = x + 0.5), times 3 nits.
  let stage = folder.appendingPathComponent("glow.usda")
  try """
    #usda 1.0
    (
        defaultPrim = "World"
        metersPerUnit = 1
        upAxis = "Y"
    )
    def Xform "World"
    {
        def Mesh "Floor"
        {
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 3, 2, 1]
            point3f[] points = [(-2, 0, -2), (2, 0, -2), (2, 0, 2), (-2, 0, 2)]
            color3f[] primvars:displayColor = [(0.5, 0.5, 0.5)]
            uniform token subdivisionScheme = "none"
        }
        def Mesh "Emitter" (prepend apiSchemas = ["MaterialBindingAPI"])
        {
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 1, 2, 3]
            point3f[] points = [(-0.5, 1, -0.5), (0.5, 1, -0.5), (0.5, 1, 0.5), (-0.5, 1, 0.5)]
            texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (interpolation = "faceVarying")
            uniform token subdivisionScheme = "none"
            rel material:binding = </World/Glow>
        }
        def Material "Glow"
        {
            token outputs:mtlx:surface.connect = </World/Glow/Surface.outputs:out>
            def Shader "Surface"
            {
                uniform token info:id = "ND_open_pbr_surface_surfaceshader"
                color3f inputs:base_color = (0, 0, 0)
                float inputs:emission_luminance = 3
                color3f inputs:emission_color.connect = </World/Glow/Image.outputs:out>
                token outputs:out
            }
            def Shader "Image"
            {
                uniform token info:id = "ND_image_color3"
                asset inputs:file = @glow.png@
                string inputs:uaddressmode = "clamp"
                color3f outputs:out
            }
        }
    }
    """.write(to: stage, atomically: true, encoding: .utf8)
  let glow = try USDImporter.load(stage, into: ProjectDocument())
  let glowState = glow.document.scenes[6]!
  let glowSlot = glow.document.graph!.materials.first(where: { $0.name == "Glow" })!.slot
  require(glowState.materialX?[glowSlot]?.emission != nil && glowState.emissions?.isEmpty != false
      && !glow.report.contains(where: { $0.contains("fallback") || $0.contains("NOT imported") }),
    "USD MaterialX emission imports as a graph emitter, not a light (\(glow.report))")
  try controller.restore(glow.document)
  let materials = testRenderer.materials
  let ordered = materials.orderedTriangles
  let emitterTriangles = ordered.filter { Int($0.uvc.z) == glowSlot }
  require(emitterTriangles.count == 2 && emitterTriangles.allSatisfy {
      simd_cross(SIMD3($0.b.x - $0.a.x, $0.b.y - $0.a.y, $0.b.z - $0.a.z), SIMD3($0.c.x - $0.a.x, $0.c.y - $0.a.y, $0.c.z - $0.a.z)).y < 0 },
    "the emitter's authored front face points down")
  let listed = Int(materials.emitterBuffer.contents().load(as: UInt32.self))
  let weight = materials.emissionBuffer.contents().load(fromByteOffset: glowSlot * 16, as: SIMD4<Float>.self).w
  require(listed == 2 && abs(weight - 3) < 1e-5, "the graph emitter joins the light list with its host weight (\(listed), \(weight))")

  let kernels = """
  kernel void fix_emission_probe(constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],
      constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(3)]], uint tid [[thread_position_in_grid]]) {
      // Camera-style hits: upward rays see the front face; a downward ray sees the back.
      float3 origins[3] = { float3(-0.3f, 0.5f, 0.1f), float3(0.3f, 0.5f, -0.1f), float3(-0.3f, 1.5f, 0.1f) };
      for (int i = 0; i < 3; ++i) {
          Ray r = { origins[i], float3(0, i < 2 ? 1.0f : -1.0f, 0) };
          HitRecord h; bool hit = trace_scene(r, 6, h, images, u);
          if (hit) resolve_material(h, r, u, settings, images, 0.0f);
          out[i] = float4(hit ? openpbr_emission(h.mat, h.normal, -r.direction) : float3(-1), hit ? float(h.mat.type) : -1);
          if (i == 0 && tid == 0) {
              // MaterialX coat on emission: (1 - F0(1.6)) (1 - (1 - N.V)^5), mixed by coat_weight.
              Material coated = h.mat; coated.coat = 1.0f;
              float3 e = openpbr_emission(h.mat, h.normal, -r.direction);
              float3 grazing = normalize(h.normal + 3.0f * h.tangent);
              float normal = openpbr_emission(coated, h.normal, -r.direction).x / e.x;
              float oblique = openpbr_emission(coated, h.normal, grazing).x / openpbr_emission(h.mat, h.normal, grazing).x;
              coated.coat = 0.5f;
              out[3] = float4(normal, oblique, openpbr_emission(coated, h.normal, -r.direction).x / e.x, dot(h.normal, grazing));
          }
      }
      // Light samples evaluate the graph at the sampled point exactly as a hit there does.
      float3 p = float3(0.2f * float(int(tid % 5u) - 2), 0.0f, 0.2f * float(int(tid / 5u) - 2));
      float3 n = float3(0, 1, 0);
      uint seed = pcg_hash(tid * 977u + 3u);
      float samples = 0, mismatch = 0, pdfError = 0, pure = 0, halves = 0;
      for (uint i = 0; i < 1024; ++i) {
          LightSample ls = sample_direct_light(p, n, u, seed, images);
          if (ls.isDirectional < 2 || !(ls.pdf > 0.0f)) continue;
          samples += 1;
          Ray r = { p, ls.wi };
          HitRecord h;
          if (!trace_scene(r, 6, h, images, u)) { mismatch = 1e9f; continue; }
          resolve_material(h, r, u, settings, images, 0.0f);
          float3 e = openpbr_emission(h.mat, h.normal, -ls.wi);
          mismatch = max(mismatch, length(e - ls.emission) / max(1e-3f, length(e)));
          pdfError = max(pdfError, abs(eval_light_pdf(p, h.position, h.mat, u, images, h.triangle) - ls.pdf) / ls.pdf);
          float3 expected = ls.position.x < -0.2f ? 3.0f * float3(\(left.x), \(left.y), \(left.z))
              : ls.position.x > 0.2f ? 3.0f * float3(\(right.x), \(right.y), \(right.z)) : float3(-1);
          if (expected.x >= 0) { halves += 1; if (all(abs(ls.emission - expected) < 2e-3f)) pure += 1; }
      }
      out[4 + tid] = float4(samples, mismatch, pdfError, halves - pure);
  }
  """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "fix_emission_probe")!)
  var probe = makeUniforms(scene: 6, mode: 1, width: 1, height: 1)
  probe.environment = SIMD4(0, 0, 0, Float(materials.nodeCount))
  probe.sunParams.w = 0
  probe.lens.z = 1
  let threads = 25
  let buffer = gpu.makeBuffer(length: (4 + threads) * 16, options: .storageModeShared)!
  let command = testRenderer.commandQueue.makeCommandBuffer()!
  let encoder = command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(pipeline)
  materials.bind(encoder)
  encoder.setBytes(&probe, length: MemoryLayout<Uniforms>.stride, index: 0)
  encoder.setBuffer(buffer, offset: 0, index: 3)
  encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
  encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
  require(command.status == .completed, "emission probe GPU command: \(String(describing: command.error))")
  let probed = (0..<(4 + threads)).map { buffer.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  print("Graph emission probe: front \(probed[0]) \(probed[1]), back \(probed[2])")
  func close(_ a: SIMD4<Float>, _ b: SIMD3<Float>) -> Bool { simd_length(SIMD3(a.x, a.y, a.z) - b) < 2e-3 * max(1, simd_length(b)) }
  require(close(probed[0], 3 * left) && close(probed[1], 3 * right) && probed[0].w == 4 && probed[1].w == 4,
    "hits see texture x luminance on the front face of an OpenPBR emitter")
  require(close(probed[2], .zero) && probed[2].w == 4, "the back face of a non-thin-walled emitter is dark")
  let f0: Float = 0.36 / 6.76, cosine = probed[3].w
  print("Graph emission coat factors: normal \(probed[3].x), oblique \(probed[3].y), half weight \(probed[3].z)")
  require(abs(probed[3].x - (1 - f0)) < 1e-4 && abs(probed[3].y - (1 - f0) * (1 - pow(1 - cosine, 5))) < 1e-4
      && abs(probed[3].z - (1 + (1 - f0)) / 2) < 1e-4,
    "coated emission follows the MaterialX generalized_schlick_edf coat factor")
  let lightSamples = probed[4...]
  let sampled = lightSamples.reduce(0) { $0 + $1.x }, worstMismatch = lightSamples.map { $0.y }.max() ?? 1
  let worstPDF = lightSamples.map { $0.z }.max() ?? 1, impure = lightSamples.reduce(0) { $0 + $1.w }
  print("Graph emission light samples: \(sampled), radiance mismatch \(worstMismatch), PDF error \(worstPDF), off-texel \(impure)")
  require(sampled == Float(threads * 1024) && worstMismatch < 1e-4 && worstPDF < 1e-3 && impure == 0,
    "light samples evaluate the graph radiance and PDF of the point they land on (clamped texture halves)")

  // MIS, light-only and BSDF-only estimators (and the ReSTIR mode's conventional path)
  // agree on the floor and on the directly visible emitter.
  var view = makeUniforms(scene: 6, mode: 3, width: 64, height: 48)
  let eye = SIMD3<Float>(0, 0.6, -2.2), target = SIMD3<Float>(0, 0.3, 0.3)
  view.cameraPos = SIMD4(eye, 45); view.cameraTarget = SIMD4(target, 16)
  view.currentViewProj = makePerspective(fovyRadians: 45 * .pi / 180, aspect: 64.0 / 48, near: 0.05, far: 100)
    * makeLookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
  view.prevViewProj = view.currentViewProj
  view.environment = SIMD4(0, 0, 0, 0)
  view.sunParams.w = 0
  view.lens.z = 1
  var floorMeans = [Float](), emitterMeans = [Float]()
  for mode in [UInt32(3), 2, 1, 0] {
    view.samplingMode = mode
    let pixels = render(view, samples: 128)
    let floor = pixels.indices.filter { lastPositions[$0].w > 0 && lastNormals[$0].y > 0.99 && abs(lastPositions[$0].y) < 1e-3 }
    let emitter = pixels.indices.filter { lastPositions[$0].w > 0 && lastNormals[$0].y < -0.99 && abs(lastPositions[$0].y - 1) < 1e-3 }
    require(floor.count > 300 && emitter.count > 20, "strategy view sees the floor and the emitter (\(floor.count), \(emitter.count))")
    floorMeans.append(floor.reduce(Float(0)) { $0 + pixels[$1].x + pixels[$1].y + pixels[$1].z } / Float(floor.count))
    emitterMeans.append(emitter.reduce(Float(0)) { $0 + pixels[$1].x + pixels[$1].y + pixels[$1].z } / Float(emitter.count))
    if mode == 1 { savePreview([pixels], width: 64, height: 48, name: "graph-emission-mis.png") }
  }
  print("Graph emitter floor (BSDF, Light, MIS, ReSTIR): \(floorMeans); emitter: \(emitterMeans)")
  require(floorMeans[0] > 0.05, "the graph emitter lights the floor")
  for (i, value) in floorMeans.enumerated().dropFirst() {
    require(abs(value - floorMeans[0]) < 0.03 * floorMeans[0], "graph-emitter strategy \(i) matches BSDF sampling on the floor")
  }
  // Camera rays add the emission itself with weight 1 in every mode (edge pixels mix in the floor).
  let visible = 3 * (left + right) / 2
  for value in emitterMeans {
    require(value > 0.5 * (visible.x + visible.y + visible.z) && abs(value - emitterMeans[0]) < 0.03 * emitterMeans[0],
      "the emitter is seen with its textured radiance in every mode")
  }
  print("PASS: fix-shaderball-emission textured graph radiance at hits and light samples; BSDF, light, MIS and ReSTIR agree")

  // UsdPreviewSurface emissiveColor (connected) is the emitted radiance at unit luminance.
  let preview = folder.appendingPathComponent("preview.usda")
  try """
    #usda 1.0
    (
        defaultPrim = "World"
        metersPerUnit = 1
        upAxis = "Y"
    )
    def Xform "World"
    {
        def Mesh "Panel" (prepend apiSchemas = ["MaterialBindingAPI"])
        {
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 1, 2, 3]
            point3f[] points = [(-0.5, 1, -0.5), (0.5, 1, -0.5), (0.5, 1, 0.5), (-0.5, 1, 0.5)]
            texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (interpolation = "faceVarying")
            uniform token subdivisionScheme = "none"
            rel material:binding = </World/Screen>
        }
        def Material "Screen"
        {
            token outputs:surface.connect = </World/Screen/Surface.outputs:surface>
            def Shader "Surface"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:emissiveColor.connect = </World/Screen/Texture.outputs:rgb>
                token outputs:surface
            }
            def Shader "Reader"
            {
                uniform token info:id = "UsdPrimvarReader_float2"
                string inputs:varname = "st"
                float2 outputs:result
            }
            def Shader "Texture"
            {
                uniform token info:id = "UsdUVTexture"
                asset inputs:file = @glow.png@
                token inputs:sourceColorSpace = "raw"
                float2 inputs:st.connect = </World/Screen/Reader.outputs:result>
                float3 outputs:rgb
            }
        }
    }
    """.write(to: preview, atomically: true, encoding: .utf8)
  let screenImport = try USDImporter.load(preview, into: ProjectDocument())
  let screenSlot = screenImport.document.graph!.materials.first(where: { $0.name == "Screen" })!.slot
  let screenProgram = screenImport.document.scenes[6]!.materialX?[screenSlot]
  require(screenProgram?.emission != nil && abs((screenProgram?.emissionWeight ?? 0) - 1) < 1e-4
      && !screenImport.report.contains(where: { $0.contains("fallback") }),
    "a connected PreviewSurface emissiveColor imports as graph emission (\(screenImport.report))")
  print("PASS: fix-shaderball-emission UsdPreviewSurface emissiveColor maps to OpenPBR emission")

  // The ASWF Standard Shader Ball: the neutral material (connected OpenPBR emission from a
  // file-less clamped image in the default variant) compiles; no material falls back.
  let reference = URL(fileURLWithPath: "build/reference-scenes/ShaderBall-triangulated.usda")
  guard FileManager.default.fileExists(atPath: reference.path) else {
    require(!CommandLine.arguments.contains("--require-reference"),
      "ASWF reference scene is missing; run /usr/bin/python3 scripts/fetch_reference_scene.py")
    print("SKIP: fix-shaderball-emission ASWF Standard Shader Ball not downloaded")
    return
  }
  func neutralSlot(_ document: ProjectDocument) -> Int? {
    document.graph?.materials.first(where: { $0.name == "neutral" })?.slot
  }
  let aswf = try USDImporter.load(reference, into: ProjectDocument())
  let fallbacks = aswf.report.filter { $0.contains("fallback to displayColor") || $0.contains("NOT imported") }
  let aswfNeutral = neutralSlot(aswf.document)
  print("ASWF material fallbacks: \(fallbacks.count) \(fallbacks)")
  require(fallbacks.isEmpty && aswfNeutral.flatMap { aswf.document.scenes[6]!.materialX?[$0] }?.emission != nil,
    "the ASWF Standard Shader Ball imports every material, including neutral, with no fallback")
  // Its internal_emitter = "bulb" variant drives the same graph with emitter_bulb.exr.
  let scene = URL(fileURLWithPath: "build/reference-scenes/StandardShaderBall/standard_shader_ball_scene.usda").standardizedFileURL
  let bulb = folder.appendingPathComponent("ShaderBall-bulb.usda")
  try """
    #usda 1.0
    (
        subLayers = [@\(scene.path)@]
        metersPerUnit = 0.01
        upAxis = "Y"
        startTimeCode = 3
        endTimeCode = 3
    )
    over "standard_shader_ball_scene" (
        variants = {
            string surface_geometry = "triangulated"
            string example_material = "usdpreview_plastic"
            string internal_emitter = "bulb"
        }
    ) {}
    """.write(to: bulb, atomically: true, encoding: .utf8)
  let lit = try USDImporter.load(bulb, into: ProjectDocument())
  let bulbMap = try Data(contentsOf: URL(fileURLWithPath: "build/reference-scenes/StandardShaderBall/maps/emitter_bulb.exr"))
  let litFallbacks = lit.report.filter { $0.contains("fallback to displayColor") || $0.contains("NOT imported") }
  let litSlot = neutralSlot(lit.document)
  let litProgram = litSlot.flatMap { lit.document.scenes[6]!.materialX?[$0] }
  print("ASWF bulb variant: fallbacks \(litFallbacks), neutral images \(litProgram?.images.count ?? -1), weight \(litProgram?.emissionWeight ?? -1)")
  require(litFallbacks.isEmpty && litProgram?.emission != nil && (litProgram?.emissionWeight ?? 0) > 0
      && litProgram?.images.contains(where: { $0.data == bulbMap }) == true,
    "the bulb variant's textured neutral emission compiles")
  try controller.restore(lit.document)
  let constantEmitters = testRenderer.materials.orderedTriangles.filter {
    (testRenderer.materials.emissions[Int($0.uvc.z)].map { simd_length_squared($0) > 0 }) == true }.count
  let bulbList = Int(testRenderer.materials.emitterBuffer.contents().load(as: UInt32.self))
  require(bulbList > constantEmitters, "neutral's graph emission joins the light list (\(bulbList) > \(constantEmitters))")
  var bulbView = makeUniforms(scene: 6, mode: 1, width: 96, height: 72)
  bulbView.environment.w = Float(testRenderer.materials.nodeCount)
  bulbView.environment.x = lit.document.options.environmentIntensity
  bulbView.sunParams.w = lit.document.options.sunIntensity
  bulbView.lens.z = 1
  let c = lit.document.camera
  let bulbEye = c.target + SIMD3(c.distance * cos(c.pitch) * sin(c.yaw), c.distance * sin(c.pitch), -c.distance * cos(c.pitch) * cos(c.yaw))
  bulbView.cameraPos = SIMD4(bulbEye, c.fov); bulbView.cameraTarget = SIMD4(c.target, 16)
  bulbView.currentViewProj = makePerspective(fovyRadians: c.fov * .pi / 180, aspect: 96.0 / 72, near: 0.001, far: 100)
    * makeLookAt(eye: bulbEye, target: c.target, up: SIMD3(0, 1, 0))
  bulbView.prevViewProj = bulbView.currentViewProj
  let bulbPixels = render(bulbView, samples: 16)
  require(bulbPixels.reduce(Float(0)) { $0 + $1.x + $1.y + $1.z } > 1, "the bulb variant renders lit")
  savePreview([bulbPixels], width: 96, height: 72, name: "openusd-shaderball-bulb.png")
  print("PASS: fix-shaderball-emission ASWF Standard Shader Ball imports with no material fallbacks; bulb emission renders")
}
try fixShaderballEmissionChecks()
