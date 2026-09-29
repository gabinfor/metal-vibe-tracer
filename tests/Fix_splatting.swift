// Multi-layer reservoir splatting (REFERENCES.md HONG2026, LIU2025): mode plumbing and layouts; forward
// projection against the camera math; deep-layer depth ordering, depth ranges and pool bookkeeping;
// memory; fallback equivalence to reprojection; mean radiance against MIS on alternating views; and
// the disocclusion error gain of unified ReSTIR PT.
@MainActor func fixSplattingChecks() throws {
  let renderer = testRenderer
  let saved = (renderer.indirectReuse, renderer.temporalReuse)
  func readBuffer(_ buffer: MTLBuffer) -> MTLBuffer {
    let shared = gpu.makeBuffer(length: buffer.length, options: .storageModeShared)!
    let command = renderer.commandQueue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
    blit.copy(from: buffer, sourceOffset: 0, to: shared, destinationOffset: 0, size: buffer.length)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    return shared
  }
  func poolCount(_ pool: PathTracerRenderer.SplatPool) -> Int {
    Int(min(pool.counters.contents().load(as: UInt32.self), UInt32(pool.capacity)))
  }

  // Plumbing: the mode rides in Uniforms.indirectReuse bit 4 (the 304-byte stride is unchanged).
  require(MemoryLayout<Uniforms>.stride == 304, "the reservoir-splatting flag needs no new uniform")
  require(TemporalReuse.reprojection.rawValue == 0 && TemporalReuse.splatting.rawValue == 1 && TemporalReuse.automatic.rawValue == 2,
    "TemporalReuse raw values")
  let environmentDefault: TemporalReuse = ["reprojection": .reprojection, "splatting": .splatting][
    ProcessInfo.processInfo.environment["VIBE_TEMPORAL_REUSE"] ?? ""] ?? .automatic
  require(PathTracerRenderer.defaultTemporalReuse == environmentDefault, "the default temporal reuse follows the VIBE_TEMPORAL_REUSE test seam")
  require(TemporalReuse.automatic.resolved(indirectReuse: .restirGI) == .reprojection
      && TemporalReuse.automatic.resolved(indirectReuse: .restirPT) == .reprojection
      && TemporalReuse.automatic.resolved(indirectReuse: .restirPTUnified) == .reprojection
      && TemporalReuse.splatting.resolved(indirectReuse: .restirGI) == .splatting
      && TemporalReuse.reprojection.resolved(indirectReuse: .restirPTUnified) == .reprojection,
    "automatic temporal reuse resolves to reprojection (tests/PERFORMANCE.md); explicit modes are kept")
  let layoutKernel = """
    kernel void splat_layout(device uint *out [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        out[0] = sizeof(SplatDomain); out[1] = sizeof(SplatLayers); out[2] = sizeof(SplatDI); out[3] = sizeof(SplatGI);
        out[4] = splat_frame(u) ? 1u : 0u; out[5] = indirect_reuse_mode(u); out[6] = SPLAT_DEEP_LAYERS;
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + layoutKernel + splatCheckKernels, options: shaderCompileOptions())
  func pipeline(_ name: String) throws -> MTLComputePipelineState {
    try gpu.makeComputePipelineState(function: library.makeFunction(name: name)!)
  }
  func dispatch(_ pipeline: MTLComputePipelineState, threads: Int, _ bind: (MTLComputeCommandEncoder) -> Void) {
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    bind(encoder)
    encoder.dispatchThreads(MTLSize(width: max(1, threads), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "splat check dispatch: \(String(describing: command.error))")
  }
  let layout = gpu.makeBuffer(length: 64, options: .storageModeShared)!
  var flagged = makeUniforms(scene: 1, mode: 0, width: 1, height: 1)
  flagged.indirectReuse = IndirectReuse.restirPTUnified.rawValue | 16
  dispatch(try pipeline("splat_layout"), threads: 1) {
    $0.setBuffer(layout, offset: 0, index: 0); $0.setBytes(&flagged, length: MemoryLayout<Uniforms>.stride, index: 1)
  }
  let words = layout.contents().bindMemory(to: UInt32.self, capacity: 16)
  require(words[0] == 32 && words[1] == 48 && words[2] == 48 && words[3] == 64 && words[4] == 1 && words[5] == 2 && words[6] == 1,
    "SplatDomain 32 B, SplatLayers 48 B, SplatDI 48 B, SplatGI 64 B; bit 4 marks a splat frame beside the reuse mode; one deep layer")

  // Splat frames: only while the view changes, with valid history, a pinhole camera and the splatting mode.
  let small = makeUniforms(scene: 0, mode: 0, width: 64, height: 48)
  renderer.indirectReuse = .restirPTUnified
  renderer.temporalReuse = .splatting
  _ = render(small, samples: 4)
  let staticSplat = renderer.lastFrameSplatted
  _ = render(small, samples: 4, orbit: true)
  let movingSplat = renderer.lastFrameSplatted
  var thinLens = small; thinLens.lens.x = 0.05; thinLens.lens.y = 4
  _ = render(thinLens, samples: 4, orbit: true)
  let lensSplat = renderer.lastFrameSplatted
  renderer.temporalReuse = .reprojection
  _ = render(small, samples: 4, orbit: true)
  require(!staticSplat && movingSplat && !lensSplat && !renderer.lastFrameSplatted && renderer.splatCurrent == nil,
    "splatting runs on moving pinhole frames only, and reprojection allocates no splat resources")
  print("PASS: fix-splatting plumbing, layouts and splat-frame policy")

  // Forward projection matches the camera math: every pixel's traced (jittered) primary hit splats into
  // that pixel, and splat_project agrees with the host's view-projection matrix for random points.
  renderer.temporalReuse = .splatting
  let pw = 128, ph = 96
  _ = render(makeUniforms(scene: 0, mode: 0, width: pw, height: ph), samples: 6, orbit: true)
  var frame = lastRenderUniforms!
  let projection = gpu.makeBuffer(length: 4 * 4, options: .storageModeShared)!
  memset(projection.contents(), 0, 16)
  dispatch(try pipeline("splat_self_projection"), threads: pw * ph) {
    $0.setTexture(renderer.historyPosDepth!, index: 0)
    $0.setBytes(&frame, length: MemoryLayout<Uniforms>.stride, index: 0)
    $0.setBuffer(projection, offset: 0, index: 1)
  }
  let hits = projection.contents().load(fromByteOffset: 0, as: UInt32.self)
  let same = projection.contents().load(fromByteOffset: 4, as: UInt32.self)
  print("Self projection: \(same) of \(hits) primary hits splat into their own pixel")
  require(hits > UInt32(pw * ph / 2) && Double(same) >= 0.999 * Double(hits), "primary hits splat into the pixel whose ray found them")
  var points = [SIMD4<Float>]()
  var state: UInt64 = 0x9e3779b97f4a7c15
  func random() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float(state >> 40) / Float(1 << 24) }
  for _ in 0..<4096 { points.append(SIMD4(random() * 8 - 4, random() * 4 - 2, random() * 8 - 4, 1)) }
  let pointBuffer = gpu.makeBuffer(bytes: points, length: points.count * 16, options: .storageModeShared)!
  let projected = gpu.makeBuffer(length: points.count * 8, options: .storageModeShared)!
  dispatch(try pipeline("splat_project_points"), threads: points.count) {
    $0.setBytes(&frame, length: MemoryLayout<Uniforms>.stride, index: 0)
    $0.setBuffer(pointBuffer, offset: 0, index: 1); $0.setBuffer(projected, offset: 0, index: 2)
  }
  let gpuPixels = projected.contents().bindMemory(to: SIMD2<Int32>.self, capacity: points.count)
  var agree = 0, onScreen = 0, ambiguous = 0
  for (i, p) in points.enumerated() {
    let clip = frame.currentViewProj * p
    var expected = SIMD2<Int32>(-1, -1)
    if clip.w > 0 {
      let uv = SIMD2<Float>(clip.x / clip.w * 0.5 + 0.5, -clip.y / clip.w * 0.5 + 0.5)
      if uv.x >= 0 && uv.x < 1 && uv.y >= 0 && uv.y < 1 {
        let s = uv * SIMD2(Float(pw), Float(ph))
        expected = SIMD2(Int32(s.x), Int32(s.y))
        onScreen += 1
        // Points within 1e-3 pixel of a pixel edge may round either way.
        if abs(s.x - s.x.rounded()) < 1e-3 || abs(s.y - s.y.rounded()) < 1e-3 { ambiguous += 1; continue }
      }
    }
    if gpuPixels[i] == expected { agree += 1 }
  }
  require(onScreen > 500 && agree + ambiguous == points.count, "splat_project matches the host camera matrix (\(agree) + \(ambiguous) of \(points.count))")
  print("PASS: fix-splatting forward projection matches the camera math")

  // Deep layers after an orbit: per pixel, deep depths increase beyond the front layer, every layer's
  // own depth falls in its own range (splat_layer), pool domains match their pixel, layer and depth,
  // lie on the pixel's camera ray, and are hidden from the camera by a nearer surface.
  for reuse in [IndirectReuse.restirGI, .restirPTUnified] {
    renderer.indirectReuse = reuse
    _ = render(makeUniforms(scene: 0, mode: 0, width: pw, height: ph), samples: 16, orbit: true)
    frame = lastRenderUniforms!
    let pool = renderer.splatPrevious!  // swapped after the last frame: that frame's pool
    let count = poolCount(pool)
    let overflow = pool.counters.contents().load(fromByteOffset: 4, as: UInt32.self)
    let result = gpu.makeBuffer(length: 8 * 4, options: .storageModeShared)!
    memset(result.contents(), 0, 32)
    dispatch(try pipeline("splat_layer_checks"), threads: pw * ph + count) {
      $0.setTexture(renderer.historyPosDepth!, index: 0)
      $0.setBytes(&frame, length: MemoryLayout<Uniforms>.stride, index: 0)
      renderer.materials.bind($0)
      $0.setBuffer(pool.domains, offset: 0, index: 12); $0.setBuffer(pool.surfaces, offset: 0, index: 13)
      $0.setBuffer(pool.counters, offset: 0, index: 14); $0.setBuffer(renderer.splatLayers!, offset: 0, index: 16)
      $0.setBuffer(result, offset: 0, index: 24)
    }
    let r = result.contents().bindMemory(to: UInt32.self, capacity: 8)
    print("\(reuse) deep layers: \(count) domains (overflow \(overflow)); pixels with deep layers \(r[0]), ordering failures \(r[1]), range failures \(r[2]); domains checked \(r[3]), bookkeeping failures \(r[4]), off-ray \(r[5]), visible \(r[6])")
    require(count > 20 && overflow == 0 && r[0] > 20 && r[1] == 0 && r[2] == 0 && r[3] == UInt32(count) && r[4] == 0 && r[5] == 0
        && Double(r[6]) <= 0.01 * Double(count),
      "\(reuse): deep layers are ordered behind the front layer with disjoint depth ranges; their domains are occluded hits on their pixel's ray")
  }
  print("PASS: fix-splatting deep-layer depth ordering, depth ranges and pool bookkeeping")

  func splatSourceCounts(pixels: Int) -> (front: Int, deep: Int) {
    let sources = readBuffer(renderer.splatSources!).contents().bindMemory(to: UInt64.self, capacity: renderer.splatSources!.length / 8)
    var fromDeep = 0, fromFront = 0
    for i in 0..<pixels where sources[i] != UInt64.max {
      if (sources[i] & 0xffffffff) >= UInt64(pixels) { fromDeep += 1 } else { fromFront += 1 }
    }
    return (fromFront, fromDeep)
  }
  // Memory: the plan matches the resident frame; a mode switch budgets the splat resources.
  let mw = 256, mh = 192
  for reuse in [IndirectReuse.restirGI, .restirPT, .restirPTUnified] {
    renderer.indirectReuse = reuse
    renderer.temporalReuse = .splatting
    _ = render(makeUniforms(scene: 1, mode: 0, width: mw, height: mh), samples: 1)
    let capacity = PathTracerRenderer.splatCapacity(width: mw, height: mh)
    let usesDI = reuse != .restirPTUnified, usesGI = reuse == .restirGI, usesPT = reuse != .restirGI
    let pool = renderer.splatCurrent!
    require(pool.capacity == capacity && pool.domains.length == capacity * 32 && pool.surfaces.length == capacity * 128
        && (pool.di?.length ?? 0) == (usesDI ? capacity * 48 : 0) && (pool.gi?.length ?? 0) == (usesGI ? capacity * 64 : 0)
        && (pool.pt?.length ?? 0) == (usesPT ? capacity * 64 : 0) && (pool.controls?.length ?? 0) == (usesPT ? capacity * 16 : 0)
        && renderer.splatLayers!.length == mw * mh * 48
        && renderer.splatSources!.length == (mw * mh + capacity) * 8,
      "\(reuse): splatting allocates two pools and the per-pixel state of its reservoirs")
    let plan = PathTracerRenderer.FrameResourcePlan(width: mw, height: mh, usesReSTIR: true, usesMetalFX: false, indirectReuse: reuse, splatting: true)
    let resident = Double(renderer.residentFrameBytes), planned = Double(plan.bytes!)
    print("\(reuse) with splatting: resident frame \(Int(resident)) B, plan \(Int(planned)) B")
    require(resident >= 0.95 * planned && resident <= 1.1 * planned, "\(reuse): the splatting resource plan matches the resident frame")
  }
  // ReSTIR PT pools also hold 16 B ReSTCV estimates (RESTCV2026).
  require(PathTracerRenderer.FrameResourcePlan.splatBytesPerPixel(.restirGI) == 198
      && PathTracerRenderer.FrameResourcePlan.splatBytesPerPixel(.restirPT) == 206
      && PathTracerRenderer.FrameResourcePlan.splatBytesPerPixel(.restirPTUnified) == 182,
    "reservoir-splatting bytes per pixel per mode")
  renderer.temporalReuse = .reprojection
  _ = render(makeUniforms(scene: 1, mode: 0, width: mw, height: mh), samples: 1)
  let withoutSplat = renderer.residentFrameBytes
  require(renderer.splatCurrent == nil && renderer.splatMask == nil, "reprojection releases the splat resources")
  renderer.temporalReuse = .splatting
  let switchPlan = renderer.renderMemoryError(width: mw, height: mh)
  require(switchPlan == nil, "a temporal-reuse switch at a small size fits the budget")
  _ = render(makeUniforms(scene: 1, mode: 0, width: mw, height: mh), samples: 1)
  require(renderer.residentFrameBytes > withoutSplat + UInt64(mw * mh) * 150, "switching to splatting allocates its resources")
  print("PASS: fix-splatting memory plan and resource switches")

  // Fallback equivalence: static accumulations, thin-lens motion and the other strategies render
  // identically whatever the temporal reuse, and reprojection is unchanged after splat frames.
  for reuse in [IndirectReuse.restirGI, .restirPT, .restirPTUnified] {
    renderer.indirectReuse = reuse
    renderer.temporalReuse = .reprojection
    let still = render(makeUniforms(scene: 0, mode: 0, width: 64, height: 48), samples: 4)
    let lens = render(thinLens, samples: 4, orbit: true)
    let moving = render(makeUniforms(scene: 0, mode: 0, width: 64, height: 48), samples: 6, orbit: true)
    renderer.temporalReuse = .splatting
    let splatStill = render(makeUniforms(scene: 0, mode: 0, width: 64, height: 48), samples: 4)
    let splatLens = render(thinLens, samples: 4, orbit: true)
    let splatMoving = render(makeUniforms(scene: 0, mode: 0, width: 64, height: 48), samples: 6, orbit: true)
    renderer.temporalReuse = .reprojection
    let after = render(makeUniforms(scene: 0, mode: 0, width: 64, height: 48), samples: 6, orbit: true)
    require(still == splatStill && lens == splatLens && after == moving && splatMoving != moving,
      "\(reuse): splatting changes only moving pinhole frames and leaves reprojection unchanged")
  }
  for mode in UInt32(1)...3 {
    renderer.temporalReuse = .reprojection
    let a = render(makeUniforms(scene: 3, mode: mode, width: 64, height: 48), samples: 3, orbit: true)
    renderer.temporalReuse = .splatting
    let b = render(makeUniforms(scene: 3, mode: mode, width: 64, height: 48), samples: 3, orbit: true)
    require(a == b, "strategy \(mode) renders identically whatever the temporal reuse")
  }
  renderer.indirectReuse = .restirPTUnified
  _ = render(makeUniforms(scene: 0, mode: 0, width: 96, height: 72), samples: 6, denoise: true, orbit: true)
  require(renderer.lastFrameSplatted && lastDisplay.contains { $0.x > 0 }, "splat frames present through MetalFX (or its raw fallback)")
  print("PASS: fix-splatting fallback equivalence to reprojection")

  // Moving frames on two alternating views (every frame disoccludes the strips its predecessor hid):
  // the mean of each view's single frames against a MIS reference of that view, and the error of the
  // pixels hidden in the preceding frame against reprojection.
  let aw = 128, ah = 96
  let output = renderOutputs[SIMD2(aw, ah)] ?? {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: aw, height: ah, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
    return gpu.makeTexture(descriptor: d)!
  }()
  renderOutputs[SIMD2(aw, ah)] = output
  let base = makeUniforms(scene: 0, mode: 0, width: aw, height: ah)
  applyTestView(base)
  let yaw0 = renderer.yaw
  let views = [yaw0 - 0.03, yaw0 + 0.03]
  var references = [[SIMD4<Float>]](), positions = [[SIMD4<Float>]]()
  for yaw in views {
    applyTestView(base); renderer.yaw = yaw
    var view = base
    let eye = renderer.target + SIMD3<Float>(renderer.distance * cos(renderer.pitch) * sin(yaw), renderer.distance * sin(renderer.pitch),
                                             -renderer.distance * cos(renderer.pitch) * cos(yaw))
    view.cameraPos = SIMD4(eye, base.cameraPos.w); view.samplingMode = 1
    references.append(render(view, samples: 768))
    positions.append(lastPositions)
  }
  // Pixels of view v hidden in the other view (a nearer surface there): disoccluded on every switch.
  var hidden = [[Bool]](repeating: [Bool](repeating: false, count: aw * ah), count: 2)
  for v in 0..<2 {
    applyTestView(base); renderer.yaw = views[1 - v]
    let eyeOther = renderer.eyePosition
    let clip = makePerspective(fovyRadians: renderer.fov * .pi / 180, aspect: Float(aw) / Float(ah),
                               near: renderer.cameraClipPlanes().near, far: renderer.cameraClipPlanes().far)
      * makeLookAt(eye: eyeOther, target: renderer.target, up: SIMD3<Float>(0, 1, 0))
    for i in 0..<(aw * ah) where positions[v][i].w > 0 {
      let p = SIMD3<Float>(positions[v][i].x, positions[v][i].y, positions[v][i].z)
      let c = clip * SIMD4<Float>(p, 1)
      guard c.w > 0 else { continue }
      let uv = SIMD2<Float>(c.x / c.w * 0.5 + 0.5, -c.y / c.w * 0.5 + 0.5)
      guard uv.x >= 0, uv.x < 1, uv.y >= 0, uv.y < 1 else { continue }
      let q = Int(uv.y * Float(ah)) * aw + Int(uv.x * Float(aw))
      let other = positions[1 - v][q]
      hidden[v][i] = other.w > 0 && other.w < simd_distance(p, eyeOther) * 0.97
    }
  }
  print("Alternating views: \(hidden[0].filter { $0 }.count) and \(hidden[1].filter { $0 }.count) pixels disoccluded on each switch")
  func alternate(frames: Int, seed: UInt32) -> (sums: [[SIMD4<Float>]], hiddenError: Double) {
    applyTestView(base)
    renderer.denoiserEnabled = false
    renderer.resetAccumulation()
    renderer.restartSampleSequence(at: seed)
    var sums = [[SIMD4<Float>]](repeating: [SIMD4<Float>](repeating: .zero, count: aw * ah), count: 2)
    var completed = 0, error = 0.0, samples = 0
    let savedUpdate = renderer.onFrameUpdate
    renderer.onFrameUpdate = { _ in completed += 1 }
    for f in 0..<frames {
      renderer.yaw = views[f % 2]
      let target = completed + 1
      renderer.renderFrame(output: output)
      let deadline = Date().addingTimeInterval(60)
      while completed < target && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
      require(completed >= target, "alternating views: frame \(f) completes")
      let image = readTexture(renderer.accumTexture!)
      for i in image.indices { sums[f % 2][i] += image[i] }
      if f >= 8 {
        for i in image.indices where hidden[f % 2][i] {
          // Display-referred: the display clamps negative (ReSTCV, RESTCV2026) values to black.
          let a = simd_max(image[i], .zero), b = simd_max(references[f % 2][i], .zero)
          let x = a / (a + 1), y = b / (b + 1), d = x - y
          error += Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3; samples += 1
        }
      }
    }
    renderer.onFrameUpdate = savedUpdate
    return (sums.map { $0.map { $0 / Float(frames / 2) } }, error / Double(max(samples, 1)))
  }
  renderer.indirectReuse = .restirPTUnified
  var ratios = [Double]()
  for trial in 0..<3 {
    var errors = [TemporalReuse: Double]()
    for temporal in [TemporalReuse.reprojection, .splatting] {
      renderer.temporalReuse = temporal
      let run = alternate(frames: 64, seed: UInt32(trial) * 4000 + 100)
      errors[temporal] = run.hiddenError
      if temporal == .splatting && trial == 0 {
        // The splats reached their destinations: disoccluded front-layer pixels reuse deep domains.
        let counts = splatSourceCounts(pixels: aw * ah)
        print("Alternating views, last frame's front-layer temporal sources: \(counts.front) front-layer splats, \(counts.deep) deep-domain splats")
        require(renderer.lastFrameSplatted && counts.deep > 20 && counts.front > aw * ah / 2,
          "alternating views splat every frame; front-layer domains reuse splats of front-layer and deep domains")
      }
    }
    ratios.append(errors[.splatting]! / errors[.reprojection]!)
  }
  print("Alternating views, unified ReSTIR PT: disoccluded-pixel tone-mapped MSE ratio (splatting / reprojection) \(ratios)")
  // Measured 0.85-0.91 (mean 0.88) over 40 frames at this size.
  require(ratios.allSatisfy { $0 < 0.97 } && ratios.reduce(0, +) / Double(ratios.count) < 0.93,
    "splatting lowers the per-frame error of disoccluded pixels")
  for reuse in [IndirectReuse.restirPTUnified, .restirGI] {
    renderer.indirectReuse = reuse
    var bias = [TemporalReuse: [(Float, Float, Float)]]()
    for temporal in [TemporalReuse.reprojection, .splatting] {
      renderer.temporalReuse = temporal
      let run = alternate(frames: 384, seed: 9000)
      bias[temporal] = (0..<2).map { v in pairedDifference(run.sums[v], references[v], width: aw, pixels: Array(0..<(aw * ah)), block: 8) }
      for (v, d) in bias[temporal]!.enumerated() {
        print("Alternating views, \(reuse) \(temporal), view \(v) - MIS: \(d.0 / d.2) ± \(d.1 / d.2) (relative)")
      }
    }
    for v in 0..<2 {
      let s = bias[.splatting]![v], p = bias[.reprojection]![v]
      // ReSTIR GI's moving frames are biased by about +1% in either mode (M-capped temporal merges);
      // splatting must agree with MIS as well as reprojection does.
      let bound = reuse == .restirGI ? abs(p.0) + 4 * (s.1 + p.1) + 0.004 * s.2 : 4 * s.1 + 0.004 * s.2
      require(abs(s.0) < bound, "\(reuse), view \(v): splatting agrees with MIS in mean radiance")
    }
  }
  print("PASS: fix-splatting mean radiance against MIS and the disocclusion error gain")
  (renderer.indirectReuse, renderer.temporalReuse) = saved
}

// GPU checks of the splat geometry (appended to the production shaders).
let splatCheckKernels = """
kernel void splat_self_projection(texture2d<float, access::read> positions [[texture(0)]], constant Uniforms &u [[buffer(0)]],
                                  device atomic_uint *out [[buffer(1)]], uint tid [[thread_position_in_grid]]) {
    if (tid >= u.width * u.height) return;
    uint2 p = uint2(tid % u.width, tid / u.width);
    float4 hit = positions.read(p);
    if (!(hit.w > 0.0f)) return;
    atomic_fetch_add_explicit(&out[0], 1u, memory_order_relaxed);
    int2 q;
    if (splat_project(hit.xyz, u, q) && all(uint2(q) == p)) atomic_fetch_add_explicit(&out[1], 1u, memory_order_relaxed);
}
kernel void splat_project_points(constant Uniforms &u [[buffer(0)]], const device float4 *points [[buffer(1)]],
                                 device int2 *out [[buffer(2)]], uint tid [[thread_position_in_grid]]) {
    int2 q;
    out[tid] = splat_project(points[tid].xyz, u, q) ? q : int2(-1);
}
// out: [0] pixels with deep layers, [1] depth-ordering failures, [2] depth-range failures,
// [3] domains checked, [4] bookkeeping failures, [5] domains off their pixel's ray, [6] visible domains.
kernel void splat_layer_checks(texture2d<float, access::read> positions [[texture(0)]], constant Uniforms &u [[buffer(0)]],
                               constant MaterialResources &images [[buffer(2)]],
                               const device SplatDomain *domains [[buffer(12)]], const device PrimarySurface *surfaces [[buffer(13)]],
                               const device uint *counters [[buffer(14)]], const device SplatLayers *layers [[buffer(16)]],
                               device atomic_uint *out [[buffer(24)]], uint tid [[thread_position_in_grid]]) {
    uint pixels = u.width * u.height;
    if (tid < pixels) {
        SplatLayers l = layers[tid];
        if (!(l.depth[0] > 0.0f)) return;
        atomic_fetch_add_explicit(&out[0], 1u, memory_order_relaxed);
        float4 front = positions.read(uint2(tid % u.width, tid / u.width));
        float previous = front.w;
        bool ordered = front.w > 0.0f, ranged = true;
        float frontHalfWidth = SPLAT_EPSILON * front.w;  // the narrowest range the kernel can use
        for (uint i = 0u; i < SPLAT_DEEP_LAYERS && l.depth[i] > 0.0f; ++i) {
            ordered = ordered && l.depth[i] > previous && l.halfWidth[i] > 0.0f;
            ranged = ranged && splat_layer(l.depth[i], front.w, frontHalfWidth, l) == i + 1u;
            previous = l.depth[i];
        }
        ranged = ranged && splat_layer(front.w, front.w, frontHalfWidth, l) == 0u;
        if (!ordered) atomic_fetch_add_explicit(&out[1], 1u, memory_order_relaxed);
        if (!ranged) atomic_fetch_add_explicit(&out[2], 1u, memory_order_relaxed);
        return;
    }
    uint j = tid - pixels;
    if (j >= splat_count(counters)) return;
    atomic_fetch_add_explicit(&out[3], 1u, memory_order_relaxed);
    SplatDomain d = domains[j];
    uint layer = d.flags & 255u;
    SplatLayers l = layers[d.pixel];
    bool kept = layer >= 2u && layer <= 1u + SPLAT_DEEP_LAYERS && l.slot[layer - 2u] == j && l.depth[layer - 2u] == d.depth;
    if (!kept) atomic_fetch_add_explicit(&out[4], 1u, memory_order_relaxed);
    float3 eye = u.cameraPos.xyz, view = float3(surfaces[j].view);
    if (distance(float3(d.position), eye + view * d.depth) > 1e-3f * d.depth) atomic_fetch_add_explicit(&out[5], 1u, memory_order_relaxed);
    Ray ray;
    ray.origin = eye;
    ray.direction = normalize(float3(d.position) - eye);
    HitRecord hit;
    if (!trace_scene(ray, u.sceneIndex, hit, images, u) || distance(eye, hit.position) > 0.99f * d.depth)
        atomic_fetch_add_explicit(&out[6], 1u, memory_order_relaxed);
}
"""
try fixSplattingChecks()
