import Foundation
import Metal
import simd

// REFERENCES.md: WALD2007 (binned SAH), WIDEBVH2008 (4-wide nodes), PBRT2023 (instancing),
// WOOP2013 (conservative traversal). The imported-mesh acceleration structure.
//
// Two levels (the default): every mesh asset is stored once in object space with its own
// 4-wide bounding volume hierarchy (BLAS), and a small top level (TLAS) bounds the visible
// scene-graph instances in world space. Transform, visibility and binding edits rebuild only
// the top level; geometry edits rebuild only the assets whose triangles changed. `flat` is the
// earlier renderer path, one median-split binary BVH over flattened world-space triangles,
// kept as the reference the tests compare against.
// `hardware` is the two-level layout traced by Metal's intersector (METALRT): the same
// instances and stored triangles, with one primitive acceleration structure per asset and an
// instance acceleration structure over the instances. Its watertightness is not documented by
// Apple, so it is gated by tests/Fix_accel.swift and is not the default.
enum MeshAcceleration: Equatable, Sendable { case twoLevel, flat, hardware }

// 128 bytes, the MeshTriangle stride, so BLAS nodes share the triangle buffer. Child k is an
// inner node (> 0, index relative to the hierarchy's first node), a leaf (< 0: -(first + 1)
// with count[k] items, relative to the hierarchy's first item) or empty (0).
struct MeshWideNode {
  var lox, loy, loz, hix, hiy, hiz: SIMD4<Float>
  var child: SIMD4<Int32>
  var count: SIMD4<Int32>
  static let empty = MeshWideNode(
    lox: SIMD4(repeating: 0), loy: SIMD4(repeating: 0), loz: SIMD4(repeating: 0),
    hix: SIMD4(repeating: 0), hiy: SIMD4(repeating: 0), hiz: SIMD4(repeating: 0), child: .zero, count: .zero)
}
// One visible scene-graph node (MSL MeshInstance, 144 bytes). world/local are the rows of the
// object-to-world matrix and its inverse (x = dot(row.xyz, p) + row.w).
struct MeshInstanceRecord {
  var world0, world1, world2: SIMD4<Float>
  var local0, local1, local2: SIMD4<Float>
  // Asset's first triangle, its first BLAS node (both in the triangle buffer), the first
  // rendered-triangle ID of this instance, the asset's triangle count.
  var range: SIMD4<UInt32>
  // First slot-table entry, graph node index + 1 (0: keep the stored slot and ID), flags
  // (1: mirrored, the flattened b/c swap), 0.
  var binding: SIMD4<UInt32>
  // max |translation|, infinity norm of the linear part, the asset's max |local coordinate|, 0.
  var bound: SIMD4<Float>
}
// First 80 bytes of the node buffer in two-level mode. info.w lands on MeshNode.lo.w, which a
// flat BVH always leaves 0, so the shader tells the layouts apart from one load.
struct MeshSceneHeader {
  var info: SIMD4<UInt32>  // instance count, TLAS offset and slot-table offset (16-byte units), magic
  var counts: SIMD4<UInt32>  // rendered triangles, stored triangles, TLAS nodes, 1 = hardware traversal
  var lo: SIMD4<Float>  // world bounds; lo.w = TLAS enlargement factor 2^-18 (1 + max condition number)
  var hi: SIMD4<Float>  // hi.w = max over instances of |translation| + |linear| * |local coordinates|
  var accelerator: SIMD4<UInt32>  // .xy: the instance acceleration structure's MTLResourceID (hardware)
  static let magic: UInt32 = 0x3256_544C
}

// Top-down binned-SAH build of a 4-wide BVH: each node repeatedly splits its child with the
// largest surface area (binned SAH over the three axes) until it has four children. Large
// builds finish their subtrees in parallel; the result does not depend on the thread count.
enum WideBVH {
  static let bins = 16
  // A BLAS traversal stack holds 64 entries and a node pushes at most 3 besides the one it
  // pops; the TLAS stack holds 32 (depth 10).
  static let maximumDepth = 20, maximumTopDepth = 10

