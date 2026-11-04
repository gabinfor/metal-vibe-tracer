import simd

// Light BVH over imported emitter triangles (docs/LIGHT_TREE_DESIGN.md). REFERENCES.md: CONTY2018 (the
// method), PBRT2023 (BVHLightSampler: LightBounds, CompactLightBounds, the importance bound and the SAOH split
// cost). The GPU walks it from the root, choosing each child in proportion to its importance at the shading
// point and a leaf's emitter in proportion to power (MSL light_tree_sample), and recomputes the same choices
// from a leaf upward for a BSDF hit (light_tree_pmf).
enum LightTree {
  // One emitter triangle: its world corners, power (area x selection weight) and the cosine of its emission
  // half-angle (0 for a one-sided Lambertian emitter, the cone angle of a UsdLux spot).
  struct Emitter {
    var a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>
    var power: Double
    var cosEmission: Double
  }

  // pbrt-v4 LightBounds: spatial bounds, power, the cone of normals (axis w, cosTheta_o) and the emission
  // half-angle beyond the normals (cosTheta_e). Emitters are one-sided, like imported_geometry.
  struct Bounds {
    var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
    var phi = 0.0
    var w = SIMD3<Double>(0, 0, 1)
    var cosO = 1.0, cosE = 1.0

    init() {}
    init(_ e: Emitter) {
      let a = SIMD3<Double>(e.a), b = SIMD3<Double>(e.b), c = SIMD3<Double>(e.c)
      lo = simd_min(a, simd_min(b, c)); hi = simd_max(a, simd_max(b, c))
      let n = simd_cross(b - a, c - a)
      let length = simd_length(n)
      phi = length > 0 && e.power.isFinite ? max(0, e.power) : 0
      w = length > 0 ? n / length : SIMD3(0, 0, 1)
      cosO = 1
      cosE = min(1, max(0, e.cosEmission))
    }
    var centroid: SIMD3<Double> { 0.5 * (lo + hi) }

    // pbrt-v4 Union(LightBounds, LightBounds): a powerless side contributes nothing.
    func union(_ o: Bounds) -> Bounds {
      if phi == 0 { return o }
      if o.phi == 0 { return self }
      var r = Bounds()
      r.lo = simd_min(lo, o.lo); r.hi = simd_max(hi, o.hi)
      r.phi = phi + o.phi
      (r.w, r.cosO) = LightTree.coneUnion(w, cosO, o.w, o.cosO)
      r.cosE = min(cosE, o.cosE)
      return r
    }
  }

  // pbrt-v4 Union(DirectionCone, DirectionCone).
  static func coneUnion(_ wa: SIMD3<Double>, _ ca: Double, _ wb: SIMD3<Double>, _ cb: Double) -> (SIMD3<Double>, Double) {
    let thetaA = acos(min(1, max(-1, ca))), thetaB = acos(min(1, max(-1, cb)))
    let thetaD = angleBetween(wa, wb)
    if min(thetaD + thetaB, .pi) <= thetaA { return (wa, ca) }
    if min(thetaD + thetaA, .pi) <= thetaB { return (wb, cb) }
    let thetaO = (thetaA + thetaD + thetaB) / 2
    if thetaO >= .pi { return (wa, -1) }
    let axis = simd_cross(wa, wb)
    if simd_length_squared(axis) == 0 { return (wa, -1) }
    let w = simd_quatd(angle: thetaO - thetaA, axis: simd_normalize(axis)).act(wa)
    return (simd_normalize(w), cos(thetaO))
  }
  // pbrt-v4 AngleBetween: numerically robust for nearly parallel and opposite vectors.
  static func angleBetween(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    if simd_dot(a, b) < 0 { return .pi - 2 * asin(min(1, simd_length(a + b) / 2)) }
    return 2 * asin(min(1, simd_length(b - a) / 2))
  }

  // pbrt-v4 BVHLightSampler::EvaluateCost: the surface area orientation heuristic (SAOH) of a set of lights,
  // with Kr penalising thin splits across the node's longest axis (axis nil: no penalty, for a leaf).
  static func cost(_ b: Bounds, nodeDiagonal: SIMD3<Double>, axis: Int?) -> Double {
    guard b.phi > 0 else { return 0 }
    let thetaO = acos(min(1, max(-1, b.cosO))), thetaE = acos(min(1, max(-1, b.cosE)))
    let thetaW = min(thetaO + thetaE, .pi)
    let sinO = (max(0, 1 - b.cosO * b.cosO)).squareRoot()
    let mOmega = 2 * .pi * (1 - b.cosO)
      + .pi / 2 * (2 * thetaW * sinO - cos(thetaO - 2 * thetaW) - 2 * thetaO * sinO + b.cosO)
    let kr = axis.map { nodeDiagonal.max() / max(nodeDiagonal[$0], 1e-300) } ?? 1
    let d = b.hi - b.lo
    let area = 2 * (d.x * d.y + d.x * d.z + d.y * d.z)
    return b.phi * mOmega * kr * area
  }

