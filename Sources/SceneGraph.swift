import Foundation
import simd

// REFERENCES.md: PBRT2023, OBJ2026, MATERIALX. Local scene model and GPU bridge.
// Stable document IDs are independent of GPU slots and BVH triangle ordering.
enum SceneLimits {
  static let materials = 64
  static let graphImages = 128
  static let nodes = 256
  static let triangles = 500_000
}
struct MeshAsset: Codable {
  var id = UUID()
  var name: String
  var triangles: [MeshTriangle]
  var subsets: [String]
}
struct SceneMaterial: Codable {
  var id = UUID()
  var name: String
  var slot: Int
}
struct SceneNode: Codable {
  var id = UUID()
  var name: String
  var parent: UUID?
  var mesh: UUID?
  var transform = ObjectSettings()
  var bindings: [UUID] = []
  var matrix: [Float]?
}
struct OBJPart {
  var object: String
  var group: String
  var triangles: [MeshTriangle] = []
  var subsets: [String] = []
}
struct SceneGraph: Codable {
  var assets: [MeshAsset] = []
  var nodes: [SceneNode] = []
  var materials: [SceneMaterial] = []

  mutating func addOBJ(_ text: String, name: String) throws -> UUID {
    let parts = try OBJMesh.parts(text)
    let root = SceneNode(name: name)
    nodes.append(root)
    var parents: [String: UUID] = [:]
    var materialIDs: [String: UUID] = [:]
    for part in parts {
      let parent: UUID
      if let existing = parents[part.object] {
        parent = existing
      } else {
        let object = SceneNode(name: part.object, parent: root.id)
        nodes.append(object)
        parents[part.object] = object.id
        parent = object.id
      }
      let asset = MeshAsset(name: part.group, triangles: part.triangles, subsets: part.subsets)
      assets.append(asset)
      var bindings: [UUID] = []
      for name in part.subsets {
        if let id = materialIDs[name] {
          bindings.append(id)
        } else {
          let material = try addMaterial(name)
          materialIDs[name] = material.id
          bindings.append(material.id)
        }
      }
      nodes.append(SceneNode(name: part.group, parent: parent, mesh: asset.id, bindings: bindings))
    }
    try validate()
    return root.id
  }
  mutating func addMaterial(_ name: String) throws -> SceneMaterial {
    let used = Set(materials.map(\.slot))
    guard let slot = (8..<SceneLimits.materials).first(where: { !used.contains($0) }) else {
      throw MaterialLibrary.error("This scene has reached the 56 imported-material limit.")
    }
    let material = SceneMaterial(name: name, slot: slot)
    materials.append(material)
    return material
  }
  func descendants(of id: UUID) -> Set<UUID> {
    var result: Set<UUID> = [id]
    for _ in 0..<nodes.count {
      let before = result.count
      for n in nodes where n.parent.map({ result.contains($0) }) == true { result.insert(n.id) }
      if result.count == before { break }
    }
    return result
  }
  mutating func instance(_ id: UUID) throws -> UUID {
    guard let source = nodes.first(where: { $0.id == id }) else {
      throw MaterialLibrary.error("Object was removed.")
    }
    let family = descendants(of: id)
    let copies = nodes.filter { family.contains($0.id) }
    let ids = Dictionary(uniqueKeysWithValues: copies.map { ($0.id, UUID()) })
    for var copy in copies {
      let old = copy.id
      copy.id = ids[old]!
      if old == id {
        copy.name += " instance"
        copy.transform.positionScale.x += 1
      } else if let p = copy.parent {
        copy.parent = ids[p]
      }
      nodes.append(copy)
    }
    try validate()
    return ids[source.id]!
  }
  mutating func remove(_ id: UUID) {
    let family = descendants(of: id)
    nodes.removeAll { family.contains($0.id) }
    let used = Set(nodes.compactMap(\.mesh))
    assets.removeAll { !used.contains($0.id) }
    pruneUnusedMaterials()
  }
  mutating func pruneUnusedMaterials() {
    let used = Set(nodes.flatMap(\.bindings))
    materials.removeAll { !used.contains($0.id) }
  }
  func validate() throws {
    func fail(_ message: String) throws { throw MaterialLibrary.error("Scene graph: " + message) }
    guard nodes.count <= SceneLimits.nodes, Set(nodes.map(\.id)).count == nodes.count,
      Set(assets.map(\.id)).count == assets.count,
      Set(materials.map(\.id)).count == materials.count,
      Set(materials.map(\.slot)).count == materials.count,
      materials.allSatisfy({ (8..<SceneLimits.materials).contains($0.slot) })
    else {
      try fail("invalid IDs or capacity.")
      return
    }
    let materialIDs = Set(materials.map(\.id))
    var triangles = 0
    var storedTriangles = 0
    for asset in assets {
      storedTriangles += asset.triangles.count
      guard !asset.subsets.isEmpty else {
        try fail("mesh has no material subsets.")
        return
      }
      for t in asset.triangles {
        guard
          [t.a, t.b, t.c, t.na, t.nb, t.nc, t.uvab, t.uvc].allSatisfy({ p in
            (0..<4).allSatisfy { p[$0].isFinite && abs(p[$0]) < 1e8 }
          }),
          t.a.w == 1, t.b.w == 1, t.c.w == 1,
          t.na.w == 0, t.nb.w == 0, t.nc.w == 0,
          t.uvc.z >= 0, t.uvc.z < Float(asset.subsets.count), t.uvc.z.rounded() == t.uvc.z
        else {
          try fail("invalid triangle or subset.")
          return
        }
      }
    }
    guard storedTriangles <= SceneLimits.triangles else {
      try fail("stored mesh assets exceed the 500,000 triangle limit.")
      return
    }
    for node in nodes {
      if let m = node.matrix {
        guard m.count == 16, m.allSatisfy({ $0.isFinite && abs($0) < 1e8 }), abs(m[3]) < 1e-6,
          abs(m[7]) < 1e-6, abs(m[11]) < 1e-6, abs(m[15] - 1) < 1e-6
        else {
          try fail("invalid imported matrix.")
          return
        }
      }
      let o = node.transform
      guard (0.01...100).contains(o.positionScale.w),
        [o.positionScale, o.rotationHidden].allSatisfy({ p in
          (0..<4).allSatisfy { p[$0].isFinite && abs(p[$0]) < 1e6 }
        })
      else {
        try fail("invalid transform.")
        return
      }
      var current: SceneNode? = node
      var visited = Set<UUID>()
      while let n = current {
        guard visited.insert(n.id).inserted else {
          try fail("parent cycle.")
          return
        }
        if let p = n.parent {
          guard let next = nodes.first(where: { $0.id == p }) else {
            try fail("missing parent.")
            return
          }
          current = next
        } else {
          current = nil
        }
      }
      if let mesh = node.mesh {
        guard let asset = assets.first(where: { $0.id == mesh }),
          node.bindings.count == asset.subsets.count,
          node.bindings.allSatisfy({ materialIDs.contains($0) })
        else {
          try fail("missing mesh or material binding.")
          return
        }
        triangles += asset.triangles.count
      }
    }
    guard triangles <= SceneLimits.triangles else {
      try fail("instances exceed the 500,000 rendered-triangle limit.")
      return
    }
  }
  func worldTransform(_ id: UUID) -> (simd_float4x4, Bool) {
    guard let node = nodes.first(where: { $0.id == id }) else {
      return (matrix_identity_float4x4, false)
    }
    let o = node.transform
    let a = SIMD3(o.rotationHidden.x, o.rotationHidden.y, o.rotationHidden.z)
    let x = rotateObject(SIMD3(o.positionScale.w, 0, 0), a)
    let y = rotateObject(SIMD3(0, o.positionScale.w, 0), a)
    let z = rotateObject(SIMD3(0, 0, o.positionScale.w), a)
    var local = simd_float4x4(
      columns: (
        SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0),
        SIMD4(o.positionScale.x, o.positionScale.y, o.positionScale.z, 1)
      ))
    if let m = node.matrix {
      local =
        local
        * simd_float4x4(
          columns: (
            SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
            SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])
          ))
    }
    if let parent = node.parent {
      let (p, hidden) = worldTransform(parent)
      return (p * local, hidden || o.rotationHidden.w > 0)
    }
    return (local, o.rotationHidden.w > 0)
  }
  // Instances share document mesh data. This initial GPU bridge flattens visible instances.
  func renderTriangles() throws -> [MeshTriangle] {
    try validate()
    var result: [MeshTriangle] = []
    let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    let slotsByID = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0.slot) })
    result.reserveCapacity(nodes.reduce(0) { $0 + ($1.mesh.flatMap { assetsByID[$0]?.triangles.count } ?? 0) })
    for (index, node) in nodes.enumerated() {
      guard let id = node.mesh, let asset = assetsByID[id] else { continue }
      let (world, hidden) = worldTransform(node.id)
      if hidden { continue }
      let scale = simd_length(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z))
      guard scale.isFinite, (0.000001...1_000_000).contains(scale) else {
        throw MaterialLibrary.error("Combined hierarchy scale exceeds the supported range.")
      }
      let determinant = simd_determinant(world)
      guard determinant.isFinite, abs(determinant) > 1e-18 else {
        throw MaterialLibrary.error("Singular USD transform.")
      }
      let normal = simd_transpose(
        simd_inverse(
          simd_float3x3(
            columns: (
              SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
              SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
              SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)
            ))))
      let slots = node.bindings.map { slotsByID[$0]! }
      for var t in asset.triangles {
        let slot = slots[Int(t.uvc.z)]
        t.a = world * t.a
        t.b = world * t.b
        t.c = world * t.c
        for key in [\MeshTriangle.na, \.nb, \.nc] {
          let p = t[keyPath: key]
          let n = normal * SIMD3(p.x, p.y, p.z)
          t[keyPath: key] = SIMD4(
            simd_length_squared(n) > 1e-12 ? simd_normalize(n) : SIMD3(0, 1, 0), 0)
        }
        if determinant < 0 {
          swap(&t.b, &t.c)
          swap(&t.nb, &t.nc)
          let uvB = SIMD2(t.uvab.z, t.uvab.w)
          t.uvab.z = t.uvc.x
          t.uvab.w = t.uvc.y
          t.uvc.x = uvB.x
          t.uvc.y = uvB.y
        }
        t.uvc.z = Float(slot)
        t.uvc.w = Float(index + 1)
        guard
          [t.a, t.b, t.c].allSatisfy({ v in
            (0..<3).allSatisfy { v[$0].isFinite && abs(v[$0]) < 1e8 }
          })
        else {
          throw MaterialLibrary.error("Hierarchy transform exceeds the supported scene extent.")
        }
        result.append(t)
      }
    }
    return result
  }
}

