// Geometry regressions: imported-scene ray tolerances and P1-02 microgeometry
// (R-03, R-51, R-119), bounded visibility traversal (R-97), MetalFX guide
// offsets (R-57), procedural UV orientation (R-50) and OBJ parsing (R-33, R-130).
@MainActor func fixGeometryChecks() throws {
  // OBJ: relative degeneracy test, skipped-face count, line numbers, "vt u", continuations.
  var patch = ""
  let cells = 40
  for j in 0...cells { for i in 0...cells { patch += "v \(1 + Float(i) * 0.0001) 0.25 \(Float(j) * 0.0001)\n" } }
  for j in 0..<cells {
    for i in 0..<cells {
      let a = j * (cells + 1) + i + 1
      patch += "f \(a) \(a + 1) \(a + cells + 2) \(a + cells + 1)\n"
    }
  }
  var skipped = 0
  let patchTriangles = try OBJMesh.parts(patch, skipped: &skipped).flatMap(\.triangles)
  require(patchTriangles.count == 2 * cells * cells && skipped == 0, "OBJ keeps 0.1 mm faces in meter units")
  let tinyOBJ = try OBJMesh.load("v 0.25 0.1 0.4\nv 0.25002 0.1 0.4\nv 0.25 0.10002 0.4\nf 1 2 3\n")
  require(tinyOBJ.count == 1, "OBJ keeps a 20 um triangle")
  let mixed = try OBJMesh.parts("v 0 0 0\nv 1 0 0\nv 2 0 0\nv 0 1 0\nf 1 2 3\nf 1 2 4\nf 1 1 4\n", skipped: &skipped)
  require(mixed.flatMap(\.triangles).count == 1 && skipped == 2, "OBJ counts collinear and coincident faces")
  do {
    _ = try OBJMesh.load("v 0 0 0\nv 1 0 0\nv 2 0 0\nf 1 2 3\n")
    require(false, "OBJ without usable faces must fail")
  } catch { require(error.localizedDescription.contains("1 degenerate"), "empty OBJ reports skipped faces") }
  func objFailure(_ text: String) -> String {
    do { _ = try OBJMesh.load(text); return "" } catch { return error.localizedDescription }
  }
  require(objFailure("v 0 0 0\nv 1 0 0\n\n# note\nf 1 2 9\n").contains("line 5"), "OBJ index error names its line")
  require(objFailure("v 0 0 0\r\nv 1 0 0\r\nv 0 1 0\r\nf 1 2 3\r\nvn 0 1\r\n").contains("line 5"), "CRLF OBJ error names its line")
  require(objFailure("v 0 0 0\nv 1 \\\n 0 0\nv 0 1 0\nf 1 2 3\nf 1 2 x\n").contains("line 6"),
    "OBJ error after a continuation names its physical line")
  let continued = try OBJMesh.load("v 0 0 0\nv 1 \\\n  0 0\nv 0 1 0\nf 1 \\\n 2 3 \\")
  require(continued.count == 1 && continued[0].b.x == 1, "OBJ joins backslash continuations, including at end of file")
  let commented = try OBJMesh.load("v 0 0 0\nv 1 0 0\nv 0 1 0 # comment \\\nf 1 2 3\n")
  require(commented.count == 1, "backslash inside an OBJ comment does not continue the line")
  let singleUV = try OBJMesh.load("v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0.25\nvt 0.75\nvt 0.5 0.5\nf 1/1 2/2 3/3\n")
  require(singleUV.count == 1 && singleUV[0].uvab == SIMD4(0.25, 1, 0.75, 1) && singleUV[0].uvc.x == 0.5,
    "OBJ accepts single-component vt")
  print("PASS: OBJ relative degeneracy test, skipped-face count, line numbers, vt u and continuations")

  func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, id: Int = 1) -> MeshTriangle {
    let n = simd_normalize(simd_cross(b - a, c - a))
    return MeshTriangle(
      a: SIMD4(a, 1), b: SIMD4(b, 1), c: SIMD4(c, 1), na: SIMD4(n, 0), nb: SIMD4(n, 0), nc: SIMD4(n, 0),
      uvab: .zero, uvc: SIMD4(0, 0, 8, Float(id)))
  }
  func quad(_ corner: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>, id: Int = 1) -> [MeshTriangle] {
    [triangle(corner, corner + u, corner + u + v, id: id), triangle(corner, corner + u + v, corner + v, id: id)]
  }
  // Deterministic scattered triangles for traversal-order and any-hit checks.
  var state: UInt32 = 12345
  func random() -> Float {
    state = state &* 1_664_525 &+ 1_013_904_223
    return Float(state >> 8) / Float(1 << 24)
  }
  var scattered: [MeshTriangle] = []
  for i in 0..<3000 {
    let center = SIMD3<Float>(random(), random(), random()) * 2.4 - 1.2
    func edge() -> SIMD3<Float> { (SIMD3<Float>(random(), random(), random()) - 0.5) * 0.16 }
    let b = center + edge(), c = center + edge()
    if simd_length(simd_cross(b - center, c - center)) > 1e-4 { scattered.append(triangle(center, b, c, id: i + 1)) }
  }
  let (_, scatteredNodes) = OBJMesh.build(scattered)
  let interior = scatteredNodes.filter { $0.links.w == 0 }
  require(interior.allSatisfy { (0...2).contains($0.links.z) } && interior.contains { $0.links.z != 0 },
    "BVH interior nodes record their split axis")

  let kernels = """
  kernel void fix_geometry_self_hits(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device atomic_uint *out [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
      float3 eye=float3(3.7f,4.1f,-5.3f);
      // Half-step z offset keeps targets off the quad diagonal x=z (a shared edge).
      float3 target=float3((float(gid.x)/63.0f-0.5f)*0.6f,0.0f,((float(gid.y)+0.5f)/63.0f-0.5f)*0.6f);
      Ray r={eye,normalize(target-eye)}; HitRecord h;
      if(!trace_scene(r,6,h,images,u) || h.objectID<64) return;
      atomic_fetch_add_explicit(&out[0],1,memory_order_relaxed);
      uint seed=gid.y*64+gid.x+1;
      for(int k=0;k<16;++k) {
          float3 d=sample_cosine_hemisphere(k<8 ? h.geometricNormal : -h.geometricNormal,seed);
          Ray next={ray_origin(h.position,h.geometricNormal,d,u,h.error),d}; HitRecord s;
          if(trace_scene(next,6,s,images,u) && s.objectID>=64 && s.t<1e-3f) atomic_fetch_add_explicit(&out[1],1,memory_order_relaxed);
          if(k>=8) continue;
          LightSample ls={}; ls.position=h.position+2.0f*d; ls.wi=d; ls.pdf=1; ls.isDirectional=0;
          if(!light_visible(h.position,h.geometricNormal,ls,6,images,u,h.error)) atomic_fetch_add_explicit(&out[2],1,memory_order_relaxed);
      }
  }
  kernel void fix_geometry_emitter(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device atomic_uint *out [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
      MeshTriangle e=images.triangles[0];
      uint seed=gid.y*64+gid.x+7;
      float2 q=rand_f2(seed); if(q.x+q.y>1) q=1-q;
      float3 x=(1-q.x-q.y)*e.a.xyz+q.x*e.b.xyz+q.y*e.c.xyz;
      float3 ng=normalize(cross(e.b.xyz-e.a.xyz,e.c.xyz-e.a.xyz));
      float3 dir=sample_cosine_hemisphere(ng,seed);
      float3 p=x+dir*(2.0f+6.0f*rand_f(seed));
      if(p.y<-0.9f) return;
      LightSample ls={}; ls.position=x; ls.wi=normalize(x-p); ls.pdf=1; ls.isDirectional=2; ls.dist=length(x-p);
      atomic_fetch_add_explicit(&out[0],1,memory_order_relaxed);
      if(!light_visible(p,-dir,ls,6,images,u)) atomic_fetch_add_explicit(&out[1],1,memory_order_relaxed);
      if(!gi_connection_visible(p,-dir,x,u,images)) atomic_fetch_add_explicit(&out[2],1,memory_order_relaxed);
  }
  kernel void fix_geometry_micro(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device float4 *out [[buffer(3)]]) {
      HitRecord h, s;
      float3 p0=float3(0.25f,0.1f,0.4f);
      Ray nearRay={p0+float3(5e-6f,5e-6f,-5e-4f),float3(0,0,1)};
      bool a=trace_scene(nearRay,6,h,images,u);
      out[0]=float4(a?h.t:-1,a?float(h.objectID):-1,0,0);
      // Continuations leaving the 20 um triangle on either side must not re-hit it.
      uint selfHits=0;
      for(int k=0;k<2 && a;++k) {
          float3 d=k==0 ? float3(0,0,-1) : normalize(float3(0.2f,0.1f,1));
          Ray next={ray_origin(h.position,h.geometricNormal,d,u,h.error),d};
          if(trace_scene(next,6,s,images,u) && s.objectID==h.objectID && s.t<1e-3f) ++selfHits;
      }
      out[0].z=float(selfHits);
      float3 towards=normalize(float3(0.3f,0.4f,-1));
      Ray farRay={p0+float3(5e-6f,5e-6f,0)+towards*5.0f,-towards};
      bool b=trace_scene(farRay,6,h,images,u);
      out[1]=float4(b?h.t:-1,b?float(h.objectID):-1,0,0);
      // Receiver at y=0.1 under a 1 mm occluder 0.3 mm above it, seen from below.
      Ray up={float3(1.5f,-0.5f,1.5f),float3(0,1,0)};
      bool c=trace_scene(up,6,h,images,u);
      LightSample ls={}; ls.pdf=1; ls.isDirectional=0;
      ls.position=float3(1.5f,2.1f,1.5f); ls.wi=normalize(ls.position-h.position);
      bool shadowed=c && !light_visible(h.position,h.geometricNormal,ls,6,images,u,h.error);
      ls.position=float3(6.5f,2.1f,1.5f); ls.wi=normalize(ls.position-h.position);
      bool lit=c && light_visible(h.position,h.geometricNormal,ls,6,images,u,h.error);
      out[2]=float4(c?h.t:-1,shadowed?1:0,lit?1:0,0);
      // The procedural floor 0.5 mm below the underside of an imported mesh.
      Ray down={float3(0.7f,-1.0f+5e-4f,-0.6f),float3(0,-1,0)};
      bool d=trace_scene(down,6,h,images,u);
      out[3]=float4(d?h.t:-1,d?float(h.objectID):-1,0,0);
      // A floor point under a mesh plate 0.5 mm above the floor is shadowed.
      Ray floorUp={float3(-1.5f,-1.5f,-1.5f),float3(0,1,0)};
      bool e=trace_scene(floorUp,6,h,images,u);
      ls.position=float3(-1.5f,2.0f,-1.5f); ls.wi=normalize(ls.position-h.position);
      out[4]=float4(e?float(h.objectID):-1,e && !light_visible(h.position,h.geometricNormal,ls,6,images,u,h.error)?1:0,0,0);
  }
  kernel void fix_geometry_anyhit(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(2)]],
      device atomic_uint *out [[buffer(3)]], constant uint &count [[buffer(4)]], uint gid [[thread_position_in_grid]]) {
      uint seed=gid*9781u+13u;
      float3 o=float3(rand_f(seed),rand_f(seed),rand_f(seed))*2.4f-1.2f;
      float3 d=normalize(float3(rand_f(seed),rand_f(seed),rand_f(seed))-0.5f+float3(1e-4f));
      Ray r={o,d}; HitRecord h;
      bool hit=trace_scene(r,6,h,images,u);
      float tMin=ray_t_min(o,u), best=1e20f; uint bestID=0xffffffffu;
      HitRecord p;
      if(trace_scene(r,6,p,images.objects,u.light.w,u.light.xyz,tMin)) { best=p.t; bestID=p.mat.slot; }
      for(uint i=0;i<count;++i) {
          float t,b1,b2;
          if(intersect_mesh_triangle(images.triangles[i],r,tMin,best,t,b1,b2)) { best=t; bestID=64+uint(images.triangles[i].uvc.w)-1; }
      }
      if(hit) atomic_fetch_add_explicit(&out[0],1,memory_order_relaxed);
      bool same=hit==(best<1e19f) && (!hit || (h.objectID==bestID && abs(h.t-best)<=1e-6f*max(1.0f,best)));
      if(!same) atomic_fetch_add_explicit(&out[1],1,memory_order_relaxed);
      float tMax=0.05f+3.0f*rand_f(seed);
      bool expected=hit && h.t<tMax;
      if(scene_occluded(r,6,tMax,images,u)!=expected && (!hit || abs(h.t-tMax)>1e-4f)) atomic_fetch_add_explicit(&out[2],1,memory_order_relaxed);
  }
  float4 fix_uv_pair(Ray a, Ray b, bool box, uint scene) {
      HitRecord ha, hb; Material m={DIFFUSE,float3(0.5f),float3(0),0,1};
      bool ok=box==1 ? intersect_box(a,float3(0),float3(1),0,m,0.001f,100,ha) && intersect_box(b,float3(0),float3(1),0,m,0.001f,100,hb)
          : scene==99 ? intersect_cylinder_ring(a,float3(0),1,2,m,0.001f,100,ha) && intersect_cylinder_ring(b,float3(0),1,2,m,0.001f,100,hb)
          : trace_scene(a,scene,ha) && trace_scene(b,scene,hb);
      if(!ok) return float4(-99);
      float3 dp=hb.position-ha.position;
      return float4(hb.uv-ha.uv,dot(ha.tangent,dp),dot(ha.bitangent,dp));
  }
  Ray fix_toward(float3 eye, float3 target) { Ray r={eye,normalize(target-eye)}; return r; }
  // Each probe returns (upward pair, rightward pair) as seen by the viewer.
  kernel void fix_geometry_uv(device float4 *out [[buffer(3)]]) {
      float3 eyes[11]={float3(0,1,0),float3(0,1,0.4f),float3(0,0.7f,-0.9f),float3(0,0.7f,0),float3(0,0.7f,0),float3(0,1,-1),
          float3(-0.8f,0.5f,-3),float3(0,0,-5),float3(5,0,0),float3(-5,0,0),float3(0,0,5)};
      float3 at[11]={float3(0.5f,1,2.8f),float3(-3.8f,1,0.4f),float3(0.3f,0.7f,1),float3(-1,0.7f,0.3f),float3(1,0.7f,0.1f),float3(0.3f,1,2),
          float3(-0.8f,-0.455f,0.078f),float3(0.2f,0,-1),float3(1,0,0.2f),float3(-1,0,0.2f),float3(0.2f,0,1)};
      float3 ups[11]={float3(0,0.4f,0),float3(0,0.4f,0),float3(0,0.15f,0),float3(0,0.15f,0),float3(0,0.15f,0),float3(0,0.4f,0),
          float3(0,0.7905f,1.1555f)*0.15f,float3(0,0.3f,0),float3(0,0.3f,0),float3(0,0.3f,0),float3(0,0.3f,0)};
      float3 rights[11]={float3(-0.4f,0,0),float3(0,0,-0.4f),float3(-0.2f,0,0),float3(0,0,-0.2f),float3(0,0,0.2f),float3(-0.2f,0,0),
          float3(-0.2f,0,0),float3(-0.3f,0,0),float3(0,0,-0.3f),float3(0,0,0.3f),float3(0.3f,0,0)};
      uint scenes[11]={0,0,1,1,1,5,2,0,0,0,0};
      for(int i=0;i<11;++i) {
          bool box=i>=7;
          out[2*i]=fix_uv_pair(fix_toward(eyes[i],at[i]),fix_toward(eyes[i],at[i]+ups[i]),box,scenes[i]);
          out[2*i+1]=fix_uv_pair(fix_toward(eyes[i],at[i]),fix_toward(eyes[i],at[i]+rights[i]),box,scenes[i]);
      }
      // Ring outside, upward pair; box bottom, +x pair (mirrors the top face).
      out[22]=fix_uv_pair(fix_toward(float3(0,0,-5),float3(0.2f,0,-0.98f)),fix_toward(float3(0,0,-5),float3(0.2f,0.3f,-0.98f)),false,99);
      out[23]=fix_uv_pair(fix_toward(float3(0,-5,0),float3(0.2f,-1,0.2f)),fix_toward(float3(0,-5,0),float3(0.5f,-1,0.2f)),true,0);
      out[24]=fix_uv_pair(fix_toward(float3(0,5,0),float3(0.2f,1,0.2f)),fix_toward(float3(0,5,0),float3(0.5f,1,0.2f)),true,0);
  }
  """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  func dispatch(_ name: String, _ input: Uniforms, grid: MTLSize, bytes: Int, count: UInt32 = 0,
                textures: [MTLTexture] = []) throws -> MTLBuffer {
    var u = input, n = count
    guard let function = library.makeFunction(name: name),
      let out = gpu.makeBuffer(length: bytes, options: .storageModeShared),
      let command = testRenderer.commandQueue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw MaterialLibrary.error("Could not encode \(name).") }
    memset(out.contents(), 0, bytes)
    encoder.setComputePipelineState(try gpu.makeComputePipelineState(function: function))
    require(testRenderer.materials.bind(encoder), "\(name) binds scene resources")
    for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
    encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setBuffer(out, offset: 0, index: 3)
    encoder.setBytes(&n, length: 4, index: 4)
    encoder.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: min(grid.width, 8), height: min(grid.height, 8), depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) GPU command")
    return out
  }
  func counters(_ buffer: MTLBuffer, _ count: Int) -> [UInt32] {
    (0..<count).map { buffer.contents().load(fromByteOffset: $0 * 4, as: UInt32.self) }
  }
  func vectors(_ buffer: MTLBuffer, _ count: Int) -> [SIMD4<Float>] {
    (0..<count).map { buffer.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  }
  func graphScene(_ triangles: [MeshTriangle]) throws -> Uniforms {
    try testRenderer.materials.setMesh(triangles)
    var u = makeUniforms(scene: 6, mode: 1, width: 1, height: 1)
    u.environment = SIMD4(0, 0, 0, Float(testRenderer.materials.nodeCount))
    u.lens.z = 1
    u.sunParams.w = 0
    return u
  }
  try testRenderer.materials.restore(SceneState())
  let grid = MTLSize(width: 64, height: 64, depth: 1)

  // R-03: hits near the world origin seen from about 7.6 m re-hit nothing, on
  // an exactly horizontal plane and on a tilted planar quad.
  for (label, corner, u, v) in [
    ("horizontal", SIMD3<Float>(-8, 0, -8), SIMD3<Float>(16, 0, 0), SIMD3<Float>(0, 0, 16)),
    ("tilted", SIMD3<Float>(-8, -0.25, -8), SIMD3<Float>(16, 0.375, 0), SIMD3<Float>(0, 0.25, 16)),
  ] {
    let counts = counters(try dispatch("fix_geometry_self_hits", try graphScene(quad(corner, u, v)), grid: grid, bytes: 16), 3)
    print("Self-hit check (\(label)): \(counts[0]) hits, \(counts[1]) self-hits, \(counts[2]) blocked shadow rays")
    require(counts[0] == 4096 && counts[1] == 0 && counts[2] == 0, "no self-hits near the origin (\(label) plane)")
  }
  // R-03: a 1 cm emitter near the origin lights receivers 2-8 m away.
  let emitter = [triangle(SIMD3(-0.004, -0.003, 0.001), SIMD3(0.006, -0.002, -0.0013), SIMD3(0.001, 0.005, 0.0004))]
  let emitterCounts = counters(try dispatch("fix_geometry_emitter", try graphScene(emitter), grid: grid, bytes: 16), 3)
  print("Emitter visibility: \(emitterCounts[0]) receivers, \(emitterCounts[1]) shadowed, \(emitterCounts[2]) GI blocked")
  require(emitterCounts[0] > 2000 && emitterCounts[1] == 0 && emitterCounts[2] == 0,
    "an emitter near the origin does not occlude itself")

  // R-119/P1-02 and R-51: 20 um triangle, sub-millimetre occluders, floor under a mesh.
  let p0 = SIMD3<Float>(0.25, 0.1, 0.4)
  var micro = [triangle(p0, p0 + SIMD3(2e-5, 0, 0), p0 + SIMD3(0, 2e-5, 0), id: 1)]
  micro += quad(SIMD3(1, 0.1, 1), SIMD3(1, 0, 0), SIMD3(0, 0, 1), id: 2)
  micro += quad(SIMD3(1.4995, 0.1003, 1.4995), SIMD3(0.001, 0, 0), SIMD3(0, 0, 0.001), id: 3)
  micro += quad(SIMD3(-1.505, -0.9995, -1.505), SIMD3(0.01, 0, 0), SIMD3(0, 0, 0.01), id: 4)
  let m = vectors(try dispatch("fix_geometry_micro", try graphScene(micro), grid: MTLSize(width: 1, height: 1, depth: 1), bytes: 80), 5)
  print("Microgeometry: \(m)")
  require(abs(m[0].x - 5e-4) < 1e-6 && m[0].y == 64 && m[0].z == 0, "20 um triangle 0.5 mm away is hit without self-hits")
  require(abs(m[1].x - 5) < 1e-4 && m[1].y == 64, "20 um triangle is hit from 5 m")
  require(abs(m[2].x - 0.6) < 1e-5 && m[2].y == 1 && m[2].z == 1, "0.3 mm occluder casts a shadow; light beside it reaches the receiver")
  require(abs(m[3].x - 5e-4) < 1e-6 && m[3].y == 1, "graph-mode floor is hit 0.5 mm below a mesh underside")
  require(m[4].x == 1 && m[4].y == 1, "mesh plate 0.5 mm above the floor shadows it")

  // R-97: BVH closest hits match brute force; the bounded any-hit test matches them.
  let anyHitUniforms = try graphScene(scattered)
  let anyHit = counters(try dispatch("fix_geometry_anyhit", anyHitUniforms, grid: MTLSize(width: 16384, height: 1, depth: 1),
    bytes: 16, count: UInt32(scattered.count)), 3)
  print("Traversal check: \(anyHit[0]) hits, \(anyHit[1]) closest-hit mismatches, \(anyHit[2]) any-hit mismatches")
  require(anyHit[0] > 4000 && anyHit[1] == 0 && anyHit[2] == 0, "near-first closest hit and bounded any-hit traversal")

  // R-57: specular MetalFX guides offset along the traced geometric normal. A
  // G-buffer point 0.2 um under the plane (ray rounding) with a tilted shading
  // normal must give the same reflection guide as a point exactly on it.
  var guideUniforms = try graphScene(quad(SIMD3(-8, 0, -8), SIMD3(16, 0, 0), SIMD3(0, 0, 16)))
  guideUniforms.environment.x = 1
  let shading = simd_normalize(SIMD3<Float>(0.98, 0.2, 0)), toCamera = simd_normalize(SIMD3<Float>(0.9, 0.3, 0))
  func guide(_ y: Float) throws -> [SIMD4<Float>] {
    func texture(_ value: SIMD4<Float>) -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
      let t = gpu.makeTexture(descriptor: d)!
      var v = value
      t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &v, bytesPerRow: 16)
      return t
    }
    let p = SIMD3<Float>(0.3, y, 0.2)
    var u = guideUniforms
    u.cameraPos = SIMD4(p + toCamera * 3, 45)
    u.cameraTarget = SIMD4(p, 16)
    let inputs = [texture(SIMD4(0, 0, 0, 1)), texture(SIMD4(p, 3)), texture(SIMD4(shading, 1)), texture(SIMD4(0.9, 0.9, 0.9, 0))]
    let outputs = (0..<9).map { _ in texture(.zero) }
    // buffer(3) is the kernel's primary-surface cache (integrator): one 104-byte
    // PrimarySurface per pixel, read only for OpenPBR hits (this G-buffer is glossy).
    _ = try dispatch("metalfx_guides_kernel", u, grid: MTLSize(width: 1, height: 1, depth: 1),
      bytes: Int(PathTracerRenderer.primarySurfaceStride), textures: inputs + outputs)
    return [readTexture(outputs[3])[0], readTexture(outputs[4])[0]]
  }
  let onPlane = try guide(0), belowPlane = try guide(-2e-7)
  print("MetalFX guides: on plane \(onPlane), below plane \(belowPlane)")
  require(zip(onPlane, belowPlane).allSatisfy { simd_length($0 - $1) < 1e-4 } && onPlane[0].x > 0,
    "specular guide rays do not re-hit their own surface")

  // R-50: image row 0 is the top of walls, box sides and the ring; u runs to the viewer's right.
  let uv = vectors(try dispatch("fix_geometry_uv", makeUniforms(scene: 0, mode: 1, width: 1, height: 1),
    grid: MTLSize(width: 1, height: 1, depth: 1), bytes: 25 * 16), 25)
  let probes = ["pavilion back wall", "pavilion side wall", "Cornell back wall", "Cornell red wall", "Cornell green wall",
    "studio back wall", "tilted plate", "box -z side", "box +x side", "box -x side", "box +z side"]
  for (i, name) in probes.enumerated() {
    let up = uv[2 * i], right = uv[2 * i + 1]
    require(up.x != -99 && right.x != -99, "\(name) UV probes hit")
    require(up.y < 0 && up.w < 0 && abs(up.x) < 1e-5, "\(name): v decreases upward and bitangent is dP/dv")
    require(right.x > 0 && right.z > 0 && abs(right.y) < 1e-5, "\(name): u increases to the viewer's right and tangent is dP/du")
  }
  require(uv[22].y < 0 && uv[22].w < 0, "ring v decreases upward")
  require(uv[23].x < 0 && uv[23].z < 0 && uv[24].x > 0 && uv[24].z > 0, "box bottom mirrors the top face")
  print("PASS: imported-scene ray tolerances, P1-02 microgeometry, bounded visibility traversal, MetalFX guide offsets, procedural UVs")
  try testRenderer.materials.setMesh([])
  try testRenderer.materials.restore(SceneState())
}
try fixGeometryChecks()
