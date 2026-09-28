// R-101 follow-up: USDImporter.load streams the scene graph for the orbit pivot and bounds
// (USDImporter.sceneExtent) instead of building a transient flattened host copy, and keeps
// the pivot and bounds of the earlier flattened-array computation bit for bit.
@MainActor func fixUSDPivotChecks() throws {
  typealias ViewRay = (eye: SIMD3<Float>, forward: SIMD3<Float>)
  let stride = MemoryLayout<MeshTriangle>.stride
  let folder = testOutputDirectory.appendingPathComponent("usd", isDirectory: true)
  // Heap high-water mark above a baseline, sampled on another thread while `body` runs.
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
  func peakHeap<T>(_ body: () throws -> T) rethrows -> (T, Int) {
    let sampler = HeapSampler()
    let baseline = HeapSampler.inUse()
    let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      started.signal()
      while sampler.sample() { usleep(50) }
      finished.signal()
    }
    started.wait()
    defer { finished.wait() }
    let result = try body()
    return (result, sampler.stop() - baseline)
  }
  // The computation USDImporter.load made before, on renderTriangles().
  func reference(_ triangles: [MeshTriangle], _ rays: [ViewRay]) -> (lo: SIMD3<Float>, hi: SIMD3<Float>, hits: [Float?]) {
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var hi = -lo
    for t in triangles {
      for v in [t.a, t.b, t.c] {
        let q = SIMD3(v.x, v.y, v.z)
        lo = simd_min(lo, q)
        hi = simd_max(hi, q)
      }
    }
    let hits = rays.map { ray -> Float? in
      let (eye, forward) = ray
      var nearest = Float.greatestFiniteMagnitude
      for t in triangles {
        let a = SIMD3(t.a.x, t.a.y, t.a.z)
        let e1 = SIMD3(t.b.x, t.b.y, t.b.z) - a, e2 = SIMD3(t.c.x, t.c.y, t.c.z) - a
        let p = simd_cross(forward, e2), det = simd_dot(e1, p)
        guard abs(det) > 1e-30 else { continue }
        let s = eye - a, q = simd_cross(s, e1)
        let u = simd_dot(s, p) / det, v = simd_dot(forward, q) / det, d = simd_dot(e2, q) / det
        if u >= 0, v >= 0, u + v <= 1, d > 1e-6, d < nearest { nearest = d }
      }
      return nearest < .greatestFiniteMagnitude ? nearest : nil
    }
    return (lo, hi, hits)
  }
  // Orbit distance as USDImporter.load derives it from a hit or the bounds.
  func orbit(_ ray: ViewRay, _ hit: Float?, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Float {
    let depth = simd_dot((lo + hi) / 2 - ray.eye, ray.forward)
    return min(1_000_000, max(0.0001, hit ?? (depth > 0 ? depth : simd_length(hi - lo))))
  }
  func bits(_ values: [Float?]) -> [UInt32?] { values.map { $0?.bitPattern } }

  // A heavily instanced graph: one 4,000-triangle asset, 100 visible instances (one mirrored,
  // one under a transformed parent) and a hidden one. sceneExtent equals the reference on
  // rays that hit, graze shared vertices and edges, miss, and start inside the bounds.
  do {
    var cell: [MeshTriangle] = []
    let up = SIMD4<Float>(0, 0, 1, 0)
    for i in 0..<50 {
      for j in 0..<40 {
        func v(_ x: Int, _ y: Int) -> SIMD4<Float> {
          let fx = Float(x) / 50, fy = Float(y) / 40
          return SIMD4(fx, fy, 0.08 * sin(5 * fx) * cos(4 * fy), 1)
        }
        let t = { (a: SIMD4<Float>, b: SIMD4<Float>, c: SIMD4<Float>) in
          MeshTriangle(a: a, b: b, c: c, na: up, nb: up, nc: up, uvab: .zero, uvc: SIMD4(0, 0, 0, 0))
        }
        cell += [t(v(i, j), v(i + 1, j), v(i + 1, j + 1)), t(v(i, j), v(i + 1, j + 1), v(i, j + 1))]
      }
    }
    var graph = SceneGraph()
    let material = try graph.addMaterial("Grid")
    let asset = MeshAsset(name: "grid", triangles: cell, subsets: ["Grid"])
    graph.assets.append(asset)
    var parent = SceneNode(name: "parent")
    parent.matrix = [1, 0, 0, 0, 0, 0.8, 0.6, 0, 0, -0.6, 0.8, 0, 0.25, -3, 1.5, 1]
    graph.nodes.append(parent)
    for k in 0..<101 {
      var node = SceneNode(name: "grid \(k)", mesh: asset.id, bindings: [material.id])
      node.matrix = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, Float(k % 10) * 1.25, Float(k / 10) * 1.25, Float(k % 7) * 0.1, 1]
      if k == 3 { node.matrix![0] = -1; node.matrix![12] += 1 }
      if k == 7 { node.parent = parent.id }
      if k == 100 { node.transform.rotationHidden.w = 1 }
      graph.nodes.append(node)
    }
    let rays: [ViewRay] = [
      (SIMD3(0.3, 0.45, 5), SIMD3(0, 0, -1)),
      (SIMD3(2.5 + 0.4, 1.25 + 0.5, 4), SIMD3(0, 0, -1)),  // a shared vertex
      (SIMD3(5 + 0.3, 2.5 + 0.25, 4), SIMD3(0, 0, -1)),  // a shared edge
      (SIMD3(-4, 3, 6), simd_normalize(SIMD3(1, 0.2, -0.9))),
      (SIMD3(4, 4, 4), simd_normalize(SIMD3(-0.3, -0.2, -1))),
      (SIMD3(9.5, -2.6, 5), SIMD3(0, 0, -1)),  // the rotated child
      (SIMD3(4.45, 0.5, 5), SIMD3(0, 0, -1)),  // the mirrored instance
      (SIMD3(-100, 0, 5), SIMD3(0, 0, -1)),  // a miss
      (SIMD3(5.6, 5.6, 0.05), SIMD3(0, 0, 1)),  // inside the bounds, looking up
    ]
    let count = try graph.renderTriangleCount(), copy = count * stride
    var clock = Date()
    let (extent, peak) = try peakHeap { try USDImporter.sceneExtent(graph, rays: rays) }
    let streamed = Date().timeIntervalSince(clock)
    clock = Date()
    let (expected, flattenedPeak) = try peakHeap { reference(try graph.renderTriangles(), rays) }
    let flattened = Date().timeIntervalSince(clock)
    print(String(format: "USD pivot/bounds scan (%d triangles, %d rays, %.1f MiB per flattened copy): streamed %.0f ms, heap peak +%.2f MiB; flattened reference %.0f ms, +%.2f MiB",
      count, rays.count, Double(copy) / 1_048_576, streamed * 1000, Double(peak) / 1_048_576, flattened * 1000,
      Double(flattenedPeak) / 1_048_576))
    require(count == 100 * cell.count, "instanced pivot fixture renders 100 visible instances")
    require(extent.lo == expected.lo && extent.hi == expected.hi && bits(extent.hits) == bits(expected.hits),
      "streamed pivot and bounds equal the flattened-array computation bit for bit")
    require([0, 1, 2, 5, 6, 8].allSatisfy { extent.hits[$0] != nil } && extent.hits[7] == nil,
      "pivot rays hit, miss and start inside the scene as authored")
    require(peak < copy / 8, "the pivot and bounds scan builds no flattened host copy (\(peak) of \(copy) bytes)")
    let empty = try USDImporter.sceneExtent(SceneGraph(), rays: rays)
    require(empty.lo.x > empty.hi.x && empty.hits.allSatisfy { $0 == nil }, "an empty scene has no bounds or hits")
  }

  // End to end: USDImporter.load on a stage of 240 meshes referencing one 200-triangle
  // prototype (the bridge shares identical meshes as one asset; the per-triangle Python
  // helper cost keeps the fixture small). The first camera is unsupported, so the other
  // cameras' hits must stay aligned. Views and the default camera equal the reference, and
  // the heap never holds the 48,000 flattened triangles.
  do {
    var points: [String] = [], counts: [String] = [], indices: [String] = []
    for j in 0...10 { for i in 0...10 { points.append("(\(Float(i) / 10), \(Float(j) / 10), 0)") } }
    for j in 0..<10 {
      for i in 0..<10 {
        let a = j * 11 + i
        counts.append("4")
        indices += ["\(a)", "\(a + 1)", "\(a + 12)", "\(a + 11)"]
      }
    }
    var text = """
    #usda 1.0
    (
        metersPerUnit = 1
        upAxis = "Y"
    )
    class Mesh "Proto"
    {
        int[] faceVertexCounts = [\(counts.joined(separator: ", "))]
        int[] faceVertexIndices = [\(indices.joined(separator: ", "))]
        point3f[] points = [\(points.joined(separator: ", "))]
        uniform token subdivisionScheme = "none"
    }

    """
    for k in 0..<240 {
      text += """
      def Mesh "I\(k)" (
          prepend references = </Proto>
      )
      {
          double3 xformOp:translate = (\(Double(k % 16) * 1.25), \(Double(k / 16) * 1.25), \(Double(k % 7) * 0.125))
          uniform token[] xformOpOrder = ["xformOp:translate"]
      }

      """
    }
    let cameras: [(name: String, eye: SIMD3<Float>, extra: String)] = [
      ("Narrow", SIMD3(0.5, 0.5, 5), "float focalLength = 1000\n"),
      ("Hit", SIMD3(4.0625, 2.9375, 3), ""),
      ("Vertex", SIMD3(6.75, 5.5, 2), ""),  // a shared grid vertex
      ("Miss", SIMD3(-100, 0, 5), ""),
    ]
    for camera in cameras {
      text += """
      def Camera "\(camera.name)"
      {
          \(camera.extra)double3 xformOp:translate = (\(camera.eye.x), \(camera.eye.y), \(camera.eye.z))
          uniform token[] xformOpOrder = ["xformOp:translate"]
      }

      """
    }
    let url = folder.appendingPathComponent("pivot-shared.usda")
    try Data(text.utf8).write(to: url, options: .atomic)
    let started = Date()
    let (imported, peak) = try peakHeap { try USDImporter.load(url, into: ProjectDocument()) }
    let seconds = Date().timeIntervalSince(started)
    let document = imported.document, graph = document.graph!
    let count = try graph.renderTriangleCount(), copy = count * stride
    let rays: [ViewRay] = cameras.dropFirst().map { ($0.eye, SIMD3(0, 0, -1)) }
    let expected = reference(try graph.renderTriangles(), rays)
    print(String(format: "USD shared-asset import (%d triangles, %.1f MiB per flattened copy): %.1f s, heap peak +%.2f MiB",
      count, Double(copy) / 1_048_576, seconds, Double(peak) / 1_048_576))
    require(graph.assets.count == 1 && count == 240 * 200, "USD stage shares one prototype asset (\(count))")
    require(imported.report.contains("Narrow: unsupported camera parameters") && document.views["USD: Narrow"] == nil,
      "an unsupported USD camera is reported and skipped")
    require(expected.hits[0] != nil && expected.hits[2] == nil, "pivot fixture cameras hit and miss as authored")
    for (k, camera) in cameras.dropFirst().enumerated() {
      let view = document.views["USD: " + camera.name]
      let distance = orbit(rays[k], expected.hits[k], expected.lo, expected.hi)
      require(view?.distance.bitPattern == distance.bitPattern,
        "USD \(camera.name) orbit distance matches the flattened computation (\(view?.distance ?? -1) vs \(distance))")
    }
    require(document.camera.distance == document.views["USD: Hit"]?.distance
      && document.options.focusDistance == document.camera.distance, "the first supported camera sets the orbit and focus")
    require(peak < copy / 2, "USD import builds no flattened host triangle copy (\(peak) of \(copy) bytes)")
  }

  // The existing fixture: the orbit distance equals the flattened computation exactly.
  do {
    let robust = try USDImporter.load(folder.appendingPathComponent("robust.usda"), into: ProjectDocument())
    let ray: ViewRay = (SIMD3(0.5, 0.5, 5), SIMD3(0, 0, -1))
    let expected = reference(try robust.document.graph!.renderTriangles(), [ray])
    require(robust.document.camera.distance.bitPattern == orbit(ray, expected.hits[0], expected.lo, expected.hi).bitPattern,
      "robust.usda orbit distance matches the flattened computation")
  }
  print("PASS: USD orbit pivot and bounds stream the scene graph without a flattened copy (R-101 follow-up)")
}
try fixUSDPivotChecks()
