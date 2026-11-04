// Light BVH (LightSampling.tree; CONTY2018, PBRT2023 BVHLightSampler; docs/LIGHT_TREE_DESIGN.md): the host tree
// is well formed, the emitter list keeps power sampling's layout when the tree is off, light samples and BSDF hits
// agree on the PDF, both selections estimate the same emitted light as a quadrature reference, the tree lowers
// the variance where nearby lights dominate, back-facing emitters are rarely chosen, and one lamp's triangles get no tree.
@MainActor func fixLightTreeChecks() throws {
  // 1. Host build: every emitter in exactly one leaf, consistent links, power sums and enclosing quantised bounds,
  // also for coincident, degenerate and powerless emitters.
  var rng = SystemRandomNumberGenerator()
  var random: [LightTree.Emitter] = (0..<500).map { i in
    let o = SIMD3<Float>(Float.random(in: -10...10, using: &rng), Float.random(in: -2...2, using: &rng), Float.random(in: -10...10, using: &rng))
    let d = { SIMD3<Float>(Float.random(in: -0.5...0.5, using: &rng), Float.random(in: -0.5...0.5, using: &rng), Float.random(in: -0.5...0.5, using: &rng)) }
    return LightTree.Emitter(a: o, b: o + d(), c: o + d(), power: i % 7 == 0 ? 0 : Double.random(in: 0.1...10, using: &rng),
                             cosEmission: i % 5 == 0 ? 0.7 : 0)
  }
  let same = random[1]
  random += Array(repeating: same, count: 40)
  random.append(LightTree.Emitter(a: .zero, b: .zero, c: .zero, power: 3, cosEmission: 0))
  let tree = LightTree.build(random)
  // LightTree.node: power in word 1, quantised bounds in words 3-5, second child or first position in word 6,
  // parent and leaf count in word 7; a node's first child follows it.
  func word(_ node: Int, _ k: Int) -> UInt32 { tree.words[8 * node + k] }
  func phi(_ node: Int) -> Double { Double(Float(bitPattern: word(node, 1))) }
  func box(_ node: Int) -> [UInt32] { [word(node, 3) & 0xffff, word(node, 3) >> 16, word(node, 4) & 0xffff,
                                        word(node, 4) >> 16, word(node, 5) & 0xffff, word(node, 5) >> 16] }
  var covered = [Int](repeating: 0, count: random.count), linked = true, enclosed = true, sums = true
  for i in 0..<tree.nodeCount {
    let count = Int(word(i, 7) >> 27)
    if count > 0 {
      linked = linked && count <= LightTree.maxLeaf
      for position in Int(word(i, 6))..<(Int(word(i, 6)) + count) {
        covered[tree.order[position]] += 1
        linked = linked && tree.leafNode[position] == UInt32(i)
      }
      continue
    }
    let children = [i + 1, Int(word(i, 6))]
    linked = linked && children.allSatisfy { $0 < tree.nodeCount && Int(word($0, 7) & 0x7ffffff) == i }
    sums = sums && abs(phi(i) - phi(children[0]) - phi(children[1])) <= 1e-5 * max(1, phi(i))
    for c in children where phi(c) > 0 {
      let (outer, inner) = (box(i), box(c))
      enclosed = enclosed && inner[0] >= outer[0] && inner[1] >= outer[1] && inner[2] >= outer[2]
        && inner[3] <= outer[3] && inner[4] <= outer[4] && inner[5] <= outer[5]
    }
  }
  let rootPower = random.reduce(0.0) { $0 + ($1.power > 0 && simd_length(simd_cross($1.b - $1.a, $1.c - $1.a)) > 0 ? $1.power : 0) }
  let leaves = (0..<tree.nodeCount).filter { word($0, 7) >> 27 != 0 }.count
  print("Light tree build: \(tree.nodeCount) nodes, \(leaves) leaves for \(random.count) emitters, depth \(tree.depth), root power \(phi(0)) of \(rootPower)")
  require(covered.allSatisfy { $0 == 1 } && word(0, 7) & 0x7ffffff == LightTree.noParent && linked && sums && enclosed
    && abs(phi(0) - rootPower) <= 1e-5 * rootPower && tree.depth <= LightTree.maxDepth && tree.nodeCount == 2 * leaves - 1,
    "the light tree is well formed: every emitter in one leaf, links, power sums and quantised bounds")

  // 2. A ceiling of small emitters: a 24 x 24 grid facing down (two emission slots) and a row facing up.
  let materials = testRenderer.materials
  let saved = (materials.emissions, materials.lightTree)
  defer { materials.emissions = saved.0; materials.lightTree = saved.1 }
  func emitter(_ x: Float, _ z: Float, slot: Float, down: Bool) -> MeshTriangle {
    let s: Float = 0.3, n = SIMD4<Float>(0, down ? -1 : 1, 0, 0)
    let a = SIMD4<Float>(x, 3, z, 1), b = SIMD4<Float>(x + s, 3, z, 1), c = SIMD4<Float>(x, 3, z + s, 1)
    return MeshTriangle(a: a, b: down ? b : c, c: down ? c : b, na: n, nb: n, nc: n, uvab: SIMD4(0, 0, 1, 0), uvc: SIMD4(0, 1, slot, 1))
  }
  var ceiling: [MeshTriangle] = []
  for i in 0..<24 { for j in 0..<24 {
    ceiling.append(emitter(-24 + 2 * Float(i), -24 + 2 * Float(j), slot: (i + j) % 3 == 0 ? 9 : 8, down: true))
  } }
  for i in 0..<12 { ceiling.append(emitter(-23 + 4 * Float(i), 0.9, slot: 8, down: false)) }
  let radiance: [Int: SIMD3<Float>] = [8: SIMD3(5, 5, 5), 9: SIMD3(1, 4, 2)]
  materials.emissions = radiance
  try materials.setMesh(ceiling)

  let kernels = """
  // Per thread, 64 light samples at receiver points[tid / perPoint]: the sum and sum of squares of the luminance
  // emitted toward p over the sample's PDF, BSDF hits on the sampled triangle, zero hit PDFs, the largest relative
  // PDF difference and the number of samples that chose an emitter facing away from p.
  kernel void lt_estimate(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]], device const float4 *points [[buffer(4)]], constant uint &perPoint [[buffer(5)]],
      uint tid [[thread_position_in_grid]]) {
      float3 p = points[tid / perPoint].xyz;
      uint seed = pcg_hash(tid * 7919u + 3u);
      float sum = 0, squares = 0, hits = 0, zero = 0, error = 0, backFacing = 0;
      for (int i = 0; i < 64; ++i) {
          LightSample ls = sample_direct_light(p, float3(0, 1, 0), u, seed, images);
          if (ls.isDirectional < 2u) continue;
          MeshTriangle t = scene_triangle(ls.isDirectional - 2u, images);
          if (dot(cross(t.b.xyz - t.a.xyz, t.c.xyz - t.a.xyz), p - ls.position) <= 0.0f) backFacing += 1;
          if (!(ls.pdf > 0.0f)) continue;
          float c = dot(ls.emission, float3(0.2126f, 0.7152f, 0.0722f)) / ls.pdf;
          sum += c; squares += c * c;
          Ray ray = { p, ls.wi }; HitRecord rec;
          if (!trace_scene(ray, 6, rec, images, u) || rec.mat.type != EMISSIVE || rec.triangle != ls.isDirectional - 2u) continue;
          hits += 1;
          float pdf = eval_light_pdf(p, rec.position, rec.mat, u, images, rec.triangle);
          if (!(pdf > 0.0f)) zero += 1; else error = max(error, abs(pdf - ls.pdf) / ls.pdf);
      }
      out[2 * tid] = float4(sum, squares, hits, zero);
      out[2 * tid + 1] = float4(error, backFacing, 0, 0);
  }
  """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  let points: [SIMD4<Float>] = [SIMD4(0, 0, 0, 0), SIMD4(-22, 0, -22, 0), SIMD4(15, 0.5, 5, 0), SIMD4(-3, 2.5, 7, 0), SIMD4(0, 5, 0, 0)]
  let perPoint = 1024, samplesPerPoint = Double(perPoint * 64)
  var view = makeUniforms(scene: 6, mode: 1, width: 1, height: 1)
  view.environment = SIMD4(0, 0, 0, Float(materials.nodeCount))
  view.sunParams.w = 0
  view.lens.z = 1
  struct Estimate { var mean: Double, variance: Double, hits: Float, zero: Float, error: Float, backFacing: Float }
  func estimate() throws -> [Estimate] {
    let threads = perPoint * points.count
    var count = UInt32(perPoint), u = view
    guard let function = library.makeFunction(name: "lt_estimate"),
      let out = gpu.makeBuffer(length: threads * 32, options: .storageModeShared),
      let input = gpu.makeBuffer(bytes: points, length: points.count * 16, options: .storageModeShared),
      let command = testRenderer.commandQueue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
    else { throw MaterialLibrary.error("light tree check setup") }
    encoder.setComputePipelineState(try gpu.makeComputePipelineState(function: function))
    require(materials.bind(encoder), "lt_estimate binds scene resources")
    encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setBuffer(out, offset: 0, index: 3)
    encoder.setBuffer(input, offset: 0, index: 4)
    encoder.setBytes(&count, length: 4, index: 5)
    encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "lt_estimate GPU command: \(String(describing: command.error))")
    let values = (0..<(2 * threads)).map { out.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
    return points.indices.map { k in
      let rows = (k * perPoint)..<((k + 1) * perPoint)
      let sum = rows.reduce(0.0) { $0 + Double(values[2 * $1].x) }, squares = rows.reduce(0.0) { $0 + Double(values[2 * $1].y) }
      let mean = sum / samplesPerPoint
      return Estimate(mean: mean, variance: max(0, squares / samplesPerPoint - mean * mean),
                      hits: rows.reduce(0) { $0 + values[2 * $1].z }, zero: rows.reduce(0) { $0 + values[2 * $1].w },
                      error: rows.map { values[2 * $0 + 1].x }.max() ?? 1, backFacing: rows.reduce(0) { $0 + values[2 * $1 + 1].y })
    }
  }
  // Quadrature reference: the luminance each front-facing triangle sends to p, integrated over 20 x 20 sub-triangles
  // (L cos_l / d^2 dA, the solid-angle measure the estimator integrates).
  func reference(_ p: SIMD3<Double>) -> Double {
    var total = 0.0
    for t in ceiling {
      let a = SIMD3<Double>(Double(t.a.x), Double(t.a.y), Double(t.a.z)), b = SIMD3<Double>(Double(t.b.x), Double(t.b.y), Double(t.b.z))
      let c = SIMD3<Double>(Double(t.c.x), Double(t.c.y), Double(t.c.z))
      let cross = simd_cross(b - a, c - a), area = 0.5 * simd_length(cross), n = simd_normalize(cross)
      let e = radiance[Int(t.uvc.z)]!, lum = 0.2126 * Double(e.x) + 0.7152 * Double(e.y) + 0.0722 * Double(e.z)
      let k = 20
      for i in 0..<k { for j in 0..<(k - i) {
        for (u, v, w) in [(Double(i) + 1.0 / 3, Double(j) + 1.0 / 3, 1.0), (Double(i) + 2.0 / 3, Double(j) + 2.0 / 3, 1.0)] {
          guard u + v <= Double(k) else { continue }
          let q = a + (b - a) * (u / Double(k)) + (c - a) * (v / Double(k)), d = p - q, d2 = simd_length_squared(d)
          total += w * lum * max(0, simd_dot(n, d) / d2.squareRoot()) / d2 * area / Double(k * k)
        }
      } }
    }
    return total
  }
  materials.lightTree = false
  let power = try estimate()
  materials.lightTree = true
  let treeEstimate = try estimate()
  let words = materials.emitterBuffer.contents().assumingMemoryBound(to: UInt32.self)
  let listed = Int(words[0])
  let sorted = (0..<(listed - 1)).allSatisfy { words[1 + $0] < words[2 + $0] }
  let positions = Set((0..<listed).map { words[1 + listed + $0] })
  print("Light tree over the ceiling: \(words[2 * listed + 2]) nodes for \(listed) emitters")
  require(listed == ceiling.count && words[2 * listed + 2] > 0 && sorted && positions.count == listed,
    "with the light tree, every emitter is listed by sorted ID with its own leaf position and the tree follows the list")
  for (k, p) in points.enumerated() {
    let t = treeEstimate[k], w = power[k]
    let exact = reference(SIMD3(Double(p.x), Double(p.y), Double(p.z)))
    let seTree = (t.variance / samplesPerPoint).squareRoot(), sePower = (w.variance / samplesPerPoint).squareRoot()
    print("Light tree at \(p.x), \(p.y), \(p.z): reference \(exact), power \(w.mean) ± \(sePower) (variance \(w.variance)),"
      + " tree \(t.mean) ± \(seTree) (variance \(t.variance)); hits \(t.hits), zero PDFs \(t.zero), max PDF error \(t.error),"
      + " back-facing choices \(t.backFacing) (power \(w.backFacing))")
    require(t.zero == 0 && t.error < 1e-3 && w.zero == 0 && w.error < 1e-3 && (exact == 0 || t.hits > 1000),
      "light samples and BSDF hits agree on the emitter PDF (tree and power) at receiver \(k)")
    require(abs(t.mean - exact) <= 5 * seTree + 1e-3 * exact && abs(w.mean - exact) <= 5 * sePower + 1e-3 * exact,
      "power and light-tree selection both estimate the emitted light without bias at receiver \(k)")
    require(Double(t.backFacing) <= 0.01 * samplesPerPoint, "the light tree rarely chooses an emitter facing away from receiver \(k)")
  }
  // Under a corner of the ceiling, near the slot-8 row and above it, nearby lights dominate.
  require(treeEstimate[1].variance < 0.5 * power[1].variance && treeEstimate[3].variance < 0.5 * power[3].variance
    && treeEstimate[4].variance < 0.5 * power[4].variance, "the light tree lowers the variance where nearby lights dominate")
  // One lamp: triangles sharing their place and facing stay one leaf, so no tree is built (power sampling
  // without the walk); eight separate lights of the ceiling do get one.
  let lamp = (0..<6).map { _ in emitter(1, 1, slot: 8, down: true) }
  try materials.setMesh(lamp)
  let lampEstimates = try estimate()
  require(lampEstimates.allSatisfy { $0.zero == 0 && $0.error < 1e-3 }, "one lamp renders through power sampling")
  let one = materials.emitterBuffer.contents().assumingMemoryBound(to: UInt32.self)
  require(Int(one[0]) == lamp.count && one[2 * lamp.count + 2] == 0, "one lamp's triangles build no tree")
  try materials.setMesh(Array(ceiling.prefix(8)))
  let eight = materials.emitterBuffer.contents().assumingMemoryBound(to: UInt32.self)
  let eightEstimates = try estimate()
  require(eightEstimates.allSatisfy { $0.zero == 0 && $0.error < 1e-3 } && eight[2 * 8 + 2] > 1, "eight separate lights build a tree")
  print("PASS: light tree: well formed, exact PDFs, unbiased against a quadrature reference, lower variance near lights")
}
try fixLightTreeChecks()