  // The GPU walks at most this many levels (MSL LIGHT_TREE_MAX_DEPTH); MaterialLibrary falls back to power
  // sampling for a deeper tree, for more nodes than the parent field holds, or when the root is a leaf: power
  // sampling without the walk.
  static let maxDepth = 64
  static let maxNodes = (1 << 27) - 1
  // A leaf holds up to maxLeaf emitters, chosen within it by power (MSL light_tree_leaf). The build keeps a
  // range of at most maxLeaf emitters as one leaf when its best split would cost at least `leafRatio` of the
  // unsplit SAOH: emitters that share their position and facing, such as the triangles of one lamp, gain
  // nothing from separate choices and are no longer walked one by one.
  static let maxLeaf = 8
  static let leafRatio = 0.75
  static let noParent = UInt32(maxNodes)

  // The built tree: nodes in depth-first order (a node's first child follows it), 8 words each (MSL
  // LightTreeNode); `order` maps leaf positions to the input emitters; `leafNode` gives each leaf position's
  // node; `grid` is the box the node bounds are quantised in.
  struct Built {
    var words: [UInt32]
    var nodeCount: Int
    var order: [Int]
    var leafNode: [UInt32]
    var depth: Int
    var grid: (lo: SIMD3<Float>, hi: SIMD3<Float>)
  }

  // Builds the tree over `emitters`. Iterative, so that degenerate inputs cannot exhaust a background thread's
  // stack.
  static func build(_ emitters: [Emitter], maxLeaf: Int = maxLeaf, leafRatio: Double = leafRatio) -> Built {
    let count = emitters.count
    let bounds = emitters.map(Bounds.init)
    var gridLo = SIMD3<Double>(repeating: .infinity), gridHi = SIMD3<Double>(repeating: -.infinity)
    for b in bounds { gridLo = simd_min(gridLo, b.lo); gridHi = simd_max(gridHi, b.hi) }
    let grid = (lo: count > 0 ? SIMD3<Float>(gridLo).nextDown : .zero, hi: count > 0 ? SIMD3<Float>(gridHi).nextUp : .zero)
    var order = Array(0..<count)
    var words = [UInt32](), leafNode = [UInt32](repeating: 0, count: count)
    words.reserveCapacity(8 * max(1, 2 * count - 1))
    var nodeCount = 0, depth = 0
    // Work items: a range of `order`, the parent, whether this is its second child, and the depth.
    var work: [(Range<Int>, UInt32, Bool, Int)] = count > 0 ? [(0..<count, noParent, false, 0)] : []
    while let (range, parent, second, level) = work.popLast() {
      let index = nodeCount
      nodeCount += 1
      depth = max(depth, level)
      if second { words[8 * Int(parent) + 6] = UInt32(index) }
      var total = Bounds(), centroids = (lo: SIMD3<Double>(repeating: .infinity), hi: SIMD3<Double>(repeating: -.infinity))
      for i in range {
        let b = bounds[order[i]]
        total = total.union(b)
        centroids.lo = simd_min(centroids.lo, b.centroid); centroids.hi = simd_max(centroids.hi, b.centroid)
      }
      if total.phi == 0 {
        // Powerless subtree: keep the full spatial bounds for a well-formed node; its importance is zero.
        for i in range { total.lo = simd_min(total.lo, bounds[order[i]].lo); total.hi = simd_max(total.hi, bounds[order[i]].hi) }
      }
      let candidate = range.count > 1 ? split(range, bounds, order, total, centroids) : nil
      let leaf = range.count == 1 || (range.count <= maxLeaf && (total.phi == 0
        || (candidate?.cost ?? .infinity) >= leafRatio * cost(total, nodeDiagonal: total.hi - total.lo, axis: nil)))
      if leaf {
        for i in range { leafNode[i] = UInt32(index) }
        words += node(total, grid, child: UInt32(range.lowerBound), parent: parent, leafCount: range.count)
        continue
      }
      let mid = partition(&order, range, bounds, centroids, candidate)
      words += node(total, grid, child: 0, parent: parent, leafCount: 0)
      work.append((mid..<range.upperBound, UInt32(index), true, level + 1))
      work.append((range.lowerBound..<mid, UInt32(index), false, level + 1))
    }
    return Built(words: words, nodeCount: nodeCount, order: order, leafNode: leafNode, depth: depth, grid: grid)
  }

  private static let buckets = 12

