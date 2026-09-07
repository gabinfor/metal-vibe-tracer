import Cocoa
import simd

extension StudioController {
  func selectGraphNode() {
    guard let graph = project.graph else { return }
    if !graph.nodes.contains(where: { $0.id == selectedNode }) {
      selectedNode = nil
      selectedSlot = 1
    }
    var ordered: [(SceneNode, Int)] = []
    func visit(_ parent: UUID?, _ depth: Int) {
      for n in graph.nodes where n.parent == parent {
        ordered.append((n, depth))
        visit(n.id, depth + 1)
      }
    }
    visit(nil, 0)
    popup(
      ["Studio floor"]
        + ordered.map {
          String(repeating: "  ", count: $0.1) + ($0.0.mesh == nil ? "▸ " : "◇ ") + $0.0.name
        },
      selectedNode.flatMap { id in ordered.firstIndex(where: { $0.0.id == id }).map { $0 + 1 } }
        ?? 0
    ) { [weak self] i in
      guard let self else { return }
      self.selectedNode = i == 0 ? nil : ordered[i - 1].0.id
      self.selectedSubset = 0
      self.selectedSlot =
        i == 0
        ? 1
        : graph.materials.first(where: { $0.id == ordered[i - 1].0.bindings.first })?.slot ?? graph
          .materials.first?.slot ?? 1
      self.rebuild()
    }
  }
  func graphBindings() {
    guard let graph = project.graph, let node = graph.nodes.first(where: { $0.id == selectedNode })
    else { return }
    if let mesh = node.mesh, let asset = graph.assets.first(where: { $0.id == mesh }) {
      selectedSubset = min(max(0, selectedSubset), asset.subsets.count - 1)
      popup(asset.subsets.map { "Subset: " + $0 }, selectedSubset) { [weak self] i in
        guard let self else { return }
        self.selectedSubset = i
        self.selectedSlot = graph.materials.first(where: { $0.id == node.bindings[i] })?.slot ?? 1
        self.rebuild()
      }
      let binding = node.bindings[selectedSubset]
      selectedSlot = graph.materials.first(where: { $0.id == binding })?.slot ?? 1
      popup(
        graph.materials.map(\.name), graph.materials.firstIndex(where: { $0.id == binding }) ?? 0
      ) { [weak self] i in
        guard let self else { return }
        let subset = self.selectedSubset
        self.editGraph("Assign material") { g in
          if let index = g.nodes.firstIndex(where: { $0.id == node.id }) {
            g.nodes[index].bindings[subset] = g.materials[i].id
          }
        }
      }
    } else {
      text(
        "Select a mesh child to assign a face subset. Material edits affect every object using that material."
      )
      popup(
        graph.materials.map(\.name),
        graph.materials.firstIndex(where: { $0.slot == selectedSlot }) ?? 0
      ) { [weak self] i in
        self?.selectedSlot = graph.materials[i].slot
        self?.rebuild()
      }
    }
    button("New material for selection") { [weak self] in
      guard let self else { return }
      let subset = self.selectedSubset
      self.editGraph("New material") { g in
        let m = try g.addMaterial("Material \(g.materials.count+1)")
        if let i = g.nodes.firstIndex(where: { $0.id == node.id }), !g.nodes[i].bindings.isEmpty {
          g.nodes[i].bindings[subset] = m.id
        }
        self.selectedSlot = m.slot
      }
    }
    text("Material edits are shared by all subsets assigned to the same material.")
  }
  func editGraph(_ title: String, rebuildGeometry: Bool = true, _ edit: (inout SceneGraph) throws -> Void) {
    guard !isBusy, var graph = project.graph else { return }
    let previousState = renderer.materials.state()
    let previousTriangles = renderer.materials.meshTriangles
    do {
      let previousMaterials = graph.materials
      try edit(&graph)
      let triangles = rebuildGeometry ? try graph.renderTriangles() : nil
      checkpoint(title)
      let remaining = Set(graph.materials.map(\.id))
      let removedSlots = previousMaterials.filter { !remaining.contains($0.id) }.map(\.slot)
      if !removedSlots.isEmpty {
        var state = renderer.materials.state()
        for slot in removedSlots {
          state.surfaces[slot] = SurfaceSettings()
          state.objects[slot] = ObjectSettings()
          for channel in 0..<4 {
            state.maps[slot * 4 + channel] = nil
            state.names[slot * 4 + channel] = "None"
          }
          state.materialX?.removeValue(forKey: slot)
          state.emissions?.removeValue(forKey: slot)
        }
        try renderer.materials.restore(state)
      }
      if let triangles { try renderer.materials.setMesh(triangles) }
      renderer.materials.hasSceneGraph = true
      project.graph = graph
      changed()
      rebuild()
    } catch {
      // Resource publication is transactional at the library level; this also
      // rolls back a multi-step material-prune plus geometry edit.
      try? renderer.materials.restore(previousState)
      try? renderer.materials.setMesh(previousTriangles)
      renderer.materials.hasSceneGraph = project.graph != nil
      show(error.localizedDescription)
    }
  }
  func graphObjectPanel() {
    heading("Scene hierarchy")
    if project.importReport != nil {
      button("USD import report…") { [weak self] in self?.showUSDReport() }
    }
    selectGraphNode()
    if let graph = project.graph, let node = graph.nodes.first(where: { $0.id == selectedNode }) {
      let o = node.transform
      button("Rename…") { [weak self] in
        guard let self else { return }
        let alert = NSAlert()
        alert.messageText = "Object name"
        let field = NSTextField(string: node.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
          !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          self.editGraph("Rename object", rebuildGeometry: false) { g in
            g.nodes[g.nodes.firstIndex(where: { $0.id == node.id })!].name = field.stringValue
          }
        }
      }
      let family = graph.descendants(of: node.id)
      let parents = graph.nodes.filter { !family.contains($0.id) }
      popup(
        ["Parent: Scene root"] + parents.map { "Parent: " + $0.name },
        node.parent.flatMap { id in parents.firstIndex(where: { $0.id == id }).map { $0 + 1 } } ?? 0
      ) { [weak self] i in
        self?.editGraph("Change parent") { g in
          g.nodes[g.nodes.firstIndex(where: { $0.id == node.id })!].parent =
            i == 0 ? nil : parents[i - 1].id
        }
      }
      text("Transforms are relative to the parent. Reparenting preserves local values.")
      button(o.rotationHidden.w > 0 ? "Hidden — click to show" : "Visible — click to hide") {
        [weak self] in
        self?.editGraph("Visibility") { g in
          g.nodes[g.nodes.firstIndex(where: { $0.id == node.id })!].transform.rotationHidden.w =
            o.rotationHidden.w > 0 ? 0 : 1
        }
      }
      func control(
        _ title: String, _ value: Float, _ range: ClosedRange<Float>, _ fallback: Float,
        _ setter: @escaping (inout ObjectSettings, Float) -> Void
      ) {
        add(
          NumberControl(title, value: value, range: range, defaultValue: fallback) {
            [weak self] v in
            self?.editGraph(title) { g in
              setter(&g.nodes[g.nodes.firstIndex(where: { $0.id == node.id })!].transform, v)
            }
          })
      }
      for i in 0..<3 {
        control("Translation \(["X","Y","Z"][i])", o.positionScale[i], -100...100, 0) {
          $0.positionScale[i] = $1
        }
        control(
          "Rotation \(["X","Y","Z"][i]), degrees", o.rotationHidden[i] * 180 / .pi, -180...180, 0
        ) { $0.rotationHidden[i] = $1 * .pi / 180 }
      }
      control("Uniform scale", o.positionScale.w, 0.01...100, 1) { $0.positionScale.w = $1 }
      button("Reset transform") { [weak self] in
        self?.editGraph("Reset transform") { g in
          g.nodes[g.nodes.firstIndex(where: { $0.id == node.id })!].transform = ObjectSettings()
        }
      }
      button("Frame selection") { [weak self] in self?.frameMesh() }
      button("Create instance") { [weak self] in
        guard let self else { return }
        self.editGraph("Create instance") { g in self.selectedNode = try g.instance(node.id) }
      }
      button("Delete selection and children") { [weak self] in
        self?.editGraph("Delete object") { g in g.remove(node.id) }
      }
      if let mesh = node.mesh, let asset = graph.assets.first(where: { $0.id == mesh }) {
        text(
          "\(asset.triangles.count) triangles · \(asset.subsets.count) material subsets · \(graph.nodes.filter{$0.mesh==mesh}.count) instances"
        )
      }
    } else {
      legacyObjectControls()
    }
    button("Frame all imported objects") { [weak self] in self?.frameAllAction() }
    heading("Import")
    button("Open USD scene…") { [weak self] in self?.importUSD() }
    button("Import OBJ…") { [weak self] in self?.importMesh() }
    button("Frame all imported objects") { [weak self] in
      self?.selectedNode = nil
      self?.frameMesh()
    }
    text(
      "OBJ objects, groups and usemtl subsets are preserved. Imports append. Instances share mesh assets; the current GPU bridge rebuilds a flattened BVH after edits. MTL shading and concave polygon triangulation are not supported."
    )
  }
  func showMaterialXReport() {
    let alert = NSAlert()
    alert.messageText = "MaterialX import report"
    alert.informativeText = materialXReport
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
  func importMaterialX() {
    chooseOpen("Import MaterialX material", extensions: ["mtlx"]) { [weak self] url in
      guard let self else { return }
      do {
        let imported = try MaterialXImporter.load(url)
        self.materialXReport = imported.report.joined(separator: "\n")
        guard !imported.materials.isEmpty else {
          self.showMaterialXReport()
          return
        }
        var programs = self.renderer.materials.materialX
        var graph = self.project.graph
        let useLibrary = self.renderer.sceneIndex == 6 && graph != nil && self.selectedNode != nil
        var firstSlot: Int?
        var firstID: UUID?
        for (i, program) in imported.materials.enumerated() {
          let slot: Int
          if useLibrary {
            let material = try graph!.addMaterial(program.name)
            slot = material.slot
            if i == 0 { firstID = material.id }
          } else {
            if i > 0 {
              self.materialXReport +=
                "\n\(program.name): choose an imported scene node to import multiple materials."
              continue
            }
            slot = self.selectedSlot
          }
          if firstSlot == nil { firstSlot = slot }
          programs[slot] = program
        }
        if let id = firstID,
          let index = graph?.nodes.firstIndex(where: { $0.id == self.selectedNode }),
          !graph!.nodes[index].bindings.isEmpty
        {
          graph!.nodes[index].bindings[
            min(self.selectedSubset, graph!.nodes[index].bindings.count - 1)] = id
        }
        let triangles = try graph?.renderTriangles()
        self.checkpoint("Import MaterialX")
        // Restore a candidate document so image/graph failures leave the current scene intact.
        var p = self.snapshot()
        var state = self.renderer.materials.state()
        state.materialX = programs
        p.scenes[Int(self.renderer.sceneIndex)] = state
        p.graph = graph
        _ = triangles
        try self.restore(p)
        self.selectedSlot = firstSlot ?? self.selectedSlot
        self.changed()
        self.rebuild()
        self.showMaterialXReport()
      } catch {
        self.materialXReport += "\nImport failed: " + error.localizedDescription
        self.showMaterialXReport()
      }
    }
  }
  func materialXPanel(_ program: MaterialXProgram, slot: Int) {
    heading(program.name)
    text(
      "MaterialX · \(program.source)\n\(program.instructions.count) expressions · \(program.images.count) embedded images"
    )
    text(
      "Edit constant graph inputs below. Connected expressions evaluate on every surface hit. Changes affect all objects using this material."
    )
    for parameter in program.parameters {
      let value = program.instructions[parameter.instruction].value
      for component in 0..<parameter.components {
        let label = parameter.name + (parameter.components > 1 ? " [\(component+1)]" : "")
        let range: ClosedRange<Float> = min(-10, value[component])...max(10, value[component])
        add(
          NumberControl(
            label, value: value[component], range: range,
            defaultValue: parameter.defaultValue?[component] ?? value[component]
          ) { [weak self] v in
            guard let self, !self.isBusy,
              var next = self.renderer.materials.materialX[slot]
            else { return }
            if parameter.components == 1 {
              next.instructions[parameter.instruction].value = SIMD4(repeating: v)
            } else {
              next.instructions[parameter.instruction].value[component] = v
            }
            var programs = self.renderer.materials.materialX
            programs[slot] = next
            do {
              self.checkpoint("MaterialX parameter")
              try self.renderer.materials.prepareMaterialX(programs)
              self.changed()
            } catch { self.show(error.localizedDescription) }
          })
      }
    }
    button("Save material preset…") { [weak self] in self?.saveMaterial() }
    button("Load material preset…") { [weak self] in self?.loadMaterial() }
    button("Remove graph and use manual material") { [weak self] in
      guard let self else { return }
      var programs = self.renderer.materials.materialX
      programs.removeValue(forKey: slot)
      do {
        self.checkpoint("Remove MaterialX")
        try self.renderer.materials.prepareMaterialX(programs)
        self.changed()
        self.rebuild()
      } catch { self.show(error.localizedDescription) }
    }
    text(
      "Supported: OpenPBR surface, constants, images, UV0, arithmetic, mix, clamp, extract, normalmap and limited convert. Unsupported nodes are reported at import. No USD or MaterialX graph export yet."
    )
  }
}