  struct Result {
    var order: [Int32]  // item order of the leaves (ordered[i] = input[order[i]])
    var nodes: [MeshWideNode]
    var depth: Int
  }
  fileprivate struct Range {
    var start: Int, end: Int
    var lo: SIMD3<Float>, hi: SIMD3<Float>  // item bounds
    var clo: SIMD3<Float>, chi: SIMD3<Float>  // centroid bounds
    var count: Int { end - start }
    var area: Float { WideBVH.area(lo, hi) }
  }
  fileprivate static func area(_ l: SIMD3<Float>, _ h: SIMD3<Float>) -> Float {
    let e = simd_max(h - l, .zero)
    return e.x * e.y + e.y * e.z + e.z * e.x
  }
  // Per-thread scratch and the item arrays it partitions (disjoint ranges per thread).
  fileprivate final class Builder {
    let bounds: UnsafePointer<Float>
    let order: UnsafeMutablePointer<Int32>
    let leafSize: Int, median: Bool
    // Bins of the three axes: item bounds, centroid bounds, counts; suffix SAH costs.
    let binLo: UnsafeMutablePointer<SIMD3<Float>>, binHi: UnsafeMutablePointer<SIMD3<Float>>
    let binCLo: UnsafeMutablePointer<SIMD3<Float>>, binCHi: UnsafeMutablePointer<SIMD3<Float>>
    let binCount: UnsafeMutablePointer<Int>, suffix: UnsafeMutablePointer<Float>
    init(bounds: UnsafePointer<Float>, order: UnsafeMutablePointer<Int32>, leafSize: Int, median: Bool) {
      self.bounds = bounds; self.order = order; self.leafSize = leafSize; self.median = median
      let n = 3 * WideBVH.bins
      binLo = .allocate(capacity: n); binHi = .allocate(capacity: n)
      binCLo = .allocate(capacity: n); binCHi = .allocate(capacity: n)
      binCount = .allocate(capacity: n); suffix = .allocate(capacity: WideBVH.bins)
    }
    deinit {
      binLo.deallocate(); binHi.deallocate(); binCLo.deallocate(); binCHi.deallocate()
      binCount.deallocate(); suffix.deallocate()
    }

    @inline(__always) func lo(_ i: Int) -> SIMD3<Float> { SIMD3(bounds[6 * i], bounds[6 * i + 1], bounds[6 * i + 2]) }
    @inline(__always) func hi(_ i: Int) -> SIMD3<Float> { SIMD3(bounds[6 * i + 3], bounds[6 * i + 4], bounds[6 * i + 5]) }
    func measure(_ start: Int, _ end: Int) -> Range {
      let big = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
      var r = Range(start: start, end: end, lo: big, hi: -big, clo: big, chi: -big)
      for k in start..<end {
        let i = Int(order[k]), l = lo(i), h = hi(i), c = (l + h) * 0.5
        r.lo = simd_min(r.lo, l); r.hi = simd_max(r.hi, h)
        r.clo = simd_min(r.clo, c); r.chi = simd_max(r.chi, c)
      }
      return r
    }
    // Splits r into two non-empty ranges, reordering its items in place.
    func split(_ r: Range) -> (Range, Range) {
      let extent = r.chi - r.clo, bins = WideBVH.bins
      if !median, simd_reduce_max(extent) > 0 {
        let big = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        let scale = SIMD3<Float>(
          extent.x > 0 ? Float(bins) / extent.x : 0, extent.y > 0 ? Float(bins) / extent.y : 0,
          extent.z > 0 ? Float(bins) / extent.z : 0)
        let top = SIMD3<Int>(repeating: bins - 1)
        let bl = binLo, bh = binHi, cl = binCLo, ch = binCHi, bc = binCount, sa = suffix
        for k in 0..<(3 * bins) { bl[k] = big; bh[k] = -big; cl[k] = big; ch[k] = -big; bc[k] = 0 }
        for k in r.start..<r.end {
          let i = Int(order[k]), l = lo(i), h = hi(i), c = (l + h) * 0.5
          let f = (c - r.clo) * scale
          let b = simd_clamp(SIMD3<Int>(Int(f.x), Int(f.y), Int(f.z)), .zero, top)
          let slots = SIMD3<Int>(b.x, bins + b.y, 2 * bins + b.z)
          for a in 0..<3 {
            let s = slots[a]
            bc[s] += 1
            bl[s] = simd_min(bl[s], l); bh[s] = simd_max(bh[s], h)
            cl[s] = simd_min(cl[s], c); ch[s] = simd_max(ch[s], c)
          }
        }
        var bestCost = Float.greatestFiniteMagnitude, best = -1, bin = 0
        for a in 0..<3 where scale[a] > 0 {
          var l = big, h = -big, count = 0
          for b in stride(from: bins - 1, to: 0, by: -1) {
            let k = a * bins + b
            if bc[k] > 0 { l = simd_min(l, bl[k]); h = simd_max(h, bh[k]) }
            count += bc[k]
            sa[b] = count > 0 ? WideBVH.area(l, h) * Float(count) : 0
          }
          l = big; h = -big; count = 0
          for b in 0..<(bins - 1) {
            let k = a * bins + b
            if bc[k] > 0 { l = simd_min(l, bl[k]); h = simd_max(h, bh[k]) }
            count += bc[k]
            if count == 0 || count == r.count { continue }
            let cost = WideBVH.area(l, h) * Float(count) + sa[b + 1]
            if cost < bestCost { bestCost = cost; best = a; bin = b }
          }
        }
        if best >= 0 {
          let s = scale[best], origin = r.clo[best]
          var i = r.start, j = r.end - 1
          while i <= j {
            let t = Int(order[i])
            let c = (bounds[6 * t + best] + bounds[6 * t + 3 + best]) * 0.5
            if min(bins - 1, max(0, Int((c - origin) * s))) <= bin { i += 1 } else { let x = order[i]; order[i] = order[j]; order[j] = x; j -= 1 }
          }
          if i > r.start && i < r.end {
            // Child bounds come from the bins; no second pass over the items.
            var left = Range(start: r.start, end: i, lo: big, hi: -big, clo: big, chi: -big)
            var right = Range(start: i, end: r.end, lo: big, hi: -big, clo: big, chi: -big)
            for b in 0..<bins where binCount[best * bins + b] > 0 {
              let k = best * bins + b
              if b <= bin {
                left.lo = simd_min(left.lo, binLo[k]); left.hi = simd_max(left.hi, binHi[k])
                left.clo = simd_min(left.clo, binCLo[k]); left.chi = simd_max(left.chi, binCHi[k])
              } else {
                right.lo = simd_min(right.lo, binLo[k]); right.hi = simd_max(right.hi, binHi[k])
                right.clo = simd_min(right.clo, binCLo[k]); right.chi = simd_max(right.chi, binCHi[k])
              }
            }
            return (left, right)
          }
        }
      }
      // Coincident centroids or balanced mode: an object median on the widest centroid axis.
      let middle = (r.start + r.end) / 2
      if simd_reduce_max(extent) > 0 {
        let a = extent.x > extent.y ? (extent.x > extent.z ? 0 : 2) : (extent.y > extent.z ? 1 : 2)
        let b = bounds
        var slice = UnsafeMutableBufferPointer(start: order + r.start, count: r.count)
        slice.sort { x, y in
          let cx = b[6 * Int(x) + a] + b[6 * Int(x) + 3 + a], cy = b[6 * Int(y) + a] + b[6 * Int(y) + 3 + a]
          return cx == cy ? x < y : cx < cy
        }
      }
      return (measure(r.start, middle), measure(middle, r.end))
    }
    // Builds the subtree of `root` into `nodes` (indices local to `nodes`). Items with fewer than
    // `defer` triangles are left for later when `deferred` is given.
    func run(_ root: Range, depth: Int, nodes: inout [MeshWideNode], deferThreshold: Int = 0,
                      deferred: inout [(Range, Int, Int, Int)]) -> Int {
      var depthReached = depth
      var work: [(Range, Int, Int, Int)] = [(root, -1, 0, depth)]
      while let (range, parent, slot, level) = work.popLast() {
        depthReached = max(depthReached, level)
        var children = [range]
        while children.count < 4 {
          var best = -1
          // Balanced mode splits the most populous child, which bounds the depth.
          for (k, c) in children.enumerated() where c.count > leafSize {
            if best < 0 || (median ? c.count > children[best].count : c.area > children[best].area) { best = k }
          }
          if best < 0 { break }
          let (a, b) = split(children[best])
          children[best] = a
          children.insert(b, at: best + 1)
        }
        var node = MeshWideNode.empty
        let index = nodes.count
        if parent >= 0 { nodes[parent].child[slot] = Int32(index) }
        for (k, c) in children.enumerated() {
          node.lox[k] = c.lo.x; node.loy[k] = c.lo.y; node.loz[k] = c.lo.z
          node.hix[k] = c.hi.x; node.hiy[k] = c.hi.y; node.hiz[k] = c.hi.z
          if c.count <= leafSize {
            node.child[k] = -Int32(c.start + 1)
            node.count[k] = Int32(c.count)
          }
        }
        nodes.append(node)
        // Depth-first order keeps a subtree's nodes together.
        for k in stride(from: children.count - 1, through: 0, by: -1) where children[k].count > leafSize {
          if children[k].count < deferThreshold { deferred.append((children[k], index, k, level + 1)) }
          else { work.append((children[k], index, k, level + 1)) }
        }
      }
      return depthReached
    }
  }

