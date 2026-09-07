import Cocoa
import Darwin
import simd

// REFERENCES.md: OPENUSD, USDPREVIEW. The official SDK composes USD in a helper process.
struct USDImportSnapshot: Decodable {
  struct Material: Decodable {
    var id: UUID
    var name: String
    var color: [Float]
    var path: String
    var mtlx: String?
    var emission: [Float]?
  }
  struct Camera: Decodable {
    var name: String
    var eye: [Float]
    var direction: [Float]
    var up: [Float]
    var fov: Float
    var focus: Float?
  }
  struct Environment: Decodable {
    var file: String
    var intensity: Float
  }
  struct Sun: Decodable {
    var direction: [Float]
    var intensity: Float
  }
  var nodes: [SceneNode]
  var assets: [MeshAsset]
  var materials: [Material]
  var cameras: [Camera]
  var environment: Environment?
  var sun: Sun?
  var report: [String]
}
struct USDImportResult {
  var document: ProjectDocument
  var report: [String]
}
final class USDImportJob: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  func cancel() {
    lock.lock()
    cancelled = true
    let child = process
    lock.unlock()
    if child?.isRunning == true { child?.terminate() }
  }
  func run(_ child: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw MaterialLibrary.error("USD import cancelled.") }
    process = child
    try child.run()
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}
enum USDImporter {
  static var helperURL: URL {
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("usd_bridge.py")
    if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("scripts/usd_bridge.py")
  }
  static func load(
    _ url: URL, into source: ProjectDocument, frame: Double? = nil,
    job: USDImportJob = USDImportJob()
  ) throws -> USDImportResult {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vibe-usd-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appendingPathComponent("scene.json")
    let log = folder.appendingPathComponent("import.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let logHandle = try FileHandle(forWritingTo: log)
    defer { try? logHandle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-I", helperURL.path, url.path, output.path]
    if let frame { process.arguments! += ["--frame", String(frame)] }
    process.standardOutput = logHandle
    process.standardError = logHandle
    // Keep external PYTHONPATH/plugin overrides from changing the bundled SDK.
    process.environment = [
      "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "PYTHONNOUSERSITE": "1",
    ]
    try job.run(process)
    let deadline = Date().addingTimeInterval(300)
    while process.isRunning {
      if job.isCancelled || Date() > deadline {
        process.terminate()
        let exitDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw MaterialLibrary.error(
          job.isCancelled ? "USD import cancelled." : "USD import exceeded five minutes.")
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if job.isCancelled { throw MaterialLibrary.error("USD import cancelled.") }
    guard process.terminationStatus == 0, !job.isCancelled else {
      let details = (try? String(contentsOf: log, encoding: .utf8)) ?? "OpenUSD helper failed."
      throw MaterialLibrary.error(String(details.suffix(6000)))
    }
    var snapshot = try JSONDecoder().decode(USDImportSnapshot.self, from: Data(contentsOf: output))
    let diagnostics = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    snapshot.report += diagnostics.components(separatedBy: .newlines).filter {
      $0.hasPrefix("Warning:")
    }.map { String($0.prefix(1200)) }
    var p = source
    // USD opens as a complete scene; it does not merge lighting or IDs into an existing import.
    var graph = SceneGraph(assets: snapshot.assets, nodes: snapshot.nodes, materials: [])
    var state = SceneState()
    for material in snapshot.materials {
      let slot = 8 + graph.materials.count
      graph.materials.append(SceneMaterial(id: material.id, name: material.name, slot: slot))
      guard material.color.count == 3, material.color.allSatisfy({ $0.isFinite }) else {
        throw MaterialLibrary.error("Invalid USD material color.")
      }
      state.surfaces[slot].enabled = 1
      state.surfaces[slot].color = SIMD4(
        min(1, max(0, material.color[0])), min(1, max(0, material.color[1])),
        min(1, max(0, material.color[2])), 1)
      if let e = material.emission, e.count == 3 {
        if state.emissions == nil { state.emissions = [:] }
        state.emissions?[slot] = SIMD3(e[0], e[1], e[2])
      }
      if let xml = material.mtlx {
        let imported = try MaterialXImporter.read(
          Data(xml.utf8), baseURL: folder, source: url.lastPathComponent + ":" + material.name)
        if var program = imported.materials.first {
          program.name = material.name
          if state.materialX == nil { state.materialX = [:] }
          state.materialX?[slot] = program
        } else {
          snapshot.report += imported.report.map { material.path + ": " + $0 }
        }
      }
    }
    try graph.validate()
    // Validate combined transforms before replacing any active renderer resources.
    _ = try graph.renderTriangles()
    p.version = 2
    p.graph = graph
    p.triangles = []
    p.scene = 6
    p.meshName = url.lastPathComponent
    p.scenes[6] = state
    p.options.aperture = 0
    p.fog = 0
    p.ring = 0
    p.environmentData = nil
    p.environmentName = "Procedural sky"
    p.options.environmentIntensity = 0
    p.options.sunIntensity = 0
    // The reference file supplies its own ground; the procedural studio floor is hidden.
    p.scenes[6]!.objects[1].rotationHidden.w = 1
    if let environment = snapshot.environment {
      p.environmentData = try Data(contentsOf: URL(fileURLWithPath: environment.file))
      p.environmentName = URL(fileURLWithPath: environment.file).lastPathComponent
      p.options.environmentIntensity = min(100, max(0, environment.intensity))
    }
    if let sun = snapshot.sun, sun.direction.count == 3 {
      let d = simd_normalize(SIMD3(sun.direction[0], sun.direction[1], sun.direction[2]))
      p.options.sunAzimuth = atan2(d.x, d.z) * 180 / .pi
      p.options.sunElevation = asin(min(1, max(-1, d.y))) * 180 / .pi
      p.options.sunIntensity = min(10000, max(0, sun.intensity))
    }
    if snapshot.environment == nil && snapshot.sun == nil && state.emissions?.isEmpty != false {
      p.options.environmentIntensity = 1
      p.options.sunIntensity = 0
      snapshot.report.append(
        "No supported authored lighting: neutral procedural sky used for inspection.")
    }
    var importedCamera: CameraState?
    for camera in snapshot.cameras {
      guard camera.eye.count == 3, camera.direction.count == 3, camera.up.count == 3,
        (5...150).contains(camera.fov)
      else {
        snapshot.report.append(camera.name + ": unsupported camera parameters")
        continue
      }
      let eye = SIMD3(camera.eye[0], camera.eye[1], camera.eye[2])
      let forward = simd_normalize(
        SIMD3(camera.direction[0], camera.direction[1], camera.direction[2]))
      let focus = min(1_000_000, max(0.0001, camera.focus ?? 1))
      let target = eye + forward * focus
      let delta = eye - target
      var c = CameraState()
      c.target = target
      c.distance = focus
      c.pitch = asin(min(0.997, max(-0.997, delta.y / focus)))
      c.yaw = atan2(delta.x, -delta.z)
      c.fov = camera.fov
      p.views["USD: " + camera.name] = c
      if importedCamera == nil { importedCamera = c }
      let expectedUp = simd_normalize(
        simd_cross(simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0))), forward))
      if simd_dot(expectedUp, SIMD3(camera.up[0], camera.up[1], camera.up[2])) < 0.999 {
        snapshot.report.append(camera.name + ": camera roll is not represented by the orbit camera")
      }
    }
    if let camera = importedCamera {
      p.camera = camera
    } else {
      let tris = try graph.renderTriangles()
      var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
      var hi = -lo
      for t in tris {
        for v in [t.a, t.b, t.c] {
          let q = SIMD3(v.x, v.y, v.z)
          lo = simd_min(lo, q)
          hi = simd_max(hi, q)
        }
      }
      if lo.x <= hi.x {
        p.camera.target = (lo + hi) / 2
        p.camera.distance = min(1_000_000, max(0.0001, simd_length(hi - lo) * 1.4))
        p.camera.yaw = 0.3
        p.camera.pitch = 0.2
        p.camera.fov = 45
      }
    }
    p.options.focusDistance = p.camera.distance
    p.importReport = snapshot.report
    try p.validate()
    return USDImportResult(document: p, report: snapshot.report)
  }
}
extension StudioController {
  func showUSDReport() {
    let alert = NSAlert()
    alert.messageText = "OpenUSD import report"
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
    scroll.hasVerticalScroller = true
    let text = NSTextView(frame: scroll.bounds)
    text.isEditable = false
    text.string = project.importReport?.joined(separator: "\n\n") ?? "No USD import report."
    text.font = .systemFont(ofSize: 12)
    scroll.documentView = text
    alert.accessoryView = scroll
    alert.runModal()
  }
  func importUSD() {
    chooseOpen("Open OpenUSD scene", extensions: ["usd", "usda", "usdc", "usdz"]) {
      [weak self] url in
      guard let self, !self.isBusy else { return }
      let source = self.snapshot()
      let job = USDImportJob()
      let wasPaused = self.renderer.paused
      let sheet = NSAlert()
      sheet.messageText = "Importing OpenUSD scene"
      sheet.informativeText =
        "Composing layers, resolving materials, and building the scene. This can take a few minutes."
      sheet.addButton(withTitle: "Cancel")
      guard let window = self.hostWindow else { return }
      self.importInProgress = true
      self.renderer.paused = true
      sheet.beginSheetModal(for: window) { _ in job.cancel() }
      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result { try USDImporter.load(url, into: source, job: job) }
        DispatchQueue.main.async {
          let cancelled = job.isCancelled
          window.endSheet(sheet.window)
          self.importInProgress = false
          self.renderer.paused = wasPaused
          if cancelled {
            self.show("USD import cancelled.")
            return
          }
          switch result {
          case .success(let imported):
            do {
              self.checkpoint("Open USD scene")
              try self.restore(imported.document)
              self.selectedNode = imported.document.graph?.nodes.first?.id
              self.page = 4
              self.changed()
              self.rebuild()
              self.showUSDReport()
            } catch { self.show(error.localizedDescription) }
          case .failure(let error): self.show(error.localizedDescription)
          }
        }
      }
    }
  }
}
