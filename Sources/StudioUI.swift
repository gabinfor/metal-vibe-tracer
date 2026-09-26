import Cocoa
import CoreImage
import MetalKit
import UniformTypeIdentifiers
import simd

final class ActionButton: NSButton {
  var actionBlock: (() -> Void)?
  convenience init(_ title: String, _ action: @escaping () -> Void) {
    self.init(frame: .zero)
    self.title = title
    bezelStyle = .rounded
    target = self
    self.action = #selector(invoke)
    actionBlock = action
  }
  @objc func invoke() { actionBlock?() }
}
final class ActionPopup: NSPopUpButton {
  var actionBlock: ((Int) -> Void)?
  convenience init(_ titles: [String], selected: Int, _ action: @escaping (Int) -> Void) {
    self.init(frame: .zero, pullsDown: false)
    addItems(withTitles: titles)
    selectItem(at: selected)
    target = self
    self.action = #selector(invoke)
    actionBlock = action
  }
  @objc func invoke() { actionBlock?(indexOfSelectedItem) }
}
final class NumberControl: NSStackView {
  let field = NSTextField(), slider = NSSlider()
  var update: ((Float) -> Void)!
  var minimum: Float = 0, maximum: Float = 1
  init(
    _ title: String, value: Float, range: ClosedRange<Float>, defaultValue: Float,
    _ action: @escaping (Float) -> Void
  ) {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 3
    minimum = range.lowerBound
    maximum = range.upperBound
    update = action
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 6
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 12)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.stringValue = String(format: "%.8g", value)
    field.alignment = .right
    field.widthAnchor.constraint(equalToConstant: 78).isActive = true
    field.target = self
    field.action = #selector(typed)
    (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
    let reset = ActionButton("↺") { [weak self] in self?.set(defaultValue) }
    reset.toolTip = "Reset \(title)"
    reset.setAccessibilityLabel("Reset \(title)")
    row.addArrangedSubview(label)
    row.addArrangedSubview(field)
    row.addArrangedSubview(reset)
    slider.minValue = Double(minimum)
    slider.maxValue = Double(maximum)
    slider.floatValue = value
    slider.isContinuous = false
    slider.target = self
    slider.action = #selector(slid)
    field.setAccessibilityLabel(title)
    slider.setAccessibilityLabel(title)
    addArrangedSubview(row)
    addArrangedSubview(slider)
    row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    slider.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
  }
  required init?(coder: NSCoder) { fatalError() }
  func set(_ value: Float) {
    guard value.isFinite else {
      NSSound.beep()
      return
    }
    let v = min(maximum, max(minimum, value))
    field.stringValue = String(format: "%.8g", v)
    slider.floatValue = v
    update(v)
  }
  @objc func typed() {
    guard let value = Float(field.stringValue), value.isFinite else {
      field.stringValue = String(format: "%.8g", slider.floatValue)
      NSSound.beep()
      return
    }
    set(value)
  }
  @objc func slid() { set(slider.floatValue) }
}
final class ActionColor: NSColorWell {
  var update: ((NSColor) -> Void)?
  convenience init(_ color: NSColor, _ action: @escaping (NSColor) -> Void) {
    self.init(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
    self.color = color
    update = action
    target = self
    self.action = #selector(changed)
  }
  @objc func changed() { update?(color) }
}
final class TopAlignedStackView: NSStackView {
  override var isFlipped: Bool { true }
}

final class StudioController: NSViewController {
  let renderer: PathTracerRenderer
  weak var hostWindow: NSWindow?
  let viewport: InteractiveMTKView
  let sidebar = NSScrollView(), stack = TopAlignedStackView(), status = NSTextField(labelWithString: "")
  let history = UndoManager()
  var project = ProjectDocument()
  var projectURL: URL?
  var importInProgress = false { didSet { busyStateChanged() } }
  // Opens (including the launch restore), saves and off-main document preparation.
  private var openInFlight = false { didSet { busyStateChanged() } }
  private var saveInFlight = false { didSet { busyStateChanged() } }
  private var preparationInFlight: UInt64? { didSet { busyStateChanged() } }
  var projectOperationInProgress: Bool { openInFlight || saveInFlight || preparationInFlight != nil }
  var isBusy: Bool {
    exportRenderer != nil || previewDenoiseJob != nil || importInProgress || projectOperationInProgress
  }
  var pauseButton: NSButton?
  private var busyButtons: [NSButton] = []
  private var projectActivity = ""
  private let autosaveQueue = DispatchQueue(label: "VibeTracer.autosave", qos: .utility)
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
  private var autosaveSuppressed = false
  private let autosaveLock = NSLock()
  private var queuedAutosave: PendingAutosave?  // guarded by autosaveLock
  private var writtenAutosave: (revision: UInt64, url: URL)?  // guarded by autosaveLock
  var selectedSlot = 1, page = 0, sidebarVisible = true
  var selectedNode: UUID?
  var selectedSubset = 0
  var materialXReport = ""
  var sidebarWidth: NSLayoutConstraint!
  var saveTimer: Timer?
  var lastCheckpoint = Date.distantPast
  var isRestoring = false
  var exportRenderer: PathTracerRenderer?
  var exportOutput: MTLTexture?
  var exportURL: URL?
  var exportHDR = false, exportRaw = false, exportDenoise = true, previousPaused = false
  var exportDenoiseJob: OIDNProgress?
  var previewDenoiseJob: OIDNProgress?
  var oidnPreviewWasPaused = false
  var messageUntil = Date.distantPast
  static let sceneNames = [
    "Architectural Pavilion", "Cornell Box", "Veach MIS Benchmark", "Cornell Glass & Mirror",
    "Cornell Fog Study", "Reflective Ring Study", "Imported Mesh Studio",
  ]
  static let strategyNames = [
    "ReSTIR Direct + First-Bounce GI", "Standard MIS", "Light Only (NEE)", "BSDF Only",
  ]
  static let viewportNames = ["Beauty", "Albedo", "World Normals", "Depth (log)", "Material / Roughness"]
  override var undoManager: UndoManager? { history }