extension ProjectDocument {
  // Build a candidate first: failed import preserves the existing document.
  mutating func appendOBJ(_ text: String, name: String) throws -> UUID {
    var p = self
    var graph = p.graph ?? SceneGraph()
    if p.graph == nil, !p.triangles.isEmpty {
      let old = p.scenes[6] ?? SceneState()
      let material = try graph.addMaterial(p.meshName)
      var triangles = p.triangles
      for i in triangles.indices { triangles[i].uvc.z = 0 }
      let asset = MeshAsset(name: p.meshName, triangles: triangles, subsets: ["Material"])
      graph.assets.append(asset)
      graph.nodes.append(
        SceneNode(
          name: p.meshName, mesh: asset.id, transform: old.objects[7], bindings: [material.id]))
      var migrated = SceneState()
      // Pad legacy documents through the resource library before copying slot data.
      for i in old.surfaces.indices {
        migrated.surfaces[i] = old.surfaces[i]
        migrated.objects[i] = old.objects[i]
      }
      for i in old.maps.indices {
        migrated.maps[i] = old.maps[i]
        migrated.names[i] = old.names[i]
      }
      migrated.materialX = old.materialX
      migrated.surfaces[material.slot] = old.surfaces[7]
      migrated.objects[material.slot].uvTransform = old.objects[7].uvTransform
      migrated.objects[material.slot].channels = old.objects[7].channels
      for c in 0..<4 {
        migrated.maps[material.slot * 4 + c] = old.maps[28 + c]
        migrated.names[material.slot * 4 + c] = old.names[28 + c]
      }
      if let program = old.materialX?[7] {
        if migrated.materialX == nil { migrated.materialX = [:] }
        migrated.materialX?[material.slot] = program
      }
      p.scenes[6] = migrated
    }
    let root = try graph.addOBJ(
      text, name: name)
    p.graph = graph
    p.triangles = []
    p.meshName = "\(graph.assets.count) meshes"
    p.scene = 6
    p.version = 2
    self = p
    return root
  }
}
