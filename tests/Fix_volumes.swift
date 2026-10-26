// Participating media, per-light spectra and spot cones (docs/VOLUME_DESIGN.md §6; REFERENCES.md ADOBEOPENPBR,
// PBRT2023, HG1941, PLANCK, CIEDATA, OPENUSD). Unit checks: the spectral free-flight sampler against the
// analytic transmittance and scattering integrals per lane, Henyey-Greenstein normalisation and mean cosine,
// the ShapingAPI cone, and the blackbody and narrow-band chromaticities. Renders: Beer-Lambert through an
// absorbing block, white furnaces (an albedo-one interior medium, and albedo-one scene haze with medium
// spheres) that must reproduce the environment, and a spot cone's cutoff with its light and BSDF strategies.
@MainActor func fixVolumeChecks() throws {
  let r = testRenderer
  let saved = (r.lightTransport, r.samplingMode, r.medium, r.materials.emitterLights)
  defer { (r.lightTransport, r.samplingMode, r.medium, r.materials.emitterLights) = saved }

  // --- Host: spectra -----------------------------------------------------------------------------
  guard let observer = CIEObserver.shared else { throw MaterialLibrary.error("CIE observer table missing") }
  func xy(_ spectrum: EmitterLight.Spectrum) -> SIMD2<Double> {
    let light = EmitterLight(spectrum: spectrum)
    var xyz = SIMD3<Double>(0, 0, 0)
    for (i, c) in observer.cmf.enumerated() { xyz += (light.shape(Double(360 + i)) ?? 0) * c }
    return SIMD2(xyz.x, xyz.y) / (xyz.x + xyz.y + xyz.z)
  }
  // CIE A is Planck's law at 2848 K with c2 = 1.435e-2 m K, which is 2855.5 K with the exact c2 (CIE 015:2018).
  let a = xy(.blackbody(kelvin: 2855.5))
  print(String(format: "Blackbody 2855.5 K chromaticity (%.5f, %.5f); CIE A (0.44757, 0.40745)", a.x, a.y))
  require(abs(a.x - 0.44757) < 3e-4 && abs(a.y - 0.40745) < 3e-4, "a 2855.5 K blackbody has CIE A's chromaticity")
  let laser = xy(.narrowband(center: 532, fwhm: 2)), line = observer.cmf[532 - 360]
  let lineXY = SIMD2(line.x, line.y) / (line.x + line.y + line.z)
  require(simd_length(laser - lineXY) < 2e-3, "a 2 nm band at 532 nm has the 532 nm line's chromaticity (\(laser) vs \(lineXY))")
  let warm = EmitterLight(spectrum: .blackbody(kelvin: 2700)).slotParameters(observer: observer)
  require(abs(0.2126 * warm[1].x + 0.7152 * warm[1].y + 0.0722 * warm[1].z - 1) < 1e-3 && warm[1].x > warm[1].z,
    "a blackbody's RGB colour has luminance one and is warm at 2700 K (\(warm[1]))")
  require(EmitterLight(spectrum: .blackbody(kelvin: 100)).isValid == false
    && EmitterLight(spectrum: .narrowband(center: 900, fwhm: 2)).isValid == false, "out-of-range spectra are rejected")

  // --- GPU units ---------------------------------------------------------------------------------
  let kernels = """
    // Per thread: 4096 free flights over [0.25, 1.25]: out[2 tid] = mean weight of flights that pass,
    // out[2 tid + 1] = mean weight of scattering events; odd threads start with one lane only (a hero path).
    kernel void volume_distance(device float4 *out [[buffer(0)]], uint tid [[thread_position_in_grid]]) {
        Medium m;
    #if VIBE_SPECTRAL
        m.sigmaT = Spectrum(0.5f, 1.0f, 2.0f, 4.0f); m.sigmaS = m.sigmaT * Spectrum(0.8f, 0.6f, 0.4f, 0.2f);
        Spectrum start = tid % 2u == 0u ? Spectrum(1.0f) : Spectrum(0.0f, 4.0f, 0.0f, 0.0f);
    #else
        m.sigmaT = Spectrum(0.5f, 1.0f, 2.0f); m.sigmaS = m.sigmaT * Spectrum(0.8f, 0.6f, 0.4f);
        Spectrum start = tid % 2u == 0u ? Spectrum(1.0f) : Spectrum(0.0f, 3.0f, 0.0f);
    #endif
        m.g = 0.0f;
        uint seed = 7919u * tid + 1u;
        Spectrum pass = Spectrum(0.0f), events = Spectrum(0.0f);
        for (int i = 0; i < 4096; ++i) {
            Spectrum t = start;
            float d;
            if (medium_sample_distance(m, 0.25f, 1.25f, t, seed, d)) events += t; else pass += t;
        }
        pass /= 4096.0f; events /= 4096.0f;
    #if VIBE_SPECTRAL
        out[2u * tid] = pass; out[2u * tid + 1u] = events;
    #else
        out[2u * tid] = float4(pass, 0.0f); out[2u * tid + 1u] = float4(events, 0.0f);
    #endif
    }
    // Per g in -0.9 ... 0.9: (g, mean of 4 pi p over uniform directions, mean cosine of HG samples, 0).
    kernel void volume_hg(device float4 *out [[buffer(0)]], uint tid [[thread_position_in_grid]]) {
        float g = (float(tid) - 3.0f) * 0.3f;
        uint seed = 31u * tid + 7u;
        float norm = 0.0f, mean = 0.0f;
        for (int i = 0; i < 65536; ++i) {
            norm += 4.0f * PI * hg_phase(1.0f - 2.0f * rand_f(seed), g);
            mean += hg_sample(float3(0, 0, 1), g, rand_f2(seed)).z;
        }
        out[tid] = float4(g, norm / 65536.0f, mean / 65536.0f, 0.0f);
    }
    // emitter_shaping of slot 9 at 64 angles off its axis.
    kernel void volume_shaping(constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(0)]],
                               uint tid [[thread_position_in_grid]]) {
        float theta = float(tid) * (PI / 2.0f) / 63.0f;
        out[tid] = float4(theta, emitter_shaping(9u, float3(0, 0, 1), float3(sin(theta), 0, cos(theta)), images), 0, 0);
    }
    """
  r.materials.emitterLights = [9: EmitterLight(coneAngle: 30, coneSoftness: 0.5, focus: 2)]
  _ = render(makeUniforms(scene: 3, mode: 1, width: 8, height: 8), samples: 1)
  for spectral in [false, true] {
    let library = try rendererShaderLibrary(kernels, spectral: spectral)
    func run(_ name: String, width: Int, _ buffer: MTLBuffer) throws {
      var unit = makeUniforms(scene: 3, mode: 1, width: 1, height: 1)
      let state = try gpu.makeComputePipelineState(function: library.makeFunction(name: name)!)
      let command = r.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
      encoder.setComputePipelineState(state)
      encoder.setBytes(&unit, length: MemoryLayout<Uniforms>.stride, index: 1)
      r.materials.bind(encoder)
      encoder.setBuffer(buffer, offset: 0, index: 0)
      encoder.dispatchThreads(MTLSize(width: width, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
      encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
      require(command.status == .completed, "\(name) completes: \(String(describing: command.error))")
    }
    let lanes = spectral ? 4 : 3, label = spectral ? "spectral" : "RGB"
    let sigmaT: [Double] = [0.5, 1, 2, 4], albedo: [Double] = [0.8, 0.6, 0.4, 0.2]
    let threads = 256
    let flights = gpu.makeBuffer(length: threads * 2 * 16, options: .storageModeShared)!
    try run("volume_distance", width: threads, flights)
    for parity in 0..<2 {
      var pass = SIMD4<Double>(repeating: 0), events = SIMD4<Double>(repeating: 0)
      for t in stride(from: parity, to: threads, by: 2) {
        pass += SIMD4<Double>(flights.contents().load(fromByteOffset: 32 * t, as: SIMD4<Float>.self))
        events += SIMD4<Double>(flights.contents().load(fromByteOffset: 32 * t + 16, as: SIMD4<Float>.self))
      }
      pass /= Double(threads / 2); events /= Double(threads / 2)
      for k in 0..<lanes {
        let start: Double = parity == 0 ? 1 : (k == 1 ? Double(lanes) : 0)
        let T = exp(-sigmaT[k]), scattered = albedo[k] * (1 - T)
        require(abs(pass[k] - start * T) < 0.01 * max(start, 0.1) && abs(events[k] - start * scattered) < 0.01 * max(start, 0.1),
          "\(label) free flights are unbiased per lane (lane \(k), \(parity == 0 ? "all lanes" : "one lane")): pass \(pass[k]) vs \(start * T), events \(events[k]) vs \(start * scattered)")
      }
    }
    let hg = gpu.makeBuffer(length: 7 * 16, options: .storageModeShared)!
    try run("volume_hg", width: 7, hg)
    for i in 0..<7 {
      let v = hg.contents().load(fromByteOffset: 16 * i, as: SIMD4<Float>.self)
      require(abs(v.y - 1) < 0.03 && abs(v.z - v.x) < 0.01, "\(label) HG phase integrates to one and its samples have mean cosine g (\(v))")
    }
    let shaping = gpu.makeBuffer(length: 64 * 16, options: .storageModeShared)!
    try run("volume_shaping", width: 64, shaping)
    var worst: Float = 0
    for i in 0..<64 {
      let v = shaping.contents().load(fromByteOffset: 16 * i, as: SIMD4<Float>.self)
      let cut: Float = .pi / 6, start = cut * 0.5, theta = v.x
      let t = min(max((theta - start) / (cut - start), 0), 1)
      let expected = theta > cut ? 0 : pow(cos(theta), 2) * (1 - t * t * (3 - 2 * t))
      worst = max(worst, abs(v.y - expected))
    }
    require(worst < 1e-4, "\(label) emitter shaping follows the ShapingAPI cone, smoothstep softness and focus (max error \(worst))")
  }
  print("PASS: volume units: per-lane free flights, HG phase, ShapingAPI cone; blackbody and narrow-band chromaticity")

  // --- Renders -------------------------------------------------------------------------------------
  let folder = testOutputDirectory.appendingPathComponent("volumes", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  func stage(_ name: String, _ body: String, root: String = "") throws -> ProjectDocument {
    let url = folder.appendingPathComponent(name + ".usda")
    try """
      #usda 1.0
      (
          defaultPrim = "World"
          metersPerUnit = 1
          upAxis = "Y"
      )
      def Xform "World"
      {
      \(root)
      \(body)
      }
      """.write(to: url, atomically: true, encoding: .utf8)
    return try USDImporter.load(url, into: ProjectDocument()).document
  }
  func look(_ name: String, _ inputs: String) -> String {
    """
        def Material "\(name)"
        {
            token outputs:mtlx:surface.connect = </World/\(name)/Surface.outputs:out>
            def Shader "Surface"
            {
                uniform token info:id = "ND_open_pbr_surface_surfaceshader"
                \(inputs)
                token outputs:out
            }
        }

    """
  }
  let medium = "float inputs:specular_weight = 0\n            float inputs:transmission_weight = 1\n            "
  let dome = "\ndef DomeLight \"Dome\"\n    {\n        color3f inputs:color = (1, 1, 1)\n        float inputs:intensity = 1\n    }"
  func view(_ eye: SIMD3<Float>, _ target: SIMD3<Float>, width: Int, height: Int, mode: UInt32 = 1) -> Uniforms {
    var v = makeUniforms(scene: 6, mode: mode, width: width, height: height)
    v.cameraPos = SIMD4(eye, 40); v.cameraTarget = SIMD4(target, 64)
    v.currentViewProj = makePerspective(fovyRadians: 40 * .pi / 180, aspect: Float(width) / Float(height), near: 0.05, far: 100)
      * makeLookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
    v.prevViewProj = v.currentViewProj
    v.environment = SIMD4(r.options.environmentIntensity, 0, r.materials.environmentData == nil ? 0 : 1, Float(r.materials.nodeCount))
    v.sunParams.w = 0
    v.lens.z = 1
    return v
  }
  func mean(_ pixels: [SIMD4<Float>], _ indices: [Int]) -> SIMD3<Float> {
    indices.reduce(SIMD3<Float>(repeating: 0)) { $0 + SIMD3(pixels[$1].x, pixels[$1].y, pixels[$1].z) } / Float(max(1, indices.count))
  }

  // Beer-Lambert: an absorbing index-matched block 1 m thick (transmission_color 0.5 per 0.5 m) in front of an
  // emitter: radiance through it is 0.25 of the emitter's, in both transports.
  let beer = try stage("beer-lambert", look("Panel", "color3f inputs:base_color = (0, 0, 0)\n            float inputs:emission_luminance = 2\n            color3f inputs:emission_color = (1, 1, 1)")
    + look("Block", medium + "float inputs:transmission_depth = 0.5\n            color3f inputs:transmission_color = (0.5, 0.5, 0.5)") + """
      def Mesh "Emitter" (prepend apiSchemas = ["MaterialBindingAPI"])
      {
          int[] faceVertexCounts = [4]
          int[] faceVertexIndices = [0, 1, 2, 3]
          point3f[] points = [(-3, -3, -1), (3, -3, -1), (3, 3, -1), (-3, 3, -1)]
          uniform token subdivisionScheme = "none"
          rel material:binding = </World/Panel>
      }
      def Cube "Absorber" (prepend apiSchemas = ["MaterialBindingAPI"])
      {
          double size = 1
          float3 xformOp:scale = (0.8, 0.8, 1)
          double3 xformOp:translate = (0, 0, 0.2)
          uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:scale"]
          rel material:binding = </World/Block>
      }
      """)
  // Furnace: an albedo-one sphere medium (transmission_color e^-1 per 0.5 m, transmission_scatter 1, g 0.6)
  // under a uniform white dome renders as the dome itself.
  let furnace = try stage("furnace", look("Cloud", medium + "float inputs:transmission_depth = 0.5\n            color3f inputs:transmission_color = (0.36787944, 0.36787944, 0.36787944)\n            color3f inputs:transmission_scatter = (1, 1, 1)\n            float inputs:transmission_scatter_anisotropy = 0.6") + """
      def Sphere "Sphere" (prepend apiSchemas = ["MaterialBindingAPI"])
      {
          double radius = 0.6
          rel material:binding = </World/Cloud>
      }
      """ + dome)
  // Scene haze of albedo one (density 1.5 per metre, g 0.3) in the box of two medium spheres: the whole view
  // renders as the dome, through the haze, the spheres and the box's edges.
  let haze = try stage("haze", look("Cloud", medium + "float inputs:transmission_depth = 0.5\n            color3f inputs:transmission_color = (0.36787944, 0.36787944, 0.36787944)\n            color3f inputs:transmission_scatter = (1, 1, 1)") + """
      def Sphere "A" (prepend apiSchemas = ["MaterialBindingAPI"])
      {
          double radius = 0.3
          double3 xformOp:translate = (-0.7, -0.5, 0)
          uniform token[] xformOpOrder = ["xformOp:translate"]
          rel material:binding = </World/Cloud>
      }
      def Sphere "B" (prepend apiSchemas = ["MaterialBindingAPI"])
      {
          double radius = 0.3
          double3 xformOp:translate = (0.7, 0.5, 0)
          uniform token[] xformOpOrder = ["xformOp:translate"]
          rel material:binding = </World/Cloud>
      }
      """ + dome, root: "float vibe:medium:density = 1.5\n    color3f vibe:medium:albedo = (1, 1, 1)\n    float vibe:medium:anisotropy = 0.3")
  require(haze.medium == SceneMedium(density: 1.5, albedo: SIMD3(repeating: 1), anisotropy: 0.3, rayleigh: false),
    "the default prim's vibe:medium attributes become the scene medium (\(String(describing: haze.medium)))")
  for transport in [LightTransport.rgb, .spectral] {
    r.lightTransport = transport
    let label = transport == .rgb ? "RGB" : "spectral"
    try controller.restore(beer)
    r.lightTransport = transport   // restore applies the project's transport
    require(r.hasMedia && r.activeSamplingMode == 1, "a scene with media renders with Standard MIS")
    let w = 48, h = 36
    let pixels = render(view(SIMD3(0, 0, 4), SIMD3(0, 0, 0), width: w, height: h), samples: 128)
    let through = pixels.indices.filter { abs(lastPositions[$0].z - 0.7) < 1e-3 && lastPositions[$0].w > 0
      && abs(lastPositions[$0].x) < 0.3 && abs(lastPositions[$0].y) < 0.3 }
    let direct = pixels.indices.filter { abs(lastPositions[$0].z + 1) < 1e-3 && lastPositions[$0].w > 0
      && max(abs(lastPositions[$0].x), abs(lastPositions[$0].y)) > 0.8 }
    let ratio = mean(pixels, through) / mean(pixels, direct)
    print("\(label) Beer-Lambert: \(through.count) pixels through the block, ratio \(ratio) (expected 0.25)")
    require(through.count > 40 && direct.count > 100 && simd_reduce_max(abs(ratio - 0.25)) < 0.015,
      "\(label) radiance through an absorbing block follows Beer-Lambert (\(ratio))")
    for (name, document, eye) in [("sphere medium", furnace, SIMD3<Float>(0, 0, 3)), ("scene haze", haze, SIMD3<Float>(0.3, 0.2, 4))] {
      try controller.restore(document)
      r.lightTransport = transport
      require(r.activeLightTransport == transport, "\(label) transport is active")
      let image = render(view(eye, SIMD3(0, 0, 0), width: w, height: h), samples: 256)
      let all = Array(image.indices), centre = image.indices.filter { abs($0 % w - w / 2) < 6 && abs($0 / w - h / 2) < 6 }
      let background = mean(image, image.indices.filter { lastPositions[$0].w <= 0 && abs($0 % w - w / 2) > 18 })
      let ratio = mean(image, centre) / background, whole = mean(image, all) / background
      print("\(label) furnace, \(name): centre \(ratio), whole view \(whole)")
      require(simd_reduce_max(abs(ratio - 1)) < 0.03 && simd_reduce_max(abs(whole - 1)) < 0.02,
        "\(label) white furnace (\(name)): albedo-one media reproduce the uniform environment (\(ratio), \(whole))")
      savePreview([image], width: w, height: h, name: "volume-furnace-\(name.replacingOccurrences(of: " ", with: "-"))-\(label).png")
    }
  }
  print("PASS: volume renders: Beer-Lambert, albedo-one sphere medium and scene haze furnaces, in RGB and spectral transport")

  // Spot cone: a 0.3 m disk light 2 m above a floor with a 15-degree cone and softness 0.3: nothing outside the
  // cone, and the light-only and BSDF-only estimates agree inside it.
  let spot = try stage("spot", look("Floor", "color3f inputs:base_color = (0.5, 0.5, 0.5)") + """
      def Mesh "Ground" (prepend apiSchemas = ["MaterialBindingAPI"])
      {
          int[] faceVertexCounts = [4]
          int[] faceVertexIndices = [0, 3, 2, 1]
          point3f[] points = [(-3, 0, -3), (3, 0, -3), (3, 0, 3), (-3, 0, 3)]
          uniform token subdivisionScheme = "none"
          rel material:binding = </World/Floor>
      }
      def DiskLight "Spot" (prepend apiSchemas = ["ShapingAPI"])
      {
          float inputs:radius = 0.3
          float inputs:intensity = 50
          float inputs:shaping:cone:angle = 15
          float inputs:shaping:cone:softness = 0.3
          double3 xformOp:translate = (0, 2, 0)
          float3 xformOp:rotateXYZ = (-90, 0, 0)
          uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateXYZ"]
      }
      """)
  require(spot.scenes[6]?.emitterLights?.values.first?.coneAngle == 15, "ShapingAPI imports as the light's cone")
  try controller.restore(spot)
  r.lightTransport = .spectral
  var estimates: [SIMD3<Float>] = []
  for mode in [UInt32(2), 3] {
    let w = 48, h = 36
    let image = render(view(SIMD3(0, 3, 3), SIMD3(0, 0, 0), width: w, height: h, mode: mode), samples: 256)
    func radius(_ i: Int) -> Float { simd_length(SIMD2(lastPositions[i].x, lastPositions[i].z)) }
    let floor = image.indices.filter { lastPositions[$0].w > 0 && abs(lastPositions[$0].y) < 1e-3 }
    let outside = floor.filter { radius($0) > 2 * tan(Float.pi / 12) + 0.3 + 0.2 }, inside = floor.filter { radius($0) < 0.35 }
    let dark = outside.map { max(image[$0].x, image[$0].y, image[$0].z) }.max() ?? 1
    require(outside.count > 200 && inside.count > 10 && dark < 1e-6, "no light reaches the floor outside the cone (mode \(mode), max \(dark))")
    estimates.append(mean(image, inside))
  }
  let agreement = estimates[0] / estimates[1]
  print("Spot cone inside the cone: light-only \(estimates[0]), BSDF-only \(estimates[1])")
  require(simd_reduce_max(abs(agreement - 1)) < 0.1, "the shaped emission agrees between light and BSDF sampling (\(agreement))")
  print("PASS: spot cone cutoff and strategy agreement")
}
try fixVolumeChecks()