  // pbrt-v4 BVHLightSampler::buildBVH: 12 buckets per axis over the centroids and the cheapest SAOH split.
  private static func split(_ range: Range<Int>, _ bounds: [Bounds], _ order: [Int], _ node: Bounds,
                            _ centroids: (lo: SIMD3<Double>, hi: SIMD3<Double>)) -> (cost: Double, axis: Int, bucket: Int)? {
    let diagonal = node.hi - node.lo
    var best: (cost: Double, axis: Int, bucket: Int)?
    for axis in 0..<3 where centroids.hi[axis] > centroids.lo[axis] {
      var bucketBounds = [Bounds](repeating: Bounds(), count: buckets)
      for i in range {
        let k = bucket(bounds[order[i]], axis, centroids)
        bucketBounds[k] = bucketBounds[k].union(bounds[order[i]])
      }
      var below = [Bounds](repeating: Bounds(), count: buckets), above = below
      for k in 0..<buckets { below[k] = k == 0 ? bucketBounds[0] : below[k - 1].union(bucketBounds[k]) }
      for k in stride(from: buckets - 1, through: 0, by: -1) { above[k] = k == buckets - 1 ? bucketBounds[k] : above[k + 1].union(bucketBounds[k]) }
      for k in 0..<(buckets - 1) where below[k].phi > 0 || above[k + 1].phi > 0 {
        let c = cost(below[k], nodeDiagonal: diagonal, axis: axis) + cost(above[k + 1], nodeDiagonal: diagonal, axis: axis)
        if c < (best?.cost ?? .infinity) { best = (c, axis, k) }
      }
    }
    return best
  }
  private static func bucket(_ b: Bounds, _ axis: Int, _ centroids: (lo: SIMD3<Double>, hi: SIMD3<Double>)) -> Int {
    let lo = centroids.lo[axis], extent = centroids.hi[axis] - lo
    return min(buckets - 1, Int(Double(buckets) * (b.centroid[axis] - lo) / extent))
  }
  // The split's partition, or the middle of the range when every centroid coincides or a side is empty.
  private static func partition(_ order: inout [Int], _ range: Range<Int>, _ bounds: [Bounds],
                                _ centroids: (lo: SIMD3<Double>, hi: SIMD3<Double>),
                                _ split: (cost: Double, axis: Int, bucket: Int)?) -> Int {
    let middle = range.lowerBound + range.count / 2
    guard let split else { return middle }
    let part = order[range].partition { bucket(bounds[$0], split.axis, centroids) > split.bucket }
    return part == range.lowerBound || part == range.upperBound ? middle : part
  }

  // pbrt-v4 CompactLightBounds, 8 words: the octahedral cone axis (2 x 16 bits), power, both cone cosines (16 bits
  // each), the bounds quantised in `grid` (6 x 16 bits), the second child or a leaf's first position, and the
  // parent (27 bits) with the leaf's emitter count (5 bits, 0 for an inner node). Quantisation rounds the bounds
  // outward and the cosines down, so the GPU's importance stays a conservative bound.
  private static func node(_ b: Bounds, _ grid: (lo: SIMD3<Float>, hi: SIMD3<Float>), child: UInt32,
                           parent: UInt32, leafCount: Int) -> [UInt32] {
    let gLo = SIMD3<Double>(grid.lo), extent = SIMD3<Double>(grid.hi) - gLo
    func q(_ v: Double, _ axis: Int, up: Bool) -> UInt32 {
      guard extent[axis] > 0, v.isFinite else { return up ? 65535 : 0 }
      let x = (v - gLo[axis]) / extent[axis] * 65535
      return UInt32(min(65535, max(0, up ? x.rounded(.up) : x.rounded(.down))))
    }
    func qCos(_ c: Double) -> UInt32 { UInt32(min(65535, max(0, ((c + 1) / 2 * 65535).rounded(.down)))) }
    let lo = (0..<3).map { q(b.lo[$0], $0, up: false) }, hi = (0..<3).map { q(b.hi[$0], $0, up: true) }
    return [octahedral(b.w), Float(b.phi).bitPattern, qCos(b.cosO) | qCos(b.cosE) << 16,
            lo[0] | lo[1] << 16, lo[2] | hi[0] << 16, hi[1] | hi[2] << 16,
            child, parent | UInt32(leafCount) << 27]
  }
  // Octahedral encoding of a unit vector in 2 x 16 bits (MSL light_tree_axis decodes it).
  static func octahedral(_ v: SIMD3<Double>) -> UInt32 {
    var p = SIMD2(v.x, v.y) / (abs(v.x) + abs(v.y) + abs(v.z))
    if v.z < 0 {
      p = SIMD2((1 - abs(p.y)) * (p.x >= 0 ? 1 : -1), (1 - abs(p.x)) * (p.y >= 0 ? 1 : -1))
    }
    func e(_ x: Double) -> UInt32 { UInt32(min(65535, max(0, ((x * 0.5 + 0.5) * 65535).rounded()))) }
    return e(p.x) | e(p.y) << 16
  }
}

private extension SIMD3 where Scalar == Float {
  var nextDown: Self { Self(x.nextDown, y.nextDown, z.nextDown) }
  var nextUp: Self { Self(x.nextUp, y.nextUp, z.nextUp) }
}
