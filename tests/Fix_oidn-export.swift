// Regression checks for the oidn-export fix package (R-40, R-41, R-79..R-83, R-106).
import ImageIO
func fixOIDNExportChecks() throws {
  func texture(_ pixels: [SIMD4<Float>], width: Int, height: Int) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    let result = gpu.makeTexture(descriptor: descriptor)!
    var copy = pixels
    result.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
      withBytes: &copy, bytesPerRow: width * 16)
    return result
  }
  // Decodes without color matching, so values are exactly what the file stores.
  func decodeEXR(_ url: URL) -> (width: Int, height: Int, pixels: [SIMD3<Float>])? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary),
      image.bitsPerComponent == 32, let data = image.dataProvider?.data as Data?
    else { return nil }
    let components = image.bitsPerPixel / 32, stride = image.bytesPerRow / 4
    var pixels: [SIMD3<Float>] = []
    data.withUnsafeBytes { bytes in
      let floats = bytes.bindMemory(to: Float.self)
      for y in 0..<image.height {
        for x in 0..<image.width {
          let base = y * stride + x * components
          pixels.append(SIMD3(floats[base], floats[base + 1], floats[base + 2]))
        }
      }
    }
    return (image.width, image.height, pixels)
  }
  func renderOneFrame() {
    var done = false
    testRenderer.onFrameUpdate = { _ in done = true }
    testRenderer.renderFrame(output: studioOutput)
    waitUntil({ done })
    testRenderer.onFrameUpdate = nil
  }
  func drag() {
    let event = NSEvent.mouseEvent(
      with: .leftMouseDragged, location: NSPoint(x: 40, y: 40), modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    controller.viewport.mouseDown(with: event)
    let moved = NSEvent.mouseEvent(
      with: .leftMouseDragged, location: NSPoint(x: 90, y: 60), modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    controller.viewport.mouseDragged(with: moved)
  }

  let savedOptions = testRenderer.options, savedOIDN = testRenderer.oidnOptions
  let savedDenoise = testRenderer.denoiserEnabled, savedStrategy = testRenderer.samplingMode
  let savedExportDenoise = controller.exportDenoise, savedExportRaw = controller.exportRaw
  let folder = studioDirectory.appendingPathComponent("fix-oidn-export", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

  // R-83: float32 EXR keeps radiance above the half-float limit, per channel and position.
  let hdrPixels: [SIMD4<Float>] = [
    SIMD4(0.001, 70000, 1, 1), SIMD4(0, 2, 0, 1), SIMD4(1e6, 1, 0.5, 1),
    SIMD4(0.25, 0, 3, 1), SIMD4(5, 6, 7, 1), SIMD4(0, 0, 123456, 1),
  ]
  let hdrURL = folder.appendingPathComponent("float32.exr")
  try RenderImage.write(texture: texture(hdrPixels, width: 3, height: 2), url: hdrURL, hdr: true)
  let decoded = decodeEXR(hdrURL)
  require(decoded?.width == 3 && decoded?.height == 2, "float EXR dimensions")
  if let decoded {
    for (index, expected) in hdrPixels.enumerated() {
      let value = decoded.pixels[index], wanted = SIMD3(expected.x, expected.y, expected.z)
      require(simd_reduce_max(abs(value - wanted)) <= 1e-6 * max(1, simd_reduce_max(wanted)),
        "EXR pixel \(index) keeps position and float32 value \(wanted), got \(value)")
    }
  }
  try testRenderer.materials.setEnvironment(try Data(contentsOf: hdrURL))
  let imported = readTexture(testRenderer.materials.environmentTexture)
  require(abs(imported[0].y - 70000) < 0.1 && abs(imported[2].x - 1e6) < 1 && imported[0].x < 0.01,
    "renderer imports float32 EXR radiance without clipping or channel crosstalk")
  try testRenderer.materials.setEnvironment(nil)
  print("PASS: float32 OpenEXR positions and radiance above 65504")

  // R-40: OIDN's automatic input scale by default; the opt-in key must not
  // mis-expose small subjects on black or scenes with large emitters.
  require(!OIDNOptions().robustInputScale, "OIDN defaults to its automatic input scale")
  func hash(_ index: Int, _ salt: UInt32) -> Float {
    var x = UInt32(truncatingIfNeeded: index) &* 747_796_405 &+ salt &* 2_891_336_453
    x = ((x >> ((x >> 28) &+ 4)) ^ x) &* 277_803_737
    x = (x >> 22) ^ x
    return Float(x) / 4_294_967_296
  }
  for kind in 0...1 {
    let size = 64
    var color: [SIMD4<Float>] = [], albedo: [SIMD4<Float>] = [], normal: [SIMD4<Float>] = []
    var reference: [SIMD3<Float>?] = []
    for index in 0..<(size * size) {
      let x = index % size, y = index / size, u = hash(index, 1), v = hash(index, 18)
      if kind == 0 {
        // A 5×5 lit subject covers under 1% of a black, geometry-free frame.
        if abs(x - size / 2) < 3 && abs(y - size / 2) < 3 {
          let mean = SIMD3<Float>(0.8, 0.6, 0.4)
          color.append(SIMD4(mean * (0.3 + 1.4 * u), 1)); albedo.append(SIMD4(0.7, 0.6, 0.5, 1))
          normal.append(SIMD4(0, 0, 1, 0)); reference.append(mean)
        } else {
          color.append(SIMD4(0, 0, 0, 1)); albedo.append(.zero)
          normal.append(SIMD4(0, 0, 0, -1)); reference.append(nil)
        }
      } else if x >= 8 && x < 28 && y >= 8 && y < 28 {
        // An emitter about 80× brighter than the surfaces covers ~10% of the frame.
        color.append(SIMD4(40, 38, 36, 1)); albedo.append(SIMD4(1, 1, 1, 1))
        normal.append(SIMD4(0, 0, 1, 3)); reference.append(nil)
      } else {
        let mean = SIMD3<Float>(0.5, 0.45, 0.4) * (x < size / 2 ? 1 : 0.6)
        color.append(SIMD4(mean * (0.3 + 1.4 * u) * (0.8 + 0.4 * v), 1))
        albedo.append(SIMD4(0.6, 0.55, 0.5, 1))
        normal.append(SIMD4(0, x < size / 2 ? 1 : 0, x < size / 2 ? 0 : 1, 0)); reference.append(mean)
      }
    }
    let c = texture(color, width: size, height: size), a = texture(albedo, width: size, height: size)
    let n = texture(normal, width: size, height: size)
    func error(_ options: OIDNOptions) throws -> Float {
      let image = try OIDNDenoiser.denoise(
        color: c, albedo: a, normal: n, commandQueue: testRenderer.commandQueue,
        progress: OIDNProgress(), options: options)
      var sum: Float = 0, count: Float = 0
      for (index, mean) in reference.enumerated() {
        guard let mean else { continue }
        let p = SIMD3(image.pixels[index].x, image.pixels[index].y, image.pixels[index].z)
        sum += simd_length_squared(p - mean) / simd_length_squared(mean); count += 1
      }
      return (sum / count).squareRoot()
    }
    var automatic = OIDNOptions(); automatic.robustInputScale = false
    var keyed = OIDNOptions(); keyed.robustInputScale = true
    let automaticError = try error(automatic), defaultError = try error(OIDNOptions())
    let keyedError = try error(keyed)
    print("OIDN fixture \(kind): auto \(automaticError), default \(defaultError), robust key \(keyedError)")
    require(defaultError.isFinite && defaultError <= automaticError * 1.1,
      "default OIDN exposure matches automatic scale on fixture \(kind)")
    require(keyedError.isFinite && keyedError <= automaticError * 1.25,
      "opt-in robust OIDN scale is no worse than automatic on fixture \(kind)")
  }
  print("PASS: OIDN automatic input scale and surface-keyed opt-in scale")

  // R-80: the host-memory preflight covers the adapter's own allocations and resident frames.
  let estimate = OIDNDenoiser.hostMemoryBytes(width: 1000, height: 1000) ?? 0
  require(estimate >= 1_000_000 * 132, "OIDN host estimate covers readbacks, OIDN images and results")
  require(OIDNDenoiser.memoryError(width: 4, height: 4) == nil
    && OIDNDenoiser.memoryError(width: 4, height: 4, residentBytes: ProcessInfo.processInfo.physicalMemory) != nil
    && OIDNDenoiser.memoryError(width: Int.max, height: 2) != nil,
    "OIDN host preflight counts resident render memory and rejects overflow")

  // R-82: inspection views never feed stale beauty to OIDN.
  testRenderer.samplingMode = 0
  testRenderer.viewportMode = 1
  renderOneFrame()
  controller.startOIDNPreview()
  require(controller.previewDenoiseJob == nil && testRenderer.offlineDenoisedPreview == nil,
    "OIDN preview is refused in inspection viewport modes")
  testRenderer.viewportMode = 0

  // R-81: Clear is a no-op without a preview and cannot apply a stale pause state.
  testRenderer.paused = false
  controller.oidnPreviewWasPaused = true
  let clearItem = NSMenuItem(title: "", action: #selector(StudioController.clearOIDNAction), keyEquivalent: "")
  require(!controller.validateMenuItem(clearItem), "Clear OIDN Preview is disabled without a preview")
  controller.clearOIDNPreview()
  require(!testRenderer.paused, "clearing without a preview leaves rendering state unchanged")

  // R-81: re-denoising a shown preview keeps the original live state.
  renderOneFrame()
  controller.startOIDNPreview()
  waitUntil({ controller.previewDenoiseJob == nil }, seconds: 45)
  require(testRenderer.offlineDenoisedPreview != nil && controller.validateMenuItem(clearItem),
    "first OIDN preview is shown and clearable")
  controller.startOIDNPreview()
  waitUntil({ controller.previewDenoiseJob == nil }, seconds: 45)
  require(testRenderer.offlineDenoisedPreview != nil, "second OIDN preview is shown")
  controller.clearOIDNPreview()
  require(!testRenderer.paused, "clearing a repeated OIDN preview restores live rendering")

  // R-79: camera gestures cannot move the view while OIDN denoises the frozen frame,
  // and a result for a changed view is discarded.
  renderOneFrame()
  let yaw = testRenderer.yaw
  controller.startOIDNPreview()
  require(controller.previewDenoiseJob != nil, "OIDN preview job starts")
  drag()
  controller.saveTimer?.invalidate() // never autosave from tests
  require(testRenderer.yaw == yaw, "camera gestures are ignored during an OIDN preview job")
  testRenderer.yaw += 0.05 // e.g. a programmatic or resize-driven reset of the frozen view
  waitUntil({ controller.previewDenoiseJob == nil }, seconds: 45)
  require(testRenderer.offlineDenoisedPreview == nil && !testRenderer.paused
    && controller.viewport.renderer === testRenderer,
    "an OIDN preview for a changed view is discarded and live rendering resumes")

  // R-106: cancelling an OIDN preview restores state and drops the late result.
  renderOneFrame()
  controller.startOIDNPreview()
  controller.cancelOIDNPreview()
  RunLoop.main.run(until: Date().addingTimeInterval(1.5))
  require(!controller.isBusy && testRenderer.offlineDenoisedPreview == nil && !testRenderer.paused
    && controller.viewport.renderer === testRenderer,
    "cancelled OIDN preview restores live rendering and discards its result")

  // R-106: cancelling during OIDN export denoising leaves no busy state or file.
  testRenderer.options.outputWidth = 512; testRenderer.options.outputHeight = 384
  testRenderer.options.exportSamples = 1
  controller.exportDenoise = true; controller.exportRaw = false
  let cancelledURL = folder.appendingPathComponent("cancelled.exr")
  try? FileManager.default.removeItem(at: cancelledURL)
  var cancelledDuringOIDN = false
  controller.startExport(url: cancelledURL, hdr: true)
  waitUntil({
    if controller.exportDenoiseJob != nil { controller.cancelExport(); cancelledDuringOIDN = true }
    return controller.exportRenderer == nil
  }, seconds: 45)
  RunLoop.main.run(until: Date().addingTimeInterval(1.5))
  require(cancelledDuringOIDN && !controller.isBusy && controller.exportDenoiseJob == nil
    && !FileManager.default.fileExists(atPath: cancelledURL.path)
    && controller.viewport.renderer === testRenderer && !testRenderer.paused,
    "cancel during OIDN export restores the controller and writes nothing")

  // R-106: controller HDR exports for every source are linear, finite and upright.
  testRenderer.options.outputWidth = 48; testRenderer.options.outputHeight = 32
  testRenderer.options.exportSamples = 4
  testRenderer.denoiserEnabled = true
  let pngURL = folder.appendingPathComponent("orientation.png")
  controller.exportDenoise = false; controller.exportRaw = true
  controller.startExport(url: pngURL, hdr: false)
  waitUntil({ controller.exportRenderer == nil }, seconds: 45)
  let png = NSBitmapImageRep(data: try Data(contentsOf: pngURL))!
  var pngRows = [Float](repeating: 0, count: 32)
  for y in 0..<32 { for x in 0..<48 {
    let color = png.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    pngRows[y] += Float(color.redComponent + color.greenComponent + color.blueComponent)
  }}
  func correlation(_ a: [Float], _ b: [Float]) -> Float {
    let ma = a.reduce(0, +) / Float(a.count), mb = b.reduce(0, +) / Float(b.count)
    var ab: Float = 0, aa: Float = 0, bb: Float = 0
    for i in a.indices { ab += (a[i] - ma) * (b[i] - mb); aa += (a[i] - ma) * (a[i] - ma); bb += (b[i] - mb) * (b[i] - mb) }
    return ab / max(1e-12, (aa * bb).squareRoot())
  }
  var means: [String: Float] = [:]
  let sources: [(String, Bool, Bool)] = [("raw", false, true), ("metalfx", false, false), ("oidn", true, false)]
  for (name, denoise, raw) in sources {
    if name == "metalfx" && !testRenderer.supportsMetalFX { continue }
    controller.exportDenoise = denoise; controller.exportRaw = raw
    let url = folder.appendingPathComponent("controller-\(name).exr")
    try? FileManager.default.removeItem(at: url)
    controller.startExport(url: url, hdr: true)
    waitUntil({ controller.exportRenderer == nil }, seconds: 45)
    guard let image = decodeEXR(url) else { require(false, "\(name) HDR export decodes as float EXR"); continue }
    require(image.width == 48 && image.height == 32, "\(name) HDR export uses output dimensions")
    require(image.pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_reduce_min($0) >= -1e-3 },
      "\(name) HDR export is finite linear radiance")
    means[name] = image.pixels.reduce(Float(0)) { $0 + $1.x + $1.y + $1.z } / Float(image.pixels.count)
    var rows = [Float](repeating: 0, count: 32)
    for (index, pixel) in image.pixels.enumerated() {
      let mapped = pixel / (pixel + 1) // monotone; orientation only
      rows[index / 48] += mapped.x + mapped.y + mapped.z
    }
    require(correlation(rows, pngRows) > correlation(Array(rows.reversed()), pngRows),
      "\(name) HDR export keeps the PNG export's vertical orientation")
  }
  if let raw = means["raw"], raw > 0 {
    for (name, mean) in means {
      require(mean > raw * 0.5 && mean < raw * 2, "\(name) HDR export matches raw radiance level (\(mean) vs \(raw))")
    }
  } else { require(false, "raw HDR export contains radiance") }
  print("PASS: OIDN preview/export state, cancel paths and HDR export sources")

  testRenderer.options = savedOptions; testRenderer.oidnOptions = savedOIDN
  testRenderer.denoiserEnabled = savedDenoise; testRenderer.samplingMode = savedStrategy
  controller.exportDenoise = savedExportDenoise; controller.exportRaw = savedExportRaw
  testRenderer.paused = false
}
try fixOIDNExportChecks()
