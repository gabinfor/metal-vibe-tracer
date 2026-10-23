import Cocoa
import CryptoKit

// REFERENCES.md: MCGUIRE2017, OBJ2026, MTL2026, SHA256FIPS. Example scenes from Morgan McGuire's Computer
// Graphics Archive. Nothing is bundled: File > Open Example Scene downloads an archive only after the user
// agrees to its size and license, checks it against the size and SHA-256 digest pinned below, extracts it
// into Application Support and imports it through ProjectDocument.appendOBJ, unchanged, with the camera and
// lighting of the README image (the scripts/showcase.json shot of the same name, ShowcaseShot).

// One archive of the McGuire archive and the folder it extracts into, relative to its scene's storage folder.
struct ExampleArchive: Sendable, Equatable {
  var name: String
  var url: URL
  var folder: String
  var bytes: Int64
  var unpackedBytes: Int64
  var sha256: String
}

struct ExampleScene: Sendable {
  // The scripts/showcase.json shot giving the camera, sky, sun, exposure and emission of the README image.
  var shot: String
  var title: String
  var summary: String
  // Folder under ExampleLibrary.root; Bistro's exterior and interior share theirs, and its texture archives.
  var storage: String
  var obj: String
  var archives: [ExampleArchive]
  var credit: String
  var license: String
  var licenseURL: URL

  // The credited work: Bistro's exterior and interior are one scene.
  var work: String { title.components(separatedBy: " (")[0] }
  var attribution: String {
    "\(title): \(credit), from Morgan McGuire's Computer Graphics Archive (casual-effects.com/data). "
      + "\(license) (\(licenseURL.absoluteString)). Renders of it are adapted works and must credit it."
  }
}

enum ExampleScenes {
  static let archiveURL = URL(string: "https://casual-effects.com/data/")!
  private static let base = "https://casual-effects.com/g3d/data10/"
  private static func archive(_ name: String, _ path: String, folder: String, _ bytes: Int64, unpacked: Int64,
                              _ sha256: String) -> ExampleArchive {
    ExampleArchive(name: name, url: URL(string: base + path)!, folder: folder, bytes: bytes, unpackedBytes: unpacked,
                   sha256: sha256)
  }
  // Sizes and digests of the archives downloaded on 2026-10-20 (REFERENCES.md MCGUIRE2017).
  static let bistroTextures = [
    archive("BuildingTextures.zip", "research/model/bistro/BuildingTextures", folder: "BuildingTextures", 507_671_451,
            unpacked: 508_329_182, "16538a37f34cadec5665d97e5b77ef3581d67ab674b33b9caeef1d277cbde6bf"),
    archive("OtherTextures.zip", "research/model/bistro/OtherTextures", folder: "OtherTextures", 431_016_313,
            unpacked: 431_592_637, "0806fee3eeb0e14cd501582edbd2d5caf33c5416a62a871e0f126391096f5c58"),
    archive("PropTextures.zip", "research/model/bistro/PropTextures", folder: "PropTextures", 415_421_476,
            unpacked: 416_385_050, "a179e4ee6367d2b518c4978d7e2e690c59503861634d67d0da8bacfa7196571a"),
  ]
  static let cc30 = URL(string: "https://creativecommons.org/licenses/by/3.0/")!
  static let cc40 = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
  static let bistroCredit = "© 2017 Amazon Lumberyard"
  static let catalog = [
    ExampleScene(
      shot: "sponza-noon", title: "Crytek Sponza", summary: "262 k triangles, at noon", storage: "sponza",
      obj: "sponza.obj",
      archives: [archive("sponza.zip", "common/model/crytek_sponza/sponza.zip", folder: "", 80_113_441,
                         unpacked: 95_882_276, "da005cbee0be2df2abc8513f3ceb61bcb6f69aac112babcd9c00169a27c2770c")],
      credit: "© 2010 Frank Meinl, Crytek", license: "CC BY 3.0", licenseURL: cc30),
    ExampleScene(
      shot: "san-miguel-golden", title: "San Miguel 2.0", summary: "10 M triangles, at golden hour",
      storage: "San_Miguel", obj: "san-miguel.obj",
      archives: [archive("San_Miguel.zip", "research/model/San_Miguel/San_Miguel.zip", folder: "", 535_519_642,
                         unpacked: 1_910_092_684, "85874077735808150e679b3c71d70a37a270cb8833f4911325aa1099da3f7d4a")],
      credit: "© Guillermo M. Leal Llaguno", license: "CC BY 3.0", licenseURL: cc30),
    ExampleScene(
      shot: "bistro-exterior-golden", title: "Amazon Lumberyard Bistro (exterior)",
      summary: "2.8 M triangles, in daylight", storage: "bistro", obj: "Exterior/exterior.obj",
      archives: [archive("Exterior.zip", "research/model/bistro/Exterior.zip", folder: "Exterior", 64_186_766,
                         unpacked: 311_371_057, "f612ba0d8a65811afe0d48a023d31e5b43ac40b78e9b12d15e2b7dc8923c29d4")]
        + bistroTextures,
      credit: bistroCredit, license: "CC BY 4.0", licenseURL: cc40),
    ExampleScene(
      shot: "bistro-interior", title: "Amazon Lumberyard Bistro (interior)",
      summary: "1.0 M triangles, in the evening", storage: "bistro", obj: "Interior/interior.obj",
      archives: [archive("Interior.zip", "research/model/bistro/Interior.zip", folder: "Interior", 21_293_389,
                         unpacked: 108_416_959, "3faa41f8d6860d1267268348d44d2b74c64a8bfb55dd4b03c562a70ab83b1062")]
        + bistroTextures,
      credit: bistroCredit, license: "CC BY 4.0", licenseURL: cc40),
  ]
  // One line per credited work, for the credits sheet and the File inspector.
  static var credits: [String] {
    var seen = Set<String>()
    return catalog.filter { seen.insert($0.work).inserted }.map {
      "\($0.work) \($0.credit). \($0.license), \($0.licenseURL.absoluteString)."
    }
  }
  static func megabytes(_ bytes: Int64) -> String {
    bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(Int((Double(bytes) / 1e6).rounded())) MB"
  }
}