  // Disjoint per-task regions of the build's arrays.
  private struct Shared: @unchecked Sendable {
    let bounds: UnsafePointer<Float>
    let order: UnsafeMutablePointer<Int32>
    let parts: UnsafeMutablePointer<[MeshWideNode]>
    let depths: UnsafeMutablePointer<Int>
  }
  // `bounds` holds 6 floats per item: lo xyz, hi xyz. `depth` bounds the node depth (the
  // shader's stack): a deeper SAH tree is rebuilt with balanced median splits.
  static func build(bounds: UnsafeBufferPointer<Float>, count n: Int, leafSize: Int, depth: Int = maximumDepth) -> Result {
    var result = build(bounds: bounds, count: n, leafSize: leafSize, median: false)
    if result.depth > depth { result = build(bounds: bounds, count: n, leafSize: leafSize, median: true) }
    return result
  }

  private static func build(bounds: UnsafeBufferPointer<Float>, count n: Int, leafSize: Int, median: Bool) -> Result {
    guard n > 0, let base = bounds.baseAddress else { return Result(order: [], nodes: [], depth: 0) }
    var order = [Int32](unsafeUninitializedCapacity: n) { buffer, initialized in
      for i in 0..<n { buffer[i] = Int32(i) }
      initialized = n
    }
    let built = order.withUnsafeMutableBufferPointer { o -> Result in
      let items = o.baseAddress!
      let builder = Builder(bounds: base, order: items, leafSize: leafSize, median: median)
      var nodes: [MeshWideNode] = []
      var deferred: [(Range, Int, Int, Int)] = []
      // Subtrees below a sixteenth of a large build are finished concurrently.
      let threshold = n >= 65_536 ? n / 16 : 0
      if threshold == 0 { nodes.reserveCapacity(max(1, n / (3 * leafSize))) }
      var depth = builder.run(builder.measure(0, n), depth: 1, nodes: &nodes, deferThreshold: threshold, deferred: &deferred)
      if !deferred.isEmpty {
        let tasks = deferred
        var parts = [[MeshWideNode]](repeating: [], count: tasks.count)
        var depths = [Int](repeating: 0, count: tasks.count)
        parts.withUnsafeMutableBufferPointer { partBuffer in
          depths.withUnsafeMutableBufferPointer { depthBuffer in
            // Each task reads the shared bounds and partitions only its own item range.
            let shared = Shared(
              bounds: base, order: items, parts: partBuffer.baseAddress!, depths: depthBuffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: tasks.count) { t in
              let local = Builder(bounds: shared.bounds, order: shared.order, leafSize: leafSize, median: median)
              var subtree: [MeshWideNode] = [], none: [(Range, Int, Int, Int)] = []
              shared.depths[t] = local.run(tasks[t].0, depth: tasks[t].3, nodes: &subtree, deferred: &none)
              shared.parts[t] = subtree
            }
          }
        }
        // Append each subtree (depth-first per subtree) and rebase its inner links, releasing
        // each part as it is copied.
        nodes.reserveCapacity(nodes.count + parts.reduce(0) { $0 + $1.count })
        for t in parts.indices {
          let offset = Int32(nodes.count)
          nodes[tasks[t].1].child[tasks[t].2] = offset
          for var node in parts[t] {
            for k in 0..<4 where node.child[k] > 0 { node.child[k] += offset }
            nodes.append(node)
          }
          parts[t] = []
          depth = max(depth, depths[t])
        }
      }
      return Result(order: [], nodes: nodes, depth: depth)
    }
    return Result(order: order, nodes: built.nodes, depth: built.depth)
  }
}

// The published two-level structure, described on the host for emitter lists, framing,
// rendered-triangle lookups and edit reuse. Immutable once published.
struct MeshSceneLayout {
  struct Asset {
    var id: UUID
    // The document's own triangle array, retained by reference (shared storage, not a copy)
    // so the next publish can tell unchanged assets from edited ones.
    var source: [MeshTriangle]
    var triangleBase: Int, count: Int
    var nodeBase: Int, nodeCount: Int
    var lo: SIMD3<Float>, hi: SIMD3<Float>, maxAbs: Float
    // Hardware traversal: the asset's primitive acceleration structure (self-contained, so it
    // survives relocations of the triangle buffer).
    var structure: MTLAccelerationStructure? = nil
  }
  struct Instance {
    var node: Int  // graph node index, -1 for a graph-less mesh
    var asset: Int
    var world: simd_float4x4
    var normal: simd_float3x3
    var slots: [UInt32]
    var renderedBase: Int
    var mirrored: Bool
    var lo: SIMD3<Float>, hi: SIMD3<Float>  // conservative world bounds
  }
  var assets: [Asset] = []
  var instances: [Instance] = []
  var storedTriangles = 0
  var renderedTriangles = 0
  var tlasNodes = 0
  var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
  // Hardware traversal: the instance acceleration structure over `instances`.
  var scene: MTLAccelerationStructure?
  // Everything the shader reaches through the hardware structures (for residency).
  var structures: [MTLResource] { (scene.map { [$0] } ?? []) + assets.compactMap(\.structure) }

  // Instance and local index (BLAS order) of a rendered-triangle ID.
  func locate(_ id: Int) -> (instance: Int, local: Int)? {
    guard id >= 0, id < renderedTriangles, !instances.isEmpty else { return nil }
    var low = 0, high = instances.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if instances[middle].renderedBase <= id { low = middle } else { high = middle - 1 }
    }
    let local = id - instances[low].renderedBase
    return local < assets[instances[low].asset].count ? (low, local) : nil
  }
  // The world-space triangle an instance renders, exactly as SceneGraph.forEachRenderTriangle
  // flattens it: transformed corners and normals, b/c swapped under a mirroring transform,
  // uvc.z the bound slot, uvc.w the node index + 1 and na.w the subset.
  func worldTriangle(_ stored: MeshTriangle, instance i: Int) -> MeshTriangle {
    let instance = instances[i]
    guard instance.node >= 0 else { return stored }
    var t = stored
    let subset = Int(t.uvc.z)
    t.a = instance.world * t.a
    t.b = instance.world * t.b
    t.c = instance.world * t.c
    for key in [\MeshTriangle.na, \.nb, \.nc] {
      let p = t[keyPath: key]
      let n = instance.normal * SIMD3(p.x, p.y, p.z)
      t[keyPath: key] = SIMD4(simd_length_squared(n) > 1e-12 ? simd_normalize(n) : SIMD3(0, 1, 0), 0)
    }
    if instance.mirrored {
      swap(&t.b, &t.c)
      swap(&t.nb, &t.nc)
      let uvB = SIMD2(t.uvab.z, t.uvab.w)
      t.uvab.z = t.uvc.x
      t.uvab.w = t.uvc.y
      t.uvc.x = uvB.x
      t.uvc.y = uvB.y
    }
    t.na.w = Float(subset)
    t.uvc.z = instance.slots.indices.contains(subset) ? Float(instance.slots[subset]) : 0
    t.uvc.w = Float(instance.node + 1)
    return t
  }
}

