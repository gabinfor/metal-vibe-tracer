// The Render tab (InspectorRender.swift): sections and their controls per scene and strategy, the collapsed Advanced
// section, the Preview resolution popup (with a Custom item), "Unlimited" / "Off" zero texts, toggles and popups with
// one undo step each, and Reset Render Settings (one undo step, GPU memory preflight).
@MainActor func fixUIRenderChecks() throws {
  let history = controller.history
  let folder = studioDirectory.absoluteURL.appendingPathComponent("fix-ui-render", isDirectory: true)
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
    controller.forceSectionsOpen = true
    controller.preferences.removeObject(forKey: "InspectorSection.render.advanced")
    controller.dismissError()
  }
  func grouped(_ body: () throws -> Void) rethrows {
    history.beginUndoGrouping()
    defer { history.endUndoGrouping() }
    try body()
  }
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
  func popups() -> [String] { views(ActionPopup.self, in: controller.stack).compactMap { $0.accessibilityLabel() } }
  func popup(_ label: String) -> ActionPopup {
    let found = views(ActionPopup.self, in: controller.stack).filter { $0.accessibilityLabel() == label }
    require(found.count == 1, "the Render tab has one “\(label)” popup")
    return found[0]
  }
  func number(_ label: String) -> NumberControl? {
    views(NumberControl.self, in: controller.stack).first { $0.field.accessibilityLabel() == label }
  }
  func switches() -> [String] { views(ActionSwitch.self, in: controller.stack).compactMap { $0.accessibilityLabel() } }
  func toggleSwitch(_ label: String) -> ActionSwitch {
    let found = views(ActionSwitch.self, in: controller.stack).filter { $0.accessibilityLabel() == label }
    require(found.count == 1, "the Render tab has one “\(label)” switch")
    return found[0]
  }
  func button(_ title: String) -> ActionButton? {
    views(ActionButton.self, in: controller.stack).first { $0.title == title }
  }
  func texts() -> [String] { views(NSTextField.self, in: controller.stack).map(\.stringValue) }
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
  func flip(_ label: String) {
    let control = toggleSwitch(label)
    control.state = control.isOn ? .off : .on
    grouped { control.invoke() }
  }
  // One change: `body` makes it, then exactly one undo step named `name` restores `state`.
  func oneUndoStep<T: Equatable>(_ name: String, _ state: () -> T, _ body: () -> Void) {
    history.removeAllActions()
    let before = state()
    body()
    require(state() != before && history.canUndo && history.undoActionName == name, "\(name) changes the setting with an undo step")
    history.undo()
    waitUntil({ !controller.isBusy })
    require(state() == before && !history.canUndo, "one undo step restores \(name)")
    controller.rebuild()
  }
  var cornell = ProjectDocument()
  cornell.scene = 1
  var ring = ProjectDocument()
  ring.scene = 5

  // Sections and their controls on Cornell Box with ReSTIR; the Display controls are gone.
  try reset(cornell)
  let headings = texts()
  let order = ["Quality", "Method", "Denoising"].map { headings.firstIndex(of: $0) ?? -1 }
  require(order.allSatisfy { $0 >= 0 } && order == order.sorted(), "Quality, Method and Denoising headings in order")
  require(views(NSButton.self, in: controller.stack).contains { $0.identifier?.rawValue == "section-render.advanced" },
    "an Advanced disclosure")
  let expectedPopups = [
    "Preview resolution", "Sampling strategy", "Light transport", "Caustics", "OIDN quality", "OIDN guides", "Sampler",
    "Light sampling", "Indirect reuse", "Spatial neighbours", "Temporal reuse", "Path shading",
  ]
  require(popups() == expectedPopups, "the Render tab's popups, in order: \(popups())")
  require(views(NumberControl.self, in: controller.stack).map { $0.field.accessibilityLabel() ?? "" }
    == ["Path depth", "Sample limit", "Time limit, seconds", "Indirect clamp"],
    "number rows: path depth, limits and the clamp (no divider while MetalFX is off)")
  require(switches() == ["MetalFX preview", "Treat guides as noisy", "Robust HDR input scale", "Diffuse firefly suppression"],
    "switches: MetalFX and the three OIDN options; no ring boost on Cornell Box")
  require(!popups().contains("Viewport mode") && !popups().contains("Tone map") && number("Exposure, EV") == nil
    && number("White balance, cool → warm") == nil, "the display controls left the Render tab")
  require(button("Denoise Current Frame")?.isEnabled == true && button("Clear Denoised Preview")?.isEnabled == false,
    "Denoise Current Frame, and Clear Denoised Preview disabled without a preview")
  let resetButton = controller.stack.arrangedSubviews.last as? ActionButton
  require(resetButton?.title == "Reset Render Settings" && resetButton?.isEnabled == false,
    "Reset Render Settings ends the tab, disabled at the defaults")
  for label in expectedPopups {
    require(!(popup(label).toolTip ?? "").isEmpty && popup(label).accessibilityHelp() == popup(label).toolTip,
      "“\(label)” explains itself in a tooltip")
  }
  require(!texts().contains { $0.hasPrefix("Caps the luminance") }, "the indirect clamp's explanation is a tooltip")
  print("PASS: fix-ui-render sections and controls on Cornell Box")

  // Number rows: zero texts, steps and scales.
  require(number("Sample limit")?.field.stringValue == "Unlimited" && number("Time limit, seconds")?.field.stringValue == "Unlimited"
    && number("Indirect clamp")?.field.stringValue == "Off", "0 shows as Unlimited and Off")
  require(number("Sample limit")?.scale == .logarithmic && number("Time limit, seconds")?.scale == .logarithmic
    && number("Indirect clamp")?.scale == .logarithmic && number("Path depth")?.scale == .linear
    && number("Path depth")?.step == 1 && number("Path depth")?.integral == true && number("Path depth")?.field.stringValue == "16",
    "limits and the clamp are logarithmic; path depth is whole numbers 1–64")
  let clamp = number("Indirect clamp")!
  clamp.field.stringValue = "20"
  grouped { clamp.typed() }
  require(testRenderer.options.indirectClamp == 20 && history.undoActionName == "Indirect clamp", "a typed clamp applies")
  controller.rebuild()
  let clampOff = number("Indirect clamp")!
  clampOff.field.stringValue = "off"
  grouped { clampOff.typed() }
  require(testRenderer.options.indirectClamp == nil && clampOff.field.stringValue == "Off", "typing Off clears the clamp")
  let limit = number("Sample limit")!
  limit.field.stringValue = "100000"
  grouped { limit.typed() }
  require(testRenderer.options.maxSamples == 100_000, "a typed sample limit may exceed the slider's range")
  limit.field.stringValue = "unlimited"
  grouped { limit.typed() }
  require(testRenderer.options.maxSamples == 0, "typing Unlimited clears the sample limit")
  print("PASS: fix-ui-render number rows: Unlimited, Off, steps and scales")

  // Preview resolution: the listed percentages, a Custom item for other values, one undo step and a restart.
  try reset(cornell)
  require(popup("Preview resolution").itemTitles == ["25%", "33%", "50%", "67%", "75%", "100%"]
    && popup("Preview resolution").indexOfSelectedItem == 2, "the default preview resolution is 50%")
  testRenderer.options.previewScale = 0.4
  controller.rebuild()
  require(popup("Preview resolution").itemTitles.last == "Custom (40%)" && popup("Preview resolution").indexOfSelectedItem == 6,
    "a project value between the choices shows as Custom (40%)")
  // (An empty undo group still counts in canUndo; checkpoint() stamps lastCheckpoint.)
  history.removeAllActions()
  var checkpoint = controller.lastCheckpoint
  pick("Preview resolution", 6)
  require(testRenderer.options.previewScale == 0.4 && controller.lastCheckpoint == checkpoint && history.undoActionName.isEmpty,
    "choosing the Custom item changes nothing")
  history.removeAllActions()
  renderOnce()
  let previewGeneration = testRenderer.interactionGeneration
  pick("Preview resolution", 5)
  require(testRenderer.options.previewScale == 1 && testRenderer.interactionGeneration != previewGeneration
    && history.undoActionName == "Preview resolution" && popup("Preview resolution").itemTitles.count == 6,
    "100% applies with one undo step and restarts accumulation; the Custom item goes")
  history.undo()
  require(testRenderer.options.previewScale == 0.4 && !history.canUndo, "one undo step restores the custom scale")
  testRenderer.options.previewScale = 0.33
  controller.rebuild()
  require(popup("Preview resolution").indexOfSelectedItem == 1 && popup("Preview resolution").itemTitles.count == 6,
    "0.33 shows as 33%")
  print("PASS: fix-ui-render preview resolution popup with Custom")

  // Toggles and popups change the model with one undo step; display and OIDN settings keep the samples.
  try reset(cornell)
  renderOnce()
  let samples = testRenderer.interactionGeneration
  oneUndoStep("Treat guides as noisy", { testRenderer.oidnOptions }) { flip("Treat guides as noisy") }
  oneUndoStep("Robust HDR input scale", { testRenderer.oidnOptions }) { flip("Robust HDR input scale") }
  oneUndoStep("Diffuse firefly suppression", { testRenderer.oidnOptions }) { flip("Diffuse firefly suppression") }
  oneUndoStep("OIDN quality", { testRenderer.oidnOptions }) { pick("OIDN quality", 0) }
  oneUndoStep("OIDN guides", { testRenderer.oidnOptions }) { pick("OIDN guides", 1) }
  require(testRenderer.interactionGeneration == samples, "OIDN settings keep the accumulated samples")
  history.removeAllActions()
  checkpoint = controller.lastCheckpoint
  pick("OIDN quality", Int(testRenderer.oidnOptions.quality))
  require(controller.lastCheckpoint == checkpoint && history.undoActionName.isEmpty,
    "re-selecting the current OIDN quality records nothing")
  if testRenderer.supportsMetalFX {
    oneUndoStep("MetalFX preview", { testRenderer.denoiserEnabled }) { flip("MetalFX preview") }
    flip("MetalFX preview")
    require(testRenderer.denoiserEnabled && testRenderer.interactionGeneration == samples
      && number("Raw / MetalFX divider")?.field.stringValue == "Off" && number("Raw / MetalFX divider")?.step == 0.01,
      "MetalFX keeps the samples and shows the Raw / MetalFX divider, Off at 0")
    flip("MetalFX preview")
    require(!testRenderer.denoiserEnabled && number("Raw / MetalFX divider") == nil, "the divider leaves with MetalFX")
  } else {
    require(!toggleSwitch("MetalFX preview").isEnabled && texts().contains("MetalFX is not supported by this GPU."),
      "MetalFX is disabled with a note on GPUs without it")
  }
  oneUndoStep("Strategy", { testRenderer.samplingMode }) { pick("Sampling strategy", 1) }
  print("PASS: fix-ui-render toggles and popups: one undo step each")

  // Other strategies: no reuse popups, one note; the sampler and light sampling stay.
  testRenderer.samplingMode = 2
  controller.rebuild()
  require(!popups().contains("Indirect reuse") && !popups().contains("Path shading") && popups().contains("Sampler")
    && popups().contains("Light sampling") && texts().filter { $0.contains("apply only to ReSTIR") }.count == 1,
    "a non-ReSTIR strategy shows the note instead of the reuse popups")
  testRenderer.samplingMode = 0

  // Advanced is collapsed by default; opening it is remembered; forced open in tests.
  controller.forceSectionsOpen = false
  controller.preferences.removeObject(forKey: "InspectorSection.render.advanced")
  controller.rebuild()
  let disclosure = views(ActionButton.self, in: controller.stack).first { $0.identifier?.rawValue == "section-render.advanced" }
  require(disclosure?.state == .off && !popups().contains("Sampler") && !switches().contains("Treat guides as noisy")
    && popups().contains("Sampling strategy") && (controller.stack.arrangedSubviews.last as? ActionButton)?.title == "Reset Render Settings",
    "Advanced starts collapsed; Reset Render Settings stays at the bottom")
  disclosure?.invoke()
  require(controller.preferences.bool(forKey: "InspectorSection.render.advanced") && popups().contains("Sampler")
    && popups().contains("Indirect reuse"), "opening Advanced shows its controls and is remembered")
  controller.preferences.set(false, forKey: "InspectorSection.render.advanced")
  controller.forceSectionsOpen = true
  controller.rebuild()
  require(popups().contains("Sampler"), "tests force Advanced open")
  print("PASS: fix-ui-render strategy gating and the collapsible Advanced section")

  // Ring boost: only on the Reflective Ring scene (or while on), one undo step, restarts accumulation.
  try reset(ring)
  require(switches().contains("Ring boost"), "the Reflective Ring scene offers Ring boost")
  renderOnce()
  let ringGeneration = testRenderer.interactionGeneration
  history.removeAllActions()
  flip("Ring boost")
  require(testRenderer.enableSMS == 1 && testRenderer.interactionGeneration != ringGeneration
    && history.undoActionName == "Ring boost", "Ring boost applies with an undo step and restarts accumulation")
  history.undo()
  require(testRenderer.enableSMS == 0 && !history.canUndo, "one undo step turns Ring boost off")
  try reset(cornell)
  testRenderer.enableSMS = 1
  controller.rebuild()
  require(switches().contains("Ring boost"), "Ring boost stays listed elsewhere while on")
  testRenderer.enableSMS = 0
  print("PASS: fix-ui-render Ring boost")

  // An imported scene builds the same sections; caustic light tracing or media explain the Standard MIS fallback.
  var imported = ProjectDocument()
  _ = try imported.appendOBJ(obj, name: "quad")
  try reset(imported)
  require(popups() == expectedPopups && !switches().contains("Ring boost"), "an imported scene shows the same controls")
  require(texts().contains { $0.contains("render with Standard MIS") || $0.contains("renders with Standard MIS") }
    == (testRenderer.activeSamplingMode != testRenderer.samplingMode), "a forced Standard MIS is explained only when it applies")
  print("PASS: fix-ui-render imported scene")

  // The button follows an edit that does not rebuild the tab.
  try reset(cornell)
  grouped { number("Path depth")!.set(8) }
  require(button("Reset Render Settings")?.isEnabled == true, "a number edit enables Reset Render Settings at once")
  grouped { number("Path depth")!.set(16) }
  require(button("Reset Render Settings")?.isEnabled == false, "back at the default it is disabled again")

  // Reset Render Settings: every setting back to its default in one undo step.
  try reset(cornell)
  testRenderer.options.previewScale = 0.25
  testRenderer.options.depth = 4
  testRenderer.options.maxSamples = 64
  testRenderer.options.timeLimit = 30
  testRenderer.options.indirectClamp = 10
  testRenderer.options.compare = 0.5
  testRenderer.samplingMode = 1
  testRenderer.denoiserEnabled = testRenderer.supportsMetalFX
  testRenderer.oidnOptions.quality = 0
  testRenderer.oidnOptions.robustInputScale = true
  testRenderer.enableSMS = 1
  testRenderer.sampler = .pcg
  testRenderer.options.exposure = 1.5
  controller.rebuild()
  let changed = controller.snapshot()
  require(!controller.renderSettingsAreDefault && button("Reset Render Settings")?.isEnabled == true,
    "Reset Render Settings is enabled away from the defaults")
  history.removeAllActions()
  renderOnce()
  let resetGeneration = testRenderer.interactionGeneration
  grouped { button("Reset Render Settings")!.invoke() }
  let o = testRenderer.options
  require(controller.renderSettingsAreDefault && o.previewScale == 0.5 && o.depth == 16 && o.maxSamples == 0 && o.timeLimit == 0
    && o.indirectClamp == nil && o.compare == 0 && testRenderer.samplingMode == 0 && !testRenderer.denoiserEnabled
    && testRenderer.oidnOptions == OIDNOptions() && testRenderer.enableSMS == 0 && ReSTIRModes(testRenderer) == ReSTIRModes.defaults,
    "Reset Render Settings restores the defaults")
  require(o.exposure == 1.5, "Reset Render Settings leaves the Camera tab's exposure alone")
  require(testRenderer.interactionGeneration != resetGeneration && history.undoActionName == "Reset Render Settings"
    && button("Reset Render Settings")?.isEnabled == false, "the reset restarts accumulation with one undo step")
  history.undo()
  waitUntil({ !controller.isBusy })
  let restored = controller.snapshot()
  require(!history.canUndo && restored.options.previewScale == 0.25 && restored.options.depth == 4
    && restored.options.indirectClamp == 10 && restored.strategy == 1 && restored.ring == 1 && restored.oidn == changed.oidn
    && restored.denoise == changed.denoise && testRenderer.sampler == .pcg, "one undo step restores every setting")
  print("PASS: fix-ui-render Reset Render Settings is one undo step")

  // The reset passes the ReSTIR memory preflight: on an imported scene Automatic resolves to a heavier indirect reuse
  // than an explicit ReSTIR GI; when that does not fit (and ReSTIR GI does), nothing changes.
  try reset(imported)
  let defaults = ReSTIRModes.defaults
  testRenderer.indirectReuse = .restirGI
  testRenderer.options.depth = 4
  controller.rebuild()
  renderOnce()
  let size = controller.previewRenderSize!
  func fits(_ bytes: UInt64, _ modes: ReSTIRModes?) -> Bool {
    testRenderer.concurrentRenderBytes = bytes
    return testRenderer.renderMemoryError(
      width: size.width, height: size.height, indirectReuse: modes?.indirectReuse, temporalReuse: modes?.temporalReuse,
      spatialNeighbors: modes?.spatialNeighbors) == nil
  }
  var low: UInt64 = 0, high: UInt64 = 1 << 50
  if fits(low, defaults) && !fits(high, nil) {
    while high - low > 1 {
      let middle = low + (high - low) / 2
      if fits(middle, defaults) { low = middle } else { high = middle }
    }
    if fits(high, nil) {
      testRenderer.concurrentRenderBytes = high
      controller.dismissError()
      history.removeAllActions()
      let before = controller.snapshot().options.depth, modes = ReSTIRModes(testRenderer)
      grouped { button("Reset Render Settings")!.invoke() }
      require(testRenderer.options.depth == before && ReSTIRModes(testRenderer) == modes && history.undoActionName.isEmpty
        && !controller.errorButton.isHidden && controller.errorButton.title.contains("Render settings were not reset"),
        "a reset whose modes exceed the GPU memory budget is refused with an error")
      testRenderer.concurrentRenderBytes = savedConcurrent
      controller.dismissError()
      grouped { button("Reset Render Settings")!.invoke() }
      require(controller.renderSettingsAreDefault && history.undoActionName == "Reset Render Settings",
        "the same reset applies once memory allows it")
      print("PASS: fix-ui-render Reset Render Settings memory preflight")
    } else {
      print("SKIP: fix-ui-render reset preflight (the default modes need no more memory here)")
    }
  } else {
    print("SKIP: fix-ui-render reset preflight (search not bracketed)")
  }
  testRenderer.concurrentRenderBytes = savedConcurrent
  try reset()
}
try fixUIRenderChecks()
