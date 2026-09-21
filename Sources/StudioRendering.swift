import Cocoa
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
    guard d > 0.05 else { return }
    distance = min(1000, d)
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
      encoder.setComputePipelineState(pickPipeline)
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
      command.addCompletedHandler { c in
        let value = result.contents().load(as: UInt32.self)
        DispatchQueue.main.async {
          completion(c.status == .completed && value < UInt32(SceneLimits.nodes + SceneLimits.materials) ? Int(value) : nil)
        }
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
      let previewTextures = renderer.materials.uniqueTextureBytes(
        renderer.materials.images + renderer.materials.graphTextures
          + [renderer.materials.environmentTexture])
      let outputPixels = UInt64(p.options.outputWidth).multipliedReportingOverflow(
        by: UInt64(p.options.outputHeight))
      let outputBytes = outputPixels.overflow
        ? UInt64.max
        : outputPixels.partialValue.multipliedReportingOverflow(by: 4).partialValue
      let previewTotal = renderer.residentFrameBytes.addingReportingOverflow(previewTextures)
      let concurrentTotal = previewTotal.partialValue.addingReportingOverflow(outputBytes)
      r.concurrentRenderBytes = previewTotal.overflow || concurrentTotal.overflow
        ? UInt64.max : concurrentTotal.partialValue
      try r.materials.restore(renderer.materials.state())
      try r.materials.setEnvironment(p.environmentData)
      try r.materials.setMesh(p.graph?.renderTriangles() ?? p.triangles)
      r.materials.hasSceneGraph = p.graph != nil
      r.sceneIndex = p.scene
      r.samplingMode = p.strategy
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
        self?.show("Export failed: \(message)")
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
    } catch { show("Export failed: \(error.localizedDescription)") }
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
    renderer.lastTick = Date()
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
      show("Export failed: \(error.localizedDescription)")
    }
  }

  private func beginOfflineDenoise(renderer r: PathTracerRenderer, url: URL) {
    guard exportDenoiseJob == nil, let color = r.accumTexture,
      let albedo = r.oidnAlbedoAccum, let normal = r.oidnNormalAccum
    else { return }
    r.onFrameUpdate = nil
    r.onError = nil
    let job = OIDNProgress()
    exportDenoiseJob = job
    job.onProgress = { [weak self, weak job] fraction in
      DispatchQueue.main.async {
        guard let self, let job, self.exportDenoiseJob === job else { return }
        self.status.stringValue = "OIDN offline denoising: \(Int(fraction * 100))%"
      }
    }
    status.stringValue = "Preparing OIDN offline denoising…"
    DispatchQueue.global(qos: .userInitiated).async { [weak self, weak r, weak job] in
      guard let self, let r, let job else { return }
      do {
        let image = try OIDNDenoiser.denoise(
          color: color, albedo: albedo, normal: normal, commandQueue: r.commandQueue,
          progress: job, options: r.oidnOptions)
        let texture = try image.makeTexture(device: r.device)
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
          self.show("Export failed: \(error.localizedDescription)")
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
        show("Export failed: \(error.localizedDescription)")
      }
      return
    }
    guard let output = exportOutput, let command = r.commandQueue.makeCommandBuffer(),
      r.encodeDisplay(command, display: texture, raw: texture, output: output)
    else {
      cancelExport()
      show("Export failed: could not tone-map the OIDN result.")
      return
    }
    command.addCompletedHandler { [weak self, weak r] completed in
      DispatchQueue.main.async {
        guard let self, let r, self.exportRenderer === r else { return }
        do {
          guard completed.status == .completed else {
            throw MaterialLibrary.error(completed.error?.localizedDescription ?? "OIDN tone mapping failed.")
          }
          try RenderImage.write(texture: output, url: url, hdr: false)
          self.cancelExport()
          self.show("Saved OIDN-denoised \(url.lastPathComponent)")
        } catch {
          self.cancelExport()
          self.show("Export failed: \(error.localizedDescription)")
        }
      }
    }
    command.commit()
  }

  func startOIDNPreview() {
    guard !isBusy else { return }
    guard OIDNDenoiser.isAvailable else {
      show("Open Image Denoise is unavailable. Rebuild the app to install OIDN.")
      return
    }
    guard renderer.completedSamples > 0, let color = renderer.accumTexture,
      let albedo = renderer.oidnAlbedoAccum, let normal = renderer.oidnNormalAccum
    else {
      show("Wait for at least one completed sample before previewing OIDN.")
      return
    }
    let samples = renderer.completedSamples
    oidnPreviewWasPaused = renderer.paused
    renderer.paused = true
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
    DispatchQueue.global(qos: .userInitiated).async { [weak self, weak job] in
      guard let self, let job else { return }
      do {
        let image = try OIDNDenoiser.denoise(
          color: color, albedo: albedo, normal: normal, commandQueue: self.renderer.commandQueue,
          progress: job, options: self.renderer.oidnOptions)
        let texture = try image.makeTexture(device: self.renderer.device)
        DispatchQueue.main.async { [weak self, weak job] in
          guard let self, let job, self.previewDenoiseJob === job else { return }
          self.previewDenoiseJob = nil
          self.renderer.offlineDenoisedPreview = texture
          self.renderer.presentationNeedsRefresh = true
          self.rebuild()
          self.show("Showing OIDN preview of \(samples) spp")
        }
      } catch {
        DispatchQueue.main.async { [weak self, weak job] in
          guard let self, let job, self.previewDenoiseJob === job else { return }
          self.previewDenoiseJob = nil
          self.renderer.paused = self.oidnPreviewWasPaused
          self.renderer.lastTick = Date()
          self.rebuild()
          self.show("OIDN preview failed: \(error.localizedDescription)")
        }
      }
    }
  }

  func cancelOIDNPreview() {
    previewDenoiseJob?.cancel()
    previewDenoiseJob = nil
    renderer.paused = oidnPreviewWasPaused
    renderer.lastTick = Date()
    rebuild()
    show("OIDN preview cancelled")
  }

  func clearOIDNPreview(resume: Bool = false) {
    renderer.offlineDenoisedPreview = nil
    renderer.presentationNeedsRefresh = true
    renderer.paused = resume ? false : oidnPreviewWasPaused
    renderer.lastTick = Date()
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
      show("Could not capture preview.")
      return
    }
    command.addCompletedHandler { [weak self] c in
      DispatchQueue.main.async {
        guard let self, c.status == .completed else { return }
        self.chooseSave("Capture preview", name: "Preview.png", ext: "png") { [weak self] url in
          do {
            try RenderImage.write(texture: output, url: url, hdr: false)
            self?.show("Saved \(url.lastPathComponent)")
          } catch { self?.show(error.localizedDescription) }
        }
      }
    }
    command.commit()
  }
}

// REFERENCES.md: COREIMAGE2026. Linear extended-sRGB EXR, display-referred sRGB PNG.
enum RenderImage {
  static func write(texture: MTLTexture, url: URL, hdr: Bool) throws {
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let input = CIImage(mtlTexture: texture, options: [.colorSpace: hdr ? linear : srgb])
    else { throw MaterialLibrary.error("Could not read the rendered image.") }
    let image = input.oriented(.downMirrored)
    let context = CIContext(mtlDevice: texture.device)
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".vibetracer-\(UUID().uuidString).\(hdr ? "exr":"png")")
    defer { try? FileManager.default.removeItem(at: temporary) }
    if hdr {
      try context.writeOpenEXRRepresentation(of: image, to: temporary, options: [:])
    } else {
      try context.writePNGRepresentation(
        of: image, to: temporary, format: .RGBA8, colorSpace: srgb, options: [:])
    }
    // Atomic replacement, including existing destinations chosen by NSSavePanel.
    try Data(contentsOf: temporary).write(to: url, options: .atomic)
  }
}
