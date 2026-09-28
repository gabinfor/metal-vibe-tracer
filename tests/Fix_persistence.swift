// Regression checks for project IO, autosave, undo, busy guards and the quit flow.
@MainActor func fixPersistenceChecks() throws {
  // Absolute, like panel URLs, so restored associations compare equal.
  let folder = studioDirectory.absoluteURL.appendingPathComponent("fix-persistence", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let history = controller.history
  let savedAutosaveURL = controller.autosaveURL
  controller.autosaveURL = folder.appendingPathComponent("Autosave.vtrace")
  defer { controller.autosaveURL = savedAutosaveURL }
  func idle() { waitUntil({ !controller.isBusy }, seconds: 60) }
  func grouped(_ body: () throws -> Void) rethrows {
    history.beginUndoGrouping()
    defer { history.endUndoGrouping() }
    try body()
  }
  func decode(_ url: URL) throws -> ProjectDocument {
    try ProjectDocument.decodeProject(Data(contentsOf: url), near: url)
  }
  func button(_ title: String, in view: NSView) -> ActionButton? {
    if let b = view as? ActionButton, b.title == title { return b }
    for child in view.subviews { if let b = button(title, in: child) { return b } }
    return nil
  }
  func reset() throws {
    controller.saveTimer?.invalidate()
    try controller.restore(ProjectDocument())
    controller.associate(nil, edited: false, replaced: true)
    controller.saveTimer?.invalidate()
    history.removeAllActions()
  }
  let wasGroupingByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer { history.groupsByEvent = wasGroupingByEvent }
  try reset()

  // R-08, R-36: Open is undoable together with its file association; the replaced
  // edited document is kept as a recovery copy.
  let fileA = folder.appendingPathComponent("A.vtrace"), fileB = folder.appendingPathComponent("B.vtrace")
  var savedA: Bool?
  controller.beginSaveProject(fileA) { savedA = $0 }
  idle()
  require(savedA == true && controller.projectURL == fileA && !controller.documentEdited, "save associates A")
  grouped {
    controller.checkpoint("Exposure")
    testRenderer.options.exposure = 1.5
    controller.changed(reset: false)
  }
  require(controller.documentEdited, "edit marks the document edited")
  var documentB = ProjectDocument()
  documentB.options.exposure = 4
  try JSONEncoder().encode(documentB).write(to: fileB)
  grouped {
    controller.beginOpenProject(fileB)
    idle()
  }
  require(controller.projectURL == fileB && testRenderer.options.exposure == 4 && !controller.documentEdited,
    "open associates B")
  waitUntil({ FileManager.default.fileExists(atPath: controller.previousAutosaveURL.path) })
  try controller.flushAutosave(to: folder.appendingPathComponent("sync.vtrace"))
  let backup = try decode(controller.previousAutosaveURL)
  require(backup.options.exposure == 1.5 && backup.recovery?.projectPath == fileA.path
    && backup.recovery?.edited == true, "replaced edited document is kept as a recovery copy")
  history.undo()
  idle()
  require(testRenderer.options.exposure == 1.5 && controller.projectURL == fileA && controller.documentEdited,
    "undoing Open restores the previous document and its file association")
  controller.beginSaveProject(controller.projectURL!)
  idle()
  let (reopenedB, resavedA) = (try decode(fileB), try decode(fileA))
  require(reopenedB.options.exposure == 4 && resavedA.options.exposure == 1.5,
    "save after undoing Open writes the previous file, not the opened one")
  history.redo()
  idle()
  require(controller.projectURL == fileB && testRenderer.options.exposure == 4, "redo of Open restores B")
  print("PASS: fix-persistence Open/Undo/Save association and replaced-document recovery copy (R-08, R-36)")

  // R-36: unsaved-changes prompt responses, New project, and recovery metadata in autosaves.
  grouped {
    controller.checkpoint("Exposure")
    testRenderer.options.exposure = 2.5
    controller.changed(reset: false)
  }
  var proceeded = false
  controller.resolveUnsavedChanges(.alertThirdButtonReturn) { proceeded = true }
  require(!proceeded, "Cancel keeps the edited document")
  controller.resolveUnsavedChanges(.alertSecondButtonReturn) { proceeded = true }
  require(proceeded, "Don't Save proceeds")
  let recoveryURL = folder.appendingPathComponent("recovery.vtrace")
  try controller.flushAutosave(to: recoveryURL)
  let recovered = try decode(recoveryURL)
  require(recovered.recovery?.projectPath == fileB.path && recovered.recovery?.edited == true,
    "autosave records the file association and unsaved state")
  grouped {
    controller.newProject()
    idle()
  }
  require(controller.projectURL == nil && !controller.documentEdited && testRenderer.options.exposure == 0,
    "New project is untitled and clean")
  try controller.flushAutosave(to: folder.appendingPathComponent("sync.vtrace"))
  let newBackup = try decode(controller.previousAutosaveURL)
  require(newBackup.options.exposure == 2.5, "New keeps the replaced edited document")
  history.undo()
  idle()
  require(controller.projectURL == fileB && testRenderer.options.exposure == 2.5, "undoing New restores association")
  try reset()
  try controller.flushAutosave(to: folder.appendingPathComponent("sync.vtrace"))
  try? FileManager.default.removeItem(at: controller.autosaveURL)
  try FileManager.default.copyItem(at: recoveryURL, to: controller.autosaveURL)
  controller.restoreAutosave()
  require(controller.projectOperationInProgress, "launch restore runs off the main thread")
  idle()
  require(controller.projectURL == fileB && controller.documentEdited && testRenderer.options.exposure == 2.5,
    "restored autosave keeps its association and unsaved state")
  print("PASS: fix-persistence unsaved-changes responses, New undo, recovery metadata (R-36)")

  // R-09: an unrestorable autosave is moved aside and never overwritten.
  try reset()
  try controller.flushAutosave(to: folder.appendingPathComponent("sync.vtrace"))
  try? FileManager.default.removeItem(at: controller.autosaveURL)
  let damaged = Data("{\"version\": 99".utf8)
  try damaged.write(to: controller.autosaveURL)
  controller.restoreAutosave()
  idle()
  let kept = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    .filter { $0.lastPathComponent.hasPrefix("Autosave-unrestorable-") }
  require(kept.count == 1 && (try? Data(contentsOf: kept[0])) == damaged, "failed autosave restore preserves the file")
  try controller.flushAutosave()
  require(!FileManager.default.fileExists(atPath: controller.autosaveURL.path),
    "quit flush after a failed restore does not write an unedited default document")
  print("PASS: fix-persistence unrestorable autosave preservation (R-09)")

  // R-45: coalesced autosaves; unchanged revisions are not rewritten; camera debounce.
  try reset()
  for i in 0..<5 {
    testRenderer.options.exposure = Float(i)
    controller.changed(reset: false)
    controller.autosave()
  }
  try controller.flushAutosave()
  let coalesced = try decode(controller.autosaveURL)
  require(coalesced.options.exposure == 4, "coalesced autosave writes the newest snapshot")
  try FileManager.default.removeItem(at: controller.autosaveURL)
  try controller.flushAutosave()
  require(!FileManager.default.fileExists(atPath: controller.autosaveURL.path),
    "flush skips a revision that is already autosaved")
  controller.viewport.onUserOrbit?()
  require((controller.saveTimer?.fireDate.timeIntervalSinceNow ?? 0) > 3, "camera-only changes use a longer debounce")
  controller.saveTimer?.invalidate()
  print("PASS: fix-persistence autosave coalescing and revision skip (R-45)")

  // R-39, R-44: display- and camera-only undo keeps accumulation and every GPU resource.
  try reset()
  let materials = testRenderer.materials, builds = testRenderer.materials.meshBuildCount
  grouped {
    controller.checkpoint("Exposure")
    testRenderer.options.exposure = 3
    controller.changed(reset: false)
  }
  let generation = testRenderer.interactionGeneration
  history.undo()
  require(!controller.isBusy && testRenderer.options.exposure == 0
    && testRenderer.interactionGeneration == generation, "display-only undo keeps accumulation")
  history.redo()
  require(testRenderer.options.exposure == 3 && testRenderer.interactionGeneration == generation,
    "display-only redo keeps accumulation")
  grouped {
    controller.checkpoint("Camera")
    testRenderer.yaw += 0.3
    controller.changed(reset: false)
  }
  history.undo()
  require(testRenderer.materials === materials && testRenderer.materials.meshBuildCount == builds,
    "camera-only undo reuses the live resources")
  grouped {
    controller.checkpoint("Sun")
    testRenderer.options.sunIntensity = 400
    controller.changed()
  }
  let sunGeneration = testRenderer.interactionGeneration
  history.undo()
  require(testRenderer.options.sunIntensity == 850 && testRenderer.interactionGeneration != sunGeneration,
    "radiance-affecting undo still resets accumulation")
  // Resource-changing undo is prepared off the main thread and reuses unchanged maps.
  var mapped = controller.snapshot()
  var mappedState = mapped.scenes[Int(mapped.scene)] ?? SceneState()
  mappedState.maps[4] = try Data(contentsOf: pngURL)
  mappedState.names[4] = "fix.png"
  mapped.scenes[Int(mapped.scene)] = mappedState
  try controller.restore(mapped)
  let mapTexture = testRenderer.materials.images[4]
  var withEnvironment = controller.snapshot()
  withEnvironment.environmentData = try Data(contentsOf: exrURL)
  let candidate = try controller.prepareResources(
    withEnvironment, reuse: testRenderer.materials.reusableResources(graph: controller.project.graph))
  require(candidate.images[4] === mapTexture && candidate !== testRenderer.materials,
    "candidate preparation reuses unchanged map textures")
  history.removeAllActions()
  grouped {
    controller.checkpoint("Environment")
    try? testRenderer.materials.setEnvironment(withEnvironment.environmentData)
    controller.changed()
  }
  history.undo()
  require(controller.projectOperationInProgress, "resource-changing undo is prepared off the main thread")
  idle()
  require(testRenderer.materials.environmentData == nil && testRenderer.materials.images[4] === mapTexture,
    "prepared undo publishes the environment change and keeps the resident map")
  print("PASS: fix-persistence display/camera undo keeps accumulation; resources reused and prepared off-main (R-39, R-44)")

  // R-34, R-76, R-35: busy guards and quit waiting for an explicit save.
  try reset()
  controller.importInProgress = true
  var busySave: Bool?
  controller.saveProject { busySave = $0 }
  require(busySave == false, "Save is rejected during project I/O")
  require(button("Save", in: controller.view)?.isEnabled == false && controller.viewport.canEdit?() == false,
    "toolbar Save and camera gestures are disabled while busy")
  let untouched = testRenderer.options.exposure
  controller.newProject()
  controller.checkpoint("Busy")
  require(!history.canUndo && testRenderer.options.exposure == untouched, "busy New and checkpoints do nothing")
  controller.importInProgress = false
  require(button("Save", in: controller.view)?.isEnabled == true, "toolbar Save re-enables after I/O")
  let quitFile = folder.appendingPathComponent("quit.vtrace")
  controller.beginSaveProject(quitFile)
  var quitReply: String??
  controller.whenProjectOperationsFinish { quitReply = .some($0) }
  require(quitReply == nil, "quit waits for the explicit save in flight")
  waitUntil({ quitReply != nil })
  require(quitReply! == nil && FileManager.default.fileExists(atPath: quitFile.path), "quit resumes after the save")
  controller.beginSaveProject(URL(fileURLWithPath: "/nonexistent-vibe-tracer-folder/x.vtrace"))
  quitReply = nil
  controller.whenProjectOperationsFinish { quitReply = .some($0) }
  waitUntil({ quitReply != nil })
  require(quitReply! != nil, "a failed save is reported before quitting")
  controller.terminationRequested = false
  print("PASS: fix-persistence busy guards and quit after pending saves (R-34, R-35, R-76)")

  // R-75, R-78: failed operations register no undo step and leave state intact.
  try reset()
  let notImage = folder.appendingPathComponent("not-an-image.png")
  try Data("not an image".utf8).write(to: notImage)
  grouped { controller.loadTexture(from: notImage, slot: 1, channel: 0) }
  require(history.undoActionName != "Load texture", "failed texture load registers no undo step")
  controller.selectedNode = nil
  controller.selectedSlot = 1
  testRenderer.materials.settings[1].surface.x = 0.77
  controller.page = 3
  controller.rebuild()
  testRenderer.materials.bindingAllocationFailureCountdown = 0
  grouped { button("Reset material and maps", in: controller.stack)?.invoke() }
  testRenderer.materials.bindingAllocationFailureCountdown = nil
  require(abs(testRenderer.materials.settings[1].surface.x - 0.77) < 1e-6 && history.undoActionName != "Reset material",
    "failed material reset leaves the material unchanged")
  controller.project.environmentName = "studio.exr"
  controller.page = 2
  controller.rebuild()
  testRenderer.materials.bindingAllocationFailureCountdown = 0
  grouped { button("Use procedural sky", in: controller.stack)?.invoke() }
  testRenderer.materials.bindingAllocationFailureCountdown = nil
  require(controller.project.environmentName == "studio.exr" && history.undoActionName != "Clear environment",
    "failed environment clear keeps the environment name")
  print("PASS: fix-persistence failed operations register no undo step (R-75, R-78)")

  // R-38: legacy triangles with out-of-range material slots are rejected.
  var legacy = ProjectDocument()
  legacy.triangles = [MeshTriangle](repeating: triangles[0], count: 1)
  legacy.triangles[0].uvc.z = 1e19
  do {
    try legacy.validate()
    require(false, "reject a huge legacy triangle slot")
  } catch {}
  legacy.triangles[0].uvc.z = 7.5
  do {
    try legacy.validate()
    require(false, "reject a fractional legacy triangle slot")
  } catch {}
  print("PASS: fix-persistence legacy triangle slot validation (R-38)")

  // R-77: object removal keeps unbound materials.
  var graph = SceneGraph()
  let root = try graph.addOBJ("v 0 0 0\nv 1 0 0\nv 0 1 0\no A\nusemtl Red\nf 1 2 3\no B\nusemtl Blue\nf 1 2 3", name: "two")
  let loose = try graph.addMaterial("Loose")
  let a = graph.nodes.first { $0.name == "A" }!.id
  graph.remove(a)
  require(graph.materials.contains { $0.id == loose.id } && graph.materials.contains { $0.name == "Blue" }
    && !graph.materials.contains { $0.name == "Red" } && graph.nodes.contains { $0.id == root },
    "removal prunes only the removed nodes' exclusive materials")
  print("PASS: fix-persistence unbound materials survive object removal (R-77)")

  // R-72: group-heavy OBJ parsing is linear and the node limit fails early.
  var groups = "v 0 0 0\nv 1 0 0\nv 0 1 0\n"
  for i in 0..<20_000 { groups += "g G\(i)\nf 1 2 3\n" }
  let start = Date()
  let groupParts = try OBJMesh.parts(groups)
  require(groupParts.count == 20_000 && Date().timeIntervalSince(start) < 5,
    "OBJ part lookup is constant time")
  var limited = SceneGraph()
  do {
    _ = try limited.addOBJ(groups, name: "groups")
    require(false, "reject an OBJ exceeding the node limit")
  } catch {
    require(error.localizedDescription.contains("too many objects and groups"), "node limit message is actionable")
  }
  try reset()
  let objURL = folder.appendingPathComponent("quad.obj")
  try obj.write(to: objURL, atomically: true, encoding: .utf8)
  grouped {
    controller.beginImportOBJ(from: objURL)
    require(controller.projectOperationInProgress, "OBJ import parses off the main thread")
    idle()
  }
  require(controller.project.graph?.assets.count == 1 && history.canUndo, "off-main OBJ import publishes")
  print("PASS: fix-persistence OBJ parsing, node budget and off-main import (R-72)")

  // R-70: an opened USD scene is untitled and carries no earlier saved views.
  let usdFolder = testOutputDirectory.appendingPathComponent("usd", isDirectory: true)
  var withViews = ProjectDocument()
  withViews.views["Old"] = CameraState()
  let usd = try USDImporter.load(usdFolder.appendingPathComponent("scene.usda"), into: withViews)
  require(usd.document.views["Old"] == nil && usd.document.views.keys.allSatisfy { $0.hasPrefix("USD: ") },
    "USD open drops earlier saved views")
  controller.associate(fileA, edited: false, replaced: true)
  let resources = try controller.prepareResources(usd.document)
  controller.publishImportedUSD(usd, resources: resources, record: nil)
  require(controller.projectURL == nil && controller.documentEdited, "USD open is a new unsaved document")
  try reset()
  controller.page = 0
  controller.rebuild()
  controller.saveTimer?.invalidate()
  print("PASS: fix-persistence USD open association (R-70)")
}
try fixPersistenceChecks()