  init(renderer: PathTracerRenderer, window: NSWindow) {
    self.renderer = renderer
    hostWindow = window
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
    viewport.onUserOrbit = { [weak self] in self?.changed(reset: false, autosaveDelay: 5) }
    viewport.canEdit = { [weak self] in self?.isBusy == false }
    viewport.onPick = { [weak self] p in self?.pick(p) }
    renderer.onFrameUpdate = { [weak self] _ in self?.updateStatus() }
    renderer.onError = { [weak self] text in self?.show(text) }
    installMenus()
    rebuild()
  }
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
    let export = ActionButton("Export…") { [weak self] in
      self?.page = 5
      self?.rebuild()
    }
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
    for v in [bar, viewport, sidebar, status] {
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
      status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
      status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
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
  }
  func add(_ v: NSView) {
    stack.addArrangedSubview(v)
    v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
  }
  func text(_ value: String) {
    let label = NSTextField(wrappingLabelWithString: value)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    add(label)
  }
  func heading(_ value: String) {
    let l = NSTextField(labelWithString: value)
    l.font = .systemFont(ofSize: 14, weight: .semibold)
    add(l)
  }
  func number(
    _ title: String, _ value: Float, _ range: ClosedRange<Float>, _ fallback: Float,
    reset: Bool = true, _ set: @escaping (Float) -> Void
  ) {
    add(
      NumberControl(title, value: value, range: range, defaultValue: fallback) { [weak self] v in
        guard let self, !self.isBusy else { return }
        self.checkpoint(title)
        set(v)
        self.changed(reset: reset)
      })
  }
  func option(
    _ title: String, _ key: WritableKeyPath<StudioOptions, Float>, _ range: ClosedRange<Float>,
    _ fallback: Float, reset: Bool = true
  ) {
    number(title, renderer.options[keyPath: key], range, fallback, reset: reset) { [weak self] in
      self?.renderer.options[keyPath: key] = $0
    }
  }
  func popup(_ titles: [String], _ value: Int, _ action: @escaping (Int) -> Void) {
    add(
      ActionPopup(titles, selected: value) { [weak self] i in
        guard let self, !self.isBusy else { return }
        action(i)
      })
  }
  func button(_ title: String, _ action: @escaping () -> Void) { add(ActionButton(title, action)) }
  func rebuild() {
    for child in stack.arrangedSubviews {
      stack.removeArrangedSubview(child)
      child.removeFromSuperview()
    }
    if page == 6 {
      button("‹ Back to Inspector") { [weak self] in self?.page = 0; self?.rebuild() }
      heading("Settings")
    } else {
      popup(
        ["Render", "Camera", "Lighting", "Materials & Textures", "Objects", "Project & Export"], page
      ) { [weak self] i in
        self?.page = i
        self?.rebuild()
      }
      popup(Self.sceneNames, Int(renderer.sceneIndex)) { [weak self] i in self?.switchScene(i) }
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
      text("Editing resumes when the project operation finishes.")
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
  func renderPanel() {
    heading("Sampling")
    popup(Self.strategyNames, Int(renderer.samplingMode)) { [weak self] i in
      guard let self else { return }
      self.checkpoint("Strategy")
      self.renderer.samplingMode = UInt32(i)
      self.changed()
      self.rebuild()
    }
    button(renderer.denoiserEnabled ? "MetalFX: On" : "MetalFX: Off") { [weak self] in
      guard let self else { return }
      self.checkpoint("MetalFX")
      self.renderer.denoiserEnabled.toggle()
      self.changed(reset: false)
      self.rebuild()
    }
    if renderer.samplingMode != 0 {
      text("MetalFX is available with ReSTIR Direct + First-Bounce GI. This strategy displays raw accumulation.")
    }
    if !renderer.supportsMetalFX { text("MetalFX is not supported by this GPU.") }
    if renderer.offlineDenoisedPreview != nil {
      button("Clear OIDN Preview") { [weak self] in self?.clearOIDNPreview() }
      text("The viewport and preview capture show the OIDN result. Clearing it restores the previous render state.")
    } else {
      button("OIDN Preview Current Frame") { [weak self] in self?.startOIDNPreview() }
      text("Freezes and denoises the current accumulated samples at the preview render resolution.")
    }
    heading("Display")
    popup(Self.viewportNames, Int(renderer.viewportMode)) { [weak self] i in
      guard let self else { return }
      self.checkpoint("Viewport mode")
      self.renderer.viewportMode = UInt32(i)
      self.changed(reset: false)
      self.rebuild()
    }
    option("Exposure, EV", \.exposure, -16...16, 0, reset: false)
    option("White balance, cool → warm", \.whiteBalance, -1...1, 0, reset: false)
    popup(
      ["Tone map: Filmic fit", "Tone map: Reinhard", "Tone map: Linear / clip"],
      Int(renderer.options.toneMap)
    ) { [weak self] i in
      guard let self else { return }
      self.checkpoint("Tone map")
      self.renderer.options.toneMap = Float(i)
      self.changed(reset: false)
    }
    option("Raw / MetalFX divider (0 = off)", \.compare, 0...1, 0, reset: false)
    text(
      "The left side shows raw accumulation. Exposure and white balance affect the display and PNG export; EXR preserves linear radiance."
    )
    text("Inspection views bypass tone mapping and denoising, and do not reset the progressive render.")
  }

  func settingsPanel() {
    heading("Render limits")
    number(
      "Sample limit (0 = unlimited)", Float(renderer.options.maxSamples), 0...16384, 0, reset: false
    ) { [weak self] in self?.renderer.options.maxSamples = UInt32($0.rounded()) }
    number(
      "Time limit, seconds (0 = unlimited)", Float(renderer.options.timeLimit), 0...3600, 0,
      reset: false
    ) { [weak self] in self?.renderer.options.timeLimit = Double($0) }
    option("Preview resolution scale", \.previewScale, 0.1...1, 0.5)
    option("Path depth (1 = direct light only)", \.depth, 1...64, 16)

    heading("Open Image Denoise")
    popup(["Quality: Fast", "Quality: Balanced", "Quality: High"], Int(renderer.oidnOptions.quality)) {
      [weak self] i in self?.setOIDN("OIDN quality") { $0.quality = UInt32(i) }
    }
    popup(["Guides: Color only", "Guides: Albedo", "Guides: Albedo + normal"], Int(renderer.oidnOptions.guides)) {
      [weak self] i in self?.setOIDN("OIDN guides") { $0.guides = UInt32(i) }
    }
    button("Treat guides as noisy: \(renderer.oidnOptions.treatGuidesAsNoisy ? "On" : "Off")") { [weak self] in
      self?.setOIDN("OIDN guide noise") { $0.treatGuidesAsNoisy.toggle() }
    }
    button("Robust HDR input scale: \(renderer.oidnOptions.robustInputScale ? "On" : "Off")") { [weak self] in
      self?.setOIDN("OIDN HDR scale") { $0.robustInputScale.toggle() }
    }
    button("Diffuse firefly suppression: \(renderer.oidnOptions.suppressDiffuseFireflies ? "On" : "Off")") { [weak self] in
      self?.setOIDN("OIDN firefly suppression") { $0.suppressDiffuseFireflies.toggle() }
    }
    text("The robust scale and diffuse firefly filter prevent isolated HDR samples from expanding into false bright patches. They affect only OIDN output; raw accumulation is preserved.")

    heading("Experimental")
    popup(["Ring boost: Off", "Ring boost: On"], Int(renderer.enableSMS)) { [weak self] i in
      guard let self else { return }
      self.checkpoint("Ring boost")
      self.renderer.enableSMS = UInt32(i)
      self.changed()
    }
    text("Ring boost is an artistic approximation for the original ring position.")
  }

  func setOIDN(_ name: String, _ update: (inout OIDNOptions) -> Void) {
    guard !isBusy else { return }
    checkpoint(name)
    update(&renderer.oidnOptions)
    if renderer.offlineDenoisedPreview != nil {
      renderer.offlineDenoisedPreview = nil
      renderer.paused = oidnPreviewWasPaused
    }
    renderer.presentationNeedsRefresh = true
    changed(reset: false)
    rebuild()
  }
  func cameraPanel() {
    heading("Camera")
    text(
      "Drag to orbit. Shift-drag to pan. Scroll to zoom. Click a surface to select its material/object group."
    )
    popup(["Choose preset…", "Perspective", "Front", "Close-up", "Overhead"], 0) { [weak self] i in
      guard let self, i > 0, let p = CameraPreset(rawValue: i - 1) else { return }
      self.checkpoint("Camera preset")
      self.renderer.applyPreset(p)
      self.changed()
      self.rebuild()
    }
    number("Field of view, degrees", renderer.fov, 5...150, 38) { [weak self] in
      self?.renderer.fov = $0
    }
    let eye = renderer.eyePosition
    for axis in 0..<3 {
      number("Position \(["X","Y","Z"][axis])", eye[axis], -100...100, eye[axis]) { [weak self] v in
        guard let self else { return }
        var p = self.renderer.eyePosition
        p[axis] = v
        self.renderer.setEye(p)
      }
      number("Target \(["X","Y","Z"][axis])", renderer.target[axis], -100...100, 0) {
        [weak self] v in self?.renderer.target[axis] = v
      }
    }
    heading("Depth of field")
    option("Aperture radius (0 = pinhole)", \.aperture, 0...0.5, 0)
    option("Focus distance", \.focusDistance, 0.01...1000, 4.6)
    button("Focus at camera target") { [weak self] in
      guard let self else { return }
      self.checkpoint("Focus")
      self.renderer.options.focusDistance = self.renderer.distance
      self.changed()
      self.rebuild()
    }
    heading("Saved views")
    button("Save current view…") { [weak self] in self?.saveView() }
    let names = project.views.keys.sorted()
    if !names.isEmpty {
      popup(["Restore view…"] + names, 0) { [weak self] i in
        guard let self, i > 0, let camera = self.project.views[names[i - 1]] else { return }
        self.checkpoint("Restore view")
        camera.apply(self.renderer)
        self.changed()
        self.rebuild()
      }
    }
  }
  func lightingPanel() {
    heading("Environment")
    popup(["Golden Hour", "High Noon", "Twilight / Studio"], Int(renderer.skyMode)) {
      [weak self] i in
      guard let self else { return }
      self.checkpoint("Sky preset")
      self.renderer.skyMode = UInt32(i)
      let p: [SIMD3<Float>] = [SIMD3(133, 27, 850), SIMD3(131, 62, 1100), SIMD3(128, 19, 550)]
      self.renderer.options.sunAzimuth = p[i].x
      self.renderer.options.sunElevation = p[i].y
      self.renderer.options.sunIntensity = p[i].z
      self.renderer.options.sunAngle = nil
      self.changed()
      self.rebuild()
    }
    text(project.environmentName)
    button("Load HDRI / environment image…") { [weak self] in self?.loadEnvironment() }
    button("Use procedural sky") { [weak self] in
      guard let self, !self.isBusy else { return }
      let record = self.undoRecord("Clear environment")
      do {
        try self.renderer.materials.setEnvironment(nil)
        self.project.environmentData = nil
        self.project.environmentName = "Procedural sky"
        self.commit(record)
        self.changed()
        self.rebuild()
      } catch { self.show(error.localizedDescription) }
    }
    option("Environment brightness", \.environmentIntensity, 0...100, 1)
    option("Environment rotation, degrees", \.environmentRotation, -180...180, 0)
    option("Sun azimuth, degrees", \.sunAzimuth, -180...180, 133)
    option("Sun elevation, degrees", \.sunElevation, -89...89, 27)
    option("Sun intensity", \.sunIntensity, 0...10000, 850)
    text(
      "Sky/HDRI lighting is used in the Pavilion and Imported Mesh Studio. Sun controls apply to the procedural sky."
    )
    if let angle = renderer.options.sunAngle {
      text(String(format: "Imported distant light: %.2f° sun, intensity is irradiance, independent of the environment. A sky preset restores the procedural sun.", angle))
    }
    heading("Scene lights")
    option("Light intensity", \.lightIntensity, 0...100, 1)
    option("Light size multiplier", \.lightSize, 0.05...4, 1)
    // Light color is linear, like material tint; the well shows sRGB.
    func encode(_ c: Float) -> CGFloat {
      CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }
    func decode(_ c: CGFloat) -> Float {
      let x = Float(c)
      return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    let c = renderer.options.lightColor
    add(
      ActionColor(NSColor(srgbRed: encode(c.x), green: encode(c.y), blue: encode(c.z), alpha: 1))
      { [weak self] c in
        guard let self, !self.isBusy, let c = c.usingColorSpace(.sRGB) else { return }
        self.checkpoint("Light color")
        self.renderer.options.lightColor = SIMD3(
          decode(c.redComponent), decode(c.greenComponent), decode(c.blueComponent))
        self.changed()
      })
    text(
      "Applies to the finite lights in Cornell, Veach, and Ring scenes. Veach lights share these controls."
    )
    popup(["Atmosphere: Clear", "Atmosphere: Fog preview"], Int(renderer.enableFog)) {
      [weak self] i in
      guard let self else { return }
      self.checkpoint("Fog")
      self.renderer.enableFog = UInt32(i)
      self.changed()
    }
  }
  func objectNames() -> [String] {
    switch renderer.sceneIndex {
    case 1, 4:
      return [
        "Room surfaces", "Unused floor slot", "Tall box", "Unused ring slot", "Unused chrome slot",
        "Unused glass slot", "Short box", "Imported mesh (Studio only)",
      ]
    case 2:
      return [
        "Unassigned", "Floor", "Plate 1", "Plate 2", "Plate 3", "Plate 4", "Unused plinth slot",
        "Imported mesh (Studio only)",
      ]
    case 3:
      return [
        "Room surfaces", "Unused floor slot", "Unused copper slot", "Unused ring slot",
        "Mirror sphere", "Glass sphere", "Unused plinth slot", "Imported mesh (Studio only)",
      ]
    case 5:
      return [
        "Back wall", "Floor", "Unused copper slot", "Gold ring", "Chrome sphere",
        "Unused glass slot", "Unused plinth slot", "Imported mesh (Studio only)",
      ]
    case 6:
      return [
        "Unassigned", "Floor", "Unused copper slot", "Unused ring slot", "Unused chrome slot",
        "Unused glass slot", "Unused plinth slot", "Imported mesh",
      ]
    default: return ["Architecture"] + Array(MaterialLibrary.names.dropFirst())
    }
  }
  func selectObject() {
    if renderer.sceneIndex == 6, project.graph != nil {
      selectGraphNode()
      return
    }
    let names = objectNames()
    let slots = names.indices.filter {
      !names[$0].hasPrefix("Unused") && names[$0] != "Unassigned"
        && !names[$0].contains("Studio only")
    }
    if !slots.contains(selectedSlot) { selectedSlot = slots.first ?? 0 }
    popup(slots.map { names[$0] }, slots.firstIndex(of: selectedSlot) ?? 0) { [weak self] i in
      self?.selectedSlot = slots[i]
      self?.rebuild()
    }
  }
  func materialPanel() {
    heading("Material")
    selectObject()
    if renderer.sceneIndex == 6, project.graph != nil, selectedNode != nil { graphBindings() }
    let slot = selectedSlot
    button("Import MaterialX…") { [weak self] in self?.importMaterialX() }
    if !materialXReport.isEmpty {
      button("Last MaterialX import report…") { [weak self] in self?.showMaterialXReport() }
    }
    if let program = renderer.materials.materialX[slot] {
      materialXPanel(program, slot: slot)
      return
    }
    if let emission = renderer.materials.emissions[slot] {
      heading("USD area emitter")
      for i in 0..<3 {
        number("Radiance \(["R","G","B"][i])", emission[i], 0...max(1000, emission[i]), emission[i])
        { [weak self] v in self?.renderer.materials.emissions[slot]?[i] = v }
      }
      text(
        "One-sided rectangular light. Move and rotate it in Objects. Values are linear radiance.")
      return
    }
    let material = renderer.materials.settings[slot]
    popup(
      [
        "Original scene material", "Plastic", "Copper", "Coated metal", "Fabric", "Rough glass",
        "Custom OpenPBR",
      ], material.enabled == 0 ? 0 : 6
    ) { [weak self] i in self?.materialPreset(i) }
    func encode(_ c: Float) -> CGFloat {
      CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }
    add(
      ActionColor(
        NSColor(
          srgbRed: encode(material.color.x), green: encode(material.color.y),
          blue: encode(material.color.z), alpha: 1)
      ) { [weak self] color in
        guard let self, !self.isBusy, let c = color.usingColorSpace(.sRGB) else { return }
        self.checkpoint("Material tint")
        func decode(_ c: CGFloat) -> Float {
          let x = Float(c)
          return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        self.renderer.materials.settings[slot].color = SIMD4(
          decode(c.redComponent), decode(c.greenComponent), decode(c.blueComponent), 1)
        self.renderer.materials.settings[slot].enabled = 1
        self.changed()
      })
    for (i, name) in ["Roughness", "Metalness", "Coat", "Anisotropy"].enumerated() {
      number(name, material.surface[i], i == 0 ? 0.03...1 : 0...1, i == 0 ? 0.3 : 0) {
        [weak self] v in
        self?.renderer.materials.settings[slot].surface[i] = v
        self?.renderer.materials.settings[slot].enabled = 1
      }
    }
    for (i, name) in ["Fuzz", "IOR", "Transmission", "UV repeat"].enumerated() {
      let range: ClosedRange<Float> = i == 1 ? 1.01...2.5 : i == 3 ? 0.01...100 : 0...1
      number(name, material.detail[i], range, i == 1 ? 1.5 : i == 3 ? 1 : 0) { [weak self] v in
        self?.renderer.materials.settings[slot].detail[i] = v
        if i != 3 { self?.renderer.materials.settings[slot].enabled = 1 }
      }
    }
    number("Normal strength", material.normalStrength, 0...4, 1) { [weak self] in
      self?.renderer.materials.settings[slot].normalStrength = $0
    }
    for (i, name) in ["UV offset U", "UV offset V", "UV rotation, degrees"].enumerated() {
      let value = renderer.materials.objects[slot].uvTransform[i] * (i == 2 ? 180 / .pi : 1)
      number(name, value, i == 2 ? -180...180 : -10...10, 0) { [weak self] v in
        self?.renderer.materials.objects[slot].uvTransform[i] = v * (i == 2 ? .pi / 180 : 1)
      }
    }
    heading("Textures")
    for channel in 0..<4 {
      text(
        MaterialLibrary.mapNames[channel] + "\n" + renderer.materials.fileNames[slot * 4 + channel])
      if let data = renderer.materials.payloads[slot * 4 + channel], let image = NSImage(data: data)
      {
        let preview = NSImageView()
        preview.image = image
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.heightAnchor.constraint(equalToConstant: 80).isActive = true
        add(preview)
      }
      button("Load \(["base color","roughness","metalness","normal map"][channel])…") {
        [weak self] in self?.loadMap(slot, channel)
      }
      button("Clear map") { [weak self] in
        guard let self, !self.isBusy else { return }
        do {
          let record = self.undoRecord("Clear texture")
          try self.renderer.materials.clear(slot: slot, channel: channel)
          self.commit(record)
          self.changed()
          self.rebuild()
        } catch { self.show(error.localizedDescription) }
      }
      if channel == 1 || channel == 2 {
        popup(
          ["Channel: Red", "Channel: Green", "Channel: Blue", "Channel: Alpha"],
          Int(renderer.materials.objects[slot].channels[channel - 1])
        ) { [weak self] i in
          guard let self else { return }
          self.checkpoint("Texture channel")
          self.renderer.materials.objects[slot].channels[channel - 1] = UInt32(i)
          self.changed()
        }
      }
    }
    text(
      "Base color multiplies tint. Roughness and metalness maps replace their sliders. Normal maps use +Y. Clear maps to restore scalar values."
    )
    button("Save material preset…") { [weak self] in self?.saveMaterial() }
    button("Load material preset…") { [weak self] in self?.loadMaterial() }
    button("Reset material and maps") { [weak self] in
      guard let self, !self.isBusy else { return }
      let record = self.undoRecord("Reset material")
      // Publish settings and all four maps in one transactional restore.
      var state = self.renderer.materials.state()
      state.surfaces[slot] = SurfaceSettings()
      for c in 0..<4 {
        state.maps[slot * 4 + c] = nil
        state.names[slot * 4 + c] = "None"
      }
      do {
        try self.renderer.materials.restore(state)
        self.commit(record)
        self.changed()
        self.rebuild()
      } catch { self.show(error.localizedDescription) }
    }
  }
  func objectPanel() {
    if renderer.sceneIndex == 6, project.graph != nil {
      graphObjectPanel()
      return
    }
    heading("Object / surface group")
    selectObject()
    legacyObjectControls()
    heading("Mesh import")
    text(project.meshName)
    button("Open USD scene…") { [weak self] in self?.importUSD() }
    button("Import OBJ…") { [weak self] in self?.importMesh() }
    button("Frame imported mesh") { [weak self] in self?.frameMesh() }
    text(
      "OBJ positions, UVs and normals are supported. Object/group hierarchy and named material subsets are preserved. Imports append to the scene. Triangulate concave polygons before import; MTL shading is not imported."
    )
  }
  func legacyObjectControls() {
    let slot = selectedSlot
    let o = renderer.materials.objects[slot]
    button(o.rotationHidden.w > 0 ? "Hidden — click to show" : "Visible — click to hide") {
      [weak self] in
      guard let self else { return }
      self.checkpoint("Visibility")
      self.renderer.materials.objects[slot].rotationHidden.w = o.rotationHidden.w > 0 ? 0 : 1
      self.changed()
      self.rebuild()
    }
    for i in 0..<3 {
      number("Translation \(["X","Y","Z"][i])", o.positionScale[i], -100...100, 0) { [weak self] in
        self?.renderer.materials.objects[slot].positionScale[i] = $0
      }
      number(
        "Rotation \(["X","Y","Z"][i]), degrees", o.rotationHidden[i] * 180 / .pi, -180...180, 0
      ) { [weak self] in self?.renderer.materials.objects[slot].rotationHidden[i] = $0 * .pi / 180 }
    }
    number("Uniform scale", o.positionScale.w, 0.01...100, 1) { [weak self] in
      self?.renderer.materials.objects[slot].positionScale.w = $0
    }
    button("Reset transform") { [weak self] in
      guard let self else { return }
      self.checkpoint("Reset transform")
      self.renderer.materials.objects[slot].positionScale = SIMD4(0, 0, 0, 1)
      self.renderer.materials.objects[slot].rotationHidden = .zero
      self.changed()
      self.rebuild()
    }
    text(
      "Transforms use the scene origin as pivot. Architecture and room surfaces are grouped. Emitters use the Lighting controls."
    )
  }
  func filePanel() {
    heading("Project")
    text(projectURL?.lastPathComponent ?? "Untitled project")
    button("New project") { [weak self] in
      self?.confirmDiscardingChanges { self?.newProject() }
    }
    button("Open project…") { [weak self] in self?.openProject() }
    button("Save project") { [weak self] in self?.saveProject() }
    button("Save project as…") { [weak self] in self?.saveProject(asNew: true) }
    text(
      "Projects embed textures, the environment image, and imported geometry. Changes are also autosaved locally and restored at next launch."
    )
    heading("Export")
    number("Output width", Float(renderer.options.outputWidth), 16...8192, 1920, reset: false) {
      [weak self] in self?.renderer.options.outputWidth = Int($0.rounded())
    }
    number("Output height", Float(renderer.options.outputHeight), 16...8192, 1080, reset: false) {
      [weak self] in self?.renderer.options.outputHeight = Int($0.rounded())
    }
    number("Export samples", Float(renderer.options.exportSamples), 1...16384, 128, reset: false) {
      [weak self] in self?.renderer.options.exportSamples = UInt32($0.rounded())
    }
    let exportSource = exportDenoise ? 0 : (exportRaw ? 1 : 2)
    popup([
      "Export source: OIDN offline (configured)",
      "Export source: raw accumulation",
      "Export source: MetalFX display",
    ], exportSource) { [weak self] i in
      self?.exportDenoise = i == 0
      self?.exportRaw = i == 1
    }
    button("Render and export PNG…") { [weak self] in self?.beginExport(hdr: false) }
    button("Render and export HDR OpenEXR…") { [weak self] in self?.beginExport(hdr: true) }
    button("Capture current preview PNG…") { [weak self] in self?.capturePreview() }
    text(
      "OIDN filters the converged linear render with albedo and normal guides. EXR stores linear floating-point radiance. PNG uses the current exposure, white balance and tone map."
    )
  }
  func show(_ message: String) {
    status.stringValue = message
    status.toolTip = message
    messageUntil = Date().addingTimeInterval(5)
  }
  func updateStatus() {
    pauseButton?.title = renderer.paused ? "Resume" : "Pause"
    busyStateChanged()
    guard Date() >= messageUntil, exportRenderer == nil else { return }
    let r = renderer
    let state = r.paused ? "Paused" : r.reachedLimit ? "Complete" : "Rendering"
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
    renderer.lastTick = Date()
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
    p.ring = renderer.enableSMS
    p.denoise = renderer.denoiserEnabled
    p.oidn = renderer.oidnOptions
    p.viewportMode = renderer.viewportMode
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
    if coalesce && Date().timeIntervalSince(lastCheckpoint) < 0.5 { return }
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
        self.show(error.localizedDescription)
        return
      }
      // Undoing Open/New/USD open returns the previous file association too.
      if let association = record.association {
        self.associate(association.url, edited: true, replaced: true)
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
    saveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      self?.autosave()
    }
  }
  // Records the file association after open/save/new and refreshes the recovery metadata.
  func associate(_ url: URL?, edited: Bool, replaced: Bool) {
    projectURL = url
    if replaced { documentIdentity &+= 1 }
    documentEdited = edited
    documentRevision &+= 1
    scheduleAutosave()
  }
  private func busyStateChanged() {
    let enabled = !isBusy
    for button in busyButtons { button.isEnabled = enabled }
    pauseButton?.isEnabled = enabled
  }
  func beginProjectActivity(_ activity: String) {
    projectActivity = activity
    show(activity)
    rebuild()
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
  func prepareResources(
    _ p: ProjectDocument, reuse: ReusableResources? = nil, resident: MaterialLibrary.ResidentTextures? = nil
  ) throws -> MaterialLibrary {
    try p.validate()
    let resources = try MaterialLibrary(
      device: renderer.device, function: renderer.materialFunction)
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
      try resources.setMesh(p.graph?.renderTriangles() ?? p.triangles)
    }
    resources.hasSceneGraph = p.graph != nil
    return resources
  }
  // Only radiance-affecting differences restart accumulation. Display-only state
  // (exposure, white balance, tone map, divider, MetalFX, viewport mode, limits,
  // export settings, saved views) keeps the accumulated samples and OIDN preview.
  func applyProject(_ p: ProjectDocument, resources: MaterialLibrary?, resourcesChanged: Bool = true) {
    isRestoring = true
    defer { isRestoring = false }
    let r = renderer
    let radianceChanged =
      resourcesChanged || r.sceneIndex != p.scene || r.samplingMode != p.strategy
      || r.skyMode != p.sky || r.enableFog != p.fog || r.enableSMS != p.ring
      || !r.options.sameRadiance(as: p.options)
    let oidn = p.oidn ?? OIDNOptions()
    if oidn != r.oidnOptions, r.offlineDenoisedPreview != nil {
      r.offlineDenoisedPreview = nil
      r.paused = oidnPreviewWasPaused
    }
    if let resources {
      r.materials = resources
      resources.external = MaterialLibrary.ResidentTextures()
    }
    project = p
    r.sceneIndex = p.scene
    r.samplingMode = p.strategy
    r.skyMode = p.sky
    r.enableFog = p.fog
    r.enableSMS = p.ring
    r.denoiserEnabled = p.denoise && r.supportsMetalFX
    r.oidnOptions = oidn
    r.viewportMode = p.viewportMode ?? 0
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
        try live.setMesh(p.graph?.renderTriangles() ?? p.triangles)
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
      beginDocumentChange(activity, build: { (p, ()) }) { result in
        if case .failure(let error) = result { completion(error) } else { completion(nil) }
      }
    }
  }
  // Builds a candidate document (parsing imports) and prepares its resources on
  // projectIOQueue, then publishes it unless a newer replacement superseded it.
  func beginDocumentChange<Extra>(
    _ activity: String, build: @escaping () throws -> (ProjectDocument, Extra),
    completion: @escaping (Result<Extra, Error>) -> Void
  ) {
    prepareGeneration &+= 1
    let generation = prepareGeneration
    let reuse = renderer.materials.reusableResources(graph: project.graph)
    preparationInFlight = generation
    beginProjectActivity(activity)
    projectIOQueue.async { [weak self] in
      guard let self else { return }
      let result = Result { () -> (ProjectDocument, Extra, MaterialLibrary) in
        let (document, extra) = try build()
        return (document, extra, try self.prepareResources(document, reuse: reuse))
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
        self.show(error.localizedDescription)
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
        self.show(error.localizedDescription)
        return
      }
      self.backUpReplacedDocument(record)
      self.commit(record)
      self.associate(nil, edited: false, replaced: true)
      self.rebuild()
    }
  }
  // Standard Save / Don't Save / Cancel prompt before Open, New and USD open replace
  // an edited document.
  func confirmDiscardingChanges(_ proceed: @escaping () -> Void) {
    guard !isBusy else { return }
    guard documentEdited, let window = hostWindow else {
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
  private func drainAutosave() -> Error? {
    autosaveLock.lock()
    let item = queuedAutosave
    queuedAutosave = nil
    autosaveLock.unlock()
    guard let item else { return nil }
    return writeAutosave(item)
  }
  private func writeAutosave(_ document: ProjectDocument, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try document.encodeForSaving().write(to: url, options: .atomic)
  }
  // autosaveQueue only: skips a revision that is already on disk at that location.
  private func writeAutosave(_ item: PendingAutosave) -> Error? {
    autosaveLock.lock()
    let written = writtenAutosave
    autosaveLock.unlock()
    if let written, written.revision == item.revision, written.url == item.url { return nil }
    do { try writeAutosave(item.document, to: item.url) } catch { return error }
    autosaveLock.lock()
    writtenAutosave = (item.revision, item.url)
    autosaveLock.unlock()
    return nil
  }
  private func markAutosaved() {
    autosaveLock.lock()
    writtenAutosave = (documentRevision, autosaveURL)
    autosaveLock.unlock()
  }
  func autosave() {
    guard !isRestoring, !autosaveSuppressed else { return }
    let item = PendingAutosave(
      document: autosaveSnapshot(), revision: documentRevision, url: autosaveURL)
    autosaveLock.lock()
    let scheduled = queuedAutosave != nil
    queuedAutosave = item
    autosaveLock.unlock()
    // Coalesce: an already queued write picks up this newer snapshot.
    guard !scheduled else { return }
    autosaveQueue.async { [weak self] in
      guard let self, let error = self.drainAutosave() else { return }
      let message = error.localizedDescription
      DispatchQueue.main.async { self.show("Autosave failed: \(message)") }
    }
  }
  // The serial queue orders this snapshot after every pending periodic save, so an
  // older snapshot can never replace the final state during application shutdown.
  // Nothing is rewritten when the current revision is already on disk.
  func flushAutosave(to destination: URL? = nil) throws {
    guard !isRestoring, !autosaveSuppressed else { return }
    saveTimer?.invalidate()
    saveTimer = nil
    let item = PendingAutosave(
      document: autosaveSnapshot(), revision: documentRevision, url: destination ?? autosaveURL)
    var failure: Error?
    autosaveQueue.sync {
      autosaveLock.lock()
      if queuedAutosave?.url == item.url { queuedAutosave = nil }
      autosaveLock.unlock()
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
    var document = record.document
    document.recovery = AutosaveRecovery(projectPath: association.url?.path, edited: true)
    let url = previousAutosaveURL
    autosaveQueue.async { [weak self] in
      do { try self?.writeAutosave(document, to: url) } catch {
        let message = error.localizedDescription
        DispatchQueue.main.async { self?.show("Recovery copy failed: \(message)") }
      }
    }
  }
  // Moves an autosave that cannot be restored aside so no later autosave can overwrite it.
  static func preserveUnrestorableAutosave(_ url: URL) throws -> URL {
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
    beginProjectActivity("Restoring autosaved project…")
    projectIOQueue.async { [weak self] in
      guard let self else { return }
      let result = Result { () -> (ProjectDocument, MaterialLibrary) in
        let data = try self.readBounded(url, maximum: ProjectDocument.maximumFileBytes)
        let document = try JSONDecoder().decode(ProjectDocument.self, from: data)
        return (document, try self.prepareResources(document, reuse: reuse))
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
          // Recovered work keeps its file association and unsaved state.
          let path = document.recovery?.projectPath.map { URL(fileURLWithPath: $0) }
          self.projectURL = path.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
          self.documentIdentity &+= 1
          self.documentEdited = document.recovery?.edited ?? true
          self.show("Restored autosaved project")
        case .failure(let error):
          switch preserved {
          case .success(let moved)?:
            self.show("Could not restore autosave: \(error.localizedDescription) It was kept as \(moved.path).")
          case .failure(let moveError)?:
            self.autosaveSuppressed = true
            self.show(
              "Could not restore autosave: \(error.localizedDescription) Autosave is off for this session because the file could not be kept (\(moveError.localizedDescription)).")
          case nil: break
          }
        }
        // The file on disk (or its preserved copy) already holds this state.
        self.markAutosaved()
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
    guard let window = hostWindow else { return }
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
    beginProjectActivity("Opening \(url.lastPathComponent)…")
    projectIOQueue.async { [weak self] in
      guard let self else { return }
      let result = Result { () -> (ProjectDocument, MaterialLibrary) in
        let data = try self.readBounded(url, maximum: ProjectDocument.maximumFileBytes)
        let document = try JSONDecoder().decode(ProjectDocument.self, from: data)
        return (document, try self.prepareResources(document, reuse: reuse))
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
          self.show("Opened \(url.lastPathComponent)")
        case .failure(let error): self.show(error.localizedDescription)
        }
        self.rebuild()
        self.finishProjectOperation()
      }
    }
  }
  func readBounded(_ url: URL, maximum: Int) throws -> Data {
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
  func saveProject(asNew: Bool = false, completion: ((Bool) -> Void)? = nil) {
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
  func beginSaveProject(_ url: URL, completion: ((Bool) -> Void)? = nil) {
    guard !isBusy else {
      completion?(false)
      return
    }
    let document = snapshot()
    let revision = documentRevision, identity = documentIdentity
    saveGeneration &+= 1
    let generation = saveGeneration
    saveInFlight = true
    beginProjectActivity("Saving \(url.lastPathComponent)…")
    projectIOQueue.async { [weak self] in
      let result = Result {
        try document.encodeForSaving().write(to: url, options: .atomic)
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
          self.show("Saved \(url.lastPathComponent)")
          completion?(true)
        case .failure(let error):
          let message = "\(url.lastPathComponent): \(error.localizedDescription)"
          if self.pendingSaveFailure == nil { self.pendingSaveFailure = message }
          self.show(error.localizedDescription)
          completion?(false)
        }
        self.rebuild()
        self.finishProjectOperation()
      }
    }
  }
  func saveView() {
    let alert = NSAlert()
    alert.messageText = "Name this camera view"
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    input.stringValue = "View \(project.views.count+1)"
    alert.accessoryView = input
    alert.beginSheetModal(for: hostWindow!) { [weak self] response in
      guard let self, !self.isBusy, response == .alertFirstButtonReturn else { return }
      let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return }
      self.checkpoint("Save view")
      self.project.views[name] = CameraState(self.renderer)
      self.changed(reset: false)
      self.rebuild()
    }
  }
  func materialPreset(_ index: Int) {
    checkpoint("Material preset")
    var s = renderer.materials.settings[selectedSlot]
    s.enabled = index == 0 ? 0 : 1
    if index > 0 && index < 6 {
      s.color = SIMD4(0.8, 0.8, 0.8, 1)
      s.surface = SIMD4(0.3, 0, 0, 0)
      s.detail.x = 0
      s.detail.y = 1.5
      s.detail.z = 0
      if index == 2 || index == 3 {
        s.color = SIMD4(0.95, 0.64, 0.54, 1)
        s.surface = SIMD4(0.22, 1, index == 3 ? 1 : 0, 0)
      }
      if index == 4 {
        s.color = SIMD4(0.25, 0.08, 0.06, 1)
        s.surface.x = 0.65
        s.detail.x = 0.8
      }
      if index == 5 {
        s.color = SIMD4(repeating: 1)
        s.surface.x = 0.12
        s.detail.z = 1
        s.detail.y = 1.52
      }
    }
    renderer.materials.settings[selectedSlot] = s
    changed()
    rebuild()
  }
  func loadMap(_ slot: Int, _ channel: Int) {
    chooseOpen(
      "Load texture image", extensions: ["png", "jpg", "jpeg", "tif", "tiff", "heic", "exr"]
    ) { [weak self] url in self?.loadTexture(from: url, slot: slot, channel: channel) }
  }
  func loadTexture(from url: URL, slot: Int, channel: Int) {
    guard !isBusy else { return }
    let record = undoRecord("Load texture")
    do {
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      let old = renderer.materials.payloads[slot * 4 + channel]?.count ?? 0
      try requireEmbeddedCapacity(snapshot().embeddedAssetBytes - old + size)
      try renderer.materials.load(url: url, slot: slot, channel: channel)
      commit(record)
      changed()
      rebuild()
    } catch { show(error.localizedDescription) }
  }
  func saveMaterial() {
    var state = SceneState()
    let source = renderer.materials.state()
    let slot = selectedSlot
    state.materialX = [:]
    if let program = source.materialX?[slot] { state.materialX?[1] = program }
    state.surfaces[1] = source.surfaces[slot]
    state.objects[1].uvTransform = source.objects[slot].uvTransform
    state.objects[1].channels = source.objects[slot].channels
    for c in 0..<4 {
      state.maps[4 + c] = source.maps[slot * 4 + c]
      state.names[4 + c] = source.names[slot * 4 + c]
    }
    var document = ProjectDocument()
    document.scenes[0] = state
    chooseSave("Save material preset", name: "Material.vmat", ext: "vmat") { [weak self] url in
      do { try JSONEncoder().encode(document).write(to: url, options: .atomic) } catch {
        self?.show(error.localizedDescription)
      }
    }
  }
  func loadMaterial() {
    let slot = selectedSlot
    chooseOpen("Load material preset", extensions: ["vmat"]) { [weak self] url in
      self?.beginLoadMaterial(from: url, slot: slot)
    }
  }
  // Presets are decoded, merged and prepared on projectIOQueue.
  func beginLoadMaterial(from url: URL, slot: Int) {
    guard !isBusy else { return }
    let record = undoRecord("Load material")
    var document = snapshot()
    let scene = Int(renderer.sceneIndex)
    beginDocumentChange("Loading \(url.lastPathComponent)…", build: { [weak self] () -> (ProjectDocument, Void) in
      guard let self else { throw MaterialLibrary.error("Material preset load cancelled.") }
      let p = try JSONDecoder().decode(
        ProjectDocument.self, from: self.readBounded(url, maximum: ProjectDocument.maximumFileBytes))
      try p.validate()
      // Padding keeps short (legacy or hand-written) presets within bounds.
      guard let source = p.scenes[0]?.padded else {
        throw MaterialLibrary.error("Empty material preset.")
      }
      var state = (document.scenes[scene] ?? SceneState()).padded
      var graphs = state.materialX ?? [:]
      graphs[slot] = source.materialX?[1]
      state.materialX = graphs
      state.surfaces[slot] = source.surfaces[1]
      state.objects[slot].uvTransform = source.objects[1].uvTransform
      state.objects[slot].channels = source.objects[1].channels
      for c in 0..<4 {
        state.maps[slot * 4 + c] = source.maps[4 + c]
        state.names[slot * 4 + c] = source.names[4 + c]
      }
      document.scenes[scene] = state
      try self.requireEmbeddedCapacity(document.embeddedAssetBytes)
      return (document, ())
    }) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.commit(record)
        self.changed()
      case .failure(let error): self.show(error.localizedDescription)
      }
    }
  }
  func loadEnvironment() {
    chooseOpen(
      "Load equirectangular environment", extensions: ["hdr", "exr", "png", "jpg", "tif", "tiff"]
    ) { [weak self] url in self?.beginLoadEnvironment(from: url) }
  }
  // HDRI conversion and importance CDFs are built on projectIOQueue.
  func beginLoadEnvironment(from url: URL) {
    guard !isBusy else { return }
    let record = undoRecord("Environment image")
    var document = snapshot()
    beginDocumentChange("Loading \(url.lastPathComponent)…", build: { [weak self] () -> (ProjectDocument, Void) in
      guard let self else { throw MaterialLibrary.error("Environment load cancelled.") }
      document.environmentData = try self.readBounded(url, maximum: 256 * 1024 * 1024)
      document.environmentName = url.lastPathComponent
      try self.requireEmbeddedCapacity(document.embeddedAssetBytes)
      return (document, ())
    }) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.commit(record)
        self.changed()
      case .failure(let error): self.show(error.localizedDescription)
      }
    }
  }
  // Keeps edits within the aggregate embedded-asset limit that open enforces.
  func requireEmbeddedCapacity(_ total: Int) throws {
    guard total <= ProjectDocument.embeddedAssetLimit else {
      throw MaterialLibrary.error(
        "Embedded images would total \(total / 1_048_576) MiB across all scenes, above the \(ProjectDocument.embeddedAssetLimit / 1_048_576) MiB project limit. Remove or downsize other maps, MaterialX images or the environment first."
      )
    }
  }
  func importMesh() {
    chooseOpen("Import OBJ mesh", extensions: ["obj"]) { [weak self] url in
      self?.beginImportOBJ(from: url)
    }
  }
  // Reading, parsing and resource preparation run on projectIOQueue.
  func beginImportOBJ(from url: URL) {
    guard !isBusy else { return }
    let record = undoRecord("Import OBJ")
    var document = snapshot()
    beginDocumentChange("Importing \(url.lastPathComponent)…", build: { [weak self] () -> (ProjectDocument, (UUID, Int, Int)) in
      guard let self else { throw MaterialLibrary.error("OBJ import cancelled.") }
      let objData = try self.readBounded(url, maximum: 256 * 1024 * 1024)
      guard let objText = String(data: objData, encoding: .utf8) else {
        throw MaterialLibrary.error("OBJ must be UTF-8 text.")
      }
      var skipped = 0
      let root = try document.appendOBJ(objText, name: url.lastPathComponent, skipped: &skipped)
      return (document, (root, document.graph?.materials.last?.slot ?? 1, skipped))
    }) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let (root, slot, skipped)):
        self.commit(record)
        self.selectedNode = root
        self.selectedSlot = slot
        self.frameMesh(recordUndo: false)
        self.changed()
        if skipped > 0 {
          self.show("Imported \(url.lastPathComponent); skipped \(skipped) degenerate faces.")
        }
      case .failure(let error): self.show(error.localizedDescription)
      }
    }
  }
  func frameMesh(recordUndo: Bool = true) {
    if renderer.sceneIndex != 6 {
      // The switch may prepare scene resources off the main thread; frame afterwards.
      switchScene(6) { [weak self] in self?.frameMesh(recordUndo: recordUndo) }
      return
    }
    let tris = renderer.materials.meshTriangles
    guard !tris.isEmpty else { return }
    if recordUndo { checkpoint("Frame mesh") }
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var hi = -lo
    let o = renderer.materials.hasSceneGraph ? ObjectSettings() : renderer.materials.objects[7]
    let family = selectedNode.flatMap { project.graph?.descendants(of: $0) }
    for t in tris {
      if let graph = project.graph, let family, Int(t.uvc.w) > 0,
        !family.contains(graph.nodes[Int(t.uvc.w) - 1].id)
      {
        continue
      }
      for p in [t.a, t.b, t.c] {
        let v =
          rotateObject(
            SIMD3(p.x, p.y, p.z) * o.positionScale.w,
            SIMD3(o.rotationHidden.x, o.rotationHidden.y, o.rotationHidden.z))
          + SIMD3(o.positionScale.x, o.positionScale.y, o.positionScale.z)
        lo = simd_min(lo, v)
        hi = simd_max(hi, v)
      }
    }
    guard lo.x.isFinite, lo.x <= hi.x else { return }
    renderer.target = (lo + hi) * 0.5
    let aspect = Float(max(1, viewport.bounds.width) / max(1, viewport.bounds.height))
    let tangent = tan(renderer.fov * .pi / 360) * min(1, aspect)
    renderer.distance = min(1_000_000, max(0.0001, simd_length(hi - lo) / (2 * tangent) * 1.2))
    renderer.options.focusDistance = renderer.distance
    changed()
    rebuild()
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
      if slot >= 64, let graph = self.project.graph, graph.nodes.indices.contains(slot - 64) {
        let node = graph.nodes[slot - 64]
        self.selectedNode = node.id
        self.selectedSubset = 0
        self.selectedSlot =
          graph.materials.first(where: { $0.id == node.bindings.first })?.slot ?? 1
        self.page = 3
        self.rebuild()
        self.show("Selected \(node.name)")
        return
      }
      guard slot < 8 else { return }
      self.selectedNode = nil
      self.selectedSlot = slot
      self.page = 3
      self.rebuild()
      self.show("Selected \(self.objectNames()[slot])")
    }
  }
  func installMenus() {
    let main = NSMenu()
    func menu(_ title: String, _ entries: [(String, String, Selector)]) {
      let item = NSMenuItem()
      item.title = title
      let sub = NSMenu(title: title)
      item.submenu = sub
      main.addItem(item)
      for (title, key, selector) in entries {
        let e = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        e.target = self
        sub.addItem(e)
      }
    }
    menu("Metal Vibe Tracer", [("Settings…", ",", #selector(settingsAction)), ("Quit Metal Vibe Tracer", "q", #selector(quit))])
    menu(
      "File",
      [
        ("Open Project…", "o", #selector(openAction)), ("Save Project", "s", #selector(saveAction)),
        ("Save Project As…", "S", #selector(saveAsAction)),
        ("Import OBJ…", "", #selector(importOBJAction)),
        ("Open USD Scene…", "", #selector(importUSDAction)),
        ("Export…", "e", #selector(exportAction)),
      ])
    menu("Edit", [("Undo", "z", #selector(undoAction)), ("Redo", "Z", #selector(redoAction))])
    // Standard responder-chain editing shortcuts remain available in numeric fields.
    if let edit = main.items.last?.submenu {
      for (title, key, selector) in [
        ("Cut", "x", #selector(NSText.cut(_:))), ("Copy", "c", #selector(NSText.copy(_:))),
        ("Paste", "v", #selector(NSText.paste(_:))),
        ("Select All", "a", #selector(NSText.selectAll(_:))),
      ] { edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
    }
    menu(
      "Render",
      [("Pause / Resume", "p", #selector(pauseAction)), ("Restart", "r", #selector(restartAction)),
       ("Denoise Current Frame with OIDN", "", #selector(oidnAction)),
       ("Clear OIDN Preview", "", #selector(clearOIDNAction))])
    menu("View", [("Show / Hide Inspector", "i", #selector(inspectorAction)), ("Frame Selection", "f", #selector(frameSelectionAction)), ("Frame All Imported Objects", "F", #selector(frameAllAction))])
    if let viewMenu = main.items.last?.submenu {
      viewMenu.addItem(.separator())
      for (index, title) in Self.viewportNames.enumerated() {
        let item = NSMenuItem(title: title, action: #selector(viewportAction(_:)), keyEquivalent: "")
        item.tag = index
        item.target = self
        viewMenu.addItem(item)
      }
    }
    NSApp.mainMenu = main
  }
  @objc func inspectorAction() {
    sidebarVisible.toggle()
    sidebarWidth.constant = sidebarVisible ? 340 : 0
    sidebar.isHidden = !sidebarVisible
  }
  @objc func settingsAction() {
    guard !isBusy else { return }
    if !sidebarVisible { inspectorAction() }
    page = 6
    rebuild()
  }
  @objc func oidnAction() { guard !isBusy else { return }; startOIDNPreview() }
  @objc func clearOIDNAction() { guard !isBusy else { return }; clearOIDNPreview(); rebuild() }
  @objc func viewportAction(_ sender: NSMenuItem) {
    guard !isBusy else { return }
    checkpoint("Viewport")
    renderer.viewportMode = UInt32(sender.tag)
    changed(reset: false)
    rebuild()
  }
  @objc func saveAsAction() { saveProject(asNew: true) }
  @objc func importOBJAction() { importMesh() }
  @objc func importUSDAction() { importUSD() }
  @objc func frameSelectionAction() { guard !isBusy else { return }; frameMesh() }
  @objc func frameAllAction() { guard !isBusy else { return }; selectedNode = nil; frameMesh() }
  @objc func quit() { NSApp.terminate(nil) }
  @objc func openAction() { openProject() }
  @objc func saveAction() { saveProject() }
  @objc func exportAction() {
    page = 5
    rebuild()
  }
  @objc func undoAction() {
    guard !isBusy else { return }
    history.undo()
  }
  @objc func redoAction() {
    guard !isBusy else { return }
    history.redo()
  }
  @objc func pauseAction() { pause() }
  @objc func restartAction() { restart() }
}

extension StudioController: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(quit) { return true }
    if item.action == #selector(inspectorAction) { return true }
    if item.action == #selector(viewportAction(_:)) {
      item.state = Int(renderer.viewportMode) == item.tag ? .on : .off
    }
    if isBusy { return false }
    if item.action == #selector(undoAction) {
      item.title = history.undoMenuItemTitle
      return history.canUndo
    }
    if item.action == #selector(redoAction) {
      item.title = history.redoMenuItemTitle
      return history.canRedo
    }
    if item.action == #selector(frameSelectionAction) || item.action == #selector(frameAllAction) {
      return project.graph?.nodes.contains { $0.mesh != nil } == true || !project.triangles.isEmpty
    }
    return true
  }
}
