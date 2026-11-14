import Cocoa
import simd

enum GraphEditKind {
  case metadata
  case bindings
  case geometry
}

// Imported scenes (a scene graph in the Imported Mesh Studio): the hierarchy popup, material bindings, the Objects
// tab's node controls, and MaterialX import and parameters.
extension StudioController {
  // The Object popup of imported scenes: the studio floor, then the hierarchy indented by depth (▸ groups, ◇ meshes).
  func selectGraphNode() {
    guard let graph = project.graph else { return }
    if !graph.nodes.contains(where: { $0.id == selectedNode }) {
      selectedNode = nil
      selectedSlot = 1
    }
    var ordered: [(SceneNode, Int)] = []
    var children: [UUID?: [SceneNode]] = [:]
    for n in graph.nodes { children[n.parent, default: []].append(n) }
    func visit(_ parent: UUID?, _ depth: Int) {
      for n in children[parent] ?? [] {
        ordered.append((n, depth))
        visit(n.id, depth + 1)
      }
    }
    visit(nil, 0)
    popupRow(
      "Object",
      ["Studio floor"]
        + ordered.map {
          String(repeating: "  ", count: $0.1) + ($0.0.mesh == nil ? "▸ " : "◇ ") + $0.0.name
        },
      selectedNode.flatMap { id in ordered.firstIndex(where: { $0.0.id == id }).map { $0 + 1 } } ?? 0
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
    }.setAccessibilityLabel("Scene object")
  }
  // The selected node's material: a mesh's face subset and the material assigned to it, or (for a group) any
  // material of the scene; then New Material and Remove Unused Materials.
  func graphBindings() {
    guard let graph = project.graph, let node = graph.nodes.first(where: { $0.id == selectedNode })
    else { return }
    if let mesh = node.mesh, let asset = graph.assets.first(where: { $0.id == mesh }) {
      selectedSubset = min(max(0, selectedSubset), asset.subsets.count - 1)
      popupRow("Subset", asset.subsets, selectedSubset, help: "A face group of the selected mesh.") { [weak self] i in
        guard let self else { return }
        self.selectedSubset = i
        self.selectedSlot = graph.materials.first(where: { $0.id == node.bindings[i] })?.slot ?? 1
        self.rebuild()
      }.setAccessibilityLabel("Material subset")
      let binding = node.bindings[selectedSubset]
      selectedSlot = graph.materials.first(where: { $0.id == binding })?.slot ?? 1
      popupRow(
        "Assigned material", graph.materials.map(\.name), graph.materials.firstIndex(where: { $0.id == binding }) ?? 0,
        help: "The material of this subset. Material edits apply to every subset assigned to the same material."
      ) { [weak self] i in
        guard let self else { return }
        let subset = self.selectedSubset
        self.editGraph("Assign material", kind: .bindings) { g in
          let index = try g.nodeIndex(node.id)
          guard g.nodes[index].bindings.indices.contains(subset), g.materials.indices.contains(i)
          else { throw MaterialLibrary.error("Object was removed.") }
          g.nodes[index].bindings[subset] = g.materials[i].id
        }
      }.setAccessibilityLabel("Subset material")
    } else {
      popupRow(
        "Material", graph.materials.map(\.name), graph.materials.firstIndex(where: { $0.slot == selectedSlot }) ?? 0,
        help: "Choose a material to edit. Select a mesh to assign materials to its subsets."
      ) { [weak self] i in
        self?.selectedSlot = graph.materials[i].slot
        self?.rebuild()
      }
    }
    let new = ActionButton("New Material") { [weak self] in
      guard let self else { return }
      let subset = self.selectedSubset
      self.editGraph("New material", kind: .bindings) { g in
        let m = try g.addMaterial("Material \(g.materials.count+1)")
        if let i = g.nodes.firstIndex(where: { $0.id == node.id }),
          g.nodes[i].bindings.indices.contains(subset)
        {
          g.nodes[i].bindings[subset] = m.id
        }
        self.selectedSlot = m.slot
      }
    }
    new.toolTip = node.mesh == nil
      ? "Adds a material to the scene." : "Adds a material and assigns it to the selected subset."
    // Object deletion keeps unassigned materials; this removes them explicitly.
    if graph.materials.contains(where: { m in !graph.nodes.contains { $0.bindings.contains(m.id) } }) {
      let prune = ActionButton("Remove Unused Materials") { [weak self] in
        self?.editGraph("Remove unused materials", kind: .bindings) { g in g.pruneUnusedMaterials() }
      }
      prune.toolTip = "Removes the materials no object uses."
      buttonRow([new, prune])
    } else {
      buttonRow([new])
    }
  }
  func editGraph(_ title: String, kind: GraphEditKind = .geometry,
                 _ edit: (inout SceneGraph) throws -> Void) {
    guard acceptsEdits, var graph = project.graph else { return }
    let previousState = renderer.materials.state()
    let previousMesh = renderer.materials.meshResources
    do {
      let previousMaterials = graph.materials
      try edit(&graph)
      try graph.validate()
      // Registered only after the resources and document are published.
      let record = undoRecord(title)
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
          state.emitterLights?.removeValue(forKey: slot)
        }
        try renderer.materials.restore(state)
      }
      if kind == .geometry { try renderer.materials.setMesh(graph) }
      else if kind == .bindings { try renderer.materials.setMeshBindings(graph) }
      renderer.materials.hasSceneGraph = true
      project.graph = graph
      commit(record)
      changed(reset: kind != .metadata)
      rebuild()
    } catch {
      // Resource publication is transactional at the library level; this also
      // rolls back a multi-step material-prune plus geometry edit.
      var rollbackFailures: [String] = []
      do { try renderer.materials.restore(previousState) }
      catch { rollbackFailures.append("materials: \(error.localizedDescription)") }
      do { try renderer.materials.restoreMesh(previousMesh) }
      catch { rollbackFailures.append("mesh: \(error.localizedDescription)") }
      renderer.materials.hasSceneGraph = project.graph != nil
      if rollbackFailures.isEmpty {
        showError(error.localizedDescription)
      } else {
        showError("\(error.localizedDescription) Rollback also failed (\(rollbackFailures.joined(separator: "; "))).")
      }
    }
  }
  // The Objects tab on imported scenes. Graph edits rebuild the flattened mesh (and its acceleration structure), so
  // number fields here commit once, on release or on entry, each one undo step through editGraph.
  func graphObjectPanel() {
    section("Selection")
    selectGraphNode()
    if project.importReport != nil {
      button("Import Report…") { [weak self] in self?.showUSDReport() }
    }
    guard let graph = project.graph, let node = graph.nodes.first(where: { $0.id == selectedNode }) else {
      // The studio floor: a built-in surface.
      legacyObjectControls()
      objectActions(node: nil)
      return
    }
    let o = node.transform
    visibilityToggle(hidden: o.rotationHidden.w > 0, help: "Hiding an object also hides its children.") {
      [weak self] hidden in
      self?.editGraph("Visibility") { g in
        g.nodes[try g.nodeIndex(node.id)].transform.rotationHidden.w = hidden ? 1 : 0
      }
    }
    let family = graph.descendants(of: node.id)
    let parents = graph.nodes.filter { !family.contains($0.id) }
    popupRow(
      "Parent", ["Scene root"] + parents.map(\.name),
      node.parent.flatMap { id in parents.firstIndex(where: { $0.id == id }).map { $0 + 1 } } ?? 0,
      help: "Transforms are relative to the parent. Changing the parent keeps the local values."
    ) { [weak self] i in
      self?.editGraph("Change parent") { g in
        g.nodes[try g.nodeIndex(node.id)].parent = i == 0 ? nil : parents[i - 1].id
      }
    }
    button("Rename…") { [weak self] in
      guard let self, self.acceptsEdits, let window = self.hostWindow else { return }
      let alert = NSAlert()
      alert.messageText = "Object name"
      let field = NSTextField(string: node.name)
      field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
      alert.accessoryView = field
      alert.addButton(withTitle: "Rename")
      alert.addButton(withTitle: "Cancel")
      // A sheet keeps project I/O from finishing inside a nested modal loop; editGraph
      // re-checks busy state and resolves the node against the graph current at return.
      alert.beginSheetModal(for: window) { [weak self] response in
        guard response == .alertFirstButtonReturn,
          !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        self?.editGraph("Rename object", kind: .metadata) { g in
          g.nodes[try g.nodeIndex(node.id)].name = field.stringValue
        }
      }
    }
    if let mesh = node.mesh, let asset = graph.assets.first(where: { $0.id == mesh }) {
      let instances = graph.nodes.filter { $0.mesh == mesh }.count
      hint(
        "\(asset.geometry.count) triangles · \(asset.subsets.count) subset\(asset.subsets.count == 1 ? "" : "s")"
          + " · \(instances) instance\(instances == 1 ? "" : "s")")
    }
    section("Transform")
    let relative = "Relative to the parent."
    add(
      VectorControl(
        "Translation", value: SIMD3(o.positionScale.x, o.positionScale.y, o.positionScale.z), range: -100...100,
        defaultValue: .zero, help: relative
      ) { [weak self] v in
        self?.editGraph("Translation") { g in
          let i = try g.nodeIndex(node.id)
          g.nodes[i].transform.positionScale = SIMD4(v, g.nodes[i].transform.positionScale.w)
        }
      })
    add(
      VectorControl(
        "Rotation, °", value: SIMD3(o.rotationHidden.x, o.rotationHidden.y, o.rotationHidden.z) * 180 / .pi,
        range: -180...180, defaultValue: .zero, step: 1, help: relative
      ) { [weak self] v in
        self?.editGraph("Rotation, °") { g in
          let i = try g.nodeIndex(node.id)
          g.nodes[i].transform.rotationHidden = SIMD4(v * .pi / 180, g.nodes[i].transform.rotationHidden.w)
        }
      })
    add(
      NumberControl("Scale", value: o.positionScale.w, range: 0.01...100, defaultValue: 1, help: "Uniform scale.") {
        [weak self] v in
        self?.editGraph("Scale") { g in g.nodes[try g.nodeIndex(node.id)].transform.positionScale.w = v }
      })
    button("Reset Transform") { [weak self] in
      self?.editGraph("Reset transform") { g in
        let i = try g.nodeIndex(node.id)
        // The visibility shares the rotation vector and survives the reset.
        let hidden = g.nodes[i].transform.rotationHidden.w
        g.nodes[i].transform = ObjectSettings()
        g.nodes[i].transform.rotationHidden.w = hidden
      }
    }
    objectActions(node: node)
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
      self?.beginImportMaterialX(from: url)
    }
  }
  // Parsing, graph compilation and image decoding run on projectIOQueue. The candidate
  // reuses the live maps and mesh, so a new binding only rebinds triangle slots.
  func beginImportMaterialX(from url: URL) {
    guard !isBusy else { return }
    struct NoMaterials: Error { let report: String }
    let record = undoRecord("Import MaterialX")
    let document = snapshot()
    let scene = Int(renderer.sceneIndex)
    let selectedNode = self.selectedNode, selectedSubset = self.selectedSubset
    let selectedSlot = self.selectedSlot
    let useLibrary = scene == 6 && document.graph != nil && selectedNode != nil
    beginDocumentChange("Importing \(url.lastPathComponent)…", build: { _ -> (ProjectDocument, (String, Int?)) in
      var document = document  // The build runs on projectIOQueue with its own copy.
      let imported = try MaterialXImporter.load(url)
      var report = imported.report.joined(separator: "\n")
      guard !imported.materials.isEmpty else { throw NoMaterials(report: report) }
      var state = document.scenes[scene] ?? SceneState()
      var programs = state.materialX ?? [:]
      var graph = document.graph
      var firstSlot: Int?
      var firstID: UUID?
      for (i, program) in imported.materials.enumerated() {
        let slot: Int
        if useLibrary, var library = graph {
          let material = try library.addMaterial(program.name)
          graph = library
          slot = material.slot
          if i == 0 { firstID = material.id }
        } else {
          if i > 0 {
            report += "\n\(program.name): choose an imported scene node to import multiple materials."
            continue
          }
          slot = selectedSlot
        }
        if firstSlot == nil { firstSlot = slot }
        programs[slot] = program
      }
      if let id = firstID, var library = graph,
        let index = library.nodes.firstIndex(where: { $0.id == selectedNode }),
        !library.nodes[index].bindings.isEmpty
      {
        library.nodes[index].bindings[min(selectedSubset, library.nodes[index].bindings.count - 1)] = id
        graph = library
      }
      state.materialX = programs
      document.scenes[scene] = state
      document.graph = graph
      return (document, (report, firstSlot))
    }) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let (report, firstSlot)):
        self.materialXReport = report
        self.commit(record)
        self.selectedSlot = firstSlot ?? self.selectedSlot
        self.changed()
        self.rebuild()
      case .failure(let empty as NoMaterials):
        self.materialXReport = empty.report
      case .failure(let error):
        self.materialXReport = "Import failed: " + error.localizedDescription
      }
      self.showMaterialXReport()
    }
  }
  // A MaterialX material's constant graph inputs, one row per parameter: three-component values (colours, vectors) as
  // one R/G/B or X/Y/Z row, scalars as number rows. Every edit recompiles the material, so rows commit on release
  // or entry, each one "MaterialX parameter" undo step.
  func materialXPanel(_ program: MaterialXProgram, slot: Int) {
    section("MaterialX graph")
    hint("\(program.name) · \(program.instructions.count) expressions · \(program.images.count) images")
    let names = Self.materialXDisplayNames(program.parameters.map(\.name))
    for (parameter, name) in zip(program.parameters, names) {
      let value = program.instructions[parameter.instruction].value
      let fallback = parameter.defaultValue ?? value
      let components = (0..<min(4, max(1, parameter.components))).map { value[$0] }
      // 0…1 weights get a 0…1 slider; typed values may go to ±10 (or beyond, to the current value).
      let entry = min(-10, components.min()!)...max(10, components.max()!)
      let unit = components.allSatisfy { (0...1).contains($0) } && (0..<components.count).allSatisfy {
        (0...1).contains(fallback[$0])
      }
      let range = unit ? 0...1 : entry
      let help = "MaterialX input \(parameter.name). Changes apply to every object using this material."
      let instruction = parameter.instruction
      if parameter.components == 3 {
        // Parameters carry no MaterialX type; colours are recognised by name.
        let port = parameter.name.split(separator: "/").last.map { $0.lowercased() } ?? ""
        let color = ["color", "colour", "tint", "albedo"].contains { port.contains($0) }
        add(
          VectorControl(
            name, value: SIMD3(value.x, value.y, value.z), range: range,
            defaultValue: SIMD3(fallback.x, fallback.y, fallback.z), labels: color ? ["R", "G", "B"] : ["X", "Y", "Z"],
            entry: entry, step: unit ? 0.01 : nil, help: help
          ) { [weak self] v in
            self?.materialXCommit(slot: slot, instruction: instruction) { $0.x = v.x; $0.y = v.y; $0.z = v.z }
          })
        continue
      }
      let letters = parameter.components == 4 ? ["R", "G", "B", "A"] : ["X", "Y"]
      for component in components.indices {
        add(
          NumberControl(
            name + (parameter.components > 1 ? " " + letters[component] : ""), value: value[component], range: range,
            defaultValue: fallback[component], entry: entry, step: unit ? 0.01 : nil, help: help
          ) { [weak self] v in
            self?.materialXCommit(slot: slot, instruction: instruction) { value in
              if parameter.components == 1 { value = SIMD4(repeating: v) } else { value[component] = v }
            }
          })
      }
    }
  }
  // Recompiles the material with one edited constant; one undo step once the program is prepared.
  func materialXCommit(slot: Int, instruction: Int, _ edit: (inout SIMD4<Float>) -> Void) {
    guard acceptsEdits, var next = renderer.materials.materialX[slot] else { return }
    edit(&next.instructions[instruction].value)
    var programs = renderer.materials.materialX
    programs[slot] = next
    do {
      let record = undoRecord("MaterialX parameter")
      try renderer.materials.prepareMaterialX(programs)
      commit(record)
      changed()
    } catch { showError(error.localizedDescription) }
  }
  func removeMaterialX(_ slot: Int) {
    guard !isBusy else { return }
    var programs = renderer.materials.materialX
    programs.removeValue(forKey: slot)
    do {
      let record = undoRecord("Remove MaterialX")
      try renderer.materials.prepareMaterialX(programs)
      commit(record)
      changed()
      rebuild()
    } catch { showError(error.localizedDescription) }
  }
  // Port names that say little without their node ("Mix" of which node?): these keep the node name.
  nonisolated static let genericMaterialXPorts: Set<String> = [
    "value", "in", "in1", "in2", "in3", "in4", "fg", "bg", "mix", "low", "high", "amount", "default", "input",
  ]
  // Readable names for MaterialX parameter paths ("Paint/base_color" → "Base color"): the shortest trailing part of
  // the path that is unique within the material (at least the node and port for generic ports such as "in1"),
  // underscores as spaces ("ior" as "IOR"), parts joined by " › ", in sentence case.
  nonisolated static func materialXDisplayNames(_ paths: [String]) -> [String] {
    let parts = paths.map { $0.split(separator: "/").map(String.init) }
    return parts.indices.map { i in
      let path = parts[i]
      guard !path.isEmpty else { return paths[i] }
      var count = genericMaterialXPorts.contains(path.last!.lowercased()) ? min(2, path.count) : 1
      while count < path.count,
        parts.indices.contains(where: { j in j != i && parts[j].suffix(count) == path.suffix(count) })
      {
        count += 1
      }
      let text = path.suffix(count).map { part in
        part.split(separator: "_").map { $0 == "ior" ? "IOR" : String($0) }.joined(separator: " ")
      }.joined(separator: " › ")
      return text.prefix(1).uppercased() + text.dropFirst()
    }
  }
}

