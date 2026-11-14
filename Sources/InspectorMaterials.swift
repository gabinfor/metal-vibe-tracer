import Cocoa
import simd

// The Materials inspector page: the selection, the surface settings of built-in slots and imported materials, texture
// maps and material files. Imported graphs (SceneGraphUI.swift) add the subset and material bindings, MaterialX
// parameters and imported lights (EmitterLights.swift).
extension StudioController {
  // Indexed by material slot (picking names the picked slot). Slots a scene does not use start with "Unused" and,
  // like "Unassigned", stay out of the Object popup.
  func objectNames() -> [String] {
    switch renderer.sceneIndex {
    case 1, 4:
      return [
        "Room surfaces", "Unused floor slot", "Tall box", "Unused ring slot", "Unused chrome slot",
        "Unused glass slot", "Short box", "Unused mesh slot",
      ]
    case 2:
      return [
        "Unassigned", "Floor", "Plate 1", "Plate 2", "Plate 3", "Plate 4", "Unused plinth slot", "Unused mesh slot",
      ]
    case 3:
      return [
        "Room surfaces", "Unused floor slot", "Unused copper slot", "Unused ring slot",
        "Mirror sphere", "Glass sphere", "Unused plinth slot", "Unused mesh slot",
      ]
    case 5:
      return [
        "Back wall", "Floor", "Unused copper slot", "Gold ring", "Chrome sphere",
        "Unused glass slot", "Unused plinth slot", "Unused mesh slot",
      ]
    case 6:
      return [
        "Unassigned", "Floor", "Unused copper slot", "Unused ring slot", "Unused chrome slot",
        "Unused glass slot", "Unused plinth slot", "Imported mesh",
      ]
    default: return ["Architecture"] + Array(MaterialLibrary.names.dropFirst(1).dropLast()) + ["Unused mesh slot"]
    }
  }
  // Whether the scene shows an imported mesh: a scene graph with a mesh node, or a legacy single mesh (documents
  // from before scene graphs, until a model is added).
  var sceneHasMesh: Bool {
    renderer.sceneIndex == 6
      && (project.graph?.nodes.contains { $0.mesh != nil } == true || (project.graph == nil && !project.triangles.isEmpty))
  }
  // The Object popup, shared by the Materials and Objects tabs: imported scenes list their hierarchy
  // (selectGraphNode), built-in scenes the surface groups they use.
  func selectObject() {
    if renderer.sceneIndex == 6, project.graph != nil {
      selectGraphNode()
      return
    }
    let names = objectNames()
    let slots = names.indices.filter {
      !names[$0].hasPrefix("Unused") && names[$0] != "Unassigned" && ($0 != 7 || sceneHasMesh)
    }
    if !slots.contains(selectedSlot) { selectedSlot = slots.first ?? 0 }
    popupRow("Object", slots.map { names[$0] }, slots.firstIndex(of: selectedSlot) ?? 0) { [weak self] i in
      self?.selectedSlot = slots[i]
      self?.rebuild()
    }
  }
  // Small cached previews: full-resolution maps are never decoded for the inspector.
  func mapThumbnail(_ data: Data, index: Int) -> NSImage? {
    if let cached = mapThumbnails[index], cached.data == data { return cached.image }
    mapThumbnails[index] = nil
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 160,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    mapThumbnails[index] = (data, image)
    return image
  }
  static let materialPresetTitles = [
    "Original scene material", "Plastic", "Copper", "Coated metal", "Fabric", "Rough glass", "Custom OpenPBR",
  ]
  static let materialXImportHelp =
    "Imports the OpenPBR materials of a .mtlx file and assigns the first to the selection. Supported: OpenPBR surface, constants, images, UV0, arithmetic, mix, clamp, extract, normalmap and limited convert; unsupported nodes are listed in the import report."
  func materialPanel() {
    section("Selection")
    selectObject()
    if renderer.sceneIndex == 6, project.graph != nil, selectedNode != nil { graphBindings() }
    let slot = selectedSlot
    if let program = renderer.materials.materialX[slot] {
      materialXPanel(program, slot: slot)
      materialFileSection(slot, presets: true) {
        self.button(
          "Remove MaterialX Graph", style: .destructive,
          help: "Removes the graph from this material; its surface settings and maps apply again."
        ) { [weak self] in self?.removeMaterialX(slot) }
      }
      return
    }
    if let emission = renderer.materials.emissions[slot] {
      emitterLightControls(slot, radiance: emission)
      materialFileSection(slot, presets: false) {}
      return
    }
    let material = renderer.materials.settings[slot]
    section("Surface")
    popupRow("Preset", Self.materialPresetTitles, material.enabled == 0 ? 0 : 6,
      help: "Original scene material keeps the scene's own surface; any edit below switches to Custom OpenPBR."
    ) { [weak self] i in self?.materialPreset(i) }
      .setAccessibilityLabel("Material preset")
    colorRow(
      "Tint", SIMD3(material.color.x, material.color.y, material.color.z), help: "Multiplies the base color map."
    ) { [weak self] rgb in
      self?.renderer.materials.settings[slot].color = SIMD4(rgb, 1)
      self?.renderer.materials.settings[slot].enabled = 1
    }.setAccessibilityLabel("Material tint")
    for (i, name) in ["Roughness", "Metalness", "Coat", "Anisotropy"].enumerated() {
      number(name, material.surface[i], i == 0 ? 0.03...1 : 0...1, i == 0 ? 0.3 : 0, step: 0.01) { [weak self] v in
        self?.renderer.materials.settings[slot].surface[i] = v
        self?.renderer.materials.settings[slot].enabled = 1
      }
    }
    for (i, name) in ["Fuzz", "IOR", "Transmission"].enumerated() {
      number(name, material.detail[i], i == 1 ? 1.01...2.5 : 0...1, i == 1 ? 1.5 : 0, step: 0.01) { [weak self] v in
        self?.renderer.materials.settings[slot].detail[i] = v
        self?.renderer.materials.settings[slot].enabled = 1
      }
    }
    section("Texture mapping")
    number("Normal strength", material.normalStrength, 0...4, 1) { [weak self] in
      self?.renderer.materials.settings[slot].normalStrength = $0
    }
    number("UV repeat", material.detail.w, 0.01...100, 1) { [weak self] in
      self?.renderer.materials.settings[slot].detail.w = $0
    }
    let uv = renderer.materials.objects[slot].uvTransform
    for (i, name) in ["UV offset U", "UV offset V"].enumerated() {
      number(name, uv[i], -10...10, 0) { [weak self] in self?.renderer.materials.objects[slot].uvTransform[i] = $0 }
    }
    number("UV rotation, °", uv.z * 180 / .pi, -180...180, 0, step: 1) { [weak self] in
      self?.renderer.materials.objects[slot].uvTransform.z = $0 * .pi / 180
    }
    section("Textures")
    for channel in 0..<4 { textureBlock(slot, channel) }
    materialFileSection(slot, presets: true) {
      self.button(
        "Reset Material", style: .destructive,
        help: "Restores the default surface settings and removes the four texture maps."
      ) { [weak self] in self?.resetMaterial(slot) }
    }
  }
  static let mapTitles = ["Base color", "Roughness", "Metalness", "Normal"]
  static let mapHelp = [
    "Base color (sRGB); multiplies the tint.", "Roughness (linear); replaces the Roughness value.",
    "Metalness (linear); replaces the Metalness value.", "Normal map (linear, +Y up, OpenGL convention).",
  ]
  // One map: its name and file, a thumbnail when loaded, Load… and Clear, and the channel read for scalar maps.
  func textureBlock(_ slot: Int, _ channel: Int) {
    let index = slot * 4 + channel
    let fileName = renderer.materials.fileNames[index]
    let loaded = renderer.materials.payloads[index] != nil || fileName != "None"
    let title = inspectorLabel(Self.mapTitles[channel], help: Self.mapHelp[channel])
    title.font = .systemFont(ofSize: 12, weight: .medium)
    let file = NSTextField(labelWithString: loaded ? fileName : "None")
    file.font = .systemFont(ofSize: 11)
    file.textColor = .secondaryLabelColor
    file.lineBreakMode = .byTruncatingMiddle
    file.toolTip = loaded ? fileName : nil
    let row = inspectorRow(title, file)
    file.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
    add(row)
    if let data = renderer.materials.payloads[index], let image = mapThumbnail(data, index: index) {
      let preview = NSImageView()
      preview.image = image
      preview.imageScaling = .scaleProportionallyUpOrDown
      preview.imageAlignment = .alignLeft
      preview.heightAnchor.constraint(equalToConstant: 64).isActive = true
      preview.setAccessibilityLabel("\(Self.mapTitles[channel]) map preview")
      add(preview)
    }
    let load = ActionButton("Load…") { [weak self] in self?.loadMap(slot, channel) }
    load.setAccessibilityLabel("Load \(Self.mapTitles[channel].lowercased()) map…")
    load.toolTip = Self.mapHelp[channel]
    let clear = ActionButton("Clear") { [weak self] in self?.clearMap(slot, channel) }
    clear.setAccessibilityLabel("Clear \(Self.mapTitles[channel].lowercased()) map")
    clear.isEnabled = loaded
    buttonRow([load, clear])
    if channel == 1 || channel == 2 {
      popupRow(
        "Channel", ["Red", "Green", "Blue", "Alpha"], Int(renderer.materials.objects[slot].channels[channel - 1]),
        help: "The image channel the \(Self.mapTitles[channel].lowercased()) map reads."
      ) { [weak self] i in
        guard let self else { return }
        self.checkpoint("Texture channel")
        self.renderer.materials.objects[slot].channels[channel - 1] = UInt32(i)
        self.changed()
      }.setAccessibilityLabel("\(MaterialLibrary.mapNames[channel]) channel")
    }
    if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
  }
  // Presets, MaterialX import and its report, then `destructive` (the section's last button).
  func materialFileSection(_ slot: Int, presets: Bool, _ destructive: () -> Void) {
    section("Material file")
    if presets {
      buttonRow([
        ActionButton("Save Preset…") { [weak self] in self?.saveMaterial() },
        ActionButton("Load Preset…") { [weak self] in self?.loadMaterial() },
      ])
    }
    button("Import MaterialX…", help: Self.materialXImportHelp) { [weak self] in self?.importMaterialX() }
    if !materialXReport.isEmpty {
      button("MaterialX Import Report…") { [weak self] in self?.showMaterialXReport() }
    }
    destructive()
  }
  func clearMap(_ slot: Int, _ channel: Int) {
    guard !isBusy else { return }
    do {
      let record = undoRecord("Clear texture")
      try renderer.materials.clear(slot: slot, channel: channel)
      commit(record)
      changed()
      rebuild()
    } catch { showError(error.localizedDescription) }
  }
  func resetMaterial(_ slot: Int) {
    guard !isBusy else { return }
    let record = undoRecord("Reset material")
    // Publish settings and all four maps in one transactional restore.
    var state = renderer.materials.state()
    state.surfaces[slot] = SurfaceSettings()
    for c in 0..<4 {
      state.maps[slot * 4 + c] = nil
      state.names[slot * 4 + c] = "None"
    }
    do {
      try renderer.materials.restore(state)
      commit(record)
      changed()
      rebuild()
    } catch { showError(error.localizedDescription) }
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
    } catch { showError(error.localizedDescription) }
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
      do { try document.encodedProject().json.write(to: url, options: .atomic) } catch {
        self?.showError(error.localizedDescription)
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
    let document = snapshot()
    let scene = Int(renderer.sceneIndex)
    beginDocumentChange("Loading \(url.lastPathComponent)…", build: { [weak self] _ -> (ProjectDocument, Void) in
      guard let self else { throw MaterialLibrary.error("Material preset load cancelled.") }
      var document = document  // The build runs on projectIOQueue with its own copy.
      let p = try ProjectDocument.decodeProject(
        self.readBounded(url, maximum: ProjectDocument.maximumFileBytes), near: nil)
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
      case .failure(let error): self.showError(error.localizedDescription)
      }
    }
  }
}
