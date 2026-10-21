// Scaling to larger Macs (docs/SCENE_STORAGE_DESIGN.md, "Scaling to larger Macs"): several samples
// encoded into one command buffer (renderFrame `samples`) accumulate exactly as the same samples
// in separate frames; samplesPerFrame's batch sizing; and the static bounds leave capacity to the
// memory budgets, with a project entry large enough for the biggest mesh asset.
@MainActor func fixScalingChecks() throws {
  let r = testRenderer
  let savedOptions = r.options, savedFrameUpdate = r.onFrameUpdate, savedError = r.onError, savedDenoiser = r.denoiserEnabled
  defer { r.options = savedOptions; r.onFrameUpdate = savedFrameUpdate; r.onError = savedError; r.denoiserEnabled = savedDenoiser }
  var drained = false
  DispatchQueue.main.async { drained = true }
  while !drained { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
  let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 48, height: 32, mipmapped: false)
  d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
  let output = gpu.makeTexture(descriptor: d)!
  // Eight samples as the given batches; returns the accumulation.
  func accumulate(_ input: Uniforms, batches: [Int]) -> [SIMD4<Float>] {
    applyTestView(input)
    r.denoiserEnabled = false
    r.options.previewScale = 1
    r.resetAccumulation()
    r.restartSampleSequence()
    var completed: UInt32 = 0, failure: String?
    r.onFrameUpdate = { completed = $0 }
    r.onError = { failure = $0 }
    for n in batches {
      let target = r.frameIndex + UInt32(n)
      r.renderFrame(output: output, samples: n)
      require(r.frameIndex == target, "renderFrame encodes \(n) samples")
      let deadline = Date().addingTimeInterval(30)
      while completed < target && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
      require(completed == target && failure == nil, "batch of \(n) completes (\(failure ?? "timeout"))")
    }
    return readTexture(r.accumTexture!)
  }
  for (label, mode) in [("Standard MIS", UInt32(1)), ("ReSTIR", UInt32(0))] {
    let view = makeUniforms(scene: 1, mode: mode, width: 48, height: 32)
    let single = accumulate(view, batches: Array(repeating: 1, count: 8))
    let batched = accumulate(view, batches: [1, 3, 4])
    let whole = accumulate(view, batches: [8])
    require(single == batched && single == whole && single.contains { $0.x > 0 },
      "\(label): samples batched in one command buffer accumulate exactly as separate frames")
  }
  // Batch sizing: one sample while accumulation restarts or MetalFX runs; otherwise the target over
  // the measured GPU time per sample, bounded by the limit and 64.
  let view = makeUniforms(scene: 1, mode: 1, width: 48, height: 32)
  _ = accumulate(view, batches: Array(repeating: 1, count: 6))
  let perSample = r.gpuMillisecondsPerSample
  require(perSample > 0, "GPU time per sample is measured (\(perSample) ms)")
  let expected = max(1, min(Int(100 / perSample), 64))
  require(r.samplesPerFrame(targetMilliseconds: 100, limit: .max) == expected
    && r.samplesPerFrame(targetMilliseconds: 100, limit: 2) == min(2, expected)
    && r.samplesPerFrame(targetMilliseconds: 0, limit: .max) == 1,
    "batch size follows the measured cost (\(perSample) ms per sample, \(expected) per 100 ms)")
  r.resetAccumulation()
  require(r.samplesPerFrame(targetMilliseconds: 100, limit: .max) == 1, "a restarted accumulation renders one sample per frame")
  print(String(format: "Batch sizing: %.3f ms GPU per sample at 48x32, %d samples per 100 ms", perSample, expected))
  print("PASS: batched samples accumulate exactly as separate frames; batch size follows measured GPU time")

  // Static bounds are addressing limits; a project entry holds the largest mesh asset (a single
  // 9 M-triangle mesh, 274 MiB, was saved but refused on reopen while entries were capped at 256 MiB).
  require(SceneLimits.triangles >= 1 << 30 && SceneLimits.renderedTriangles == Int(Int32.max)
    && ProjectAssets.maximumEntryBytes >= 16 + SceneLimits.triangles * 112
    && ProjectAssets.maximumTableBytes >= ProjectAssets.maximumEntryBytes,
    "scene bounds leave capacity to the memory budgets; an entry holds the largest mesh")
  print("PASS: static scene bounds and project entries scale past 16 GB Macs")
}
try fixScalingChecks()