// The extracted scenes: <root>/<storage>/<folder>, with one marker per installed archive holding its digest.
struct ExampleLibrary: Sendable {
  var root: URL
  static var defaultRoot: URL {
    (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("VibeTracer/Example Scenes", isDirectory: true)
  }
  init(root: URL = ExampleLibrary.defaultRoot) { self.root = root }
  func storage(_ scene: ExampleScene) -> URL { root.appendingPathComponent(scene.storage, isDirectory: true) }
  func objURL(_ scene: ExampleScene) -> URL { storage(scene).appendingPathComponent(scene.obj) }
  func marker(_ archive: ExampleArchive, storage: String) -> URL {
    root.appendingPathComponent(storage, isDirectory: true).appendingPathComponent(".\(archive.name).installed")
  }
  func isInstalled(_ archive: ExampleArchive, storage: String) -> Bool {
    (try? String(contentsOf: marker(archive, storage: storage), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) == archive.sha256
  }
  func missing(_ scene: ExampleScene) -> [ExampleArchive] {
    scene.archives.filter { !isInstalled($0, storage: scene.storage) }
  }
  func downloadBytes(_ scene: ExampleScene) -> Int64 { missing(scene).reduce(0) { $0 + $1.bytes } }
  func diskBytes(_ scene: ExampleScene) -> Int64 { missing(scene).reduce(0) { $0 + $1.unpackedBytes } }
}

// Downloads, verifies and extracts a scene's missing archives on the calling (background) thread.
// cancel() from any thread stops the transfer or the extraction; completed archives stay installed.
final class ExampleSceneDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var task: URLSessionDownloadTask?
  private var process: Process?
  private var received: (file: URL?, error: Error?) = (nil, nil)
  private var partial: URL?
  private var completed: Int64 = 0, total: Int64 = 0, current = "", lastReport: TimeInterval = 0
  private let finished = DispatchSemaphore(value: 0)
  // Fraction of the bytes to download and a status line; called on URLSession's delegate queue and the worker.
  let progress: @Sendable (Double, String) -> Void
  init(progress: @escaping @Sendable (Double, String) -> Void) { self.progress = progress }

  static func failure(_ message: String) -> Error { MaterialLibrary.error(message) }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func cancel() {
    lock.lock()
    cancelled = true
    let running = (task, process)
    lock.unlock()
    running.0?.cancel()
    if running.1?.isRunning == true { running.1?.terminate() }
  }
  private func checkCancelled() throws {
    if isCancelled { throw Self.failure("Example scene download cancelled.") }
  }

  func install(_ scene: ExampleScene, into library: ExampleLibrary) throws {
    let archives = library.missing(scene)
    lock.lock()
    total = archives.reduce(0) { $0 + $1.bytes }
    completed = 0
    lock.unlock()
    let storage = library.storage(scene)
    let downloads = library.root.appendingPathComponent(".downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    let needed = library.downloadBytes(scene) + library.diskBytes(scene)
    if let free = try? library.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage, free < needed
    {
      throw Self.failure(
        "\(scene.title) needs \(ExampleScenes.megabytes(needed)) of free disk space while it downloads and extracts; "
          + "\(ExampleScenes.megabytes(free)) is available.")
    }
    let session = URLSession(configuration: Self.configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    for (index, archive) in archives.enumerated() {
      try checkCancelled()
      let label = "\(archive.name) (\(index + 1) of \(archives.count))"
      let file = downloads.appendingPathComponent(archive.name)
      try download(archive, to: file, label: label, session: session)
      defer { try? FileManager.default.removeItem(at: file) }
      lock.lock()
      completed += archive.bytes
      lock.unlock()
      report("Verifying \(label)…")
      try Self.installDownloaded(file, archive: archive, storage: storage, library: library, job: self) { [weak self] in
        self?.report("Extracting \(label)…")
      }
    }
  }
  static var configuration: URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 6 * 3600
    configuration.waitsForConnectivity = false
    return configuration
  }
  private func report(_ message: String, received: Int64 = 0) {
    lock.lock()
    let fraction = total > 0 ? Double(completed + received) / Double(total) : 1
    lock.unlock()
    progress(min(1, fraction), message)
  }
  private func download(_ archive: ExampleArchive, to file: URL, label: String, session: URLSession) throws {
    try? FileManager.default.removeItem(at: file)
    lock.lock()
    received = (nil, nil)
    partial = file
    current = label
    guard !cancelled else {
      lock.unlock()
      throw Self.failure("Example scene download cancelled.")
    }
    // A cancel() from here on cancels the task, which then completes with an error.
    let task = session.downloadTask(with: archive.url)
    self.task = task
    lock.unlock()
    report("Downloading \(label)…")
    task.resume()
    finished.wait()
    lock.lock()
    let result = received
    self.task = nil
    lock.unlock()
    try checkCancelled()
    if let error = result.error { throw error }
    guard result.file != nil else { throw Self.failure("\(archive.name) did not download.") }
  }

  // Checks a downloaded archive against its pinned size and digest, extracts it into a staging folder
  // beside the destination, moves its top-level items into place and records the marker.
  static func installDownloaded(_ file: URL, archive: ExampleArchive, storage: URL, library: ExampleLibrary,
                                job: ExampleSceneDownload? = nil, extracting: () -> Void = {}) throws {
    try verify(file, bytes: archive.bytes, sha256: archive.sha256, name: archive.name, job: job)
    extracting()
    let manager = FileManager.default
    let destination = archive.folder.isEmpty ? storage : storage.appendingPathComponent(archive.folder, isDirectory: true)
    let staging = storage.appendingPathComponent(".\(archive.name).extracting", isDirectory: true)
    try? manager.removeItem(at: staging)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: staging) }
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", file.path, staging.path]
    ditto.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    ditto.standardError = errors
    if let job {
      job.lock.lock()
      let stop = job.cancelled
      if !stop { job.process = ditto }
      job.lock.unlock()
      if stop { throw failure("Example scene download cancelled.") }
    }
    try ditto.run()
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    ditto.waitUntilExit()
    if let job {
      job.lock.lock()
      job.process = nil
      job.lock.unlock()
      try job.checkCancelled()
    }
    guard ditto.terminationStatus == 0 else {
      throw failure("\(archive.name) could not be extracted: \(String(decoding: message, as: UTF8.self))")
    }
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    for item in try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
      let target = destination.appendingPathComponent(item.lastPathComponent)
      try? manager.removeItem(at: target)
      try manager.moveItem(at: item, to: target)
    }
    try Data((archive.sha256 + "\n").utf8).write(
      to: library.marker(archive, storage: storage.lastPathComponent), options: .atomic)
  }
  static func verify(_ file: URL, bytes: Int64, sha256: String, name: String, job: ExampleSceneDownload? = nil) throws {
    let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1
    guard size == bytes else {
      throw failure("\(name) has \(size) bytes, not the expected \(bytes); the archive on the server may have changed.")
    }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while true {
      try job?.checkCancelled()
      let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
      guard let chunk, !chunk.isEmpty else { break }
      hash.update(data: chunk)
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == sha256 else {
      throw failure("\(name)'s SHA-256 digest \(digest) differs from the expected \(sha256).")
    }
  }

  // URLSessionDownloadDelegate, on the session's delegate queue.
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    lock.lock()
    let file = partial
    lock.unlock()
    var result: (URL?, Error?) = (nil, nil)
    if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
      result.1 = Self.failure("\(downloadTask.originalRequest?.url?.absoluteString ?? "The server") answered HTTP \(status).")
    } else if let file {
      // The temporary file is removed when this method returns.
      do {
        try FileManager.default.moveItem(at: location, to: file)
        result.0 = file
      } catch { result.1 = error }
    }
    lock.lock()
    received = result
    lock.unlock()
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    // At most ten updates a second reach the main thread.
    let now = awakeSeconds()
    lock.lock()
    let label = current, due = now - lastReport >= 0.1
    if due { lastReport = now }
    lock.unlock()
    guard due else { return }
    report("Downloading \(label): \(ExampleScenes.megabytes(totalBytesWritten)) of "
      + "\(ExampleScenes.megabytes(max(totalBytesExpectedToWrite, totalBytesWritten)))", received: totalBytesWritten)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    if let error, received.error == nil { received.error = error }
    lock.unlock()
    finished.signal()
  }
}

