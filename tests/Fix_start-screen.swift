// Launch state (AppDelegate, SceneBrowserView, ScenesWindowController): background shader compilation with
// on-demand kernel groups, the "No scene loaded" placeholder and the Scenes window, the kept and restorable
// last-session autosave, and the activity strip of project operations.
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
  require(!compiledOnMain && progress.snapshot.fraction == 1 && progress.snapshot.detail == "9 of 9",
    "launch compiles the nine core pipelines off the main thread with counted progress")
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

  // No document loaded: the No scene loaded placeholder covers the paused viewport and the inspector; nothing renders,
  // only open and import commands apply, quitting keeps the autosave.
  controller.showStartScreen()
  controller.view.layoutSubtreeIfNeeded()
  guard let placeholder = controller.startScreen, placeholder.superview === controller.view,
    placeholder.identifier?.rawValue == "no-scene"
  else { return require(false, "the no-scene placeholder is in the controller's view") }
  require(controller.viewport.isPaused && controller.viewport.isHidden && placeholder.frame.width > 300
    && views(NSTextField.self, in: placeholder).contains { $0.stringValue == "No scene loaded" },
    "with no document the No scene loaded placeholder covers the paused, hidden viewport")
  controller.browseScenes()
  require(scenes.isVisible && controller.isBrowsingScenes, "Browse Scenes shows the Scenes window with no document loaded")
  start.cancelOperation(nil)
  require(!scenes.isVisible && controller.startScreen === placeholder && controller.viewport.isHidden,
    "Esc hides the Scenes window with no document loaded, and the placeholder stays")
  let placeholderBrowse = views(NSButton.self, in: placeholder).first { $0.identifier?.rawValue == "no-scene-browse" }
  require(placeholderBrowse?.title == "Browse Scenes…", "the placeholder has a Browse Scenes… button")
  placeholderBrowse?.performClick(nil)
  require(scenes.isVisible, "the placeholder's Browse Scenes… shows the Scenes window after it was hidden")
  if let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
    controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: studioDirectory.appendingPathComponent("start-screen.png"))
  }
  start.filter = .all; start.search = ""
  require(start.control("start-restore")?.superview?.isHidden == false && start.control("start-open")?.isEnabled == true
    && (start.control("scene-filter-0") as? NSButton)?.state == .on && (start.control("scene-filter-1") as? NSButton)?.state == .off
    && start.control("scene-credits")?.isHidden == false && start.control("scene-close") == nil
    && start.visibleEntries.count == SceneCatalog.entries.count
    && SceneBrowserView.describe(.scene("lantern-arcade")) == "Opening Lantern Arcade",
    "the Scenes window offers open, restoring the autosaved session and every catalog scene, and has no Close button")

  // The browser: filters, search, the details pane's primary button, the busy state and the minimum window size.
  let browser = SceneBrowserView(library: ExampleLibrary(root: folder.appendingPathComponent("library")))
  require(browser.visibleEntries.count == 21 && browser.selection?.id == "pavilion", "all scenes, first selected")
  browser.filter = .downloads
  require(browser.visibleEntries.count == 10 && browser.visibleEntries.allSatisfy(\.isDownload), "downloads filter")
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
  require(browser.control("scene-open")?.isEnabled == false && browser.control("start-open")?.isEnabled == false,
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
    && !valid(#selector(StudioController.undoAction)), "with no document only open, import and browse commands apply")
  testRenderer.options.exposure = 3
  controller.changed(reset: false)
  controller.saveTimer?.invalidate()
  try controller.flushAutosave()
  require((try? Data(contentsOf: controller.autosaveURL)) == lastSession,
    "quitting with no document loaded keeps the last session's autosave")

  // Restore Last Session loads the autosave, keeps the file and hides the Scenes window.
  controller.browseScenes()
  controller.performStartAction(.restoreSession)
  require(controller.projectOperationInProgress && !controller.activityStrip.isHidden,
    "restoring runs off the main thread with the activity strip shown")
  idle()
  require(controller.startScreen == nil && placeholder.superview == nil && testRenderer.options.exposure == 1.75
    && !controller.viewport.isPaused && !controller.viewport.isHidden && controller.activityStrip.isHidden && !scenes.isVisible
    && start.control("start-restore")?.superview?.isHidden == true,
    "restoring the last session removes the placeholder, hides the Scenes window and no longer offers Restore")
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
  func browseButton() -> NSButton? { views(NSButton.self, in: controller.stack).first { $0.identifier?.rawValue == "scene-browse" } }
  require(browseButton()?.title == "Browse…"
    && !views(ActionPopup.self, in: controller.stack).contains { $0.accessibilityLabel() == "Scene" }
    && views(NSTextField.self, in: controller.stack).map(\.stringValue).contains("Cornell Box"),
    "the inspector shows the current scene's title and a Browse… button instead of a Scene selector")
  let fileMenu = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
  let browseItem = fileMenu?.items.first { $0.title == "Browse Scenes…" }
  require(browseItem?.keyEquivalent == "O" && browseItem?.keyEquivalentModifierMask.contains(.command) == true
    && fileMenu?.items.contains { $0.title == "Open Example Scene" } == false
    && fileMenu?.items.contains { $0.action == #selector(StudioController.exampleCreditsAction) } == true,
    "File > Browse Scenes… (shift-command-O) replaces Open Example Scene; Credits and Licenses… stays")
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
  require(start.control("start-restore")?.superview?.isHidden == true && start.control("scene-credits")?.isHidden == false,
    "over a document the Scenes window has Credits and does not offer Restore Last Session")
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
  require(!controller.isBrowsingScenes && !scenes.isVisible && !controller.viewport.isPaused
    && !controller.viewport.isHidden && sameDocument(),
    "Esc hides the Scenes window over a document, and the viewport and the document are untouched")
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
  require(["glb", "gltf", "usdz", "usd", "obj"].allSatisfy(SceneFile.extensions.contains)
    && (start.control("start-open-scene") as? NSButton)?.title == "Open Scene File…" && start.control("start-import-obj") == nil
    && SceneBrowserView.describe(.openScene(URL(fileURLWithPath: "/tmp/Chair.glb"))) == "Opening Chair.glb",
    "the Scenes window and SceneFile offer one Open Scene File entry for USD, glTF and OBJ")
  let sceneObj = folder.appendingPathComponent("quad.obj")
  try "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n".write(to: sceneObj, atomically: true, encoding: .utf8)
  let history = controller.history, groupsByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer { history.groupsByEvent = groupsByEvent }
  func grouped(_ body: () -> Void) { history.beginUndoGrouping(); body(); history.endUndoGrouping() }
  grouped {
    controller.performStartAction(.openScene(sceneObj))
    idle()
  }
  require(controller.startScreen == nil && controller.projectURL == nil
    && controller.project.graph?.assets.map(\.geometry.count) == [2], "Open Scene File opens an OBJ as a new untitled scene")
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
  controller.unsavedChangesAnswer = nil
  controller.associate(nil, edited: false, replaced: false)
  // Saving reports its phase in the activity strip until it finishes.
  var saved = false
  controller.beginSaveProject(folder.appendingPathComponent("strip.vtrace")) { saved = $0 }
  require(!controller.activityStrip.isHidden && controller.activityLabel.stringValue.contains("strip.vtrace"),
    "a save shows its phase in the activity strip")
  idle()
  require(saved && controller.activityStrip.isHidden && controller.activity == nil, "the activity strip clears when the save ends")

  controller.viewport.isPaused = true
  controller.saveTimer?.invalidate()
  try controller.restore(ProjectDocument())
  controller.associate(nil, edited: false, replaced: true)
  controller.saveTimer?.invalidate()
  controller.history.removeAllActions()
  print("PASS: fix-start-screen no-scene placeholder and Scenes window, kept and restored autosave, activity strip")
}
try fixStartScreenChecks()
