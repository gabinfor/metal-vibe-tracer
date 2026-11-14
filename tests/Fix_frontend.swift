// Regression checks for inspector editing, viewport input, menus, errors and window state.
@MainActor func fixFrontendChecks() throws {
  let folder = studioDirectory.absoluteURL.appendingPathComponent("fix-frontend", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let history = controller.history
  let savedAutosaveURL = controller.autosaveURL
  controller.autosaveURL = folder.appendingPathComponent("Autosave.vtrace")
  let wasGroupingByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer {
    controller.saveTimer?.invalidate()
    controller.autosaveURL = savedAutosaveURL
    history.groupsByEvent = wasGroupingByEvent
  }
  func grouped(_ body: () throws -> Void) rethrows {
    history.beginUndoGrouping()
    defer { history.endUndoGrouping() }
    try body()
  }
  func reset() throws {
    controller.saveTimer?.invalidate()
    try controller.restore(ProjectDocument())
    controller.associate(nil, edited: false, replaced: true)
    controller.saveTimer?.invalidate()
    history.removeAllActions()
    controller.lastCheckpoint = .distantPast
  }
  func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
  }
  func control(_ label: String) -> NumberControl? {
    views(NumberControl.self, in: controller.stack).first { $0.field.accessibilityLabel() == label }
  }
  func show(page: Int) {
    controller.page = page
    controller.rebuild()
    controller.view.layoutSubtreeIfNeeded()
  }
  try reset()

  // R-02, R-90: an unchanged commit is ignored; locale decimals parse; invalid text reverts.
  var commits: [Float] = []
  var rejected: String?
  let number = NumberControl("Probe", value: 1, range: 0...10, defaultValue: 1, entry: -100...100) {
    commits.append($0)
  }
  number.onReject = { rejected = $0 }
  number.typed()
  require(commits.isEmpty, "ending editing with the displayed text commits nothing")
  number.field.stringValue = " 50 "
  number.typed()
  require(commits == [50] && number.slider.floatValue == 10, "typed values reach the entry range beyond the slider")
  number.field.stringValue = "abc"
  number.typed()
  require(commits == [50] && number.field.stringValue == "50" && rejected != nil,
    "invalid text reverts to the model value with a message")
  require(NumberControl.parse("0,25", locale: Locale(identifier: "fr_FR")) == 0.25
    && NumberControl.parse(" 1.5\n") == 1.5, "comma decimals and whitespace parse")
  print("PASS: fix-frontend NumberControl commits, entry range and parsing (R-02, R-87, R-90)")

  // R-02: a focused field does not re-commit its stale value when undo rebuilds the inspector.
  show(page: 1)
  let exposure = control("Exposure, EV")!
  grouped {
    exposure.field.stringValue = "2"
    exposure.typed()
  }
  require(testRenderer.options.exposure == 2, "typed exposure applies")
  _ = testWindow.makeFirstResponder(control("Exposure, EV")!.field)
  history.undo()
  require(testRenderer.options.exposure == 0 && history.canRedo, "undo with a focused field restores the value")
  history.redo()
  require(testRenderer.options.exposure == 2, "redo still applies")
  // A graph transform field with pending text, then a restore that removes the graph.
  var withGraph = ProjectDocument()
  let root = try withGraph.appendOBJ(obj, name: "quad")
  try controller.restore(withGraph)
  let child = controller.project.graph!.nodes.first { $0.parent != nil && $0.mesh != nil }!.id
  controller.selectedNode = child
  show(page: 4)
  let translation = control("Translation X")!
  _ = testWindow.makeFirstResponder(translation.field)
  translation.field.stringValue = "0.5"
  try controller.restore(ProjectDocument())
  require(controller.project.graph == nil && testRenderer.materials.triangleCount == 0,
    "restoring over a focused graph field neither crashes nor edits the new document")
  var removed = SceneGraph()
  _ = try removed.addOBJ(obj, name: "quad")
  do {
    _ = try removed.nodeIndex(root)
    require(false, "missing nodes throw instead of trapping")
  } catch {
    require(error.localizedDescription == "Object was removed.", "missing node message")
  }
  _ = testWindow.makeFirstResponder(nil)
  print("PASS: fix-frontend focused fields during undo/restore and safe node lookups (R-02, R-43)")

  // R-42, R-85, R-88: drag threshold, click selection without edits, scroll deltas.
  try reset()
  let viewport = controller.viewport
  let originalPick = viewport.onPick, originalBegin = viewport.onBeginEdit
  var picks = 0, began = 0
  viewport.onPick = { _ in picks += 1 }
  viewport.onBeginEdit = { began += 1; originalBegin?() }
  defer {
    viewport.onPick = originalPick
    viewport.onBeginEdit = originalBegin
  }
  func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: viewport.convert(NSPoint(x: 100 + x, y: 100), to: nil), modifierFlags: [],
      timestamp: 0, windowNumber: testWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
      pressure: 1)!
  }
  let yaw = testRenderer.yaw
  viewport.mouseDown(with: mouse(.leftMouseDown, 0))
  viewport.mouseDragged(with: mouse(.leftMouseDragged, 1))
  viewport.mouseDragged(with: mouse(.leftMouseDragged, 2))
  viewport.mouseUp(with: mouse(.leftMouseUp, 2))
  require(picks == 1 && began == 0 && testRenderer.yaw == yaw && !controller.documentEdited,
    "a click with jitter picks without moving the camera or marking the document edited")
  grouped {
    viewport.mouseDown(with: mouse(.leftMouseDown, 0))
    for step in 1...6 { viewport.mouseDragged(with: mouse(.leftMouseDragged, CGFloat(step))) }
    viewport.mouseUp(with: mouse(.leftMouseUp, 6))
  }
  require(picks == 1 && began == 1 && abs(testRenderer.yaw - (yaw + 6 * 0.007)) < 1e-5
    && history.undoActionName == "Camera", "a slow drag orbits by its full travel with one undo step")
  history.removeAllActions()
  let silent = NSEvent(cgEvent: CGEvent(
    scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)!)!
  viewport.scrollWheel(with: silent)
  require(began == 1 && !history.canUndo, "zero-delta scrolls register no camera step")
  let notch = NSEvent(cgEvent: CGEvent(
    scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!
  let distance = testRenderer.distance
  controller.lastCheckpoint = .distantPast
  grouped { viewport.scrollWheel(with: notch) }
  let expected = exp(-Float(notch.scrollingDeltaY) * 10 * 0.015)
  require(!notch.hasPreciseScrollingDeltas && notch.scrollingDeltaY != 0
    && abs(testRenderer.distance / distance - expected) < 1e-3, "line scroll deltas are scaled for notched wheels")
  print("PASS: fix-frontend drag threshold, click picking and scroll zoom (R-42, R-85, R-88)")

  // R-86: a colour-panel burst records one undo step (the Cornell Box has the Light color row).
  try reset()
  var cornell = ProjectDocument()
  cornell.scene = 1
  try controller.restore(cornell)
  history.removeAllActions()
  show(page: 2)
  let well = views(ActionColor.self, in: controller.stack).first { $0.accessibilityLabel() == "Light color" }!
  for (i, red) in [0.2, 0.4, 0.6].enumerated() {
    grouped {
      well.color = NSColor(srgbRed: red, green: 0.5, blue: 0.5, alpha: 1)
      well.changed()
    }
    if i == 0 { require(history.undoActionName == "Light color", "first colour change is undoable") }
  }
  let finalColor = testRenderer.options.lightColor
  history.undo()
  require(testRenderer.options.lightColor == finalColor, "later colour changes in a burst add no snapshots")
  while history.canUndo { history.undo() }
  require(testRenderer.options.lightColor == SIMD3<Float>(repeating: 1), "one undo step restores the colour")
  print("PASS: fix-frontend coalesced colour undo (R-86)")

  // R-87, R-89: camera fields refresh after navigation; wide ranges; pages reveal the inspector.
  try reset()
  show(page: 1)
  testRenderer.target = SIMD3(7, 0, 0)
  viewport.onUserOrbit?()
  waitUntil({ control("Target X")?.displayed == "7" })
  let target = control("Target X")!
  grouped {
    target.field.stringValue = "250"
    target.typed()
  }
  require(testRenderer.target.x == 250, "camera target accepts values beyond the slider range")
  testRenderer.target = .zero
  testRenderer.setEye(SIMD3(0, 0, 0.01))
  require(abs(testRenderer.distance - 0.01) < 1e-6, "small eye offsets are applied")
  testRenderer.setEye(SIMD3(0, 0, 5000))
  require(abs(testRenderer.distance - 5000) < 0.01, "far eye positions are not capped at 1000")
  controller.inspectorAction()
  require(!controller.sidebarVisible, "inspector hidden")
  controller.exportAction()
  require(controller.sidebarVisible && controller.page == 5, "Export reveals the hidden inspector")
  print("PASS: fix-frontend camera field refresh and limits, page reveal (R-87, R-89)")

  // R-47: map previews are cached small thumbnails.
  let large = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let largePNG = large.representation(using: .png, properties: [:])!
  let thumbnail = controller.mapThumbnail(largePNG, index: 4)
  require(thumbnail != nil && max(thumbnail!.size.width, thumbnail!.size.height) <= 160
    && controller.mapThumbnail(largePNG, index: 4) === thumbnail, "map previews are cached thumbnails")
  print("PASS: fix-frontend cached map thumbnails (R-47)")

  // R-91, R-92, R-94: accessibility labels, toolbar refresh, persistent errors.
  show(page: 0)
  require(views(ActionPopup.self, in: controller.stack).contains { $0.accessibilityLabel() == "Sampling strategy" },
    "popups carry accessibility labels")
  let pauseButton = controller.pauseButton!
  testRenderer.paused = true
  require(pauseButton.title == "Resume", "pause label refreshes without a frame")
  testRenderer.paused = false
  require(pauseButton.title == "Pause", "resume label refreshes without a frame")
  controller.exportRenderer = testRenderer
  let restartButton = views(ActionButton.self, in: controller.view).first { $0.title == "Restart" }!
  require(!restartButton.isEnabled && !pauseButton.isEnabled && controller.viewModePopup?.isEnabled == false,
    "toolbar disables during export")
  controller.exportRenderer = nil
  require(restartButton.isEnabled && controller.viewModePopup?.isEnabled == true, "toolbar re-enables after export")
  controller.showError("Import failed:\nTraceback line")
  controller.messageUntil = .distantPast
  controller.updateStatus()
  require(controller.errorMessage == "Import failed:\nTraceback line" && !controller.errorButton.isHidden
    && controller.errorButton.title.contains("Import failed"), "errors stay visible after the status clears")
  controller.dismissError()
  require(controller.errorButton.isHidden && controller.errorMessage == nil, "errors can be dismissed")
  print("PASS: fix-frontend accessibility labels, toolbar state and persistent errors (R-91, R-92, R-94)")

  // R-131, R-132: one framing button; standard menus; project name in the title.
  var framed = ProjectDocument()
  _ = try framed.appendOBJ(obj, name: "quad")
  try controller.restore(framed)
  controller.selectedNode = nil
  show(page: 4)
  require(views(ActionButton.self, in: controller.stack).filter { $0.title == "Frame All" }.count == 1,
    "Objects panel has one framing button")
  let items = NSApp.mainMenu!.items.flatMap { $0.submenu?.items ?? [] }
  for (key, action) in [("w", #selector(NSWindow.performClose(_:))), ("m", #selector(NSWindow.performMiniaturize(_:))),
    ("h", #selector(NSApplication.hide(_:)))] {
    require(items.contains { $0.keyEquivalent == key && $0.action == action }, "standard ⌘\(key) menu item")
  }
  require(NSApp.windowsMenu != nil, "Window menu is registered")
  let named = folder.appendingPathComponent("Named.vtrace")
  controller.associate(named, edited: false, replaced: true)
  require(testWindow.title == "Named.vtrace" && testWindow.representedURL == named, "window shows the project file")
  controller.associate(nil, edited: false, replaced: true)
  require(testWindow.title == "Untitled", "untitled projects are named in the window")
  try reset()
  show(page: 0)
  print("PASS: fix-frontend single framing button, standard menus and window title (R-131, R-132)")

  // Control kit: steps, precision, logarithmic sliders, snapping, zero text and arrow-key steps.
  require(NumberControl.niceStep(near: 0.16) == 0.2 && NumberControl.niceStep(near: 0.007) == 0.005
    && NumberControl.automaticStep(0...1, integral: false) == 0.005 && NumberControl.automaticStep(1...64, integral: true) == 1
    && NumberControl.decimals(for: 1) == 0 && NumberControl.decimals(for: 0.5) == 1 && NumberControl.decimals(for: 0.05) == 2,
    "1–2–5 steps and their decimal places")
  var probeValue: Float = 0
  let weight = NumberControl("Weight", value: 0.15, range: 0...1, defaultValue: 0.5, entry: -10...10, step: 0.01) {
    probeValue = $0
  }
  require(weight.scale == .linear && weight.field.stringValue == "0.15", "a 0–1 weight shows two decimals, trimmed")
  weight.set(4.599999)
  require(weight.field.stringValue == "4.6" && probeValue == 4.599999, "computed values show without float noise")
  weight.field.stringValue = "0.1234"
  weight.typed()
  require(probeValue == Float("0.1234")! && weight.field.stringValue == "0.1234", "typed values are kept as typed")
  require(weight.value(atPosition: 0.123) == 0.12 && abs(weight.value(atPosition: 0.123, snapping: false) - 0.123) < 1e-6,
    "slider values snap to the step unless snapping is off")
  weight.set(0.5)
  weight.nudge(1)
  require(probeValue == 0.51, "↑ steps by one step")
  weight.nudge(1, modifiers: .shift)
  require(abs(probeValue - 0.61) < 1e-6, "⇧↑ steps by ten")
  weight.nudge(-1, modifiers: .option)
  require(abs(probeValue - 0.609) < 1e-6, "⌥↓ steps by a tenth")
  let depth = NumberControl("Depth", value: 16, range: 1...64, defaultValue: 16, integral: true) { probeValue = $0 }
  depth.field.stringValue = "7.6"
  depth.typed()
  require(probeValue == 8 && depth.field.stringValue == "8", "integral controls round and show no decimals")
  for (range, label) in [(Float(0)...10000, "0…10000"), (Float(0.01)...1000, "0.01…1000"), (Float(0)...16384, "0…16384")] {
    let log = NumberControl("Log", value: range.lowerBound, range: range, defaultValue: range.lowerBound) { _ in }
    require(log.scale == .logarithmic && log.position(of: range.lowerBound) == 0 && log.position(of: range.upperBound) == 1
      && log.value(atPosition: 0) == range.lowerBound && log.value(atPosition: 1) == range.upperBound,
      "a logarithmic slider maps \(label) exactly at its ends")
    let middle = log.value(atPosition: 0.5)
    require(middle > range.lowerBound && middle < (range.lowerBound + range.upperBound) / 10
      && abs(log.position(of: middle) - 0.5) < 0.02, "a logarithmic slider spends its middle on small values (\(label))")
  }
  require(NumberControl.automaticScale(0...100) == .linear && NumberControl.automaticScale(-10...10) == .linear,
    "narrow or signed ranges stay linear")
  let limit = NumberControl("Limit", value: 0, range: 0...16384, defaultValue: 0, integral: true, zeroText: "Unlimited") {
    probeValue = $0
  }
  require(limit.field.stringValue == "Unlimited", "zero shows as its zero text")
  limit.field.stringValue = "200"
  limit.typed()
  limit.field.stringValue = "unlimited"
  limit.typed()
  require(probeValue == 0 && limit.field.stringValue == "Unlimited", "the zero text is accepted when typed")
  // The reset button shows only away from the default.
  let resettable = NumberControl("Resettable", value: 1, range: 0...10, defaultValue: 1) { probeValue = $0 }
  require(resettable.resetButton?.isHidden == true, "reset hidden at the default")
  resettable.set(3)
  require(resettable.resetButton?.isHidden == false, "reset shown away from the default")
  resettable.resetToDefault()
  require(probeValue == 1 && resettable.resetButton?.isHidden == true, "reset restores the default and hides")
  // A non-live control: the field tracks the knob, one commit on release.
  var nonLiveCommits: [Float] = []
  let heavy = NumberControl("Heavy", value: 0, range: 0...10, defaultValue: 0, step: 1) { nonLiveCommits.append($0) }
  heavy.beginDrag()
  for v in [2.2, 4.4, 6.6] {
    heavy.slider.doubleValue = v
    heavy.slid()
  }
  require(nonLiveCommits.isEmpty && heavy.field.stringValue == "7", "a non-live drag shows the knob's value without committing")
  heavy.endDrag()
  require(nonLiveCommits == [7], "a non-live drag commits once on release")
  print("PASS: fix-frontend number rows: steps, precision, typed values, log mapping, snapping, zero text, reset, non-live")

  // A live slider drag is one undo step, and a rebuild during the drag waits for its end.
  try reset()
  show(page: 1)
  let fov = control("Field of view, °")!
  let fovBefore = testRenderer.fov
  // Each change arrives in its own run-loop pass, as mouse events do: any undo step it registered would be its own group.
  history.groupsByEvent = true
  fov.beginDrag()
  for v in [50.0, 60.0, 70.0] {
    fov.slider.doubleValue = v
    fov.slid()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    if v == 60 {
      controller.rebuild()
      require(fov.superview != nil && control("Field of view, °") === fov,
        "a rebuild during a drag keeps the dragged slider")
    }
  }
  require(testRenderer.fov == 70, "a live drag applies its value while dragging")
  fov.endDrag()
  RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  history.groupsByEvent = false
  require(fov.superview == nil && control("Field of view, °") != nil, "the deferred rebuild runs when the drag ends")
  history.undo()
  require(testRenderer.fov == fovBefore && !history.canUndo, "one undo step undoes the whole drag")
  print("PASS: fix-frontend live slider drag: one undo step, rebuild deferred to the drag's end")

  // Row builders: toggle, vector, colour and collapsible sections.
  try reset()
  show(page: 0)
  var toggled: Bool?
  let probeSwitch = controller.toggle("Probe switch", false, reset: false) { toggled = $0 }
  probeSwitch.state = .on
  grouped { probeSwitch.invoke() }
  require(toggled == true && history.undoActionName == "Probe switch" && probeSwitch.accessibilityLabel() == "Probe switch"
    && probeSwitch.controlSize == .small, "a toggle row reports its state with one undo step")
  history.removeAllActions()
  var vectorValue = SIMD3<Float>(1, 2, 3)
  let probeVector = controller.vector("Probe offset", vectorValue, -10...10, .zero) { vectorValue = $0 }
  let ySlot = probeVector.components[1]
  require(ySlot.field.accessibilityLabel() == "Probe offset Y" && probeVector.resetButton.isHidden == false,
    "vector fields are labelled per component")
  ySlot.field.stringValue = " 4.5 "
  grouped { ySlot.typed() }
  ySlot.field.stringValue = "x"
  ySlot.typed()
  require(vectorValue == SIMD3(1, 4.5, 3) && ySlot.field.stringValue == "4.5", "a vector field parses one component")
  grouped { probeVector.resetToDefault() }
  require(vectorValue == .zero && probeVector.resetButton.isHidden && probeVector.components.allSatisfy { $0.field.stringValue == "0" },
    "the vector reset restores the triple")
  history.undo()
  history.undo()
  require(!history.canUndo, "each vector edit and the reset are one undo step")
  controller.forceSectionsOpen = false
  controller.preferences.removeObject(forKey: "InspectorSection.probe")
  var built = 0
  controller.collapsible("Probe section", key: "probe") { built += 1 }
  let disclosure = views(ActionButton.self, in: controller.stack).first { $0.identifier?.rawValue == "section-probe" }!
  require(built == 0 && disclosure.state == .off, "a collapsible section starts closed")
  disclosure.invoke()
  require(controller.preferences.bool(forKey: "InspectorSection.probe"), "opening a section is remembered")
  controller.collapsible("Probe section", key: "probe") { built += 1 }
  controller.forceSectionsOpen = true
  controller.preferences.set(false, forKey: "InspectorSection.probe")
  controller.collapsible("Probe section", key: "probe") { built += 1 }
  require(built == 2, "an open or forced-open section builds its body")
  controller.preferences.removeObject(forKey: "InspectorSection.probe")
  print("PASS: fix-frontend toggle, vector and collapsible rows")

  // Shell: tab bar, scene title, inspector width, status bar.
  show(page: 0)
  let tabs = controller.tabBar!
  require((0..<tabs.segmentCount).map { tabs.label(forSegment: $0) } == StudioController.pageTitles
    && tabs.selectedSegment == 0, "the tab bar lists the six tabs")
  tabs.selectedSegment = 2
  tabs.invoke()
  require(controller.page == 2 && controller.tabBar?.selectedSegment == 2, "the tab bar switches pages")
  try controller.restore(framed)
  controller.catalogSceneTitle = "Probe Scene"
  func stackLabels() -> [String] { views(NSTextField.self, in: controller.stack).map(\.stringValue) }
  require(stackLabels().contains("Probe Scene"), "a scene opened from the browser shows its catalog title")
  controller.associate(folder.appendingPathComponent("Saved.vtrace"), edited: false, replaced: false)
  require(controller.catalogSceneTitle == nil && stackLabels().contains("Saved.vtrace"), "saving names the scene by its file")
  controller.associate(nil, edited: false, replaced: true)
  controller.setInspectorWidth(1000)
  require(controller.sidebarWidth.constant == 520
    && controller.preferences.double(forKey: StudioController.inspectorWidthKey) == 520, "the inspector width is clamped and remembered")
  controller.inspectorAction()
  require(controller.sidebarWidth.constant == 0 && controller.sidebar.isHidden, "the inspector hides")
  controller.inspectorAction()
  require(controller.sidebarWidth.constant == 520, "the inspector reopens at its remembered width")
  controller.preferences.removeObject(forKey: StudioController.inspectorWidthKey)
  controller.setInspectorVisible(true)
  require((340...380).contains(controller.sidebarWidth.constant), "the default width fits the tab labels")
  require(StudioController.renderStatus(state: "Rendering", samples: 128, limit: 1024, elapsed: 12.34)
    == "Rendering · 128 / 1024 samples · 12.3 s"
    && StudioController.renderStatus(state: "Paused", samples: 1, limit: 0, elapsed: 0) == "Paused · 1 sample · 0.0 s"
    && StudioController.frameStatus(fps: 5, gpuMilliseconds: 81.2, width: 780, height: 740) == "5.0 fps · 81 ms GPU · 780×740",
    "status texts")
  controller.messageUntil = .distantPast
  testRenderer.options.maxSamples = 1024
  controller.updateStatus()
  require(controller.status.stringValue.contains(" / 1024 samples") && controller.statusDetail.stringValue.contains("fps"),
    "the status shows the sample target: \(controller.status.stringValue)")
  testRenderer.options.maxSamples = 0
  controller.updateStatus()
  require(controller.status.stringValue.contains(" sample") && !controller.status.stringValue.contains("/"),
    "the status shows the samples alone without a limit: \(controller.status.stringValue)")
  controller.showStartScreen()
  controller.updateStatus()
  require(controller.status.stringValue.isEmpty && controller.statusDetail.stringValue.isEmpty,
    "no render status while the main menu is shown")
  try controller.restore(ProjectDocument())
  controller.viewport.isPaused = true
  controller.autosaveQueue.sync {}
  require(controller.startScreen == nil, "a restored document dismisses the main menu")
  print("PASS: fix-frontend tab bar, catalog scene title, inspector width and status bar")
  try reset()
  show(page: 0)
}
try fixFrontendChecks()
