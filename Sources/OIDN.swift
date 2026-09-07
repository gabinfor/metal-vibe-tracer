import Darwin
import Foundation
import Metal
import simd

/// Cancellation and progress state retained for the duration of one offline OIDN filter.
final class OIDNProgress {
  private let lock = NSLock()
  private var cancelled = false
  private var lastReported = -1.0
  var onProgress: ((Double) -> Void)?

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  fileprivate func update(_ fraction: Double) -> Bool {
    lock.lock()
    let shouldContinue = !cancelled
    let report = shouldContinue && (fraction >= 1 || fraction - lastReported >= 0.01)
    if report { lastReported = fraction }
    let callback = onProgress
    lock.unlock()
    if report { callback?(fraction) }
    return shouldContinue
  }
}

private let oidnProgressMonitor: @convention(c) (UnsafeMutableRawPointer?, Double) -> Bool = {
  pointer, fraction in
  guard let pointer else { return true }
  return Unmanaged<OIDNProgress>.fromOpaque(pointer).takeUnretainedValue().update(fraction)
}

struct OIDNImage {
  let width: Int
  let height: Int
  let pixels: [SIMD4<Float>]

  func makeTexture(device: MTLDevice) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw MaterialLibrary.error("Could not allocate the OIDN result texture.")
    }
    pixels.withUnsafeBytes { bytes in
      texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: width * 16)
    }
    return texture
  }
}

