// ReSTCV spatio-temporal control variates (REFERENCES.md RESTCV2026): layout, mode resolution and
// plumbing; the reflectance code and the coefficient alpha (Eq. 9); the reservoir-based difference
// estimate (Eq. 10) vanishing between identical domains; unchanged reservoirs; fallback equivalence
// where ReSTCV does not apply; mean radiance against MIS, including temporal control variates on
// every frame; and the interactive and equal-sample error gains on an imported mesh and Cornell.
@MainActor func fixReSTCVChecks() throws {
  let renderer = testRenderer
  let saved = (renderer.indirectReuse, renderer.spatialNeighbors, renderer.temporalReuse, renderer.controlVariates,
               renderer.ptTemporalWhileAccumulating)
  let savedSettings = renderer.materials.settings
  defer {
    (renderer.indirectReuse, renderer.spatialNeighbors, renderer.temporalReuse, renderer.controlVariates,
     renderer.ptTemporalWhileAccumulating) = saved
    renderer.materials.settings = savedSettings
  }

  // Modes: Automatic is ReSTCV wherever it applies (ReSTIR PT with paired spatial reuse).
  let environmentDefault: ControlVariates = ["off": .off, "restcv": .restcv][
    ProcessInfo.processInfo.environment["VIBE_CONTROL_VARIATES"] ?? ""] ?? .automatic
  require(PathTracerRenderer.defaultControlVariates == environmentDefault, "the default follows the VIBE_CONTROL_VARIATES test seam")
  for reuse in [IndirectReuse.restirPT, .restirPTUnified] {
    for spatial in [SpatialNeighborSelection.uniform, .compatibility] {
      require(ControlVariates.automatic.resolved(indirectReuse: reuse, spatialNeighbors: spatial) == .restcv
        && ControlVariates.restcv.resolved(indirectReuse: reuse, spatialNeighbors: spatial) == .restcv
        && ControlVariates.off.resolved(indirectReuse: reuse, spatialNeighbors: spatial) == .off,
        "\(reuse) with paired reuse: Automatic and ReSTCV resolve to ReSTCV, Resampled stays resampled")
    }
    require(ControlVariates.restcv.resolved(indirectReuse: reuse, spatialNeighbors: .stochasticPairwise) == .off,
      "stochastic pairwise MIS runs without ReSTCV")
  }
  require(ControlVariates.restcv.resolved(indirectReuse: .restirGI, spatialNeighbors: .uniform) == .off
    && ControlVariates.automatic.resolved(indirectReuse: .restirGI, spatialNeighbors: .compatibility) == .off,
    "ReSTIR GI runs without ReSTCV")
  require(PathTracerRenderer.ptControlStride == 16
    && PathTracerRenderer.FrameResourcePlan.ptReservoirBytesPerPixel == 2 * 64 + 3 * 16 + 16 + 128 + 2 + 16,
    "ReSTCV adds a 16-byte estimate per pixel to the ReSTIR PT resources")

  let kernels = """
    kernel void restcv_layout(device uint *out [[buffer(0)]]) { out[0] = sizeof(PTControl); }
    kernel void restcv_units(device float *out [[buffer(0)]]) {
        uint seed = 17u;
        float relative = 0.0f, absolute = 0.0f;
        for (uint i = 0; i < 65536u; ++i) {
            float3 rho = float3(rand_f(seed), rand_f(seed), rand_f(seed));
            rho = rand_f(seed) < 0.5f ? rho : rho * 0.02f;
            float3 back = pt_decode_reflectance(pt_encode_reflectance(rho));
            float3 error = abs(back - rho);
            absolute = max(absolute, max(error.x, max(error.y, error.z)));
            if (all(rho > 0.05f)) relative = max(relative, max(error.x / rho.x, max(error.y / rho.y, error.z / rho.z)));
        }
        out[0] = relative; out[1] = absolute;
        float3 a = pt_cv_alpha(float3(0.5f, 0.9f, 0.0f), float3(0.25f, 0.1f, 0.0f));
        float3 b = pt_cv_alpha(float3(0.3f, 0.0f, 0.2f), float3(0.6f, 0.4f, 0.0f));
        out[2] = a.x; out[3] = a.y; out[4] = a.z; out[5] = b.x; out[6] = b.y; out[7] = b.z;
    }
    // Eq. 10 between two copies of one domain: the canonical reservoir as both the current and the
    // temporal sample at the same primary hit. Identity shifts keep each integrand, so the difference
    // estimate is zero (the control variate cancels exactly); returns |difference| and |F W|.
    kernel void restcv_same_domain(texture2d<float, access::read> positions [[texture(0)]],
        constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],
        constant MaterialResources &images [[buffer(2)]], const device PrimarySurface *surfaces [[buffer(3)]],
        const device PTReservoir *reservoirs [[buffer(5)]], device float2 *out [[buffer(7)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.width || gid.y >= u.height) return;
        uint i = gid.y * u.width + gid.x;
        out[i] = float2(-1.0f);
        PTReservoir c = reservoirs[i];
        float4 p = positions.read(gid);
        if (pt_length(c) == 0u || !(p.w > 0.0f) || !(c.W > 0.0f) || !(pt_luminance(c.F) > 0.0f)) return;
        HitRecord x1 = load_primary_surface(surfaces[i], p);
        float3 view = float3(surfaces[i].view);
        PTReservoir t = c;
        t.M = 7.0f;
        float3 difference;
        PTReservoir merged = pt_temporal_merge(c, x1, view, p.w, t, x1, view, p.w, PT_CONFIDENCE_CAP, 5u, u, settings, images,
                                               difference);
        out[i] = float2(length(difference), length(float3(c.F) * c.W) + 0.0f * merged.W);
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  func run(_ name: String, width: Int, height: Int = 1, _ bind: (MTLComputeCommandEncoder) -> Void) throws {
    let state = try gpu.makeComputePipelineState(function: library.makeFunction(name: name)!)
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(state)
    bind(encoder)
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: height > 1 ? 8 : 1, height: height > 1 ? 8 : 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) completes: \(String(describing: command.error))")
  }
  let layout = gpu.makeBuffer(length: 4, options: .storageModeShared)!
  try run("restcv_layout", width: 1) { $0.setBuffer(layout, offset: 0, index: 0) }
  require(layout.contents().load(as: UInt32.self) == 16, "MSL PTControl is 16 bytes")
  let units = gpu.makeBuffer(length: 8 * 4, options: .storageModeShared)!
  try run("restcv_units", width: 1) { $0.setBuffer(units, offset: 0, index: 0) }
  let v = (0..<8).map { units.contents().load(fromByteOffset: $0 * 4, as: Float.self) }
  print("ReSTCV units: reflectance relative error \(v[0]) (rho > 0.05), absolute \(v[1]); alpha \(Array(v[2...]))")
  require(v[0] < 0.02 && v[1] < 0.002, "10-bit square-root reflectance codes keep rho within 2% (rho > 0.05) or 0.002")
  require(abs(v[2] - 2) < 1e-6 && abs(v[3] - 2) < 1e-6 && v[4] == 1 && abs(v[5] - 0.5) < 1e-6 && v[6] == 0 && v[7] == 2,
    "alpha = min(rho_i / rho_j, 2) per channel (Eq. 9), 1 for two black channels, 2 over a black one")
  print("PASS: fix-restcv modes, layout, reflectance codes and alpha")

  // Plumbing: Uniforms bit 5 is set exactly where ReSTCV applies, and the reservoirs it shades from
  // are the same with or without it (it changes the colour estimate only).
  let cornell = makeUniforms(scene: 1, mode: 0, width: 96, height: 72)
  func bit() -> Bool { lastRenderUniforms!.indirectReuse & 32 != 0 }
  func sharedCopy(_ buffer: MTLBuffer) -> [UInt8] {
    let shared = gpu.makeBuffer(length: buffer.length, options: .storageModeShared)!
    let command = renderer.commandQueue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
    blit.copy(from: buffer, sourceOffset: 0, to: shared, destinationOffset: 0, size: buffer.length)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    return Array(UnsafeRawBufferPointer(start: shared.contents(), count: buffer.length))
  }
  renderer.spatialNeighbors = .uniform
  renderer.temporalReuse = .reprojection
  renderer.ptTemporalWhileAccumulating = true
  var images = [ControlVariates: [SIMD4<Float>]](), reservoirs = [ControlVariates: [UInt8]]()
  for reuse in [IndirectReuse.restirPT, .restirPTUnified] {
    for mode in [ControlVariates.off, .restcv] {
      renderer.indirectReuse = reuse
      renderer.controlVariates = mode
      images[mode] = render(cornell, samples: 6)
      require(bit() == (mode == .restcv), "\(reuse) \(mode): Uniforms.indirectReuse bit 5 marks ReSTCV")
      reservoirs[mode] = sharedCopy(renderer.ptHistory!)
    }
    require(reservoirs[.off] == reservoirs[.restcv], "\(reuse): ReSTCV leaves the path reservoirs unchanged")
    require(images[.off] != images[.restcv], "\(reuse): ReSTCV changes the shaded estimate")
  }
  renderer.ptTemporalWhileAccumulating = false
  // Where it does not apply the renders are identical: ReSTIR GI and stochastic pairwise MIS.
  for (reuse, spatial) in [(IndirectReuse.restirGI, SpatialNeighborSelection.uniform), (.restirPTUnified, .stochasticPairwise)] {
    renderer.indirectReuse = reuse
    renderer.spatialNeighbors = spatial
    for mode in [ControlVariates.off, .restcv] {
      renderer.controlVariates = mode
      images[mode] = render(cornell, samples: 4)
      require(!bit(), "\(reuse), \(spatial): ReSTCV stays off")
    }
    require(images[.off] == images[.restcv], "\(reuse), \(spatial): the render is unchanged by the ReSTCV setting")
  }
  renderer.spatialNeighbors = .uniform
  print("PASS: fix-restcv plumbing, unchanged reservoirs and fallback equivalence")

  // Eq. 10 between identical domains: the temporal difference estimate cancels.
  renderer.indirectReuse = .restirPTUnified
  renderer.controlVariates = .restcv
  _ = render(cornell, samples: 1)
  let pixels = Int(cornell.width) * Int(cornell.height)
  let same = gpu.makeBuffer(length: pixels * 8, options: .storageModeShared)!
  try run("restcv_same_domain", width: Int(cornell.width), height: Int(cornell.height)) { encoder in
    var u = lastRenderUniforms!
    encoder.setTexture(renderer.historyPosDepth!, index: 0)
    encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    require(renderer.materials.bind(encoder), "material bindings for the difference check")
    encoder.setBuffer(renderer.primarySurfaces!, offset: 0, index: 3)
    encoder.setBuffer(renderer.ptReservoirs!, offset: 0, index: 5)
    encoder.setBuffer(same, offset: 0, index: 7)
  }
  let pairs = (0..<pixels).map { same.contents().load(fromByteOffset: $0 * 8, as: SIMD2<Float>.self) }.filter { $0.x >= 0 }
  let cancelled = pairs.filter { $0.x <= 1e-3 * $0.y }.count
  print("ReSTCV difference between identical domains: \(cancelled) of \(pairs.count) pixels cancel within 1e-3")
  require(pairs.count > pixels / 4 && Double(cancelled) >= 0.99 * Double(pairs.count),
    "the reservoir-based difference estimate (Eq. 10) is zero between identical domains")
  print("PASS: fix-restcv difference estimate between identical domains")

  // Mean radiance against MIS: the control variates keep ReSTIR PT unbiased, with spatial reuse only
  // (the static policy) and with temporal control variates on every frame.
  func agreement(_ view: Uniforms, label: String, modes: [IndirectReuse], temporal: Bool) {
    var mis = view; mis.samplingMode = 1
    let reference = render(mis, samples: 768)
    renderer.ptTemporalWhileAccumulating = temporal
    renderer.controlVariates = .restcv
    for reuse in modes {
      renderer.indirectReuse = reuse
      var pt = view; pt.samplingMode = 0
      let image = render(pt, samples: 384)
      let d = pairedDifference(image, reference, width: Int(view.width), pixels: Array(0..<image.count), block: 8)
      print("\(label) \(reuse) ReSTCV - MIS: \(d.mean / d.reference) ± \(d.se / d.reference) (relative)")
      require(abs(d.mean) < 4 * d.se + 0.004 * d.reference, "\(label): \(reuse) with ReSTCV agrees with MIS in mean radiance")
    }
    renderer.ptTemporalWhileAccumulating = false
  }
  agreement(makeUniforms(scene: 1, mode: 0, width: 128, height: 96), label: "Cornell", modes: [.restirPT, .restirPTUnified], temporal: false)
  agreement(makeUniforms(scene: 1, mode: 0, width: 128, height: 96), label: "Cornell, temporal on every frame",
            modes: [.restirPT, .restirPTUnified], temporal: true)
  agreement(makeUniforms(scene: 3, mode: 0, width: 128, height: 96), label: "Cornell glass & mirror, temporal on every frame",
            modes: [.restirPTUnified], temporal: true)
  print("PASS: fix-restcv mean radiance agrees with MIS")

  // Error gains on an imported UV sphere (scene 6) and Cornell.
  var obj = "v -3 -1 -3\nv 3 -1 -3\nv 3 -1 3\nv -3 -1 3\nf 1 4 3 2\n"
  let rings = 32, segments = 32
  for i in 0...rings { for j in 0..<segments {
    let theta = Float.pi * Float(i) / Float(rings), phi = 2 * Float.pi * Float(j) / Float(segments)
    obj += "v \(0.6 * sin(theta) * cos(phi)) \(-0.4 + 0.6 * cos(theta)) \(0.6 * sin(theta) * sin(phi))\n"
  }}
  for i in 0..<rings { for j in 0..<segments {
    let a = 5 + i * segments + j, b = 5 + i * segments + (j + 1) % segments
    obj += "f \(a) \(b) \(b + segments) \(a + segments)\n"
  }}
  renderer.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  try renderer.materials.setMesh(try OBJMesh.load(obj))
  renderer.materials.hasSceneGraph = false
  defer { try? renderer.materials.setMesh([]) }
  var mesh = makeUniforms(scene: 6, mode: 1, width: 160, height: 120)
  mesh.environment.w = Float(renderer.materials.nodeCount)
  renderer.indirectReuse = .restirPTUnified
  // Squared error in linear RGB, and after the display curve (tests/GPUChecks.swift displayPixels).
  func squaredError(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
    zip(a, b).reduce(0.0) { sum, pair in let d = pair.0 - pair.1; return sum + Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3 }
      / Double(a.count)
  }
  func displayed(_ pixels: [SIMD4<Float>]) -> [SIMD4<Float>] {
    pixels.map { pixel in
      var result = SIMD4<Float>(0, 0, 0, 1)
      for c in 0..<3 {
        let v = max(0, pixel[c])
        let x = max(0, min(1, (v * (v + 0.0245786) - 0.000090537) / (v * (0.983729 * v + 0.4329510) + 0.238081)))
        result[c] = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / Float(2.4)) - 0.055
      }
      return result
    }
  }
  // Accumulates frames through renderFrame from the renderer's current sample index.
  func accumulate(_ view: Uniforms, frames: Int) -> [SIMD4<Float>] {
    let w = Int(view.width), h = Int(view.height)
    let output = renderOutputs[SIMD2(w, h)] ?? {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
      return gpu.makeTexture(descriptor: d)!
    }()
    renderOutputs[SIMD2(w, h)] = output
    let savedUpdate = renderer.onFrameUpdate
    var completed = 0
    renderer.onFrameUpdate = { _ in completed += 1 }
    renderer.denoiserEnabled = false
    for frame in 1...frames {
      renderer.renderFrame(output: output)
      let deadline = Date().addingTimeInterval(60)
      while completed < frame && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
      require(completed >= frame, "ReSTCV accumulation completes frame \(frame)")
    }
    renderer.onFrameUpdate = savedUpdate
    return readTexture(renderer.accumTexture!)
  }
  // Display-referred tone-mapped error: the display clamps negative values to black.
  func toneMapped(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
    zip(a, b).reduce(0.0) { sum, pair in
      let p = simd_max(pair.0, .zero), q = simd_max(pair.1, .zero)
      let x = p / (p + 1), y = q / (q + 1), d = x - y
      return sum + Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3 } / Double(a.count)
  }
  // Interactive preview: after 12 orbiting frames (accumulation reset every frame, history kept),
  // the raw frame and the MetalFX output against MIS at that view.
  for (view, label, rawBound) in [(mesh, "Imported mesh", 0.8), (makeUniforms(scene: 1, mode: 0, width: 160, height: 120), "Cornell", 0.9)] {
    var start = view; start.samplingMode = 0
    var raw = [ControlVariates: Double](), display = [ControlVariates: Double]()
    var reference = [SIMD4<Float>]()
    for mode in [ControlVariates.off, .restcv] {
      renderer.controlVariates = mode
      let frame = render(start, samples: 12, denoise: true, orbit: true)
      let shown = lastDisplay
      if reference.isEmpty {
        var still = lastRenderUniforms!; still.samplingMode = 1
        reference = render(still, samples: 768)
      }
      raw[mode] = toneMapped(frame, reference)
      display[mode] = renderer.supportsMetalFX ? squaredError(displayed(shown), displayed(reference)) : 0
    }
    print("\(label) orbiting frame, resampled / ReSTCV: raw \(raw[.off]!) / \(raw[.restcv]!), MetalFX \(display[.off]!) / \(display[.restcv]!)")
    require(raw[.restcv]! < rawBound * raw[.off]!, "\(label): ReSTCV lowers the per-frame error while the camera moves")
    require(display[.restcv]! <= 1.02 * display[.off]!, "\(label): ReSTCV does not raise the MetalFX display error")
  }
  // Static accumulation: equal-sample MSE of 32 frames from independent seed sequences.
  let meshReference = render(mesh, samples: 1024)
  mesh.samplingMode = 0
  var ratios = [Double]()
  for trial in 0..<4 {
    var errors = [Double]()
    for mode in [ControlVariates.off, .restcv] {
      renderer.controlVariates = mode
      applyTestView(mesh); renderer.resetAccumulation(); renderer.restartSampleSequence(at: UInt32(trial) * 5000 + 70_000)
      errors.append(squaredError(accumulate(mesh, frames: 32), meshReference))
    }
    ratios.append(errors[1] / errors[0])
  }
  let meanRatio = ratios.reduce(0, +) / Double(ratios.count)
  print("Imported mesh 32-frame MSE ratio (ReSTCV / resampled): \(ratios) mean \(meanRatio)")
  require(ratios.allSatisfy { $0 < 1 } && meanRatio < 0.95, "ReSTCV lowers the equal-sample MSE of a still view of the imported mesh")
  print("PASS: fix-restcv interactive and equal-sample error gains")
}
try fixReSTCVChecks()
