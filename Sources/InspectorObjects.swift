import Cocoa
import simd

// The Objects inspector page for built-in scene slots, model import and framing.
extension StudioController {
  func objectPanel() {
    if renderer.sceneIndex == 6, project.graph != nil {
      graphObjectPanel()
      return
    }
    heading("Object / surface group")
    selectObject()
    legacyObjectControls()
    heading("Add model")
    text(project.meshName)
    button("Add Model…") { [weak self] in self?.addModel() }
    button("Frame imported mesh") { [weak self] in self?.frameMesh() }
    text(
      "OBJ positions, UVs and normals are supported. Object/group hierarchy and named material subsets are preserved. Imports append to the scene. MTL materials are imported. Triangulate concave polygons before import."
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
  func addModel() {
    chooseOpen("Add OBJ model", extensions: ["obj"]) { [weak self] url in
      self?.beginImportOBJ(from: url)
    }
  }
  // Reading, parsing and resource preparation run on projectIOQueue.
  func beginImportOBJ(from url: URL) {
    guard !isBusy else { return }
    let record = undoRecord("Add model")
    let document = snapshot()
    beginDocumentChange("Importing \(url.lastPathComponent)…", build: { [weak self] progress -> (ProjectDocument, (UUID, Int, Int, [String])) in
      guard let self else { throw MaterialLibrary.error("OBJ import cancelled.") }
      var document = document  // The build runs on projectIOQueue with its own copy.
      // Memory-mapped and streamed: files of several GB parse without a text copy.
      let objData = try self.readBounded(url, maximum: 1 << 40)
      var skipped = 0
      var report: [String] = []
      let root = try document.appendOBJ(objData, name: url.lastPathComponent, folder: url.deletingLastPathComponent(),
        skipped: &skipped, report: &report, progress: progress)
      return (document, (root, document.graph?.materials.last?.slot ?? 1, skipped, report))
    }) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let (root, slot, skipped, report)):
        self.commit(record)
        self.selectedNode = root
        self.selectedSlot = slot
        self.frameMesh(recordUndo: false)
        self.changed()
        if skipped > 0 || !report.isEmpty {
          self.show("Imported \(url.lastPathComponent)"
            + (skipped > 0 ? "; skipped \(skipped) degenerate faces" : "")
            + (report.isEmpty ? "." : "; see the import report in the scene hierarchy."))
        }
      case .failure(let error): self.showError(error.localizedDescription)
      }
    }
  }
  func frameMesh(recordUndo: Bool = true) {
    if renderer.sceneIndex != 6 {
      // The switch may prepare scene resources off the main thread; frame afterwards.
      switchScene(6) { [weak self] in self?.frameMesh(recordUndo: recordUndo) }
      return
    }
    // Reads the shared GPU buffer (BVH order); no host copy of the mesh is kept for this.
    let materials = renderer.materials
    let tris = materials.orderedTriangles
    guard !tris.isEmpty else { return }
    if recordUndo { checkpoint("Frame mesh") }
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var hi = -lo
    let o = materials.hasSceneGraph ? ObjectSettings() : materials.objects[7]
    let family = selectedNode.flatMap { project.graph?.descendants(of: $0) }
    let rotation = SIMD3(o.rotationHidden.x, o.rotationHidden.y, o.rotationHidden.z)
    if let layout = materials.meshLayout {
      // Two-level: each instance of the family, exactly. A translated instance is bounded by
      // its asset's bounds plus the translation (rounding is monotonic), others by vertices.
      func add(_ p: SIMD3<Float>) {
        let v = rotateObject(p * o.positionScale.w, rotation) + SIMD3(o.positionScale.x, o.positionScale.y, o.positionScale.z)
        lo = simd_min(lo, v)
        hi = simd_max(hi, v)
      }
      for (i, instance) in layout.instances.enumerated() {
        if let graph = project.graph, let family, instance.node >= 0,
          !graph.nodes.indices.contains(instance.node) || !family.contains(graph.nodes[instance.node].id)
        {
          continue
        }
        let asset = layout.assets[instance.asset]
        if rotation == .zero, MeshSceneLayout.linear(instance.world) == matrix_identity_float3x3 {
          let t = SIMD3(instance.world.columns.3.x, instance.world.columns.3.y, instance.world.columns.3.z)
          if asset.count > 0 { add(asset.lo + t); add(asset.hi + t) }
          continue
        }
        for k in 0..<asset.count {
          let w = layout.worldTriangle(tris[asset.triangleBase + k], instance: i)
          for p in [w.a, w.b, w.c] { add(SIMD3(p.x, p.y, p.z)) }
        }
      }
    } else if family == nil, rotation == .zero, materials.nodeCount > 0 {
      // Unrotated whole-mesh framing: the BVH root already bounds every vertex.
      let root = materials.nodeBuffer.contents().load(as: MeshNode.self)
      for v in [SIMD3(root.lo.x, root.lo.y, root.lo.z), SIMD3(root.hi.x, root.hi.y, root.hi.z)] {
        let p = v * o.positionScale.w + SIMD3(o.positionScale.x, o.positionScale.y, o.positionScale.z)
        lo = simd_min(lo, p)
        hi = simd_max(hi, p)
      }
    }
    for t in lo.x <= hi.x || materials.meshLayout != nil ? tris[0..<0] : tris[...] {
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
}
