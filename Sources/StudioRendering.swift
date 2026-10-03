import Cocoa
import Compression
import CoreImage
import MetalKit
import simd

func rotateObject(_ point: SIMD3<Float>, _ a: SIMD3<Float>) -> SIMD3<Float> {
  var p = point
  p = SIMD3(p.x, cos(a.x) * p.y - sin(a.x) * p.z, sin(a.x) * p.y + cos(a.x) * p.z)
  p = SIMD3(cos(a.y) * p.x + sin(a.y) * p.z, p.y, -sin(a.y) * p.x + cos(a.y) * p.z)
  return SIMD3(cos(a.z) * p.x - sin(a.z) * p.y, sin(a.z) * p.x + cos(a.z) * p.y, p.z)
}
extension PathTracerRenderer {
  var eyePosition: SIMD3<Float> {
    target
      + SIMD3(
        distance * cos(pitch) * sin(yaw), distance * sin(pitch), -distance * cos(pitch) * cos(yaw))
  }
  func setEye(_ eye: SIMD3<Float>) {
    let delta = eye - target
    let d = simd_length(delta)
    // Same limits as scroll zoom and framing.
    guard d >= 0.0001 else { return }
    distance = min(1_000_000, d)
    pitch = asin(min(0.997, max(-0.997, delta.y / d)))
    yaw = atan2(delta.x, -delta.z)
  }
  func pick(_ pixel: SIMD2<Float>, completion: @escaping (Int?) -> Void) {
    guard var uniforms = lastUniforms else {
      completion(nil)
      return
    }
      guard let result = device.makeBuffer(length: 4, options: .storageModeShared),
        let command = commandQueue.makeCommandBuffer(),
        let encoder = command.makeComputeCommandEncoder()
      else {
        completion(nil)
        return
      }
      var point = pixel
      encoder.setComputePipelineState(sceneKernels.pick)
      guard materials.bind(encoder) else {
        encoder.endEncoding()
        completion(nil)
        return
      }
      encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      encoder.setBuffer(result, offset: 0, index: 3)
      encoder.setBytes(&point, length: 8, index: 4)
      encoder.dispatchThreads(
        MTLSize(width: 1, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
      encoder.endEncoding()
      // Metal calls the handler on its own thread; the result is read on the main actor.
      let finish: @MainActor (Bool) -> Void = { completed in
        let value = result.contents().load(as: UInt32.self)
        completion(completed && value < UInt32(SceneLimits.nodes + SceneLimits.materials) ? Int(value) : nil)
      }
      command.addCompletedHandler { c in
        let completed = c.status == .completed
        DispatchQueue.main.async { finish(completed) }
      }
      command.commit()

  }
}

extension StudioController {
  func beginExport(hdr: Bool) {
    guard !isBusy else { return }
    chooseSave(
      hdr ? "Render HDR OpenEXR" : "Render PNG", name: hdr ? "Render.exr" : "Render.png",
      ext: hdr ? "exr" : "png"
    ) { [weak self] url in self?.startExport(url: url, hdr: hdr) }
  }
  func startExport(url: URL, hdr: Bool) {
    guard !isBusy else { return }
    do {
      if exportDenoise && !OIDNDenoiser.isAvailable {
        throw MaterialLibrary.error(
          "Open Image Denoise is unavailable. Rebuild Metal Vibe Tracer to install the OIDN runtime.")
      }
      let p = snapshot()
      try p.validate()
      let r = try PathTracerRenderer(device: renderer.device, sharing: renderer)
      // The export library shares identical textures with the live preview and
      // counts the preview's set once (external), not as a second copy.
      r.materials.external = renderer.materials.residentSnapshot()
      let outputPixels = UInt64(p.options.outputWidth).multipliedReportingOverflow(
        by: UInt64(p.options.outputHeight))
      let outputBytes = outputPixels.overflow
        ? UInt64.max
        : outputPixels.partialValue.multipliedReportingOverflow(by: 4).partialValue
      let concurrentTotal = renderer.residentFrameBytes.addingReportingOverflow(outputBytes)
      r.concurrentRenderBytes = concurrentTotal.overflow ? UInt64.max : concurrentTotal.partialValue
      try r.materials.restore(renderer.materials.state())
      try r.materials.setEnvironment(p.environmentData)
      try r.materials.setMesh(p)
      r.materials.hasSceneGraph = p.graph != nil
      r.sceneIndex = p.scene
      r.samplingMode = p.strategy
      // The project's ReSTIR modes. Temporal reuse acts only while the view changes and an
      // export accumulates one still view, which renders identically with either mode, so the
      // export keeps reprojection and does not allocate the splatting resources.
      r.spatialNeighbors = p.restirModes.spatialNeighbors
      r.indirectReuse = p.restirModes.indirectReuse
      r.temporalReuse = .reprojection
      r.controlVariates = p.restirModes.controlVariates
      r.sampler = p.restirModes.sampler
      r.lightTransport = p.restirModes.lightTransport
      r.zTemporal = renderer.zTemporal
      r.ptDecorrelation = renderer.ptDecorrelation
      r.ptTemporalWhileAccumulating = renderer.ptTemporalWhileAccumulating
      r.skyMode = p.sky
      r.enableFog = p.fog
      r.enableSMS = p.ring
      r.oidnOptions = p.oidn ?? OIDNOptions()
      r.viewportMode = 0
      r.denoiserEnabled = !exportDenoise && !exportRaw && p.denoise && r.supportsMetalFX
      r.options = p.options
      r.options.previewScale = 1
      r.options.compare = 0
      r.options.maxSamples = p.options.exportSamples
      r.options.timeLimit = 0
      p.camera.apply(r)
      if let message = r.renderMemoryError(width: p.options.outputWidth, height: p.options.outputHeight) {
        throw MaterialLibrary.error(message)
      }
      if exportDenoise {
        // OIDN runs after the render while the export and preview frames stay resident.
        let frames = PathTracerRenderer.FrameResourcePlan(
          width: p.options.outputWidth, height: p.options.outputHeight,
          usesReSTIR: r.samplingMode == 0, usesMetalFX: false, indirectReuse: r.activeIndirectReuse,
          splatting: r.activeTemporalReuse == .splatting).bytes
        let resident = frames.map { $0.addingReportingOverflow(r.concurrentRenderBytes) }
        if let message = OIDNDenoiser.memoryError(
          width: p.options.outputWidth, height: p.options.outputHeight,
          residentBytes: resident.flatMap { $0.overflow ? nil : $0.partialValue } ?? .max)
        {
          throw MaterialLibrary.error(message)
        }
      }
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: p.options.outputWidth, height: p.options.outputHeight,
        mipmapped: false)
      d.storageMode = .private
      d.usage = [.shaderRead, .shaderWrite]
      guard let out = r.device.makeTexture(descriptor: d) else {
        throw MaterialLibrary.error(
          "Could not allocate export image. Reduce the output dimensions.")
      }
      exportRenderer = r
      exportOutput = out
      exportURL = url
      exportHDR = hdr
      previousPaused = renderer.paused
      renderer.paused = true
      // Camera gestures cannot alter the preview while exporting.
      viewport.renderer = nil
      r.onError = { [weak self] message in
        self?.cancelExport()
        self?.showError("Export failed: \(message)")
      }
      let start = Date()
      r.onFrameUpdate = { [weak self, weak r] count in
        guard let self, let r, self.exportRenderer === r else { return }
        self.status.stringValue =
          "Export: \(count) / \(r.options.exportSamples) spp · \(Int(Date().timeIntervalSince(start))) s"
        if count >= r.options.exportSamples {
          self.finishExport()
        } else {
          DispatchQueue.main.async { [weak self, weak r] in
            guard let self, let r, self.exportRenderer === r, let out = self.exportOutput else {
              return
            }
            r.renderFrame(output: out)
          }
        }
      }
      rebuild()
      show("Rendering \(out.width)×\(out.height) export…")
      r.renderFrame(output: out)
    } catch { showError("Export failed: \(error.localizedDescription)") }
  }
  func cancelExport() {
    exportDenoiseJob?.cancel()
    exportDenoiseJob = nil
    exportRenderer?.onFrameUpdate = nil
    exportRenderer?.onError = nil
    exportRenderer = nil
    exportOutput = nil
    exportURL = nil
    renderer.paused = previousPaused
    renderer.lastTick = awakeSeconds()
    viewport.renderer = renderer
    rebuild()
    show("Export cancelled")
  }
  func finishExport() {
    guard let r = exportRenderer, let url = exportURL else { return }
    if exportDenoise {
      beginOfflineDenoise(renderer: r, url: url)
      return
    }
    guard let texture = exportHDR ? r.lastDisplay : exportOutput else { return }
    do {
      try RenderImage.write(texture: texture, url: url, hdr: exportHDR)
      cancelExport()
      show("Saved \(url.lastPathComponent)")
    } catch {
      cancelExport()
      showError("Export failed: \(error.localizedDescription)")
    }
  }

  private func beginOfflineDenoise(renderer r: PathTracerRenderer, url: URL) {
    guard exportDenoiseJob == nil, let color = r.accumTexture,
      let albedo = r.oidnAlbedoAccum, let normal = r.oidnNormalAccum
    else { return }
    r.onFrameUpdate = nil
    r.onError = nil
    let resident = r.residentFrameBytes.addingReportingOverflow(r.concurrentRenderBytes)
    let residentBytes = resident.overflow ? UInt64.max : resident.partialValue
    let job = OIDNProgress()
    exportDenoiseJob = job
    job.onProgress = { [weak self, weak job] fraction in
      DispatchQueue.main.async {
        guard let self, let job, self.exportDenoiseJob === job else { return }
        self.status.stringValue = "OIDN offline denoising: \(Int(fraction * 100))%"
      }
    }
    status.stringValue = "Preparing OIDN offline denoising…"
    // The worker gets snapshots; renderer state is only read on the main actor.
    let input = OIDNInput(color: color, albedo: albedo, normal: normal)
    let queue = r.commandQueue, options = r.oidnOptions
    DispatchQueue.global(qos: .userInitiated).async { [weak self, weak r, weak job] in
      guard self != nil, r != nil, let job else { return }
      do {
        let image = try OIDNDenoiser.denoise(
          color: input.color, albedo: input.albedo, normal: input.normal, commandQueue: queue,
          progress: job, options: options, residentBytes: residentBytes)
        let texture = try image.makeTexture(device: queue.device)
        DispatchQueue.main.async { [weak self, weak r, weak job] in
          guard let self, let r, let job, self.exportDenoiseJob === job,
            self.exportRenderer === r else { return }
          self.writeOfflineDenoised(texture, renderer: r, url: url)
        }
      } catch {
        DispatchQueue.main.async { [weak self, weak r, weak job] in
          guard let self, let r, let job, self.exportDenoiseJob === job,
            self.exportRenderer === r else { return }
          self.cancelExport()
          self.showError("Export failed: \(error.localizedDescription)")
        }
      }
    }
  }

  private func writeOfflineDenoised(_ texture: MTLTexture, renderer r: PathTracerRenderer, url: URL) {
    if exportHDR {
      do {
        try RenderImage.write(texture: texture, url: url, hdr: true)
        cancelExport()
        show("Saved OIDN-denoised \(url.lastPathComponent)")
      } catch {
        cancelExport()
        showError("Export failed: \(error.localizedDescription)")
      }
      return
    }
    guard let output = exportOutput, let command = r.commandQueue.makeCommandBuffer(),
      r.encodeDisplay(command, display: texture, raw: texture, output: output)
    else {
      cancelExport()
      showError("Export failed: could not tone-map the OIDN result.")
      return
    }
    // Metal calls the handler on its own thread; the output is written on the main actor.
    let finish: @MainActor (Bool, String?) -> Void = { [weak self, weak r] completed, failure in
      guard let self, let r, self.exportRenderer === r else { return }
      do {
        guard completed else {
          throw MaterialLibrary.error(failure ?? "OIDN tone mapping failed.")
        }
        try RenderImage.write(texture: output, url: url, hdr: false)
        self.cancelExport()
        self.show("Saved OIDN-denoised \(url.lastPathComponent)")
      } catch {
        self.cancelExport()
        self.showError("Export failed: \(error.localizedDescription)")
      }
    }
    command.addCompletedHandler { completed in
      let succeeded = completed.status == .completed, failure = completed.error?.localizedDescription
      DispatchQueue.main.async { finish(succeeded, failure) }
    }
    command.commit()
  }

  func startOIDNPreview() {
    guard !isBusy else { return }
    guard OIDNDenoiser.isAvailable else {
      showError("Open Image Denoise is unavailable. Rebuild the app to install OIDN.")
      return
    }
    // Inspection views advance the sample counter without writing beauty radiance.
    guard renderer.viewportMode == 0 else {
      show("Switch the viewport to Beauty before previewing OIDN.")
      return
    }
    guard renderer.completedSamples > 0, let color = renderer.accumTexture,
      let albedo = renderer.oidnAlbedoAccum, let normal = renderer.oidnNormalAccum
    else {
      show("Wait for at least one completed sample before previewing OIDN.")
      return
    }
    let samples = renderer.completedSamples
    let generation = renderer.interactionGeneration
    let residentBytes = renderer.residentFrameBytes
    // A shown preview already froze rendering; keep the state saved before it.
    if renderer.offlineDenoisedPreview == nil {
      oidnPreviewWasPaused = renderer.paused
    } else {
      renderer.offlineDenoisedPreview = nil
      renderer.presentationNeedsRefresh = true
    }
    renderer.paused = true
    // Camera gestures cannot move the view away from the frozen accumulation.
    viewport.renderer = nil
    let job = OIDNProgress()
    previewDenoiseJob = job
    job.onProgress = { [weak self, weak job] fraction in
      DispatchQueue.main.async {
        guard let self, let job, self.previewDenoiseJob === job else { return }
        self.status.stringValue = "OIDN preview: \(Int(fraction * 100))%"
      }
    }
    rebuild()
    status.stringValue = "Preparing OIDN preview of \(samples) spp…"
    // The worker gets snapshots; renderer state is only read on the main actor.
    let input = OIDNInput(color: color, albedo: albedo, normal: normal)
    let queue = renderer.commandQueue, options = renderer.oidnOptions
    DispatchQueue.global(qos: .userInitiated).async { [weak self, weak job] in
      guard self != nil, let job else { return }
      do {
        let image = try OIDNDenoiser.denoise(
          color: input.color, albedo: input.albedo, normal: input.normal, commandQueue: queue,
          progress: job, options: options, residentBytes: residentBytes)
        let texture = try image.makeTexture(device: queue.device)
        DispatchQueue.main.async { [weak self, weak job] in
          guard let self, let job, self.previewDenoiseJob === job else { return }
          self.previewDenoiseJob = nil
          self.viewport.renderer = self.renderer
          guard self.renderer.interactionGeneration == generation else {
            self.renderer.paused = self.oidnPreviewWasPaused
            self.renderer.lastTick = awakeSeconds()
            self.rebuild()
            self.show("OIDN preview discarded because the view changed.")
            return
          }
          self.renderer.offlineDenoisedPreview = texture
          self.renderer.presentationNeedsRefresh = true
          self.rebuild()
          self.show("Showing OIDN preview of \(samples) spp")
        }
      } catch {
        DispatchQueue.main.async { [weak self, weak job] in
          guard let self, let job, self.previewDenoiseJob === job else { return }
          self.previewDenoiseJob = nil
          self.viewport.renderer = self.renderer
          self.renderer.paused = self.oidnPreviewWasPaused
          self.renderer.lastTick = awakeSeconds()
          self.rebuild()
          self.showError("OIDN preview failed: \(error.localizedDescription)")
        }
      }
    }
  }

  func cancelOIDNPreview() {
    previewDenoiseJob?.cancel()
    previewDenoiseJob = nil
    viewport.renderer = renderer
    renderer.paused = oidnPreviewWasPaused
    renderer.lastTick = awakeSeconds()
    rebuild()
    show("OIDN preview cancelled")
  }

  func clearOIDNPreview(resume: Bool = false) {
    // oidnPreviewWasPaused is only meaningful while a preview is shown.
    guard renderer.offlineDenoisedPreview != nil else { return }
    renderer.offlineDenoisedPreview = nil
    renderer.presentationNeedsRefresh = true
    renderer.paused = resume ? false : oidnPreviewWasPaused
    renderer.lastTick = awakeSeconds()
    rebuild()
    show(resume ? "Resumed live rendering" : "Cleared OIDN preview")
  }
  func capturePreview() {
    guard !isBusy, let raw = renderer.accumTexture, renderer.lastDisplay != nil
    else {
      show("Wait for the first rendered frame.")
      return
    }
    // Freeze a presentation copy now, so the save panel cannot change its contents.
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: raw.width, height: raw.height, mipmapped: false)
    desc.storageMode = .private
    desc.usage = [.shaderRead, .shaderWrite]
    guard let output = renderer.device.makeTexture(descriptor: desc),
      let command = renderer.commandQueue.makeCommandBuffer(),
      renderer.presentCurrentFrame(command, output: output)
    else {
      showError("Could not capture preview.")
      return
    }
    // Metal calls the handler on its own thread; the copy is saved on the main actor.
    let finish: @MainActor () -> Void = { [weak self] in
      self?.chooseSave("Capture preview", name: "Preview.png", ext: "png") { [weak self] url in
        do {
          try RenderImage.write(texture: output, url: url, hdr: false)
          self?.show("Saved \(url.lastPathComponent)")
        } catch { self?.showError(error.localizedDescription) }
      }
    }
    command.addCompletedHandler { c in
      guard c.status == .completed else { return }
      DispatchQueue.main.async { finish() }
    }
    command.commit()
  }
}

