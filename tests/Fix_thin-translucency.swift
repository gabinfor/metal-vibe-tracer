// Thin-walled diffuse translucency (REFERENCES.md OPENPBR thin-walled subsurface, ADOBEOPENPBR
// thin_wall_diffuse_trans_lobe, MITSUBA3 principledthin): OpenPBR subsurface_weight, subsurface_color and
// subsurface_scatter_anisotropy on a geometry_thin_walled surface compile (constant or textured), reach the GPU,
// conserve energy, split it into transmission (anisotropy + 1) / 2 and reflection, are reciprocal, sample the
// PDF they evaluate, and let light through to the back side under every strategy and transport.
@MainActor func fixThinTranslucencyChecks() throws {
  let r = testRenderer
  let saved = (r.lightTransport, r.indirectReuse)
  defer { (r.lightTransport, r.indirectReuse) = saved }
  let folder = testOutputDirectory.appendingPathComponent("thin-translucency", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  func parse(_ name: String, _ body: String) throws -> MaterialXImport {
    try MaterialXImporter.read(
      Data(("<materialx version=\"1.39\">" + body + "</materialx>").utf8), baseURL: folder, source: name + ".mtlx")
  }
  let thin = "<input name=\"geometry_thin_walled\" type=\"boolean\" value=\"true\"/>"
  // 2 x 1 linear texture: left half (u < 0.5) and right half one colour each.
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
  for (i, c) in ([255, 128, 0, 255] + [0, 128, 255, 255] as [UInt8]).enumerated() { bitmap.bitmapData![i] = c }
  try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("leaf.png"))

  // --- Importer ----------------------------------------------------------------------------------
  let leaf = try parse("Leaf", """
    <open_pbr_surface name="Leaf" type="surfaceshader">\(thin)
      <input name="subsurface_weight" type="float" value="0.6"/><input name="subsurface_color" type="color3" value="0.9, 0.6, 0.3"/>
      <input name="subsurface_scatter_anisotropy" type="float" value="0.2"/><input name="subsurface_radius" type="float" value="0.5"/>
    </open_pbr_surface>
    """)
  let program = leaf.materials.first
  require(program?.subsurfaceWeight != nil && program?.subsurfaceColor != nil && program?.subsurfaceAnisotropy == 0.2,
    "constant thin-walled subsurface compiles to registers and the anisotropy constant (\(leaf.report))")
  let textured = try parse("Textured", """
    <image name="tex" type="color3"><input name="file" type="filename" value="leaf.png"/>
      <input name="filtertype" type="string" value="linear"/></image>
    <open_pbr_surface name="Textured" type="surfaceshader">\(thin)
      <input name="subsurface_weight" type="float" value="1"/><input name="subsurface_color" type="color3" nodename="tex"/>
    </open_pbr_surface>
    """)
  require(textured.materials.first?.subsurfaceColor != nil && textured.materials.first?.images.count == 1
      && textured.materials.first?.subsurfaceAnisotropy == nil,
    "a textured subsurface_color compiles (\(textured.report))")
  let zero = try parse("Zero", "<open_pbr_surface name=\"Zero\" type=\"surfaceshader\">\(thin)<input name=\"subsurface_weight\" type=\"float\" value=\"0\"/></open_pbr_surface>")
  require(zero.materials.first.map { $0.subsurfaceWeight == nil && $0.subsurfaceColor == nil } == true,
    "a zero subsurface_weight adds no registers")
  for (name, body, message) in [
    ("Solid", "<input name=\"subsurface_weight\" type=\"float\" value=\"0.5\"/>", "volumetric subsurface scattering"),
    ("Linked", thin + "<input name=\"subsurface_weight\" type=\"float\" value=\"1\"/><input name=\"subsurface_scatter_anisotropy\" type=\"float\" nodename=\"g\"/>",
     "subsurface_scatter_anisotropy must be a constant"),
    ("Range", thin + "<input name=\"subsurface_scatter_anisotropy\" type=\"float\" value=\"1.5\"/>", "within -1 to 1"),
  ] {
    let rejected = try parse(name, "<constant name=\"g\" type=\"float\"><input name=\"value\" type=\"float\" value=\"0\"/></constant>"
      + "<open_pbr_surface name=\"\(name)\" type=\"surfaceshader\">\(body)</open_pbr_surface>")
    require(rejected.materials.isEmpty && rejected.report.contains { $0.contains(message) },
      "\(name) subsurface is rejected with '\(message)': \(rejected.report)")
  }

  // --- GPU: resolved inputs and the BSDF ------------------------------------------------------------
  var state = SceneState()
  state.materialX = [8: leaf.materials[0], 9: textured.materials[0]]
  let l = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
  try l.restore(state)
  let kernel = """
    float4 thin_resolved(uint slot, float2 uv, constant MaterialResources &images, thread Material &m) {
        HitRecord h = {}; h.mat.type = OPENPBR; h.mat.slot = slot; h.uv = uv; h.front_face = true;
        h.normal = h.geometricNormal = float3(0, 0, 1);
        Ray ray = { float3(0, 0, 1), float3(0, 0, -1) };
        TextureFootprint fp = { float2(0), float2(0) };
        resolve_materialx(h, ray, images, fp); m = h.mat;
        return h.mat.subsurface;
    }
    kernel void thin_probe(constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(3)]], uint id [[thread_position_in_grid]]) {
        if (id != 0) return;
        Material leaf;
        out[0] = thin_resolved(8u, float2(0.5f), images, leaf);
        out[1] = float4(leaf.subsurfaceAnisotropy, leaf.transmissionTint.w, material_transmits(leaf) ? 1 : 0, 0);
        Material tex;
        out[2] = thin_resolved(9u, float2(0.25f, 0.5f), images, tex);
        out[3] = thin_resolved(9u, float2(0.75f, 0.5f), images, tex);
        // Cases: 0 white, no specular, anisotropy 0 (furnace); 1 as 0 with anisotropy 0.2; 2 the leaf with
        // a specular layer (IOR 1.5) over base colour 0.5; 3 as 0 seen from the back face; 4-6 white under a
        // specular layer at roughness 0.03, 0.3 and 0.8 (above 0.04 the dielectric multiple-scattering lobe is active;
        // scripts/prepare_shaders.py leaves the subsurface share out of it on thin walls).
        Wavelengths wl;
        float3 n = float3(0, 0, 1);
        for (uint c = 0; c < 7; ++c) {
            Material m = {}; m.type = OPENPBR; m.usesMaterialX = 1u; m.ior = 1.5f;
            m.roughness = c == 4 ? 0.03f : c == 6 ? 0.8f : 0.3f;
            m.baseWeight = 1.0f; m.slot = 8u; m.specularColor = float3(1.0f); m.transmissionTint = float4(1, 1, 1, 1);
            m.albedo = float3(0.5f); m.specularWeight = c == 2 || c >= 4 ? 1.0f : 0.0f;
            m.subsurface = c == 2 ? leaf.subsurface : float4(1.0f);
            m.subsurfaceAnisotropy = c == 2 ? leaf.subsurfaceAnisotropy : c == 1 ? 0.2f : 0.0f;
            float3 normal = c == 3 ? -n : n;
            m.geometricNormal = normal; m.inside = c == 3;
            float3 wo = normalize(float3(sin(0.7f), 0, cos(0.7f))) * (c == 3 ? -1.0f : 1.0f);
            float3 reflected = float3(0), transmitted = float3(0);
            float pdfError = 0.0f, weightError = 0.0f;
            uint seed = 977u + c;
            const uint N = 16384u;
            for (uint i = 0; i < N; ++i) {
                float3 wi; Spectrum w; float pdf;
                if (!sample_bsdf(m, normal, -wo, c != 3, seed, wi, w, pdf, wl)) continue;
                if (dot(wi, normal) > 0.0f) reflected += w; else transmitted += w;
                float evalPdf;
                Spectrum f = eval_bsdf_with_pdf(m, normal, wo, wi, evalPdf, wl);
                pdfError = max(pdfError, abs(evalPdf - pdf) / max(pdf, 1e-3f));
                weightError = max(weightError, length(f * abs(dot(normal, wi)) / pdf - w) / max(length(w), 1e-3f));
            }
            out[4 + 3 * c] = float4(reflected / float(N), 0);
            out[5 + 3 * c] = float4(transmitted / float(N), 0);
            out[6 + 3 * c] = float4(pdfError, weightError, 0, 0);
        }
        // Reciprocity: f(wo -> wi) = f(wi -> wo), the reverse seen from wi's side, for reflected and transmitted
        // pairs of the leaf without and with its specular layer, at roughness 0.03 and 0.3 (multiple-scattering lobe
        // active; its transmitted share, tabulated with the IOR on one side and its inverse on the other, would not be
        // reciprocal).
        float4 worstReflected = float4(0.0f), worstTransmitted = float4(0.0f);
        float pairs = 0.0f, below = 0.0f;
        for (uint layer = 0; layer < 4; ++layer) {
            Material m = {}; m.type = OPENPBR; m.usesMaterialX = 1u; m.roughness = layer < 2 ? 0.03f : 0.3f; m.ior = 1.5f;
            m.baseWeight = 1.0f; m.slot = 8u; m.specularColor = float3(1.0f); m.transmissionTint = float4(1, 1, 1, 1);
            m.albedo = float3(0.5f); m.specularWeight = float(layer % 2);
            m.subsurface = leaf.subsurface; m.subsurfaceAnisotropy = leaf.subsurfaceAnisotropy;
            uint seed = 4242u;
            for (uint i = 0; i < 4096u; ++i) {
                float3 wo = sample_cosine_hemisphere(n, rand_f2(seed));
                float3 u = rand_f3(seed);
                float z = 1.0f - 2.0f * u.x, s = sqrt(max(0.0f, 1.0f - z * z));
                float3 wi = float3(s * cos(TWO_PI * u.y), s * sin(TWO_PI * u.y), z);
                if (abs(wi.z) < 0.05f || wo.z < 0.05f) continue;
                float3 back = wi.z > 0.0f ? n : -n;
                Material a = m; a.geometricNormal = n;
                Material b = m; b.geometricNormal = back; b.inside = wi.z < 0.0f;
                float3 f1 = eval_bsdf(a, n, wo, wi, wl), f2 = eval_bsdf(b, back, wi, wo, wl);
                if (max(f1.x, max(f1.y, f1.z)) < 1e-4f) continue;
                float error = length(f1 - f2) / length(f1);
                if (wi.z < 0.0f) worstTransmitted[layer] = max(worstTransmitted[layer], error);
                else worstReflected[layer] = max(worstReflected[layer], error);
                pairs += 1.0f; below += wi.z < 0.0f ? 1.0f : 0.0f;
            }
        }
        out[25] = worstReflected;
        out[26] = worstTransmitted;
        out[27] = float4(pairs, below, 0, 0);
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernel, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "thin_probe")!)
  let out = gpu.makeBuffer(length: 28 * 16, options: .storageModeShared)!
  let command = r.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(pipeline)
  require(l.bind(encoder), "thin translucency probe binds material resources")
  encoder.setBuffer(out, offset: 0, index: 3)
  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
  let v = (0..<28).map { out.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  print("Thin translucency probe: \(v)")
  func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ e: Float) -> Bool { simd_reduce_max(simd_abs(a - b)) < e }
  require(near(v[0], SIMD4(0.9, 0.6, 0.3, 0.6), 1e-6) && v[1] == SIMD4(0.2, 1, 1, 0),
    "the leaf's subsurface colour, weight and anisotropy reach the resolved material (\(v[0]), \(v[1]))")
  require(near(v[2], SIMD4(1, 128.0 / 255, 0, 1), 2e-3) && near(v[3], SIMD4(0, 128.0 / 255, 1, 1), 2e-3),
    "a textured subsurface_color follows the texture (\(v[2]), \(v[3]))")
  for c in 0..<7 {
    let reflect = v[4 + 3 * c], transmit = v[5 + 3 * c], errors = v[6 + 3 * c]
    require(errors.x < 1e-3 && errors.y < 1e-3, "case \(c): sampled PDFs and weights match evaluation (\(errors))")
    let total = reflect + transmit
    print("Thin translucency case \(c): reflected \(reflect), transmitted \(transmit)")
    require((0..<3).allSatisfy { total[$0] <= 1.005 }, "case \(c): energy is conserved (\(total))")
    switch c {
    case 4, 5, 6:
      require(near(total, SIMD4(1, 1, 1, 0), 0.005) && transmit.x > 0.45 && transmit.x <= 0.5,
        "case \(c): a white thin wall under a specular layer keeps its energy; the layer reflects some (\(reflect), \(transmit))")
    case 0, 3:
      require(near(total, SIMD4(1, 1, 1, 0), 0.01) && near(transmit, SIMD4(0.5, 0.5, 0.5, 0), 0.01),
        "case \(c): a white thin wall without specular scatters everything, half of it through (\(reflect), \(transmit))")
    case 1:
      require(near(total, SIMD4(1, 1, 1, 0), 0.01) && near(transmit, SIMD4(0.6, 0.6, 0.6, 0), 0.01),
        "anisotropy 0.2 transmits (1 + 0.2) / 2 (\(transmit))")
    default:
      require(transmit.x > transmit.y && transmit.y > transmit.z && transmit.z > 0.01 && transmit.x < 0.6 * 0.6 * 0.9,
        "the leaf transmits its subsurface colour under the specular layer (\(transmit))")
    }
  }
  print("Thin translucency reciprocity, worst relative error (roughness 0.03 without / with specular, 0.3 without / with):"
    + " reflected \(v[25]), transmitted \(v[26])")
  require(simd_reduce_max(v[25]) < 1e-3 && simd_reduce_max(v[26]) < 1e-3 && v[27].x > 8000 && v[27].y > 3600,
    "the thin translucent BSDF is reciprocal (\(v[25]), \(v[26]), \(v[27]))")

  // --- Rendering: a translucent plate lit only from behind ------------------------------------------
  // The camera sees the plate's unlit side; light reaches it only through the plate. BSDF-only, light-only,
  // MIS and ReSTIR (GI and unified PT), in RGB and spectral transport, must agree.
  let stage = folder.appendingPathComponent("backlit.usda")
  try """
    #usda 1.0
    (
        defaultPrim = "World"
        metersPerUnit = 1
        upAxis = "Y"
    )
    def Xform "World"
    {
        def Mesh "Plate" (prepend apiSchemas = ["MaterialBindingAPI"])
        {
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 1, 2, 3]
            point3f[] points = [(-1.5, -0.5, 0), (1.5, -0.5, 0), (1.5, 2.5, 0), (-1.5, 2.5, 0)]
            uniform token subdivisionScheme = "none"
            rel material:binding = </World/Paper>
        }
        def Mesh "Emitter" (prepend apiSchemas = ["MaterialBindingAPI"])
        {
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 1, 2, 3]
            point3f[] points = [(-0.5, 0.5, 1), (-0.5, 1.5, 1), (0.5, 1.5, 1), (0.5, 0.5, 1)]
            uniform token subdivisionScheme = "none"
            rel material:binding = </World/Glow>
        }
        def Material "Paper"
        {
            token outputs:mtlx:surface.connect = </World/Paper/Surface.outputs:out>
            def Shader "Surface"
            {
                uniform token info:id = "ND_open_pbr_surface_surfaceshader"
                color3f inputs:base_color = (0.5, 0.5, 0.5)
                bool inputs:geometry_thin_walled = 1
                float inputs:subsurface_weight = 0.8
                color3f inputs:subsurface_color = (0.9, 0.6, 0.3)
                float inputs:specular_roughness = 0.4
                token outputs:out
            }
        }
        def Material "Glow"
        {
            token outputs:mtlx:surface.connect = </World/Glow/Surface.outputs:out>
            def Shader "Surface"
            {
                uniform token info:id = "ND_open_pbr_surface_surfaceshader"
                color3f inputs:base_color = (0, 0, 0)
                float inputs:emission_luminance = 4
                token outputs:out
            }
        }
    }
    """.write(to: stage, atomically: true, encoding: .utf8)
  let lit = try USDImporter.load(stage, into: ProjectDocument())
  let paperSlot = lit.document.graph!.materials.first(where: { $0.name == "Paper" })!.slot
  require(lit.document.scenes[6]!.materialX?[paperSlot]?.subsurfaceWeight != nil
      && !lit.report.contains(where: { $0.contains("fallback") || $0.contains("NOT imported") }),
    "USD OpenPBR thin-walled subsurface imports (\(lit.report))")
  try controller.restore(lit.document)
  var view = makeUniforms(scene: 6, mode: 3, width: 48, height: 36)
  let eye = SIMD3<Float>(0, 1, -2.5), target = SIMD3<Float>(0, 1, 0)
  view.cameraPos = SIMD4(eye, 45); view.cameraTarget = SIMD4(target, 8)
  view.currentViewProj = makePerspective(fovyRadians: 45 * .pi / 180, aspect: 48.0 / 36, near: 0.05, far: 100)
    * makeLookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
  view.prevViewProj = view.currentViewProj
  view.environment = SIMD4(0, 0, 0, 0)
  view.sunParams.w = 0
  view.lens.z = 1
  var means: [(String, SIMD3<Float>)] = []
  for transport in [LightTransport.rgb, .spectral] {
    r.lightTransport = transport
    for (mode, reuse, label) in [(UInt32(3), IndirectReuse.restirGI, "BSDF"), (2, .restirGI, "light"), (1, .restirGI, "MIS"),
                                 (0, .restirGI, "ReSTIR GI"), (0, .restirPTUnified, "unified ReSTIR PT")] {
      r.indirectReuse = reuse
      view.samplingMode = mode
      let pixels = render(view, samples: 256)
      let plate = pixels.indices.filter { lastPositions[$0].w > 0 && abs(lastPositions[$0].z) < 1e-3 }
      require(plate.count > 1200, "\(label): the view sees the plate (\(plate.count))")
      let sum = plate.reduce(SIMD3<Float>(0, 0, 0)) { $0 + SIMD3(pixels[$1].x, pixels[$1].y, pixels[$1].z) }
      means.append(("\(transport == .rgb ? "RGB" : "spectral") \(label)", sum / Float(plate.count)))
      if mode == 1 && transport == .rgb { savePreview([pixels], width: 48, height: 36, name: "thin-translucency-mis.png") }
    }
  }
  print("Back-lit translucent plate means: \(means)")
  let reference = means[0].1
  require(reference.x > 0.05 && reference.x > reference.y && reference.y > reference.z,
    "light passes through the plate to its unlit side, coloured by subsurface_color (\(reference))")
  for (label, mean) in means.dropFirst() {
    require(simd_reduce_max(simd_abs(mean - reference) / reference) < 0.03, "\(label) matches BSDF sampling (\(mean) vs \(reference))")
  }
  print("PASS: thin-walled OpenPBR subsurface compiles, conserves energy, is reciprocal, and transmits light under every strategy")
}
try fixThinTranslucencyChecks()
