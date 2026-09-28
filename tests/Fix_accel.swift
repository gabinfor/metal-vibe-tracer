// Acceleration structure: the two-level binned-SAH 4-wide BVH (default) against the flat
// median BVH (reference) and brute force, watertight shared edges through instance transforms,
// mirrored instances, edit paths (transform, visibility, bindings, geometry), the fallback seam,
// a large instanced scene, and the Metal hardware intersector gate (REFERENCES.md: WALD2007,
// WIDEBVH2008, WOOP2013, METALRT).
@MainActor func fixAccelChecks() throws {
  func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, subset: Float = 0) -> MeshTriangle {
    let n = simd_normalize(simd_cross(b - a, c - a))
    // Distinct corner normals and UVs make interpolation, tangents and the mirrored b/c swap visible.
    let tilt = SIMD3<Float>(0.2, 0, 0.1)
    return MeshTriangle(a: SIMD4(a, 1), b: SIMD4(b, 1), c: SIMD4(c, 1),
      na: SIMD4(simd_normalize(n + tilt), 0), nb: SIMD4(simd_normalize(n - tilt), 0), nc: SIMD4(n, 0),
      uvab: SIMD4(a.x, a.z, b.x, b.z), uvc: SIMD4(c.x, c.z, subset, 0))
  }
  // A curved N x N height-field patch in [-1, 1]^2 whose quads alternate their diagonal.
  func patch(_ cells: Int, subsets: Int = 1) -> (vertices: [[SIMD3<Float>]], triangles: [MeshTriangle]) {
    var vertices: [[SIMD3<Float>]] = []
    for i in 0...cells {
      vertices.append((0...cells).map { j in
        let x = Float(i) / Float(cells) * 2 - 1, z = Float(j) / Float(cells) * 2 - 1
        return SIMD3(x, 0.15 * sin(1.7 * x + 0.3) * cos(1.3 * z) + 0.05 * x, z)
      })
    }
    var triangles: [MeshTriangle] = []
    for i in 0..<cells {
      for j in 0..<cells {
        let a = vertices[i][j], b = vertices[i + 1][j], c = vertices[i + 1][j + 1], d = vertices[i][j + 1]
        let s = Float((i + j) % subsets)
        triangles += (i + j) % 2 == 0
          ? [triangle(a, b, c, subset: s), triangle(a, c, d, subset: s)] : [triangle(a, b, d, subset: s), triangle(b, c, d, subset: s)]
      }
    }
    return (vertices, triangles)
  }
  func columns(_ m: simd_float4x4) -> [Float] { (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } } }
  func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t, 1)))
  }
  func rotation(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(axis))) }
  func scale(_ s: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(diagonal: SIMD4(s, 1)) }
  // A graph of instances of one asset (subset i bound to material i), one node per matrix.
  func instancedGraph(_ triangles: [MeshTriangle], subsets: Int = 1, _ matrices: [simd_float4x4]) throws -> SceneGraph {
    var graph = SceneGraph()
    let materials = try (0..<subsets).map { try graph.addMaterial("M\($0)") }
    let asset = MeshAsset(name: "asset", triangles: triangles, subsets: (0..<subsets).map { "S\($0)" })
    graph.assets.append(asset)
    for (k, m) in matrices.enumerated() {
      graph.nodes.append(SceneNode(name: "instance \(k)", mesh: asset.id, bindings: materials.map(\.id), matrix: columns(m)))
    }
    try graph.validate()
    return graph
  }
  func library(_ acceleration: MeshAcceleration) throws -> MaterialLibrary {
    let l = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
    l.acceleration = acceleration
    try l.restore(SceneState())
    return l
  }
  func view(_ l: MaterialLibrary, graph: Bool = true) -> Uniforms {
    var u = makeUniforms(scene: 6, mode: 1, width: 1, height: 1)
    u.environment = SIMD4(0, 0, 0, Float(l.nodeCount))
    u.lens.z = graph ? 1 : 0
    u.sunParams.w = 0
    return u
  }

  let kernels = """
  // Per ray (origin.xyz, tMax) + direction: a HitRecord summary, the world triangle of its ID,
  // and occlusion before tMax.
  kernel void ac_trace(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]], constant uint &count [[buffer(4)]], device const float4 *rays [[buffer(5)]],
      uint id [[thread_position_in_grid]]) {
      if(id>=count) return;
      Ray r={rays[2*id].xyz,rays[2*id+1].xyz}; HitRecord h;
      bool hit=trace_scene(r,6,h,images,u);
      device float4 *o=out+7*id;
      o[0]=float4(hit ? h.t : -1.0f, float(h.objectID), float(h.mat.slot), as_type<float>(hit ? h.triangle : 0xffffffffu));
      o[1]=float4(h.position,h.error);
      o[2]=float4(h.geometricNormal,h.front_face ? 1.0f : 0.0f);
      o[3]=float4(h.normal,h.uv.x);
      o[4]=float4(h.tangent,h.uv.y);
      MeshTriangle t=hit && h.triangle!=0xffffffffu ? scene_triangle(h.triangle,images) : MeshTriangle{};
      o[5]=float4(t.a.xyz,scene_occluded(r,6,rays[2*id].w,images,u) ? 1.0f : 0.0f);
      o[6]=float4(t.b.xyz,t.uvc.z);
  }
  // Emitter sampling through instances: the sampled point is hit, its triangle ID round-trips and
  // the BSDF-hit PDF equals the sampling PDF; hist counts selections per rendered-triangle ID.
  kernel void ac_emitters(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]], constant uint &count [[buffer(4)]], device atomic_uint *hist [[buffer(5)]],
      uint id [[thread_position_in_grid]]) {
      if(id>=count) return;
      uint seed=pcg_hash(id*7919u+11u);
      float3 p=float3(0.2f,-0.5f,0.1f), n=float3(0,1,0);
      float hits=0, wrong=0, error=0;
      for(int i=0;i<64;++i) {
          LightSample ls=sample_direct_light(p,n,u,seed,images);
          if(ls.isDirectional<2) continue;
          atomic_fetch_add_explicit(&hist[ls.isDirectional-2],1u,memory_order_relaxed);
          Ray ray={p,ls.wi}; HitRecord rec;
          if(!trace_scene(ray,6,rec,images,u) || rec.mat.type!=EMISSIVE) { wrong+=1; continue; }
          hits+=1;
          if(rec.triangle!=ls.isDirectional-2 && abs(rec.t-ls.dist)>1e-4f*ls.dist) wrong+=1;
          float pdf=eval_light_pdf(p,rec.position,rec.mat,u,images,rec.triangle);
          error=max(error,abs(pdf-ls.pdf)/ls.pdf);
      }
      out[id]=float4(hits,wrong,error,0);
  }
  // Spawned rays from mesh hits (both sides, the hit's error-bounded offset) never re-hit
  // their own surface nearby, and unoccluded light connections are not self-shadowed.
  kernel void ac_self(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]], constant uint &count [[buffer(4)]], device const float4 *rays [[buffer(5)]],
      uint id [[thread_position_in_grid]]) {
      if(id>=count) return;
      Ray r={rays[2*id].xyz,rays[2*id+1].xyz}; HitRecord h;
      float scale=rays[2*id].w;
      out[id]=float4(0);
      if(!trace_scene(r,6,h,images,u) || h.objectID<64) return;
      uint seed=id*977u+3u; float self=0, shadowed=0;
      for(int k=0;k<16;++k) {
          float3 d=sample_cosine_hemisphere(k<8 ? h.geometricNormal : -h.geometricNormal,seed);
          Ray next={ray_origin(h.position,h.geometricNormal,d,u,h.error),d}; HitRecord s;
          if(trace_scene(next,6,s,images,u) && s.objectID==h.objectID && s.t<1e-3f*scale) self+=1;
          if(k>=8) continue;
          // Far from the origin a connection must outlast the endpoint tolerance to be tested at all.
          LightSample ls={}; ls.position=h.position+max(0.05f*scale,1000.0f*h.error)*d; ls.wi=d; ls.pdf=1; ls.isDirectional=0;
          if(!light_visible(h.position,h.geometricNormal,ls,6,images,u,h.error)) shadowed+=1;
      }
      out[id]=float4(1,self,shadowed,h.error);
  }
  // Brute force over a flat library's world-space triangles (and the analytic floor).
  kernel void ac_brute(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]], constant uint &count [[buffer(4)]], device const float4 *rays [[buffer(5)]],
      constant uint &triangles [[buffer(6)]], uint id [[thread_position_in_grid]]) {
      if(id>=count) return;
      Ray r={rays[2*id].xyz,rays[2*id+1].xyz};
      float tMin=ray_t_min(r.origin,u), best=1e20f; int index=-1; HitRecord p;
      if(trace_scene(r,6,p,images.objects,u.light.w,u.light.xyz,tMin)) best=p.t;
      WatertightRay w=watertight_ray(r);
      for(uint i=0;i<triangles;++i) { float t,b1,b2; if(intersect_mesh_triangle(images.triangles[i],w,tMin,best,t,b1,b2)) { best=t; index=int(i); } }
      out[id]=float4(best<1e19f ? best : -1.0f, float(index), 0, 0);
  }
  """
  let checks = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  func dispatch(_ name: String, _ l: MaterialLibrary, _ u: Uniforms, rays: [SIMD4<Float>], stride: Int, extra: UInt32 = 0) throws -> [SIMD4<Float>] {
    var input = u, count = UInt32(rays.count / 2), e = extra
    guard let function = checks.makeFunction(name: name),
      let out = gpu.makeBuffer(length: max(16, Int(count) * stride * 16), options: .storageModeShared),
      let rayBuffer = rays.withUnsafeBytes({ gpu.makeBuffer(bytes: $0.baseAddress!, length: max(16, $0.count), options: .storageModeShared) }),
      let command = testRenderer.commandQueue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
    else { throw MaterialLibrary.error("Could not encode \(name).") }
    let pipeline = try gpu.makeComputePipelineState(function: function)
    encoder.setComputePipelineState(pipeline)
    require(l.bind(encoder), "\(name) binds scene resources")
    encoder.setBytes(&input, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setBuffer(out, offset: 0, index: 3)
    encoder.setBytes(&count, length: 4, index: 4)
    encoder.setBuffer(rayBuffer, offset: 0, index: 5)
    encoder.setBytes(&e, length: 4, index: 6)
    encoder.dispatchThreads(MTLSize(width: Int(count), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) GPU command")
    return Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: SIMD4<Float>.self, capacity: Int(count) * stride),
      count: Int(count) * stride))
  }
  func emitterDispatch(_ l: MaterialLibrary, _ u: Uniforms, threads: Int, bins: Int) throws -> ([SIMD4<Float>], [UInt32]) {
    var input = u, count = UInt32(threads)
    guard let function = checks.makeFunction(name: "ac_emitters"),
      let out = gpu.makeBuffer(length: threads * 16, options: .storageModeShared),
      let hist = gpu.makeBuffer(length: max(4, bins * 4), options: .storageModeShared),
      let command = testRenderer.commandQueue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
    else { throw MaterialLibrary.error("Could not encode ac_emitters.") }
    memset(hist.contents(), 0, max(4, bins * 4))
    encoder.setComputePipelineState(try gpu.makeComputePipelineState(function: function))
    require(l.bind(encoder), "ac_emitters binds scene resources")
    encoder.setBytes(&input, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setBuffer(out, offset: 0, index: 3)
    encoder.setBytes(&count, length: 4, index: 4)
    encoder.setBuffer(hist, offset: 0, index: 5)
    encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "ac_emitters GPU command")
    return ((0..<threads).map { out.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) },
      (0..<bins).map { hist.contents().load(fromByteOffset: $0 * 4, as: UInt32.self) })
  }
  struct Hit {
    var t: Float, object: Int, slot: Int, triangle: UInt32, position: SIMD3<Float>, error: Float
    var geometric: SIMD3<Float>, front: Bool, normal: SIMD3<Float>, uv: SIMD2<Float>, tangent: SIMD3<Float>
    var a: SIMD3<Float>, b: SIMD3<Float>, occluded: Bool, triangleSlot: Float
  }
  func trace(_ l: MaterialLibrary, _ rays: [SIMD4<Float>], graph: Bool = true) throws -> [Hit] {
    let o = try dispatch("ac_trace", l, view(l, graph: graph), rays: rays, stride: 7)
    return (0..<(rays.count / 2)).map { i in
      let v = Array(o[(7 * i)..<(7 * i + 7)])
      func xyz(_ p: SIMD4<Float>) -> SIMD3<Float> { SIMD3(p.x, p.y, p.z) }
      return Hit(t: v[0].x, object: Int(v[0].y), slot: Int(v[0].z), triangle: v[0].w.bitPattern, position: xyz(v[1]), error: v[1].w,
        geometric: xyz(v[2]), front: v[2].w > 0.5, normal: xyz(v[3]), uv: SIMD2(v[3].w, v[4].w), tangent: xyz(v[4]),
        a: xyz(v[5]), b: xyz(v[6]), occluded: v[5].w > 0.5, triangleSlot: v[6].w)
    }
  }
  var seed: UInt32 = 20260928
  func random() -> Float {
    seed = seed &* 1_664_525 &+ 1_013_904_223
    return Float(seed >> 8) / Float(1 << 24)
  }
  func unit() -> SIMD3<Float> {
    while true {
      let v = SIMD3(random(), random(), random()) * 2 - 1
      if simd_length_squared(v) > 1e-4 && simd_length_squared(v) <= 1 { return simd_normalize(v) }
    }
  }

  // Sections 1-6 run on the default software traversal and, where the device supports it, on
  // the hardware one (the gate; MaterialLibrary.defaultAcceleration stays two-level).
  func gate(_ mode: MeshAcceleration) throws {
    // 1. Parity: a scattered soup and curved patches under identity, rotated, scaled, mirrored and
    // far-translated instances. The two-level hits equal brute force over the flattened scene and the
    // flat BVH: same surface (world triangle), t within the hit's own error bound.
    do {
      var soup: [MeshTriangle] = []
      for _ in 0..<4000 {
        let c = SIMD3(random(), random(), random()) * 2 - 1
        let e = { SIMD3(random(), random(), random()) * 0.2 - 0.1 }
        let a = c + e(), b = c + e(), d = c + e()
        if simd_length(simd_cross(b - a, d - a)) > 1e-4 { soup.append(triangle(a, b, d)) }
      }
      let (_, surface) = patch(48, subsets: 2)
      var graph = SceneGraph()
      let m0 = try graph.addMaterial("A"), m1 = try graph.addMaterial("B")
      let soupAsset = MeshAsset(name: "soup", triangles: soup, subsets: ["S"])
      let patchAsset = MeshAsset(name: "patch", triangles: surface, subsets: ["S0", "S1"])
      graph.assets += [soupAsset, patchAsset]
      let placements: [(MeshAsset, simd_float4x4)] = [
        (soupAsset, matrix_identity_float4x4),
        (soupAsset, translation(SIMD3(3.5, 0.2, 0)) * rotation(0.7, SIMD3(1, 2, 3)) * scale(SIMD3(0.5, 0.5, 0.5))),
        (patchAsset, translation(SIMD3(0, 0, 3))),
        (patchAsset, translation(SIMD3(3, 0, 3)) * scale(SIMD3(-1, 1, 1))),  // mirrored
        (patchAsset, translation(SIMD3(-3, 0.3, 0)) * rotation(-0.4, SIMD3(0, 0, 1)) * scale(SIMD3(1.6, 0.4, 0.9))),
        (patchAsset, translation(SIMD3(-3, 0, 3.2)) * rotation(2.1, SIMD3(0, 1, 0)) * scale(SIMD3(1, -1, 1))),  // mirrored
      ]
      for (k, (asset, m)) in placements.enumerated() {
        graph.nodes.append(SceneNode(name: "n\(k)", mesh: asset.id, bindings: asset.subsets.count == 1 ? [m0.id] : [m0.id, m1.id], matrix: columns(m)))
      }
      try graph.validate()
      let two = try library(mode), flat = try library(.flat)
      try two.setMesh(graph); try flat.setMesh(graph)
      two.hasSceneGraph = true; flat.hasSceneGraph = true
      require(two.meshLayout?.instances.count == placements.count && two.renderedTriangleCount == flat.triangleCount
        && two.triangleCount == soup.count + surface.count, "two-level layout stores each asset once and renders every instance")
      // Random rays through the scene, then rays aimed at every patch instance's interior vertices
      // and interior edge points from eyes above it (the adversarial case for cracks; the soup has
      // no shared edges, so its corners are silhouettes, not cracks).
      var rays: [SIMD4<Float>] = [], kinds: [Int] = []
      for _ in 0..<60_000 {
        let o = SIMD3(random() * 10 - 5, random() * 4 - 1.5, random() * 8 - 2.5)
        rays += [SIMD4(o, 0.2 + 6 * random()), SIMD4(unit(), 0)]
        kinds.append(0)
      }
      let (grid, _) = patch(48, subsets: 2)
      for (k, (asset, m)) in placements.enumerated() where asset.id == patchAsset.id {
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { let v = m * SIMD4(p, 1); return SIMD3(v.x, v.y, v.z) }
        let identity = MeshSceneLayout.linear(m) == matrix_identity_float3x3
        var targets: [SIMD3<Float>] = []
        for i in 1..<48 { for j in 1..<48 { targets.append(grid[i][j]) } }
        for i in 1..<47 { for j in 1..<47 { for f in [Float(0.25), 0.5, 0.75] {
          targets += [grid[i][j] + (grid[i + 1][j] - grid[i][j]) * f, grid[i][j] + (grid[i][j + 1] - grid[i][j]) * f]
        } } }
        for (q, target) in targets.enumerated() where q % 3 == k % 3 {
          let eye = world(SIMD3(0.3 * sin(Float(q)), 2.5, 0.3 * cos(Float(q))))
          let p = world(target)
          rays += [SIMD4(eye, simd_length(p - eye) * 1.001), SIMD4(simd_normalize(p - eye), 0)]
          kinds.append(identity ? 1 : 2)
        }
      }
      let a = try trace(two, rays), b = try trace(flat, rays)
      let brute = try dispatch("ac_brute", flat, view(flat), rays: rays, stride: 1, extra: UInt32(flat.triangleCount))
      var misses = [0, 0, 0], triangles = [0, 0, 0], worst: [Float] = [0, 0, 0], faces = 0, occlusion = 0, ties = 0, meshHits = 0
      for i in a.indices {
        let x = a[i], y = b[i], reference = brute[i].x, kind = kinds[i]
        if (x.t < 0) != (reference < 0) || (kind > 0 && x.t < 0) { misses[kind] += 1; continue }
        if x.t < 0 { continue }
        worst[kind] = max(worst[kind], abs(x.t - reference) / max(1e-30, x.error))
        if x.occluded != y.occluded && abs(rays[2 * i].w - x.t) > 2 * x.error { occlusion += 1 }
        guard x.object >= 64 || y.object >= 64 else { continue }
        meshHits += 1
        // The rendered-triangle ID names the flat BVH's world triangle, except at an exact tie on a
        // shared edge (equal t), where either neighbour is the closest hit.
        let same = simd_length(x.a - y.a) <= 1e-5 * max(1, simd_length(y.a)) && simd_length(x.b - y.b) <= 1e-5 * max(1, simd_length(y.b))
        let tie = abs(x.t - y.t) <= x.error + y.error
        if x.object != y.object || Float(x.slot) != x.triangleSlot || (same ? x.slot != y.slot : !tie) { triangles[kind] += 1 }
        if !same && tie { ties += 1 }
        if same, x.front != y.front || simd_dot(x.geometric, y.geometric) < 0.9999 || simd_dot(x.normal, y.normal) < 0.999 { faces += 1 }
      }
      print("\(mode) parity: \(a.count) rays (random, translated-instance edges, transformed-instance edges): misses \(misses), \(meshHits) mesh hits, triangle/slot/ID mismatches \(triangles) (\(ties) shared-edge ties), worst |t - brute| / error \(worst), orientation \(faces), occlusion \(occlusion)")
      require(misses == [0, 0, 0] && triangles == [0, 0, 0] && worst.allSatisfy({ $0 <= 1 }) && faces == 0 && occlusion == 0,
        "two-level traversal matches brute force and the flat BVH through instance transforms")
    }
    print("PASS: fix-accel \(mode) two-level parity with brute force and the flat BVH")

    // 2. Watertightness through transforms: rays at interior shared edges and vertices of patch
    // instances (translated, rotated, non-uniformly scaled, mirrored, 1 km away) always hit, as
    // closest and as any hit. A graph-less mesh (identity instance) is bit-exact with brute force.
    do {
      let cells = 24
      let (grid, surface) = patch(cells)
      let matrices = [
        matrix_identity_float4x4, translation(SIMD3(4, 0.5, -2)) * rotation(0.9, SIMD3(1, 3, 2)) * scale(SIMD3(2.5, 0.7, 1.3)),
        translation(SIMD3(-4, 0, 1)) * scale(SIMD3(1, 1, -1)), translation(SIMD3(1000, 20, -700)) * rotation(-2.3, SIMD3(0.2, 1, 0.1)),
        translation(SIMD3(0, 3, 6)) * rotation(0.3, SIMD3(0, 0, 1)) * scale(SIMD3(-0.01, 0.01, 0.01)),
      ]
      let graph = try instancedGraph(surface, matrices)
      let two = try library(mode)
      try two.setMesh(graph); two.hasSceneGraph = true
      var rays: [SIMD4<Float>] = []
      for m in matrices {
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { let v = m * SIMD4(p, 1); return SIMD3(v.x, v.y, v.z) }
        var targets: [SIMD3<Float>] = []
        for i in 1..<cells { for j in 1..<cells { targets.append(grid[i][j]) } }
        for i in 0..<cells { for j in 0..<cells {
          let a = grid[i][j], b = grid[i + 1][j], c = grid[i + 1][j + 1], d = grid[i][j + 1]
          for f in [Float(0.25), 0.5, 0.75] {
            if j > 0 { targets.append(a + (b - a) * f) }
            if i > 0 { targets.append(a + (d - a) * f) }
            targets.append((i + j) % 2 == 0 ? a + (c - a) * f : b + (d - b) * f)
          }
        } }
        for eye in [SIMD3<Float>(0.3, 3, 0.2), SIMD3(4, 3.5, -3), SIMD3(0.05, 20, 0.01), SIMD3(-0.4, 9, -12)] {
          let e = world(eye)
          for target in targets {
            let p = world(target)
            rays += [SIMD4(e, simd_length(p - e) * 1.001), SIMD4(simd_normalize(p - e), 0)]
          }
        }
      }
      let hits = try trace(two, rays)
      let closestMisses = hits.filter { $0.t < 0 || $0.object < 64 }.count, anyMisses = hits.filter { !$0.occluded }.count
      print("\(mode) instanced watertightness: \(hits.count) rays at shared edges/vertices of \(matrices.count) instances, \(closestMisses) closest-hit misses, \(anyMisses) any-hit misses")
      require(closestMisses == 0 && anyMisses == 0, "rays at shared edges and vertices never pass between instanced triangles")

      // Graph-less mesh: one identity instance, so the object-space ray is the world ray itself.
      let legacy = try library(mode), reference = try library(.flat)
      try legacy.setMesh(surface); try reference.setMesh(surface)
      var probes: [SIMD4<Float>] = []
      for _ in 0..<20_000 {
        let o = SIMD3<Float>(random() * 4 - 2, random() * 2 + 0.2, random() * 4 - 2)
        probes += [SIMD4(o, 5), SIMD4(simd_normalize(unit() - SIMD3<Float>(0, 0.8, 0)), 0)]
      }
      let x = try trace(legacy, probes, graph: false), y = try trace(reference, probes, graph: false)
      let brute = try dispatch("ac_brute", reference, view(reference, graph: false), rays: probes, stride: 1, extra: UInt32(surface.count))
      // Software: the identity instance's object-space ray is the world ray, so t matches brute
      // force bit for bit (the rebuilt point may differ by the compiler's FMA contraction, an ulp).
      // Hardware: Metal's own triangle test, so t within the hit's error bound.
      let exact = mode != .hardware
      let inexact = x.indices.filter { i in
        exact ? x[i].t != brute[i].x || y[i].t != brute[i].x : (x[i].t < 0) != (brute[i].x < 0) || abs(x[i].t - brute[i].x) > x[i].error
      }.count
      let different = x.indices.filter { i in
        let tie = abs(x[i].t - y[i].t) <= x[i].error + y[i].error && x[i].a != y[i].a
        return x[i].t >= 0 && x[i].object >= 7 && !(tie && !exact)
          && (simd_distance(x[i].position, y[i].position) > (exact ? 0x1p-22 * simd_reduce_max(simd_abs(y[i].position)) : 2 * (x[i].error + y[i].error))
            || x[i].front != y[i].front || x[i].a != y[i].a || simd_dot(x[i].normal, y[i].normal) < 0.99999)
      }.count
      print("\(mode) graph-less mesh: \(probes.count / 2) rays, \(inexact) \(exact ? "not bit-exact with" : "outside the error bound of") brute force, \(different) hit records differ from the flat BVH")
      require(inexact == 0 && different == 0, "an identity instance reproduces the flat BVH's hits")
    }
    print("PASS: fix-accel \(mode) watertight shared edges through instance transforms; identity instances are exact")

    // 3. Mirrored instances render like their flattened copies: hit records (position, both normals,
    // front face, UVs, tangent, slot, object, rendered-triangle ID) agree with the flat BVH.
    do {
      let (_, surface) = patch(32, subsets: 2)
      let matrices = [scale(SIMD3(-1, 1, 1)), translation(SIMD3(3, 3, 0)) * scale(SIMD3(1, -1, 1)) * rotation(0.5, SIMD3(0, 1, 0)),
        translation(SIMD3(0, 0, 3)) * scale(SIMD3(-2, 0.5, -1.5))]
      let graph = try instancedGraph(surface, subsets: 2, matrices)
      let two = try library(mode), flat = try library(.flat)
      try two.setMesh(graph); try flat.setMesh(graph)
      two.hasSceneGraph = true; flat.hasSceneGraph = true
      var rays: [SIMD4<Float>] = []
      for m in matrices {
        for _ in 0..<3000 {
          let local = SIMD3(random() * 1.8 - 0.9, 0, random() * 1.8 - 0.9)
          let target = m * SIMD4(local, 1), eye = m * SIMD4(local + SIMD3(random() - 0.5, 2, random() - 0.5), 1)
          let e = SIMD3(eye.x, eye.y, eye.z), t = SIMD3(target.x, target.y, target.z)
          rays += [SIMD4(e, 10), SIMD4(simd_normalize(t - e), 0)]
        }
      }
      let x = try trace(two, rays), y = try trace(flat, rays)
      var mismatched = 0, compared = [0, 0, 0]
      for i in x.indices where x[i].object >= 64 && y[i].object >= 64 {
        let a = x[i], b = y[i]
        guard simd_distance(a.a, b.a) <= 1e-5 * max(1, simd_length(b.a)) else { continue }  // shared-edge ties
        compared[i / 3000] += 1
        if simd_distance(a.position, b.position) > 2 * (a.error + b.error) || a.front != b.front
          || simd_dot(a.geometric, b.geometric) < 0.9999 || simd_dot(a.normal, b.normal) < 0.9999
          || simd_distance(a.uv, b.uv) > 1e-3 || simd_dot(a.tangent, b.tangent) < 0.999
          || a.slot != b.slot || a.object != b.object || simd_distance(a.b, b.b) > 1e-5 * max(1, simd_length(b.b))
        { mismatched += 1 }
      }
      print("\(mode) mirrored instances: \(compared) hits on the same world triangle, \(mismatched) hit records differ")
      require(compared.allSatisfy { $0 > 1500 } && mismatched == 0, "mirrored and negatively scaled instances keep the flattened winding, normals and UVs")
    }
    print("PASS: fix-accel \(mode) mirrored instances match their flattened copies")

    // 4. Instanced emitters: every rendered emissive triangle joins the list with its world area,
    // samples round-trip through their rendered-triangle IDs and the BSDF-hit PDF is exact.
    do {
      let quad = [triangle(SIMD3(-0.5, 0, -0.5), SIMD3(0.5, 0, 0.5), SIMD3(0.5, 0, -0.5)),
        triangle(SIMD3(-0.5, 0, -0.5), SIMD3(-0.5, 0, 0.5), SIMD3(0.5, 0, 0.5))]
      let matrices = [translation(SIMD3(-1, 1, 0)), translation(SIMD3(1, 1.2, 0)) * scale(SIMD3(2, 1, 1)),
        translation(SIMD3(0, 1.5, 1.5)) * scale(SIMD3(-0.5, 1, 1)) * rotation(0.4, SIMD3(0, 1, 0))]
      let graph = try instancedGraph(quad, matrices)
      let two = try library(mode), flat = try library(.flat)
      let slot = graph.materials[0].slot
      for l in [two, flat] { l.emissions = [slot: SIMD3(3, 3, 3)]; try l.setMesh(graph); l.hasSceneGraph = true }
      let listed = { (l: MaterialLibrary) in Int(l.emitterBuffer.contents().load(as: UInt32.self)) }
      let totals = [two, flat].map { l in l.emitterBuffer.contents().load(fromByteOffset: 4 * (2 * listed(l) + 1), as: Float.self) }
      require(listed(two) == 6 && listed(flat) == 6 && abs(totals[0] - totals[1]) <= 1e-6 * totals[1],
        "instanced emitters: one entry per rendered triangle, world areas (\(totals))")
      let (results, selections) = try emitterDispatch(two, view(two), threads: 2048, bins: 6)
      let hits = results.reduce(0) { $0 + $1.x }, wrong = results.reduce(0) { $0 + $1.y }, error = results.map(\.z).max() ?? 1
      // Selection probability follows world area: 1, 2 and 0.5 per instance.
      let total = Double(selections.reduce(0, +))
      var byInstance = [Double](repeating: 0, count: 3)
      for (id, n) in selections.enumerated() {
        guard let (instance, _) = two.meshLayout?.locate(id) else { continue }
        byInstance[instance] += Double(n) / total
      }
      print("\(mode) instanced emitters: \(hits) hits, \(wrong) wrong, max PDF error \(error), selection by instance \(byInstance)")
      require(hits > 50_000 && wrong == 0 && error < 1e-3
        && abs(byInstance[0] - 1 / 3.5) < 0.01 && abs(byInstance[1] - 2 / 3.5) < 0.01 && abs(byInstance[2] - 0.5 / 3.5) < 0.01,
        "instanced emitter samples, IDs and PDFs are consistent")
    }
    print("PASS: fix-accel \(mode) instanced emitters are power sampled by world area with exact PDFs")

    // 5. Error-bounded offsets through large and small instance scales and far translations.
    do {
      let (_, surface) = patch(40)
      let scales: [Float] = [1, 1000, 0.001, 1, 50]
      let matrices = [matrix_identity_float4x4, translation(SIMD3(0, 0, 5000)) * scale(SIMD3(repeating: 1000)),
        translation(SIMD3(-3, 0, 0)) * scale(SIMD3(repeating: 0.001)), translation(SIMD3(20000, 300, -10000)) * rotation(1.1, SIMD3(1, 1, 0)),
        translation(SIMD3(0, 0, -400)) * scale(SIMD3(50, 5, 50)) * rotation(0.6, SIMD3(0, 1, 0))]
      let graph = try instancedGraph(surface, matrices)
      let two = try library(mode)
      try two.setMesh(graph); two.hasSceneGraph = true
      var rays: [SIMD4<Float>] = []
      for (m, s) in zip(matrices, scales) {
        for _ in 0..<2048 {
          let local = SIMD3(random() * 1.8 - 0.9, 0.1, random() * 1.8 - 0.9)
          let target = m * SIMD4(local, 1), eye = m * SIMD4(local + SIMD3(0.3 * random(), 2, 0.3 * random()), 1)
          let e = SIMD3(eye.x, eye.y, eye.z), t = SIMD3(target.x, target.y, target.z)
          rays += [SIMD4(e, s), SIMD4(simd_normalize(t - e), 0)]
        }
      }
      // The flat BVH over the flattened scene is the reference: the curved patch may occlude a
      // grazing connection, but only as the flattened geometry does.
      let flat = try library(.flat)
      try flat.setMesh(graph); flat.hasSceneGraph = true
      let results = try dispatch("ac_self", two, view(two), rays: rays, stride: 1)
      let expected = try dispatch("ac_self", flat, view(flat), rays: rays, stride: 1)
      let hits = results.reduce(0) { $0 + $1.x }, selfHits = results.reduce(0) { $0 + $1.y }, shadowed = results.reduce(0) { $0 + $1.z }
      let flatSelf = expected.reduce(0) { $0 + $1.y }, flatShadowed = expected.reduce(0) { $0 + $1.z }
      print("\(mode) instanced microgeometry: \(hits) hits, \(selfHits) self-intersections, \(shadowed) occluded connections (flattened scene: \(flatSelf), \(flatShadowed))")
      require(hits > 9000 && selfHits == 0 && shadowed <= flatShadowed, "instanced hits spawn rays off their own surface at every scale")
    }
    print("PASS: fix-accel \(mode) error-bounded offsets through instance scales and translations")

    // 6. Edit paths: transform and visibility edits rebuild only the top level (the triangle buffer
    // and every asset hierarchy are kept), binding edits only the slot table, and a geometry edit
    // rebuilds only the assets whose triangles changed. Hits follow each edit.
    do {
      let (_, first) = patch(20), (_, second) = patch(12)
      var graph = SceneGraph()
      let m0 = try graph.addMaterial("A"), m1 = try graph.addMaterial("B")
      let a0 = MeshAsset(name: "first", triangles: first, subsets: ["S"]), a1 = MeshAsset(name: "second", triangles: second, subsets: ["S"])
      graph.assets += [a0, a1]
      graph.nodes.append(SceneNode(name: "a", mesh: a0.id, bindings: [m0.id]))
      graph.nodes.append(SceneNode(name: "b", mesh: a0.id, transform: ObjectSettings(positionScale: SIMD4(3, 0, 0, 1)), bindings: [m0.id]))
      graph.nodes.append(SceneNode(name: "c", mesh: a1.id, transform: ObjectSettings(positionScale: SIMD4(-3, 0, 0, 1)), bindings: [m1.id]))
      try graph.validate()
      let l = try library(mode)
      try l.setMesh(graph); l.hasSceneGraph = true
      func probe(_ x: Float) throws -> Hit { try trace(l, [SIMD4(x, 3, 0.1, 10), SIMD4(0, -1, 0, 0)])[0] }
      var hit = try probe(3)
      // Hardware traversal builds a primitive acceleration structure beside each software BLAS.
      let perAsset = mode == .hardware ? 2 : 1
      require(l.assetBuildCount == 2 * perAsset && l.sceneBuildCount == 1 && hit.object == 65, "initial publish builds both assets once")
      let buffer = l.triangleBuffer!, builds = l.assetBuildCount
      var moved = graph
      moved.nodes[1].transform.positionScale.x = 6
      try l.setMesh(moved)
      hit = try probe(6)
      var vacated = try probe(3)
      require(l.triangleBuffer === buffer && l.assetBuildCount == builds && l.sceneBuildCount == 2
        && hit.object == 65 && vacated.object < 64, "a transform edit rebuilds only the top level")
      var hidden = moved
      hidden.nodes[2].transform.rotationHidden.w = 1
      try l.setMesh(hidden)
      vacated = try probe(-3)
      require(l.triangleBuffer === buffer && l.assetBuildCount == builds && l.renderedTriangleCount == 2 * first.count
        && vacated.object < 64, "a visibility edit rebuilds only the top level")
      var rebound = hidden
      rebound.nodes[1].bindings = [m1.id]
      let meshBuilds = l.meshBuildCount, instances = l.meshLayout?.scene
      try l.setMeshBindings(rebound)
      hit = try probe(6)
      let kept = try probe(0)
      require(l.triangleBuffer === buffer && l.assetBuildCount == builds && l.meshBuildCount == meshBuilds
        && hit.slot == m1.slot && kept.slot == m0.slot && l.meshLayout?.scene === instances
        && (mode != .hardware || instances != nil), "a binding edit rewrites only the slot table (no acceleration-structure work)")
      var edited = rebound
      edited.assets[1].triangles = patch(14).triangles
      edited.nodes[2].transform.rotationHidden.w = 0
      let firstRegion = l.meshLayout!.assets[0]
      let before = Data(bytes: l.triangleBuffer.contents().advanced(by: firstRegion.triangleBase * 128), count: firstRegion.count * 128)
      try l.setMesh(edited)
      let reused = l.meshLayout!.assets[0]
      let after = Data(bytes: l.triangleBuffer.contents().advanced(by: reused.triangleBase * 128), count: reused.count * 128)
      let nodesBefore = Data(bytes: buffer.contents().advanced(by: firstRegion.nodeBase * 128), count: firstRegion.nodeCount * 128)
      let nodesAfter = Data(bytes: l.triangleBuffer.contents().advanced(by: reused.nodeBase * 128), count: reused.nodeCount * 128)
      hit = try probe(-3)
      require(l.triangleBuffer !== buffer && l.assetBuildCount == builds + perAsset && before == after && nodesBefore == nodesAfter
        && l.triangleCount == first.count + 2 * 14 * 14 && hit.object == 66, "a geometry edit rebuilds only the edited asset")
      // The same paths through the studio controller (undoable edits of the live library), unless
      // the suite runs on the flat reference path (VIBE_ACCELERATION=flat).
      var document = ProjectDocument()
      document.scene = 6; document.graph = graph; document.version = 2
      try controller.restore(document)
      let live = testRenderer.materials
      if live.acceleration != .flat {
        let liveBuffer = live.triangleBuffer!, liveBuilds = live.assetBuildCount
        let history = controller.history, grouping = history.groupsByEvent
        history.groupsByEvent = false
        defer { history.groupsByEvent = grouping }
        func grouped(_ body: () -> Void) { history.beginUndoGrouping(); body(); history.endUndoGrouping() }
        func settle() {
          let deadline = Date().addingTimeInterval(30)
          while controller.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
      }
      grouped { controller.editGraph("Move instance") { g in g.nodes[1].transform.positionScale.z = 2 } }
      grouped { controller.editGraph("Hide instance") { g in g.nodes[2].transform.rotationHidden.w = 1 } }
      grouped { controller.editGraph("Rebind", kind: .bindings) { g in g.nodes[0].bindings = [m1.id] } }
      require(live === testRenderer.materials && live.triangleBuffer === liveBuffer && live.assetBuildCount == liveBuilds
        && live.meshLayout?.instances.count == 2, "studio transform, visibility and binding edits keep every asset hierarchy")
      for _ in 0..<3 { history.undo(); settle() }
      // Undo may publish a prepared candidate library; it adopts the live buffers instead of building.
      let restored = testRenderer.materials
      require(restored.triangleBuffer === liveBuffer && restored.meshLayout?.instances.count == 3
        && restored.assetBuildCount == (restored === live ? liveBuilds : 0) && controller.project.graph?.nodes[1].transform.positionScale.z == 0,
        "undoing transform, visibility and binding edits rebuilds no asset hierarchy")
      }
      try controller.restore(ProjectDocument())
    }
    print("PASS: fix-accel \(mode) edit paths: transforms, visibility and bindings keep asset hierarchies; geometry edits rebuild only edited assets")

  }
  try gate(.twoLevel)
  if gpu.supportsRaytracing { try gate(.hardware) }

  // 7. The fallback seam and production rendering: VIBE_ACCELERATION=flat (test builds only)
  // selects the reference path for new libraries, and renderFrame gives the same image on both.
  func camera(_ input: Uniforms, eye: SIMD3<Float>, target: SIMD3<Float>) -> Uniforms {
    var u = input
    u.cameraPos = SIMD4(eye, 40); u.cameraTarget = SIMD4(target, 8)
    u.currentViewProj = makePerspective(fovyRadians: 40 * .pi / 180, aspect: Float(u.width) / Float(u.height), near: 0.05, far: 500)
      * makeLookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
    u.prevViewProj = u.currentViewProj
    return u
  }
  do {
    let prior = ProcessInfo.processInfo.environment["VIBE_ACCELERATION"]
    setenv("VIBE_ACCELERATION", "flat", 1)
    let forced = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
    unsetenv("VIBE_ACCELERATION")
    let normal = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
    let unforced = MaterialLibrary.defaultAcceleration
    if let prior { setenv("VIBE_ACCELERATION", prior, 1) }
    let expected: MeshAcceleration = MaterialLibrary.hardwareWatertight ? .hardware : .twoLevel
    require(forced.acceleration == .flat && normal.acceleration == expected && unforced == expected,
      "the VIBE_ACCELERATION test seam selects the flat reference path; the default follows the hardware gate")
    let (_, surface) = patch(64)
    var means: [MeshAcceleration: Float] = [:]
    let saved = testRenderer.materials.acceleration
    for mode in [MeshAcceleration.flat, .twoLevel] + (gpu.supportsRaytracing ? [.hardware] : []) {
      testRenderer.materials.acceleration = mode
      try testRenderer.materials.restore(SceneState())
      try testRenderer.materials.setMesh(surface)
      testRenderer.materials.hasSceneGraph = false
      var u = camera(makeUniforms(scene: 6, mode: 1, width: 96, height: 72), eye: SIMD3(1.5, 1.6, -2.2), target: SIMD3(0, -0.2, 0))
      u.environment.w = Float(testRenderer.materials.nodeCount)
      means[mode] = mean(render(u, samples: 8))
    }
    testRenderer.materials.acceleration = saved
    try testRenderer.materials.setMesh([])
    let flatMean = means[.flat] ?? 0, twoMean = means[.twoLevel] ?? 0, hardwareMean = means[.hardware] ?? flatMean
    print("Production render, flat / two-level / hardware: mean radiance \(flatMean) / \(twoMean) / \(hardwareMean)")
    // Software paths intersect identically; Metal's triangle test differs within the error bounds.
    require(flatMean > 0 && abs(flatMean - twoMean) <= 1e-4 * flatMean && abs(flatMean - hardwareMean) <= 2e-3 * flatMean,
      "every path renders the same image")
  }
  print("PASS: fix-accel VIBE_ACCELERATION fallback seam and identical production renders")

  // 8. A large instanced scene: 40 instances of a 199,712-triangle asset (7,988,480 rendered, 16x
  // the former 500,000 cap) in one stored copy, rendered through renderFrame; the flat path refuses
  // it. GPU time against the flat BVH on the largest scene both can hold (5 instances).
  do {
    let (_, surface) = patch(316)
    func grid(_ count: Int) -> [simd_float4x4] {
      (0..<count).map { k in translation(SIMD3(Float(k % 8) * 2.2 - 7.7, 0, Float(k / 8) * 2.2 - 4.4)) * rotation(Float(k) * 0.37, SIMD3(0, 1, 0)) }
    }
    let big = try instancedGraph(surface, grid(40))
    let flat = try library(.flat)
    var refused = false
    do { try flat.setMesh(big) } catch { refused = true }
    require(refused, "the flat BVH refuses more than \(SceneLimits.triangles) rendered triangles")
    let saved = testRenderer.materials.acceleration
    func timed(_ graph: SceneGraph, _ mode: MeshAcceleration, eye: SIMD3<Float>) throws -> (build: Double, gpu: Double, mean: Float, bytes: UInt64) {
      testRenderer.materials.acceleration = mode
      try testRenderer.materials.restore(SceneState())
      try testRenderer.materials.setMesh([])
      let start = Date()
      try testRenderer.materials.setMesh(graph)
      let build = Date().timeIntervalSince(start) * 1000
      testRenderer.materials.hasSceneGraph = true
      var u = camera(makeUniforms(scene: 6, mode: 1, width: 320, height: 240), eye: eye, target: SIMD3(0, -0.3, 0))
      u.environment.w = Float(testRenderer.materials.nodeCount)
      u.lens.z = 1
      frameMilliseconds = []
      let pixels = render(u, samples: 12)
      let times = frameMilliseconds.dropFirst(4).sorted()
      return (build, times[times.count / 2], mean(pixels), testRenderer.materials.meshBytes)
    }
    let large = try timed(big, .twoLevel, eye: SIMD3(2, 6, -10))
    let layout = testRenderer.materials.meshLayout
    print(String(format: "Instanced scene: %d rendered triangles from %d stored, %.1f MiB mesh memory (the flattened scene alone would need %.1f MiB), build %.0f ms, median frame %.2f ms (320x240, MIS, depth 8)",
      testRenderer.materials.renderedTriangleCount, testRenderer.materials.triangleCount, Double(large.bytes) / 1_048_576,
      Double(testRenderer.materials.renderedTriangleCount * 128) / 1_048_576, large.build, large.gpu))
    require(testRenderer.materials.renderedTriangleCount == 40 * surface.count && testRenderer.materials.triangleCount == surface.count
      && layout?.instances.count == 40 && large.mean > 0 && large.bytes < 64 * 1_048_576,
      "40 instances render from one stored asset in bounded memory")
    if gpu.supportsRaytracing {
      let hardwareLarge = try timed(big, .hardware, eye: SIMD3(2, 6, -10))
      print(String(format: "Instanced scene, hardware traversal: %.1f MiB mesh memory, build %.0f ms, median frame %.2f ms (software %.2f ms); mean radiance %.5f vs %.5f",
        Double(hardwareLarge.bytes) / 1_048_576, hardwareLarge.build, hardwareLarge.gpu, large.gpu, hardwareLarge.mean, large.mean))
      require(abs(hardwareLarge.mean - large.mean) <= 2e-3 * large.mean, "hardware traversal renders the instanced scene alike")
    }
    let five = try instancedGraph(surface, grid(5))
    let flatFive = try timed(five, .flat, eye: SIMD3(-4, 3, -6)), twoFive = try timed(five, .twoLevel, eye: SIMD3(-4, 3, -6))
    print(String(format: "5 instances (%d rendered): flat build %.0f ms, %.2f ms/frame, %.1f MiB; two-level build %.0f ms, %.2f ms/frame, %.1f MiB; mean radiance %.5f vs %.5f",
      5 * surface.count, flatFive.build, flatFive.gpu, Double(flatFive.bytes) / 1_048_576, twoFive.build, twoFive.gpu,
      Double(twoFive.bytes) / 1_048_576, flatFive.mean, twoFive.mean))
    require(abs(flatFive.mean - twoFive.mean) <= 2e-3 * flatFive.mean && twoFive.bytes * 3 < flatFive.bytes,
      "the instanced scene renders alike on both paths, the two-level one in a fraction of the memory")
    testRenderer.materials.acceleration = saved
    try testRenderer.materials.setMesh([])
    testRenderer.materials.hasSceneGraph = false
  }
  print("PASS: fix-accel large instanced scene beyond the former 500,000-triangle cap")

  // 9. Hierarchy depth stays within the shader stacks for adversarial (exponentially spaced) input.
  do {
    let n = 6000
    var bounds = [Float](repeating: 0, count: 6 * n)
    for k in 0..<n {
      let x = powf(1.004, Float(k))
      bounds[6 * k] = x; bounds[6 * k + 3] = x * 1.0001; bounds[6 * k + 4] = 1; bounds[6 * k + 5] = 1
    }
    let result = bounds.withUnsafeBufferPointer { WideBVH.build(bounds: $0, count: n, leafSize: 2) }
    var covered = [Bool](repeating: false, count: n)
    for node in result.nodes { for k in 0..<4 where node.child[k] < 0 { for q in 0..<Int(node.count[k]) { covered[Int(-node.child[k] - 1) + q] = true } } }
    print("Adversarial hierarchy: depth \(result.depth) for \(n) exponentially spaced items")
    require(result.depth <= WideBVH.maximumDepth && covered.allSatisfy { $0 } && Set(result.order).count == n,
      "binned SAH falls back to balanced splits before the traversal stack depth")
  }
  print("PASS: fix-accel hierarchy depth bound")

  // 10. The hardware gate (METALRT): Metal's triangle intersector on the same shared-edge fixture
  // as the WOOP2013 check in Fix_renderer-followups. Apple documents no watertightness guarantee;
  // leaks here keep the exact software traversal the default (REFERENCES.md, tests/PERFORMANCE.md).
  do {
    guard gpu.supportsRaytracing else {
      print("Metal hardware intersector: not supported on \(gpu.name); the software traversal is the only path")
      print("PASS: fix-accel hardware intersector gate (not applicable)")
      return
    }
    let cells = 16
    let (grid, surface) = patch(cells)
    var targets: [SIMD4<Float>] = []
    for i in 1..<cells { for j in 1..<cells { targets.append(SIMD4(grid[i][j], 0)) } }
    for i in 0..<cells { for j in 0..<cells {
      let a = grid[i][j], b = grid[i + 1][j], c = grid[i + 1][j + 1], d = grid[i][j + 1]
      for f in [Float(0.25), 0.5, 0.75] {
        if j > 0 { targets.append(SIMD4(a + (b - a) * f, 0)) }
        if i > 0 { targets.append(SIMD4(a + (d - a) * f, 0)) }
        targets.append(SIMD4((i + j) % 2 == 0 ? a + (c - a) * f : b + (d - b) * f, 0))
      }
    } }
    let source = """
    #include <metal_stdlib>
    #include <metal_raytracing>
    using namespace metal;
    using namespace raytracing;
    kernel void hardware_edges(instance_acceleration_structure scene [[buffer(0)]], device atomic_uint *out [[buffer(1)]],
        device const float4 *targets [[buffer(2)]], constant uint &count [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
        if(gid.x>=count) return;
        float3 eyes[6]={float3(0.3f,3,0.2f),float3(4,3.5f,-3),float3(-7,6,5),float3(0.05f,20,0.01f),float3(2.5f,1.8f,1.7f),float3(-0.4f,9,-12)};
        float3 eye=eyes[gid.y], target=targets[gid.x].xyz;
        ray r(eye,normalize(target-eye),0.0f,length(target-eye)*1.001f+1e-3f);
        intersector<triangle_data, instancing> closest; closest.assume_geometry_type(geometry_type::triangle);
        intersector<instancing> any; any.assume_geometry_type(geometry_type::triangle); any.accept_any_intersection(true);
        atomic_fetch_add_explicit(&out[0],1,memory_order_relaxed);
        if(closest.intersect(r,scene).type!=intersection_type::triangle) atomic_fetch_add_explicit(&out[1],1,memory_order_relaxed);
        if(any.intersect(r,scene).type!=intersection_type::triangle) atomic_fetch_add_explicit(&out[2],1,memory_order_relaxed);
    }
    """
    let hardware = try gpu.makeLibrary(source: source, options: nil)
    let pipeline = try gpu.makeComputePipelineState(function: hardware.makeFunction(name: "hardware_edges")!)
    // Vertices straight from the MeshTriangle records (stride 16, three indices per triangle).
    guard let vertices = surface.withUnsafeBytes({ gpu.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
      let indices = (0..<surface.count).flatMap({ [UInt32(8 * $0), UInt32(8 * $0 + 1), UInt32(8 * $0 + 2)] })
        .withUnsafeBytes({ gpu.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
    else { throw MaterialLibrary.error("Could not allocate the hardware fixture.") }
    let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
    geometry.vertexBuffer = vertices; geometry.vertexStride = 16; geometry.vertexFormat = .float3
    geometry.indexBuffer = indices; geometry.indexType = .uint32; geometry.triangleCount = surface.count; geometry.opaque = true
    let primitive = MTLPrimitiveAccelerationStructureDescriptor()
    primitive.geometryDescriptors = [geometry]
    func build(_ descriptor: MTLAccelerationStructureDescriptor) throws -> MTLAccelerationStructure {
      let sizes = gpu.accelerationStructureSizes(descriptor: descriptor)
      guard let structure = gpu.makeAccelerationStructure(size: sizes.accelerationStructureSize),
        let scratch = gpu.makeBuffer(length: max(16, sizes.buildScratchBufferSize), options: .storageModePrivate),
        let command = testRenderer.commandQueue.makeCommandBuffer(), let encoder = command.makeAccelerationStructureCommandEncoder()
      else { throw MaterialLibrary.error("Could not build a hardware acceleration structure.") }
      encoder.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
      encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
      return structure
    }
    let blas = try build(primitive)
    var instance = MTLAccelerationStructureInstanceDescriptor()
    instance.transformationMatrix = MTLPackedFloat4x3(columns: (MTLPackedFloat3Make(1, 0, 0), MTLPackedFloat3Make(0, 1, 0),
      MTLPackedFloat3Make(0, 0, 1), MTLPackedFloat3Make(0, 0, 0)))
    instance.options = .opaque; instance.mask = 0xff; instance.accelerationStructureIndex = 0
    let top = MTLInstanceAccelerationStructureDescriptor()
    top.instancedAccelerationStructures = [blas]; top.instanceCount = 1
    top.instanceDescriptorBuffer = gpu.makeBuffer(bytes: &instance, length: MemoryLayout.size(ofValue: instance), options: .storageModeShared)
    let tlas = try build(top)
    var count = UInt32(targets.count)
    guard let out = gpu.makeBuffer(length: 16, options: .storageModeShared),
      let targetBuffer = targets.withUnsafeBytes({ gpu.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
      let command = testRenderer.commandQueue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
    else { throw MaterialLibrary.error("Could not encode the hardware probe.") }
    memset(out.contents(), 0, 16)
    encoder.setComputePipelineState(pipeline)
    encoder.setAccelerationStructure(tlas, bufferIndex: 0)
    encoder.useResource(blas, usage: .read)
    encoder.setBuffer(out, offset: 0, index: 1); encoder.setBuffer(targetBuffer, offset: 0, index: 2)
    encoder.setBytes(&count, length: 4, index: 3)
    encoder.dispatchThreads(MTLSize(width: targets.count, height: 6, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    let counts = (0..<3).map { out.contents().load(fromByteOffset: 4 * $0, as: UInt32.self) }
    require(command.status == .completed && counts[0] == UInt32(targets.count * 6), "hardware intersector probe ran")
    print("Metal hardware intersector on \(gpu.name), unwelded MeshTriangle vertices: \(counts[0]) rays at shared edges/vertices, \(counts[1]) closest-hit and \(counts[2]) any-hit leaks")
    // The same rays through packed (tightly strided) vertices, the layout the gate rejects.
    let packed = surface.flatMap { [$0.a.x, $0.a.y, $0.a.z, $0.b.x, $0.b.y, $0.b.z, $0.c.x, $0.c.y, $0.c.z] }
    let packedGeometry = MTLAccelerationStructureTriangleGeometryDescriptor()
    packedGeometry.vertexBuffer = packed.withUnsafeBytes { gpu.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    packedGeometry.vertexStride = 12; packedGeometry.vertexFormat = .float3; packedGeometry.triangleCount = surface.count; packedGeometry.opaque = true
    let packedPrimitive = MTLPrimitiveAccelerationStructureDescriptor()
    packedPrimitive.geometryDescriptors = [packedGeometry]
    let packedBLAS = try build(packedPrimitive)
    top.instancedAccelerationStructures = [packedBLAS]
    let packedTLAS = try build(top)
    guard let packedCommand = testRenderer.commandQueue.makeCommandBuffer(), let packedEncoder = packedCommand.makeComputeCommandEncoder()
    else { throw MaterialLibrary.error("Could not encode the hardware probe.") }
    memset(out.contents(), 0, 16)
    packedEncoder.setComputePipelineState(pipeline)
    packedEncoder.setAccelerationStructure(packedTLAS, bufferIndex: 0)
    packedEncoder.useResource(packedBLAS, usage: .read)
    packedEncoder.setBuffer(out, offset: 0, index: 1); packedEncoder.setBuffer(targetBuffer, offset: 0, index: 2)
    packedEncoder.setBytes(&count, length: 4, index: 3)
    packedEncoder.dispatchThreads(MTLSize(width: targets.count, height: 6, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    packedEncoder.endEncoding(); packedCommand.commit(); packedCommand.waitUntilCompleted()
    let packedLeaks = (1..<3).map { out.contents().load(fromByteOffset: 4 * $0, as: UInt32.self) }
    print("Metal hardware intersector, packed vertices: \(packedLeaks[0]) closest-hit and \(packedLeaks[1]) any-hit leaks")
    let probe = MaterialLibrary.hardwareLeaks(device: gpu)
    print("Runtime gate (MaterialLibrary.hardwareLeaks): \(probe.map(String.init) ?? "unavailable") leaks; default traversal \(MaterialLibrary.defaultAcceleration)")
    // The run-time gate and this check agree, and the default follows the gate.
    let forcedMode = ProcessInfo.processInfo.environment["VIBE_ACCELERATION"] != nil
    require((probe == 0) == (counts[1] + counts[2] == 0) && MaterialLibrary.hardwareWatertight == (probe == 0)
      && (forcedMode || MaterialLibrary.defaultAcceleration == (probe == 0 ? .hardware : .twoLevel)),
      "hardware traversal is the default exactly when the unwelded layout is watertight on this device")
  }
  print("PASS: fix-accel hardware intersector gate")
}
try fixAccelChecks()
