// Launch start state (AppDelegate, SceneBrowserView): background shader compilation with on-demand
// kernel groups, the scene browser of the empty start screen, the kept and restorable last-session
// autosave, and the activity strip of project operations.
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

  // The start screen: nothing renders, only open and import commands apply, quitting keeps the autosave.
  controller.showStartScreen()
  controller.view.layoutSubtreeIfNeeded()
  guard let start = controller.startScreen else { return require(false, "the start screen is shown") }
  require(controller.viewport.isPaused && controller.viewport.isHidden && start.frame.width > 300,
    "the start screen covers the paused viewport")
  if let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
    controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: studioDirectory.appendingPathComponent("start-screen.png"))
  }
  require(start.control("start-restore")?.superview?.isHidden == false && start.control("start-open")?.isEnabled == true
    && (start.control("scene-filter-0") as? NSButton)?.state == .on && (start.control("scene-filter-1") as? NSButton)?.state == .off
    && start.control("scene-credits")?.isHidden == false
    && start.visibleEntries.count == SceneCatalog.entries.count && start.selection?.id == SceneCatalog.entries.first?.id
    && SceneBrowserView.describe(.scene("lantern-arcade")) == "Opening Lantern Arcade",
    "the start screen offers open, restoring the autosaved session and the scene browser with every catalog scene")

  // The browser: filters, search, the details pane's primary button, the busy state and the minimum window size.
  let browser = SceneBrowserView(library: ExampleLibrary(root: folder.appendingPathComponent("library")))
  require(browser.visibleEntries.count == 21 && browser.selection?.id == "pavilion", "all scenes, first selected")
  browser.filter = .downloads
  require(browser.visibleEntries.count == 10 && browser.visibleEntries.allSatisfy(\.isDownload), "downloads filter")
  browser.filter = .installed
  require(browser.visibleEntries.isEmpty && browser.selection == nil && browser.control("scene-empty")?.isHidden == false,
    "nothing installed")
  browser.filter = .builtIn
  require(browser.visibleEntries.map(\.id) == SceneCatalog.entries(.builtIn).map(\.id)
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
    && SceneBrowserView.thumbnail(SceneCatalog.entry("sponza")!) == nil, "card spec lines and states")
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
  require(browser.control("scene-close")?.isHidden == true && browser.control("scene-download-cancel")?.isHidden == true
    && browser.control("scene-credits")?.isHidden == true,
    "without onClose and onCredits there is no Close button or credits link, and no download progress until one is set")
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
  require(valid(#selector(StudioController.openAction)) && valid(#selector(StudioController.openSceneFileAction))
    && !valid(#selector(StudioController.saveAction)) && !valid(#selector(StudioController.exportAction))
    && !valid(#selector(StudioController.undoAction)), "the start screen enables only open and import commands")
  testRenderer.options.exposure = 3
  controller.changed(reset: false)
  controller.saveTimer?.invalidate()
  try controller.flushAutosave()
  require((try? Data(contentsOf: controller.autosaveURL)) == lastSession,
    "quitting from the start screen keeps the last session's autosave")

  // Restore Last Session loads the autosave and keeps the file.
  controller.performStartAction(.restoreSession)
  require(controller.projectOperationInProgress && !controller.activityStrip.isHidden,
    "restoring runs off the main thread with the activity strip shown")
  idle()
  require(controller.startScreen == nil && testRenderer.options.exposure == 1.75 && !controller.viewport.isPaused
    && controller.activityStrip.isHidden, "restoring the last session dismisses the start screen")
  controller.autosaveQueue.sync {}
  require(FileManager.default.fileExists(atPath: controller.autosaveURL.path)
    && !FileManager.default.fileExists(atPath: controller.previousAutosaveURL.path),
    "a restored session keeps its autosave in place")

  // Another start action keeps the last session as the recovery copy before autosaving anew.
  controller.showStartScreen()
  controller.associate(nil, edited: false, replaced: false)  // The start screen opens with nothing to discard.
  controller.performStartAction(.scene("cornell-box"))
  idle()
  controller.autosaveQueue.sync {}
  require(controller.startScreen == nil && testRenderer.sceneIndex == 1 && controller.projectURL == nil
    && !controller.documentEdited, "a built-in scene opens as a new untitled project")
  require(!testRenderer.denoiserEnabled, "MetalFX is off in a new project")
  // The labelled scene selector lists the built-in scenes, the bundled examples and the downloads in groups.
  func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { views(type, in: $0) }
  }
  controller.page = 0
  controller.rebuild()
  let picker = views(ActionPopup.self, in: controller.stack).first { $0.accessibilityLabel() == "Scene" }
  let headers = picker?.menu?.items.filter(\.isSectionHeader).map(\.title) ?? []
  let captions = views(NSTextField.self, in: controller.stack).map(\.stringValue)
  require(picker?.selectedTag() == 1 && headers == ["Built-in scenes", "Example scenes", "Download examples"]
    && picker?.menu?.items.filter { $0.tag >= StudioController.exampleTag && !$0.isSectionHeader }.count
      == SceneCatalog.entries(.spectral).count + SceneCatalog.entries(.mcguire).count
    && captions.prefix(2).contains("Scene"), "the inspector's Scene selector is labelled and groups built-in, example and download scenes")
  if let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
    controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: studioDirectory.appendingPathComponent("inspector-scene.png"))
  }
  require((try? Data(contentsOf: controller.previousAutosaveURL)) == lastSession,
    "starting another document keeps the last session as Autosave-previous.vtrace")

  // Open Scene File: an OBJ opens as a new untitled scene; with unsaved changes the prompt comes first.
  require(["glb", "gltf", "usdz", "usd", "obj"].allSatisfy(SceneFile.extensions.contains)
    && (start.control("start-open-scene") as? NSButton)?.title == "Open Scene File…" && start.control("start-import-obj") == nil
    && SceneBrowserView.describe(.openScene(URL(fileURLWithPath: "/tmp/Chair.glb"))) == "Opening Chair.glb",
    "the start screen and SceneFile offer one Open Scene File entry for USD, glTF and OBJ")
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
  print("PASS: fix-start-screen empty start state, kept and restored autosave, activity strip")
}
try fixStartScreenChecks()
