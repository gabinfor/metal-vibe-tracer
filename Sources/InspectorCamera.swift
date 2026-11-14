import Cocoa

// The Camera inspector page: lens, position and target, and saved views.
extension StudioController {
  // Mouse navigation refreshes the Camera page fields at most four times a second.
  func scheduleCameraPanelRefresh() {
    guard page == 1, sidebarVisible, !cameraRefreshPending else { return }
    cameraRefreshPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self else { return }
      self.cameraRefreshPending = false
      if self.page == 1, !self.isBusy { self.rebuild() }
    }
  }
  func cameraPanel() {
    heading("Camera")
    text(
      "Drag to orbit. Shift-drag to pan. Scroll to zoom. Click a surface to select its material/object group."
    )
    number("Field of view, degrees", renderer.fov, 5...150, 38) { [weak self] in
      self?.renderer.fov = $0
    }
    let eye = renderer.eyePosition
    // Typed coordinates reach the full navigation range; the sliders cover ±100.
    let reach: ClosedRange<Float> = -1_000_000...1_000_000
    for axis in 0..<3 {
      number("Position \(["X","Y","Z"][axis])", eye[axis], -100...100, eye[axis], entry: reach) {
        [weak self] v in
        guard let self else { return }
        var p = self.renderer.eyePosition
        p[axis] = v
        self.renderer.setEye(p)
      }
      number("Target \(["X","Y","Z"][axis])", renderer.target[axis], -100...100, 0, entry: reach) {
        [weak self] v in self?.renderer.target[axis] = v
      }
    }
    heading("Depth of field")
    option("Aperture radius (0 = pinhole)", \.aperture, 0...0.5, 0)
    option("Focus distance", \.focusDistance, 0.01...1000, 4.6, entry: 0.0001...1_000_000)
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
      popup(["Restore view…"] + names, 0, label: "Saved views") { [weak self] i in
        guard let self, i > 0, let camera = self.project.views[names[i - 1]] else { return }
        self.checkpoint("Restore view")
        camera.apply(self.renderer)
        self.changed()
        self.rebuild()
      }
    }
  }
  func saveView() {
    guard acceptsEdits, let window = hostWindow else { return }
    let alert = NSAlert()
    alert.messageText = "Name this camera view"
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    input.stringValue = "View \(project.views.count+1)"
    alert.accessoryView = input
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, !self.isBusy, response == .alertFirstButtonReturn else { return }
      let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return }
      self.checkpoint("Save view")
      self.project.views[name] = CameraState(self.renderer)
      self.changed(reset: false)
      self.rebuild()
    }
  }
}