// REFERENCES.md: COREIMAGE2026. Linear extended-sRGB EXR, display-referred sRGB PNG.
enum RenderImage {
  static func write(texture: MTLTexture, url: URL, hdr: Bool) throws {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    // HDR pixels bypass color management and are encoded locally: Core Image's EXR
    // writer is half-float, and ImageIO's EXR encoder color-converts through a
    // quantized matrix that leaks a hot channel into the others.
    let colorSpace: Any = hdr ? NSNull() : srgb
    guard let input = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])
    else { throw MaterialLibrary.error("Could not read the rendered image.") }
    let image = input.oriented(.downMirrored)
    let context = hdr
      ? CIContext(mtlDevice: texture.device, options: [
        .workingColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
      : CIContext(mtlDevice: texture.device)
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".vibetracer-\(UUID().uuidString).\(hdr ? "exr":"png")")
    defer { try? FileManager.default.removeItem(at: temporary) }
    if hdr {
      let width = texture.width, height = texture.height
      let (count, overflow) = width.multipliedReportingOverflow(by: height)
      guard !overflow, count > 0, count <= Int.max / 16 else {
        throw MaterialLibrary.error("The rendered image is too large to encode.")
      }
      var pixels = [SIMD4<Float>](repeating: .zero, count: count)
      pixels.withUnsafeMutableBytes { bytes in
        context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
          bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
      }
      // Radiance is nonnegative, as presentation shows it: a raw ReSTCV accumulation (RESTCV2026)
      // can hold small negative values before it converges, which the file would otherwise keep.
      for index in pixels.indices { pixels[index] = simd_max(pixels[index], .zero) }
      try OpenEXRFloat.encode(pixels, width: width, height: height).write(to: temporary)
    } else {
      try context.writePNGRepresentation(
        of: image, to: temporary, format: .RGBA8, colorSpace: srgb, options: [:])
    }
    // Atomic replacement, including existing destinations chosen by NSSavePanel.
    try Data(contentsOf: temporary).write(to: url, options: .atomic)
  }
}