// A shot of scripts/showcase.json: the README images' scene, camera, lens, lighting and output settings.
// scripts/render_showcase.py renders them; File > Open Example Scene opens the McGuire archive ones.
struct ShowcaseShot: Decodable, Sendable {
  var name: String
  var scene: UInt32?
  var project: String?
  var usd: String?
  var obj: String?
  var hdri: String?
  var sky: UInt32?
  var fog: UInt32?
  var ring: UInt32?
  var strategy: UInt32?
  var lightTransport: UInt32?
  var yaw: Float?, pitch: Float?, distance: Float?, fov: Float?
  var target: [Float]?
  var aperture: Float?, focusDistance: Float?
  var exposure: Float?, toneMap: Float?
  var sunAzimuth: Float?, sunElevation: Float?, sunIntensity: Float?
  var environmentIntensity: Float?, environmentRotation: Float?
  var lightIntensity: Float?, lightSize: Float?
  var lightSpectrum: UInt32?, sunSpectrum: UInt32?
  var lightColor: [Float]?
  var width: Int?, height: Int?
  var samples: UInt32?
  var depth: Float?
  // Raw linear radiance as OpenEXR, without a denoiser (renderer comparisons).
  var raw: Bool?
  // Scales the imported scene's emission (lamps, signs, emissive glass): 0 switches it off for a daylight
  // shot, above 1 brightens it for a night shot, since MTL emission has no absolute scale.
  var emissionScale: Float?