extension MeshSceneLayout {
  static let triangleStride = MemoryLayout<MeshTriangle>.stride

  // Local bounds, 6 floats per triangle, for the BLAS build.
  static func bounds(_ triangles: UnsafeBufferPointer<MeshTriangle>) -> [Float] {
    [Float](unsafeUninitializedCapacity: 6 * triangles.count) { b, initialized in
      for (i, t) in triangles.enumerated() {
        let a = SIMD3(t.a.x, t.a.y, t.a.z), p = SIMD3(t.b.x, t.b.y, t.b.z), q = SIMD3(t.c.x, t.c.y, t.c.z)
        let l = simd_min(simd_min(a, p), q), h = simd_max(simd_max(a, p), q)
        b[6 * i] = l.x; b[6 * i + 1] = l.y; b[6 * i + 2] = l.z
        b[6 * i + 3] = h.x; b[6 * i + 4] = h.y; b[6 * i + 5] = h.z
      }
      initialized = 6 * triangles.count
    }
  }

  // Builds one asset's hierarchy: BLAS-ordered triangles are written straight to `target`
  // (the GPU buffer), and the nodes (item and child indices relative to the asset) returned.
  static func buildAsset(_ source: UnsafeBufferPointer<MeshTriangle>, into target: UnsafeMutablePointer<MeshTriangle>)
    -> [MeshWideNode]
  {
    let b = bounds(source)
    let result = b.withUnsafeBufferPointer { WideBVH.build(bounds: $0, count: source.count, leafSize: 2) }
    for (i, k) in result.order.enumerated() { target[i] = source[Int(k)] }
    return result.nodes
  }

  static func linear(_ m: simd_float4x4) -> simd_float3x3 {
    simd_float3x3(
      columns: (
        SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
        SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
      ))
  }
  // Infinity norm (max row sum of |entries|) of the linear part.
  static func norm(_ m: simd_float3x3) -> Float {
    (0..<3).map { r in abs(m.columns.0[r]) + abs(m.columns.1[r]) + abs(m.columns.2[r]) }.max() ?? 0
  }

  // Adds an instance of `asset` with world matrix `world`; throws like the flattening does
  // for transforms the renderer cannot represent.
  mutating func addInstance(node: Int, asset: Int, world: simd_float4x4, slots: [UInt32]) throws {
    let a = assets[asset]
    guard a.count > 0 else { return }
    let linear = Self.linear(world)
    if node >= 0 {
      let scale = simd_length(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z))
      guard scale.isFinite, (0.000001...1_000_000).contains(scale) else {
        throw MaterialLibrary.error("Combined hierarchy scale exceeds the supported range.")
      }
      let determinant = simd_determinant(world)
      guard determinant.isFinite, abs(determinant) > 1e-18 else {
        throw MaterialLibrary.error("Singular USD transform.")
      }
    }
    let translation = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
    let reach = simd_reduce_max(simd_abs(translation)) + Self.norm(linear) * a.maxAbs
    if node >= 0, !(reach < 1e8) {
      // The bound is conservative: only an exact check of the corners can reject.
      for t in a.source {
        for p in [t.a, t.b, t.c] {
          let v = world * p
          guard (0..<3).allSatisfy({ v[$0].isFinite && abs(v[$0]) < 1e8 }) else {
            throw MaterialLibrary.error("Hierarchy transform exceeds the supported scene extent.")
          }
        }
      }
    }
    // Corners of the local bounds, transformed; the shader's enlargement covers rounding.
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
    for k in 0..<8 {
      let p = SIMD4(k & 1 == 0 ? a.lo.x : a.hi.x, k & 2 == 0 ? a.lo.y : a.hi.y, k & 4 == 0 ? a.lo.z : a.hi.z, 1)
      let v = world * p
      lo = simd_min(lo, SIMD3(v.x, v.y, v.z)); hi = simd_max(hi, SIMD3(v.x, v.y, v.z))
    }
    let margin = Float(0x1p-20) * reach
    lo -= margin; hi += margin
    instances.append(
      Instance(
        node: node, asset: asset, world: world, normal: simd_transpose(simd_inverse(linear)), slots: slots,
        renderedBase: renderedTriangles, mirrored: node >= 0 && simd_determinant(world) < 0, lo: lo, hi: hi))
    renderedTriangles += a.count
    self.lo = simd_min(self.lo, lo); self.hi = simd_max(self.hi, hi)
  }

  // The node buffer of a two-level scene: header, instances, TLAS, slot table.
  func sceneBlob(accelerator: MTLResourceID? = nil) -> [UInt8] {
    let header = MemoryLayout<MeshSceneHeader>.stride, record = MemoryLayout<MeshInstanceRecord>.stride
    let node = MemoryLayout<MeshWideNode>.stride
    var boxes = [Float](repeating: 0, count: 6 * instances.count)
    for (i, instance) in instances.enumerated() {
      boxes[6 * i] = instance.lo.x; boxes[6 * i + 1] = instance.lo.y; boxes[6 * i + 2] = instance.lo.z
      boxes[6 * i + 3] = instance.hi.x; boxes[6 * i + 4] = instance.hi.y; boxes[6 * i + 5] = instance.hi.z
    }
    var tlas = boxes.withUnsafeBufferPointer {
      WideBVH.build(bounds: $0, count: instances.count, leafSize: 1, depth: WideBVH.maximumTopDepth)
    }
    // Single-instance leaves name the instance itself, so records keep rendered-ID order
    // (the shader's binary search) instead of TLAS order.
    for n in tlas.nodes.indices {
      for k in 0..<4 where tlas.nodes[n].child[k] < 0 {
        tlas.nodes[n].child[k] = -(tlas.order[Int(-tlas.nodes[n].child[k] - 1)] + 1)
      }
    }
    let slots = instances.flatMap(\.slots)
    let tlasOffset = header + record * instances.count
    let slotOffset = tlasOffset + node * tlas.nodes.count
    var bytes = [UInt8](repeating: 0, count: max(128, slotOffset + 4 * max(1, slots.count)))
    var condition: Float = 0, reach: Float = 0
    bytes.withUnsafeMutableBytes { raw in
      var slotBase = 0
      for (k, instance) in instances.enumerated() {
        let asset = assets[instance.asset]
        let m = instance.world, inverse = simd_inverse(m)
        func row(_ m: simd_float4x4, _ r: Int) -> SIMD4<Float> { SIMD4(m.columns.0[r], m.columns.1[r], m.columns.2[r], m.columns.3[r]) }
        let linear = Self.linear(m), n = Self.norm(linear)
        let translation = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        condition = max(condition, n * Self.norm(Self.linear(inverse)))
        reach = max(reach, simd_reduce_max(simd_abs(translation)) + n * asset.maxAbs)
        let r = MeshInstanceRecord(
          world0: row(m, 0), world1: row(m, 1), world2: row(m, 2),
          local0: row(inverse, 0), local1: row(inverse, 1), local2: row(inverse, 2),
          range: SIMD4(UInt32(asset.triangleBase), UInt32(asset.nodeBase), UInt32(instance.renderedBase), UInt32(asset.count)),
          binding: SIMD4(UInt32(slotBase), UInt32(instance.node + 1), instance.mirrored ? 1 : 0, 0),
          bound: SIMD4(simd_reduce_max(simd_abs(translation)), n, asset.maxAbs, 0))
        raw.storeBytes(of: r, toByteOffset: header + record * k, as: MeshInstanceRecord.self)
        slotBase += instance.slots.count
      }
      for (k, value) in tlas.nodes.enumerated() {
        raw.storeBytes(of: value, toByteOffset: tlasOffset + node * k, as: MeshWideNode.self)
      }
      for (k, value) in slots.enumerated() { raw.storeBytes(of: value, toByteOffset: slotOffset + 4 * k, as: UInt32.self) }
      let id = accelerator.map { withUnsafeBytes(of: $0) { $0.load(as: SIMD2<UInt32>.self) } } ?? .zero
      let h = MeshSceneHeader(
        info: SIMD4(UInt32(instances.count), UInt32(tlasOffset / 16), UInt32(slotOffset / 16), MeshSceneHeader.magic),
        counts: SIMD4(UInt32(renderedTriangles), UInt32(storedTriangles), UInt32(tlas.nodes.count), accelerator == nil ? 0 : 1),
        lo: SIMD4(lo, Float(0x1p-18) * (1 + condition)), hi: SIMD4(hi, reach), accelerator: SIMD4(id.x, id.y, 0, 0))
      raw.storeBytes(of: h, toByteOffset: 0, as: MeshSceneHeader.self)
    }
    return bytes
  }
}

