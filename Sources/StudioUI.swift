import Cocoa
import CoreImage
import MetalKit
import Synchronization
import UniformTypeIdentifiers
import simd

final class StudioController: NSViewController {
  let renderer: PathTracerRenderer
  weak var hostWindow: NSWindow?
  let viewport: InteractiveMTKView
  let sidebar = NSScrollView(), stack = TopAlignedStackView(), status = NSTextField(labelWithString: "")
  // The activity strip left of the status line: a progress bar, its phase and, for operations that
  // support it, a Cancel button (beginActivity). Background shader compilation shows there too.
  let activityStrip = NSStackView(), activityBar = NSProgressIndicator()
  let activityLabel = NSTextField(labelWithString: "")
  private(set) lazy var activityCancel = ActionButton("Cancel") { [weak self] in self?.activityCancelHandler?() }
  private(set) var activity: OperationProgress?
  private var activityCancelHandler: (() -> Void)?
  private var activityTimer: Timer?
  private var statusAtEdge: NSLayoutConstraint!, statusAfterActivity: NSLayoutConstraint!
  // The main menu (MainMenuView) covering the content until a document is loaded; nil once one is.
  fileprivate(set) var startScreen: MainMenuView?
  // The Scenes window with the app's scene browser, created by AppDelegate at launch.
  let scenes: ScenesWindowController
  // The recent projects of the main menu and File › Open Recent, created by AppDelegate at launch.
  let recent: RecentProjects
  // File › Open Recent's submenu, refilled when the recent projects change.
  var openRecentMenu: NSMenu?
  // The inspector's scene title, refreshed when the document's name changes.
  private weak var sceneTitleLabel: NSTextField?
  var isBrowsingScenes: Bool { scenes.isVisible }
  // Tests answer the Save / Don't Save / Cancel prompt through this instead of showing the sheet.
  var unsavedChangesAnswer: ((@escaping (NSApplication.ModalResponse) -> Void) -> Void)?
  // Tests are told an import report would be shown through this instead of the modal alert.
  var importReportShown: (() -> Void)?
  // Set while Restore Last Session restores the last session, which keeps its autosave file.
  fileprivate var restoringSession = false
  private(set) var errorMessage: String?
  private(set) lazy var errorButton = ActionButton("") { [weak self] in self?.showErrorDetails() }
  let history = UndoManager()
  var project = ProjectDocument()
  var projectURL: URL? { didSet { updateWindowTitle() } }
  var importInProgress = false { didSet { busyStateChanged() } }
  var usdImportJob: USDImportJob?
  // The scene browser's download in progress (ExampleScenes.swift): its job, scene and latest progress, which
  // the browser shows while the scene's card is selected.
  var exampleDownload: ExampleSceneDownload?
  var downloadingScene: SceneEntry?
  var downloadProgress: (fraction: Double, status: String)?
  // Opens (including Restore Last Session), saves and off-main document preparation.
  private(set) var openInFlight = false { didSet { busyStateChanged() } }
  private var saveInFlight = false { didSet { busyStateChanged() } }
  private var preparationInFlight: UInt64? { didSet { busyStateChanged() } }
  var projectOperationInProgress: Bool { openInFlight || saveInFlight || preparationInFlight != nil }
  var isBusy: Bool {
    exportRenderer != nil || previewDenoiseJob != nil || importInProgress || projectOperationInProgress
  }
  var pauseButton: NSButton?
  private var busyButtons: [NSButton] = []
  private var projectActivity = ""
  let autosaveQueue = DispatchQueue(label: "VibeTracer.autosave", qos: .utility)
  private let projectIOQueue = DispatchQueue(label: "VibeTracer.project-io", qos: .userInitiated)
  private var documentRevision: UInt64 = 0
  var openGeneration: UInt64 = 0, saveGeneration: UInt64 = 0, prepareGeneration: UInt64 = 0
  // Changes whenever another document replaces the current one; saves bind to it.
  private var documentIdentity: UInt64 = 0
  private(set) var documentEdited = false {
    didSet { hostWindow?.isDocumentEdited = documentEdited }
  }
  // Quit waits for pending project I/O; the first failed save is reported before quitting.
  var terminationRequested = false
  private var idleWaiters: [(String?) -> Void] = []
  private var pendingSaveFailure: String?
  // Tests redirect the recovery files; production uses Application Support.
  var autosaveURL = StudioController.defaultAutosaveURL
  // Downloaded example scenes (ExampleScenes.swift); tests redirect them too.
  var exampleLibrary = ExampleLibrary() { didSet { scenes.browser.library = exampleLibrary } }
  private(set) var autosaveSuppressed = false
  // Shared with autosaveQueue: the newest queued snapshot and the revision last written.
  private struct AutosaveState {
    var queued: PendingAutosave?
    var written: (revision: UInt64, url: URL)?
  }
  private let autosaveState = Mutex(AutosaveState())
  var selectedSlot = 1, page = 0, sidebarVisible = true
  var selectedNode: UUID?
  var selectedSubset = 0
  var materialXReport = ""
  var sidebarWidth: NSLayoutConstraint!
  var saveTimer: Timer?
  var lastCheckpoint = Date.distantPast
  var isRestoring = false
  private var rebuilding = false, rebuildRequested = false
  // A rebuild requested while a number row's slider is dragged runs when the drag ends (runDeferredRebuild), so the
  // dragged slider is never torn down mid-drag.
  private var rebuildAfterDrag = false
  // Builds the body of every collapsible inspector section, whatever its saved state (tests).
  var forceSectionsOpen = false
  // Inspector state kept across launches (collapsed sections); tests redirect it to a volatile suite.
  var preferences = UserDefaults.standard
  var cameraRefreshPending = false
  var mapThumbnails: [Int: (data: Data, image: NSImage)] = [:]
  var exportRenderer: PathTracerRenderer? { didSet { busyStateChanged() } }
  var exportOutput: MTLTexture?
  var exportURL: URL?
  var exportHDR = false, exportRaw = false, exportDenoise = true, previousPaused = false
  var exportDenoiseJob: OIDNProgress?
  var previewDenoiseJob: OIDNProgress? { didSet { busyStateChanged() } }
  var oidnPreviewWasPaused = false
  var messageUntil = Date.distantPast
  nonisolated static let sceneNames = [
    "Architectural Pavilion", "Cornell Box", "Veach MIS Benchmark", "Cornell Glass & Mirror",
    "Cornell Fog Study", "Reflective Ring Study", "Imported Mesh Studio",
  ]
  static let viewportNames = ["Beauty", "Albedo", "World Normals", "Depth (log)", "Material / Roughness"]
  override var undoManager: UndoManager? { history }