  static func load(_ url: URL) throws -> [ShowcaseShot] {
    try JSONDecoder().decode([ShowcaseShot].self, from: Data(contentsOf: url))
  }
  // The bundled copy of scripts/showcase.json (the repository's in test builds).
  static func bundled() throws -> [ShowcaseShot] {
    guard let url = runtimeResourceURL(bundled: Bundle.main.url(forResource: "showcase", withExtension: "json"),
                                       repositoryPath: "scripts/showcase.json")
    else { throw MaterialLibrary.error("showcase.json is missing from the application bundle.") }
    return try load(url)
  }

  // Everything but the scene source (scene, usd, obj, project, hdri) and the export mode (raw).
  func apply(to p: inout ProjectDocument) {
    if let k = emissionScale { p.scaleImportedEmission(by: k) }
    if let v = sky { p.sky = v }
    if let v = fog { p.fog = v }
    if let v = ring { p.ring = v }
    if let v = strategy { p.strategy = v }
    if let v = lightTransport { p.lightTransport = v }
    if let v = yaw { p.camera.yaw = v }
    if let v = pitch { p.camera.pitch = v }
    if let v = distance { p.camera.distance = v }
    if let v = fov { p.camera.fov = v }
    if let v = target, v.count == 3 { p.camera.target = SIMD3<Float>(v[0], v[1], v[2]) }
    if let v = aperture { p.options.aperture = v }
    if let v = focusDistance { p.options.focusDistance = v }
    if let v = exposure { p.options.exposure = v }
    if let v = toneMap { p.options.toneMap = v }
    if let v = sunAzimuth { p.options.sunAzimuth = v }
    if let v = sunElevation { p.options.sunElevation = v }
    if let v = sunIntensity { p.options.sunIntensity = v }
    if let v = environmentIntensity { p.options.environmentIntensity = v }
    if let v = environmentRotation { p.options.environmentRotation = v }
    if let v = lightIntensity { p.options.lightIntensity = v }
    if let v = lightSize { p.options.lightSize = v }
    if let v = lightSpectrum { p.options.lightSpectrum = v }
    if let v = sunSpectrum { p.options.sunSpectrum = v }
    if let v = lightColor, v.count == 3 { p.options.lightColor = SIMD3<Float>(v[0], v[1], v[2]) }
    if let v = width { p.options.outputWidth = v }
    if let v = height { p.options.outputHeight = v }
    if let v = samples { p.options.exportSamples = v }
    if let v = depth { p.options.depth = v }
  }
}