extension MeshSceneLayout {
  // The asset ID of a graph-less (legacy) mesh.
  static let legacyAsset = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

  // One instance per visible scene-graph node with a mesh, in node order.
  mutating func addInstances(_ graph: SceneGraph) throws {
    let slotsByID = Dictionary(uniqueKeysWithValues: graph.materials.map { ($0.id, UInt32($0.slot)) })
    var assetIndex: [UUID: Int] = [:]
    for (i, asset) in assets.enumerated() { assetIndex[asset.id] = i }
    for (index, node) in graph.nodes.enumerated() {
      guard let id = node.mesh else { continue }
      guard let asset = assetIndex[id] else { throw MaterialLibrary.error("Scene graph: missing mesh.") }
      let (world, hidden) = graph.worldTransform(node.id)
      if hidden { continue }
      var slots: [UInt32] = []
      for binding in node.bindings {
        guard let slot = slotsByID[binding] else { throw MaterialLibrary.error("Scene graph: missing material binding.") }
        slots.append(slot)
      }
      try addInstance(node: index, asset: asset, world: world, slots: slots)
      guard renderedTriangles <= SceneLimits.renderedTriangles else {
        throw MaterialLibrary.error(
          "Instances exceed the \(SceneLimits.renderedTriangles.formatted()) rendered-triangle limit.")
      }
    }
  }
}

extension MaterialLibrary {
  // GPU bytes of the published mesh: triangles, hierarchies, instances and emitter list.
  var meshBytes: UInt64 {
    UInt64((triangleBuffer?.length ?? 0) + (nodeBuffer?.length ?? 0) + (emitterBuffer?.length ?? 0))
      + (meshLayout?.structures.reduce(UInt64(0)) { $0 + UInt64($1.allocatedSize) } ?? 0)
  }
  var meshBudget: UInt64 {
    meshBudgetOverride ?? max(UInt64(256 * 1024 * 1024), device.recommendedMaxWorkingSetSize / 4)
  }
  // Rendered (instanced) triangles: HitRecord.triangle and emitter IDs range over these.
  var renderedTriangleCount: Int { meshLayout?.renderedTriangles ?? triangleCount }

  // The world-space triangle of a rendered-triangle ID, as SceneGraph flattening builds it.
  func renderedTriangle(_ id: Int) -> MeshTriangle? {
    guard let layout = meshLayout else { return orderedTriangles.indices.contains(id) ? orderedTriangles[id] : nil }
    guard let (instance, local) = layout.locate(id) else { return nil }
    return layout.worldTriangle(
      orderedTriangles[layout.assets[layout.instances[instance].asset].triangleBase + local], instance: instance)
  }
  // Every rendered triangle in ID order: a flattened copy, for checks and tools only.
  func renderedTriangles() -> [MeshTriangle] {
    var result: [MeshTriangle] = []
    result.reserveCapacity(renderedTriangleCount)
    forEachRenderedTriangle { _, t in result.append(t) }
    return result
  }
  // Visits rendered triangles (ID, world triangle). With `emitting`, only triangles whose
  // slot it accepts are visited; two-level scenes skip instances without such slots.
  func forEachRenderedTriangle(emitting: ((Int) -> Bool)? = nil, _ body: (Int, MeshTriangle) throws -> Void) rethrows {
    let stored = orderedTriangles
    guard let layout = meshLayout else {
      for (i, t) in stored.enumerated() where emitting.map({ $0(Int(exactly: t.uvc.z) ?? -1) }) ?? true { try body(i, t) }
      return
    }
    for (i, instance) in layout.instances.enumerated() {
      let asset = layout.assets[instance.asset]
      var subsets: Set<Int>?
      if let emitting, instance.node >= 0 {
        let accepted = Set(instance.slots.indices.filter { emitting(Int(instance.slots[$0])) })
        if accepted.isEmpty { continue }
        subsets = accepted
      }
      for k in 0..<asset.count {
        let t = stored[asset.triangleBase + k]
        if let subsets, !subsets.contains(Int(t.uvc.z)) { continue }
        if instance.node < 0, let emitting, !emitting(Int(exactly: t.uvc.z) ?? -1) { continue }
        try body(instance.renderedBase + k, layout.worldTriangle(t, instance: i))
      }
    }
  }

