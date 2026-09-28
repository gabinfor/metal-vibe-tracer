// Renderer follow-ups: one host copy of imported triangles (R-101), the watertight
// ray/triangle test (WOOP2013) and its conservative BVH traversal, and time limits that
// do not count system sleep.
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

  // WOOP2013: rays aimed exactly at shared edges and vertices of a tessellated, curved
  // patch never pass between its triangles (closest hit and any hit), and the BVH still
  // returns exactly the brute-force closest hit. The patch is a height field whose slope
  // stays below 20 degrees and every eye looks down on it more steeply, so each ray
  // crosses it exactly once (no silhouette tangency): any miss is a crack.
  let kernels = """
  kernel void rf_edge_rays(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device atomic_uint *out [[buffer(3)]], constant uint &count [[buffer(4)]], device const float4 *targets [[buffer(5)]],
      constant uint &targetCount [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
      if(gid.x>=targetCount) return;
      float3 eyes[6]={float3(0.3f,3,0.2f),float3(4,3.5f,-3),float3(-7,6,5),float3(0.05f,20,0.01f),float3(2.5f,1.8f,1.7f),float3(-0.4f,9,-12)};
      float3 eye=eyes[gid.y], target=targets[gid.x].xyz;
      Ray r={eye,normalize(target-eye)}; HitRecord h;
      atomic_fetch_add_explicit(&out[0],1,memory_order_relaxed);
      bool hit=trace_scene(r,6,h,images,u) && h.objectID>=64;
      if(!hit) atomic_fetch_add_explicit(&out[1],1,memory_order_relaxed);
      if(!scene_occluded(r,6,length(target-eye)*1.001f+1e-3f,images,u)) atomic_fetch_add_explicit(&out[2],1,memory_order_relaxed);
      float tMin=ray_t_min(eye,u), best=1e20f; bool mesh=false; HitRecord p;
      if(trace_scene(r,6,p,images.objects,u.light.w,u.light.xyz,tMin)) best=p.t;
      for(uint i=0;i<count;++i) { float t,b1,b2; if(intersect_mesh_triangle(images.triangles[i],r,tMin,best,t,b1,b2)) { best=t; mesh=true; } }
      if(hit!=mesh || (hit && abs(h.t-best)>1e-6f*max(1.0f,best))) atomic_fetch_add_explicit(&out[3],1,memory_order_relaxed);
  }
  // Edge functions are exact negatives for the two orientations of an edge, including
  // near-collinear operands; a tie of the rounded products resolves to the exact sign.
  kernel void rf_edge_function(device atomic_uint *out [[buffer(3)]], device float *tie [[buffer(5)]], uint gid [[thread_position_in_grid]]) {
      if(gid==0) {
          float2 p=float2(1.000244140625f,1.00048828125f), q=float2(1.0f,1.000244140625f);
          tie[0]=watertight_edge(p,q); tie[1]=watertight_edge(q,p);
      }
      uint seed=gid*7919u+3u;
      for(int k=0;k<64;++k) {
          float2 p=float2(rand_f(seed),rand_f(seed))*4.0f-2.0f;
          float s=rand_f(seed)*3.0f-1.5f;
          float2 q=k<32 ? p*s*float2(1.0f+1e-7f*(rand_f(seed)-0.5f),1.0f+1e-7f*(rand_f(seed)-0.5f)) : float2(rand_f(seed),rand_f(seed))*4.0f-2.0f;
          if(watertight_edge(p,q)!=-watertight_edge(q,p)) atomic_fetch_add_explicit(&out[0],1,memory_order_relaxed);
      }
  }
  """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  func dispatch(_ name: String, _ input: Uniforms, grid: MTLSize, count: UInt32 = 0, extra: MTLBuffer? = nil,
                extraCount: UInt32 = 0) throws -> MTLBuffer {
    var u = input, n = count, m = extraCount
    guard let function = library.makeFunction(name: name),
      let out = gpu.makeBuffer(length: 64, options: .storageModeShared),
      let command = testRenderer.commandQueue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw MaterialLibrary.error("Could not encode \(name).") }
    memset(out.contents(), 0, 64)
    encoder.setComputePipelineState(try gpu.makeComputePipelineState(function: function))
    require(testRenderer.materials.bind(encoder), "\(name) binds scene resources")
    encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setBuffer(out, offset: 0, index: 3)
    encoder.setBytes(&n, length: 4, index: 4)
    encoder.setBuffer(extra, offset: 0, index: 5)
    encoder.setBytes(&m, length: 4, index: 6)
    encoder.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: min(grid.width, 64), height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) GPU command")
    return out
  }
  func counters(_ buffer: MTLBuffer, _ count: Int) -> [UInt32] {
    (0..<count).map { buffer.contents().load(fromByteOffset: $0 * 4, as: UInt32.self) }
  }
  let cells = 16
  let (vertices, surface) = patch(cells)
  var targets: [SIMD4<Float>] = []
  for i in 1..<cells { for j in 1..<cells { targets.append(SIMD4(vertices[i][j], 0)) } }
  func edge(_ a: SIMD3<Float>, _ b: SIMD3<Float>) { for f in [Float(0.25), 0.5, 0.75] { targets.append(SIMD4(a + (b - a) * f, 0)) } }
  for i in 0..<cells {
    for j in 0..<cells {
      if j > 0 { edge(vertices[i][j], vertices[i + 1][j]) }
      if i > 0 { edge(vertices[i][j], vertices[i][j + 1]) }
      if (i + j) % 2 == 0 { edge(vertices[i][j], vertices[i + 1][j + 1]) } else { edge(vertices[i + 1][j], vertices[i][j + 1]) }
    }
  }
  try testRenderer.materials.restore(SceneState())
  try testRenderer.materials.setMesh(surface)
  var u = makeUniforms(scene: 6, mode: 1, width: 1, height: 1)
  u.environment = SIMD4(0, 0, 0, Float(testRenderer.materials.nodeCount))
  u.lens.z = 1
  u.sunParams.w = 0
  guard let targetBuffer = targets.withUnsafeBytes({ gpu.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
    let tieBuffer = gpu.makeBuffer(length: 8, options: .storageModeShared)
  else { throw MaterialLibrary.error("Could not allocate edge-ray inputs.") }
  let edges = counters(try dispatch("rf_edge_rays", u, grid: MTLSize(width: targets.count, height: 6, depth: 1),
    count: UInt32(surface.count), extra: targetBuffer, extraCount: UInt32(targets.count)), 4)
  print("Watertight edge rays: \(edges[0]) rays at shared edges/vertices, \(edges[1]) closest-hit misses, "
    + "\(edges[2]) any-hit misses, \(edges[3]) BVH/brute-force mismatches")
  require(edges[0] == UInt32(targets.count * 6) && edges[1] == 0 && edges[2] == 0 && edges[3] == 0,
    "rays at shared edges and vertices never pass between triangles; BVH matches brute force")
  let symmetric = counters(try dispatch("rf_edge_function", u, grid: MTLSize(width: 4096, height: 1, depth: 1), extra: tieBuffer), 1)
  let tie = (0..<2).map { tieBuffer.contents().load(fromByteOffset: $0 * 4, as: Float.self) }
  print("Edge functions: \(symmetric[0]) antisymmetry failures, tie resolved to \(tie)")
  require(symmetric[0] == 0 && tie[0] == 0x1p-24 && tie[1] == -0x1p-24,
    "edge functions are exactly antisymmetric and resolve rounded-product ties exactly")
  try testRenderer.materials.setMesh([])
  try testRenderer.materials.restore(SceneState())
  print("PASS: fix-renderer-followups watertight ray/triangle intersection and conservative traversal (WOOP2013)")

  // The USD import limit, its SIGTERM grace period and the render time limit run on
  // awakeSeconds: CLOCK_UPTIME_RAW, the mach_absolute_time clock that stops while the Mac
  // sleeps (CLOCK_MONOTONIC_RAW keeps counting). Injected clocks stand in for sleep.
  do {
    let uptime = Double(DispatchTime.now().uptimeNanoseconds) / 1e9, awake = awakeSeconds()
    let continuous = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
    print(String(format: "Clocks: awake %.3f s, uptime %.3f s, continuous %.3f s since boot", awake, uptime, continuous))
    require(abs(awake - uptime) < 0.05 && continuous >= awake - 0.05, "time limits use the clock that excludes sleep")
    final class ManualClock: @unchecked Sendable {
      private let lock = NSLock()
      private var value: TimeInterval = 0, step: TimeInterval = 0
      nonisolated func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        value += step
        return value
      }
      nonisolated func advance(by step: TimeInterval) { lock.lock(); self.step = step; lock.unlock() }
    }
    let file = usdFolder.appendingPathComponent("scene.usda")
    let scratch = { Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("vibe-usd-") } }
    let before = scratch()
    // Awake time stands still for the whole import (the Mac slept through it): the import
    // outlasts its limit in wall time and still completes.
    let asleep = ManualClock()
    let started = Date()
    let slept = try USDImporter.load(file, into: ProjectDocument(), job: USDImportJob(limit: 0.01, clock: { asleep.now() }))
    require(slept.document.graph != nil && Date().timeIntervalSince(started) > 0.01,
      "an import whose awake time stays under the limit completes however long the wall time")
    // Awake time passing the limit mid-import stops the helper, escalating to SIGKILL once the
    // grace period has passed on the same clock, and removes the scratch folder.
    let awakeClock = ManualClock()
    let job = USDImportJob(limit: 300, clock: { awakeClock.now() })
    final class Outcome: @unchecked Sendable { var message: String? }
    let outcome = Outcome(), done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      do { _ = try USDImporter.load(file, into: ProjectDocument(), job: job) } catch { outcome.message = error.localizedDescription }
      done.signal()
    }
    let launch = Date()
    while !job.isHelperRunning && Date().timeIntervalSince(launch) < 10 { Thread.sleep(forTimeInterval: 0.005) }
    require(job.isHelperRunning, "USD helper started for the time-limit check")
    awakeClock.advance(by: 1000)
    require(done.wait(timeout: .now() + 20) == .success, "an import past its awake-time limit stops")
    require(outcome.message?.contains("exceeded five minutes") == true && !job.isHelperRunning && !job.isCancelled,
      "the awake-time limit terminates the helper (\(outcome.message ?? "no error"))")
    require(scratch().subtracting(before).isEmpty, "a timed-out import removes its scratch folder")
  }
  print("PASS: fix-renderer-followups USD import limit and render time limit exclude system sleep")
}
try fixRendererFollowupsChecks()