// REFERENCES.md: OIDN250. Thin dynamic binding to the upstream C99 API.
final class OIDNDenoiser {
  private typealias Handle = UnsafeMutableRawPointer
  private typealias NewDevice = @convention(c) (Int32) -> Handle?
  private typealias ReleaseDevice = @convention(c) (Handle?) -> Void
  private typealias CommitDevice = @convention(c) (Handle?) -> Void
  private typealias GetDeviceError = @convention(c) (Handle?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
  private typealias NewBuffer = @convention(c) (Handle?, Int) -> Handle?
  private typealias GetBufferData = @convention(c) (Handle?) -> UnsafeMutableRawPointer?
  private typealias ReleaseBuffer = @convention(c) (Handle?) -> Void
  private typealias NewFilter = @convention(c) (Handle?, UnsafePointer<CChar>?) -> Handle?
  private typealias ReleaseFilter = @convention(c) (Handle?) -> Void
  private typealias SetFilterImage = @convention(c) (
    Handle?, UnsafePointer<CChar>?, Handle?, Int32, Int, Int, Int, Int, Int
  ) -> Void
  private typealias SetFilterBool = @convention(c) (Handle?, UnsafePointer<CChar>?, Bool) -> Void
  private typealias SetFilterInt = @convention(c) (Handle?, UnsafePointer<CChar>?, Int32) -> Void
  private typealias SetProgress = @convention(c) (
    Handle?, (@convention(c) (UnsafeMutableRawPointer?, Double) -> Bool)?, UnsafeMutableRawPointer?
  ) -> Void
  private typealias CommitFilter = @convention(c) (Handle?) -> Void
  private typealias ExecuteFilter = @convention(c) (Handle?) -> Void

  private final class API {
    let library: UnsafeMutableRawPointer
    let newDevice: NewDevice
    let releaseDevice: ReleaseDevice
    let commitDevice: CommitDevice
    let getDeviceError: GetDeviceError
    let newBuffer: NewBuffer
    let getBufferData: GetBufferData
    let releaseBuffer: ReleaseBuffer
    let newFilter: NewFilter
    let releaseFilter: ReleaseFilter
    let setFilterImage: SetFilterImage
    let setFilterBool: SetFilterBool
    let setFilterInt: SetFilterInt
    let setProgress: SetProgress
    let commitFilter: CommitFilter
    let executeFilter: ExecuteFilter

    init() throws {
      let manager = FileManager.default
      var candidates: [URL] = []
      if let frameworks = Bundle.main.privateFrameworksURL {
        candidates.append(frameworks.appendingPathComponent("OIDN/lib/libOpenImageDenoise.2.dylib"))
      }
      candidates.append(URL(fileURLWithPath: manager.currentDirectoryPath)
        .appendingPathComponent("build/OIDN/lib/libOpenImageDenoise.2.dylib"))
      guard let path = candidates.first(where: { manager.fileExists(atPath: $0.path) }) else {
        throw MaterialLibrary.error("Open Image Denoise is not installed in this application bundle. Rebuild the app to prepare OIDN.")
      }
      guard let library = dlopen(path.path, RTLD_NOW | RTLD_LOCAL) else {
        let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
        throw MaterialLibrary.error("Could not load Open Image Denoise: \(detail)")
      }
      self.library = library

      func load<T>(_ name: String, _ type: T.Type) throws -> T {
        guard let address = dlsym(library, name) else {
          throw MaterialLibrary.error("The Open Image Denoise runtime is missing \(name).")
        }
        return unsafeBitCast(address, to: type)
      }
      do {
        newDevice = try load("oidnNewDevice", NewDevice.self)
        releaseDevice = try load("oidnReleaseDevice", ReleaseDevice.self)
        commitDevice = try load("oidnCommitDevice", CommitDevice.self)
        getDeviceError = try load("oidnGetDeviceError", GetDeviceError.self)
        newBuffer = try load("oidnNewBuffer", NewBuffer.self)
        getBufferData = try load("oidnGetBufferData", GetBufferData.self)
        releaseBuffer = try load("oidnReleaseBuffer", ReleaseBuffer.self)
        newFilter = try load("oidnNewFilter", NewFilter.self)
        releaseFilter = try load("oidnReleaseFilter", ReleaseFilter.self)
        setFilterImage = try load("oidnSetFilterImage", SetFilterImage.self)
        setFilterBool = try load("oidnSetFilterBool", SetFilterBool.self)
        setFilterInt = try load("oidnSetFilterInt", SetFilterInt.self)
        setProgress = try load("oidnSetFilterProgressMonitorFunction", SetProgress.self)
        commitFilter = try load("oidnCommitFilter", CommitFilter.self)
        executeFilter = try load("oidnExecuteFilter", ExecuteFilter.self)
      } catch {
        dlclose(library)
        throw error
      }
    }

    deinit { dlclose(library) }
  }

  private struct Readback {
    let buffer: MTLBuffer
    let rowBytes: Int
    let pixelBytes: Int
    let half: Bool

    func pixel(_ index: Int, width: Int) -> SIMD4<Float> {
      let offset = (index / width) * rowBytes + (index % width) * pixelBytes
      var value = SIMD4<Float>(0, 0, 0, 1)
      for channel in 0..<4 {
        if half {
          let bits = buffer.contents().load(fromByteOffset: offset + channel * 2, as: UInt16.self)
          value[channel] = Float(Float16(bitPattern: bits))
        } else {
          value[channel] = buffer.contents().load(fromByteOffset: offset + channel * 4, as: Float.self)
        }
      }
      return value
    }
  }

  private static func readback(
    _ textures: [MTLTexture], queue: MTLCommandQueue
  ) throws -> [Readback] {
    guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
      throw MaterialLibrary.error("Could not begin OIDN guide readback.")
    }
    var reads: [Readback] = []
    for texture in textures {
      let half: Bool
      switch texture.pixelFormat {
      case .rgba16Float: half = true
      case .rgba32Float: half = false
      default:
        blit.endEncoding()
        throw MaterialLibrary.error("OIDN received an unsupported render texture format.")
      }
      let pixelBytes = half ? 8 : 16
      let rowBytes = (texture.width * pixelBytes + 255) & ~255
      guard let buffer = texture.device.makeBuffer(
        length: rowBytes * texture.height, options: .storageModeShared)
      else {
        blit.endEncoding()
        throw MaterialLibrary.error("Could not allocate memory for OIDN guide readback.")
      }
      blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
        sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
        to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
        destinationBytesPerImage: rowBytes * texture.height)
      reads.append(Readback(buffer: buffer, rowBytes: rowBytes, pixelBytes: pixelBytes, half: half))
    }
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else {
      throw MaterialLibrary.error(command.error?.localizedDescription ?? "OIDN guide readback failed.")
    }
    return reads
  }

  static var isAvailable: Bool {
    (try? API()) != nil
  }

  static func denoise(
    color: MTLTexture, albedo: MTLTexture, normal: MTLTexture,
    commandQueue: MTLCommandQueue, progress: OIDNProgress
  ) throws -> OIDNImage {
    guard color.width == albedo.width, color.height == albedo.height,
      color.width == normal.width, color.height == normal.height
    else { throw MaterialLibrary.error("OIDN color and guide dimensions do not match.") }
    let width = color.width, height = color.height
    let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
    guard !overflow, pixelCount > 0, pixelCount <= Int.max / 48 else {
      throw MaterialLibrary.error("The requested OIDN image is too large.")
    }
    // Four float3 images plus Metal readback and OIDN's internal workspace.
    let estimated = UInt64(pixelCount) * 80
    guard estimated < ProcessInfo.processInfo.physicalMemory / 2 else {
      throw MaterialLibrary.error("This OIDN export needs too much system memory. Reduce the output dimensions.")
    }

    let reads = try readback([color, albedo, normal], queue: commandQueue)
    guard progress.update(0) else { throw MaterialLibrary.error("OIDN denoising was cancelled.") }
    let api = try API()
    guard let device = api.newDevice(0) else {
      var message: UnsafePointer<CChar>?
      _ = api.getDeviceError(nil, &message)
      throw MaterialLibrary.error(message.map { String(cString: $0) } ?? "OIDN could not create a device.")
    }
    defer { api.releaseDevice(device) }
    api.commitDevice(device)
    try check(api, device, "initializing OIDN")

    let imageBytes = pixelCount * 12
    func buffer(_ label: String) throws -> Handle {
      guard let result = api.newBuffer(device, imageBytes), api.getBufferData(result) != nil else {
        try check(api, device, "allocating the OIDN \(label) buffer")
        throw MaterialLibrary.error("OIDN could not allocate its \(label) buffer.")
      }
      return result
    }
    let colorBuffer = try buffer("color"); defer { api.releaseBuffer(colorBuffer) }
    let albedoBuffer = try buffer("albedo"); defer { api.releaseBuffer(albedoBuffer) }
    let normalBuffer = try buffer("normal"); defer { api.releaseBuffer(normalBuffer) }
    let outputBuffer = try buffer("output"); defer { api.releaseBuffer(outputBuffer) }
    let colorData = api.getBufferData(colorBuffer)!.assumingMemoryBound(to: Float.self)
    let albedoData = api.getBufferData(albedoBuffer)!.assumingMemoryBound(to: Float.self)
    let normalData = api.getBufferData(normalBuffer)!.assumingMemoryBound(to: Float.self)

    for index in 0..<pixelCount {
      if index % 65_536 == 0, !progress.update(0) {
        throw MaterialLibrary.error("OIDN denoising was cancelled.")
      }
      let sourceColor = reads[0].pixel(index, width: width)
      let sourceAlbedo = reads[1].pixel(index, width: width)
      let sourceNormal = reads[2].pixel(index, width: width)
      var n = SIMD3<Float>(sourceNormal.x, sourceNormal.y, sourceNormal.z)
      n = simd_length_squared(n) > 1e-12 ? simd_normalize(n) : .zero
      for channel in 0..<3 {
        let c = sourceColor[channel]
        colorData[index * 3 + channel] = c.isFinite ? max(0, c) : 0
        let a = sourceAlbedo[channel]
        albedoData[index * 3 + channel] = a.isFinite ? min(1, max(0, a)) : 0
        normalData[index * 3 + channel] = n[channel].isFinite ? n[channel] : 0
      }
    }

    let filter = "RT".withCString { api.newFilter(device, $0) }
    guard let filter else {
      try check(api, device, "creating the OIDN filter")
      throw MaterialLibrary.error("OIDN could not create its ray-tracing filter.")
    }
    defer { api.releaseFilter(filter) }
    func setImage(_ name: String, _ buffer: Handle) {
      name.withCString {
        api.setFilterImage(filter, $0, buffer, 3, width, height, 0, 12, width * 12)
      }
    }
    setImage("color", colorBuffer)
    setImage("albedo", albedoBuffer)
    setImage("normal", normalBuffer)
    setImage("output", outputBuffer)
    "hdr".withCString { api.setFilterBool(filter, $0, true) }
    // The per-frame guides contain stochastic edge coverage, so let OIDN prefilter them.
    "cleanAux".withCString { api.setFilterBool(filter, $0, false) }
    "quality".withCString { api.setFilterInt(filter, $0, 6) } // OIDN_QUALITY_HIGH
    api.setProgress(filter, oidnProgressMonitor, Unmanaged.passUnretained(progress).toOpaque())
    api.commitFilter(filter)
    try check(api, device, "committing the OIDN filter")
    api.executeFilter(filter)
    try check(api, device, "executing the OIDN filter")
    guard progress.update(1) else { throw MaterialLibrary.error("OIDN denoising was cancelled.") }

    let outputData = api.getBufferData(outputBuffer)!.assumingMemoryBound(to: Float.self)
    var pixels = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: pixelCount)
    for index in 0..<pixelCount {
      pixels[index] = SIMD4(
        outputData[index * 3], outputData[index * 3 + 1], outputData[index * 3 + 2], 1)
    }
    return OIDNImage(width: width, height: height, pixels: pixels)
  }

  private static func check(_ api: API, _ device: Handle?, _ context: String) throws {
    var message: UnsafePointer<CChar>?
    let code = api.getDeviceError(device, &message)
    guard code == 0 else {
      let detail = message.map { String(cString: $0) } ?? "error code \(code)"
      throw MaterialLibrary.error("Error while \(context): \(detail)")
    }
  }
}