/// Lets DispatchQueue.concurrentPerform workers write disjoint elements of one buffer.
/// @unchecked: Swift cannot prove that the workers' elements are disjoint; each use states
/// its partition, and concurrentPerform returns only after every worker has finished.
struct DisjointWrites<Element>: @unchecked Sendable {
  let base: UnsafeMutablePointer<Element>
}

// REFERENCES.md: OPENEXRLAYOUT. Single-part scanline OpenEXR with FLOAT (32-bit) R, G, B
// channels, ZIP compression, and Rec. 709 chromaticities. Half-float output would
// clip radiance above 65504.
enum OpenEXRFloat {
  static func encode(_ pixels: [SIMD4<Float>], width: Int, height: Int) throws -> Data {
    guard width > 0, height > 0, pixels.count == width * height, width <= Int(Int32.max) / 192
    else { throw MaterialLibrary.error("Invalid OpenEXR image dimensions.") }
    var header = Data([0x76, 0x2f, 0x31, 0x01, 2, 0, 0, 0])
    func attribute(_ name: String, _ type: String, _ value: Data) {
      header.append(contentsOf: Array(name.utf8) + [0] + Array(type.utf8) + [0])
      append(Int32(value.count), to: &header)
      header.append(value)
    }
    var channels = Data()
    for name in ["B", "G", "R"] { // Channel lists are sorted by name.
      channels.append(contentsOf: Array(name.utf8) + [0])
      append(Int32(2), to: &channels) // FLOAT
      channels.append(contentsOf: [0, 0, 0, 0]) // pLinear + reserved
      append(Int32(1), to: &channels); append(Int32(1), to: &channels)
    }
    channels.append(0)
    var window = Data()
    for value in [0, 0, width - 1, height - 1] { append(Int32(value), to: &window) }
    var chromaticities = Data()
    for value: Float in [0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.3290] {
      append(value, to: &chromaticities)
    }
    var center = Data(); append(Float(0), to: &center); append(Float(0), to: &center)
    var one = Data(); append(Float(1), to: &one)
    attribute("channels", "chlist", channels)
    attribute("chromaticities", "chromaticities", chromaticities)
    attribute("compression", "compression", Data([3])) // ZIP_COMPRESSION, 16 scanlines
    attribute("dataWindow", "box2i", window)
    attribute("displayWindow", "box2i", window)
    attribute("lineOrder", "lineOrder", Data([0])) // INCREASING_Y
    attribute("pixelAspectRatio", "float", one)
    attribute("screenWindowCenter", "v2f", center)
    attribute("screenWindowWidth", "float", one)
    header.append(0)

    let linesPerChunk = 16
    let chunkCount = (height + linesPerChunk - 1) / linesPerChunk
    var chunks = [Data](repeating: Data(), count: chunkCount)
    chunks.withUnsafeMutableBufferPointer { output in
      guard let base = output.baseAddress else { return }
      let output = DisjointWrites(base: base) // Each worker writes only its own chunk.
      DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
        let first = chunk * linesPerChunk, lines = min(linesPerChunk, height - first)
        var raw = [Float](repeating: 0, count: lines * width * 3)
        for line in 0..<lines {
          for channel in 0..<3 { // B, G, R planes per scanline
            let plane = (line * 3 + channel) * width, row = (first + line) * width
            for x in 0..<width { raw[plane + x] = pixels[row + x][2 - channel] }
          }
        }
        let packed = raw.withUnsafeBytes { zipChunk(Array($0)) }
        var block = Data()
        append(Int32(first), to: &block)
        append(Int32(packed.count), to: &block)
        block.append(contentsOf: packed)
        output.base[chunk] = block
      }
    }
    var offset = UInt64(header.count + chunkCount * 8)
    for chunk in chunks {
      append(offset, to: &header)
      offset += UInt64(chunk.count)
    }
    for chunk in chunks { header.append(chunk) }
    return header
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
  private static func append(_ value: Float, to data: inout Data) {
    append(value.bitPattern, to: &data)
  }

