// Launch state (AppDelegate, MainMenuView, RecentProjects, SceneBrowserView, ScenesWindowController): background
// shader compilation with on-demand kernel groups, the main menu and the Scenes window, recent projects, the kept and
// restorable last-session autosave, and the activity strip of project operations.
@MainActor func fixStartScreenChecks() throws {
  let folder = studioDirectory.absoluteURL.appendingPathComponent("fix-start-screen", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let savedAutosaveURL = controller.autosaveURL
  controller.autosaveURL = folder.appendingPathComponent("Autosave.vtrace")
  defer { controller.autosaveURL = savedAutosaveURL }
  func idle() { waitUntil({ !controller.isBusy }, seconds: 120) }

  // The launch path: core pipelines compile off the main thread with counted progress; the optional
  // groups compile in the background when a mode needs them, which falls back until then.
  let progress = OperationProgress("Preparing GPU shaders")
  let source = metalSource, mathMode = shaderCompileOptions().mathMode
  final class Outcome: @unchecked Sendable {
    let lock = NSLock()
    var result: Result<PathTracerRenderer.CompiledShaders, Error>?
    var onMain = true
    var done: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
  }
  let outcome = Outcome()
  DispatchQueue.global(qos: .userInitiated).async {
    let result = Result {
      try PathTracerRenderer.compileShaders(device: gpu, source: source, mathMode: mathMode, groups: [], progress: progress)
    }
    outcome.lock.lock(); outcome.result = result; outcome.onMain = Thread.isMainThread; outcome.lock.unlock()
  }
  waitUntil({ outcome.done }, seconds: 600)
  let compiled = outcome.result, compiledOnMain = outcome.onMain
  let launched = try PathTracerRenderer(device: gpu, shaders: compiled!.get())
  require(!compiledOnMain && progress.snapshot.fraction == 1 && progress.snapshot.detail == "10 of 10",
    "launch compiles the ten core pipelines off the main thread with counted progress")
  require(launched.sceneKernels.pt == nil && launched.meshKernels.splat == nil && launched.meshKernels.spmis == nil,
    "the optional kernel groups are not compiled at launch")
  launched.sceneIndex = 6
  launched.indirectReuse = .restirPT
  require(launched.activeIndirectReuse == .restirGI, "ReSTIR PT falls back to GI until its kernels are compiled")
  launched.requestKernels()
  require(launched.sceneShaders.compiling == [.pt] && launched.sceneShaders.progress != nil,
    "a mode that needs ReSTIR PT starts compiling only that group in the background")
  waitUntil({ launched.sceneShaders.compiling.isEmpty }, seconds: 600)
  require(launched.meshKernels.pt != nil && launched.proceduralKernels.pt != nil && launched.activeIndirectReuse == .restirPT
    && launched.sceneShaders.progress == nil && launched.meshKernels.splat == nil,
    "the compiled ReSTIR PT group is installed for both libraries")
  let export = try PathTracerRenderer(device: gpu, sharing: launched)
  require(export.sceneShaders === launched.sceneShaders && export.meshKernels.pt != nil,
    "renderers created with sharing: share the background-compiled groups")
  print("PASS: fix-start-screen background core compile, on-demand kernel groups and their fallbacks")

  // A last session on disk.
  try controller.restore(ProjectDocument())
  testRenderer.options.exposure = 1.75
  try controller.flushAutosave(to: controller.autosaveURL)
  let lastSession = try Data(contentsOf: controller.autosaveURL)
  try? FileManager.default.removeItem(at: controller.previousAutosaveURL)

  func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { views(type, in: $0) }
  }
  // The Scenes window holds the app's one scene browser.
  let scenes = controller.scenes, start = scenes.browser
  require(scenes.window?.contentView === start && scenes.window?.title == "Scenes"
    && scenes.window?.identifier?.rawValue == "scenes-window" && scenes.window?.styleMask.contains(.resizable) == true
    && scenes.window?.contentMinSize == NSSize(width: 700, height: 440) && scenes.window?.isReleasedWhenClosed == false,
    "the scene browser lives in the resizable Scenes window, which is kept when closed")
  scenes.hide()
  // Whether a control is shown: neither it nor a view between it and `root` is hidden.
  func visible(_ control: NSView?, in root: NSView) -> Bool {
    guard var view = control else { return false }
    while view !== root {
      if view.isHidden { return false }
      guard let parent = view.superview else { return false }
      view = parent
    }
    return true
  }
  func click(_ control: NSControl?) { (control as? NSButton)?.performClick(nil) }

  // No document loaded: the main menu covers the paused viewport and the inspector; nothing renders, only open and
  // import commands apply, quitting keeps the autosave. The Scenes window opens only on request.
  let recent = controller.recent
  recent.clear()
  controller.showStartScreen()
  controller.view.layoutSubtreeIfNeeded()
  guard let menu = controller.startScreen, menu.superview === controller.view, menu.identifier?.rawValue == "main-menu"
  else { return require(false, "the main menu is in the controller's view") }
  let menuTexts = views(NSTextField.self, in: menu).map(\.stringValue)
  require(controller.viewport.isPaused && controller.viewport.isHidden && menu.frame.width > 300
    && menuTexts.contains("Metal Vibe Tracer") && menuTexts.contains("Start") && menuTexts.contains("Recent projects")
    && !menuTexts.contains { $0.hasPrefix("Version") },
    "with no document the main menu covers the paused, hidden viewport; without a bundle version it shows none")
  require(!scenes.isVisible && !controller.isBrowsingScenes, "the Scenes window is not shown with the main menu")
  let startButtons = [("menu-new", "New Project"), ("menu-open-project", "Open Project…"),
                      ("menu-open-scene", "Open Scene File…"), ("menu-browse", "Browse Scenes…"),
                      ("menu-restore", "Restore Last Session")]
  require(startButtons.allSatisfy { (menu.control($0.0) as? NSButton)?.title == $0.1 && menu.control($0.0)?.isEnabled == true }
    && (menu.control("menu-guide") as? NSButton)?.title == "User Guide"
    && (menu.control("menu-credits") as? NSButton)?.title == "Credits and licenses…"
    && menu.control("menu-credits")?.isEnabled == true && menu.control("menu-settings") == nil,
    "the main menu's Start buttons, User Guide and Credits and licenses… with their labels; no Settings")
  require(visible(menu.control("menu-restore"), in: menu)
    && views(NSTextField.self, in: menu).contains { $0.stringValue.hasPrefix("Autosaved ") && visible($0, in: menu) },
    "with an autosave the main menu offers Restore Last Session with its date")
  require(visible(menu.control("menu-recent-empty"), in: menu) && !visible(menu.control("menu-recent-clear"), in: menu)
    && (menu.control("menu-recent-empty") as? NSTextField)?.stringValue == "No recent projects",
    "an empty recent list shows No recent projects and no Clear")
  var openedURLs: [URL] = []
  menu.openURL = { openedURLs.append($0) }
  click(menu.control("menu-guide"))
  require(openedURLs == [MainMenuView.userGuideURL]
    && MainMenuView.userGuideURL.absoluteString == "https://github.com/gabinfor/metal-vibe-tracer/blob/main/docs/USER_GUIDE.md",
    "User Guide opens the guide on GitHub")
  click(menu.control("menu-browse"))
  require(scenes.isVisible && controller.isBrowsingScenes, "Browse Scenes… on the main menu shows the Scenes window")
  start.cancelOperation(nil)
  require(!scenes.isVisible && controller.startScreen === menu && controller.viewport.isHidden,
    "Esc hides the Scenes window with no document loaded, and the main menu stays")
  click(menu.control("menu-browse"))
  require(scenes.isVisible, "Browse Scenes… shows the Scenes window again after it was hidden")
  if let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
    controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: studioDirectory.appendingPathComponent("main-menu.png"))
  }
  start.filter = .all; start.search = ""
  require(start.control("start-open") == nil && start.control("start-open-scene") == nil && start.control("start-restore") == nil
    && start.control("start-progress") == nil && start.control("start-cancel-pending") == nil
    && (start.control("scene-filter-0") as? NSButton)?.state == .on && (start.control("scene-filter-1") as? NSButton)?.state == .off
    && start.control("scene-credits")?.isHidden == false && start.control("scene-close") == nil
    && start.visibleEntries.count == SceneCatalog.entries.count
    && SceneBrowserView.describe(.scene("lantern-arcade")) == "Opening Lantern Arcade"
    && SceneBrowserView.describe(.newProject) == "Creating a new project",
    "the Scenes window holds scenes only: every catalog scene, no file actions, no launch rows and no Close button")

  // The main menu in its launch state, before the studio exists (AppDelegate): its buttons send start actions, and it
  // shows the shader progress, a queued action with Cancel and its own messages.
  let launch = MainMenuView(version: "1.2.3")
  var sent: [String] = []
  launch.onAction = { action in
    switch action {
    case .newProject: sent.append("new")
    case .openProject(nil): sent.append("project")
    case .openScene(nil): sent.append("scene")
    case .restoreSession: sent.append("restore")
    default: sent.append("other")
    }
  }
  var browsed = 0, launchCancels = 0
  launch.onBrowse = { browsed += 1 }
  launch.onCancelPending = { launchCancels += 1 }
  launch.frame = NSRect(x: 0, y: 0, width: 900, height: 640); launch.layoutSubtreeIfNeeded()
  require(views(NSTextField.self, in: launch).contains { $0.stringValue == "Version 1.2.3" },
    "the header shows the bundle version")
  require(!visible(launch.control("menu-restore"), in: launch), "without an autosave Restore Last Session is hidden")
  launch.setRestore(Date())
  require(visible(launch.control("menu-restore"), in: launch), "an autosave date shows Restore Last Session")
  for id in ["menu-new", "menu-open-project", "menu-open-scene", "menu-restore", "menu-browse"] { click(launch.control(id)) }
  require(sent == ["new", "project", "scene", "restore"] && browsed == 1,
    "the Start buttons send New Project, Open Project…, Open Scene File… and Restore Last Session; Browse Scenes… browses")
  require(launch.control("menu-credits")?.isEnabled == false && launch.control("menu-guide")?.isEnabled == true,
    "Credits and licenses… is disabled until the studio sets its action; User Guide is not")
  var launchCredits = 0
  launch.onCredits = { launchCredits += 1 }
  click(launch.control("menu-credits"))
  require(launchCredits == 1, "Credits and licenses… calls onCredits once set")
  require(!visible(launch.control("start-progress"), in: launch) && !visible(launch.control("start-cancel-pending"), in: launch),
    "no launch rows without progress or a queued action")
  launch.setProgress(OperationProgress("Preparing GPU shaders").snapshot)
  launch.setPending("Opening a.vtrace once the shaders are ready.")
  require(visible(launch.control("start-progress"), in: launch) && visible(launch.control("start-cancel-pending"), in: launch),
    "the main menu shows the shader progress and the queued action with Cancel")
  click(launch.control("start-cancel-pending"))
  require(launchCancels == 1, "Cancel calls onCancelPending")
  launch.setProgress(nil); launch.setPending(nil)
  require(!visible(launch.control("start-progress"), in: launch) && !visible(launch.control("start-cancel-pending"), in: launch),
    "nil hides the launch rows")
  launch.setMessage("Old.vtrace is no longer at ~/Gone.")
  require(visible(launch.control("menu-message"), in: launch)
    && (launch.control("menu-message") as? NSTextField)?.stringValue == "Old.vtrace is no longer at ~/Gone.",
    "the main menu's message row")
  let manyRecent = (0..<10).map { folder.appendingPathComponent("many/Project \($0).vtrace") }
  launch.setRecent(manyRecent)
  var openedRecent: [URL] = []
  launch.onOpenRecent = { openedRecent.append($0) }
  click(launch.control("menu-recent-2"))
  require(launch.control("menu-recent-7") != nil && launch.control("menu-recent-8") == nil && openedRecent == [manyRecent[2]]
    && !visible(launch.control("menu-recent-empty"), in: launch) && visible(launch.control("menu-recent-clear"), in: launch),
    "at most eight recent rows, each opening its project")
  launch.setActionsEnabled(false)
  require(["menu-new", "menu-open-project", "menu-open-scene", "menu-browse", "menu-restore", "menu-recent-0",
           "menu-recent-clear", "menu-credits"].allSatisfy { launch.control($0)?.isEnabled == false }
    && launch.control("menu-guide")?.isEnabled == true && launch.control("start-cancel-pending")?.isEnabled == true,
    "setActionsEnabled(false) disables the Start buttons, recent rows, Clear and Credits; User Guide and Cancel stay")
  launch.setActionsEnabled(true)
  // At the minimum window size the menu scrolls to its last control.
  launch.frame = NSRect(x: 0, y: 0, width: 700, height: 440); launch.layoutSubtreeIfNeeded()
  guard let lastControl = launch.control("menu-credits"), let menuScroll = lastControl.enclosingScrollView,
    let menuDocument = menuScroll.documentView
  else { return require(false, "the main menu sits in a scroll view") }
  require(menuDocument.bounds.contains(lastControl.convert(lastControl.bounds, to: menuDocument))
    && launch.bounds.contains(menuScroll.convert(menuScroll.bounds, to: launch)) && menuDocument.frame.height > 440,
    "at 700 x 440 the main menu's document holds its last control and is taller than the window")
  lastControl.scrollToVisible(lastControl.bounds)
  require(lastControl.convert(lastControl.bounds, to: menuDocument).intersects(menuScroll.contentView.documentVisibleRect),
    "at 700 x 440 the main menu's last control scrolls into view")
  if let rep = launch.bitmapImageRepForCachingDisplay(in: launch.bounds) {
    launch.cacheDisplay(in: launch.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: studioDirectory.appendingPathComponent("main-menu-700x440.png"))
  }

  // The browser: filters, search, the details pane's primary button, the busy state and the minimum window size.
  let browser = SceneBrowserView(library: ExampleLibrary(root: folder.appendingPathComponent("library")))
  require(browser.visibleEntries.count == 31 && browser.selection?.id == "pavilion", "all scenes, first selected")
  browser.filter = .downloads
  require(browser.visibleEntries.count == 20 && browser.visibleEntries.allSatisfy(\.isDownload), "downloads filter")
  browser.filter = .installed
  require(browser.visibleEntries.isEmpty && browser.selection == nil && browser.control("scene-empty")?.isHidden == false,
    "nothing installed")
  browser.filter = .builtIn
  require(browser.visibleEntries.map(\.id) == SceneCatalog.entries.filter { $0.collection == .builtIn }.map(\.id)
    && browser.control("scene-empty")?.isHidden == true, "built-in filter")
  browser.filter = .included
  require(browser.visibleEntries.count == 11 && !browser.visibleEntries.contains(where: \.isDownload), "included filter")
  browser.filter = .all; browser.search = "bistro"
  require(browser.visibleEntries.map(\.id) == ["bistro-exterior", "bistro-interior"], "search by title")
  browser.search = "spectral"
  require(browser.visibleEntries.count == 5, "search by tag")
  browser.search = "STANFORD"
  require(browser.visibleEntries.map(\.id) == ["buddha", "chinese-dragon"], "search by credit, ignoring case")
  browser.search = "no such scene"
  func shown(_ id: String) -> Bool {
    guard let control = browser.control(id) else { return false }
    var view: NSView? = control
    while let current = view, current !== browser { if current.isHidden { return false }; view = current.superview }
    return true
  }
  require(browser.visibleEntries.isEmpty && browser.selection == nil && browser.control("scene-empty")?.isHidden == false
    && (browser.control("scene-empty") as? NSTextField)?.stringValue == "No scenes match"
    && !shown("scene-open") && !shown("scene-download"), "an empty search")
  browser.search = ""; browser.selection = SceneCatalog.entry("sponza")
  require(browser.control("scene-download")?.isHidden == false && browser.control("scene-open")?.isHidden == true
    && (browser.control("scene-download") as? NSButton)?.title == "Download 80 MB", "a missing download offers Download")
  require(SceneBrowserView.specLine(SceneCatalog.entry("sponza")!) == "262 k triangles · OBJ"
    && SceneBrowserView.specLine(SceneCatalog.entry("cornell-box")!) == "Built-in"
    && browser.stateText(SceneCatalog.entry("sponza")!) == "Download 80 MB"
    && browser.stateText(SceneCatalog.entry("abbe-row")!) == "Included"
    && SceneBrowserView.thumbnail(SceneCatalog.entry("sponza")!) != nil
    && SceneBrowserView.thumbnail(SceneCatalog.entry("buddha")!) == nil, "card spec lines, states and thumbnails")
  require(SceneBrowserView(library: ExampleLibrary(root: folder.appendingPathComponent("library"))).control("scene-download")?.isEnabled == false,
    "Download is disabled until the studio owns the browser")
  var downloaded: [String] = [], actions: [String] = []
  browser.onDownload = { downloaded.append($0.id) }
  browser.onAction = { if case .scene(let id) = $0 { actions.append(id) } }
  // The details pane states what Download does; selecting cards and filtering never start it.
  let named = SceneBrowserView(library: ExampleLibrary(root: folder.appendingPathComponent("Example Scenes")))
  named.selection = SceneCatalog.entry("sponza")
  let consent = named.control("scene-download-consent") as? NSTextField
  let destination = (folder.appendingPathComponent("Example Scenes/sponza").path as NSString).abbreviatingWithTildeInPath
  require(consent?.isHidden == false && consent?.stringValue.hasPrefix("Downloads 80 MB from casual-effects.com and uses ") == true
    && consent?.stringValue.hasSuffix(" in \(destination).") == true && destination.hasSuffix("Example Scenes/sponza"),
    "the consent text above Download: \(consent?.stringValue ?? "")")
  browser.selection = SceneCatalog.entry("san-miguel")
  browser.filter = .downloads; browser.filter = .installed; browser.filter = .all
  browser.selection = SceneCatalog.entry("sponza")
  require(downloaded.isEmpty, "selecting cards and changing filters never download")
  (browser.control("scene-download") as? NSButton)?.performClick(nil)
  browser.selection = SceneCatalog.entry("cornell-box")
  require(browser.control("scene-open")?.isHidden == false && browser.control("scene-download")?.isHidden == true,
    "included scenes open")
  (browser.control("scene-open") as? NSButton)?.performClick(nil)
  require(downloaded == ["sponza"] && actions == ["cornell-box"], "Download asks onDownload and Open sends .scene(id)")
  require(browser.control("scene-close") == nil && browser.control("scene-download-cancel")?.isHidden == true
    && browser.control("scene-credits")?.isHidden == true,
    "the browser has no Close button, no credits link without onCredits, and no download progress until one is set")
  var credits = 0
  browser.onCredits = { credits += 1 }
  (browser.control("scene-credits") as? NSButton)?.performClick(nil)
  require(credits == 1 && browser.control("scene-credits")?.isHidden == false, "Credits and licenses… calls onCredits")
  // A running download replaces Download and the consent text with its progress while its card is selected, which
  // other cards do not show; reselecting the card shows the same progress again.
  let sponzaEntry = SceneCatalog.entry("sponza")!
  var cancels = 0
  browser.onCancelDownload = { cancels += 1 }
  browser.selection = sponzaEntry
  browser.setDownload(sponzaEntry, fraction: 0.5, status: "x")
  let bar = browser.control("scene-download-cancel")
  require(bar?.isHidden == false && browser.control("scene-download")?.isHidden == true
    && browser.control("scene-download-consent")?.isHidden == true, "a download shows its Cancel button instead of Download")
  (bar as? NSButton)?.performClick(nil)
  require(cancels == 1, "Cancel calls onCancelDownload")
  browser.selection = SceneCatalog.entry("san-miguel")
  require(browser.control("scene-download-cancel")?.isHidden == true && browser.control("scene-download")?.isHidden == false,
    "another card shows no progress")
  browser.selection = sponzaEntry
  require(browser.control("scene-download-cancel")?.isHidden == false && browser.control("scene-download")?.isHidden == true,
    "the progress shows again when the card is reselected")
  func progressBars(_ view: NSView) -> [NSProgressIndicator] {
    view.subviews.flatMap { ($0 as? NSProgressIndicator).map { [$0] } ?? [] } + view.subviews.flatMap(progressBars)
  }
  require(progressBars(browser).contains { !$0.isHidden && !$0.isIndeterminate && $0.doubleValue == 0.5 },
    "the details pane's bar shows the fraction done")
  browser.setDownload(nil, fraction: nil, status: nil)
  require(browser.control("scene-download-cancel")?.isHidden == true && browser.control("scene-download")?.isHidden == false,
    "no download restores the Download button")
  browser.showDownloadError(sponzaEntry, "Could not download Crytek Sponza: disk full")
  let error = browser.control("scene-download-error") as? NSTextField
  require(error?.isHidden == false && error?.stringValue.contains("disk full") == true
    && browser.control("scene-download")?.isHidden == false, "a failure shows its text above the Download button")
  browser.selection = SceneCatalog.entry("san-miguel")
  require(error?.isHidden == true, "the failure belongs to its scene")
  browser.selection = sponzaEntry
  browser.setDownload(sponzaEntry, fraction: nil, status: "Connecting")
  browser.setDownload(nil, fraction: nil, status: nil)
  require(error?.isHidden == true, "a new attempt clears the failure")
  browser.setActionsEnabled(false)
  require(browser.control("scene-open")?.isEnabled == false && browser.control("scene-download")?.isEnabled == false,
    "busy disables actions")
  browser.setActionsEnabled(true)
  browser.frame = NSRect(x: 0, y: 0, width: 700, height: 440); browser.layoutSubtreeIfNeeded()
  func scrollViews(_ view: NSView) -> [NSScrollView] {
    view.subviews.flatMap { ($0 as? NSScrollView).map { [$0] } ?? [] } + view.subviews.flatMap(scrollViews)
  }
  let gridScroll = scrollViews(browser).first { $0.documentView is NSCollectionView }
  guard let open = browser.control("scene-open"), let detailsScroll = open.enclosingScrollView,
    let detailsDocument = detailsScroll.documentView
  else { return require(false, "the primary button sits in the details pane's scroll view") }
  let openFrame = open.convert(open.bounds, to: detailsDocument)
  require(browser.bounds.contains(detailsScroll.convert(detailsScroll.bounds, to: browser))
    && detailsDocument.bounds.contains(openFrame) && (gridScroll?.frame.width ?? 0) >= 180,
    "at the minimum window size the details pane fits the browser, holds the primary button, and cards keep 180 pt")
  open.scrollToVisible(open.bounds)
  require(open.convert(open.bounds, to: detailsDocument).intersects(detailsScroll.contentView.documentVisibleRect),
    "at the minimum window size the primary button scrolls into view")
  if let rep = browser.bitmapImageRepForCachingDisplay(in: browser.bounds) {
    browser.cacheDisplay(in: browser.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: studioDirectory.appendingPathComponent("scene-browser-700x440.png"))
  }
  func valid(_ selector: Selector) -> Bool {
    controller.validateMenuItem(NSMenuItem(title: "", action: selector, keyEquivalent: ""))
  }
  require(scenes.isVisible && valid(#selector(StudioController.browseScenesAction)),
    "Browse Scenes is available with no document loaded while the Scenes window shows (it brings it forward)")
  scenes.hide()
  require(valid(#selector(StudioController.browseScenesAction)), "Browse Scenes is available with no document loaded")
  require(valid(#selector(StudioController.openAction)) && valid(#selector(StudioController.openSceneFileAction))
    && !valid(#selector(StudioController.saveAction)) && !valid(#selector(StudioController.exportAction))
    && valid(#selector(StudioController.openRecentAction(_:))) && valid(#selector(StudioController.clearRecentAction))
    && !valid(#selector(StudioController.undoAction)), "with no document only open, Open Recent, import and browse commands apply")
  testRenderer.options.exposure = 3
  controller.changed(reset: false)
  controller.saveTimer?.invalidate()
  try controller.flushAutosave()
  require((try? Data(contentsOf: controller.autosaveURL)) == lastSession,
    "quitting with no document loaded keeps the last session's autosave")

  // Restore Last Session loads the autosave, keeps the file and hides the Scenes window.
  controller.browseScenes()
  click(menu.control("menu-restore"))
  require(controller.projectOperationInProgress && !controller.activityStrip.isHidden
    && menu.control("menu-new")?.isEnabled == false,
    "restoring runs off the main thread with the activity strip shown and the main menu's buttons disabled")
  idle()
  require(controller.startScreen == nil && menu.superview == nil && testRenderer.options.exposure == 1.75
    && !controller.viewport.isPaused && !controller.viewport.isHidden && controller.activityStrip.isHidden && !scenes.isVisible,
    "restoring the last session removes the main menu and hides the Scenes window")
  controller.autosaveQueue.sync {}
  require(FileManager.default.fileExists(atPath: controller.autosaveURL.path)
    && !FileManager.default.fileExists(atPath: controller.previousAutosaveURL.path),
    "a restored session keeps its autosave in place")

  // Another start action keeps the last session as the recovery copy before autosaving anew.
  controller.showStartScreen()
  controller.associate(nil, edited: false, replaced: false)  // No document loaded: nothing to discard.
  controller.browseScenes()
  controller.performStartAction(.scene("cornell-box"))
  idle()
  controller.autosaveQueue.sync {}
  require(controller.startScreen == nil && testRenderer.sceneIndex == 1 && controller.projectURL == nil
    && !controller.documentEdited && !scenes.isVisible, "a built-in scene opens as a new untitled project and hides the Scenes window")
  require(!testRenderer.denoiserEnabled, "MetalFX is off in a new project")
  // The inspector's scene control names the current scene and opens the browser; the scene lists are gone.
  controller.page = 0
  controller.rebuild()
  func browseButton() -> NSButton? { views(NSButton.self, in: controller.inspectorHeader).first { $0.identifier?.rawValue == "scene-browse" } }
  require(browseButton()?.title == "Browse…"
    && !views(ActionPopup.self, in: controller.stack).contains { $0.accessibilityLabel() == "Scene" }
    && views(NSTextField.self, in: controller.inspectorHeader).map(\.stringValue).contains("Cornell Box"),
    "the inspector shows the current scene's title and a Browse… button instead of a Scene selector")
  let fileMenu = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
  let helpMenu = NSApp.mainMenu?.items.first { $0.title == "Help" }?.submenu
  let browseItem = fileMenu?.items.first { $0.title == "Browse Scenes…" }
  require(browseItem?.keyEquivalent == "O" && browseItem?.keyEquivalentModifierMask.contains(.command) == true
    && fileMenu?.items.contains { $0.title == "Open Example Scene" } == false
    && helpMenu?.items.contains { $0.action == #selector(StudioController.exampleCreditsAction) } == true,
    "File > Browse Scenes… (shift-command-O) replaces Open Example Scene; Credits and Licenses… is in Help")
  if let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
    controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: studioDirectory.appendingPathComponent("inspector-scene.png"))
  }
  require((try? Data(contentsOf: controller.previousAutosaveURL)) == lastSession,
    "starting another document keeps the last session as Autosave-previous.vtrace")

  // The Scenes window over a loaded document: the document stays loaded, the render keeps running and the autosave is
  // untouched while it is shown and hidden.
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  try controller.flushAutosave()
  controller.autosaveQueue.sync {}
  let autosaved = StudioController.autosaveDate(at: controller.autosaveURL)
  let before = try encoder.encode(controller.project)
  func sameDocument() -> Bool { (try? encoder.encode(controller.project)) == before }
  let browseValid = NSMenuItem(title: "", action: #selector(StudioController.browseScenesAction), keyEquivalent: "")
  let saveValid = NSMenuItem(title: "", action: #selector(StudioController.saveAction), keyEquivalent: "")
  require(!scenes.isVisible && controller.validateMenuItem(browseValid), "Browse Scenes is available over a document")
  controller.browseScenes()
  require(controller.validateMenuItem(browseValid) && controller.validateMenuItem(saveValid),
    "Browse Scenes stays available while the Scenes window shows (it brings it forward), and the document's commands too")
  require(controller.isBrowsingScenes && scenes.isVisible && controller.startScreen == nil && !controller.viewport.isPaused
    && !controller.viewport.isHidden && sameDocument(),
    "browseScenes shows the Scenes window and the viewport is neither paused nor hidden")
  require(start.control("scene-credits")?.isHidden == false, "over a document the Scenes window has Credits")
  // A card is found by its identifier scene-card-<id> once scrolled into view, and selecting it fills the details pane.
  start.layoutSubtreeIfNeeded()
  guard let cards = views(NSCollectionView.self, in: start).first,
    let index = start.visibleEntries.firstIndex(where: { $0.id == "abbe-row" })
  else { return require(false, "the browser's grid lists abbe-row") }
  cards.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .top)
  start.layoutSubtreeIfNeeded()
  guard let card = views(NSView.self, in: start).first(where: { $0.identifier?.rawValue == "scene-card-abbe-row" })
  else { return require(false, "the browser shows a card with the identifier scene-card-abbe-row") }
  require(card.accessibilityLabel()?.hasSuffix(", Included") == true, "the card is labelled with its title and state")
  cards.selectionIndexPaths = [IndexPath(item: index, section: 0)]
  cards.delegate?.collectionView?(cards, didSelectItemsAt: cards.selectionIndexPaths)
  require(start.selection?.id == "abbe-row" && start.control("scene-open")?.isHidden == false,
    "selecting the card selects its scene and shows Open")
  controller.browseScenes()
  require(scenes.isVisible && scenes.browser === start && start.selection?.id == "abbe-row",
    "browsing again brings the same window forward")
  controller.saveTimer?.invalidate()
  controller.autosaveQueue.sync {}
  require(StudioController.autosaveDate(at: controller.autosaveURL) == autosaved,
    "showing the Scenes window does not rewrite the autosave")
  start.cancelOperation(nil)
  controller.browseScenes()
  scenes.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: scenes.window))
  require(!controller.isBrowsingScenes && !scenes.isVisible && !controller.viewport.isPaused
    && !controller.viewport.isHidden && sameDocument(),
    "Esc and the close button hide the Scenes window over a document, and the viewport and the document are untouched")
  controller.browseScenes()
  scenes.hide()
  controller.saveTimer?.invalidate()
  controller.autosaveQueue.sync {}
  require(!controller.isBrowsingScenes && !controller.viewport.isPaused && sameDocument()
    && StudioController.autosaveDate(at: controller.autosaveURL) == autosaved,
    "hiding the Scenes window changes nothing, and the autosave is unchanged across show and hide")
  // Opening a scene from the Scenes window asks before discarding unsaved changes: Cancel keeps the window, Don't Save
  // opens the scene and hides it. The last session stays the recovery copy.
  controller.associate(nil, edited: true, replaced: false)
  var browsePrompts = 0
  var browseAnswer = NSApplication.ModalResponse.alertThirdButtonReturn
  controller.unsavedChangesAnswer = { respond in browsePrompts += 1; respond(browseAnswer) }
  let editedBefore = try encoder.encode(controller.project)
  controller.browseScenes()
  controller.performStartAction(.scene("cornell-box"))
  require(browsePrompts == 1 && scenes.isVisible && controller.documentEdited
    && (try? encoder.encode(controller.project)) == editedBefore,
    "cancelling the unsaved-changes prompt keeps the Scenes window open and the document unchanged")
  browseAnswer = .alertSecondButtonReturn
  controller.performStartAction(.scene("cornell-box"))
  idle()
  controller.autosaveQueue.sync {}
  require(browsePrompts == 2 && !scenes.isVisible && !controller.viewport.isPaused && !controller.documentEdited
    && (try? Data(contentsOf: controller.previousAutosaveURL)) == lastSession,
    "opening a scene from the Scenes window discards the changes, hides the window once the document is applied and keeps the recovery copy")
  // Opening a project file or a bundled scene from the Scenes window over an edited document asks first too; Cancel
  // keeps both.
  let editedProject = try encoder.encode(controller.project)
  controller.associate(nil, edited: true, replaced: false)
  browseAnswer = .alertThirdButtonReturn
  controller.browseScenes()
  controller.performStartAction(.openProject(folder.appendingPathComponent("never-opened.vtrace")))
  require(browsePrompts == 3 && scenes.isVisible && controller.documentEdited
    && (try? encoder.encode(controller.project)) == editedProject && controller.projectURL == nil,
    "opening a project from the Scenes window asks first, and Cancel keeps it open and the document unchanged")
  controller.performStartAction(.scene("abbe-row"))
  idle()
  require(browsePrompts == 4 && scenes.isVisible && controller.documentEdited
    && (try? encoder.encode(controller.project)) == editedProject,
    "opening a bundled scene from the Scenes window asks first, and Cancel keeps it open and the document unchanged")
  scenes.hide()
  controller.associate(nil, edited: false, replaced: false)
  controller.unsavedChangesAnswer = nil

  // Open Scene File: an OBJ opens as a new untitled scene; with unsaved changes the prompt comes first.
  require(["glb", "gltf", "usdz", "usd", "xml", "obj"].allSatisfy(SceneFile.extensions.contains)
    && (MainMenuView().control("menu-open-scene") as? NSButton)?.title == "Open Scene File…"
    && SceneBrowserView.describe(.openScene(URL(fileURLWithPath: "/tmp/Chair.glb"))) == "Opening Chair.glb",
    "the main menu and SceneFile offer one Open Scene File entry for USD, glTF, Mitsuba and OBJ")
  let sceneObj = folder.appendingPathComponent("quad.obj")
  try "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n".write(to: sceneObj, atomically: true, encoding: .utf8)
  let history = controller.history, groupsByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer { history.groupsByEvent = groupsByEvent }
  func grouped(_ body: () -> Void) { history.beginUndoGrouping(); body(); history.endUndoGrouping() }
  controller.browseScenes()
  grouped {
    controller.performStartAction(.openScene(sceneObj))
    idle()
  }
  require(controller.startScreen == nil && controller.projectURL == nil && !scenes.isVisible
    && controller.project.graph?.assets.map(\.geometry.count) == [2],
    "Open Scene File opens an OBJ as a new untitled scene and hides the Scenes window")
  // Undo, redo and Add Model change the document but open none: the Scenes window stays shown.
  controller.browseScenes()
  history.undo()
  idle()
  require(scenes.isVisible && controller.project.graph?.assets.count != 1, "undoing an open leaves the Scenes window shown")
  history.redo()
  idle()
  require(scenes.isVisible && controller.project.graph?.assets.map(\.geometry.count) == [2],
    "redoing an open leaves the Scenes window shown")
  let exposureBefore = testRenderer.options.exposure
  grouped { controller.checkpoint("Exposure"); testRenderer.options.exposure = exposureBefore + 0.5 }
  history.undo()
  idle()
  require(scenes.isVisible && testRenderer.options.exposure == exposureBefore, "undoing an edit leaves the Scenes window shown")
  history.redo()
  idle()
  require(scenes.isVisible && testRenderer.options.exposure == exposureBefore + 0.5, "redoing an edit leaves the Scenes window shown")
  let nodesBefore = controller.project.graph?.nodes.count ?? 0
  grouped {
    controller.beginImportOBJ(from: sceneObj)
    idle()
  }
  require(scenes.isVisible && (controller.project.graph?.nodes.count ?? 0) > nodesBefore, "Add Model leaves the Scenes window shown")
  scenes.hide()
  // Unsaved changes to an empty document, so that only a replacement brings the OBJ's graph back.
  try controller.restore(ProjectDocument())
  controller.associate(nil, edited: true, replaced: false)
  var prompts = 0
  var answer = NSApplication.ModalResponse.alertThirdButtonReturn
  controller.unsavedChangesAnswer = { respond in prompts += 1; respond(answer) }
  defer { controller.unsavedChangesAnswer = nil }
  grouped {
    controller.beginOpenSceneFile(sceneObj)
    idle()
  }
  require(prompts == 1 && controller.documentEdited && controller.project.graph == nil
    && !controller.projectOperationInProgress, "Open Scene File asks before replacing unsaved changes and Cancel keeps them")
  answer = .alertSecondButtonReturn
  grouped {
    controller.beginOpenSceneFile(sceneObj)
    idle()
  }
  require(prompts == 2 && controller.projectURL == nil
    && controller.project.graph?.assets.map(\.geometry.count) == [2], "Don't Save lets Open Scene File replace the document")
  try controller.flushAutosave()
  require(recent.urls.isEmpty,
    "restoring the session, catalog scenes, scene files and the autosave add nothing to the recent projects")
  controller.unsavedChangesAnswer = nil
  controller.associate(nil, edited: false, replaced: false)
  // Saving reports its phase in the activity strip until it finishes.
  var saved = false
  controller.beginSaveProject(folder.appendingPathComponent("strip.vtrace")) { saved = $0 }
  require(!controller.activityStrip.isHidden && controller.activityLabel.stringValue.contains("strip.vtrace"),
    "a save shows its phase in the activity strip")
  idle()
  require(saved && controller.activityStrip.isHidden && controller.activity == nil, "the activity strip clears when the save ends")
  // Opening a project and New hide the Scenes window too.
  controller.browseScenes()
  grouped {
    controller.beginOpenProject(folder.appendingPathComponent("strip.vtrace"))
    idle()
  }
  require(controller.projectURL?.lastPathComponent == "strip.vtrace" && !scenes.isVisible,
    "opening a project hides the Scenes window")
  controller.browseScenes()
  grouped {
    controller.newProject()
    idle()
  }
  require(controller.projectURL == nil && !scenes.isVisible, "New hides the Scenes window")

  // Recent projects (the test controller's in-memory list): saving, saving as and opening a project file put it first.
  let strip = folder.appendingPathComponent("strip.vtrace"), other = folder.appendingPathComponent("recent-other.vtrace")
  require(recent.urls == [strip], "saving and then opening a project file lists it once")
  var savedAs = false
  controller.beginSaveProject(other) { savedAs = $0 }  // Save As writes the chosen file through beginSaveProject.
  idle()
  require(savedAs && recent.urls == [other, strip], "saving as adds the new file first")
  grouped {
    controller.beginOpenProject(strip)
    idle()
  }
  require(recent.urls == [strip, other], "opening a project file moves it first")
  let gone = folder.appendingPathComponent("gone/Gone.vtrace")
  recent.note(gone)
  controller.showStartScreen()
  controller.view.layoutSubtreeIfNeeded()
  guard let recentMenu = controller.startScreen else { return require(false, "the main menu shows again") }
  let folderText = (folder.path as NSString).abbreviatingWithTildeInPath
  let rowTitles = (0..<3).map { (recentMenu.control("menu-recent-\($0)") as? NSButton)?.title ?? "" }
  require(rowTitles[0].hasPrefix("Gone.vtrace") && rowTitles[1].hasPrefix("strip.vtrace") && rowTitles[1].contains(folderText)
    && rowTitles[2].hasPrefix("recent-other.vtrace") && folderText.hasPrefix("~") && recentMenu.control("menu-recent-3") == nil
    && !visible(recentMenu.control("menu-recent-empty"), in: recentMenu)
    && visible(recentMenu.control("menu-recent-clear"), in: recentMenu),
    "the main menu lists the recent projects newest first with their ~-abbreviated folders: \(rowTitles)")
  let openRecentMenu = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items
    .first { $0.title == "Open Recent" }?.submenu
  require(openRecentMenu?.items.map(\.title) == ["Gone.vtrace", "strip.vtrace", "recent-other.vtrace", "", "Clear Menu"]
    && openRecentMenu?.items[3].isSeparatorItem == true,
    "File › Open Recent lists the same projects, then Clear Menu: \(openRecentMenu?.items.map(\.title) ?? [])")
  let beforeMissing = try encoder.encode(controller.project)
  click(recentMenu.control("menu-recent-0"))
  require(recent.urls == [strip, other] && controller.status.stringValue == "Gone.vtrace is no longer at \(folderText)/gone."
    && controller.startScreen === recentMenu && (try? encoder.encode(controller.project)) == beforeMissing
    && (recentMenu.control("menu-recent-0") as? NSButton)?.title.hasPrefix("strip.vtrace") == true
    && openRecentMenu?.items.first?.title == "strip.vtrace",
    "a recent project that is gone is removed with a message, and the document is unchanged: \(controller.status.stringValue)")
  grouped {
    if let item = openRecentMenu?.items.first { controller.openRecentAction(item) }
    idle()
  }
  require(controller.startScreen == nil && recentMenu.superview == nil && controller.projectURL == strip
    && recent.urls == [strip, other], "File › Open Recent opens the project like Open Project")
  // A project on a volume that is not connected stays listed, with a message, and the document is unchanged.
  let unmounted = URL(fileURLWithPath: "/Volumes/vibe-tracer-unmounted-\(UUID().uuidString)/Away.vtrace")
  recent.note(unmounted)
  let beforeUnmounted = try encoder.encode(controller.project)
  controller.openRecent(unmounted)
  require(recent.urls == [unmounted, strip, other]
    && controller.status.stringValue == "Away.vtrace is on a volume that is not connected."
    && controller.projectURL == strip && (try? encoder.encode(controller.project)) == beforeUnmounted,
    "a recent project on a volume that is not connected is kept: \(controller.status.stringValue)")
  recent.remove(unmounted)
  // Same-named projects in different folders are told apart in File › Open Recent by their folders.
  let twin = folder.appendingPathComponent("twin/strip.vtrace")
  recent.note(twin)
  require(openRecentMenu?.items.prefix(3).map(\.title)
    == ["strip.vtrace — \(folderText)/twin", "strip.vtrace — \(folderText)", "recent-other.vtrace"],
    "File › Open Recent adds the folder to colliding names: \(openRecentMenu?.items.map(\.title) ?? [])")
  recent.remove(twin)
  controller.showStartScreen()
  guard let clearing = controller.startScreen else { return require(false, "the main menu shows again") }
  click(clearing.control("menu-recent-clear"))
  require(recent.urls.isEmpty && visible(clearing.control("menu-recent-empty"), in: clearing)
    && !visible(clearing.control("menu-recent-clear"), in: clearing) && clearing.control("menu-recent-0") == nil
    && openRecentMenu?.items.map(\.title) == ["Clear Menu"] && openRecentMenu?.items.first?.action == nil,
    "Clear empties the recent projects in the main menu and File › Open Recent")
  grouped {
    click(clearing.control("menu-new"))
    idle()
  }
  require(controller.startScreen == nil && clearing.superview == nil && controller.projectURL == nil
    && !controller.documentEdited && !controller.viewport.isHidden && recent.urls.isEmpty,
    "New Project on the main menu loads an untitled project and removes the main menu")

  controller.viewport.isPaused = true
  controller.saveTimer?.invalidate()
  try controller.restore(ProjectDocument())
  controller.associate(nil, edited: false, replaced: true)
  controller.saveTimer?.invalidate()
  controller.history.removeAllActions()
  print("PASS: fix-start-screen main menu and Scenes window, recent projects, kept and restored autosave, activity strip")
}
try fixStartScreenChecks()