  init(renderer: PathTracerRenderer, window: NSWindow, scenes: ScenesWindowController, recent: RecentProjects) {
    self.renderer = renderer
    hostWindow = window
    self.scenes = scenes
    self.recent = recent
    viewport = InteractiveMTKView(frame: .zero, device: renderer.device)
    super.init(nibName: nil, bundle: nil)
    viewport.renderer = renderer
    viewport.delegate = renderer
    viewport.colorPixelFormat = .bgra8Unorm
    // present_kernel writes sRGB-encoded values; tag the layer to match PNG export.
    viewport.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    viewport.framebufferOnly = false
    viewport.preferredFramesPerSecond = 60
    loadView()
    viewport.onBeginEdit = { [weak self] in self?.checkpoint("Camera", coalesce: true) }
    // Camera-only changes use a longer autosave debounce than document edits.
    viewport.onUserOrbit = { [weak self] in
      self?.changed(reset: false, autosaveDelay: 5)
      self?.scheduleCameraPanelRefresh()
    }
    viewport.canEdit = { [weak self] in self?.isBusy == false }
    viewport.onPick = { [weak self] p in self?.pick(p) }
    renderer.onFrameUpdate = { [weak self] _ in self?.updateStatus() }
    renderer.onError = { [weak self] text in self?.showError(text) }
    renderer.onPausedChange = { [weak self] in self?.busyStateChanged() }
    renderer.onSpectralShadersReady = { [weak self] in self?.rebuild(); self?.refreshActivity() }
    renderer.onKernelsReady = { [weak self] in self?.rebuild(); self?.refreshActivity() }
    installMenus()
    connectSceneBrowser()
    recent.onChange = { [weak self] in self?.recentProjectsChanged() }
    updateWindowTitle()
    rebuild()
  }
  // The window names the project file (with its proxy icon); the app name is the subtitle.
  func updateWindowTitle() {
    sceneTitleLabel?.stringValue = currentSceneTitle
    if startScreen != nil {
      hostWindow?.representedURL = nil
      hostWindow?.title = "Metal Vibe Tracer"
      hostWindow?.subtitle = ""
      return
    }
    hostWindow?.representedURL = projectURL
    hostWindow?.title = documentName
    hostWindow?.subtitle = "Metal Vibe Tracer"
  }
  // The project file's name, or Untitled.
  var documentName: String { projectURL?.lastPathComponent ?? "Untitled" }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    let root = NSView()
    view = root
    let bar = NSStackView()
    bar.orientation = .horizontal
    bar.spacing = 8
    let toggle = ActionButton("Inspector") { [weak self] in
      self?.inspectorAction()
    }
    bar.addArrangedSubview(toggle)
    let open = ActionButton("Open…") { [weak self] in self?.openProject() }
    let save = ActionButton("Save") { [weak self] in self?.saveProject() }
    bar.addArrangedSubview(open)
    bar.addArrangedSubview(save)
    let pause = ActionButton("Pause") { [weak self] in self?.pause() }
    pauseButton = pause
    bar.addArrangedSubview(pause)
    let restart = ActionButton("Restart") { [weak self] in self?.restart() }
    bar.addArrangedSubview(restart)
    let export = ActionButton("Export…") { [weak self] in self?.showPage(5) }
    bar.addArrangedSubview(export)
    let spacer = NSView()
    bar.addArrangedSubview(spacer)
    let settings = ActionButton("Settings…") { [weak self] in self?.settingsAction() }
    bar.addArrangedSubview(settings)
    busyButtons = [open, save, restart, export, settings]
    sidebar.hasVerticalScroller = true
    sidebar.drawsBackground = true
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.setContentHuggingPriority(.required, for: .vertical)
    stack.setContentCompressionResistancePriority(.required, for: .vertical)
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
    sidebar.documentView = stack
    status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    status.lineBreakMode = .byTruncatingTail
    errorButton.isBordered = false
    errorButton.contentTintColor = .systemRed
    errorButton.font = .systemFont(ofSize: 11)
    errorButton.lineBreakMode = .byTruncatingTail
    errorButton.isHidden = true
    errorButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    activityStrip.orientation = .horizontal
    activityStrip.spacing = 6
    activityBar.style = .bar
    activityBar.controlSize = .small
    activityBar.minValue = 0
    activityBar.maxValue = 1
    activityBar.widthAnchor.constraint(equalToConstant: 120).isActive = true
    activityLabel.font = .systemFont(ofSize: 11)
    activityLabel.lineBreakMode = .byTruncatingTail
    activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    activityCancel.controlSize = .small
    activityCancel.font = .systemFont(ofSize: 11)
    for v in [activityBar, activityLabel, activityCancel] { activityStrip.addArrangedSubview(v) }
    activityStrip.isHidden = true
    for v in [bar, viewport, sidebar, activityStrip, status, errorButton] {
      v.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(v)
    }
    stack.translatesAutoresizingMaskIntoConstraints = false
    sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 340)
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
      bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
      bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
      bar.heightAnchor.constraint(equalToConstant: 30),
      status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
      activityStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
      activityStrip.centerYAnchor.constraint(equalTo: status.centerYAnchor),
      activityStrip.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.5),
      status.trailingAnchor.constraint(equalTo: errorButton.leadingAnchor, constant: -8),
      errorButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      errorButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
      errorButton.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.45),
      status.heightAnchor.constraint(equalToConstant: 22),
      sidebar.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
      sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      sidebar.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6), sidebarWidth,
      viewport.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      viewport.topAnchor.constraint(equalTo: sidebar.topAnchor),
      viewport.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
      viewport.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: sidebar.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: sidebar.contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: sidebar.contentView.topAnchor),
    ])
    statusAtEdge = status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12)
    statusAfterActivity = status.leadingAnchor.constraint(equalTo: activityStrip.trailingAnchor, constant: 10)
    statusAtEdge.isActive = true
  }
  // The title of the current scene: the catalog's for a built-in scene, the document's name for imported or opened
  // content (the imported-mesh studio, which has no catalog entry).
  var currentSceneTitle: String {
    let builtIn = SceneCatalog.entries.first { entry in
      if case .builtIn(let index) = entry.source { return index == Int(renderer.sceneIndex) }
      return false
    }
    return builtIn?.title ?? documentName
  }
  // The inspector's scene control: the current scene's title and a button that opens the scene browser.
  func sceneControl() {
    let title = NSTextField(labelWithString: currentSceneTitle)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.lineBreakMode = .byTruncatingTail
    sceneTitleLabel = title
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let browse = ActionButton("Browse…") { [weak self] in self?.browseScenes() }
    browse.identifier = NSUserInterfaceItemIdentifier("scene-browse")
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let row = NSStackView(views: [title, spacer, browse])
    row.orientation = .horizontal
    add(row)
  }
  // Inspector mutations are ignored while a document is restored or project I/O runs.
  var acceptsEdits: Bool { !isBusy && !isRestoring }
  func rebuild() {
    // Re-entrant requests (from callbacks fired while controls are torn down) run afterwards.
    guard !rebuilding else {
      rebuildRequested = true
      return
    }
    if let dragged = NumberControl.dragging, dragged.isDescendant(of: stack) {
      rebuildAfterDrag = true
      return
    }
    rebuilding = true
    defer {
      rebuilding = false
      if rebuildRequested {
        rebuildRequested = false
        rebuild()
      }
    }
    for child in stack.arrangedSubviews {
      // End field editing without committing: removal would otherwise re-send stale text.
      (child as? NumberControl)?.field.abortEditing()
      stack.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    if page == 6 {
      button("‹ Back to Inspector") { [weak self] in self?.page = 0; self?.rebuild() }
      heading("Settings")
    } else {
      caption("Scene")
      sceneControl()
      caption("Inspector page")
      popup(
        ["Render", "Camera", "Lighting", "Materials & Textures", "Objects", "Project & Export"], page,
        label: "Inspector page"
      ) { [weak self] i in
        self?.page = i
        self?.rebuild()
      }
    }
    if exportRenderer != nil {
      heading("Rendering export…")
      text("The preview is paused while the export renders.")
      button("Cancel Export") { [weak self] in self?.cancelExport() }
      return
    }
    if previewDenoiseJob != nil {
      heading("OIDN preview…")
      text("The current accumulation is frozen while OIDN denoises it.")
      button("Cancel OIDN Preview") { [weak self] in self?.cancelOIDNPreview() }
      return
    }
    if projectOperationInProgress || importInProgress {
      heading(projectActivity.isEmpty ? "Working…" : projectActivity)
      text("Editing resumes when the project operation finishes. The progress bar below the viewport shows each step.")
      if let job = usdImportJob { button("Cancel Import") { [weak self] in job.cancel(); self?.show("Cancelling the import…") } }
      return
    }
    switch page {
    case 0: renderPanel()
    case 1: cameraPanel()
    case 2: lightingPanel()
    case 3: materialPanel()
    case 4: objectPanel()
    case 5: filePanel()
    default: settingsPanel()
    }
  }
  // Runs the rebuild deferred while a slider was dragged.
  func runDeferredRebuild() {
    guard rebuildAfterDrag, NumberControl.dragging == nil else { return }
    rebuildAfterDrag = false
    rebuild()
  }
  func show(_ message: String) {
    status.textColor = .labelColor
    status.stringValue = message
    status.toolTip = message
    messageUntil = Date().addingTimeInterval(5)
  }
  // Failures stay visible as a red indicator until dismissed; the full text opens in an alert.
  func showError(_ message: String) {
    show(message)
    status.textColor = .systemRed
    errorMessage = message
    errorButton.title = "⚠ " + (message.split(separator: "\n").first.map(String.init) ?? message)
    errorButton.toolTip = message
    errorButton.isHidden = false
  }
  func dismissError() {
    errorMessage = nil
    errorButton.isHidden = true
  }
  func showErrorDetails() {
    guard let message = errorMessage, let window = hostWindow else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Last error"
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
    scroll.hasVerticalScroller = true
    let text = NSTextView(frame: scroll.bounds)
    text.isEditable = false
    text.string = message
    text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    scroll.documentView = text
    alert.accessoryView = scroll
    alert.addButton(withTitle: "Dismiss")
    alert.addButton(withTitle: "Keep")
    alert.beginSheetModal(for: window) { [weak self] response in
      if response == .alertFirstButtonReturn { self?.dismissError() }
    }
  }
  func updateStatus() {
    pauseButton?.title = renderer.paused ? "Resume" : "Pause"
    busyStateChanged()
    if activityTimer == nil, backgroundShaderProgress != nil { refreshActivity() }
    guard Date() >= messageUntil, exportRenderer == nil else { return }
    let r = renderer
    let state = r.paused ? "Paused" : r.reachedLimit ? "Complete" : "Rendering"
    status.textColor = .labelColor
    status.stringValue = String(
      format: "%@ · %u spp · %.1f fps · %.1f ms GPU · %.1f s · %d×%d", state, r.completedSamples,
      r.framesPerSecond, r.gpuMilliseconds, r.renderElapsed, r.accumTexture?.width ?? 0,
      r.accumTexture?.height ?? 0)
    status.toolTip = status.stringValue
  }
  func pause() {
    guard !isBusy else { return }
    if renderer.offlineDenoisedPreview != nil {
      clearOIDNPreview(resume: true)
      return
    }
    renderer.paused.toggle()
    renderer.lastTick = awakeSeconds()
    messageUntil = .distantPast
    updateStatus()
  }
  func restart() {
    guard !isBusy else { return }
    renderer.resetAccumulation()
    renderer.paused = false
    messageUntil = .distantPast
  }
  func snapshot() -> ProjectDocument {
    var p = project
    p.scene = renderer.sceneIndex
    p.strategy = renderer.samplingMode
    p.sky = renderer.skyMode
    p.fog = renderer.enableFog
    p.medium = renderer.medium
    p.ring = renderer.enableSMS
    p.denoise = renderer.denoiserEnabled
    p.oidn = renderer.oidnOptions
    p.viewportMode = renderer.viewportMode
    p.restirModes = ReSTIRModes(renderer)
    p.options = renderer.options
    p.camera = CameraState(renderer)
    p.scenes[Int(renderer.sceneIndex)] = renderer.materials.state()
    p.environmentData = renderer.materials.environmentData
    p.version = 2
    p.triangles = p.graph == nil ? renderer.materials.meshTriangles : []
    p.recovery = nil
    return p
  }
  // An undo step is captured before an action and registered only once it succeeds.
  struct UndoRecord {
    let name: String
    let document: ProjectDocument
    // Set for actions that replace the document (Open, New, USD open).
    let association: DocumentAssociation?
  }
  struct DocumentAssociation {
    var url: URL?
    var edited: Bool
  }
  func undoRecord(_ name: String, replacesDocument: Bool = false) -> UndoRecord? {
    guard !isRestoring, !isBusy else { return nil }
    return UndoRecord(
      name: name, document: snapshot(),
      association: replacesDocument ? DocumentAssociation(url: projectURL, edited: documentEdited) : nil)
  }
  func commit(_ record: UndoRecord?) {
    guard let record else { return }
    lastCheckpoint = Date()
    history.levelsOfUndo = 40
    history.registerUndo(withTarget: self) { target in target.applyUndo(record) }
    history.setActionName(record.name)
  }
  func checkpoint(_ name: String, coalesce: Bool = false) {
    guard !isRestoring, !isBusy else { return }
    if coalesce && Date().timeIntervalSince(lastCheckpoint) < 0.5 {
      lastCheckpoint = Date()  // A continuing burst (a long colour-panel drag) stays one undo step.
      return
    }
    commit(undoRecord(name))
  }
  func applyUndo(_ record: UndoRecord) {
    // Register the inverse synchronously so UndoManager files it on the redo (or undo)
    // stack even when the document is prepared off the main thread.
    let inverse = UndoRecord(
      name: record.name, document: snapshot(),
      association: record.association.map { _ in
        DocumentAssociation(url: projectURL, edited: documentEdited)
      })
    history.registerUndo(withTarget: self) { $0.applyUndo(inverse) }
    history.setActionName(record.name)
    replaceDocument(record.document, activity: "Restoring “\(record.name)”…") { [weak self] error in
      guard let self else { return }
      if let error {
        self.showError(error.localizedDescription)
        return
      }
      // Undoing Open/New/USD open returns the previous file association too.
      if let association = record.association {
        self.associate(association.url, edited: true, replaced: true, undoing: true)
      }
      self.changed(reset: false)
    }
  }
  func changed(reset: Bool = true, autosaveDelay: TimeInterval = 1) {
    documentRevision &+= 1
    documentEdited = true
    if reset { renderer.resetAccumulation() }
    scheduleAutosave(after: autosaveDelay)
  }
  private func scheduleAutosave(after delay: TimeInterval = 1) {
    saveTimer?.invalidate()
    // Scheduled on the main run loop, so the timer fires on the main actor.
    saveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.autosave() }
    }
  }
  // Records the file association after open/save/new and refreshes the recovery metadata. A replaced document
  // (an open or New, not an undo or redo of one) hides the Scenes window.
  func associate(_ url: URL?, edited: Bool, replaced: Bool, undoing: Bool = false) {
    projectURL = url
    if replaced { documentIdentity &+= 1 }
    if replaced && !undoing { scenes.hideAfterOpening() }
    documentEdited = edited
    documentRevision &+= 1
    scheduleAutosave()
  }
  private func busyStateChanged() {
    let enabled = !isBusy
    if enabled, activity != nil {
      activity = nil
      activityCancelHandler = nil
      refreshActivity()
    }
    scenes.browser.setActionsEnabled(enabled)
    startScreen?.setActionsEnabled(enabled)
    for button in busyButtons { button.isEnabled = enabled }
    pauseButton?.isEnabled = enabled
    pauseButton?.title = renderer.paused ? "Resume" : "Pause"
  }
  @discardableResult func beginProjectActivity(_ activity: String, cancel: (() -> Void)? = nil) -> OperationProgress {
    projectActivity = activity
    show(activity)
    let progress = beginActivity(activity.hasSuffix("…") ? String(activity.dropLast()) : activity, cancel: cancel)
    rebuild()
    return progress
  }
  // Shows a new operation's progress in the activity strip (and on the main menu) until the
  // controller is no longer busy; `cancel` adds a Cancel button. Call it once the operation is busy.
  @discardableResult func beginActivity(_ phase: String, cancel: (() -> Void)? = nil) -> OperationProgress {
    let progress = OperationProgress(phase)
    activity = progress
    activityCancelHandler = cancel
    refreshActivity()
    return progress
  }
  // Background compilation of optional kernel groups or spectral pipelines.
  var backgroundShaderProgress: OperationProgress? {
    renderer.sceneShaders.progress ?? renderer.spectralShaders.progress
  }
  // Updates the activity strip from the current progress; polls at 10 Hz while one is shown.
  func refreshActivity() {
    let progress = activity ?? backgroundShaderProgress
    let visible = progress != nil
    if activityStrip.isHidden == visible {
      activityStrip.isHidden = !visible
      statusAtEdge.isActive = !visible
      statusAfterActivity.isActive = visible
    }
    activityCancel.isHidden = activity == nil || activityCancelHandler == nil
    if let snapshot = progress?.snapshot {
      activityLabel.stringValue = snapshot.text
      activityStrip.toolTip = snapshot.text
      if let fraction = snapshot.fraction {
        activityBar.isIndeterminate = false
        activityBar.doubleValue = fraction
      } else {
        activityBar.isIndeterminate = true
      }
      activityBar.startAnimation(nil)
    } else {
      activityBar.stopAnimation(nil)
    }
    // An operation started with no document loaded shows its progress on the main menu too.
    startScreen?.setProgress(activity?.snapshot)
    if visible, activityTimer == nil {
      let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshActivity() }
      }
      RunLoop.main.add(timer, forMode: .common)
      activityTimer = timer
    } else if !visible {
      activityTimer?.invalidate()
      activityTimer = nil
    }
  }
  // Runs quit continuations once no project I/O remains.
  private func finishProjectOperation() {
    guard !projectOperationInProgress else { return }
    let waiters = idleWaiters, failure = pendingSaveFailure
    idleWaiters = []
    pendingSaveFailure = nil
    for waiter in waiters { waiter(failure) }
  }
  // Calls `body` when pending opens, saves and preparations have finished, with the
  // first failed save (if any), so quitting never discards an explicit Save.
  func whenProjectOperationsFinish(_ body: @escaping (String?) -> Void) {
    terminationRequested = true
    idleWaiters.append(body)
    finishProjectOperation()
  }
  // Validates and prepares a complete candidate library. With `reuse`, unchanged maps,
  // MaterialX images, the environment and the flattened mesh and BVH are adopted from
  // the live library instead of being decoded or rebuilt. Safe on projectIOQueue.
  // `resident` (default: the snapshot in `reuse`) is the published library's texture
  // set, taken on the main thread. It stays live until applyProject, so the candidate
  // budgets and shares against it.
  nonisolated func prepareResources(
    _ p: ProjectDocument, reuse: ReusableResources? = nil, resident: MaterialLibrary.ResidentTextures? = nil,
    progress: OperationProgress? = nil
  ) throws -> MaterialLibrary {
    try p.validate()
    let resources = try MaterialLibrary(
      device: renderer.device, function: renderer.materialFunction)
    resources.progress = progress
    resources.external = resident ?? reuse?.resident ?? MaterialLibrary.ResidentTextures()
    if let reuse { resources.adopt(reuse) }
    try resources.restore(p.scenes[Int(p.scene)] ?? SceneState())
    try resources.setEnvironment(p.environmentData)
    if let reuse, let graph = p.graph, reuse.hasSceneGraph, let live = reuse.graph,
      graph.sameGeometry(as: live)
    {
      if !graph.sameBindings(as: live) { try resources.setMeshBindings(graph) }
    } else if let reuse, p.graph == nil, !reuse.hasSceneGraph,
      sameBytes(p.triangles, reuse.meshTriangles)
    {
      // The adopted flattened mesh and BVH are already bound.
    } else {
      try resources.setMesh(p)
    }
    resources.hasSceneGraph = p.graph != nil
    resources.progress = nil
    return resources
  }
  // Only radiance-affecting differences restart accumulation. Display-only state
  // (exposure, white balance, tone map, divider, MetalFX, viewport mode, limits,
  // export settings, saved views) keeps the accumulated samples and OIDN preview.
  func applyProject(_ p: ProjectDocument, resources: MaterialLibrary?, resourcesChanged: Bool = true) {
    if startScreen != nil { dismissStartScreen() }
    isRestoring = true
    defer { isRestoring = false }
    let r = renderer
    let radianceChanged =
      resourcesChanged || r.sceneIndex != p.scene || r.samplingMode != p.strategy
      || r.skyMode != p.sky || r.enableFog != p.fog || r.medium != p.medium || r.enableSMS != p.ring
      || !r.options.sameRadiance(as: p.options) || ReSTIRModes(r) != p.restirModes
    let oidn = p.oidn ?? OIDNOptions()
    if oidn != r.oidnOptions, r.offlineDenoisedPreview != nil {
      r.offlineDenoisedPreview = nil
      r.paused = oidnPreviewWasPaused
    }
    if let resources {
      r.materials = resources
      resources.external = MaterialLibrary.ResidentTextures()
      if let side = resources.graphTextureSide {
        show("Large textures are shown at reduced resolution (down to \(side) px) to fit GPU memory; the project keeps the full-size images.")
      }
    }
    project = p
    r.sceneIndex = p.scene
    r.samplingMode = p.strategy
    r.skyMode = p.sky
    r.enableFog = p.fog
    r.medium = p.medium
    r.enableSMS = p.ring
    r.denoiserEnabled = p.denoise && r.supportsMetalFX
    r.oidnOptions = oidn
    r.viewportMode = p.viewportMode ?? 0
    p.restirModes.apply(r)
    r.options = p.options
    // Camera properties reset accumulation (keeping MetalFX history) only when they change.
    p.camera.apply(r)
    if radianceChanged { r.resetAccumulation() }
    r.presentationNeedsRefresh = true
    rebuild()
  }
  func restore(_ p: ProjectDocument) throws {
    prepareGeneration &+= 1
    applyProject(p, resources: try prepareResources(p, resident: renderer.materials.residentSnapshot()))
  }
  private enum ResourceChange { case none, inPlace, prepare }
  private func resourceChange(to p: ProjectDocument) -> ResourceChange {
    let live = renderer.materials
    let current = live.state(), target = p.scenes[Int(p.scene)] ?? SceneState()
    guard p.environmentData == live.environmentData, current.hasImages(of: target) else {
      return .prepare
    }
    let sameMesh: Bool
    if let graph = p.graph {
      sameMesh =
        live.hasSceneGraph
        && project.graph.map { graph.sameGeometry(as: $0) && graph.sameBindings(as: $0) } == true
    } else {
      sameMesh = !live.hasSceneGraph && sameBytes(p.triangles, live.meshTriangles)
    }
    return sameMesh && current.sameResources(as: target) ? .none : .inPlace
  }
  // Updates the live library like the forward edits do; no image is decoded because
  // resourceChange(to:) verified every map and graph image is already resident.
  private func applyInPlace(_ p: ProjectDocument) throws {
    let live = renderer.materials
    let previous = live.state(), target = p.scenes[Int(p.scene)] ?? SceneState()
    let materialsChanged = !previous.sameResources(as: target)
    if materialsChanged { try live.restore(target) }
    do {
      if let graph = p.graph, live.hasSceneGraph, let current = project.graph,
        graph.sameGeometry(as: current)
      {
        if !graph.sameBindings(as: current) { try live.setMeshBindings(graph) }
      } else if p.graph != nil || live.hasSceneGraph || !sameBytes(p.triangles, live.meshTriangles) {
        try live.setMesh(p)
      }
    } catch {
      if materialsChanged {
        do { try live.restore(previous) } catch let rollback {
          throw MaterialLibrary.error(
            "\(error.localizedDescription) Rollback also failed (\(rollback.localizedDescription)).")
        }
      }
      throw error
    }
    live.hasSceneGraph = p.graph != nil
  }
  // Publishes a replacement document (undo/redo, scene switch, New). Camera, option and
  // display-only differences apply directly and resource edits that need no decoding
  // update the live library in place; anything else is prepared on projectIOQueue.
  // `completion` runs on the main thread, synchronously for the first two cases.
  func replaceDocument(_ p: ProjectDocument, activity: String, completion: @escaping (Error?) -> Void) {
    switch resourceChange(to: p) {
    case .none:
      prepareGeneration &+= 1
      applyProject(p, resources: nil, resourcesChanged: false)
      completion(nil)
    case .inPlace:
      prepareGeneration &+= 1
      do {
        try applyInPlace(p)
        applyProject(p, resources: nil)
        completion(nil)
      } catch { completion(error) }
    case .prepare:
      beginDocumentChange(activity, build: { _ in (p, ()) }) { result in
        if case .failure(let error) = result { completion(error) } else { completion(nil) }
      }
    }
  }
  // Builds a candidate document (parsing imports) and prepares its resources on
  // projectIOQueue, then publishes it unless a newer replacement superseded it.
  func beginDocumentChange<Extra: Sendable>(
    _ activity: String, build: @escaping @Sendable (OperationProgress) throws -> (ProjectDocument, Extra),
    completion: @escaping @MainActor (Result<Extra, Error>) -> Void
  ) {
    prepareGeneration &+= 1
    let generation = prepareGeneration
    let reuse = renderer.materials.reusableResources(graph: project.graph)
    preparationInFlight = generation
    let progress = beginProjectActivity(activity)
    projectIOQueue.async { [weak self] in
      guard let self else { return }
      let result = Result { () -> (ProjectDocument, Extra, MaterialLibrary) in
        let (document, extra) = try build(progress)
        return (document, extra, try self.prepareResources(document, reuse: reuse, progress: progress))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if self.preparationInFlight == generation { self.preparationInFlight = nil }
        guard generation == self.prepareGeneration else {
          self.finishProjectOperation()
          return
        }
        switch result {
        case .success(let (document, extra, resources)):
          self.applyProject(document, resources: resources)
          completion(.success(extra))
        case .failure(let error): completion(.failure(error))
        }
        self.rebuild()
        self.finishProjectOperation()
      }
    }
  }
  func switchScene(_ i: Int, then: (() -> Void)? = nil) {
    guard !isBusy, UInt32(i) != renderer.sceneIndex else { return }
    let record = undoRecord("Scene")
    var p = snapshot()
    p.scene = UInt32(i)
    let oldCamera = CameraState(renderer)
    let oldScene = renderer.sceneIndex
    renderer.sceneIndex = UInt32(i)
    p.camera = CameraState(renderer)
    renderer.sceneIndex = oldScene
    oldCamera.apply(renderer)
    replaceDocument(p, activity: "Switching scene…") { [weak self] error in
      guard let self else { return }
      if let error {
        self.showError(error.localizedDescription)
        self.rebuild()
        return
      }
      self.commit(record)
      self.changed(reset: false)
      then?()
    }
  }
  func newProject() {
    guard !isBusy else { return }
    let record = undoRecord("New project", replacesDocument: true)
    replaceDocument(ProjectDocument(), activity: "Creating project…") { [weak self] error in
      guard let self else { return }
      if let error {
        self.showError(error.localizedDescription)
        return
      }
      self.backUpReplacedDocument(record)
      self.commit(record)
      self.associate(nil, edited: false, replaced: true)
      self.rebuild()
    }
  }
  // Standard Save / Don't Save / Cancel prompt before Open, New and Open Scene File
  // replace an edited document, as a sheet on sheetWindow.
  func confirmDiscardingChanges(_ proceed: @escaping () -> Void) {
    guard !isBusy else { return }
    if documentEdited, let answer = unsavedChangesAnswer {
      answer { [weak self] response in self?.resolveUnsavedChanges(response, proceed) }
      return
    }
    guard documentEdited, let window = sheetWindow else {
      proceed()
      return
    }
    let alert = NSAlert()
    alert.messageText =
      "Do you want to save the changes made to “\(projectURL?.lastPathComponent ?? "Untitled project")”?"
    alert.informativeText =
      "If you don't save, the current version is kept only as a recovery copy (\(previousAutosaveURL.lastPathComponent))."
    alert.addButton(withTitle: "Save")
    let discard = alert.addButton(withTitle: "Don't Save")
    discard.keyEquivalent = "d"
    discard.keyEquivalentModifierMask = .command
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      // Present any follow-up sheet after this one has been ordered out.
      DispatchQueue.main.async { self?.resolveUnsavedChanges(response, proceed) }
    }
  }
  func resolveUnsavedChanges(_ response: NSApplication.ModalResponse, _ proceed: @escaping () -> Void) {
    switch response {
    case .alertFirstButtonReturn:
      saveProject { [weak self] saved in
        if saved, self?.terminationRequested == false { proceed() }
      }
    case .alertSecondButtonReturn: proceed()
    default: break
    }
  }
  static var defaultAutosaveURL: URL {
    (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("VibeTracer/Autosave.vtrace")
  }
  // Recovery copy of the document replaced by Open, New or USD open while edited.
  var previousAutosaveURL: URL {
    autosaveURL.deletingLastPathComponent().appendingPathComponent("Autosave-previous.vtrace")
  }
  struct PendingAutosave {
    var document: ProjectDocument
    var revision: UInt64
    var url: URL
  }
  private func autosaveSnapshot() -> ProjectDocument {
    var document = snapshot()
    document.recovery = AutosaveRecovery(projectPath: projectURL?.path, edited: documentEdited)
    return document
  }
  // autosaveQueue only: writes the newest queued snapshot.
  nonisolated private func drainAutosave() -> Error? {
    let item = autosaveState.withLock { state -> PendingAutosave? in
      let item = state.queued
      state.queued = nil
      return item
    }
    guard let item else { return nil }
    return writeAutosave(item)
  }
  // Payloads go to AutosaveAssets/ beside the file, each written once (ProjectAssets).
  nonisolated private func writeAutosave(_ document: ProjectDocument, to url: URL) throws {
    _ = try document.writeAutosave(to: url)
  }
  // autosaveQueue only: skips a revision that is already on disk at that location.
  nonisolated private func writeAutosave(_ item: PendingAutosave) -> Error? {
    let written = autosaveState.withLock { $0.written }
    if let written, written.revision == item.revision, written.url == item.url { return nil }
    do { try writeAutosave(item.document, to: item.url) } catch { return error }
    autosaveState.withLock { $0.written = (item.revision, item.url) }
    return nil
  }
  private func markAutosaved() {
    let written = (revision: documentRevision, url: autosaveURL)
    autosaveState.withLock { $0.written = written }
  }
  func autosave() {
    guard !isRestoring, !autosaveSuppressed, startScreen == nil else { return }
    let item = PendingAutosave(
      document: autosaveSnapshot(), revision: documentRevision, url: autosaveURL)
    let scheduled = autosaveState.withLock { state -> Bool in
      let scheduled = state.queued != nil
      state.queued = item
      return scheduled
    }
    // Coalesce: an already queued write picks up this newer snapshot.
    guard !scheduled else { return }
    autosaveQueue.async { [weak self] in
      guard let self, let error = self.drainAutosave() else { return }
      let message = error.localizedDescription
      DispatchQueue.main.async { self.showError("Autosave failed: \(message)") }
    }
  }
  // The serial queue orders this snapshot after every pending periodic save, so an
  // older snapshot can never replace the final state during application shutdown.
  // Nothing is rewritten when the current revision is already on disk.
  func flushAutosave(to destination: URL? = nil) throws {
    // Quitting from the main menu keeps the last session's autosave for the next launch.
    guard !isRestoring, !autosaveSuppressed, startScreen == nil || destination != nil else { return }
    saveTimer?.invalidate()
    saveTimer = nil
    let item = PendingAutosave(
      document: autosaveSnapshot(), revision: documentRevision, url: destination ?? autosaveURL)
    var failure: Error?
    autosaveQueue.sync {
      autosaveState.withLock { state in
        if state.queued?.url == item.url { state.queued = nil }
      }
      _ = drainAutosave()
      failure = writeAutosave(item)
    }
    if let failure { throw failure }
  }
  // Keeps the document replaced by Open/New/USD open when it had unsaved changes.
  func backUpReplacedDocument(_ record: UndoRecord?) {
    guard let record, let association = record.association, association.edited,
      !autosaveSuppressed
    else { return }
    var copy = record.document
    copy.recovery = AutosaveRecovery(projectPath: association.url?.path, edited: true)
    let document = copy, url = previousAutosaveURL
    autosaveQueue.async { [weak self] in
      do { try self?.writeAutosave(document, to: url) } catch {
        let message = error.localizedDescription
        DispatchQueue.main.async { self?.showError("Recovery copy failed: \(message)") }
      }
    }
  }
  // Moves an autosave that cannot be restored aside so no later autosave can overwrite it.
  nonisolated static func preserveUnrestorableAutosave(_ url: URL) throws -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let folder = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent + "-unrestorable-" + formatter.string(from: Date())
    var target = folder.appendingPathComponent(base + ".vtrace")
    var suffix = 2
    while FileManager.default.fileExists(atPath: target.path) {
      target = folder.appendingPathComponent("\(base)-\(suffix).vtrace")
      suffix += 1
    }
    try FileManager.default.moveItem(at: url, to: target)
    return target
  }
  // Reads, decodes and prepares the autosave off the main thread. A failed restore
  // keeps the file under a new name and nothing is autosaved until the next edit.
  func restoreAutosave() {
    let url = autosaveURL
    guard FileManager.default.fileExists(atPath: url.path), !isBusy else { return }
    openGeneration &+= 1
    let generation = openGeneration
    let reuse = renderer.materials.reusableResources(graph: project.graph)
    openInFlight = true
    let progress = beginProjectActivity("Restoring autosaved project…")
    projectIOQueue.async { [weak self] in
      guard let self else { return }
      let result = Result { () -> (ProjectDocument, MaterialLibrary) in
        let data = try self.readBounded(url, maximum: ProjectDocument.maximumFileBytes)
        progress.begin("Decoding the autosaved project")
        let document = try ProjectDocument.decodeProject(data, near: url)
        return (document, try self.prepareResources(document, reuse: reuse, progress: progress))
      }
      var preserved: Result<URL, Error>?
      if case .failure = result { preserved = Result { try Self.preserveUnrestorableAutosave(url) } }
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.openGeneration else { return }
        self.openInFlight = false
        switch result {
        case .success(let (document, resources)):
          self.prepareGeneration &+= 1
          self.applyProject(document, resources: resources)
          self.scenes.hideAfterOpening()
          // Recovered work keeps its file association and unsaved state.
          let path = document.recovery?.projectPath.map { URL(fileURLWithPath: $0) }
          self.projectURL = path.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
          self.documentIdentity &+= 1
          self.documentEdited = document.recovery?.edited ?? true
          self.show("Restored autosaved project")
        case .failure(let error):
          switch preserved {
          case .success(let moved)?:
            self.showError("Could not restore autosave: \(error.localizedDescription) It was kept as \(moved.path).")
          case .failure(let moveError)?:
            self.autosaveSuppressed = true
            self.showError(
              "Could not restore autosave: \(error.localizedDescription) Autosave is off for this session because the file could not be kept (\(moveError.localizedDescription)).")
          case nil: break
          }
        }
        // The file on disk (or its preserved copy) already holds this state.
        self.markAutosaved()
        self.restoringSession = false
        self.startScreen?.setRestore(Self.autosaveDate(at: url))
        self.rebuild()
        self.finishProjectOperation()
      }
    }
  }
  func chooseOpen(_ title: String, extensions: [String], _ action: @escaping (URL) -> Void) {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.title = title
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
    guard let window = sheetWindow else { return }
    panel.beginSheetModal(for: window) { response in
      if response == .OK, let url = panel.url { action(url) }
    }
  }
  func chooseSave(
    _ title: String, name: String, ext: String, cancelled: (() -> Void)? = nil,
    _ action: @escaping (URL) -> Void
  ) {
    let panel = NSSavePanel()
    panel.title = title
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
    guard let window = hostWindow else {
      cancelled?()
      return
    }
    panel.beginSheetModal(for: window) { response in
      if response == .OK, let url = panel.url { action(url) } else { cancelled?() }
    }
  }
  func openProject() {
    confirmDiscardingChanges { [weak self] in
      self?.chooseOpen("Open Metal Vibe Tracer project", extensions: ["vtrace", "json"]) {
        [weak self] url in self?.beginOpenProject(url)
      }
    }
  }
  func beginOpenProject(_ url: URL) {
    guard !isBusy else { return }
    let record = undoRecord("Open project", replacesDocument: true)
    openGeneration &+= 1
    let generation = openGeneration
    let reuse = renderer.materials.reusableResources(graph: project.graph)
    openInFlight = true
    let progress = beginProjectActivity("Opening \(url.lastPathComponent)…")
    projectIOQueue.async { [weak self] in
      guard let self else { return }
      let result = Result { () -> (ProjectDocument, MaterialLibrary) in
        let data = try self.readBounded(url, maximum: ProjectDocument.maximumFileBytes)
        progress.begin("Decoding \(url.lastPathComponent)")
        let document = try ProjectDocument.decodeProject(data, near: url)
        return (document, try self.prepareResources(document, reuse: reuse, progress: progress))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.openGeneration else { return }
        self.openInFlight = false
        switch result {
        case .success(let (document, resources)):
          self.prepareGeneration &+= 1
          self.backUpReplacedDocument(record)
          self.applyProject(document, resources: resources)
          self.commit(record)
          self.associate(url, edited: false, replaced: true)
          self.recent.note(url)
          self.show("Opened \(url.lastPathComponent)")
        case .failure(let error): self.showError(error.localizedDescription)
        }
        self.rebuild()
        self.finishProjectOperation()
      }
    }
  }
  nonisolated func readBounded(_ url: URL, maximum: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    if let size = values.fileSize, size > maximum {
      throw MaterialLibrary.error("\(url.lastPathComponent) exceeds the supported file-size limit.")
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count <= maximum else {
      throw MaterialLibrary.error("\(url.lastPathComponent) exceeds the supported file-size limit.")
    }
    return data
  }
  // `completion` reports whether the document was written (false when busy, cancelled or failed).
  func saveProject(asNew: Bool = false, completion: (@MainActor (Bool) -> Void)? = nil) {
    guard !isBusy else {
      completion?(false)
      return
    }
    let write: (URL) -> Void = { [weak self] url in
      self?.beginSaveProject(url, completion: completion)
    }
    if let url = projectURL, !asNew {
      write(url)
    } else {
      chooseSave(
        "Save project", name: projectURL?.lastPathComponent ?? "Untitled.vtrace", ext: "vtrace",
        cancelled: { completion?(false) }, write)
    }
  }
  func beginSaveProject(_ url: URL, completion: (@MainActor (Bool) -> Void)? = nil) {
    guard !isBusy else {
      completion?(false)
      return
    }
    let document = snapshot()
    let revision = documentRevision, identity = documentIdentity
    saveGeneration &+= 1
    let generation = saveGeneration
    saveInFlight = true
    let progress = beginProjectActivity("Saving \(url.lastPathComponent)…")
    projectIOQueue.async { [weak self] in
      let result = Result {
        progress.begin("Encoding \(url.lastPathComponent)")
        let data = try document.encodeForSaving()
        progress.begin("Writing \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
        try data.write(to: url, options: .atomic)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.saveGeneration else { return }
        self.saveInFlight = false
        switch result {
        case .success:
          // Bind the file only to the document that was saved.
          if self.documentIdentity == identity {
            self.associate(
              url, edited: self.documentEdited && self.documentRevision != revision, replaced: false)
          }
          self.recent.note(url)
          self.show("Saved \(url.lastPathComponent)")
          completion?(true)
        case .failure(let error):
          let message = "\(url.lastPathComponent): \(error.localizedDescription)"
          if self.pendingSaveFailure == nil { self.pendingSaveFailure = message }
          self.showError(error.localizedDescription)
          completion?(false)
        }
        self.rebuild()
        self.finishProjectOperation()
      }
    }
  }
  // Keeps edits within the aggregate embedded-asset limit that open enforces.
  nonisolated func requireEmbeddedCapacity(_ total: Int) throws {
    guard total <= ProjectDocument.embeddedAssetLimit else {
      throw MaterialLibrary.error(
        "Embedded images would total \(total / 1_048_576) MiB across all scenes, above the \(ProjectDocument.embeddedAssetLimit / 1_048_576) MiB project limit. Remove or downsize other maps, MaterialX images or the environment first."
      )
    }
  }
  func pick(_ pixel: SIMD2<Float>) {
    guard !isBusy else { return }
    let resources = renderer.materials
    let scene = renderer.sceneIndex
    let generation = renderer.interactionGeneration
    renderer.pick(pixel) { [weak self] slot in
      guard let self, let slot, self.renderer.materials === resources,
        self.renderer.sceneIndex == scene, self.renderer.interactionGeneration == generation
      else { return }
      if slot >= SceneLimits.materials, let graph = self.project.graph, graph.nodes.indices.contains(slot - SceneLimits.materials) {
        let node = graph.nodes[slot - SceneLimits.materials]
        self.selectedNode = node.id
        self.selectedSubset = 0
        self.selectedSlot =
          graph.materials.first(where: { $0.id == node.bindings.first })?.slot ?? 1
        self.showPage(3)
        self.show("Selected \(node.name)")
        return
      }
      guard slot < 8 else { return }
      self.selectedNode = nil
      self.selectedSlot = slot
      self.showPage(3)
      self.show("Selected \(self.objectNames()[slot])")
    }
  }
  // Page switches from menus, the toolbar and picks reveal a hidden inspector.
  func showPage(_ index: Int) {
    if !sidebarVisible { inspectorAction() }
    page = index
    rebuild()
  }
}

// The main menu shown while no document is loaded, recent projects, and the Scenes window (ScenesWindowController) with
// the scene browser.
extension StudioController {
  // The Scenes window while it is the key window, else the main window: where the scene browser's sheets and open
  // panels attach.
  var sheetWindow: NSWindow? { scenes.window?.isKeyWindow == true ? scenes.window : hostWindow }
  // Takes over the browser from the launch state (AppDelegate): its actions, downloads and credits now go through the
  // studio.
  private func connectSceneBrowser() {
    let browser = scenes.browser
    browser.library = exampleLibrary
    browser.onAction = { [weak self] action in self?.performStartAction(action) }
    browser.onDownload = { [weak self] entry in self?.beginSceneDownload(entry) }
    browser.onCancelDownload = { [weak self] in self?.cancelSceneDownload() }
    browser.onCredits = { [weak self] in self?.showExampleCredits() }
    browser.setActionsEnabled(!isBusy)
    browser.setDownload(downloadingScene, fraction: downloadProgress?.fraction, status: downloadProgress?.status)
  }
  // No document loaded: the main menu covers the viewport and inspector until a document loads, and offers the last
  // session. Nothing renders meanwhile, and no autosave is written, so the last session stays restorable.
  func showStartScreen() {
    if let menu = startScreen {
      menu.setRestore(Self.autosaveDate(at: autosaveURL))
      return
    }
    let menu = MainMenuView()
    menu.onAction = { [weak self] action in self?.performStartAction(action) }
    menu.onBrowse = { [weak self] in self?.browseScenes() }
    menu.onOpenRecent = { [weak self] url in self?.openRecent(url) }
    menu.onClearRecent = { [weak self] in self?.recent.clear() }
    menu.onCredits = { [weak self] in self?.showExampleCredits() }
    menu.setRestore(Self.autosaveDate(at: autosaveURL))
    menu.setRecent(recent.shown)
    menu.setActionsEnabled(!isBusy)
    menu.setProgress(activity?.snapshot)
    menu.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(menu)
    NSLayoutConstraint.activate([
      menu.topAnchor.constraint(equalTo: view.topAnchor),
      menu.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      menu.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      menu.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
    ])
    startScreen = menu
    viewport.isPaused = true
    viewport.isHidden = true
    updateWindowTitle()
  }
  // A loaded document (applyProject) removes the main menu and resumes the viewport. Unless the last session was
  // restored, its autosave becomes the recovery copy (Autosave-previous.vtrace) before this session's first autosave
  // can replace it.
  func dismissStartScreen() {
    guard let menu = startScreen else { return }
    menu.removeFromSuperview()
    startScreen = nil
    if !restoringSession { retireLastSessionAutosave() }
    viewport.isHidden = false
    viewport.isPaused = false
    renderer.lastTick = awakeSeconds()
    updateWindowTitle()
  }
  // Shows the Scenes window, or brings it to the front, whether or not a document is loaded. The viewport keeps
  // rendering and the document is untouched; opening a document hides the window again (associate, restoreAutosave).
  func browseScenes() {
    guard !isBusy else { return }
    scenes.show()
  }
  private func retireLastSessionAutosave() {
    let current = autosaveURL, previous = previousAutosaveURL
    guard !autosaveSuppressed else { return }
    autosaveQueue.async {
      let files = FileManager.default
      guard files.fileExists(atPath: current.path) else { return }
      try? files.removeItem(at: previous)
      try? files.moveItem(at: current, to: previous)
    }
  }
  nonisolated static func autosaveDate(at url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
  }
  // A recent project from the main menu or File › Open Recent: opened like Open Project, or, when the file is gone,
  // removed from the list with a message in the status line.
  func openRecent(_ url: URL) {
    guard !isBusy else { return }
    recent.open(url, with: { [weak self] in self?.performStartAction(.openProject($0)) }, report: { [weak self] in self?.show($0) })
  }
  private func recentProjectsChanged() {
    if let menu = openRecentMenu {
      recent.fill(menu, target: self, open: #selector(openRecentAction(_:)), clear: #selector(clearRecentAction))
    }
    startScreen?.setRecent(recent.shown)
  }
  func performStartAction(_ action: StartAction) {
    guard !isBusy else { return }
    switch action {
    case .newProject: newProject()
    case .openProject(let url?): confirmDiscardingChanges { [weak self] in self?.beginOpenProject(url) }
    case .openScene(let url?): beginOpenSceneFile(url)
    case .scene(let id): if let entry = SceneCatalog.entry(id) { openScene(entry) }
    case .restoreSession:
      restoringSession = true
      restoreAutosave()
      if !openInFlight { restoringSession = false }
    case .openProject(nil), .openScene(nil):
      guard let window = sheetWindow else { return }
      SceneBrowserView.chooseFile(for: action, window: window) { [weak self] chosen in self?.performStartAction(chosen) }
    }
  }
  // A new untitled project of built-in scene `index`, with that scene's default camera.
  func startBuiltInScene(_ index: Int) {
    var p = ProjectDocument()
    p.scene = UInt32(index)
    let oldCamera = CameraState(renderer), oldScene = renderer.sceneIndex
    renderer.sceneIndex = UInt32(index)
    p.camera = CameraState(renderer)
    renderer.sceneIndex = oldScene
    oldCamera.apply(renderer)
    replaceDocument(p, activity: "Loading \(Self.sceneNames[index])…") { [weak self] error in
      guard let self else { return }
      if let error {
        self.showError(error.localizedDescription)
        return
      }
      self.history.removeAllActions()
      self.associate(nil, edited: false, replaced: true)
      self.rebuild()
    }
  }
}
