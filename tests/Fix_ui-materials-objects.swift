// The Materials and Objects tabs (InspectorMaterials.swift, InspectorObjects.swift, SceneGraphUI.swift, EmitterLights.swift).
@MainActor func fixUIMaterialsObjectsChecks() throws {
  let history = controller.history
  let folder = studioDirectory.absoluteURL.appendingPathComponent("fix-ui-materials-objects", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let savedAutosaveURL = controller.autosaveURL
  controller.autosaveURL = folder.appendingPathComponent("Autosave.vtrace")
  let wasGroupingByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer {
    controller.saveTimer?.invalidate()
    controller.autosaveURL = savedAutosaveURL
    history.groupsByEvent = wasGroupingByEvent
    controller.selectedNode = nil
    controller.page = 0
    controller.rebuild()
  }
  func grouped(_ body: () throws -> Void) rethrows {
    history.beginUndoGrouping()
    defer { history.endUndoGrouping() }
    try body()
  }
  func idle() { waitUntil({ !controller.isBusy }, seconds: 60) }
  func reset(_ document: ProjectDocument) throws {
    controller.saveTimer?.invalidate()
    try controller.restore(document)
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
  // The page's section headings, in order (the 14-pt semibold labels, the scene row's title excluded).
  func sections() -> [String] {
    views(NSTextField.self, in: controller.stack).filter {
      $0.font == .systemFont(ofSize: 14, weight: .semibold) && !$0.isEditable
    }.map(\.stringValue).filter { !$0.isEmpty }
  }
  func popup(_ label: String) -> ActionPopup? {
    views(ActionPopup.self, in: controller.stack).first { $0.accessibilityLabel() == label }
  }
  func button(_ title: String) -> ActionButton? {
    views(ActionButton.self, in: controller.stack).first { $0.title == title }
  }
  func buttons(_ label: String) -> [ActionButton] {
    views(ActionButton.self, in: controller.stack).filter { $0.title == label || $0.accessibilityLabel() == label }
  }
  func vector(_ title: String) -> VectorControl? {
    views(VectorControl.self, in: controller.stack).first { $0.components[0].field.accessibilityLabel()?.hasPrefix(title + " ") == true }
  }
  func number(_ label: String) -> NumberControl? {
    views(NumberControl.self, in: controller.stack).first { $0.field.accessibilityLabel() == label }
  }
  func visible() -> ActionSwitch? {
    views(ActionSwitch.self, in: controller.stack).first { $0.accessibilityLabel() == "Visible" }
  }
  func labels() -> [String] {
    views(NSTextField.self, in: controller.stack).map(\.stringValue)
      + views(NSButton.self, in: controller.stack).map(\.title)
  }
  let mesh = ["No mesh", "Frame imported mesh", "Frame All", "Frame Selection", "Frame all imported objects"]

  // Built-in scene (Cornell Box): Objects shows the used surface groups, Visible, Transform and Add Model… only.
  var cornell = ProjectDocument()
  cornell.scene = 1
  try reset(cornell)
  show(page: 4)
  require(sections() == ["Selection", "Transform", "Actions"], "Cornell Objects sections: \(sections())")
  require(popup("Object")?.itemTitles == ["Room surfaces", "Tall box", "Short box"],
    "built-in Object popup lists only the scene's surface groups: \(popup("Object")?.itemTitles ?? [])")
  require(!labels().contains { mesh.contains($0) } && button("Add Model…") != nil && button("Delete") == nil,
    "nothing mesh-specific on a scene without a mesh")
  controller.selectedSlot = 2
  show(page: 4)
  let tall = visible()!
  require(tall.isOn, "the tall box starts visible")
  tall.state = .off
  grouped { tall.invoke() }
  require(testRenderer.materials.objects[2].rotationHidden.w == 1 && history.undoActionName == "Visibility"
    && visible()?.isOn == false, "the Visible switch hides the group with one undo step")
  history.undo()
  idle()
  require(testRenderer.materials.objects[2].rotationHidden.w == 0, "undo shows the group again")
  show(page: 4)
  history.removeAllActions()
  grouped { vector("Translation")!.set(SIMD3(0.1, 0.2, -0.3)) }
  grouped { vector("Rotation, °")!.set(SIMD3(90, 0, 0)) }
  grouped { number("Scale")!.set(2) }
  let moved = testRenderer.materials.objects[2]
  require(moved.positionScale == SIMD4(0.1, 0.2, -0.3, 2) && abs(moved.rotationHidden.x - .pi / 2) < 1e-5
    && history.undoActionName == "Scale", "the grouped transform rows set the model")
  history.undo()
  idle()
  require(testRenderer.materials.objects[2].positionScale.w == 1, "each transform row is one undo step")
  show(page: 4)
  testRenderer.materials.objects[2].rotationHidden.w = 1
  grouped { button("Reset Transform")!.invoke() }
  require(testRenderer.materials.objects[2].positionScale == SIMD4(0, 0, 0, 1)
    && testRenderer.materials.objects[2].rotationHidden == SIMD4(0, 0, 0, 1), "Reset Transform keeps the visibility")
  print("PASS: fix-ui-materials-objects built-in Objects tab: sections, Object popup, Visible, grouped transform")

  // Built-in Materials: sections, labelled rows, texture blocks and the destructive Reset Material.
  controller.selectedSlot = 2
  show(page: 3)
  require(sections() == ["Selection", "Surface", "Texture mapping", "Textures", "Material file"],
    "Materials sections: \(sections())")
  require(popup("Material preset")?.itemTitles.first == "Original scene material"
    && views(ActionColor.self, in: controller.stack).contains { $0.accessibilityLabel() == "Material tint" }
    && popup("Roughness (linear R) channel")?.itemTitles == ["Red", "Green", "Blue", "Alpha"]
    && popup("Metalness (linear R) channel") != nil, "Surface and channel rows keep their accessibility labels")
  require(controller.stack.arrangedSubviews.compactMap { $0 as? NumberControl }.first?.field.accessibilityLabel()
    == "Roughness", "Roughness is the page's first number row")
  require(!labels().contains { $0.hasPrefix("Channel: ") || $0.hasPrefix("Subset: ") || $0.hasPrefix("Parent: ") },
    "no label prefixes in popups")
  let loads = ["base color", "roughness", "metalness", "normal"].map { buttons("Load \($0) map…").first }
  let clears = ["base color", "roughness", "metalness", "normal"].map { buttons("Clear \($0) map").first }
  require(loads.allSatisfy { $0?.title == "Load…" } && clears.allSatisfy { $0?.title == "Clear" && $0?.isEnabled == false },
    "each map has Load… and Clear (disabled while empty)")
  let resetMaterial = button("Reset Material")!
  let file = views(ActionButton.self, in: controller.stack).filter { ["Save Preset…", "Load Preset…", "Import MaterialX…", "Reset Material"].contains($0.title) }
  require(file.last === resetMaterial && resetMaterial.style == .destructive, "Reset Material is the destructive last item")
  let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let png = folder.appendingPathComponent("rough.png")
  try image.representation(using: .png, properties: [:])!.write(to: png)
  grouped { controller.loadTexture(from: png, slot: 2, channel: 1) }
  show(page: 3)
  require(buttons("Clear roughness map").first?.isEnabled == true && labels().contains("rough.png")
    && views(NSImageView.self, in: controller.stack).contains { $0.accessibilityLabel() == "Roughness map preview" },
    "a loaded map shows its name, thumbnail and an enabled Clear")
  grouped { buttons("Clear roughness map").first!.invoke() }
  require(testRenderer.materials.payloads[2 * 4 + 1] == nil && history.undoActionName == "Clear texture", "Clear removes the map")
  show(page: 3)
  grouped { number("Roughness")!.set(0.8) }
  grouped { button("Reset Material")!.invoke() }
  require(testRenderer.materials.settings[2].surface.x == SurfaceSettings().surface.x
    && history.undoActionName == "Reset material", "Reset Material restores the defaults")
  print("PASS: fix-ui-materials-objects Materials tab: sections, labels, texture blocks, Reset Material")

  // Pavilion: no internal slot names.
  try reset(ProjectDocument())
  for page in [3, 4] {
    show(page: page)
    let items = popup("Object")?.itemTitles ?? []
    require(!items.isEmpty && !items.contains { $0.hasPrefix("Unused") || $0 == "Unassigned" || $0.contains("mesh") },
      "Pavilion Object popup hides internal slots: \(items)")
    require(!labels().contains { mesh.contains($0) }, "Pavilion page \(page) shows nothing mesh-specific")
  }

  // Imported scene: hierarchy, Visible, Parent, grouped graph transforms, actions.
  var imported = ProjectDocument()
  let obj = "v 0 0 0\nv 1 0 0\nv 0 1 0\no A\nusemtl Red\nf 1 2 3\no B\nusemtl Blue\nf 1 2 3\n"
  _ = try imported.appendOBJ(obj, name: "pair.obj")
  imported.scene = 6
  try reset(imported)
  controller.selectedNode = nil
  show(page: 4)
  require(button("Frame All") != nil && button("Frame Selection") == nil && button("Delete") == nil
    && popup("Scene object")?.itemTitles.first == "Studio floor", "imported scene without a selection")
  let a = controller.project.graph!.nodes.first { $0.name == "A" }!.id
  controller.selectedNode = a
  show(page: 4)
  require(sections() == ["Selection", "Transform", "Actions"] && popup("Parent")?.itemTitles.first == "Scene root",
    "imported Objects sections and Parent popup: \(sections())")
  let actions = views(ActionButton.self, in: controller.stack).map(\.title)
  require(actions.suffix(5) == ["Frame Selection", "Frame All", "Create Instance", "Add Model…", "Delete"]
    && button("Delete")!.style == .destructive && !(button("Delete")!.toolTip ?? "").isEmpty,
    "Actions: framing, instancing, Add Model… and Delete last: \(actions)")
  func node() -> SceneNode { controller.project.graph!.nodes.first { $0.id == a }! }
  visible()!.state = .off
  grouped { visible()!.invoke() }
  require(node().transform.rotationHidden.w == 1 && history.undoActionName == "Visibility" && visible()?.isOn == false,
    "graph Visible hides the node with one undo step")
  history.undo()
  idle()
  require(node().transform.rotationHidden.w == 0, "undo shows the node again")
  controller.selectedNode = a
  show(page: 4)
  grouped { vector("Translation")!.set(SIMD3(1, 2, 3)) }
  require(node().transform.positionScale == SIMD4(1, 2, 3, 1) && history.undoActionName == "Translation",
    "graph Translation is one edit")
  grouped { vector("Rotation, °")!.set(SIMD3(0, 45, 0)) }
  grouped { number("Scale")!.set(0.5) }
  require(abs(node().transform.rotationHidden.y - .pi / 4) < 1e-5 && node().transform.positionScale.w == 0.5,
    "graph Rotation and Scale set the node")
  idle()
  show(page: 4)
  let count = controller.project.graph!.nodes.count
  grouped { button("Create Instance")!.invoke() }
  let family = controller.project.graph!.descendants(of: a).count
  require(family == 2 && controller.project.graph!.nodes.count == count + family && controller.selectedNode != a,
    "Create Instance copies the object and its children")
  let instance = controller.selectedNode!
  idle()
  show(page: 4)
  grouped { button("Delete")!.invoke() }
  require(controller.project.graph!.nodes.count == count && !controller.project.graph!.nodes.contains { $0.id == instance },
    "Delete removes the object and its children")
  // OBJ object A is a group holding one mesh node.
  controller.selectedNode = controller.project.graph!.nodes.first { $0.parent == a && $0.mesh != nil }!.id
  controller.selectedSubset = 0
  show(page: 3)
  require(popup("Material subset")?.itemTitles.isEmpty == false && popup("Subset material") != nil
    && button("New Material") != nil, "imported Materials selection rows")
  print("PASS: fix-ui-materials-objects imported Objects and Materials tabs")

  // MaterialX: readable names, R/G/B vector rows that recompile the program.
  require(
    StudioController.materialXDisplayNames(["Paint/base_color", "Graph/tint", "Graph/blend/fg", "Graph/mul/in1",
      "Other/mul/in1", "Paint/specular_ior"])
      == ["Base color", "Tint", "Blend › fg", "Graph › mul › in1", "Other › mul › in1", "Specular IOR"],
    "MaterialX display names")
  let mx = try MaterialXImporter.read(Data("""
    <materialx version="1.39"><open_pbr_surface name="Paint" type="surfaceshader">
    <input name="base_color" type="color3" value="0.8,0.2,0.1"/><input name="coat_weight" type="float" value="0.3"/>
    </open_pbr_surface></materialx>
    """.utf8), baseURL: folder, source: "Paint.mtlx")
  let slot = controller.selectedSlot
  try testRenderer.materials.prepareMaterialX([slot: mx.materials[0]])
  show(page: 3)
  let names = views(NumberControl.self, in: controller.stack).compactMap { $0.field.accessibilityLabel() }
  require(!names.contains { $0.contains("/") || $0.contains("[") || $0.contains("_") } && number("Coat weight") != nil,
    "MaterialX rows have readable names: \(names)")
  let base = vector("Base color")!
  require(base.components.map { $0.field.accessibilityLabel() } == ["Base color R", "Base color G", "Base color B"],
    "a colour parameter is one R/G/B row")
  grouped { base.components[1].set(0.5) }
  let edited = testRenderer.materials.materialX[slot]!
  let parameter = edited.parameters.first { $0.name.hasSuffix("base_color") }!
  require(abs(edited.instructions[parameter.instruction].value.y - 0.5) < 1e-6
    && history.undoActionName == "MaterialX parameter", "editing the vector row recompiles the program")
  require(button("Remove MaterialX Graph")?.style == .destructive, "MaterialX materials end with Remove MaterialX Graph")
  print("PASS: fix-ui-materials-objects MaterialX parameter names and vector rows")

  // Imported light: Radiance vector row, Spectrum, blackbody fields, Spot cone.
  var lit = ProjectDocument()
  _ = try lit.appendOBJ(obj, name: "pair.obj")
  lit.scene = 6
  let glow = try lit.graph!.addMaterial("Glow")
  let lamp = lit.graph!.nodes.firstIndex { $0.mesh != nil }!
  lit.graph!.nodes[lamp].bindings[0] = glow.id
  var state = SceneState()
  state.emissions = [glow.slot: SIMD3<Float>(6, 6, 6)]
  lit.scenes[6] = state
  try reset(lit)
  controller.selectedNode = lit.graph!.nodes[lamp].id
  show(page: 3)
  require(sections().contains("Light") && sections().contains("Spot cone") && !sections().contains("Surface"),
    "an imported light shows Light and Spot cone: \(sections())")
  grouped { vector("Radiance")!.set(SIMD3(1, 2, 3)) }
  require(testRenderer.materials.emissions[glow.slot] == SIMD3(1, 2, 3), "Radiance row sets the emission")
  let spectrum = popup("Spectrum")!
  spectrum.selectItem(withTitle: "Blackbody")
  grouped { spectrum.invoke() }
  require(number("Temperature, K") != nil && number("Cone angle, °") != nil, "blackbody and cone rows")
  print("PASS: fix-ui-materials-objects imported light controls")
}
try fixUIMaterialsObjectsChecks()
