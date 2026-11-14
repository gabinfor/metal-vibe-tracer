// The Export tab, the menu bar, file drops and the inspector shell's pinned header, tab bar and status bar
// (InspectorExport.swift, StudioMenus.swift, AppDelegate.swift, StudioUI.swift, StudioRendering.swift).
@MainActor func fixUIExportMenusChecks() throws {
  let folder = studioDirectory.absoluteURL.appendingPathComponent("fix-ui-export-menus", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let savedAutosaveURL = controller.autosaveURL, savedAnswer = controller.unsavedChangesAnswer
  let savedReveal = controller.revealInFinder, savedReport = controller.importReportShown
  let savedSize = testWindow.contentLayoutRect.size
  let savedExport = (testRenderer.options.outputWidth, testRenderer.options.outputHeight, testRenderer.options.exportSamples)
  let savedSource = (controller.exportDenoise, controller.exportRaw)
  controller.autosaveURL = folder.appendingPathComponent("Autosave.vtrace")
  controller.importReportShown = {}
  let history = controller.history, wasGroupingByEvent = history.groupsByEvent
  history.groupsByEvent = false
  var revealed: [URL] = []
  controller.revealInFinder = { revealed += $0 }
  defer {
    controller.saveTimer?.invalidate()
    history.groupsByEvent = wasGroupingByEvent
    controller.autosaveURL = savedAutosaveURL
    controller.unsavedChangesAnswer = savedAnswer
    controller.revealInFinder = savedReveal
    controller.importReportShown = savedReport
    controller.exportDestination = nil
    testWindow.setContentSize(savedSize)
    (testRenderer.options.outputWidth, testRenderer.options.outputHeight, testRenderer.options.exportSamples) = savedExport
    (controller.exportDenoise, controller.exportRaw) = savedSource
    for key in [StudioController.exportFormatKey, StudioController.exportRevealKey, StudioController.inspectorWidthKey] {
      controller.preferences.removeObject(forKey: key)
    }
    controller.setInspectorVisible(true)
  }
  func idle() { waitUntil({ !controller.isBusy }, seconds: 120) }
  func grouped<T>(_ body: () throws -> T) rethrows -> T {
    history.beginUndoGrouping()
    defer { history.endUndoGrouping() }
    return try body()
  }
  func reset() throws {
    controller.saveTimer?.invalidate()
    try controller.restore(ProjectDocument())
    controller.associate(nil, edited: false, replaced: true)
    controller.saveTimer?.invalidate()
    controller.history.removeAllActions()
  }
  func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
  }
  func show(page: Int) {
    controller.page = page
    controller.rebuild()
    controller.view.layoutSubtreeIfNeeded()
  }
  func valid(_ selector: Selector, tag: Int = 0) -> NSMenuItem? {
    let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
    item.tag = tag
    return controller.validateMenuItem(item) ? item : nil
  }
  func enabled(_ selector: Selector) -> Bool { valid(selector) != nil }
  try reset()

  // The menu bar: menus, items, separators, shortcuts.
  let bar = NSApp.mainMenu!
  func submenu(_ title: String) -> NSMenu { bar.items.first { $0.title == title }!.submenu! }
  func titles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }
  func key(_ menu: NSMenu, _ title: String) -> String? { menu.items.first { $0.title == title }?.keyEquivalent }
  require(titles(bar) == ["Metal Vibe Tracer", "File", "Edit", "Render", "View", "Window", "Help"],
    "the menu bar's menus: \(titles(bar))")
  let app = submenu("Metal Vibe Tracer"), file = submenu("File"), edit = submenu("Edit"), render = submenu("Render")
  let view = submenu("View"), help = submenu("Help")
  require(titles(app) == ["About Metal Vibe Tracer", "", "Hide Metal Vibe Tracer", "Hide Others", "Show All", "",
    "Quit Metal Vibe Tracer"] && app.items[0].action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
    "App menu: \(titles(app))")
  require(titles(file) == ["New Project", "Open Project…", "Open Recent", "Open Scene File…", "Browse Scenes…", "",
    "Save", "Save As…", "", "Add Model…", "Import MaterialX…", "Load Environment Image…", "", "Export…", "",
    "Show Downloaded Scenes in Finder", "", "Close Window"], "File menu: \(titles(file))")
  require(key(file, "New Project") == "n" && key(file, "Open Project…") == "o" && key(file, "Browse Scenes…") == "O"
    && key(file, "Save") == "s" && key(file, "Save As…") == "S" && key(file, "Export…") == "e"
    && key(file, "Close Window") == "w", "File shortcuts")
  require(titles(edit) == ["Undo", "Redo", "", "Cut", "Copy", "Paste", "Select All"], "Edit menu: \(titles(edit))")
  require(titles(render) == ["Pause", "Restart", "", "Denoise Current Frame", "Clear Denoised Preview"]
    && key(render, "Pause") == "p" && key(render, "Restart") == "r", "Render menu: \(titles(render))")
  require(titles(view) == ["Hide Inspector", ""] + StudioController.pageTitles + ["", "Frame Selection", "Frame All", ""]
    + StudioController.viewportNames && key(view, "Hide Inspector") == "i"
    && (0..<6).allSatisfy { key(view, StudioController.pageTitles[$0]) == "\($0 + 1)" }
    && key(view, "Frame Selection") == "f" && key(view, "Frame All") == "F", "View menu: \(titles(view))")
  require(titles(help) == ["User Guide", "Credits and Licenses…"] && NSApp.helpMenu === help
    && NSApp.windowsMenu === submenu("Window"), "Help menu and the registered Window and Help menus")
  print("PASS: fix-ui-export-menus menu bar structure and shortcuts")

  // State-aware titles and checkmarks; ⌘1–⌘6 switch tabs.
  testRenderer.paused = true
  require(valid(#selector(StudioController.pauseAction))?.title == "Resume", "Pause reads Resume while paused")
  testRenderer.paused = false
  require(valid(#selector(StudioController.pauseAction))?.title == "Pause", "Pause reads Pause while rendering")
  require(valid(#selector(StudioController.inspectorAction))?.title == "Hide Inspector", "Hide Inspector while shown")
  controller.inspectorAction()
  require(valid(#selector(StudioController.inspectorAction))?.title == "Show Inspector" && controller.inspectorHeader.isHidden,
    "Show Inspector while hidden; the header hides with the inspector")
  controller.inspectorAction()
  for tab in 0..<6 {
    let item = NSMenuItem(title: "", action: #selector(StudioController.showTabAction(_:)), keyEquivalent: "")
    item.tag = tab
    controller.showTabAction(item)
    require(controller.page == tab && controller.tabBar?.selectedSegment == tab
      && valid(#selector(StudioController.showTabAction(_:)), tag: tab)?.state == .on
      && valid(#selector(StudioController.showTabAction(_:)), tag: (tab + 1) % 6)?.state == .off,
      "⌘\(tab + 1) shows the \(StudioController.pageTitles[tab]) tab with a checkmark")
  }
  require([#selector(StudioController.saveAction), #selector(StudioController.addModelAction),
    #selector(StudioController.importMaterialXAction), #selector(StudioController.loadEnvironmentAction),
    #selector(StudioController.exportAction), #selector(StudioController.newProjectAction)].allSatisfy(enabled)
    && !enabled(#selector(StudioController.clearOIDNAction)), "document commands apply with a document loaded")
  controller.exportRenderer = testRenderer
  require(!enabled(#selector(StudioController.saveAction)) && !enabled(#selector(StudioController.showTabAction(_:)))
    && !enabled(#selector(StudioController.newProjectAction)) && !enabled(#selector(StudioController.addModelAction))
    && enabled(#selector(StudioController.userGuideAction)) && enabled(#selector(StudioController.exampleCreditsAction))
    && controller.tabBar?.isEnabled == false, "while busy only Help, Finder and the inspector toggle apply")
  controller.exportRenderer = nil
  require(controller.tabBar?.isEnabled == true, "the tab bar re-enables")
  print("PASS: fix-ui-export-menus state-aware titles, tab shortcuts and busy validation")

  // The Export tab: size presets, Match Viewport, Custom, source, format and Show in Finder when done.
  show(page: 5)
  func popup(_ label: String) -> ActionPopup? {
    views(ActionPopup.self, in: controller.stack).first { $0.accessibilityLabel() == label }
  }
  func pick(_ label: String, _ index: Int) {
    popup(label)?.selectItem(at: index)
    popup(label)?.invoke()
    controller.view.layoutSubtreeIfNeeded()
  }
  let labels = views(NSTextField.self, in: controller.stack).map(\.stringValue)
  require(["Size", "Quality", "Output", "Preset", "Width", "Height", "Samples", "Source", "Format", "Show in Finder when done"]
    .allSatisfy(labels.contains) && !labels.contains("Project"), "Export tab sections and rows: \(labels)")
  require(popup("Preset").map { $0.itemTitles } == ["Custom", "1280 × 720", "1920 × 1080", "2560 × 1440", "3840 × 2160",
    "1080 × 1080", "Match Viewport"] && popup("Export source")?.itemTitles == ["OIDN denoised", "Raw", "MetalFX display"]
    && popup("Format")?.itemTitles == ["PNG", "OpenEXR"], "Export popups")
  let buttons = views(ActionButton.self, in: controller.stack).map(\.title)
  require(buttons.contains("Render and Export…") && buttons.contains("Save Preview as PNG…")
    && !buttons.contains { $0.lowercased().contains("project") }, "Export buttons, no project buttons: \(buttons)")
  testRenderer.options.outputWidth = 1920; testRenderer.options.outputHeight = 1080
  show(page: 5)
  require(popup("Preset")?.indexOfSelectedItem == 2, "1920 × 1080 selects its preset")
  grouped { pick("Preset", 4) }
  require(testRenderer.options.outputWidth == 3840 && testRenderer.options.outputHeight == 2160
    && popup("Preset")?.indexOfSelectedItem == 4 && controller.history.undoActionName == "Output size", "a preset sets the size, one undo step")
  grouped { pick("Preset", 6) }
  let viewportSize = controller.viewportPixelSize
  require(testRenderer.options.outputWidth == viewportSize.width && testRenderer.options.outputHeight == viewportSize.height
    && viewportSize.width >= 16, "Match Viewport takes the viewport's pixel size: \(viewportSize)")
  testRenderer.options.outputWidth = 1000; testRenderer.options.outputHeight = 777
  show(page: 5)
  require(popup("Preset")?.indexOfSelectedItem == 0 && StudioController.exportSizeIndex(width: 1080, height: 1080) == 5,
    "an unlisted size shows Custom")
  let width = views(NumberControl.self, in: controller.stack).first { $0.field.accessibilityLabel() == "Width" }
  require(width?.live == false && width?.integral == true && width?.minimum == 16 && width?.maximum == 8192,
    "Width: whole numbers 16–8192, committed on release")
  pick("Export source", 1)
  require(!controller.exportDenoise && controller.exportRaw, "Source Raw")
  pick("Export source", 2)
  require(!controller.exportDenoise && !controller.exportRaw, "Source MetalFX display")
  pick("Format", 1)
  require(controller.exportsOpenEXR && controller.preferences.integer(forKey: StudioController.exportFormatKey) == 1,
    "the format is kept in the preferences")
  let edited = controller.documentEdited, undoName = controller.history.undoActionName
  guard let reveal = views(ActionSwitch.self, in: controller.stack).first(where: { $0.accessibilityLabel() == "Show in Finder when done" })
  else { return require(false, "the Show in Finder when done toggle") }
  reveal.state = .on
  reveal.invoke()
  require(controller.preferences.bool(forKey: StudioController.exportRevealKey) && controller.documentEdited == edited
    && controller.history.undoActionName == undoName, "Show in Finder when done is a preference: no undo step, no edit")
  // Render and Export… writes the chosen format and, with the toggle on, reveals the file (through the test hook).
  testRenderer.options.outputWidth = 32; testRenderer.options.outputHeight = 24; testRenderer.options.exportSamples = 2
  controller.exportDenoise = false; controller.exportRaw = true
  var asked: [String] = []
  controller.exportDestination = { ext in asked.append(ext); return folder.appendingPathComponent("export.\(ext)") }
  show(page: 5)
  func renderAndExport() {
    views(ActionButton.self, in: controller.stack).first { $0.title == "Render and Export…" }?.invoke()
    idle()
  }
  renderAndExport()
  let exr = try Data(contentsOf: folder.appendingPathComponent("export.exr"))
  require(asked == ["exr"] && Array(exr.prefix(4)) == [0x76, 0x2f, 0x31, 0x01] && revealed == [folder.appendingPathComponent("export.exr")],
    "OpenEXR writes an EXR file and shows it in the Finder")
  controller.revealsExportInFinder = false
  pick("Format", 0)
  renderAndExport()
  let png = try Data(contentsOf: folder.appendingPathComponent("export.png"))
  require(asked == ["exr", "png"] && Array(png.prefix(4)) == [0x89, 0x50, 0x4e, 0x47] && revealed.count == 1,
    "PNG writes a PNG file; with the toggle off nothing is revealed")
  print("PASS: fix-ui-export-menus Export tab presets, source, format, Render and Export… and Show in Finder")

  // The pinned header: scene row and tab bar above the scrolling page.
  try reset()
  show(page: 0)
  guard let tabs = controller.tabBar else { return require(false, "the tab bar exists") }
  let browse = views(NSButton.self, in: controller.inspectorHeader).first { $0.identifier?.rawValue == "scene-browse" }
  require(tabs.isDescendant(of: controller.inspectorHeader) && browse != nil
    && !controller.inspectorHeader.isDescendant(of: controller.sidebar) && !tabs.isDescendant(of: controller.stack)
    && !views(NSButton.self, in: controller.stack).contains { $0.identifier?.rawValue == "scene-browse" },
    "the scene row and tab bar sit in the pinned header, outside the scroll view")
  let headerFrame = controller.inspectorHeader.frame
  controller.sidebar.contentView.scroll(to: NSPoint(x: 0, y: 300))
  controller.sidebar.reflectScrolledClipView(controller.sidebar.contentView)
  controller.view.layoutSubtreeIfNeeded()
  require(controller.inspectorHeader.frame == headerFrame && controller.sidebar.frame.maxY <= headerFrame.minY + 0.5,
    "the header stays put above the page while it scrolls")
  // The tab bar degrades at narrow widths.
  controller.setInspectorWidth(520)
  require(controller.tabBarStyle == .labels && tabs.label(forSegment: 3) == "Materials", "wide: labels")
  controller.setInspectorWidth(280)
  require(controller.tabBarStyle == .symbols && tabs.label(forSegment: 3) == "" && tabs.image(forSegment: 3) != nil
    && tabs.toolTip(forSegment: 3) == "Materials (⌘4)", "at 280 pt each tab is a symbol with its name in the tooltip")
  controller.preferences.removeObject(forKey: StudioController.inspectorWidthKey)
  controller.setInspectorVisible(true)
  require(controller.tabBarStyle != .symbols && tabs.label(forSegment: 0) == "Render", "the default width shows labels")
  print("PASS: fix-ui-export-menus pinned header and narrow tab bar")

  // The toolbar and status bar at the minimum window size with long texts.
  testWindow.setContentSize(NSSize(width: 700, height: 440))
  controller.show(String(repeating: "A long status message ", count: 8))
  controller.showError("Import failed: " + String(repeating: "a long error text ", count: 8))
  controller.view.layoutSubtreeIfNeeded()
  let bounds = controller.view.bounds
  let statusViews: [NSView] = [controller.status, controller.statusDetail, controller.errorButton]
  let statusFrames = statusViews.map(\.frame).sorted { $0.minX < $1.minX }
  require(zip(statusFrames, statusFrames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 }
    && statusFrames.allSatisfy { $0.minX >= 0 && $0.maxX <= bounds.maxX }
    && controller.errorButton.frame.width >= 60
    && controller.statusDetail.frame.width >= controller.statusDetail.intrinsicContentSize.width - 1,
    "at 700 × 440 the status, frame figures and error indicator do not overlap: \(statusFrames)")
  if let toolbar = controller.pauseButton?.superview as? NSStackView {
    let frames = toolbar.arrangedSubviews.map(\.frame)
    require(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 }
      && toolbar.frame.maxX <= bounds.maxX && toolbar.arrangedSubviews.allSatisfy { $0.frame.width >= $0.fittingSize.width - 1 },
      "at 700 × 440 the toolbar's controls fit unclipped")
  } else { require(false, "the toolbar is a stack view") }
  controller.dismissError()
  controller.messageUntil = .distantPast
  testWindow.setContentSize(savedSize)
  print("PASS: fix-ui-export-menus toolbar and status bar at the minimum window size")

  // File drops: routed by extension through the menu commands' paths.
  try reset()
  func dropFile(_ name: String, _ contents: Data = Data()) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try contents.write(to: url)
    return url
  }
  let text = try dropFile("notes.txt")
  require(!controller.openDroppedFiles([text]) && controller.status.stringValue.contains("notes.txt can't be opened"),
    "an unsupported file is refused with a message")
  require(!controller.openDroppedFiles([text, text]) && controller.status.stringValue == "Drop one file at a time.",
    "several files are refused")
  require(StudioController.dropKind(URL(fileURLWithPath: "/a.vtrace")) == .project
    && ["usd", "usda", "usdc", "usdz", "gltf", "glb", "obj", "xml", "USDZ"].allSatisfy {
      StudioController.dropKind(URL(fileURLWithPath: "/a.\($0)")) == .scene }
    && StudioController.dropKind(URL(fileURLWithPath: "/a.hdr")) == .environment
    && StudioController.dropKind(URL(fileURLWithPath: "/a.exr")) == .environment
    && StudioController.dropKind(URL(fileURLWithPath: "/a.mtlx")) == .materialX
    && StudioController.dropKind(URL(fileURLWithPath: "/a.png")) == nil, "drop kinds by extension")
  let environment = try dropFile("sky.exr", OpenEXRFloat.encode([SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: 4), width: 2, height: 2))
  controller.exportRenderer = testRenderer
  require(!controller.openDroppedFiles([environment]) && controller.status.stringValue.contains("Wait for the current operation"),
    "drops wait while busy")
  controller.exportRenderer = nil
  grouped {
    require(controller.openDroppedFiles([environment]), "an environment image is accepted")
    idle()
  }
  require(controller.project.environmentName == "sky.exr" && controller.history.undoActionName == "Environment image",
    "a dropped .exr loads as the environment image, undoably")
  let materialX = try dropFile("Drop.mtlx", Data("""
    <materialx version="1.39">
    <open_pbr_surface name="Dropped" type="surfaceshader"><input name="base_color" type="color3" value="0.2,0.4,0.6"/></open_pbr_surface>
    <surfacematerial name="DroppedMaterial" type="material"><input name="surfaceshader" type="surfaceshader" nodename="Dropped"/></surfacematerial>
    </materialx>
    """.utf8))
  grouped {
    require(controller.openDroppedFiles([materialX]), "a MaterialX file is accepted")
    idle()
  }
  require(controller.history.undoActionName == "Import MaterialX" && testRenderer.materials.materialX[controller.selectedSlot] != nil,
    "a dropped .mtlx imports through Import MaterialX")
  // A project drop asks first about unsaved changes; Cancel keeps the document.
  var project = ProjectDocument()
  project.options.exposure = 1.25
  let projectURL = try dropFile("Dropped.vtrace", project.encodeForSaving())
  var prompts = 0
  controller.unsavedChangesAnswer = { respond in prompts += 1; respond(.alertThirdButtonReturn) }
  controller.changed(reset: false)
  let cancelled = grouped { controller.openDroppedFiles([projectURL]) }
  require(cancelled && prompts == 1 && controller.projectURL == nil,
    "a project drop asks about unsaved changes; Cancel keeps the document")
  controller.unsavedChangesAnswer = { respond in prompts += 1; respond(.alertSecondButtonReturn) }
  // On the main menu: projects and scene files open; environment and MaterialX files need a document.
  controller.showStartScreen()
  require(enabled(#selector(StudioController.newProjectAction)) && enabled(#selector(StudioController.openAction))
    && enabled(#selector(StudioController.openSceneFileAction)) && !enabled(#selector(StudioController.saveAction))
    && !enabled(#selector(StudioController.showTabAction(_:)))
    && !enabled(#selector(StudioController.inspectorAction)) && !enabled(#selector(StudioController.loadEnvironmentAction))
    && enabled(#selector(StudioController.userGuideAction)), "on the main menu only the opening commands and Help apply")
  require(!controller.openDroppedFiles([environment]) && controller.status.stringValue.contains("Open a project or scene"),
    "an environment image needs a document")
  grouped {
    require(controller.openDroppedFiles([projectURL]), "a project drop on the main menu is accepted")
    idle()
  }
  require(controller.startScreen == nil && controller.projectURL == projectURL && testRenderer.options.exposure == 1.25,
    "a project dropped on the main menu opens")
  controller.showStartScreen()
  let objURL = try dropFile("Dropped.obj", Data(obj.utf8))
  grouped {
    require(controller.openDroppedFiles([objURL]), "a scene file drop is accepted")
    idle()
  }
  require(controller.startScreen == nil && testRenderer.sceneIndex == 6
    && (controller.project.graph != nil || !controller.project.triangles.isEmpty), "a scene file dropped on the main menu opens")
  print("PASS: fix-ui-export-menus file drops")

  // The launch menu bar (AppDelegate, before the studio exists) has the same shape; what needs the studio is disabled.
  let delegate = AppDelegate()
  let launch = StudioController.makeMenuBar(target: delegate, recent: controller.recent).bar
  require(launch.items.map(\.title) == bar.items.map(\.title)
    && zip(launch.items, bar.items).allSatisfy { titles($0.submenu!) == titles($1.submenu!) },
    "the launch menu bar has the studio's menus and items")
  for item in launch.items { item.submenu?.update() }
  func launchItem(_ menu: String, _ title: String) -> NSMenuItem? {
    launch.items.first { $0.title == menu }?.submenu?.items.first { $0.title == title }
  }
  require(["New Project", "Open Project…", "Open Scene File…", "Browse Scenes…"].allSatisfy { launchItem("File", $0)?.isEnabled == true }
    && launchItem("Help", "User Guide")?.isEnabled == true
    && ["Save", "Save As…", "Export…", "Add Model…"].allSatisfy { launchItem("File", $0)?.isEnabled == false }
    && launchItem("Help", "Credits and Licenses…")?.isEnabled == false && launchItem("Render", "Pause")?.isEnabled == false,
    "at launch the open commands and User Guide work; the rest waits for the studio")
  require(!delegate.openDroppedFiles([environment]), "at launch an environment image drop is refused")
  print("PASS: fix-ui-export-menus launch menu bar")

  try reset()
  show(page: 0)
}
try fixUIExportMenusChecks()
