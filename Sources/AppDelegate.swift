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
final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var studio: StudioController!
  // Until the launch shader compilation finishes: the start screen, the compilation's progress and
  // the start action the user chose meanwhile, performed once the renderer exists.
  private(set) var startScreen: StartScreenView?
  private var launchProgress: OperationProgress?
  private var launchTimer: Timer?
  private var launchStarted = Date()
  private(set) var pendingStart: StartAction?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
  }

  // The window opens at once on the empty start screen; the GPU shaders compile in the background
  // (minutes on the first launch of a new build, while the Metal compiler service fills its cache)
  // and the studio replaces the launch screen when they are ready.
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
    window.contentMinSize = NSSize(width: 700, height: 440)
    window.center()
    let start = StartScreenView()
    start.setRestore(StudioController.autosaveDate(at: StudioController.defaultAutosaveURL))
    start.onAction = { [weak self] action in self?.queueStartAction(action) }
    start.onCancelPending = { [weak self] in self?.cancelPendingStart() }
    startScreen = start
    window.contentView = start
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
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated { [weak self] in self?.refreshLaunchProgress() }
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
    startScreen?.setProgress(progress.snapshot, hint: slow
      ? "The first launch of a new build compiles the renderer's GPU shaders, which can take a few minutes. Later launches reuse them." : nil)
  }

  private func shadersCompiled(_ device: MTLDevice, _ result: Result<PathTracerRenderer.CompiledShaders, Error>) {
    launchTimer?.invalidate()
    launchTimer = nil
    launchProgress = nil
    do {
      let renderer = try PathTracerRenderer(device: device, shaders: result.get())
      let studio = StudioController(renderer: renderer, window: window)
      self.studio = studio
      window.contentView = studio.view
      let start = startScreen ?? StartScreenView()
      startScreen = nil
      start.setProgress(nil)
      studio.showStartScreen(start)
      launchTrace("shaders-ready")
      // Warm the groups a first scene most likely needs: ReSTIR PT (imported scenes' default) and
      // spectral transport (Automatic's); both compile in the background.
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

  // Before the studio exists, open and import actions ask for their file at once and wait with it.
  func queueStartAction(_ action: StartAction) {
    if let studio {
      studio.performStartAction(action)
      return
    }
    guard pendingStart == nil, let window else { return }
    StartScreenView.chooseFile(for: action, window: window) { [weak self] chosen in
      guard let self, self.studio == nil else {
        self?.studio?.performStartAction(chosen)
        return
      }
      self.pendingStart = chosen
      self.startScreen?.setPending(StartScreenView.describe(chosen) + " once the shaders are ready.")
      self.startScreen?.setActionsEnabled(false)
    }
  }
  private func cancelPendingStart() {
    pendingStart = nil
    startScreen?.setPending(nil)
    startScreen?.setActionsEnabled(true)
  }

  // Quit, window commands and the start actions until StudioController installs the full menus.
  private func installLaunchMenus() {
    let main = NSMenu()
    func menu(_ title: String, _ entries: [(String, String, Selector, AnyObject?)]) {
      let item = NSMenuItem()
      let sub = NSMenu(title: title)
      item.submenu = sub
      main.addItem(item)
      for (title, key, selector, target) in entries {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = target
        sub.addItem(entry)
      }
    }
    menu("Metal Vibe Tracer", [
      ("Hide Metal Vibe Tracer", "h", #selector(NSApplication.hide(_:)), nil),
      ("Quit Metal Vibe Tracer", "q", #selector(NSApplication.terminate(_:)), nil),
    ])
    menu("File", [
      ("Open Project…", "o", #selector(openProjectAction), self), ("Import OBJ…", "", #selector(importOBJAction), self),
      ("Open USD Scene…", "", #selector(importUSDAction), self),
      ("Close Window", "w", #selector(NSWindow.performClose(_:)), nil),
    ])
    menu("Window", [("Minimize", "m", #selector(NSWindow.performMiniaturize(_:)), nil)])
    NSApp.mainMenu = main
  }
  @objc func openProjectAction() { queueStartAction(.openProject(nil)) }
  @objc func importOBJAction() { queueStartAction(.importOBJ(nil)) }
  @objc func importUSDAction() { queueStartAction(.importUSD(nil)) }
}
