import Cocoa
import simd

// The Materials inspector page for built-in scene slots: surface settings, texture maps and material presets.
extension StudioController {
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
    popup(slots.map { names[$0] }, slots.firstIndex(of: selectedSlot) ?? 0, label: "Object") { [weak self] i in
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
      emitterLightControls(slot)
      return
    }
    let material = renderer.materials.settings[slot]
    popup(
      [
        "Original scene material", "Plastic", "Copper", "Coated metal", "Fabric", "Rough glass",
        "Custom OpenPBR",
      ], material.enabled == 0 ? 0 : 6, label: "Material preset"
    ) { [weak self] i in self?.materialPreset(i) }
    func encode(_ c: Float) -> CGFloat {
      CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }
    text("Material tint")
    add(
      ActionColor(
        NSColor(
          srgbRed: encode(material.color.x), green: encode(material.color.y),
          blue: encode(material.color.z), alpha: 1), label: "Material tint"
      ) { [weak self] color in
        guard let self, self.acceptsEdits, let c = color.usingColorSpace(.sRGB) else { return }
        self.checkpoint("Material tint", coalesce: true)
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
      if let data = renderer.materials.payloads[slot * 4 + channel],
        let image = mapThumbnail(data, index: slot * 4 + channel)
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
        } catch { self.showError(error.localizedDescription) }
      }
      if channel == 1 || channel == 2 {
        popup(
          ["Channel: Red", "Channel: Green", "Channel: Blue", "Channel: Alpha"],
          Int(renderer.materials.objects[slot].channels[channel - 1]),
          label: "\(MaterialLibrary.mapNames[channel]) channel"
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
      } catch { self.showError(error.localizedDescription) }
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