  // Publishes a two-level mesh: assets whose ID and triangles match the published layout keep
  // their hierarchy (and, when nothing else changed, the whole triangle buffer); the others
  // are built. `instances` then adds the visible instances.
  func publishTwoLevel(
    assets inputs: [(UUID, [MeshTriangle])], document: [MeshTriangle], layout: inout MeshSceneLayout,
    instances: (inout MeshSceneLayout) throws -> Void
  ) throws {
    let previous = meshLayout
    var reused = [Int?](repeating: nil, count: inputs.count)
    if let previous {
      var byID: [UUID: Int] = [:]
      for (i, asset) in previous.assets.enumerated() { byID[asset.id] = i }
      for (i, input) in inputs.enumerated() {
        if let j = byID[input.0], sameBytes(previous.assets[j].source, input.1) { reused[i] = j }
      }
    }
    let stored = inputs.reduce(0) { $0 + $1.1.count }
    guard stored <= SceneLimits.triangles else {
      throw Self.error("Stored mesh assets exceed the \(SceneLimits.triangles.formatted()) triangle limit.")
    }
    let stride = MeshSceneLayout.triangleStride
    let buffer: MTLBuffer
    if let previous, previous.assets.count == inputs.count, reused.enumerated().allSatisfy({ $0.element == $0.offset }) {
      // Only instances changed: the triangle buffer and every hierarchy are kept.
      layout.assets = previous.assets
      for i in inputs.indices { layout.assets[i].source = inputs[i].1 }
      buffer = triangleBuffer
    } else {
      var built: [Int: WideBVH.Result] = [:]
      for (i, input) in inputs.enumerated() where reused[i] == nil && !input.1.isEmpty {
        let bounds = input.1.withUnsafeBufferPointer { MeshSceneLayout.bounds($0) }
        built[i] = bounds.withUnsafeBufferPointer { WideBVH.build(bounds: $0, count: input.1.count, leafSize: 2) }
        assetBuildCount += 1
      }
      var triangleBase = 0, nodeBase = stored
      layout.assets = []
      for (i, input) in inputs.enumerated() {
        var asset: MeshSceneLayout.Asset
        if let j = reused[i], let previous {
          asset = previous.assets[j]
          asset.source = input.1
        } else {
          let nodes = built[i]?.nodes ?? []
          var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
          if let root = nodes.first {
            for k in 0..<4 where root.child[k] != 0 {
              lo = simd_min(lo, SIMD3(root.lox[k], root.loy[k], root.loz[k]))
              hi = simd_max(hi, SIMD3(root.hix[k], root.hiy[k], root.hiz[k]))
            }
          }
          asset = MeshSceneLayout.Asset(
            id: input.0, source: input.1, triangleBase: 0, count: input.1.count, nodeBase: 0, nodeCount: nodes.count,
            lo: lo, hi: hi, maxAbs: nodes.isEmpty ? 0 : max(simd_reduce_max(simd_abs(lo)), simd_reduce_max(simd_abs(hi))))
        }
        asset.triangleBase = triangleBase
        asset.nodeBase = nodeBase
        triangleBase += asset.count
        nodeBase += asset.nodeCount
        layout.assets.append(asset)
      }
      let bytes = nodeBase.multipliedReportingOverflow(by: stride)
      guard !bytes.overflow,
        UInt64(bytes.partialValue) + meshBytes <= meshBudget,
        let b = device.makeBuffer(length: max(128, bytes.partialValue), options: .storageModeShared)
      else { throw Self.error("The imported meshes exceed the safe GPU memory budget.") }
      let target = b.contents().bindMemory(to: MeshTriangle.self, capacity: max(1, nodeBase))
      let raw = b.contents()
      for (i, asset) in layout.assets.enumerated() {
        if let j = reused[i], let previous {
          // Hierarchies index relative to their asset, so they move as plain bytes.
          let old = previous.assets[j], source = triangleBuffer.contents()
          raw.advanced(by: asset.triangleBase * stride)
            .copyMemory(from: source.advanced(by: old.triangleBase * stride), byteCount: old.count * stride)
          raw.advanced(by: asset.nodeBase * stride)
            .copyMemory(from: source.advanced(by: old.nodeBase * stride), byteCount: old.nodeCount * stride)
        } else if let result = built[i] {
          inputs[i].1.withUnsafeBufferPointer { source in
            for (k, item) in result.order.enumerated() { target[asset.triangleBase + k] = source[Int(item)] }
          }
          result.nodes.withUnsafeBytes { raw.advanced(by: asset.nodeBase * stride).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
      }
      buffer = b
    }
    layout.storedTriangles = stored
    var pending = buffer === triangleBuffer ? 0 : UInt64(buffer.length)
    if hardwareTraversal { try buildAssetStructures(&layout, triangleBuffer: buffer, pending: &pending) }
    try instances(&layout)
    meshBuildCount += 1
    try publishScene(layout, triangleBuffer: buffer, document: document, pending: pending)
  }

  // METALRT: hardware traversal needs a device that supports ray tracing; otherwise the
  // two-level software traversal runs on the same buffers.
  var hardwareTraversal: Bool { acceleration == .hardware && device.supportsRaytracing }

  // Builds one acceleration structure and waits for it (edits publish synchronously); primitive
  // structures are then compacted (about 10% smaller, measured watertight alike). `pending` counts
  // the structures this publish has already built, which stay live beside the published mesh.
  func buildStructure(_ descriptor: MTLAccelerationStructureDescriptor, compact: Bool = false,
                      pending: inout UInt64) throws -> MTLAccelerationStructure {
    if accelerationQueue == nil { accelerationQueue = device.makeCommandQueue() }
    let sizes = device.accelerationStructureSizes(descriptor: descriptor)
    guard let queue = accelerationQueue, UInt64(sizes.accelerationStructureSize) + pending + meshBytes <= meshBudget
    else { throw Self.error("The imported meshes exceed the safe GPU memory budget.") }
    let structure = try Self.buildStructure(descriptor, device: device, queue: queue, compact: compact)
    pending += UInt64(structure.allocatedSize)
    return structure
  }
  static func buildStructure(_ descriptor: MTLAccelerationStructureDescriptor, device: MTLDevice, queue: MTLCommandQueue,
                             compact: Bool) throws -> MTLAccelerationStructure {
    let sizes = device.accelerationStructureSizes(descriptor: descriptor)
    guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
      let scratch = device.makeBuffer(length: max(16, sizes.buildScratchBufferSize), options: .storageModePrivate),
      let compacted = device.makeBuffer(length: 8, options: .storageModeShared),
      let command = queue.makeCommandBuffer(), let encoder = command.makeAccelerationStructureCommandEncoder()
    else { throw Self.error("The imported meshes exceed the safe GPU memory budget.") }
    encoder.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
    if compact { encoder.writeCompactedSize(accelerationStructure: structure, buffer: compacted, offset: 0, sizeDataType: .ulong) }
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { throw Self.error("Could not build the mesh acceleration structure.") }
    let size = compacted.contents().load(as: UInt64.self)
    guard compact, size > 0, size < UInt64(sizes.accelerationStructureSize), let small = device.makeAccelerationStructure(size: Int(size)),
      let copy = queue.makeCommandBuffer(), let copier = copy.makeAccelerationStructureCommandEncoder()
    else { return structure }
    copier.copyAndCompact(sourceAccelerationStructure: structure, destinationAccelerationStructure: small)
    copier.endEncoding()
    copy.commit()
    copy.waitUntilCompleted()
    guard copy.status == .completed else { throw Self.error("Could not compact the mesh acceleration structure.") }
    return small
  }

  // METALRT gate at run time. Apple does not document the intersector's watertightness, and
  // Fix_accel measured leaks on shared edges with packed or welded vertices but none with the
  // unwelded MeshTriangle layout used here. Hardware traversal is the default only if, on this
  // device and OS, the production structures (compacted, unwelded, one identity and one
  // rotated/scaled instance) pass rays aimed at every shared edge and vertex of a curved patch
  // (the WOOP2013 check of tests/Fix_renderer-followups.swift). Otherwise the exact software
  // two-level traversal is the default. Computed once per process.
  static let hardwareWatertight: Bool = hardwareLeaks(device: MTLCreateSystemDefaultDevice()) == 0
  // Rays that leak through shared edges (nil: no hardware ray tracing or the probe failed).
  static func hardwareLeaks(device: MTLDevice?) -> Int? {
    guard let device, device.supportsRaytracing, let queue = device.makeCommandQueue() else { return nil }
    let cells = 16
    var grid: [[SIMD3<Float>]] = []
    for i in 0...cells {
      grid.append((0...cells).map { j in
        let x = Float(i) / Float(cells) * 2 - 1, z = Float(j) / Float(cells) * 2 - 1
        return SIMD3(x, 0.15 * sin(1.7 * x + 0.3) * cos(1.3 * z) + 0.05 * x, z)
      })
    }
    let zero = SIMD4<Float>(repeating: 0)
    var triangles: [MeshTriangle] = [], targets: [SIMD4<Float>] = []
    func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> MeshTriangle {
      MeshTriangle(a: SIMD4(a, 1), b: SIMD4(b, 1), c: SIMD4(c, 1), na: zero, nb: zero, nc: zero, uvab: zero, uvc: zero)
    }
    for i in 0..<cells {
      for j in 0..<cells {
        let a = grid[i][j], b = grid[i + 1][j], c = grid[i + 1][j + 1], d = grid[i][j + 1]
        triangles += (i + j) % 2 == 0 ? [triangle(a, b, c), triangle(a, c, d)] : [triangle(a, b, d), triangle(b, c, d)]
        if i > 0 && j > 0 { targets.append(SIMD4(a, 0)) }
        for f in [Float(0.25), 0.5, 0.75] {
          if j > 0 { targets.append(SIMD4(a + (b - a) * f, 0)) }
          if i > 0 { targets.append(SIMD4(a + (d - a) * f, 0)) }
          targets.append(SIMD4((i + j) % 2 == 0 ? a + (c - a) * f : b + (d - b) * f, 0))
        }
      }
    }
    var rotated = simd_float4x4(simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3)))) * simd_float4x4(diagonal: SIMD4(3, 3, 3, 1))
    rotated.columns.3 = SIMD4(10, 0, 0, 1)
    let source = """
      #include <metal_stdlib>
      #include <metal_raytracing>
      using namespace metal;
      using namespace raytracing;
      kernel void probe(instance_acceleration_structure scene [[buffer(0)]], device atomic_uint *leaks [[buffer(1)]],
          device const float4 *targets [[buffer(2)]], constant uint &count [[buffer(3)]], constant float4x4 &rotated [[buffer(4)]],
          uint2 gid [[thread_position_in_grid]]) {
          if(gid.x>=count) return;
          float3 eyes[6]={float3(0.3f,3,0.2f),float3(4,3.5f,-3),float3(-7,6,5),float3(0.05f,20,0.01f),float3(2.5f,1.8f,1.7f),float3(-0.4f,9,-12)};
          float4x4 m=gid.y<6 ? float4x4(1) : rotated;
          float3 eye=(m*float4(eyes[gid.y%6],1)).xyz, target=(m*float4(targets[gid.x].xyz,1)).xyz;
          intersector<instancing> closest; closest.assume_geometry_type(geometry_type::triangle);
          auto h=closest.intersect(ray(eye,normalize(target-eye),0.0f,length(target-eye)*1.001f+1e-3f),scene);
          if(h.type!=intersection_type::triangle) atomic_fetch_add_explicit(leaks,1,memory_order_relaxed);
      }
      """
    do {
      let library = try device.makeLibrary(source: source, options: nil)
      guard let function = library.makeFunction(name: "probe"),
        let vertices = triangles.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
        let indices = unweldedIndices(device, count: triangles.count),
        let targetBuffer = targets.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
        let leaks = device.makeBuffer(length: 4, options: .storageModeShared)
      else { return nil }
      let pipeline = try device.makeComputePipelineState(function: function)
      let blas = try buildStructure(primitiveDescriptor(vertices: vertices, offset: 0, count: triangles.count, indices: indices),
        device: device, queue: queue, compact: true)
      func instance(_ m: simd_float4x4) -> MTLAccelerationStructureInstanceDescriptor {
        func column(_ c: SIMD4<Float>) -> MTLPackedFloat3 { MTLPackedFloat3Make(c.x, c.y, c.z) }
        var d = MTLAccelerationStructureInstanceDescriptor()
        d.transformationMatrix = MTLPackedFloat4x3(columns: (column(m.columns.0), column(m.columns.1), column(m.columns.2), column(m.columns.3)))
        d.options = .opaque; d.mask = 0xFF; d.accelerationStructureIndex = 0
        return d
      }
      let descriptors = [instance(matrix_identity_float4x4), instance(rotated)]
      let top = MTLInstanceAccelerationStructureDescriptor()
      top.instancedAccelerationStructures = [blas]
      top.instanceCount = descriptors.count
      top.instanceDescriptorBuffer = descriptors.withUnsafeBytes {
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
      }
      let scene = try buildStructure(top, device: device, queue: queue, compact: false)
      guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return nil }
      memset(leaks.contents(), 0, 4)
      var count = UInt32(targets.count), m = rotated
      encoder.setComputePipelineState(pipeline)
      encoder.setAccelerationStructure(scene, bufferIndex: 0)
      encoder.useResource(blas, usage: .read)
      encoder.setBuffer(leaks, offset: 0, index: 1)
      encoder.setBuffer(targetBuffer, offset: 0, index: 2)
      encoder.setBytes(&count, length: 4, index: 3)
      encoder.setBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: 4)
      encoder.dispatchThreads(MTLSize(width: targets.count, height: 12, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
      encoder.endEncoding()
      command.commit()
      command.waitUntilCompleted()
      guard command.status == .completed else { return nil }
      return Int(leaks.contents().load(as: UInt32.self))
    } catch {
      return nil
    }
  }
  // One primitive acceleration structure per asset lacking one. The vertices are the stored
  // MeshTriangle records themselves (stride 16, triangle k indexing vertices 8k, 8k + 1 and
  // 8k + 2): Fix_accel measured this unwelded layout leak-free on shared edges, while packed and
  // welded vertex layouts leaked through the same intersector.
  func buildAssetStructures(_ layout: inout MeshSceneLayout, triangleBuffer: MTLBuffer, pending: inout UInt64) throws {
    let missing = layout.assets.indices.filter { layout.assets[$0].structure == nil && layout.assets[$0].count > 0 }
    guard let largest = missing.map({ layout.assets[$0].count }).max() else { return }
    guard let indexBuffer = MaterialLibrary.unweldedIndices(device, count: largest)
    else { throw Self.error("Could not allocate the mesh acceleration structure.") }
    for i in missing {
      let descriptor = MaterialLibrary.primitiveDescriptor(
        vertices: triangleBuffer, offset: layout.assets[i].triangleBase * MeshSceneLayout.triangleStride,
        count: layout.assets[i].count, indices: indexBuffer)
      layout.assets[i].structure = try buildStructure(descriptor, compact: true, pending: &pending)
      assetBuildCount += 1
    }
  }
  // Triangle k of a MeshTriangle array indexes vertices 8k, 8k + 1 and 8k + 2 (its a, b, c).
  static func unweldedIndices(_ device: MTLDevice, count: Int) -> MTLBuffer? {
    let indices = [UInt32](unsafeUninitializedCapacity: 3 * count) { b, initialized in
      for k in 0..<count { b[3 * k] = UInt32(8 * k); b[3 * k + 1] = UInt32(8 * k + 1); b[3 * k + 2] = UInt32(8 * k + 2) }
      initialized = 3 * count
    }
    return indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(16, $0.count), options: .storageModeShared) }
  }
  static func primitiveDescriptor(vertices: MTLBuffer, offset: Int, count: Int, indices: MTLBuffer)
    -> MTLPrimitiveAccelerationStructureDescriptor
  {
    let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
    geometry.vertexBuffer = vertices
    geometry.vertexBufferOffset = offset
    geometry.vertexStride = 16
    geometry.vertexFormat = .float3
    geometry.indexBuffer = indices
    geometry.indexType = .uint32
    geometry.triangleCount = count
    geometry.opaque = true
    let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
    descriptor.geometryDescriptors = [geometry]
    return descriptor
  }
  // The instance acceleration structure: instance k of `layout.instances` is instance_id k.
  func buildSceneStructure(_ layout: MeshSceneLayout, pending: inout UInt64) throws -> MTLAccelerationStructure? {
    guard !layout.instances.isEmpty else { return nil }
    var compact: [Int: Int] = [:], structures: [MTLAccelerationStructure] = []
    for (i, asset) in layout.assets.enumerated() {
      guard let structure = asset.structure else { continue }
      compact[i] = structures.count
      structures.append(structure)
    }
    var descriptors: [MTLAccelerationStructureInstanceDescriptor] = []
    for instance in layout.instances {
      guard let index = compact[instance.asset] else { throw Self.error("A mesh asset has no acceleration structure.") }
      let m = instance.world
      func column(_ c: SIMD4<Float>) -> MTLPackedFloat3 { MTLPackedFloat3Make(c.x, c.y, c.z) }
      var d = MTLAccelerationStructureInstanceDescriptor()
      d.transformationMatrix = MTLPackedFloat4x3(columns: (column(m.columns.0), column(m.columns.1), column(m.columns.2), column(m.columns.3)))
      d.options = .opaque
      d.mask = 0xFF
      d.intersectionFunctionTableOffset = 0
      d.accelerationStructureIndex = UInt32(index)
      descriptors.append(d)
    }
    guard let buffer = descriptors.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
    else { throw Self.error("Could not allocate the mesh acceleration structure.") }
    let descriptor = MTLInstanceAccelerationStructureDescriptor()
    descriptor.instancedAccelerationStructures = structures
    descriptor.instanceCount = descriptors.count
    descriptor.instanceDescriptorBuffer = buffer
    return try buildStructure(descriptor, pending: &pending)
  }

  // Builds the TLAS and instance table of `layout` and publishes it with `triangleBuffer`.
  func publishScene(_ layout: MeshSceneLayout, triangleBuffer t: MTLBuffer, document: [MeshTriangle], pending: UInt64 = 0,
                    keepScene: Bool = false) throws {
    var layout = layout, pending = pending
    // Hardware traversal: a new instance structure for every instance change (the per-asset
    // structures are kept), so transform edits cost one small build; binding edits keep it.
    if !(keepScene && layout.scene != nil) {
      layout.scene = hardwareTraversal ? try buildSceneStructure(layout, pending: &pending) : nil
    }
    let blob = layout.sceneBlob(accelerator: layout.scene?.gpuResourceID)
    let header = blob.withUnsafeBytes { $0.load(as: MeshSceneHeader.self) }
    layout.tlasNodes = Int(header.counts.z)
    guard UInt64(blob.count) + pending + meshBytes <= meshBudget,
      let n = blob.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
    else { throw Self.error("The imported meshes exceed the safe GPU memory budget.") }
    sceneBuildCount += 1
    let nodes = layout.instances.isEmpty ? 0 : layout.tlasNodes + layout.assets.reduce(0) { $0 + $1.nodeCount }
    try restoreMesh(MeshResources(triangles: document, triangleBuffer: t, triangleCount: layout.storedTriangles,
      nodeBuffer: n, nodeCount: nodes, layout: layout))
  }
}
