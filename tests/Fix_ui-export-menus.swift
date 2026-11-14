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
    controller.limitsGPULoad = false
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
  require(titles(render) == ["Pause", "Restart", "", "Denoise Current Frame", "Clear Denoised Preview", "", "Limit GPU Load"]
    && key(render, "Pause") == "p" && key(render, "Restart") == "r"
    && render.items.last?.toolTip?.isEmpty == false, "Render menu: \(titles(render))")
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
    && enabled(#selector(StudioController.gpuLoadLimitAction))
    && controller.tabBar?.isEnabled == false, "while busy only Help, Finder, Limit GPU Load and the inspector toggle apply")
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
  let height = views(NumberControl.self, in: controller.stack).first { $0.field.accessibilityLabel() == "Height" }
  grouped { width!.set(1280) }
  grouped { height!.set(720) }
  require(popup("Preset")?.indexOfSelectedItem == 1, "the preset popup follows a typed size")
  controller.history.removeAllActions()
  grouped { pick("Preset", 1) }
  require(controller.history.undoActionName != "Output size", "choosing the current preset records no undo step")
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

  // The viewport shows the export while it renders (PathTracerRenderer.stillImage), then the preview again.
  testRenderer.options.outputWidth = 64; testRenderer.options.outputHeight = 16; testRenderer.options.exportSamples = 16384
  let wasPaused = testRenderer.paused, progressURL = folder.appendingPathComponent("progress.png")
  controller.startExport(url: progressURL, hdr: false)
  require(controller.exportRenderer != nil && testRenderer.stillImage == nil, "the preview stays until the export has an image")
  waitUntil({ testRenderer.stillImage != nil || controller.exportRenderer == nil }, seconds: 60)
  require(controller.exportRenderer != nil && testRenderer.stillImage === controller.exportOutput && testRenderer.paused,
    "the viewport shows the export in progress")
  controller.cancelExport()
  require(testRenderer.stillImage == nil && testRenderer.paused == wasPaused && testRenderer.presentationNeedsRefresh
    && !FileManager.default.fileExists(atPath: progressURL.path), "a cancelled export returns the viewport to the preview")
  // The fitted image is centred on the surround and averaged in linear light when it is shown smaller.
  func fitted(_ image: MTLTexture, width: Int, height: Int) -> [SIMD4<Float>] {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite]
    let target = gpu.makeTexture(descriptor: descriptor)!, command = testRenderer.commandQueue.makeCommandBuffer()!
    require(testRenderer.encodeFit(command, image: image, output: target), "the fit pass encodes")
    command.commit(); command.waitUntilCompleted()
    return readTexture(target)
  }
  // 64x16: black and white columns on the left half, red on the right.
  let stripes = gpu.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: 64, height: 16, mipmapped: false))!
  var bytes = [UInt8](repeating: 255, count: 64 * 16 * 4)
  for y in 0..<16 { for x in 0..<64 {
    let i = (y * 64 + x) * 4
    if x < 32 { for c in 0..<3 { bytes[i + c] = x % 2 == 0 ? 0 : 255 } } else { bytes[i] = 0; bytes[i + 1] = 0 }
  }}
  stripes.replace(region: MTLRegionMake2D(0, 0, 64, 16), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 256)
  func near(_ a: SIMD4<Float>, _ r: Float, _ g: Float, _ b: Float) -> Bool {
    simd_reduce_max(simd_abs(SIMD3(a.x, a.y, a.z) - SIMD3(r, g, b))) < 0.01
  }
  let small = fitted(stripes, width: 32, height: 32), large = fitted(stripes, width: 128, height: 64)
  require(near(small[11 * 32 + 8], 0.11, 0.11, 0.11) && near(small[20 * 32 + 24], 0.11, 0.11, 0.11)
    && near(small[12 * 32 + 24], 1, 0, 0) && near(small[19 * 32 + 24], 1, 0, 0),
    "a wide image is centred between surround bands")
  require(near(small[16 * 32 + 8], 0.7354, 0.7354, 0.7354), "halving averages black and white in linear light (sRGB 0.735)")
  require(near(large[15 * 128 + 100], 0.11, 0.11, 0.11) && near(large[16 * 128 + 100], 1, 0, 0)
    && near(large[47 * 128 + 100], 1, 0, 0) && near(large[48 * 128 + 100], 0.11, 0.11, 0.11),
    "a small image is enlarged to fit")
  print("PASS: fix-ui-export-menus export shown in the viewport while it renders")

  // Render › Limit GPU Load: checked and on by default, remembered by the app, applied to the preview and exports.
  let limit = #selector(StudioController.gpuLoadLimitAction), limited = PathTracerRenderer.limitedGPULoad
  controller.preferences.removeObject(forKey: StudioController.gpuLoadLimitKey)
  controller.applyGPULoadLimit()
  require(controller.limitsGPULoad && testRenderer.gpuLoadLimit == limited && valid(limit)?.state == .on,
    "the GPU load limit is on by default")
  controller.gpuLoadLimitAction()
  require(!controller.limitsGPULoad && testRenderer.gpuLoadLimit == 1 && valid(limit)?.state == .off
    && controller.preferences.object(forKey: StudioController.gpuLoadLimitKey) as? Bool == false,
    "the menu item switches the limit off and remembers it")
  controller.gpuLoadLimitAction()
  require(controller.limitsGPULoad && testRenderer.gpuLoadLimit == limited, "and on again")
  testRenderer.options.outputWidth = 64; testRenderer.options.outputHeight = 16; testRenderer.options.exportSamples = 64
  controller.startExport(url: progressURL, hdr: false)
  require(controller.exportRenderer?.gpuLoadLimit == limited, "an export renders under the limit")
  idle()
  require(FileManager.default.fileExists(atPath: progressURL.path), "a limited export completes")
  controller.limitsGPULoad = false

  // The limit itself (PathTracerRenderer.submissionDelay), on a renderer of its own.
  let paced = try PathTracerRenderer(device: gpu, sharing: testRenderer)
  paced.sceneIndex = 1; paced.samplingMode = 1; paced.denoiserEnabled = false
  let pacedDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 480, mipmapped: false)
  pacedDescriptor.usage = [.shaderRead, .shaderWrite]
  let pacedOutput = gpu.makeTexture(descriptor: pacedDescriptor)!
  var frames = 0, busy = 0.0
  paced.onFrameUpdate = { [unowned paced] _ in frames += 1; busy += paced.gpuMilliseconds }
  defer { paced.onFrameUpdate = nil }
  paced.renderFrame(output: pacedOutput)
  require(paced.submissionDelay() == 0, "without a limit a frame may always be submitted")
  waitUntil({ frames == 1 })
  let untimed = try PathTracerRenderer(device: gpu, sharing: testRenderer)
  untimed.sceneIndex = 1; untimed.samplingMode = 1; untimed.denoiserEnabled = false
  untimed.gpuLoadLimit = limited
  var untimedDone = false
  untimed.onFrameUpdate = { _ in untimedDone = true }
  require(untimed.submissionDelay() == 0, "a limited renderer starts at once")
  untimed.renderFrame(output: pacedOutput)
  require(untimed.submissionDelay() == .infinity, "until a frame has been timed, frames go one at a time")
  waitUntil({ untimedDone })
  require(untimed.submissionDelay().isFinite, "a timed frame ends the wait")
  untimed.onFrameUpdate = nil
  // A frame longer than the credit is followed by its idle share: 120 ms of samples wait at least (120 - 32) / 0.9 ms.
  paced.gpuLoadLimit = limited
  let sample = max(busy, 0.01)
  paced.renderFrame(output: pacedOutput, samples: Int((120 / sample).rounded(.up)))
  let wait = paced.submissionDelay()
  require(wait.isFinite && wait > 0.09, "a long frame is followed by its idle share: \(wait) s")
  waitUntil({ frames == 2 })
  waitUntil({ paced.submissionDelay() == 0 }, seconds: 5)
  // Over time the frames use at most the limit's share of the GPU (plus the credit and the frame in flight).
  frames = 0; busy = 0
  var submitted = 0
  let batch = max(1, Int(40 / max(paced.gpuMillisecondsPerSample, 0.01))), start = awakeSeconds()
  while awakeSeconds() - start < 2.5 {
    if paced.submissionDelay() == 0 {
      paced.renderFrame(output: pacedOutput, samples: batch)
      submitted += 1
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
  }
  let elapsed = (awakeSeconds() - start) * 1000
  waitUntil({ frames == submitted })
  require(frames >= 8 && busy <= limited * elapsed + PathTracerRenderer.gpuCreditLimit + 2.5 * busy / Double(frames)
    && busy >= 0.5 * elapsed, "limited frames leave the GPU its idle share: \(Int(busy)) ms of \(Int(elapsed)) ms in \(frames) frames")
  print(String(format: "PASS: fix-ui-export-menus GPU load limit (%.0f%% of the GPU's time in %d frames)", 100 * busy / elapsed, frames))

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
  // The import's completion shows its report in a modal alert (SceneGraphUI), so the check stops at the routing: a
  // newer document change supersedes the import before it completes.
  require(controller.openDroppedFiles([materialX]) && controller.projectOperationInProgress
    && controller.status.stringValue == "Importing Drop.mtlx…", "a dropped .mtlx starts Import MaterialX")
  controller.prepareGeneration &+= 1
  idle()
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
