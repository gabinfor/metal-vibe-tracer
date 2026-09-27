// Light sampling regressions: HDRI importance sampling and PDFs, sun cones, sphere
// cones, imported emitter PDFs/power sampling, and imported UsdLux distant lights.
@MainActor func fixLightsChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("lights", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let kernels = """
  kernel void fix_lights_environment(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]], device atomic_uint *hist [[buffer(4)]], uint tid [[thread_position_in_grid]]) {
      uint seed = pcg_hash(tid * 7919u + 13u);
      uint width = images.environmentMap.get_width(), height = images.environmentMap.get_height();
      float3 p = float3(0), n = float3(0, 1, 0);
      float mismatches = 0, normalization = 0, invalid = 0;
      for (uint i = 0; i < 256; ++i) {
          LightSample ls = sample_direct_light(p, n, u, seed, images);
          if (!(ls.pdf > 0.0f) || ls.isDirectional != 1) { invalid += 1; continue; }
          float theta = acos(clamp(ls.wi.y, -1.0f, 1.0f));
          float2 uv = float2(fract(atan2(ls.wi.z, ls.wi.x) / TWO_PI + 0.5f + u.environment.y / TWO_PI), theta / PI);
          uint x = min(width - 1, uint(uv.x * float(width))), y = min(height - 1, uint(uv.y * float(height)));
          atomic_fetch_add_explicit(&hist[y * width + x], 1u, memory_order_relaxed);
          if (abs(eval_environment_pdf(ls.wi, n, u, images) - ls.pdf) > 1e-3f * ls.pdf) mismatches += 1;
          float2 r = rand_f2(seed);
          float z = 1.0f - 2.0f * r.x, s = sqrt(max(0.0f, 1.0f - z * z));
          normalization += eval_environment_pdf(float3(s * cos(TWO_PI * r.y), z, s * sin(TWO_PI * r.y)), n, u, images) * 4.0f * PI;
      }
      out[tid] = float4(mismatches, normalization / 256.0f, invalid, 0);
  }
  kernel void fix_lights_sun(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]], device atomic_uint *hist [[buffer(4)]], uint tid [[thread_position_in_grid]]) {
      uint seed = pcg_hash(tid + 101u);
      float3 sunDir = normalize(u.sunParams.xyz), su, sv;
      make_basis(sunDir, su, sv);
      float disagreements = 0, discs = 0, cosineOnly = 0;
      for (uint i = 0; i < 256; ++i) {
          // Directions up to twice the widest preset disc around the sun.
          float2 r = rand_f2(seed);
          float oneMinusCos = r.x * 2e-3f, sinTheta = sqrt(oneMinusCos * (2.0f - oneMinusCos));
          float3 d = normalize(su * (cos(TWO_PI * r.y) * sinTheta) + sv * (sin(TWO_PI * r.y) * sinTheta) + sunDir * (1.0f - oneMinusCos));
          bool disc = any(eval_procedural_sky(d, u.sunParams, u.skyMode) != eval_procedural_sky(d, float4(u.sunParams.xyz, 0), u.skyMode));
          bool proposed = eval_environment_pdf(d, -sunDir, u, images) > 0.0f;
          discs += disc ? 1 : 0;
          disagreements += disc != proposed ? 1 : 0;
          LightSample ls = sample_direct_light(float3(0), float3(0, 1, 0), u, seed, images);
          cosineOnly += abs(ls.pdf - max(0.0f, ls.wi.y) / PI) <= 1e-4f * max(ls.pdf, 1e-6f) ? 1 : 0;
      }
      out[tid] = float4(disagreements, discs, cosineOnly, environment_sun_probability(u));
  }
  kernel void fix_lights_sphere(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]], device atomic_uint *hist [[buffer(4)]], uint tid [[thread_position_in_grid]]) {
      float3 p = float3(0, -0.9f, 0), c = float3(2.4f, 1.8f, 1.2f);
      float r = 0.016f * u.light.w;
      Material m = { EMISSIVE, float3(0), float3(1), 0, 1 };
      uint seed = 29;
      float misses = 0, smallest = 0, radial = 0;
      for (uint i = 0; i < 8192; ++i) {
          LightSample ls = sample_direct_light(p, float3(0, 1, 0), u, seed, images);
          if (!(ls.pdf > 0.0f)) { misses += 1; continue; }
          if (length(ls.position - c) < 2.0f * r) { smallest += 1; radial = max(radial, abs(length(ls.position - c) - r) / r); }
      }
      out[0] = float4(eval_light_pdf(p, c + r * normalize(p - c), m, u), misses, smallest, radial);
  }
  kernel void fix_lights_emitters(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]], device atomic_uint *hist [[buffer(4)]], uint tid [[thread_position_in_grid]]) {
      uint seed = pcg_hash(tid * 131u + 5u);
      float3 p = float3(1000.0f, 1000.0f, 1000.0f), n = float3(0, 1, 0);
      float hits = 0, zero = 0, error = 0;
      for (uint i = 0; i < 256; ++i) {
          LightSample ls = sample_direct_light(p, n, u, seed, images);
          if (ls.isDirectional < 2) continue;
          atomic_fetch_add_explicit(&hist[ls.isDirectional - 2], 1u, memory_order_relaxed);
          Ray ray = { p, ls.wi }; // A free point: no surface offset, so the hit is the sampled point.
          HitRecord rec;
          if (!trace_scene(ray, 6, rec, images, u) || rec.mat.type != EMISSIVE) continue;
          hits += 1;
          float pdf = eval_light_pdf(p, rec.position, rec.mat, u, images, rec.triangle);
          if (!(pdf > 0.0f)) zero += 1; else error = max(error, abs(pdf - ls.pdf) / ls.pdf);
      }
      out[tid] = float4(hits, zero, error, 0);
  }
  """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  func dispatch(_ name: String, _ input: Uniforms, threads: Int, bins: Int = 1) throws -> ([SIMD4<Float>], [UInt32]) {
    var u = input
    guard let function = library.makeFunction(name: name),
      let out = gpu.makeBuffer(length: threads * 16, options: .storageModeShared),
      let hist = gpu.makeBuffer(length: bins * 4, options: .storageModeShared),
      let command = testRenderer.commandQueue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw MaterialLibrary.error("light check setup") }
    memset(hist.contents(), 0, bins * 4)
    encoder.setComputePipelineState(try gpu.makeComputePipelineState(function: function))
    testRenderer.materials.bind(encoder)
    encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setBuffer(out, offset: 0, index: 3)
    encoder.setBuffer(hist, offset: 0, index: 4)
    encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(threads, 64), height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) GPU command: \(String(describing: command.error))")
    return ((0..<threads).map { out.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) },
      (0..<bins).map { hist.contents().load(fromByteOffset: $0 * 4, as: UInt32.self) })
  }
  func view(_ input: Uniforms, eye: SIMD3<Float>, target: SIMD3<Float>) -> Uniforms {
    var u = input
    u.cameraPos = SIMD4(eye, 45); u.cameraTarget = SIMD4(target, 16)
    u.currentViewProj = makePerspective(fovyRadians: 45 * .pi / 180, aspect: Float(u.width) / Float(u.height), near: 0.05, far: 100)
      * makeLookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
    u.prevViewProj = u.currentViewProj
    return u
  }
  // Mean radiance / albedo over upward-facing primary hits of the last render.
  func floorRatio(_ pixels: [SIMD4<Float>]) -> Float {
    let floor = pixels.indices.filter { lastPositions[$0].w > 0 && lastNormals[$0].y > 0.99 && lastMaterials[$0].x > 0.01 }
    require(floor.count > 200, "light checks see the floor")
    return floor.reduce(Float(0)) { $0 + pixels[$1].x / lastMaterials[$1].x } / Float(floor.count)
  }
  func exr(_ name: String, width: Int, height: Int, _ radiance: (Int, Int) -> SIMD4<Float>) throws -> Data {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
    guard let texture = gpu.makeTexture(descriptor: descriptor) else { throw MaterialLibrary.error("light check texture") }
    var pixels = (0..<(width * height)).map { radiance($0 % width, $0 / width) }
    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: width * 16)
    let url = folder.appendingPathComponent(name)
    try RenderImage.write(texture: texture, url: url, hdr: true)
    return try Data(contentsOf: url)
  }

  // R-10 / R-53: procedural sun disc, cone proposal and horizon culling agree.
  for sky in UInt32(0)...2 {
    var u = makeUniforms(scene: 0, mode: 1, width: 1, height: 1)
    u.skyMode = sky
    let above = try dispatch("fix_lights_sun", u, threads: 64).0
    require(above.reduce(0) { $0 + $1.x } == 0 && above.reduce(0) { $0 + $1.y } > 1000,
      "sky \(sky): emitted sun disc matches the sampled sun cone")
    u.sunParams = SIMD4(0.65, -0.3, -0.6, 850)
    let below = try dispatch("fix_lights_sun", u, threads: 64).0
    require(below[0].w == 0 && below.reduce(0) { $0 + $1.z } == 64 * 256,
      "sky \(sky): no sun proposals when the disc is below the horizon")
  }
  print("PASS: procedural sun disc, cone PDF and below-horizon proposals agree")

  // R-52: sphere cone solid angle for small light sizes, and no clamped misses.
  for size: Float in [0.25, 0.05] {
    var u = makeUniforms(scene: 2, mode: 1, width: 1, height: 1)
    u.light.w = size
    let result = try dispatch("fix_lights_sphere", u, threads: 1).0[0]
    let r = 0.016 * Double(size), d = SIMD3<Double>(2.4, 2.7, 1.2), x = r * r / simd_length_squared(d)
    let exact = 0.25 / (2 * Double.pi * x / (1 + (1 - x).squareRoot()))
    print("Sphere light size \(size): PDF \(result.x), exact \(exact), misses \(result.y), smallest \(result.z), radial \(result.w)")
    require(abs(Double(result.x) - exact) < 1e-3 * exact, "small sphere-light cone PDF, size \(size)")
    require(result.y == 0 && result.z > 1000 && result.w < 1e-3, "sphere cone samples land on the sphere, size \(size)")
  }
  print("PASS: sphere-light cone PDFs are stable for small light sizes")

  // R-12 / R-98: exact O(1) emitter PDF 1 km from the origin and power-weighted selection.
  func downTriangle(_ x: Float, _ z: Float, _ s: Float, slot: Float) -> MeshTriangle {
    MeshTriangle(a: SIMD4(x, 1002, z, 1), b: SIMD4(x + s, 1002, z, 1), c: SIMD4(x, 1002, z + s, 1),
      na: SIMD4(0, -1, 0, 0), nb: SIMD4(0, -1, 0, 0), nc: SIMD4(0, -1, 0, 0),
      uvab: SIMD4(0, 0, 1, 0), uvc: SIMD4(0, 1, slot, 1))
  }
  let emitterTriangles = [downTriangle(999, 999, 1, slot: 8), downTriangle(1000.5, 999, 2, slot: 8), downTriangle(999, 1001, 1, slot: 9)]
  testRenderer.materials.emissions = [8: SIMD3(2, 2, 2), 9: SIMD3(8, 8, 8)]
  try testRenderer.materials.setMesh(emitterTriangles)
  var emitterView = makeUniforms(scene: 6, mode: 1, width: 1, height: 1)
  emitterView.environment = SIMD4(0, 0, 0, Float(testRenderer.materials.nodeCount))
  emitterView.sunParams.w = 0
  emitterView.lens.z = 1
  let (emitterResults, selections) = try dispatch("fix_lights_emitters", emitterView, threads: 1024, bins: 3)
  let hits = emitterResults.reduce(0) { $0 + $1.x }, zero = emitterResults.reduce(0) { $0 + $1.y }
  let pdfError = emitterResults.map { $0.z }.max() ?? 1
  print("Far emitters: hits \(hits), zero PDFs \(zero), max relative PDF error \(pdfError), selections \(selections)")
  require(hits > 100_000 && zero == 0 && pdfError < 1e-3, "imported emitter BSDF-hit PDF is exact far from the origin")
  // BVH order may permute triangles; map each selection back through its area.
  let total = Double(selections.reduce(0) { $0 + $1 })
  var observed: [Float: Double] = [:]
  let ordered = testRenderer.materials.orderedTriangles
  for (i, count) in selections.enumerated() {
    let t = ordered[i]
    let area = 0.5 * Double(simd_length(simd_cross(SIMD3(t.b.x - t.a.x, t.b.y - t.a.y, t.b.z - t.a.z), SIMD3(t.c.x - t.a.x, t.c.y - t.a.y, t.c.z - t.a.z))))
    observed[Float(area) * (t.uvc.z == 9 ? 10 : 1), default: 0] += Double(count) / total
  }
  // Power weights: 0.5 x 2, 2 x 2 and 0.5 x 8 -> 1/9, 4/9, 4/9.
  require(abs((observed[0.5] ?? 0) - 1.0 / 9) < 0.01 && abs((observed[2] ?? 0) - 4.0 / 9) < 0.01
    && abs((observed[5] ?? 0) - 4.0 / 9) < 0.01, "imported emitters are chosen by area x luminance")
  testRenderer.materials.emissions = [:]
  print("PASS: imported emitter PDFs are O(1) and exact at 1 km; emitters are power sampled")

  // R-01 / R-11 / R-48: HDRI importance sampling on a non-uniform 64 x 32 map.
  let width = 64, height = 32
  let hdri = try exr("importance.exr", width: width, height: height) { x, y in
    let v = 0.25 + 1.5 * Float(height - y) / Float(height) * (1 + 0.5 * sin(2 * .pi * Float(x) / Float(width)))
    let spot: Float = abs(x - 40) <= 1 && abs(y - 9) <= 1 ? 12 : 0
    return SIMD4(v + spot, 0.8 * v + spot, 0.6 * v + spot, 1)
  }
  let white = try exr("white.exr", width: width, height: height) { _, _ in SIMD4(1, 1, 1, 1) }
  var environmentDocument = ProjectDocument()
  environmentDocument.scene = 6
  environmentDocument.environmentData = hdri
  environmentDocument.environmentName = "importance.exr"
  try controller.restore(environmentDocument)
  let stored = readTexture(testRenderer.materials.environmentTexture)
  require(stored.count == width * height, "HDRI fixture dimensions")
  var weights = [Double]()
  for y in 0..<height { for x in 0..<width {
    let p = stored[y * width + x]
    let luminance = max(1e-6, 0.2126 * Double(p.x) + 0.7152 * Double(p.y) + 0.0722 * Double(p.z))
    weights.append(luminance * max(1e-4, sin(Double.pi * (Double(y) + 0.5) / Double(height))))
  }}
  let weightSum = weights.reduce(0, +)
  var environmentView = makeUniforms(scene: 6, mode: 1, width: 1, height: 1)
  environmentView.environment = SIMD4(1, 0, 1, 0)
  environmentView.sunParams.w = 0
  let (environmentResults, histogram) = try dispatch("fix_lights_environment", environmentView, threads: 4096, bins: width * height)
  let samples = Double(histogram.reduce(0) { $0 + UInt64($1) })
  var chiSquare = 0.0, rowError = 0.0
  for i in 0..<(width * height) {
    let expected = samples * weights[i] / weightSum
    chiSquare += pow(Double(histogram[i]) - expected, 2) / expected
  }
  for y in 0..<height {
    let expected = (0..<width).reduce(0.0) { $0 + samples * weights[y * width + $1] / weightSum }
    let observedRow = Double((0..<width).reduce(0) { $0 + histogram[y * width + $1] })
    rowError = max(rowError, abs(observedRow - expected) / (5 * expected.squareRoot() + 0.02 * expected))
  }
  let dof = Double(width * height - 1)
  let mismatches = Double(environmentResults.reduce(0) { $0 + $1.x })
  let normalization = Double(environmentResults.reduce(0) { $0 + $1.y }) / Double(environmentResults.count)
  let invalid = environmentResults.reduce(0) { $0 + $1.z }
  print("HDRI importance: samples \(samples), chi-square \(chiSquare) / \(dof) dof, row score \(rowError), PDF mismatches \(mismatches), normalization \(normalization), invalid \(invalid)")
  require(samples == 4096 * 256 && invalid == 0, "every HDRI proposal has a positive PDF")
  require(chiSquare < dof + 6 * (2 * dof).squareRoot() && rowError < 1, "HDRI samples follow luminance x sin(theta) cells")
  require(mismatches < 1e-3 * samples, "HDRI sampled and evaluated PDFs agree")
  require(abs(normalization - 1) < 0.02, "HDRI mixture PDF integrates to one")

  // HDRI furnace: Light, BSDF, MIS and ReSTIR agree; a white map returns the albedo.
  testRenderer.materials.settings[1].enabled = 0
  var furnace = view(makeUniforms(scene: 6, mode: 3, width: 64, height: 48), eye: SIMD3(0, 0.6, -2.2), target: SIMD3(0, -1, 0.4))
  furnace.environment = SIMD4(1, 0, 1, 0)
  furnace.sunParams.w = 0
  for (name, map) in [("non-uniform", hdri), ("white", white)] {
    try testRenderer.materials.setEnvironment(map)
    var ratios = [Float]()
    for mode in [UInt32(3), 2, 1, 0] {
      furnace.samplingMode = mode
      ratios.append(floorRatio(render(furnace, samples: 64)))
    }
    print("HDRI furnace \(name) (BSDF, Light, MIS, ReSTIR): \(ratios)")
    for (i, ratio) in ratios.enumerated().dropFirst() {
      require(abs(ratio - ratios[0]) < (i == 3 ? 0.05 : 0.03) * ratios[0], "HDRI \(name) furnace strategy \(i) matches BSDF sampling")
    }
    if name == "white" { require(ratios.allSatisfy { abs($0 - 1) < 0.03 }, "white HDRI furnace returns the albedo") }
  }
  print("PASS: HDRI row/column sampling (chi-square), sampled/evaluated PDFs, normalization and four-strategy furnace")

  // R-07 / R-119: imported distant lights light the scene independently of the
  // environment, for rotated/oblique suns on Y-up and Z-up stages.
  func stage(_ name: String, upAxis: String, metersPerUnit: Double, floor: String, light: String) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try """
    #usda 1.0
    (
        defaultPrim = "World"
        metersPerUnit = \(metersPerUnit)
        upAxis = "\(upAxis)"
    )
    def Xform "World"
    {
        def Mesh "Floor"
        {
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 1, 2, 3]
            point3f[] points = [\(floor)]
            uniform token subdivisionScheme = "none"
        }
        def DistantLight "Sun"
        {
    \(light)
        }
    }
    """.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
  let yFloor = "(-2, 0, -2), (-2, 0, 2), (2, 0, 2), (2, 0, -2)"
  let zFloor = "(-200, -200, 0), (200, -200, 0), (200, 200, 0), (-200, 200, 0)"
  let defaultIrradiance = 50000 * Double.pi * pow(sin(0.53 * Double.pi / 360), 2)
  let cases: [(URL, azimuth: Float, elevation: Float, irradiance: Double, angle: Float)] = [
    (try stage("sun-y-oblique.usda", upAxis: "Y", metersPerUnit: 1, floor: yFloor, light: """
            float3 xformOp:rotateXYZ = (-60, 30, 0)
            uniform token[] xformOpOrder = ["xformOp:rotateXYZ"]
    """), 30, 60, defaultIrradiance, 0.53),
    (try stage("sun-y-low-normalized.usda", upAxis: "Y", metersPerUnit: 1, floor: yFloor, light: """
            float inputs:angle = 0
            float inputs:intensity = 3
            bool inputs:normalize = 1
            float xformOp:rotateX = -20
            uniform token[] xformOpOrder = ["xformOp:rotateX"]
    """), 0, 20, 3, 0.1),
    (try stage("sun-z-rotated.usda", upAxis: "Z", metersPerUnit: 0.01, floor: zFloor, light: """
            float inputs:exposure = 1
            float inputs:intensity = 25000
            float3 xformOp:rotateXYZ = (30, 0, 45)
            uniform token[] xformOpOrder = ["xformOp:rotateXYZ"]
    """), 45, 60, defaultIrradiance, 0.53),
  ]
  for (url, azimuth, elevation, irradiance, angle) in cases {
    let imported = try USDImporter.load(url, into: ProjectDocument())
    let o = imported.document.options
    print("\(url.lastPathComponent): azimuth \(o.sunAzimuth), elevation \(o.sunElevation), irradiance \(o.sunIntensity), angle \(String(describing: o.sunAngle))")
    require(abs(o.sunAzimuth - azimuth) < 0.05 && abs(o.sunElevation - elevation) < 0.05, "\(url.lastPathComponent): sun direction mapping")
    require(abs(Double(o.sunIntensity) - irradiance) < 1e-3 * irradiance && abs((o.sunAngle ?? 0) - angle) < 1e-4,
      "\(url.lastPathComponent): UsdLux intensity and angle conversion")
    require(o.environmentIntensity == 0, "\(url.lastPathComponent): sun-only stage has no environment")
    if angle != 0.53 { require(imported.report.contains { $0.contains("rendered as") }, "clamped distant-light angle is reported") }
    try imported.document.validate()
    try controller.restore(imported.document)
    for slot in 8..<SceneLimits.materials { testRenderer.materials.settings[slot].enabled = 0 }
    var sun = view(makeUniforms(scene: 6, mode: 1, width: 48, height: 36), eye: SIMD3(0, 3, -3.5), target: SIMD3(0, 0, 0))
    let az = o.sunAzimuth * .pi / 180, el = o.sunElevation * .pi / 180
    sun.sunParams = SIMD4(sin(az) * cos(el), sin(el), cos(az) * cos(el), o.sunIntensity)
    sun.environment = SIMD4(o.environmentIntensity, 0, 0, Float(testRenderer.materials.nodeCount))
    sun.lens = SIMD4(0, 4, 1, o.independentSunCone)
    let expected = Float(irradiance) * sin(el) / .pi
    for mode in UInt32(0)...2 {
      sun.samplingMode = mode
      let ratio = floorRatio(render(sun, samples: 16))
      print("\(url.lastPathComponent) strategy \(mode): floor radiance / albedo \(ratio), expected \(expected)")
      require(abs(ratio - expected) < 0.02 * expected, "\(url.lastPathComponent): imported sun lights the floor, strategy \(mode)")
    }
    if url.lastPathComponent == "sun-y-oblique.usda" {
      // A textured dome and the sun add; neither replaces the other.
      try testRenderer.materials.setEnvironment(white)
      sun.environment = SIMD4(1, 0, 1, Float(testRenderer.materials.nodeCount))
      for mode in UInt32(1)...2 {
        sun.samplingMode = mode
        let ratio = floorRatio(render(sun, samples: 64))
        print("HDRI + imported sun strategy \(mode): \(ratio), expected \(1 + expected)")
        require(abs(ratio - (1 + expected)) < 0.03 * (1 + expected), "HDRI and imported sun both contribute, strategy \(mode)")
      }
    }
  }
  print("PASS: imported oblique/rotated distant lights on Y-up and Z-up stages light the scene with and without an HDRI")
  controller.saveTimer?.invalidate()
}
try fixLightsChecks()
