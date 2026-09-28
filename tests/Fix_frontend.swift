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
  show(page: 0)
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

  // R-86: a colour-panel burst records one undo step.
  try reset()
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
  let save = views(ActionButton.self, in: controller.view).first { $0.title == "Save" }!
  require(!save.isEnabled && !pauseButton.isEnabled, "toolbar disables during export")
  controller.exportRenderer = nil
  require(save.isEnabled, "toolbar re-enables after export")
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
  require(views(ActionButton.self, in: controller.stack).filter { $0.title == "Frame all imported objects" }.count == 1,
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
}
try fixFrontendChecks()
