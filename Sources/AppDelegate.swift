import Cocoa
import Metal

// With VIBE_LAUNCH_TRACE=1, prints `VIBE_LAUNCH <event> <unix time>` to standard error at launch
// milestones (scripts/measure_launch.swift, tests/PERFORMANCE.md).
let launchTraceEnabled = ProcessInfo.processInfo.environment["VIBE_LAUNCH_TRACE"] == "1"
func launchTrace(_ event: String) {
  guard launchTraceEnabled else { return }
  FileHandle.standardError.write(Data("VIBE_LAUNCH \(event) \(Date().timeIntervalSince1970)\n".utf8))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var window: NSWindow!
  var studio: StudioController!
  // The Scenes window with the scene browser, and the recent projects; both are handed to the studio once it exists.
  private(set) var scenes: ScenesWindowController!
  private var recent: RecentProjects!
  // Until the launch shader compilation finishes: the main menu, the compilation's progress shown on it,
  // and the start action the user chose meanwhile, performed once the renderer exists.
  private var launchMenu: MainMenuView?
  private var openRecentMenu: NSMenu?
  private var launchProgress: OperationProgress?
  private var launchTimer: Timer?
  private var launchStarted = Date()
  private(set) var pendingStart: StartAction?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  // Closing the window asks to quit, so the window is still there when the quit is cancelled
  // (a failed final save): without it the document could no longer be saved.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(nil)
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let studio else { return .terminateNow }
    // An explicit Save (or Open) still running on the project queue finishes first.
    if studio.projectOperationInProgress {
      studio.whenProjectOperationsFinish { [weak self] failure in
        let quit = self?.finishTermination(studio, saveFailure: failure) ?? true
        if !quit { studio.terminationRequested = false }
        sender.reply(toApplicationShouldTerminate: quit)
      }
      return .terminateLater
    }
    return finishTermination(studio, saveFailure: nil) ? .terminateNow : .terminateCancel
  }

  private func finishTermination(_ studio: StudioController, saveFailure: String?) -> Bool {
    func confirm(_ title: String, _ detail: String) -> Bool {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = title
      alert.informativeText = detail
      alert.addButton(withTitle: "Cancel Quit")
      alert.addButton(withTitle: "Quit Anyway")
      return alert.runModal() == .alertSecondButtonReturn
    }
    if let saveFailure, !confirm("The project could not be saved", saveFailure) { return false }
    do {
      try studio.flushAutosave()
      return true
    } catch {
      return confirm("The final autosave failed", error.localizedDescription)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // A quit during an OpenUSD import must not leave the python3 helper or its scratch folder behind.
    studio?.usdImportJob?.cancelAndWait(timeout: 3)
    // An example-scene download stops; its partial archive is replaced on the next attempt.
    studio?.exampleDownload?.cancel()
  }

  // The main window opens at once on the main menu; the Scenes window is created but shown only on request.
  // The GPU shaders compile in the background (minutes on the first launch of a new build, while the Metal
  // compiler service fills its cache) and the studio takes over both windows when they are ready.
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    guard let device = MTLCreateSystemDefaultDevice() else {
      NSAlert(error: MaterialLibrary.error("Metal is unavailable.")).runModal()
      NSApp.terminate(nil)
      return
    }
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    window.title = "Metal Vibe Tracer"
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentMinSize = NSSize(width: 700, height: 440)
    window.center()
    // Restores the frame the window had when the app last quit.
    window.setFrameAutosaveName("MainWindow")
    let scenes = ScenesWindowController(over: window)
    scenes.browser.onAction = { [weak self] action in self?.queueStartAction(action) }
    self.scenes = scenes
    let recent = RecentProjects()
    recent.onChange = { [weak self] in self?.recentProjectsChanged() }
    self.recent = recent
    let menu = MainMenuView()
    menu.onAction = { [weak self] action in self?.queueStartAction(action) }
    menu.onBrowse = { [weak self] in self?.scenes.show() }
    menu.onOpenRecent = { [weak self] url in self?.openRecent(url) }
    menu.onClearRecent = { [weak self] in self?.recent.clear() }
    menu.onCancelPending = { [weak self] in self?.cancelPendingStart() }
    menu.onDropFiles = { [weak self] urls in self?.openDroppedFiles(urls) ?? false }
    menu.setRestore(StudioController.autosaveDate(at: StudioController.defaultAutosaveURL))
    menu.setRecent(recent.shown)
    launchMenu = menu
    window.contentView = menu
    installLaunchMenus()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    launchTrace("window")
    compileShaders(device)
  }

  private func compileShaders(_ device: MTLDevice) {
    let progress = OperationProgress("Preparing GPU shaders")
    launchProgress = progress
    launchStarted = Date()
    let source = metalSource, mathMode = shaderCompileOptions().mathMode
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshLaunchProgress() }
    }
    RunLoop.main.add(timer, forMode: .common)
    launchTimer = timer
    refreshLaunchProgress()
    // The optional kernel groups compile on demand later (PathTracerRenderer.requestKernels).
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result {
        try PathTracerRenderer.compileShaders(device: device, source: source, mathMode: mathMode, groups: [], progress: progress)
      }
      DispatchQueue.main.async { [weak self] in self?.shadersCompiled(device, result) }
    }
  }

  private func refreshLaunchProgress() {
    guard let progress = launchProgress else { return }
    // A cached build compiles in well under a second; explain only a compile that takes a while.
    let slow = Date().timeIntervalSince(launchStarted) > 2
    launchMenu?.setProgress(progress.snapshot, hint: slow
      ? "The first launch of a new build compiles the renderer's GPU shaders, which can take a few minutes. Later launches reuse them." : nil)
  }

  private func shadersCompiled(_ device: MTLDevice, _ result: Result<PathTracerRenderer.CompiledShaders, Error>) {
    launchTimer?.invalidate()
    launchTimer = nil
    launchProgress = nil
    do {
      let renderer = try PathTracerRenderer(device: device, shaders: result.get())
      let studio = StudioController(renderer: renderer, window: window, scenes: scenes, recent: recent)
      self.studio = studio
      launchMenu = nil
      openRecentMenu = nil
      window.contentView = studio.view
      studio.showStartScreen()
      launchTrace("shaders-ready")
      // Warm the groups a first scene most likely needs: ReSTIR PT (imported scenes' default) and,
      // when it is the active transport, spectral transport; both compile in the background.
      renderer.requestKernels([.pt])
      if renderer.activeLightTransport == .spectral { _ = renderer.prepareSpectralShaders() }
      if let pending = pendingStart {
        pendingStart = nil
        studio.performStartAction(pending)
      }
    } catch {
      NSAlert(error: error).runModal()
      NSApp.terminate(nil)
    }
  }

  // Before the studio exists, open and import actions ask for their file at once (a sheet on the Scenes
  // window while it is key, else on the main window) and wait with it, shown on the main menu.
  func queueStartAction(_ action: StartAction) {
    if let studio {
      studio.performStartAction(action)
      return
    }
    guard pendingStart == nil, let window, let scenesWindow = scenes.window else { return }
    SceneBrowserView.chooseFile(for: action, window: scenesWindow.isKeyWindow ? scenesWindow : window) { [weak self] chosen in
      guard let self, self.studio == nil else {
        self?.studio?.performStartAction(chosen)
        return
      }
      self.pendingStart = chosen
      self.launchMenu?.setPending(SceneBrowserView.describe(chosen) + " once the shaders are ready.")
      self.launchMenu?.setActionsEnabled(false)
      self.scenes.browser.setActionsEnabled(false)
    }
  }
  private func cancelPendingStart() {
    pendingStart = nil
    launchMenu?.setPending(nil)
    launchMenu?.setActionsEnabled(true)
    scenes.browser.setActionsEnabled(true)
  }
  // A recent project before the studio exists: queued like Open Project, or, when the file is gone, removed with
  // a message on the main menu.
  private func openRecent(_ url: URL) {
    guard pendingStart == nil else { return }
    recent.open(url, with: { [weak self] in self?.queueStartAction(.openProject($0)) },
      report: { [weak self] in self?.launchMenu?.setMessage($0) })
  }
  private func recentProjectsChanged() {
    launchMenu?.setRecent(recent.shown)
    if let menu = openRecentMenu {
      recent.fill(menu, target: self, open: #selector(openRecentAction(_:)), clear: #selector(clearRecentAction))
    }
  }

  // The studio's menu bar (StudioController.makeMenuBar) with this delegate as the target until StudioController
  // installs its own: New Project, the open commands, Open Recent, Browse Scenes… and User Guide work; the commands
  // that need the studio stay disabled, so the bar keeps its shape.
  private func installLaunchMenus() {
    let menus = StudioController.makeMenuBar(target: self, recent: recent)
    openRecentMenu = menus.openRecent
    NSApp.mainMenu = menus.bar
    NSApp.windowsMenu = menus.window
    NSApp.helpMenu = menus.help
  }
  @objc func newProjectAction() { queueStartAction(.newProject) }
  @objc func openAction() { queueStartAction(.openProject(nil)) }
  @objc func openSceneFileAction() { queueStartAction(.openScene(nil)) }
  @objc func browseScenesAction() { scenes.show() }
  @objc func openRecentAction(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL { openRecent(url) }
  }
  @objc func clearRecentAction() { recent.clear() }
  @objc func userGuideAction() { NSWorkspace.shared.open(MainMenuView.userGuideURL) }
  // A file dropped on the main menu before the studio exists: projects and scene files are queued like their open
  // commands; anything else waits for the studio (StudioController.openDroppedFiles).
  func openDroppedFiles(_ urls: [URL]) -> Bool {
    if let studio { return studio.openDroppedFiles(urls) }
    let refusal: String
    if let url = urls.first, urls.count == 1, pendingStart == nil {
      switch StudioController.dropKind(url) {
      case .project:
        queueStartAction(.openProject(url))
        return true
      case .scene:
        queueStartAction(.openScene(url))
        return true
      case .environment, .materialX: refusal = "Open a project or scene before adding \(url.lastPathComponent)."
      case nil: refusal = StudioController.unsupportedDropMessage(url)
      }
    } else {
      refusal = pendingStart != nil ? "Wait for the queued action, or cancel it." : "Drop one file at a time."
    }
    launchMenu?.setMessage(refusal)
    return false
  }
}

// The commands that open a document wait, like the main menu, while an action is queued.
extension AppDelegate: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(userGuideAction), #selector(browseScenesAction): return true
    default: return pendingStart == nil
    }
  }
}