extension ProjectDocument {
  // Multiplies the Imported Mesh Studio's emission (MaterialX emission registers and constant MTL Ke) by k;
  // 0 removes it. A program without room for the two extra instructions keeps its emission; returns their count.
  @discardableResult mutating func scaleImportedEmission(by k: Float) -> Int {
    guard var state = scenes[6] else { return 0 }
    var unscaled = 0
    for (slot, var program) in state.materialX ?? [:] {
      guard let root = program.emission else { continue }
      if k == 0 {
        program.emission = nil
      } else if program.instructions.count + 2 <= 64 {
        var constant = GraphInstruction()
        constant.value = SIMD4(repeating: k)
        program.instructions.append(constant)
        // Opcode 3 multiplies registers A and B (MaterialX `multiply`).
        program.instructions.append(GraphInstruction(code: SIMD4(3, root, Int32(program.instructions.count - 1), 0)))
        program.emission = Int32(program.instructions.count - 1)
      } else {
        unscaled += 1
      }
      state.materialX?[slot] = program
    }
    state.emissions = state.emissions?.mapValues { $0 * k }
    scenes[6] = state
    return unscaled
  }
}

// File > Open Example Scene and the File inspector's Example scenes section.
extension StudioController {
  func exampleSceneTitle(_ scene: ExampleScene) -> String {
    let download = exampleLibrary.downloadBytes(scene)
    return download > 0 ? "\(scene.title) — \(ExampleScenes.megabytes(download)) download…" : "\(scene.title)"
  }
  func openExampleScene(_ index: Int) {
    guard !isBusy, ExampleScenes.catalog.indices.contains(index) else { return }
    confirmDiscardingChanges { [weak self] in self?.confirmExampleDownload(ExampleScenes.catalog[index]) }
  }
  // Nothing is downloaded without this consent sheet, which names the size, source, destination and license.
  func confirmExampleDownload(_ scene: ExampleScene) {
    guard !isBusy, let window = hostWindow else { return }
    let library = exampleLibrary
    let download = library.downloadBytes(scene)
    guard download > 0 else {
      beginExampleImport(scene)
      return
    }
    let parts = library.missing(scene).count
    let alert = NSAlert()
    alert.messageText = "Download \(scene.title)?"
    alert.informativeText = """
      This example scene is not included with Metal Vibe Tracer. Opening it downloads \(ExampleScenes.megabytes(download)) \
      (\(parts) archive\(parts == 1 ? "" : "s")) from Morgan McGuire's Computer Graphics Archive (casual-effects.com) \
      and uses about \(ExampleScenes.megabytes(library.diskBytes(scene))) of disk space in \
      \((library.root.path as NSString).abbreviatingWithTildeInPath). Each archive is checked against its expected size \
      and SHA-256 digest before it is extracted.

      \(scene.title) \(scene.credit). \(scene.license), \(scene.licenseURL.absoluteString). Images rendered from it \
      are adapted works and must credit it.
      """
    alert.addButton(withTitle: "Download \(ExampleScenes.megabytes(download))")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      // Present the progress sheet after this one has been ordered out.
      DispatchQueue.main.async { self?.beginExampleDownload(scene) }
    }
  }
  func beginExampleDownload(_ scene: ExampleScene) {
    guard !isBusy, let window = hostWindow else { return }
    let library = exampleLibrary
    let sheet = NSAlert()
    sheet.messageText = "Downloading \(scene.title)"
    sheet.informativeText = "Connecting to casual-effects.com…"
    let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 320, height: 20))
    bar.style = .bar
    bar.isIndeterminate = false
    bar.minValue = 0
    bar.maxValue = 1
    sheet.accessoryView = bar
    sheet.addButton(withTitle: "Cancel")
    let job = ExampleSceneDownload { fraction, message in
      DispatchQueue.main.async {
        bar.doubleValue = fraction
        sheet.informativeText = message
      }
    }
    importInProgress = true
    exampleDownload = job
    beginProjectActivity("Downloading \(scene.title)…")
    sheet.beginSheetModal(for: window) { _ in job.cancel() }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try job.install(scene, into: library) }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let cancelled = job.isCancelled
        window.endSheet(sheet.window)
        self.importInProgress = false
        self.exampleDownload = nil
        if cancelled {
          self.show("Example scene download cancelled; finished archives are kept.")
          self.rebuild()
          return
        }
        switch result {
        case .success: self.beginExampleImport(scene)
        case .failure(let error):
          self.showError("Could not download \(scene.title): \(error.localizedDescription)")
          self.rebuild()
        }
      }
    }
  }
  // Opens the extracted scene as a new, unsaved, untitled project with the showcase shot's settings.
  func beginExampleImport(_ scene: ExampleScene) {
    guard !isBusy else { return }
    let shot: ShowcaseShot
    do {
      guard let found = try ShowcaseShot.bundled().first(where: { $0.name == scene.shot }) else {
        throw MaterialLibrary.error("showcase.json has no shot named \(scene.shot).")
      }
      shot = found
    } catch {
      showError(error.localizedDescription)
      return
    }
    let url = exampleLibrary.objURL(scene)
    let record = undoRecord("Open example scene", replacesDocument: true)
    beginDocumentChange("Importing \(scene.title)…", build: { [weak self] () -> (ProjectDocument, Int) in
      guard let self else { throw MaterialLibrary.error("Example scene import cancelled.") }
      var document = ProjectDocument()
      let objData = try self.readBounded(url, maximum: 1 << 40)
      var skipped = 0
      var report: [String] = []
      _ = try document.appendOBJ(objData, name: url.lastPathComponent, folder: url.deletingLastPathComponent(),
        skipped: &skipped, report: &report)
      shot.apply(to: &document)
      // The credit travels with the project in its import report.
      document.importReport = [scene.attribution] + (document.importReport ?? [])
      return (document, skipped)
    }) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.backUpReplacedDocument(record)
        self.commit(record)
        self.associate(nil, edited: true, replaced: true)
        self.selectedNode = nil
        self.changed()
        self.show("Opened \(scene.title) \(scene.credit), \(scene.license). Credits: File > Open Example Scene.")
      case .failure(let error): self.showError(error.localizedDescription)
      }
    }
  }
  func showExampleCredits() {
    guard let window = hostWindow else { return }
    let alert = NSAlert()
    alert.messageText = "Example scene credits"
    alert.informativeText =
      ExampleScenes.credits.joined(separator: "\n\n")
      + "\n\nFrom Morgan McGuire's Computer Graphics Archive, July 2017, downloaded on request and imported unchanged. "
      + "Metal Vibe Tracer translates their MTL materials and sets its own camera, sky and sun; renders are adapted "
      + "works and must keep this credit and the license link."
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Open Archive Website")
    alert.beginSheetModal(for: window) { response in
      if response == .alertSecondButtonReturn { NSWorkspace.shared.open(ExampleScenes.archiveURL) }
    }
  }
  func revealExampleScenes() {
    let root = exampleLibrary.root
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([root])
  }
  func exampleScenePanel() {
    heading("Example scenes")
    for (index, scene) in ExampleScenes.catalog.enumerated() {
      button(exampleSceneTitle(scene)) { [weak self] in self?.openExampleScene(index) }
    }
    text(
      "Production scenes from Morgan McGuire's Computer Graphics Archive, opened with the camera and lighting of the README images. They are not bundled: each is downloaded once, after you agree, into Application Support.\n"
        + ExampleScenes.credits.joined(separator: "\n"))
    button("Credits and licenses…") { [weak self] in self?.showExampleCredits() }
    button("Show downloaded scenes in Finder") { [weak self] in self?.revealExampleScenes() }
  }
  @objc func exampleSceneAction(_ sender: NSMenuItem) { openExampleScene(sender.tag) }
  @objc func exampleCreditsAction() { showExampleCredits() }
  @objc func revealExampleScenesAction() { revealExampleScenes() }
}
