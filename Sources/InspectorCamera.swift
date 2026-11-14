import Cocoa
import simd

// The Camera inspector page: lens, position and target, saved views, and the display image settings.
extension StudioController {
  // Mouse navigation refreshes the Camera page fields at most four times a second. While one of the inspector's
  // fields is being edited the refresh waits, so it never takes the focus (or the typed text) away.
  func scheduleCameraPanelRefresh() {
    guard page == 1, sidebarVisible, !cameraRefreshPending else { return }
    cameraRefreshPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self else { return }
      self.cameraRefreshPending = false
      guard self.page == 1, !self.isBusy else { return }
      if self.editingInspectorField {
        self.scheduleCameraPanelRefresh()
      } else {
        self.rebuild()
      }
    }
  }
  // Whether a text field in the inspector has keyboard focus.
  var editingInspectorField: Bool {
    guard let editor = stack.window?.firstResponder as? NSTextView, editor.isFieldEditor,
      let field = editor.delegate as? NSTextField
    else { return false }
    return field.isDescendant(of: stack)
  }
  static let toneMapTitles = ["Filmic fit", "Reinhard", "Linear / clip"]
  func cameraPanel() {
    hint("Drag to orbit, Shift-drag to pan, scroll to zoom, click to select.")
    section("Lens")
    number("Field of view, °", renderer.fov, 5...150, renderer.defaultFieldOfView, step: 1, help: "Vertical field of view.") {
      [weak self] in self?.renderer.fov = $0
    }
    option(
      "Aperture radius", \.aperture, 0...0.5, 0, step: 0.001, scale: .logarithmic, zeroText: "Pinhole",
      help: "Lens radius in scene units. Pinhole (0) keeps everything in focus; larger apertures blur more.")
    option(
      "Focus distance", \.focusDistance, 0.01...1000, 4.6, entry: 0.0001...1_000_000,
      help: "Distance from the camera to the plane in focus, in scene units. Applies when the aperture is open.")
    button("Focus at Camera Target", help: "Sets the focus distance to the distance between camera and target.") {
      [weak self] in
      guard let self, self.acceptsEdits else { return }
      self.checkpoint("Focus")
      self.renderer.options.focusDistance = self.renderer.distance
      self.changed()
      self.rebuild()
    }

    section("Position")
    // Fields show the coordinates on a grid fine enough for the view's scale (0.01 at a few units away); a field
    // edit replaces only the coordinates that changed, so the others keep their full precision.
    let step = Float(pow(10, floor(log10(Double(max(renderer.distance, 1e-4)) / 50))))
    let reach: ClosedRange<Float> = -1_000_000...1_000_000
    func grid(_ v: SIMD3<Float>) -> SIMD3<Float> {
      SIMD3((0..<3).map { NumberControl.snap(v[$0], to: step) })
    }
    func merge(_ typed: SIMD3<Float>, shown: SIMD3<Float>, into exact: SIMD3<Float>) -> SIMD3<Float> {
      var p = exact
      for i in 0..<3 where typed[i] != shown[i] { p[i] = typed[i] }
      return p
    }
    let eye = grid(renderer.eyePosition), target = grid(renderer.target)
    vector(
      "Position", eye, -100...100, eye, entry: reach, step: step,
      help: "Camera position. Moving it keeps the target, so the camera turns to keep looking at it."
    ) { [weak self] v in
      guard let self else { return }
      self.renderer.setEye(merge(v, shown: eye, into: self.renderer.eyePosition))
    }
    vector(
      "Target", target, -100...100, target, entry: reach, step: step,
      help: "The point the camera looks at and orbits around. Moving it keeps the camera's direction and distance."
    ) { [weak self] v in
      guard let self else { return }
      self.renderer.target = merge(v, shown: target, into: self.renderer.target)
    }
    button(
      "Reset View",
      help: "Returns to the scene's default view: the built-in camera of a built-in scene; for an imported scene, the "
        + "camera imported with it, or every object framed when it had none."
    ) { [weak self] in self?.resetView() }

    section("Saved views")
    let names = project.views.keys.sorted()
    let selected = selectedViewName(names)
    if let selected {
      popupRow(
        "Saved view", names, names.firstIndex(of: selected) ?? 0,
        help: "Choosing a view moves the camera there. Update, Rename… and Delete act on the chosen view."
      ) { [weak self] i in
        guard let self, let camera = self.project.views[names[i]] else { return }
        self.preferences.set(names[i], forKey: Self.savedViewKey)
        self.checkpoint("Restore view")
        camera.apply(self.renderer)
        self.changed()
        self.rebuild()
      }
    }
    button("Save Current View…") { [weak self] in self?.saveView() }
    if let selected {
      buttonRow([
        ActionButton("Update") { [weak self] in self?.updateView(selected) },
        ActionButton("Rename…") { [weak self] in self?.beginRenameView(selected) },
        ActionButton("Delete", style: .destructive) { [weak self] in self?.deleteView(selected) },
      ])
    }

    section("Image")
    option(
      "Exposure, EV", \.exposure, -16...16, 0, reset: false, step: 0.1,
      help: "Display exposure in stops. Affects the viewport and PNG export; EXR keeps linear radiance.")
    option(
      "White balance, cool → warm", \.whiteBalance, -1...1, 0, reset: false, step: 0.01,
      help: "Display white balance. Affects the viewport and PNG export; EXR keeps linear radiance.")
    popupRow(
      "Tone map", Self.toneMapTitles, renderer.options.toneMap,
      help: "The display curve. Affects the viewport and PNG export; EXR keeps linear radiance."
    ) { [weak self] i in
      guard let self else { return }
      self.checkpoint("Tone map")
      self.renderer.options.toneMap = i
      self.changed(reset: false)
    }
  }

  // MARK: Default view

  // The view Reset View returns to, as one undo step. Built-in scenes: the renderer's camera for the scene
  // (applyDefaultCamera). Imported scenes: the camera the importer made active, which it also saved as a view named
  // after the format ("USD: …", "glTF: …", "Mitsuba: camera"; the first such name when there are several); without
  // one, the renderer's default angles with every object framed (as Frame All does), keeping the focus distance.
  static let importedViewPrefixes = ["USD: ", "glTF: ", "Mitsuba: "]
  var importedViewName: String? {
    project.views.keys.sorted().first { name in Self.importedViewPrefixes.contains { name.hasPrefix($0) } }
  }
  func resetView() {
    guard acceptsEdits else { return }
    checkpoint("Reset view")
    if renderer.sceneIndex == 6, let name = importedViewName, let camera = project.views[name] {
      camera.apply(renderer)
    } else {
      renderer.applyDefaultCamera()
      if renderer.sceneIndex == 6 {
        let selection = selectedNode, focus = renderer.options.focusDistance
        selectedNode = nil
        frameMesh(recordUndo: false)
        selectedNode = selection
        renderer.options.focusDistance = focus
      }
    }
    changed()
    rebuild()
  }

  // MARK: Saved views

  // The saved view the Update, Rename… and Delete buttons act on (kept in preferences): the last one chosen, saved
  // or renamed, else the first by name.
  static let savedViewKey = "Camera.savedView"
  func selectedViewName(_ names: [String]) -> String? {
    if let name = preferences.string(forKey: Self.savedViewKey), names.contains(name) { return name }
    return names.first
  }
  func saveView() {
    guard acceptsEdits, let window = hostWindow else { return }
    askViewName("Name this camera view", button: "Save", initial: "View \(project.views.count + 1)", window: window) {
      [weak self] name in self?.storeView(name)
    }
  }
  // Saves the current camera as `name` (replacing a view of that name) and chooses it.
  func storeView(_ name: String) {
    guard acceptsEdits, !name.isEmpty else { return }
    checkpoint("Save view")
    project.views[name] = CameraState(renderer)
    preferences.set(name, forKey: Self.savedViewKey)
    changed(reset: false)
    rebuild()
  }
  func updateView(_ name: String) {
    guard acceptsEdits, project.views[name] != nil else { return }
    checkpoint("Update view")
    project.views[name] = CameraState(renderer)
    changed(reset: false)
    rebuild()
  }
  func beginRenameView(_ name: String) {
    guard acceptsEdits, let window = hostWindow else { return }
    askViewName("Rename “\(name)”", button: "Rename", initial: name, window: window) { [weak self] newName in
      self?.renameView(name, to: newName)
    }
  }
  // Renames a view; a name another view already has is refused with a message. Returns whether it renamed.
  @discardableResult func renameView(_ name: String, to newName: String) -> Bool {
    guard acceptsEdits, let camera = project.views[name], !newName.isEmpty, newName != name else { return false }
    guard project.views[newName] == nil else {
      show("A view named “\(newName)” already exists.")
      return false
    }
    checkpoint("Rename view")
    project.views[name] = nil
    project.views[newName] = camera
    preferences.set(newName, forKey: Self.savedViewKey)
    changed(reset: false)
    rebuild()
    return true
  }
  func deleteView(_ name: String) {
    guard acceptsEdits, project.views[name] != nil else { return }
    checkpoint("Delete view")
    project.views[name] = nil
    changed(reset: false)
    rebuild()
  }
  // A sheet asking for a view name; `done` receives the trimmed, non-empty name.
  private func askViewName(
    _ message: String, button: String, initial: String, window: NSWindow, _ done: @escaping (String) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    input.stringValue = initial
    alert.accessoryView = input
    alert.window.initialFirstResponder = input
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, !self.isBusy, response == .alertFirstButtonReturn else { return }
      let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { done(name) }
    }
  }
}
