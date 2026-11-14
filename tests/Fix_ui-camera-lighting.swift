// The Camera and Lighting tabs (InspectorCamera.swift, InspectorLighting.swift).
@MainActor func fixUICameraLightingChecks() throws {
  let history = controller.history
  let wasGroupingByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer {
    controller.saveTimer?.invalidate()
    history.groupsByEvent = wasGroupingByEvent
  }
  func grouped(_ body: () throws -> Void) rethrows {
    history.beginUndoGrouping()
    defer { history.endUndoGrouping() }
    try body()
  }
  func open(scene: UInt32, _ edit: (inout ProjectDocument) -> Void = { _ in }) throws {
    controller.saveTimer?.invalidate()
    var p = ProjectDocument()
    p.scene = scene
    edit(&p)
    try controller.restore(p)
    controller.associate(nil, edited: false, replaced: true)
    controller.saveTimer?.invalidate()
    history.removeAllActions()
    controller.lastCheckpoint = .distantPast
  }
  func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
  }
  func show(page: Int) {
    controller.page = page
    controller.rebuild()
    controller.view.layoutSubtreeIfNeeded()
  }
  func texts() -> Set<String> { Set(views(NSTextField.self, in: controller.stack).map(\.stringValue)) }
  func number(_ label: String) -> NumberControl? {
    views(NumberControl.self, in: controller.stack).first { $0.field.accessibilityLabel() == label }
  }
  func vector(_ label: String) -> VectorControl? {
    views(VectorControl.self, in: controller.stack).first { $0.components[0].field.accessibilityLabel() == label + " X" }
  }
  func popup(_ label: String) -> ActionPopup? {
    views(ActionPopup.self, in: controller.stack).first { $0.accessibilityLabel() == label }
  }
  func well(_ label: String) -> ActionColor? {
    views(ActionColor.self, in: controller.stack).first { $0.accessibilityLabel() == label }
  }
  func button(_ title: String) -> ActionButton? {
    views(ActionButton.self, in: controller.stack).first { $0.title == title }
  }
  func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool {
    simd_length(a - b) <= tolerance * max(1, simd_length(b))
  }

  // Lighting shows what the scene reads: sky scenes, finite-light scenes, imported scenes.
  try open(scene: 0)
  show(page: 2)
  var shown = texts()
  require(shown.isSuperset(of: ["Environment", "Sun", "Atmosphere"]) && !shown.contains("Lights"),
    "the Pavilion shows Environment, Sun and Atmosphere, not Lights")
  require(popup("Sky preset") != nil && popup("Sun spectrum") != nil && popup("Light spectrum") == nil
    && well("Light color") == nil && number("Brightness") != nil && number("Rotation, °") == nil
    && button("Load Environment Image…") != nil && button("Remove Image") == nil,
    "the procedural sky offers a preset and brightness, no image rotation or Remove Image")
  require(number("Azimuth, °")?.step == 1 && number("Elevation, °")?.step == 1
    && number("Intensity")?.scale == .logarithmic, "sun angles step by 1°, intensity is logarithmic")
  try open(scene: 1)
  show(page: 2)
  shown = texts()
  require(shown.isSuperset(of: ["Lights", "Atmosphere"]) && !shown.contains("Environment") && !shown.contains("Sun"),
    "the Cornell Box shows Lights and Atmosphere only")
  require(well("Light color") != nil && popup("Light spectrum") != nil && popup("Sky preset") == nil
    && popup("Sun spectrum") == nil && number("Intensity") != nil && number("Size") != nil,
    "finite-light scenes show intensity, size, colour and spectrum")
  try open(scene: 6)
  show(page: 2)
  shown = texts()
  require(shown.isSuperset(of: ["Environment", "Sun", "Lights", "Atmosphere"])
    && shown.contains("Select a light to edit it on the Materials tab.")
    && popup("Light spectrum") != nil && well("Light color") == nil && number("Size") == nil,
    "imported scenes keep the light spectrum with a pointer to the Materials tab")
  print("PASS: ui-camera-lighting Lighting sections per scene (sky, finite lights, imported)")

  // Environment image: rotation and Remove Image appear; the sky preset and procedural sun do not.
  try open(scene: 0)
  controller.project.environmentData = Data([0])
  controller.project.environmentName = "studio.exr"
  show(page: 2)
  shown = texts()
  require(shown.contains("Image: studio.exr") && popup("Sky preset") == nil && number("Rotation, °") != nil
    && !shown.contains("Sun") && button("Remove Image") != nil, "an environment image replaces the sky preset and sun")
  grouped { button("Remove Image")!.invoke() }
  require(controller.project.environmentData == nil && controller.project.environmentName == "Procedural sky"
    && history.undoActionName == "Clear environment" && popup("Sky preset") != nil,
    "Remove Image returns to the procedural sky with one undo step")
  history.removeAllActions()
  print("PASS: ui-camera-lighting environment image controls and Remove Image")

  // Atmosphere: the participating medium's albedo is one colour row.
  try open(scene: 1)
  show(page: 2)
  require(popup("Atmosphere")?.itemTitles == ["Clear", "Fog preview", "Participating medium"], "atmosphere choices")
  grouped {
    popup("Atmosphere")!.selectItem(at: 2)
    popup("Atmosphere")!.invoke()
  }
  require(testRenderer.medium != nil && popup("Scattering law") != nil && number("Density, 1/m")?.scale == .logarithmic,
    "a participating medium shows its controls")
  let albedo = well("Scattering albedo")!
  require(views(NumberControl.self, in: controller.stack).allSatisfy { !$0.field.accessibilityLabel()!.hasPrefix("Scattering albedo") },
    "no per-channel albedo rows remain")
  history.removeAllActions()
  controller.lastCheckpoint = .distantPast  // A colour change within 0.5 s of the last step would coalesce with it.
  grouped {
    albedo.color = NSColor(srgbRed: 0.5, green: 0.25, blue: 1, alpha: 1)
    albedo.changed()
  }
  let a = testRenderer.medium!.albedo
  require(abs(a.x - 0.21404) < 0.001 && abs(a.y - 0.05088) < 0.001 && abs(a.z - 1) < 1e-5
    && history.undoActionName == "Scattering albedo", "the albedo row stores linear albedo with one undo step")
  history.undo()
  require(testRenderer.medium?.albedo == SIMD3(repeating: 0.9), "undo restores the albedo")
  testRenderer.medium = nil
  testRenderer.enableFog = 0
  print("PASS: ui-camera-lighting atmosphere popup and albedo colour row")

  // Camera: vector rows, Reset View, Image controls.
  try open(scene: 1)
  show(page: 1)
  require(vector("Position") != nil && vector("Target") != nil
    && !controller.stack.arrangedSubviews.contains { $0 is NumberControl && ($0 as! NumberControl).field.accessibilityLabel() == "Position X" }
    && number("Target Z")?.isDescendant(of: vector("Target")!) == true,
    "position and target are vector rows with per-axis field labels")
  require(number("Aperture radius")?.field.stringValue == "Pinhole" && number("Focus distance")?.scale == .logarithmic
    && number("Field of view, °")?.step == 1, "lens rows: pinhole aperture, logarithmic focus, 1° field of view")
  testRenderer.target = .zero
  testRenderer.setEye(SIMD3(0, 0, -3))
  show(page: 1)
  grouped {
    let x = vector("Position")!.components[0]
    x.field.stringValue = "1"
    x.typed()
  }
  require(abs(testRenderer.eyePosition.x - 1) < 1e-4 && abs(testRenderer.eyePosition.z + 3) < 1e-4
    && history.undoActionName == "Position", "a position field sets that coordinate with one undo step")
  history.undo()
  require(near(testRenderer.eyePosition, SIMD3(0, 0, -3)), "undo restores the position")
  history.removeAllActions()
  show(page: 1)
  grouped { vector("Target")!.set(SIMD3(1, 2, 3)) }
  require(near(testRenderer.target, SIMD3(1, 2, 3)) && history.undoActionName == "Target",
    "the target row sets all three coordinates as one undo step")
  history.undo()
  require(near(testRenderer.target, .zero) && !history.canUndo, "one undo restores the target")
  grouped { button("Reset View")!.invoke() }
  require(testRenderer.yaw == 0.45 && testRenderer.pitch == 0.25 && testRenderer.distance == 3.4
    && testRenderer.target == SIMD3(0, -0.1, 0) && testRenderer.fov == 42 && history.undoActionName == "Reset view",
    "Reset View restores the built-in scene's camera with one undo step")
  history.undo()
  require(near(testRenderer.target, .zero), "undo returns to the previous view")
  var imported = CameraState()
  imported.yaw = 1.1; imported.pitch = 0.3; imported.distance = 7; imported.fov = 30
  imported.target = SIMD3(1, 1, 1)
  try open(scene: 6) { $0.views = ["USD: cam": imported, "Mine": CameraState()] }
  testRenderer.target = SIMD3(5, 5, 5)
  show(page: 1)
  grouped { button("Reset View")!.invoke() }
  require(testRenderer.yaw == 1.1 && testRenderer.distance == 7 && testRenderer.fov == 30
    && testRenderer.target == SIMD3(1, 1, 1), "Reset View on an imported scene returns to the imported camera")
  print("PASS: ui-camera-lighting position/target vector rows and Reset View")

  // Image controls change the display without restarting accumulation.
  try open(scene: 0)
  show(page: 1)
  require(popup("Tone map")?.itemTitles == ["Filmic fit", "Reinhard", "Linear / clip"]
    && number("Exposure, EV")?.step == 0.1, "Image section: tone map popup and exposure in 0.1 EV")
  let generation = testRenderer.interactionGeneration
  grouped {
    let exposure = number("Exposure, EV")!
    exposure.field.stringValue = "1.5"
    exposure.typed()
  }
  grouped {
    popup("Tone map")!.selectItem(at: 1)
    popup("Tone map")!.invoke()
  }
  grouped { number("White balance, cool → warm")!.set(0.2) }
  require(testRenderer.options.exposure == 1.5 && testRenderer.options.toneMap == 1
    && testRenderer.options.whiteBalance == 0.2 && testRenderer.interactionGeneration == generation
    && history.undoActionName == "White balance, cool → warm", "Image controls apply without restarting accumulation")
  history.undo(); history.undo()
  require(testRenderer.options.toneMap == 0, "tone map undo")
  print("PASS: ui-camera-lighting Image section (display only)")

  // Saved views: save, choose, update, rename and delete, each one undo step.
  try open(scene: 0)
  show(page: 1)
  require(popup("Saved view") == nil && button("Update") == nil, "no saved view: only Save Current View…")
  testRenderer.target = SIMD3(1, 0, 0)
  grouped { controller.storeView("Front") }
  require(controller.project.views["Front"]?.target == SIMD3(1, 0, 0) && history.undoActionName == "Save view"
    && popup("Saved view")?.titleOfSelectedItem == "Front" && button("Rename…") != nil,
    "Save stores and chooses the view")
  testRenderer.target = SIMD3(2, 0, 0)
  grouped { button("Update")!.invoke() }
  require(controller.project.views["Front"]?.target == SIMD3(2, 0, 0) && history.undoActionName == "Update view",
    "Update stores the current camera in the chosen view")
  history.undo()
  waitUntil({ controller.project.views["Front"]?.target == SIMD3(1, 0, 0) })
  grouped { require(controller.renameView("Front", to: "Side"), "rename succeeds") }
  require(controller.project.views.keys.sorted() == ["Side"] && history.undoActionName == "Rename view"
    && popup("Saved view")?.titleOfSelectedItem == "Side", "Rename keeps the camera under the new name")
  grouped { controller.storeView("Top") }
  require(!controller.renameView("Top", to: "Side") && controller.project.views.count == 2,
    "renaming to an existing name is refused")
  history.undo()
  history.undo()
  waitUntil({ controller.project.views.keys.sorted() == ["Front"] })
  show(page: 1)
  testRenderer.target = .zero
  grouped {
    popup("Saved view")!.selectItem(at: 0)
    popup("Saved view")!.invoke()
  }
  require(testRenderer.target == SIMD3(1, 0, 0) && history.undoActionName == "Restore view", "choosing a view restores it")
  grouped { button("Delete")!.invoke() }
  require(controller.project.views.isEmpty && history.undoActionName == "Delete view" && popup("Saved view") == nil,
    "Delete removes the chosen view")
  history.undo()
  waitUntil({ controller.project.views["Front"] != nil })
  print("PASS: ui-camera-lighting saved views: save, choose, update, rename, delete with undo")

  // Navigation refreshes the fields, but not while one is being edited.
  try open(scene: 0)
  show(page: 1)
  let targetX = views(NumberControl.self, in: controller.stack).first { $0.field.accessibilityLabel() == "Target X" }!
  _ = testWindow.makeFirstResponder(targetX.field)
  testRenderer.target = SIMD3(7, 0, 0)
  controller.viewport.onUserOrbit?()
  RunLoop.main.run(until: Date().addingTimeInterval(0.6))
  require(targetX.isDescendant(of: controller.stack) && controller.editingInspectorField,
    "the refresh waits while a field is edited")
  _ = testWindow.makeFirstResponder(nil)
  waitUntil({ !targetX.isDescendant(of: controller.stack) }, seconds: 5)
  let refreshed = views(NumberControl.self, in: controller.stack).first { $0.field.accessibilityLabel() == "Target X" }
  require(refreshed?.field.stringValue == "7", "the refresh runs once editing ends")
  print("PASS: ui-camera-lighting camera refresh keeps the field being edited")

  try open(scene: 0)
  controller.page = 0
  controller.rebuild()
}
try fixUICameraLightingChecks()
