// Renderer follow-ups: one host copy of imported triangles (R-101).
@MainActor func fixRendererFollowupsChecks() throws {
  let stride = MemoryLayout<MeshTriangle>.stride
  func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, slot: Float = 0, id: Float = 1) -> MeshTriangle {
    let up = SIMD4<Float>(0, 1, 0, 0)
    return MeshTriangle(a: SIMD4(a, 1), b: SIMD4(b, 1), c: SIMD4(c, 1), na: up, nb: up, nc: up,
      uvab: .zero, uvc: SIMD4(0, 0, slot, id))
  }
  func bytes<T>(_ values: UnsafeBufferPointer<T>) -> Data { Data(buffer: values) }
  // A curved N x N patch whose quads alternate their diagonal; every vertex is shared exactly.
  func patch(_ cells: Int, slot: Float = 0, id: Float = 1) -> (vertices: [[SIMD3<Float>]], triangles: [MeshTriangle]) {
    var vertices: [[SIMD3<Float>]] = []
    for i in 0...cells {
      vertices.append((0...cells).map { j in
        let x = Float(i) / Float(cells) * 2 - 1, z = Float(j) / Float(cells) * 2 - 1
        return SIMD3(x, 0.15 * sin(1.7 * x + 0.3) * cos(1.3 * z) + 0.05 * x, z)
      })
    }
    var triangles: [MeshTriangle] = []
    triangles.reserveCapacity(2 * cells * cells)
    for i in 0..<cells {
      for j in 0..<cells {
        let a = vertices[i][j], b = vertices[i + 1][j], c = vertices[i + 1][j + 1], d = vertices[i][j + 1]
        if (i + j) % 2 == 0 {
          triangles += [triangle(a, b, c, slot: slot, id: id), triangle(a, c, d, slot: slot, id: id)]
        } else {
          triangles += [triangle(a, b, d, slot: slot, id: id), triangle(b, c, d, slot: slot, id: id)]
        }
      }
    }
    return (vertices, triangles)
  }

  // R-101: a scene-graph mesh keeps the graph's assets and the shared GPU buffer as its only
  // triangle copies. The flattened triangles go straight into that buffer and are put into BVH
  // order there, so no flattened or reordered host array is retained or even transiently built.
  // Measured: the heap high-water mark (sampled) and the retained heap across setMesh.
  final class HeapSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true, highest = 0
    nonisolated static func inUse() -> Int {
      var statistics = malloc_statistics_t()
      malloc_zone_statistics(nil, &statistics)
      return Int(statistics.size_in_use)
    }
    nonisolated func sample() -> Bool {
      let bytes = Self.inUse()
      lock.lock(); defer { lock.unlock() }
      highest = max(highest, bytes)
      return running
    }
    nonisolated func stop() -> Int {
      _ = sample()
      lock.lock(); defer { lock.unlock() }
      running = false
      return highest
    }
  }
  do {
    let large = patch(316, slot: 0, id: 1).triangles
    var graph = SceneGraph()
    let material = try graph.addMaterial("Patch")
    let asset = MeshAsset(name: "patch", triangles: large, subsets: ["Patch"])
    graph.assets.append(asset)
    graph.nodes.append(SceneNode(name: "patch", mesh: asset.id, bindings: [material.id]))
    let count = large.count, copy = count * stride
    let library = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
    let sampler = HeapSampler()
    let baseline = HeapSampler.inUse()
    let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      started.signal()
      while sampler.sample() { usleep(50) }
      finished.signal()
    }
    started.wait()
    try library.setMesh(graph)
    let retained = HeapSampler.inUse() - baseline
    let peak = sampler.stop() - baseline
    finished.wait()
    library.hasSceneGraph = true
    print(String(format: "Scene-graph mesh (%d triangles, %.1f MiB per copy): heap peak +%.1f MiB, retained %+.1f MiB",
      count, Double(copy) / 1_048_576, Double(peak) / 1_048_576, Double(retained) / 1_048_576))
    require(library.meshTriangles.isEmpty && library.triangleCount == count && library.triangleBuffer.length == copy,
      "a scene-graph mesh retains no flattened host copy; the shared buffer holds exactly its triangles")
    require(retained < copy / 4, "publishing a scene-graph mesh retains no host triangle copy (\(retained) bytes)")
    require(peak < copy, "publishing a scene-graph mesh never builds a transient full host copy (\(peak) bytes)")
    // The in-place BVH order and nodes equal the reference build of the flattened scene.
    let (ordered, nodes) = OBJMesh.build(try graph.renderTriangles())
    let gpuNodes = UnsafeBufferPointer(start: library.nodeBuffer.contents().bindMemory(to: MeshNode.self, capacity: nodes.count),
      count: nodes.count)
    require(library.nodeCount == nodes.count && bytes(library.orderedTriangles) == ordered.withUnsafeBufferPointer(bytes)
      && bytes(gpuNodes) == nodes.withUnsafeBufferPointer(bytes), "in-place BVH ordering matches the reference build")
    // A graph-less mesh keeps the caller's array by reference (shared storage, not a copy).
    let legacy = patch(4).triangles
    let published = library.meshResources
    try library.setMesh(legacy)
    require(library.meshTriangles.withUnsafeBufferPointer { $0.baseAddress } == legacy.withUnsafeBufferPointer { $0.baseAddress }
      && library.triangleCount == legacy.count, "a legacy mesh shares the document's triangle storage")
    // Rollback rebinds the previous buffers without flattening or rebuilding.
    let builds = library.meshBuildCount
    try library.restoreMesh(published)
    require(library.triangleBuffer === published.triangleBuffer && library.nodeBuffer === published.nodeBuffer
      && library.triangleCount == count && library.meshTriangles.isEmpty && library.meshBuildCount == builds,
      "restoreMesh republishes the previous mesh buffers")
  }
  // Framing reads the published buffer: the BVH root for the whole unrotated mesh, the
  // triangles themselves for a selected object.
  do {
    var graph = SceneGraph()
    let first = try graph.addOBJ("v -1 0 0\nv 1 0 0\nv 1 2 0\nv -1 2 0\nf 1 2 3 4\n", name: "left")
    _ = try graph.addOBJ("v 3 0 -1\nv 5 0 -1\nv 5 1 -1\nf 1 2 3\n", name: "right")
    var document = ProjectDocument()
    document.scene = 6; document.graph = graph
    try controller.restore(document)
    func center(_ triangles: [MeshTriangle]) -> SIMD3<Float> {
      var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
      for t in triangles { for p in [t.a, t.b, t.c] { lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z)) } }
      return (lo + hi) / 2
    }
    let flattened = try graph.renderTriangles()
    controller.selectedNode = nil
    controller.frameMesh(recordUndo: false)
    require(simd_length(testRenderer.target - center(flattened)) < 1e-6,
      "framing the whole mesh uses the BVH root bounds")
    controller.selectedNode = first
    controller.frameMesh(recordUndo: false)
    let family = graph.descendants(of: first)
    let selected = flattened.filter { family.contains(graph.nodes[Int($0.uvc.w) - 1].id) }
    require(simd_length(testRenderer.target - center(selected)) < 1e-6, "framing a selected object uses its triangles")
    controller.selectedNode = nil
    try controller.restore(ProjectDocument())
  }
  print("PASS: fix-renderer-followups single host triangle copy and buffer-based framing (R-101)")

}
try fixRendererFollowupsChecks()
