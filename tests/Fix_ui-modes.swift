// Render inspector controls for the ReSTIR reuse modes (IndirectReuse, SpatialNeighborSelection,
// TemporalReuse, ControlVariates): popup items, labels and state; one undo step and an accumulation reset per
// change; strategy gating and edit guards; project round trips, including projects written
// without the fields; "Automatic (currently: …)" per scene; exports; the GPU memory preflight.
@MainActor func fixUIModesChecks() throws {
  let history = controller.history
  let folder = studioDirectory.absoluteURL.appendingPathComponent("fix-ui-modes", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let savedAutosaveURL = controller.autosaveURL
  controller.autosaveURL = folder.appendingPathComponent("Autosave.vtrace")
  let wasGroupingByEvent = history.groupsByEvent
  history.groupsByEvent = false
  let savedModes = ReSTIRModes(testRenderer), savedConcurrent = testRenderer.concurrentRenderBytes
  let savedFrameUpdate = testRenderer.onFrameUpdate
  defer {
    controller.saveTimer?.invalidate()
    controller.autosaveURL = savedAutosaveURL
    history.groupsByEvent = wasGroupingByEvent
    testRenderer.concurrentRenderBytes = savedConcurrent
    testRenderer.onFrameUpdate = savedFrameUpdate
    savedModes.apply(testRenderer)
    controller.dismissError()
  }
  func grouped(_ body: () throws -> Void) rethrows {
    history.beginUndoGrouping()
    defer { history.endUndoGrouping() }
    try body()
  }
  func idle() { waitUntil({ !controller.isBusy }, seconds: 60) }
  func reset(_ document: ProjectDocument = ProjectDocument()) throws {
    controller.saveTimer?.invalidate()
    try controller.restore(document)
    controller.associate(nil, edited: false, replaced: true)
    controller.saveTimer?.invalidate()
    history.removeAllActions()
    controller.lastCheckpoint = .distantPast
    controller.page = 0
    controller.rebuild()
  }
  func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
  }
  func popup(_ label: String) -> ActionPopup {
    let found = views(ActionPopup.self, in: controller.stack).filter { $0.accessibilityLabel() == label }
    require(found.count == 1, "the Render page has one “\(label)” popup")
    return found[0]
  }
  func titles(_ label: String) -> [String] { popup(label).itemTitles }
  func renderOnce() {
    var done = false
    testRenderer.onFrameUpdate = { _ in done = true }
    testRenderer.renderFrame(output: studioOutput)
    waitUntil({ done })
    testRenderer.onFrameUpdate = savedFrameUpdate
  }
  func pick(_ label: String, _ index: Int) {
    let control = popup(label)
    control.selectItem(at: index)
    grouped { control.invoke() }
  }
  let indirect = "Indirect reuse", spatial = "Spatial neighbours", temporal = "Temporal reuse", shading = "Path shading"
  let defaults = ReSTIRModes.defaults
  let environment = ProcessInfo.processInfo.environment
  if ["VIBE_INDIRECT_REUSE", "VIBE_SPATIAL_NEIGHBORS", "VIBE_TEMPORAL_REUSE", "VIBE_CONTROL_VARIATES"]
    .allSatisfy({ environment[$0] == nil })
  {
    require(defaults == ReSTIRModes(indirectReuse: .automatic, spatialNeighbors: .automatic, temporalReuse: .automatic,
                                    controlVariates: .automatic),
      "without test overrides every mode defaults to Automatic")
  }
  // Path shading's Automatic resolves with the current reuse modes (ReSTCV needs ReSTIR PT with
  // paired spatial reuse), which the suite-wide overrides may change.
  func automaticShading() -> String {
    testRenderer.resolvedControlVariates(.automatic) == .restcv ? "Control variates" : "Resampled"
  }
  // Items, labels, tooltips and state on a procedural scene.
  var procedural = ProjectDocument()
  procedural.scene = 1
  try reset(procedural)
  require(testRenderer.sceneKernels.pt != nil && testRenderer.sceneKernels.splat != nil,
    "the test library has the ReSTIR PT and splatting kernels")
  require(ReSTIRModes(testRenderer) == defaults, "a project without stored modes restores the defaults")
  require(titles(indirect) == ["Automatic (currently: ReSTIR GI)", "ReSTIR GI", "ReSTIR PT", "ReSTIR PT (unified)"]
    && titles(spatial) == ["Automatic (currently: Uniform)", "Uniform", "Compatibility-guided", "Stochastic pairwise MIS"]
    && titles(temporal) == ["Automatic (currently: Reprojection)", "Reprojection", "Reservoir splatting"]
    && titles(shading) == ["Automatic (currently: \(automaticShading()))", "Control variates", "Resampled"],
    "procedural scenes list the modes and resolve Automatic to ReSTIR GI, uniform neighbours and reprojection")
  if testRenderer.resolvedIndirectReuse(testRenderer.indirectReuse) == .restirGI {
    require(titles(shading)[0] == "Automatic (currently: Resampled)", "ReSTIR GI resolves path shading to resampled")
  }
  for label in [indirect, spatial, temporal, shading] {
    let control = popup(label)
    require(control.isEnabled && !(control.toolTip ?? "").isEmpty && control.accessibilityHelp() == control.toolTip,
      "“\(label)” is enabled with ReSTIR and explains its trade-off")
  }
  let labels = views(NSTextField.self, in: controller.stack).map(\.stringValue)
  require([indirect, spatial, temporal, shading].allSatisfy(labels.contains), "each popup has a visible label")
  func reflects() -> Bool {
    popup(indirect).indexOfSelectedItem == StudioController.indirectReuseChoices.firstIndex { $0.mode == testRenderer.indirectReuse }
      && popup(spatial).indexOfSelectedItem
        == StudioController.spatialNeighborChoices.firstIndex { $0.mode == testRenderer.spatialNeighbors }
      && popup(temporal).indexOfSelectedItem
        == StudioController.temporalReuseChoices.firstIndex { $0.mode == testRenderer.temporalReuse }
      && popup(shading).indexOfSelectedItem
        == StudioController.controlVariateChoices.firstIndex { $0.mode == testRenderer.controlVariates }
  }
  require(reflects(), "the popups show the renderer's modes")
  print("PASS: fix-ui-modes popup items, labels, tooltips and state")

  // Every choice: renderer update, accumulation reset, exactly one undo step, undo and redo.
  func exercise<Mode: Equatable>(_ label: String, _ choices: [(mode: Mode, title: String)], _ current: () -> Mode) {
    for (index, choice) in choices.enumerated() {
      let before = ReSTIRModes(testRenderer), base = current()
      guard choice.mode != base else {
        renderOnce()
        let generation = testRenderer.interactionGeneration, checkpoint = controller.lastCheckpoint
        pick(label, index)
        // (An empty undo group still counts in canUndo; commit() stamps lastCheckpoint.)
        require(controller.lastCheckpoint == checkpoint && history.undoActionName.isEmpty
          && testRenderer.interactionGeneration == generation,
          "re-selecting the current \(label) records nothing and keeps the samples")
        continue
      }
      history.removeAllActions()
      renderOnce()
      require(testRenderer.frameIndex > 0, "accumulation runs before the \(label) change")
      let generation = testRenderer.interactionGeneration
      pick(label, index)
      require(current() == choice.mode && testRenderer.frameIndex == 0 && testRenderer.interactionGeneration != generation
        && controller.documentEdited, "\(label) → \(choice.title) updates the renderer and restarts accumulation")
      require(reflects(), "the rebuilt popup shows \(choice.title)")
      require(history.canUndo && history.undoActionName == label, "\(label) records an undo step")
      history.undo()
      require(!history.canUndo && history.canRedo && ReSTIRModes(testRenderer) == before && reflects(),
        "exactly one undo step restores the previous \(label)")
      history.redo()
      require(current() == choice.mode && !history.canRedo && reflects(), "redo reapplies \(choice.title)")
      history.undo()
      require(ReSTIRModes(testRenderer) == before, "undo returns to the baseline")
    }
  }
  exercise(indirect, StudioController.indirectReuseChoices) { testRenderer.indirectReuse }
  exercise(spatial, StudioController.spatialNeighborChoices) { testRenderer.spatialNeighbors }
  exercise(temporal, StudioController.temporalReuseChoices) { testRenderer.temporalReuse }
  exercise(shading, StudioController.controlVariateChoices) { testRenderer.controlVariates }
  // An undo restoring different modes restarts accumulation even with nothing else changed.
  try reset(procedural)
  // Pick a mode that differs from the current one (VIBE_INDIRECT_REUSE may already select PT).
  let differentIndirect = StudioController.indirectReuseChoices.firstIndex { $0.mode != .automatic
    && $0.mode != testRenderer.resolvedIndirectReuse(testRenderer.indirectReuse) }!
  pick(indirect, differentIndirect)
  renderOnce()
  let beforeUndo = testRenderer.interactionGeneration
  history.undo()
  require(testRenderer.interactionGeneration != beforeUndo && testRenderer.frameIndex == 0,
    "restoring a document with other modes restarts accumulation")
  print("PASS: fix-ui-modes each mode updates the renderer, resets accumulation and undoes in one step")

  // Other strategies disable the popups; edits are ignored while restoring.
  try reset(procedural)
  testRenderer.samplingMode = 1
  controller.rebuild()
  require([indirect, spatial, temporal, shading].allSatisfy { !popup($0).isEnabled }
    && views(NSTextField.self, in: controller.stack).contains { $0.stringValue.contains("apply only to ReSTIR") },
    "non-ReSTIR strategies disable the reuse popups with a note")
  testRenderer.samplingMode = 0
  controller.rebuild()
  let restoringCheckpoint = controller.lastCheckpoint
  controller.isRestoring = true
  pick(indirect, 2)
  controller.isRestoring = false
  require(ReSTIRModes(testRenderer) == defaults && controller.lastCheckpoint == restoringCheckpoint,
    "a popup edit during a restore is ignored")
  print("PASS: fix-ui-modes strategy gating and edit guards")

  // "Automatic (currently: …)" follows the scene: imported scene graph ↔ procedural scene.
  var imported = ProjectDocument()
  _ = try imported.appendOBJ(obj, name: "quad")
  try reset(imported)
  require(titles(indirect)[0] == "Automatic (currently: ReSTIR PT (unified))"
    && titles(spatial)[0] == "Automatic (currently: Compatibility-guided)"
    && titles(temporal)[0] == "Automatic (currently: Reprojection)"
    && titles(shading)[0] == "Automatic (currently: \(automaticShading()))",
    "an imported scene graph resolves Automatic to unified ReSTIR PT and compatibility-guided neighbours")
  if testRenderer.indirectReuse == .automatic && testRenderer.spatialNeighbors == .automatic {
    require(titles(shading)[0] == "Automatic (currently: Control variates)",
      "unified ReSTIR PT resolves path shading to control variates")
  }
  pick(temporal, 2)
  grouped { controller.switchScene(1) }
  idle()
  controller.page = 0
  controller.rebuild()
  require(testRenderer.sceneIndex == 1 && titles(indirect)[0] == "Automatic (currently: ReSTIR GI)"
    && titles(spatial)[0] == "Automatic (currently: Uniform)",
    "switching to a procedural scene updates the Automatic labels")
  require(testRenderer.temporalReuse == .splatting && reflects(), "an explicit choice survives the scene switch")
  history.undo()
  idle()
  controller.page = 0
  controller.rebuild()
  require(testRenderer.sceneIndex == 6 && titles(indirect)[0] == "Automatic (currently: ReSTIR PT (unified))"
    && testRenderer.temporalReuse == .splatting, "undoing the scene switch restores the imported labels")
  print("PASS: fix-ui-modes Automatic labels follow procedural and imported scenes")

  // Project round trips: explicit modes persist; files without the fields open as the default.
  try reset(procedural)
  pick(indirect, 3)
  pick(spatial, 1)
  pick(temporal, 2)
  pick(shading, 2)
  let chosen = ReSTIRModes(indirectReuse: .restirPTUnified, spatialNeighbors: .uniform, temporalReuse: .splatting,
                           controlVariates: .off)
  require(ReSTIRModes(testRenderer) == chosen, "four picks set four modes")
  let saved = try controller.snapshot().encodeForSaving()
  let savedObject = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
  require(savedObject["version"] as? Int == 3 && savedObject["indirectReuse"] as? Int == 2
    && savedObject["spatialNeighbors"] as? Int == 0 && savedObject["temporalReuse"] as? Int == 1
    && savedObject["controlVariates"] as? Int == 0,
    "format 3 stores the four raw modes")
  let reopened = try ProjectDocument.decodeProject(saved, near: nil)
  require(reopened.restirModes == chosen, "a saved project reopens with its modes")
  try reset(procedural)
  require(ReSTIRModes(testRenderer) == defaults, "a new document uses the defaults")
  try controller.restore(reopened)
  controller.rebuild()
  require(ReSTIRModes(testRenderer) == chosen && reflects(), "opening the project applies its modes")
  // An autosave keeps them too.
  let autosave = try controller.snapshot().encodeForAutosave()
  let fromAutosave = try ProjectDocument.decodeProject(autosave.json, near: nil)
  require(fromAutosave.restirModes == chosen, "autosaves keep the modes")
  // Older files: a version 2 project and a format 3 project without the fields.
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(controller.snapshot())) as! [String: Any]
  for key in ["indirectReuse", "spatialNeighbors", "temporalReuse", "controlVariates"] { legacy[key] = nil }
  legacy["version"] = 2
  let old = try ProjectDocument.decodeProject(JSONSerialization.data(withJSONObject: legacy), near: nil)
  require(old.indirectReuse == nil && old.spatialNeighbors == nil && old.temporalReuse == nil && old.controlVariates == nil
    && old.restirModes == defaults, "a version 2 project without the fields decodes as the default")
  // A format 3 project written before path shading was stored opens with its other modes and the
  // default shading.
  var beforeShading = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
  beforeShading["controlVariates"] = nil
  let withoutShading = try ProjectDocument.decodeProject(JSONSerialization.data(withJSONObject: beforeShading), near: nil)
  require(withoutShading.controlVariates == nil && withoutShading.restirModes.indirectReuse == .restirPTUnified
    && withoutShading.restirModes.controlVariates == defaults.controlVariates,
    "a project without the path shading field keeps its other modes and uses the default shading")
  try controller.restore(old)
  require(ReSTIRModes(testRenderer) == defaults, "opening it resets the renderer to Automatic")
  let plain = try ProjectDocument().encodeForSaving()
  let plainText = String(decoding: plain, as: UTF8.self)
  let plainDecoded = try ProjectDocument.decodeProject(plain, near: nil)
  require(!plainText.contains("indirectReuse") && !plainText.contains("controlVariates") && plainDecoded.indirectReuse == nil
    && plainDecoded.restirModes == defaults,
    "a format 3 project without the fields opens as the default")
  // Stochastic pairwise MIS (raw value 3) round-trips like the other spatial selections.
  var stochastic = ProjectDocument()
  stochastic.restirModes = ReSTIRModes(indirectReuse: .automatic, spatialNeighbors: .stochasticPairwise, temporalReuse: .automatic)
  let stochasticDecoded = try ProjectDocument.decodeProject(stochastic.encodeForSaving(), near: nil)
  try stochasticDecoded.validate()
  require(stochasticDecoded.spatialNeighbors == 3 && stochasticDecoded.restirModes.spatialNeighbors == .stochasticPairwise,
    "a project stores and reopens stochastic pairwise MIS")
  for (key, value) in [("indirectReuse", 4), ("spatialNeighbors", 4), ("temporalReuse", 3), ("controlVariates", 3)] {
    var bad = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectDocument())) as! [String: Any]
    bad[key] = value
    var rejected = false
    do { try ProjectDocument.decodeProject(JSONSerialization.data(withJSONObject: bad), near: nil).validate() } catch {
      rejected = true
    }
    require(rejected, "an out-of-range \(key) is rejected")
  }
  print("PASS: fix-ui-modes project, autosave and legacy round trips")

  // Exports use the chosen indirect reuse and neighbours (a still view keeps reprojection).
  try reset(procedural)
  pick(indirect, 2)
  pick(spatial, 2)
  pick(temporal, 2)
  pick(shading, 2)
  let savedOutput = (testRenderer.options.outputWidth, testRenderer.options.outputHeight, testRenderer.options.exportSamples)
  let savedExport = (controller.exportDenoise, controller.exportRaw)
  testRenderer.options.outputWidth = 32
  testRenderer.options.outputHeight = 24
  testRenderer.options.exportSamples = 2
  controller.exportDenoise = false
  controller.exportRaw = true
  let exportURL = folder.appendingPathComponent("modes.png")
  controller.startExport(url: exportURL, hdr: false)
  let export = controller.exportRenderer
  require(export?.indirectReuse == .restirPT && export?.spatialNeighbors == .compatibility
    && export?.temporalReuse == .reprojection && export?.controlVariates == .off, "the export renderer copies the chosen modes")
  waitUntil({ controller.exportRenderer == nil }, seconds: 45)
  require(FileManager.default.fileExists(atPath: exportURL.path), "the export with the chosen modes completes")
  (testRenderer.options.outputWidth, testRenderer.options.outputHeight, testRenderer.options.exportSamples) = savedOutput
  (controller.exportDenoise, controller.exportRaw) = savedExport
  print("PASS: fix-ui-modes exports use the chosen modes")

  // GPU memory preflight: a heavier mode that does not fit is refused, the popup reverts, no
  // undo step is recorded, and the preview keeps rendering with the current modes.
  func rejects(_ label: String, _ index: Int, _ indirectMode: IndirectReuse?, _ temporalMode: TemporalReuse?) throws {
    try reset(procedural)
    pick(indirect, 1)
    pick(temporal, 1)
    history.removeAllActions()
    renderOnce()
    let size = controller.previewRenderSize!
    func fits(_ bytes: UInt64, _ i: IndirectReuse?, _ t: TemporalReuse?) -> Bool {
      testRenderer.concurrentRenderBytes = bytes
      return testRenderer.renderMemoryError(width: size.width, height: size.height, indirectReuse: i, temporalReuse: t) == nil
    }
    // The largest concurrent load at which the heavier mode still fits.
    var low: UInt64 = 0, high: UInt64 = 1 << 50
    require(fits(low, indirectMode, temporalMode) && !fits(high, nil, nil), "the preflight search is bracketed")
    while high - low > 1 {
      let middle = low + (high - low) / 2
      if fits(middle, indirectMode, temporalMode) { low = middle } else { high = middle }
    }
    require(fits(high, nil, nil), "\(label): the current modes fit where the heavier one does not")
    testRenderer.concurrentRenderBytes = high
    controller.dismissError()
    let before = ReSTIRModes(testRenderer), generation = testRenderer.interactionGeneration
    let selected = popup(label).indexOfSelectedItem, checkpoint = controller.lastCheckpoint
    pick(label, index)
    require(ReSTIRModes(testRenderer) == before && popup(label).indexOfSelectedItem == selected
      && controller.lastCheckpoint == checkpoint && history.undoActionName.isEmpty
      && testRenderer.interactionGeneration == generation,
      "\(label): a switch that exceeds the GPU memory budget is refused and the popup reverts")
    require(!controller.errorButton.isHidden && controller.errorButton.title.contains("\(label) was not changed")
      && controller.errorButton.toolTip?.contains("GPU memory") == true, "\(label): the refusal is shown as an error")
    var failure: String?
    let savedError = testRenderer.onError
    testRenderer.onError = { failure = $0 }
    renderOnce()
    testRenderer.onError = savedError
    require(failure == nil && testRenderer.frameIndex > 0, "\(label): rendering continues after the refusal")
    testRenderer.concurrentRenderBytes = savedConcurrent
    controller.dismissError()
    pick(label, index)
    require(ReSTIRModes(testRenderer) != before && history.canUndo, "\(label): the same switch applies once memory allows it")
  }
  try rejects(indirect, 2, .restirPT, nil)
  try rejects(temporal, 2, nil, .splatting)
  print("PASS: fix-ui-modes memory preflight refusal reverts cleanly")

  try reset()
}
try fixUIModesChecks()
