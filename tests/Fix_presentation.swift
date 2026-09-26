// Regression checks for presentation, idle behaviour and display encoding
// (R-14, R-15, R-16, R-46, R-61, R-63, R-84, R-123, R-124).
func fixPresentationChecks() throws {
  let renderer = testRenderer
  final class ProbeView: MTKView {
    var drawableRequests = 0
    override var currentDrawable: CAMetalDrawable? {
      drawableRequests += 1
      return super.currentDrawable
    }
  }
  func sharedTexture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
    return gpu.makeTexture(descriptor: d)!
  }
  func srgb(_ x: Float) -> Float {
    let c = max(0, min(1, x))
    return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / Float(2.4)) - 0.055
  }
  func filmic(_ x: Float) -> Float {
    (x * (x + 0.0245786) - 0.000090537) / (x * (0.983729 * x + 0.4329510) + 0.238081)
  }
  let savedOptions = renderer.options
  renderer.paused = false; renderer.viewportMode = 0

  // R-84, R-123: every display curve ends in the exact piecewise sRGB OETF, and
  // negative or NaN radiance displays black instead of bright.
  let values: [Float] = [0.001, 0.01, 0.2, 0.5, 0.9, -0.5, .nan, -3]
  let hdr = sharedTexture(.rgba32Float, values.count, 1)
  let pixels = values.flatMap { [$0, $0, $0, Float(1)] }
  hdr.replace(region: MTLRegionMake2D(0, 0, values.count, 1), mipmapLevel: 0, withBytes: pixels,
    bytesPerRow: values.count * 16)
  let out = sharedTexture(.rgba32Float, values.count, 1)
  renderer.options.exposure = 0; renderer.options.whiteBalance = 0; renderer.options.compare = 0
  let curves: [(Float, (Float) -> Float)] = [(2, { $0 }), (1, { $0 / (1 + $0) }), (0, filmic)]
  for (toneMap, curve) in curves {
    renderer.options.toneMap = toneMap
    let command = renderer.commandQueue.makeCommandBuffer()!
    require(renderer.encodeDisplay(command, display: hdr, raw: hdr, output: out), "display encodes")
    command.commit(); command.waitUntilCompleted()
    let shown = readTexture(out)
    for (i, v) in values.enumerated() {
      let expected = v.isNaN || v <= 0 ? 0 : srgb(curve(v))
      require(abs(shown[i].x - expected) < 2e-3,
        "tone map \(toneMap): linear \(v) displays \(shown[i].x), sRGB expects \(expected)")
    }
  }
  renderer.viewportMode = 1
  do {
    let command = renderer.commandQueue.makeCommandBuffer()!
    require(renderer.encodeDisplay(command, display: hdr, raw: hdr, output: out, albedo: hdr), "albedo view encodes")
    command.commit(); command.waitUntilCompleted()
    let shown = readTexture(out)
    for i in 0..<5 {
      require(abs(shown[i].x - srgb(values[i])) < 2e-3, "albedo inspection view is sRGB encoded")
    }
  }
  renderer.viewportMode = 0
  renderer.options = savedOptions
  print("PASS: display curves use the piecewise sRGB OETF and clamp negative/NaN radiance")

  // R-124: reversed-Z projection keeps distant MetalFX depth distinguishable.
  let projection = makePerspective(fovyRadians: 0.7, aspect: 1.5, near: 0.0005, far: 10_000)
  func depth(_ distance: Float) -> Float {
    let clip = projection * SIMD4<Float>(0, 0, -distance, 1)
    return clip.z / clip.w
  }
  require(abs(depth(0.0005) - 1) < 1e-5 && abs(depth(10_000)) < 1e-5, "reversed-Z maps near to 1 and far to 0")
  require(depth(100) > depth(100.1) && depth(1000) > depth(1001), "distant depth remains distinguishable")

  // Live frames through MTKView.draw(), which calls the production draw(in:).
  renderer.options = StudioOptions(); renderer.options.previewScale = 0.5
  renderer.sceneIndex = 1; renderer.samplingMode = 0
  renderer.denoiserEnabled = renderer.supportsMetalFX
  let probe = ProbeView(frame: NSRect(x: 0, y: 0, width: 96, height: 64), device: gpu)
  probe.colorPixelFormat = .bgra8Unorm; probe.framebufferOnly = false
  probe.autoResizeDrawable = false; probe.isPaused = true; probe.enableSetNeedsDisplay = false
  probe.drawableSize = CGSize(width: 96, height: 64)
  probe.delegate = renderer
  var completed = 0
  renderer.onFrameUpdate = { _ in completed += 1 }
  func settle(until condition: () -> Bool = { false }, seconds: Double = 20) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  }
  func liveFrame() {
    let target = completed + 1
    probe.draw()
    settle(until: { completed >= target })
    require(completed >= target, "live draw traces and completes a frame")
  }
  for _ in 0..<3 { liveFrame() }
  require(renderer.lastDisplay != nil && renderer.accumTexture?.width == 48, "live draws present frames")
  if renderer.supportsMetalFX {
    require(renderer.metalFX?.scaler.isDepthReversed == true, "MetalFX receives reversed-Z depth")
  }

  // R-14: display-only edits repaint while paused, without tracing.
  renderer.paused = true
  let pausedCount = renderer.frameIndex, pausedAccum = renderer.accumTexture
  probe.draw()
  renderer.presentationNeedsRefresh = false
  var requests = probe.drawableRequests
  renderer.options.exposure = 3
  require(renderer.presentationNeedsRefresh, "exposure edit requests a repaint")
  probe.draw()
  require(probe.drawableRequests == requests + 1 && !renderer.presentationNeedsRefresh
      && renderer.frameIndex == pausedCount, "paused exposure edit repaints without tracing")
  renderer.options.toneMap = 1
  requests = probe.drawableRequests
  probe.draw()
  require(probe.drawableRequests == requests + 1 && !renderer.presentationNeedsRefresh, "paused tone-map edit repaints")

  // R-15: a paused resize keeps the render and presents it without tracing.
  var before = completed
  probe.drawableSize = CGSize(width: 120, height: 80)
  renderer.mtkView(probe, drawableSizeWillChange: probe.drawableSize)
  require(renderer.accumTexture === pausedAccum && renderer.frameIndex == pausedCount
      && renderer.lastDisplay != nil && renderer.presentationNeedsRefresh,
    "paused resize keeps the accumulation and requests a scaled repaint")
  probe.draw()
  settle(seconds: 0.3)
  require(completed == before && renderer.frameIndex == pausedCount && !renderer.presentationNeedsRefresh,
    "paused refresh after resize presents without tracing a sample")

  // R-16: paused refreshes never re-run MetalFX or consume its history reset.
  if renderer.supportsMetalFX, let fx = renderer.metalFX {
    let denoised = readTexture(fx.output)
    renderer.denoiserEnabled = false
    probe.draw()
    require(!renderer.lastPresentationUsedMetalFX, "disabling the denoiser while paused shows the raw render")
    renderer.denoiserEnabled = true
    probe.draw()
    renderer.viewportMode = 2; probe.draw(); renderer.viewportMode = 0; probe.draw()
    let after = readTexture(fx.output)
    require(zip(denoised, after).allSatisfy { $0 == $1 }, "paused refreshes keep the converged MetalFX output")
    require(renderer.metalFXHistoryNeedsReset && renderer.lastPresentationUsedMetalFX,
      "paused refresh re-displays MetalFX output and keeps the pending history reset")
    require(renderer.frameIndex == pausedCount, "paused MetalFX refreshes preserve the accumulation")
  }

  // R-63: an edit while paused invalidates the last display for capture and picking.
  renderer.resetAccumulation()
  require(renderer.lastDisplay == nil && renderer.lastUniforms == nil, "reset invalidates the stale display and uniforms")
  var picked: Int? = -1
  renderer.pick(SIMD2<Float>(0.5, 0.5)) { picked = $0 }
  settle(until: { picked != -1 }, seconds: 2)
  require(picked == nil, "picking waits for a frame of the edited scene")
  controller.capturePreview()
  require(controller.status.stringValue.contains("Wait for the first rendered frame"), "capture waits for a fresh frame")
  before = completed; requests = probe.drawableRequests
  renderer.presentationNeedsRefresh = true
  probe.draw()
  settle(seconds: 0.3)
  require(completed == before && probe.drawableRequests == requests, "paused draw never traces after an edit")

  // R-61: frames count toward inspection by the mode they were submitted in.
  renderer.paused = false
  probe.drawableSize = CGSize(width: 96, height: 64)
  renderer.mtkView(probe, drawableSizeWillChange: probe.drawableSize)
  for _ in 0..<2 { liveFrame() }
  let beautyCount = renderer.frameIndex
  let target = completed + 1
  probe.draw()
  renderer.viewportMode = 2
  settle(until: { completed >= target })
  for _ in 0..<2 { liveFrame() }
  renderer.viewportMode = 0
  require(renderer.frameIndex == beautyCount + 1, "an in-flight beauty frame stays in the beauty sample count")

  // R-46: with every frame slot in flight, draw(in:) returns without waiting
  // for a drawable.
  for _ in 0..<3 {
    require(renderer.inFlightFrames.wait(timeout: .now() + 20) == .success, "reserve frame slot")
  }
  requests = probe.drawableRequests
  let heldCount = renderer.frameIndex
  probe.draw()
  require(probe.drawableRequests == requests && renderer.frameIndex == heldCount,
    "busy GPU does not block draw on nextDrawable")
  for _ in 0..<3 { renderer.inFlightFrames.signal() }
  liveFrame()
  require(probe.drawableRequests == requests + 1 && renderer.frameIndex == heldCount + 1, "draw resumes with a free slot")

  probe.delegate = nil
  renderer.onFrameUpdate = nil
  renderer.options = savedOptions
  print("PASS: paused repaint, resize, MetalFX refresh, stale-frame, inspection-count and drawable-wait behaviour")
}
try fixPresentationChecks()
