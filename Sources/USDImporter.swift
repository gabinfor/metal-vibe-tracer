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
    var angle: Float?
    var normalize: Bool?
  }
  var nodes: [SceneNode]
  var assets: [MeshAsset]
  var materials: [Material]
  var cameras: [Camera]
  var environment: Environment?
  var sun: Sun?
  var report: [String]
  var fallbackColors: [String: [[Float]]]?
}
struct USDImportResult {
  var document: ProjectDocument
  var report: [String]
}
/// Seconds on a monotonic clock that does not advance while the Mac sleeps
/// (CLOCK_UPTIME_RAW: mach_absolute_time, the clock of DispatchTime). Limits measured on it
/// are neither used up by system sleep nor moved by wall-clock changes, unlike Date().
func awakeSeconds() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
// @unchecked Sendable: the UI thread cancels while the import thread runs the helper;
// every mutable property is read and written only while holding `lock`.
final class USDImportJob: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  // The import limit and the SIGTERM grace period run on `clock` (injectable for tests),
  // so a Mac that sleeps mid-import does not fail it.
  let limit: TimeInterval
  let clock: @Sendable () -> TimeInterval
  init(limit: TimeInterval = 300, clock: @escaping @Sendable () -> TimeInterval = awakeSeconds) {
    self.limit = limit
    self.clock = clock
  }
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
  var isHelperRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return process?.isRunning == true
  }
  private let finished = DispatchSemaphore(value: 0)
  func finish() { finished.signal() }
  /// Stops the helper and waits until the import has reaped it and removed its scratch folder.
  @discardableResult func cancelAndWait(timeout: TimeInterval) -> Bool {
    cancel()
    guard finished.wait(timeout: .now() + timeout) == .success else { return false }
    finished.signal()
    return true
  }
}
enum USDImporter {
  static var helperURL: URL? {
    runtimeResourceURL(
      bundled: Bundle.main.resourceURL?.appendingPathComponent("usd_bridge.py"),
      repositoryPath: "scripts/usd_bridge.py")
  }
  // REFERENCES.md: OBJ2026 (scene bridge). One streamed pass over the visible triangles gives
  // their bounds and, for each ray, the nearest surface distance (nil: no hit). It builds no
  // flattened host copy (R-101), and it throws what forEachRenderTriangle throws for invalid
  // combined transforms. The pivot keeps a two-sided Möller–Trumbore test rather than the
  // renderer's watertight one (WOOP2013): it only places the orbit target, a ray that slips
  // through a shared edge falls back to the bounds depth, and results stay those of the
  // earlier flattened-array computation.
  static func sceneExtent(
    _ graph: SceneGraph, rays: [(eye: SIMD3<Float>, forward: SIMD3<Float>)]
  ) throws -> (lo: SIMD3<Float>, hi: SIMD3<Float>, hits: [Float?]) {
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var hi = -lo
    var nearest = [Float](repeating: .greatestFiniteMagnitude, count: rays.count)
    try graph.forEachRenderTriangle { t in
      for v in [t.a, t.b, t.c] {
        let q = SIMD3(v.x, v.y, v.z)
        lo = simd_min(lo, q)
        hi = simd_max(hi, q)
      }
      let a = SIMD3(t.a.x, t.a.y, t.a.z)
      let e1 = SIMD3(t.b.x, t.b.y, t.b.z) - a, e2 = SIMD3(t.c.x, t.c.y, t.c.z) - a
      for (r, ray) in rays.enumerated() {
        let p = simd_cross(ray.forward, e2), det = simd_dot(e1, p)
        guard abs(det) > 1e-30 else { continue }
        let s = ray.eye - a, q = simd_cross(s, e1)
        let u = simd_dot(s, p) / det, v = simd_dot(ray.forward, q) / det, d = simd_dot(e2, q) / det
        if u >= 0, v >= 0, u + v <= 1, d > 1e-6, d < nearest[r] { nearest[r] = d }
      }
    }
    return (lo, hi, nearest.map { $0 < .greatestFiniteMagnitude ? $0 : nil })
  }
  static func load(
    _ url: URL, into source: ProjectDocument, frame: Double? = nil,
    job: USDImportJob = USDImportJob()
  ) throws -> USDImportResult {
    defer { job.finish() }
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
    guard let helper = helperURL else {
      throw MaterialLibrary.error("The OpenUSD bridge is missing from this application bundle. Rebuild the app.")
    }
    process.arguments = ["-I", helper.path, url.path, output.path]
    if let frame { process.arguments! += ["--frame", String(frame)] }
    process.standardOutput = logHandle
    process.standardError = logHandle
    // Keep external PYTHONPATH/plugin overrides from changing the bundled SDK.
    process.environment = [
      "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "PYTHONNOUSERSITE": "1",
    ]
    try job.run(process)
    let deadline = job.clock() + job.limit
    while process.isRunning {
      if job.isCancelled || job.clock() > deadline {
        process.terminate()
        let exitDeadline = job.clock() + 2
        while process.isRunning && job.clock() < exitDeadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw MaterialLibrary.error(
          job.isCancelled ? "USD import cancelled."
            : "USD import exceeded \(job.limit == 300 ? "five minutes" : "\(job.limit) s") (time asleep is not counted).")
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
    var uncompiled = Set<UUID>()
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
        guard e.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1e8 }) else {
          throw MaterialLibrary.error(
            "USD light \(material.path) emission is outside the supported range 0…1e8.")
        }
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
          uncompiled.insert(material.id)
        }
      }
    }
    // A material the compiler rejects falls back to each prim's own displayColor, not the first prim's.
    var fallbackColors: [UUID: [[Float]]] = [:]
    for (key, colors) in snapshot.fallbackColors ?? [:] {
      if let id = UUID(uuidString: key) { fallbackColors[id] = colors }
    }
    var splits: [String: UUID] = [:]
    for n in graph.nodes.indices {
      guard let colors = fallbackColors[graph.nodes[n].id], colors.count == graph.nodes[n].bindings.count
      else { continue }
      for (k, id) in graph.nodes[n].bindings.enumerated() where uncompiled.contains(id) {
        let color = colors[k]
        guard let base = snapshot.materials.first(where: { $0.id == id }), color != base.color,
          color.count == 3, color.allSatisfy({ $0.isFinite })
        else { continue }
        let key = id.uuidString + "\(color)"
        if splits[key] == nil {
          let slot = 8 + graph.materials.count
          guard slot < SceneLimits.materials else {
            snapshot.report.append(base.path + ": too many materials to keep per-prim fallback colors")
            continue
          }
          let split = SceneMaterial(name: base.name, slot: slot)
          graph.materials.append(split)
          state.surfaces[slot].enabled = 1
          state.surfaces[slot].color = SIMD4(
            min(1, max(0, color[0])), min(1, max(0, color[1])), min(1, max(0, color[2])), 1)
          splits[key] = split.id
        }
        if let split = splits[key] { graph.nodes[n].bindings[k] = split }
      }
    }
    try graph.validate()
    // A supported camera's view ray (eye, unit forward); nil for unsupported parameters.
    func viewRay(_ camera: USDImportSnapshot.Camera) -> (eye: SIMD3<Float>, forward: SIMD3<Float>)? {
      guard camera.eye.count == 3, camera.direction.count == 3, camera.up.count == 3,
        (5...150).contains(camera.fov)
      else { return nil }
      return (SIMD3(camera.eye[0], camera.eye[1], camera.eye[2]),
        simd_normalize(SIMD3(camera.direction[0], camera.direction[1], camera.direction[2])))
    }
    let cameraRays = snapshot.cameras.map(viewRay)
    // Validate combined transforms before replacing any active renderer resources. The
    // triangles are streamed once for every camera; no flattened copy is built (R-101).
    let extent = try sceneExtent(graph, rays: cameraRays.compactMap { $0 })
    let lo = extent.lo, hi = extent.hi
    var hits = extent.hits[...]
    // Orbit pivot: the first surface on the view ray, else the bounds center's depth.
    func orbitDistance(_ eye: SIMD3<Float>, _ forward: SIMD3<Float>, _ hit: Float?) -> Float {
      if let hit { return hit }
      guard lo.x <= hi.x else { return 1 }
      let depth = simd_dot((lo + hi) / 2 - eye, forward)
      return depth > 0 ? depth : simd_length(hi - lo)
    }
    p.version = 2
    p.graph = graph
    p.triangles = []
    p.scene = 6
    p.meshName = url.lastPathComponent
    // A USD scene opens as a new untitled document: earlier saved views do not carry over.
    p.views = [:]
    p.scenes[6] = state
    p.options.aperture = 0
    p.fog = 0
    p.ring = 0
    p.environmentData = nil
    p.environmentName = "Procedural sky"
    p.options.environmentIntensity = 0
    p.options.sunIntensity = 0
    p.options.sunAngle = nil
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
      // REFERENCES.md: OPENUSD. UsdLux radiance is intensity x 2^exposure, divided by
      // sizeFactor when normalized; the renderer stores the normal-incidence
      // irradiance, radiance x sizeFactor, and renders an independent sun cone.
      let angle = min(180, max(0, sun.angle ?? 0.53))
      let half = Double(angle) * .pi / 360, s2 = pow(sin(half), 2)
      let sizeFactor = half == 0 ? 1 : .pi * (half <= .pi / 2 ? s2 : 2 - s2)
      let irradiance = Double(max(0, sun.intensity)) * (sun.normalize == true ? 1 : sizeFactor)
      p.options.sunIntensity = Float(min(10000, irradiance))
      p.options.sunAngle = min(StudioOptions.sunAngleRange.upperBound, max(StudioOptions.sunAngleRange.lowerBound, angle))
      if irradiance > 10000 {
        snapshot.report.append(String(format: "Distant light irradiance %.4g clamped to 10000.", irradiance))
      }
      if p.options.sunAngle != sun.angle ?? 0.53 {
        snapshot.report.append(String(
          format: "Distant light angle %.3g degrees rendered as %.3g degrees at the same irradiance.",
          sun.angle ?? 0.53, p.options.sunAngle ?? 0))
      }
    }
    if snapshot.environment == nil && snapshot.sun == nil && state.emissions?.isEmpty != false {
      p.options.environmentIntensity = 1
      p.options.sunIntensity = 0
      snapshot.report.append(
        "No supported authored lighting: neutral procedural sky used for inspection.")
    }
    var importedCamera: CameraState?
    var importedFocus: Float?
    for (camera, ray) in zip(snapshot.cameras, cameraRays) {
      guard let (eye, forward) = ray, let hit = hits.popFirst() else {
        snapshot.report.append(camera.name + ": unsupported camera parameters")
        continue
      }
      // The orbit pivot is scene-derived; optical focus stays separate and is kept only when authored.
      let distance = min(1_000_000, max(0.0001, orbitDistance(eye, forward, hit)))
      let target = eye + forward * distance
      let delta = eye - target
      var c = CameraState()
      c.target = target
      c.distance = distance
      c.pitch = asin(min(0.997, max(-0.997, delta.y / distance)))
      c.yaw = atan2(delta.x, -delta.z)
      c.fov = camera.fov
      p.views["USD: " + camera.name] = c
      if importedCamera == nil {
        importedCamera = c
        importedFocus = camera.focus.flatMap { $0.isFinite && $0 > 0 ? min(1_000_000, max(0.0001, $0)) : nil }
      }
      let expectedUp = simd_normalize(
        simd_cross(simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0))), forward))
      if simd_dot(expectedUp, SIMD3(camera.up[0], camera.up[1], camera.up[2])) < 0.999 {
        snapshot.report.append(camera.name + ": camera roll is not represented by the orbit camera")
      }
    }
    if let camera = importedCamera {
      p.camera = camera
    } else {
      if lo.x <= hi.x {
        p.camera.target = (lo + hi) / 2
        p.camera.distance = min(1_000_000, max(0.0001, simd_length(hi - lo) * 1.4))
        p.camera.yaw = 0.3
        p.camera.pitch = 0.2
        p.camera.fov = 45
      }
    }
    p.options.focusDistance = importedFocus ?? p.camera.distance
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
    confirmDiscardingChanges { [weak self] in
      self?.chooseOpen("Open OpenUSD scene", extensions: ["usd", "usda", "usdc", "usdz"]) {
        [weak self] url in self?.beginImportUSD(from: url)
      }
    }
  }
  func beginImportUSD(from url: URL) {
    guard !isBusy, let window = hostWindow else { return }
    let record = undoRecord("Open USD scene", replacesDocument: true)
    let source = snapshot()
    let reuse = renderer.materials.reusableResources(graph: project.graph)
    let job = USDImportJob()
    let wasPaused = renderer.paused
    let sheet = NSAlert()
    sheet.messageText = "Importing OpenUSD scene"
    sheet.informativeText =
      "Composing layers, resolving materials, and building the scene. This can take a few minutes."
    sheet.addButton(withTitle: "Cancel")
    importInProgress = true
    usdImportJob = job
    renderer.paused = true
    beginProjectActivity("Importing \(url.lastPathComponent)…")
    sheet.beginSheetModal(for: window) { _ in job.cancel() }
    DispatchQueue.global(qos: .userInitiated).async {
      // Resources are prepared off the main thread, reusing unchanged live resources.
      let result = Result { () -> (USDImportResult, MaterialLibrary) in
        let imported = try USDImporter.load(url, into: source, job: job)
        return (imported, try self.prepareResources(imported.document, reuse: reuse))
      }
      DispatchQueue.main.async {
        let cancelled = job.isCancelled
        window.endSheet(sheet.window)
        self.importInProgress = false
        self.usdImportJob = nil
        self.renderer.paused = wasPaused
        if cancelled {
          self.show("USD import cancelled.")
          self.rebuild()
          return
        }
        switch result {
        case .success(let (imported, resources)):
          self.publishImportedUSD(imported, resources: resources, record: record)
          self.showUSDReport()
        case .failure(let error):
          self.showError(error.localizedDescription)
          self.rebuild()
        }
      }
    }
  }
  // The imported scene replaces the document as a new, unsaved, untitled project.
  func publishImportedUSD(_ imported: USDImportResult, resources: MaterialLibrary, record: UndoRecord?) {
    prepareGeneration &+= 1
    backUpReplacedDocument(record)
    applyProject(imported.document, resources: resources)
    commit(record)
    associate(nil, edited: true, replaced: true)
    selectedNode = imported.document.graph?.nodes.first?.id
    page = 4
    changed()
    rebuild()
  }
}