  /// OpenEXR ZIP: split even/odd bytes, delta-encode, zlib-compress; stored raw
  /// when compression does not shrink the block.
  private static func zipChunk(_ raw: [UInt8]) -> [UInt8] {
    let count = raw.count
    var shuffled = [UInt8](repeating: 0, count: count)
    let half = (count + 1) / 2
    for index in 0..<count {
      shuffled[index % 2 == 0 ? index / 2 : half + index / 2] = raw[index]
    }
    var previous = Int(shuffled[0])
    for index in 1..<count {
      let current = Int(shuffled[index])
      shuffled[index] = UInt8(truncatingIfNeeded: current - previous + 128 + 256)
      previous = current
    }
    var deflated = [UInt8](repeating: 0, count: count)
    let size = compression_encode_buffer(
      &deflated, count, shuffled, count, nil, COMPRESSION_ZLIB)
    // COMPRESSION_ZLIB emits raw DEFLATE; OpenEXR expects a zlib (RFC 1950) stream.
    guard size > 0, size + 6 < count else { return raw }
    var a: UInt32 = 1, b: UInt32 = 0
    var index = 0
    while index < count {
      let end = min(count, index + 5552)
      for byte in shuffled[index..<end] { a += UInt32(byte); b += a }
      a %= 65521; b %= 65521
      index = end
    }
    let adler = (b << 16) | a
    return [0x78, 0x01] + deflated[0..<size]
      + [UInt8(adler >> 24), UInt8((adler >> 16) & 255), UInt8((adler >> 8) & 255), UInt8(adler & 255)]
  }
}
