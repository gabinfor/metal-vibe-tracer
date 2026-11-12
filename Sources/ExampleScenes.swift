import Cocoa
import CryptoKit

// REFERENCES.md: MCGUIRE2017, OBJ2026, MTL2026, SHA256FIPS, STANFORD3DSCAN, BITTERLI2016 (the Fireplace and Living
// Room cameras). The download scenes of SceneCatalog, from Morgan McGuire's Computer Graphics Archive. Nothing is
// bundled: the scene browser's Download button, whose details pane states the size and source, downloads an archive,
// checks it against the size and SHA-256 digest pinned in SceneCatalog, extracts it into Application Support and imports it
// through ProjectDocument.appendOBJ, unchanged, with the camera and lighting of the README image (the
// scripts/showcase.json shot of the same name, ShowcaseShot). The bundled spectral examples open through the USD
// importer with their shot (Examples/Spectral).

// One archive of the McGuire archive and the folder it extracts into, relative to its scene's storage folder.
struct ExampleArchive: Sendable, Equatable {
  var name: String
  var url: URL
  var folder: String
  var bytes: Int64
  var unpackedBytes: Int64
  var sha256: String
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
  // The scene's folder; the library's root for a scene that is not a download.
  func storage(_ entry: SceneEntry) -> URL {
    guard case .download(let storage, _, _) = entry.source else { return root }
    return root.appendingPathComponent(storage, isDirectory: true)
  }
  // The downloaded scene's file in its folder; nil for a scene that is not a download.
  func sceneFileURL(_ entry: SceneEntry) -> URL? {
    guard case .download(_, let file, _) = entry.source else { return nil }
    return storage(entry).appendingPathComponent(file)
  }
  func marker(_ archive: ExampleArchive, storage: String) -> URL {
    root.appendingPathComponent(storage, isDirectory: true).appendingPathComponent(".\(archive.name).installed")
  }
  func isInstalled(_ archive: ExampleArchive, storage: String) -> Bool {
    (try? String(contentsOf: marker(archive, storage: storage), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) == archive.sha256
  }
  func missing(_ entry: SceneEntry) -> [ExampleArchive] {
    guard case .download(let storage, _, let archives) = entry.source else { return [] }
    return archives.filter { !isInstalled($0, storage: storage) }
  }
  func downloadBytes(_ entry: SceneEntry) -> Int64 { missing(entry).reduce(0) { $0 + $1.bytes } }
  func diskBytes(_ entry: SceneEntry) -> Int64 { missing(entry).reduce(0) { $0 + $1.unpackedBytes } }
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

  func install(_ entry: SceneEntry, into library: ExampleLibrary) throws {
    let archives = library.missing(entry)
    lock.lock()
    total = archives.reduce(0) { $0 + $1.bytes }
    completed = 0
    lock.unlock()
    let storage = library.storage(entry)
    let downloads = library.root.appendingPathComponent(".downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    let needed = library.downloadBytes(entry) + library.diskBytes(entry)
    if let free = try? library.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage, free < needed
    {
      throw Self.failure(
        "\(entry.title) needs \(SceneCatalog.megabytes(needed)) of free disk space while it downloads and extracts; "
          + "\(SceneCatalog.megabytes(free)) is available.")
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
    report("Downloading \(label): \(SceneCatalog.megabytes(totalBytesWritten)) of "
      + "\(SceneCatalog.megabytes(max(totalBytesExpectedToWrite, totalBytesWritten)))", received: totalBytesWritten)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    if let error, received.error == nil { received.error = error }
    lock.unlock()
    finished.signal()
  }
}

// A shot of scripts/showcase.json: the README images' scene, camera, lens, lighting and output settings.
// scripts/render_showcase.py renders them; the scene browser opens the McGuire archive ones.
struct ShowcaseShot: Decodable, Sendable {
  var name: String
  var scene: UInt32?
  var project: String?
  var usd: String?
  var gltf: String?
  var mitsuba: String?
  var obj: String?
  var hdri: String?
  var sky: UInt32?
  var fog: UInt32?
  var ring: UInt32?
  var strategy: UInt32?
  var lightTransport: UInt32?
  // LightSampling raw value (0 power, 1 light tree); nil keeps the project's choice.
  var lightSampling: UInt32?
  // CausticMode raw value (0 off, 1 light tracing, 3 light tracing + photons); nil keeps the project's choice.
  var caustics: UInt32?
  var yaw: Float?, pitch: Float?, distance: Float?, fov: Float?
  var target: [Float]?
  var aperture: Float?, focusDistance: Float?
  var exposure: Float?, toneMap: Int?
  var sunAzimuth: Float?, sunElevation: Float?, sunIntensity: Float?
  var environmentIntensity: Float?, environmentRotation: Float?
  var lightIntensity: Float?, lightSize: Float?
  var lightSpectrum: UInt32?, sunSpectrum: UInt32?
  var lightColor: [Float]?
  var width: Int?, height: Int?
  var samples: UInt32?
  var depth: Int?
  // Raw linear radiance as OpenEXR, without a denoiser (renderer comparisons).
  var raw: Bool?
  // Open Image Denoise for scripts/render_showcase.py's export; off by default, so documentation and test images
  // show the raw accumulation.
  var denoise: Bool?
  // With denoise: also write the raw accumulation as <name>-raw.png, from the same render, before OIDN runs.
  var keepRaw: Bool?
  // StudioOptions.indirectClamp: a biased per-sample cap of indirect light that removes fireflies.
  var indirectClamp: Float?
  // Scales the imported scene's emission (lamps, signs, emissive glass): 0 switches it off for a daylight
  // shot, above 1 brightens it for a night shot, since MTL emission has no absolute scale.
  var emissionScale: Float?
  // Rotation of the imported scene's top-level objects, X, Y, Z in degrees (as in the Objects inspector):
  // [-90, 0, 0] stands a Z-up OBJ upright, since the camera's up is +Y.
  var rotation: [Float]?
  // A saved view of the imported scene ("glTF: camera_front") as the camera, before yaw, pitch and the
  // other camera fields adjust it.
  var view: String?

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

  // Everything but the scene source (scene, usd, gltf, mitsuba, obj, project, hdri) and the export mode (raw).
  func apply(to p: inout ProjectDocument) {
    if let k = emissionScale { p.scaleImportedEmission(by: k) }
    if let r = rotation, r.count == 3, var graph = p.graph {
      for i in graph.nodes.indices where graph.nodes[i].parent == nil {
        graph.nodes[i].transform.rotationHidden.x = r[0] * .pi / 180
        graph.nodes[i].transform.rotationHidden.y = r[1] * .pi / 180
        graph.nodes[i].transform.rotationHidden.z = r[2] * .pi / 180
      }
      p.graph = graph
    }
    if let v = sky { p.sky = v }
    if let v = fog { p.fog = v }
    if let v = ring { p.ring = v }
    if let v = strategy { p.strategy = v }
    if let v = lightTransport { p.lightTransport = v }
    if let v = lightSampling { p.lightSampling = v }
    if let v = caustics { p.caustics = v }
    if let v = view, let c = p.views[v] {
      p.camera = c
      p.options.focusDistance = c.distance
    }
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
    if let v = indirectClamp { p.options.indirectClamp = v > 0 ? v : nil }
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

// Opening, downloading and crediting the catalog's scenes for the scene browser and the File menu.
extension StudioController {
  // Built-in and bundled scenes are always available; a download scene once every archive is extracted.
  func isInstalled(_ entry: SceneEntry) -> Bool { !entry.isDownload || exampleLibrary.missing(entry).isEmpty }
  // Opens the scene as a new, unsaved, untitled project, after confirming that changes are discarded. A download
  // scene that is not installed does nothing: its Download button in the scene browser installs it first.
  func openScene(_ entry: SceneEntry) {
    guard !isBusy, isInstalled(entry) else { return }
    switch entry.source {
    case .builtIn(let index): confirmDiscardingChanges { [weak self] in self?.startBuiltInScene(index) }
    case .bundled: openBundledScene(entry)
    case .download: confirmDiscardingChanges { [weak self] in self?.beginExampleImport(entry) }
    }
  }
  // The scene browser's Download button: downloads, verifies and extracts the missing archives while the details pane
  // shows the progress. The download goes on when another card is selected or the Scenes window is hidden. A finished
  // download reloads the browser and opens the scene when the Scenes window is shown, with no sheet on it, and nothing
  // would be discarded (no document loaded, or a document without unsaved changes); otherwise it selects the scene, whose Open button shows,
  // and says so in the status line. A failure or a cancel leaves the archives that finished installed.
  func beginSceneDownload(_ entry: SceneEntry) {
    guard entry.isDownload, !isInstalled(entry) else { return }
    if let running = downloadingScene {
      show("Wait for the download of \(running.title) to finish.")
      return
    }
    let library = exampleLibrary
    let host = library.missing(entry).first?.url.host ?? "the server"
    let job = ExampleSceneDownload { [weak self] fraction, message in
      DispatchQueue.main.async { self?.sceneDownloadProgress(entry, fraction, message) }
    }
    exampleDownload = job
    downloadingScene = entry
    downloadProgress = (0, "Connecting to \(host)…")
    scenes.browser.setDownload(entry, fraction: 0, status: downloadProgress?.status)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try job.install(entry, into: library) }
      DispatchQueue.main.async { [weak self] in self?.sceneDownloadFinished(entry, job, result) }
    }
  }
  func cancelSceneDownload() { exampleDownload?.cancel() }
  private func sceneDownloadProgress(_ entry: SceneEntry, _ fraction: Double, _ message: String) {
    guard downloadingScene?.id == entry.id else { return }
    downloadProgress = (fraction, message)
    scenes.browser.setDownload(entry, fraction: fraction, status: message)
  }
  private func sceneDownloadFinished(_ entry: SceneEntry, _ job: ExampleSceneDownload, _ result: Result<Void, Error>) {
    exampleDownload = nil
    downloadingScene = nil
    downloadProgress = nil
    scenes.browser.setDownload(nil, fraction: nil, status: nil)
    scenes.browser.reload()
    switch result {
    case .success:
      // Opens the scene only when the Scenes window is shown without a sheet on it (opening would hide the window under
      // the sheet) and that discards nothing: with no document loaded or over a document without changes.
      if scenes.isVisible && scenes.window?.attachedSheet == nil && !isBusy && (startScreen != nil || !documentEdited) {
        openScene(entry)
      } else {
        scenes.browser.selection = entry
        show("\(entry.title) is downloaded; open it from the scene browser.")
      }
    case .failure where job.isCancelled:
      show("Download of \(entry.title) cancelled; finished archives are kept.")
    case .failure(let error):
      let message = "Could not download \(entry.title): \(error.localizedDescription)"
      scenes.browser.showDownloadError(entry, message)
      showError(message)
    }
  }
  // Opens the extracted scene as a new, unsaved, untitled project with the showcase shot's settings.
  func beginExampleImport(_ entry: SceneEntry) {
    guard !isBusy, let shotName = entry.shot, let url = exampleLibrary.sceneFileURL(entry),
      let attribution = entry.attribution, let credit = entry.credit, let license = entry.license
    else { return }
    let shot: ShowcaseShot
    do {
      guard let found = try ShowcaseShot.bundled().first(where: { $0.name == shotName }) else {
        throw MaterialLibrary.error("showcase.json has no shot named \(shotName).")
      }
      shot = found
    } catch {
      showError(error.localizedDescription)
      return
    }
    openOBJAsNewDocument(url, activity: "Importing \(entry.title)…", undoName: "Open example scene", adjust: { document in
      shot.apply(to: &document)
      // The credit travels with the project in its import report.
      document.importReport = [attribution] + (document.importReport ?? [])
    }) { [weak self] in
      self?.changed()
      self?.show("Opened \(entry.title) \(credit), \(license). Credits: File > Credits and Licenses….")
    }
  }
  // Opens an OBJ chosen with Open Scene File as a new, unsaved, untitled project, framed to the model.
  func beginOpenOBJScene(_ url: URL) {
    openOBJAsNewDocument(url, activity: "Importing \(url.lastPathComponent)…", undoName: "Open scene", adjust: { _ in }) {
      [weak self] in
      guard let self else { return }
      self.frameMesh(recordUndo: false)
      self.changed()
    }
  }
  // Builds a new document from the OBJ off the main thread (`adjust` edits it before its resources are
  // prepared), replaces the current one with it and runs `finish`.
  private func openOBJAsNewDocument(
    _ url: URL, activity: String, undoName: String, adjust: @escaping @Sendable (inout ProjectDocument) -> Void,
    finish: @escaping @MainActor () -> Void
  ) {
    guard !isBusy else { return }
    let record = undoRecord(undoName, replacesDocument: true)
    beginDocumentChange(activity, build: { [weak self] progress -> (ProjectDocument, Int) in
      guard let self else { throw MaterialLibrary.error("Scene import cancelled.") }
      var document = ProjectDocument()
      let objData = try self.readBounded(url, maximum: 1 << 40)
      var skipped = 0
      var report: [String] = []
      _ = try document.appendOBJ(objData, name: url.lastPathComponent, folder: url.deletingLastPathComponent(),
        skipped: &skipped, report: &report, progress: progress)
      adjust(&document)
      return (document, skipped)
    }) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.backUpReplacedDocument(record)
        self.commit(record)
        self.associate(nil, edited: true, replaced: true)
        self.selectedNode = nil
        finish()
      case .failure(let error): self.showError(error.localizedDescription)
      }
    }
  }
  func showExampleCredits() {
    guard let window = sheetWindow else { return }
    let alert = NSAlert()
    alert.messageText = "Example scene credits"
    alert.informativeText =
      SceneCatalog.credits.joined(separator: "\n\n")
      + "\n\nFrom Morgan McGuire's Computer Graphics Archive, July 2017, downloaded on request and imported unchanged. "
      + "Metal Vibe Tracer translates their MTL materials and sets its own camera, sky and sun; renders are adapted "
      + "works and must keep this credit and the license link."
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Open Archive Website")
    alert.beginSheetModal(for: window) { response in
      if response == .alertSecondButtonReturn, let website = SceneEntry.Collection.mcguire.website {
        NSWorkspace.shared.open(website)
      }
    }
  }
  func revealExampleScenes() {
    let root = exampleLibrary.root
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([root])
  }
  // Opens a bundled spectral example with its showcase shot's settings.
  private func openBundledScene(_ example: SceneEntry) {
    guard case .bundled(let path) = example.source else { return }
    let shot: ShowcaseShot
    let url: URL
    do {
      guard let found = try ShowcaseShot.bundled().first(where: { $0.name == example.shot }),
        let stage = SceneCatalog.bundledURL(path)
      else { throw MaterialLibrary.error("\(example.title) is missing from the application bundle.") }
      (shot, url) = (found, stage)
    } catch {
      showError(error.localizedDescription)
      return
    }
    confirmDiscardingChanges { [weak self] in
      self?.beginImportUSD(from: url, opened: "Opened \(example.title). Spectral light transport renders its effects.") {
        shot.apply(to: &$0)
      }
    }
  }
  @objc func exampleCreditsAction() { showExampleCredits() }
  @objc func revealExampleScenesAction() { revealExampleScenes() }
}
