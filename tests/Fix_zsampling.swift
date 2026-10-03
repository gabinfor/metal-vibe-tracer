// Z++ sampler (REFERENCES.md ZPP2026, ZSAMPLING2020, PBRT2023): mode plumbing and the test seam;
// the constituent sequences (O2m3 (0, 2m, 3)-nets with (0, 2m, 2) pairwise projections at every
// power of four, 2D Sobol' (0, m, 2)-nets), kept by Owen scrambling; the recursive quadrant
// shuffle (aligned blocks onto aligned blocks); per-frame Z masks over aligned pixel blocks and
// per-pixel nets over the frames of an accumulation in every temporal model; exact equivalence
// of the PCG-mode Sampler to the previous uint streams; distinct streams for the two passes and
// exact replay of ReSTIR PT paths from their keys (identity and round-trip shifts); mean
// radiance against MIS; the screen-space (blue-noise-like) error distribution of single frames;
// and the equal-sample error gains of static accumulation.
@MainActor func fixZSamplingChecks() throws {
  let renderer = testRenderer
  let saved = (renderer.sampler, renderer.zTemporal, renderer.indirectReuse, renderer.spatialNeighbors,
               renderer.temporalReuse, renderer.controlVariates)
  let savedSettings = renderer.materials.settings
  defer {
    (renderer.sampler, renderer.zTemporal, renderer.indirectReuse, renderer.spatialNeighbors,
     renderer.temporalReuse, renderer.controlVariates) = saved
    renderer.materials.settings = savedSettings
  }

  // Modes and the test seam.
  let environmentDefault: SamplerMode = ["pcg": .pcg, "z": .zSampling][
    ProcessInfo.processInfo.environment["VIBE_SAMPLER"] ?? ""] ?? .automatic
  require(PathTracerRenderer.defaultSampler == environmentDefault, "the default sampler follows the VIBE_SAMPLER test seam")
  require(SamplerMode.pcg.resolved() == .pcg && SamplerMode.zSampling.resolved() == .zSampling
    && SamplerMode.automatic.resolved() != .automatic, "explicit samplers resolve to themselves, Automatic to one of them")
  renderer.sampler = .zSampling; renderer.zTemporal = .interlaced
  _ = render(makeUniforms(scene: 1, mode: 1, width: 16, height: 16), samples: 1)
  require(lastRenderUniforms!.indirectReuse & 0x1C0 == 64 | (1 << 7), "the Z sampler and its temporal model reach the shaders (bits 6-8)")
  renderer.sampler = .pcg
  _ = render(makeUniforms(scene: 1, mode: 1, width: 16, height: 16), samples: 1)
  require(lastRenderUniforms!.indirectReuse & 0x1C0 == 0, "PCG mode leaves the sampler bits clear")

  let kernels = """
    // Coordinates (0.32 fixed point) of 4096 consecutive points: O2m3 (x, y, z) and 2D Sobol'
    // (x, y), unscrambled (seed 0) and Owen-scrambled.
    kernel void z_sequences(constant uint &seed [[buffer(0)]], device uint4 *o2m3 [[buffer(1)]],
                            device uint2 *sobol [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        uint V = reverse_bits(i);
        uint3 p = uint3(z_o2m3_x(V), z_o2m3_y(V), z_o2m3_z(V));
        uint2 q = uint2(V, z_sobol1(i));
        if (seed != 0u) {
            p = uint3(z_owen(p.x, z_owen_seed(seed, 0u)), z_owen(p.y, z_owen_seed(seed, 1u)), z_owen(p.z, z_owen_seed(seed, 2u)));
            q = uint2(z_owen(q.x, z_owen_seed(seed, 0u)), z_owen(q.y, z_owen_seed(seed, 1u)));
        }
        o2m3[i] = uint4(p, 0u); sobol[i] = q;
    }
    kernel void z_shuffles(constant uint2 &base [[buffer(0)]], device uint *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
        out[i] = z_shuffle(base.x + i, base.y);
    }
    // Pixel samples of one frame: rand_f, rand_f2 and rand_f3 of one event, per pixel.
    kernel void z_frame(constant Uniforms &u [[buffer(0)]], device float4 *one [[buffer(1)]],
                        device float4 *three [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        Sampler s = pixel_sampler(gid, u);
        sampler_event(s, 3u, Z_NEE);
        float a = rand_f(s); float2 b = rand_f2(s); float3 c = rand_f3(s);
        one[gid.y * u.width + gid.x] = float4(a, b, 0.0f);
        three[gid.y * u.width + gid.x] = float4(c, 0.0f);
    }
    // PCG-mode Sampler against the uint streams: lens, lights, BSDFs, DI candidates, fog and
    // ReSTIR PT streams must draw identical numbers (counts of mismatching trials). RGB library
    // only (spectral transport draws the same numbers; its helpers need a wavelength context).
    #if !VIBE_SPECTRAL
    kernel void z_pcg_equivalence(constant Uniforms &u [[buffer(0)]], constant MaterialResources &images [[buffer(1)]],
                                  device atomic_uint *mismatches [[buffer(2)]], uint id [[thread_position_in_grid]]) {
        uint2 gid = uint2(id % u.width, id / u.width);
        Sampler s = pixel_sampler(gid, u);
        uint seed = (gid.y * u.width + gid.x) ^ (u.sampleIndex * 1999999973u);
        bool same = !s.z && s.state == seed;
        float3 p = float3(0.3f * rand_f(seed) - 0.15f, -0.9f, 0.2f), n = float3(0, 1, 0);
        rand_f(s.state);
        Ray a = { float3(0, 0, 4), normalize(float3(0.1f, 0.2f, -1)) }, b = a;
        lens_ray(a, float3(0, 0, -1), float3(1, 0, 0), float3(0, 1, 0), u, seed);
        lens_ray(b, float3(0, 0, -1), float3(1, 0, 0), float3(0, 1, 0), u, s);
        same = same && all(a.origin == b.origin) && all(a.direction == b.direction);
        LightSample l1 = sample_direct_light(p, n, u, seed, images), l2 = sample_direct_light(p, n, u, s, images);
        same = same && all(l1.position == l2.position) && l1.pdf == l2.pdf;
        Material m = { OPENPBR, float3(0.7f, 0.5f, 0.3f), float3(0), 0.3f, 1.5f };
        m.specularWeight = 1.0f; m.baseWeight = 1.0f; m.metalness = 0.3f; m.coat = 0.5f; m.coatRoughness = 0.2f;
        m.geometricNormal = n; m.tangent = float3(1, 0, 0);
        Material d = { DIFFUSE, float3(0.6f), float3(0), 1.0f, 1.0f }, g = { DIELECTRIC, float3(1), float3(0), 0.0f, 1.5f };
        float3 view = normalize(float3(0.3f, -1, 0.2f));
        for (int k = 0; k < 3; ++k) {
            Material q = k == 0 ? m : k == 1 ? d : g;
            float3 d1, w1, d2, w2; float p1, p2;
            bool r1 = sample_bsdf(q, n, view, true, seed, d1, w1, p1, Wavelengths()), r2 = sample_bsdf(q, n, view, true, s, d2, w2, p2, Wavelengths());
            same = same && r1 == r2 && (!r1 || (all(d1 == d2) && p1 == p2));
        }
        HitRecord rec = {}; rec.position = p; rec.normal = n; rec.geometricNormal = n; rec.mat = d; rec.front_face = true;
        DIReservoir c1 = restir_di_initial(rec, view, u, seed, images, Wavelengths()), c2 = restir_di_initial(rec, view, u, s, images, Wavelengths());
        same = same && c1.weightSum == c2.weightSum && all(c1.sample.position == c2.sample.position);
        Ray fogRay = { float3(0, 0, 3), normalize(float3(0.05f, 0.1f, -1)) };
        same = same && all(apply_camera_fog(float3(0.5f), fogRay, 5.0f, u, seed, images, Wavelengths()) == apply_camera_fog(float3(0.5f), fogRay, 5.0f, u, s, images, Wavelengths()));
        same = same && seed == s.state;
        uint key = pcg_hash(id * 7919u + 3u);
        uint streamA = pt_seed(key, 2u, 0u);
        Sampler streamB = pt_sampler(key, 2u, 0u, u);
        same = same && all(rand_f3(streamA) == rand_f3(streamB)) && rand_f(streamA) == rand_f(streamB);
        if (!same) atomic_fetch_add_explicit(mismatches, 1u, memory_order_relaxed);
    }
    #endif
    // Z mode: replaying a ReSTIR PT stream from its key reproduces its numbers; the two passes'
    // events and every PT stream draw different numbers from the same key; the lens event is
    // shared by both passes (it defines the pixel's primary ray).
    kernel void z_streams(constant Uniforms &u [[buffer(0)]], device atomic_uint *counts [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.width || gid.y >= u.height) return;
        Sampler pass1 = pixel_sampler(gid, u), pass2 = pixel_sampler(gid, u);
        decorrelate_shading_seed(pass2.state);
        sampler_event(pass1, 0u, Z_LENS); sampler_event(pass2, 0u, Z_LENS);
        bool lens = all(rand_f2(pass1) == rand_f2(pass2));
        sampler_event(pass1, 1u, Z_GI_BSDF); sampler_event(pass2, 1u, Z_BSDF);
        bool distinct = any(rand_f3(pass1) != rand_f3(pass2));
        uint key = z_pixel_key(gid, u);
        Sampler a = pt_sampler(key, 2u, 0u, u), b = pt_sampler(key, 2u, 0u, u), c = pt_sampler(key, 2u, 1u, u), d = pt_sampler(key, 3u, 0u, u);
        float3 x = rand_f3(a), y = rand_f3(b), z = rand_f3(c), w = rand_f3(d);
        bool replay = all(x == y) && rand_f(a) == rand_f(b) && a.state == b.state;
        distinct = distinct && any(x != z) && any(x != w);
        Sampler e = pixel_sampler(gid, u); sampler_event(e, 2u, Z_BSDF);
        distinct = distinct && any(rand_f3(e) != x);
        atomic_fetch_add_explicit(&counts[0], lens ? 1u : 0u, memory_order_relaxed);
        atomic_fetch_add_explicit(&counts[1], replay ? 1u : 0u, memory_order_relaxed);
        atomic_fetch_add_explicit(&counts[2], distinct ? 1u : 0u, memory_order_relaxed);
    }
    // tests/Fix_restir-pt.swift's identity and round-trip shifts, for reservoirs whose seeds are Z keys.
    kernel void z_round_trip(texture2d<float, access::read> positions [[texture(0)]],
        texture2d<float, access::read> normals [[texture(1)]],
        constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],
        constant MaterialResources &images [[buffer(2)]], const device PrimarySurface *surfaces [[buffer(3)]],
        const device PTReservoir *reservoirs [[buffer(5)]], constant int2 &offset [[buffer(6)]],
        device float4 *identity [[buffer(7)]], device float4 *trip [[buffer(8)]] SPECTRAL_BUFFERS, uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.width || gid.y >= u.height) return;
        uint i = gid.y * u.width + gid.x;
        identity[i] = float4(-1); trip[i] = float4(-1);
        PTReservoir r = reservoirs[i];
        float4 p = positions.read(gid);
        if (pt_length(r) == 0u || !(p.w > 0.0f) || !(pt_luminance(r.F) > 0.0f)) return;
        float cone = pt_primary_cone(u);
        HitRecord y = load_primary_surface(surfaces[i], p);
        float3 view = float3(surfaces[i].view);
        float threshold = pt_footprint_threshold(p.w, y.geometricNormal, view);
        PTShift s = pt_shift(r, y, view, threshold, cone, u, settings, images, SPECTRAL_CONTEXT(u, images));
        float J = pt_rc_index(r) > 0u ? s.jacobian / r.rcJacobian : 1.0f;
        identity[i] = float4(pt_luminance(s.FJ), pt_luminance(r.F), J, float(pt_rc_index(r)));
        int2 q = int2(gid) + offset;
        if (!pt_in_frame(q, u)) return;
        float4 qp = positions.read(uint2(q));
        if (!pt_pair_compatible(p, normals.read(gid), qp, normals.read(uint2(q)))) return;
        uint qi = uint(q.y) * u.width + uint(q.x);
        HitRecord z = load_primary_surface(surfaces[qi], qp);
        float3 zView = float3(surfaces[qi].view);
        PTShift forward = pt_shift(r, z, zView, pt_footprint_threshold(qp.w, z.geometricNormal, zView), cone, u, settings, images, SPECTRAL_CONTEXT(u, images));
        if (!(pt_luminance(forward.FJ) > 0.0f)) { trip[i] = float4(0, 0, 0, float(pt_rc_index(r))); return; }
        PTReservoir shifted = r;
        float J1 = pt_rc_index(r) > 0u ? forward.jacobian / r.rcJacobian : 1.0f;
        shifted.F = forward.FJ / J1;
        if (pt_rc_index(r) > 0u) shifted.rcJacobian = forward.jacobian;
        PTShift back = pt_shift(shifted, y, view, threshold, cone, u, settings, images, SPECTRAL_CONTEXT(u, images));
        float J2 = pt_rc_index(r) > 0u ? back.jacobian / shifted.rcJacobian : 1.0f;
        trip[i] = float4(pt_luminance(back.FJ / J2), pt_luminance(r.F), J1 * J2, float(pt_rc_index(r)) + 1000.0f);
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  // Kernels that read rendered reservoirs need their transport's layouts (rendererShaderLibrary).
  let reservoirLibrary = try rendererShaderLibrary(kernels)
  func run(_ name: String, width: Int, height: Int = 1, _ bind: (MTLComputeCommandEncoder) -> Void) throws {
    let state = try gpu.makeComputePipelineState(function: (name == "z_round_trip" ? reservoirLibrary : library).makeFunction(name: name)!)
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(state)
    bind(encoder)
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: height > 1 ? 8 : 64, height: height > 1 ? 8 : 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) completes: \(String(describing: command.error))")
  }
  // Whether every elementary box with `bits` leading bits per listed axis (summing to m) holds
  // exactly one of the 2^m points.
  func isNet(_ points: [[UInt32]], axes: [Int], m: Int) -> Bool {
    func splits(_ total: Int, _ parts: Int) -> [[Int]] {
      parts == 1 ? [[total]] : (0...total).flatMap { a in splits(total - a, parts - 1).map { [a] + $0 } }
    }
    for bits in splits(m, axes.count) {
      var seen = Set<UInt64>()
      for p in points {
        var key: UInt64 = 0
        for (axis, b) in zip(axes, bits) where b > 0 { key = (key << UInt64(b)) | UInt64(p[axis] >> UInt32(32 - b)) }
        if !seen.insert(key).inserted { return false }
      }
    }
    return true
  }

  // Constituent sequences, unscrambled and under two Owen scrambles.
  let o2m3 = gpu.makeBuffer(length: 4096 * 16, options: .storageModeShared)!
  let sobol = gpu.makeBuffer(length: 4096 * 8, options: .storageModeShared)!
  var netFailures = [String]()
  for seed: UInt32 in [0, 7, 0x5eed] {
    var s = seed
    try run("z_sequences", width: 4096) {
      $0.setBytes(&s, length: 4, index: 0); $0.setBuffer(o2m3, offset: 0, index: 1); $0.setBuffer(sobol, offset: 0, index: 2)
    }
    let p = (0..<4096).map { i -> [UInt32] in let v = o2m3.contents().load(fromByteOffset: i * 16, as: SIMD4<UInt32>.self); return [v.x, v.y, v.z] }
    let q = (0..<4096).map { i -> [UInt32] in let v = sobol.contents().load(fromByteOffset: i * 8, as: SIMD2<UInt32>.self); return [v.x, v.y] }
    for m in stride(from: 2, through: 10, by: 2) {
      for start in stride(from: 0, to: 4096, by: 1 << m) where start < 4 << m {
        let block = Array(p[start..<(start + (1 << m))])
        for axes in [[0, 1, 2], [0, 1], [1, 2], [0, 2], [0], [1], [2]] where !isNet(block, axes: axes, m: m) {
          netFailures.append("O2m3 seed \(seed) m \(m) block \(start) axes \(axes)")
        }
      }
    }
    for m in 1...10 {
      for start in stride(from: 0, to: 4096, by: 1 << m) where start < 4 << m {
        if !isNet(Array(q[start..<(start + (1 << m))]), axes: [0, 1], m: m) { netFailures.append("Sobol' seed \(seed) m \(m) block \(start)") }
      }
    }
  }
  require(netFailures.isEmpty, "O2m3 blocks of 4^m points are (0, 2m, 3)-nets with (0, 2m, 2) pairs and 2D Sobol' blocks (0, m, 2)-nets, scrambled or not: \(netFailures.prefix(4))")

  // The recursive shuffle maps aligned blocks of 4^m indices onto aligned blocks.
  let shuffled = gpu.makeBuffer(length: 4096 * 4, options: .storageModeShared)!
  var shuffleOK = true
  for (baseIndex, dimension) in [(UInt32(0), UInt32(1)), (4096 * 777, 12345), (0xFFFF_F000, 3)] {
    var base = SIMD2<UInt32>(baseIndex, dimension)
    try run("z_shuffles", width: 4096) { $0.setBytes(&base, length: 8, index: 0); $0.setBuffer(shuffled, offset: 0, index: 1) }
    let v = (0..<4096).map { shuffled.contents().load(fromByteOffset: $0 * 4, as: UInt32.self) }
    for m in 1...6 {
      for start in stride(from: 0, to: 4096, by: 1 << (2 * m)) {
        let block = v[start..<(start + (1 << (2 * m)))]
        let high = Set(block.map { $0 >> UInt32(2 * m) }), low = Set(block.map { $0 & ((1 << UInt32(2 * m)) - 1) })
        shuffleOK = shuffleOK && high.count == 1 && low.count == 1 << (2 * m)
      }
    }
    shuffleOK = shuffleOK && Set(v).count == 4096
  }
  require(shuffleOK, "the quadrant shuffle is a bijection that maps aligned blocks of 4^m indices onto aligned blocks")

  // Z masks and temporal nets through the production key (z_pixel_key) of every temporal model.
  let side = 32
  let one = gpu.makeBuffer(length: side * side * 16, options: .storageModeShared)!
  let three = gpu.makeBuffer(length: side * side * 16, options: .storageModeShared)!
  func frame(_ model: ZTemporal, sample: UInt32, frameIndex: UInt32) throws -> (one: [SIMD4<Float>], three: [SIMD4<Float>]) {
    var u = makeUniforms(scene: 1, mode: 1, width: side, height: side)
    u.indirectReuse = 64 | (model.rawValue << 7); u.sampleIndex = sample; u.frameIndex = frameIndex
    try run("z_frame", width: side, height: side) {
      $0.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
      $0.setBuffer(one, offset: 0, index: 1); $0.setBuffer(three, offset: 0, index: 2)
    }
    return ((0..<(side * side)).map { one.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) },
            (0..<(side * side)).map { three.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) })
  }
  func fixed(_ v: Float) -> UInt32 { UInt32(v * 16_777_216) << 8 }
  for model in [ZTemporal.perPixel, .interlaced, .spatiotemporal, .reshuffled] {
    // One frame: an aligned 2^k x 2^k pixel block holds a (0, 2k, 1) set of rand_f and a (0, 2k, 2)
    // net of rand_f2 (not for STZ, whose Eq. 6 trades the per-frame mask for less pixelation).
    let single = try frame(model, sample: 1234, frameIndex: 1)
    var maskOK = true
    for k in model == .spatiotemporal ? [] : [1, 2, 3] {
      let n = 1 << k
      for by in stride(from: 0, to: side, by: n) { for bx in stride(from: 0, to: side, by: n) {
        var points1 = [[UInt32]](), points2 = [[UInt32]]()
        for y in by..<(by + n) { for x in bx..<(bx + n) {
          let v = single.one[y * side + x]
          points1.append([fixed(v.x)]); points2.append([fixed(v.y), fixed(v.z)])
        }}
        maskOK = maskOK && isNet(points1, axes: [0], m: 2 * k) && (model == .spatiotemporal || isNet(points2, axes: [0, 1], m: 2 * k))
      }}
    }
    require(maskOK, "\(model): each frame is a Z mask (aligned pixel blocks hold stratified 1D and 2D samples)")
    // Accumulation from an arbitrary start: each pixel's first 16 frames give a (0, 4, 1) set and a
    // (0, 4, 2) net, its first 64 frames a (0, 6, 3)-net of rand_f3.
    var frames = [(one: [SIMD4<Float>], three: [SIMD4<Float>])]()
    for j in 0..<64 { frames.append(try frame(model, sample: 5000 + UInt32(j), frameIndex: UInt32(j) + 1)) }
    var temporalOK = true
    for pixel in stride(from: 0, to: side * side, by: 37) {
      let a = frames.prefix(16).map { [fixed($0.one[pixel].x)] }, b = frames.prefix(16).map { [fixed($0.one[pixel].y), fixed($0.one[pixel].z)] }
      let c = frames.map { [fixed($0.three[pixel].x), fixed($0.three[pixel].y), fixed($0.three[pixel].z)] }
      temporalOK = temporalOK && isNet(a, axes: [0], m: 4) && isNet(b, axes: [0, 1], m: 4) && isNet(c, axes: [0, 1, 2], m: 6)
    }
    require(temporalOK, "\(model): a pixel's samples over an accumulation's frames are nets of every constituent")
  }
  // Uniform marginals over many pixels and frames of a moving camera (every frame starts an accumulation).
  var sum = SIMD3<Double>(0, 0, 0), count = 0.0
  for f in 0..<16 {
    let moving = try frame(.perPixel, sample: 90_000 + UInt32(f) * 13, frameIndex: 1)
    for v in moving.three { sum += SIMD3(Double(v.x), Double(v.y), Double(v.z)); count += 1 }
  }
  let means = sum / count
  require(abs(means.x - 0.5) < 0.005 && abs(means.y - 0.5) < 0.005 && abs(means.z - 0.5) < 0.005, "uniform marginals: \(means)")
  print("PASS: fix-zsampling nets, shuffles, per-frame Z masks and per-pixel temporal nets")

  // Fallback equivalence and streams.
  let mismatches = gpu.makeBuffer(length: 4, options: .storageModeShared)!
  memset(mismatches.contents(), 0, 4)
  for scene: UInt32 in [0, 1, 2] {
    var u = makeUniforms(scene: scene, mode: 1, width: 64, height: 64, fog: 1)
    u.lens.x = 0.05; u.sampleIndex = 17
    try run("z_pcg_equivalence", width: 64 * 64) {
      $0.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0); renderer.materials.bind($0)
      $0.setBuffer(mismatches, offset: 0, index: 2)
    }
  }
  require(mismatches.contents().load(as: UInt32.self) == 0, "the PCG-mode Sampler draws the previous uint streams exactly")
  let counts = gpu.makeBuffer(length: 12, options: .storageModeShared)!
  memset(counts.contents(), 0, 12)
  var zu = makeUniforms(scene: 1, mode: 0, width: 128, height: 96)
  zu.indirectReuse = 64 | (ZTemporal.interlaced.rawValue << 7); zu.sampleIndex = 4242; zu.frameIndex = 3; zu.lens.x = 0.05
  try run("z_streams", width: 128, height: 96) {
    $0.setBytes(&zu, length: MemoryLayout<Uniforms>.stride, index: 0); $0.setBuffer(counts, offset: 0, index: 1)
  }
  let c = (0..<3).map { counts.contents().load(fromByteOffset: $0 * 4, as: UInt32.self) }
  require(c == [128 * 96, 128 * 96, 128 * 96], "Z streams: shared lens event, exact replay from a key, distinct events and PT streams: \(c)")
  print("PASS: fix-zsampling PCG equivalence, exact replay and distinct streams")

  // Random replay of rendered Z-mode ReSTIR PT reservoirs (their seeds are Z keys): a path shifted
  // into its own pixel keeps its integrand, and shifting to another pixel and back recovers it.
  renderer.sampler = .zSampling; renderer.zTemporal = .perPixel
  renderer.temporalReuse = .reprojection; renderer.spatialNeighbors = .automatic; renderer.controlVariates = .automatic
  renderer.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  let rw = 160, rh = 120
  for (scene, label) in [(UInt32(1), "Cornell"), (3, "Cornell glass & mirror"), (0, "Pavilion")] {
    for reuse in [IndirectReuse.restirPT, .restirPTUnified] {
      renderer.indirectReuse = reuse
      _ = render(makeUniforms(scene: scene, mode: 0, width: rw, height: rh), samples: 1)
      var u = lastRenderUniforms!
      require(u.indirectReuse & 64 != 0, "the round-trip render uses the Z sampler")
      let identity = gpu.makeBuffer(length: rw * rh * 16, options: .storageModeShared)!
      let trip = gpu.makeBuffer(length: rw * rh * 16, options: .storageModeShared)!
      var offset = SIMD2<Int32>(3, -2)
      try run("z_round_trip", width: rw, height: rh) {
        $0.setTexture(renderer.historyPosDepth!, index: 0); $0.setTexture(renderer.historyNormalMat!, index: 1)
        renderer.materials.bind($0)
        $0.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        $0.setBuffer(renderer.historyPrimarySurfaces!, offset: 0, index: 3)
        $0.setBuffer(renderer.ptReservoirs!, offset: 0, index: 5)
        $0.setBytes(&offset, length: 8, index: 6)
        $0.setBuffer(identity, offset: 0, index: 7); $0.setBuffer(trip, offset: 0, index: 8)
        bindRendererSpectral($0)
      }
      var identityTotal = 0, identityMatch = 0, tripTotal = 0, tripMatch = 0, tripFailed = 0
      for i in 0..<(rw * rh) {
        let a = identity.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
        if a.w >= 0 { identityTotal += 1; if abs(a.x - a.y) <= 1e-3 * a.y && abs(a.z - 1) <= 1e-3 { identityMatch += 1 } }
        let b = trip.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
        if b.w >= 1000 {
          tripTotal += 1
          if b.x == 0 { tripFailed += 1 } else if abs(b.x - b.y) <= 2e-3 * b.y && abs(b.z - 1) <= 2e-3 { tripMatch += 1 }
        }
      }
      print("Z sampler, \(label) \(reuse): identity \(identityMatch)/\(identityTotal); round trips \(tripMatch)/\(tripTotal) (\(tripFailed) undefined)")
      require(identityTotal > 1000 && Double(identityMatch) >= 0.99 * Double(identityTotal),
        "Z sampler, \(label) \(reuse): replaying a path into its own pixel keeps its integrand and a unit Jacobian")
      require(tripTotal > 300 && Double(tripMatch) >= 0.97 * Double(tripTotal) && Double(tripFailed) <= 0.02 * Double(tripTotal),
        "Z sampler, \(label) \(reuse): shifting to another pixel and back recovers the path")
    }
  }
  print("PASS: fix-zsampling exact random replay of ReSTIR PT paths from Z keys")

  // Rendering: bias, screen-space error distribution and equal-sample error on Cornell.
  func squaredError(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
    zip(a, b).reduce(0.0) { sum, pair in let d = pair.0 - pair.1; return sum + Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3 }
      / Double(a.count)
  }
  // Tone-mapped (x / (1 + x)) error of 4 x 4 pixel means: the part a denoiser or the eye averages over.
  func lowPassError(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>], width: Int, height: Int) -> Double {
    var sum = 0.0, count = 0
    for by in stride(from: 0, to: height - 3, by: 4) { for bx in stride(from: 0, to: width - 3, by: 4) {
      var d = SIMD4<Float>(0, 0, 0, 0)
      for y in by..<(by + 4) { for x in bx..<(bx + 4) {
        let p = simd_max(a[y * width + x], .zero), q = simd_max(b[y * width + x], .zero)
        d += p / (p + 1) - q / (q + 1)
      }}
      d /= 16
      sum += Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3; count += 1
    }}
    return sum / Double(count)
  }
  // Accumulates frames through renderFrame from the renderer's current sample index.
  func accumulate(_ view: Uniforms, frames: Int) -> [SIMD4<Float>] {
    let w = Int(view.width), h = Int(view.height)
    let output = renderOutputs[SIMD2(w, h)] ?? {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
      return gpu.makeTexture(descriptor: d)!
    }()
    renderOutputs[SIMD2(w, h)] = output
    let savedUpdate = renderer.onFrameUpdate
    var completed = 0
    renderer.onFrameUpdate = { _ in completed += 1 }
    renderer.denoiserEnabled = false
    for frame in 1...frames {
      renderer.renderFrame(output: output)
      let deadline = Date().addingTimeInterval(60)
      while completed < frame && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
      require(completed >= frame, "Z-sampler accumulation completes frame \(frame)")
    }
    renderer.onFrameUpdate = savedUpdate
    return readTexture(renderer.accumTexture!)
  }
  let cw = 160, ch = 120
  var cornell = makeUniforms(scene: 1, mode: 1, width: cw, height: ch)
  renderer.sampler = .pcg
  let reference = render(cornell, samples: 2048)
  // Mean radiance against MIS with independent PCG streams, for MIS, ReSTIR GI and unified ReSTIR PT;
  // ReSTIR GI is biased (RESTIRGI2021), so its Z-mode mean is compared with its PCG-mode mean.
  for (mode, reuse, label) in [(UInt32(1), IndirectReuse.restirGI, "MIS"), (0, .restirGI, "ReSTIR GI"), (0, .restirPTUnified, "unified ReSTIR PT")] {
    renderer.indirectReuse = reuse
    cornell.samplingMode = mode
    var means = [SamplerMode: (Double, Double)]()
    for sampler in label == "ReSTIR GI" ? [SamplerMode.pcg, .zSampling] : [.zSampling] {
      renderer.sampler = sampler
      applyTestView(cornell); renderer.resetAccumulation(); renderer.restartSampleSequence(at: 31_000)
      let image = accumulate(cornell, frames: 512)
      let d = pairedDifference(image, reference, width: cw, pixels: Array(0..<image.count), block: 8)
      means[sampler] = (Double(d.mean) / Double(d.reference), Double(d.se) / Double(d.reference))
    }
    let z = means[.zSampling]!, base = means[.pcg] ?? (0, 0)
    print("Z sampler, Cornell \(label): mean radiance \(100 * z.0)% ± \(100 * z.1)% against MIS (PCG mode \(100 * base.0)% ± \(100 * base.1)%)")
    let bound: Double = 3 * (z.1 * z.1 + base.1 * base.1).squareRoot() + 0.001
    require(abs(z.0 - base.0) <= bound, "Z sampler, \(label): mean radiance agrees with the PCG sampler's")
  }
  // One frame of MIS: the Z sampler moves error to high spatial frequencies (4 x 4 means).
  cornell.samplingMode = 1; renderer.indirectReuse = .restirGI
  var low = [SamplerMode: Double](), all = [SamplerMode: Double]()
  for mode in [SamplerMode.pcg, .zSampling] {
    renderer.sampler = mode
    for trial in 0..<8 {
      applyTestView(cornell); renderer.resetAccumulation(); renderer.restartSampleSequence(at: UInt32(trial) * 977 + 5)
      let frame = accumulate(cornell, frames: 1)
      low[mode, default: 0] += lowPassError(frame, reference, width: cw, height: ch) / 8
      all[mode, default: 0] += squaredError(frame, reference) / 8
    }
  }
  print("Cornell MIS single frame, PCG / Z: all \(all[.pcg]!) / \(all[.zSampling]!), 4 x 4 means \(low[.pcg]!) / \(low[.zSampling]!)")
  require(low[.zSampling]! < 0.9 * low[.pcg]! && all[.zSampling]! < 1.1 * all[.pcg]!,
    "Z sampler: one frame's error is blue-noise-like (lower at 4 x 4 pixel scale, not higher per pixel)")
  // Static accumulation: equal-sample MSE of 64 frames from independent sequences.
  var ratios = [Double]()
  for trial in 0..<3 {
    var errors = [Double]()
    for mode in [SamplerMode.pcg, .zSampling] {
      renderer.sampler = mode
      applyTestView(cornell); renderer.resetAccumulation(); renderer.restartSampleSequence(at: UInt32(trial) * 7000 + 11)
      errors.append(squaredError(accumulate(cornell, frames: 64), reference))
    }
    ratios.append(errors[1] / errors[0])
  }
  print("Cornell MIS 64-frame MSE ratio (Z / PCG): \(ratios)")
  require(ratios.allSatisfy { $0 < 0.9 }, "Z sampler lowers the equal-sample MSE of static MIS accumulation")
  print("PASS: fix-zsampling mean radiance, blue-noise frame error and equal-sample gains")
}
try fixZSamplingChecks()
