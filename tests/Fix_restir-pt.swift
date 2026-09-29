// ReSTIR PT (REFERENCES.md RESTIRPT2022, RESTIRPTE2026): layout and mode plumbing; the pairing
// textures and their per-frame transforms; octahedral directions; resampling MIS partitions of
// unity; the reconnection criteria; identity and round-trip (invertibility, Jacobian) checks of
// the hybrid shift on rendered reservoirs; the temporal-reuse policy; reservoir memory and
// placeholders; fallback equivalence of the other strategies; mean radiance against MIS; and
// equal-sample and interactive error gains over ReSTIR GI.
@MainActor func fixRestirPTChecks() throws {
  let renderer = testRenderer
  let saved = (renderer.indirectReuse, renderer.ptDecorrelation, renderer.ptTemporalWhileAccumulating)
  let savedSettings = renderer.materials.settings

  // Layout: the mode occupies former padding, so the 304-byte stride is unchanged.
  require(MemoryLayout<Uniforms>.stride == 304 && MemoryLayout<Uniforms>.offset(of: \Uniforms.indirectReuse) == 228
      && MemoryLayout<Uniforms>.offset(of: \Uniforms.jitter) == 232, "Uniforms.indirectReuse sits at offset 228 of the 304-byte uniforms")
  require(PathTracerRenderer.primarySurfaceStride == 128 && PathTracerRenderer.ptReservoirStride == 64, "128-byte primary surfaces, 64-byte path reservoirs")
  let environmentDefault: IndirectReuse = ["gi": .restirGI, "pt": .restirPT, "unified": .restirPTUnified][
    ProcessInfo.processInfo.environment["VIBE_INDIRECT_REUSE"] ?? ""] ?? .automatic
  require(PathTracerRenderer.defaultIndirectReuse == environmentDefault, "the default indirect reuse follows the VIBE_INDIRECT_REUSE test seam")
  require(IndirectReuse.automatic.resolved(importedScene: true) == .restirPTUnified
      && IndirectReuse.automatic.resolved(importedScene: false) == .restirGI
      && IndirectReuse.restirPT.resolved(importedScene: false) == .restirPT
      && IndirectReuse.restirGI.resolved(importedScene: true) == .restirGI,
    "automatic reuse is unified ReSTIR PT for imported scenes and ReSTIR GI for procedural ones; explicit modes are kept")

  let kernels = """
    kernel void pt_layout(device uint *out [[buffer(0)]]) {
        Uniforms v;
        out[0] = sizeof(Uniforms);
        out[1] = uint((thread char *)&v.indirectReuse - (thread char *)&v);
        out[2] = sizeof(PTReservoir);
        out[3] = sizeof(PrimarySurface);
    }
    kernel void pt_units(device float *out [[buffer(0)]]) {
        uint seed = 91u;
        float worst = 0.0f;
        for (uint i = 0; i < 65536u; ++i) {
            float3 d = normalize(float3(rand_f(seed), rand_f(seed), rand_f(seed)) * 2.0f - 1.0f);
            worst = max(worst, length(d - pt_decode_direction(pt_encode_direction(d))));  // chord ~ angle
        }
        out[0] = worst;
        // Partitions of unity at one path y: Talbot over two domains, and pairwise MIS over the
        // canonical domain and n neighbours, from the target values of y in each domain.
        float talbot = 0.0f, pairwise = 0.0f;
        for (uint trial = 0; trial < 4096u; ++trial) {
            float pc = rand_f(seed) * 3.0f, cc = 1.0f + 20.0f * rand_f(seed);
            float pt = rand_f(seed) < 0.2f ? 0.0f : rand_f(seed) * 3.0f, ct = 20.0f * rand_f(seed) + 0.5f;
            if (pc > 0.0f || pt > 0.0f) talbot = max(talbot, abs(pt_talbot(pc, cc, pt, ct) + pt_talbot(pt, ct, pc, cc) - 1.0f));
            uint n = 1u + uint(rand_f(seed) * 3.0f);
            float neighbour[3], confidence[3];
            float sum = 1.0f, canonical = 1.0f;
            for (uint j = 0; j < n; ++j) {
                neighbour[j] = rand_f(seed) < 0.3f ? 0.0f : rand_f(seed) * 3.0f;
                confidence[j] = 1.0f + 60.0f * rand_f(seed);
            }
            float scale = 1.0f / (float(n) + 1.0f);
            for (uint j = 0; j < n; ++j) {
                float b = pt_pairwise(neighbour[j], confidence[j], pc, cc, float(n));
                canonical += 1.0f - b;
                sum += b;
            }
            sum = sum - 1.0f + canonical;
            if (pc > 0.0f) pairwise = max(pairwise, abs(sum * scale - 1.0f));
        }
        out[1] = talbot; out[2] = pairwise;
        // Reconnection criteria (Eq. 5): R = 0.01 m^2; a matte x_{k-1} with pdf 1/pi.
        Material matte = { DIFFUSE, float3(0.8f), float3(0), 0.0f, 1.0f };
        Material glossy = { GLOSSY, float3(0.9f), float3(0), 0.1f, 1.0f };
        Material rough = { GLOSSY, float3(0.9f), float3(0), 0.3f, 1.0f };
        Material glass = { DIELECTRIC, float3(1), float3(0), 0.0f, 1.5f };
        float p = 1.0f / PI, R = 0.01f;
        out[3] = pt_connectable(matte, p, 0.04f, 1.0f, 1.0f, false, 0.0f, R) ? 1.0f : 0.0f;   // 0.2 m: passes
        out[4] = pt_connectable(matte, p, 0.001f, 1.0f, 1.0f, false, 0.0f, R) ? 1.0f : 0.0f;  // 3 cm: fails
        out[5] = pt_connectable(glossy, p, 1.0f, 1.0f, 1.0f, false, 0.0f, R) ? 1.0f : 0.0f;   // roughness guard
        out[6] = pt_connectable(rough, 2.0f, 1.0f, 1.0f, 1.0f, true, 50.0f, R) ? 1.0f : 0.0f;  // inverse footprint 1/50 >= R
        out[7] = pt_connectable(rough, 2.0f, 1.0f, 1.0f, 1.0f, true, 500.0f, R) ? 1.0f : 0.0f; // 1/500 < R: fails
        out[8] = pt_connectable(glass, p, 1.0f, 1.0f, 1.0f, false, 0.0f, R) ? 1.0f : 0.0f;
        out[9] = pt_connectable(matte, p, -1.0f, 1.0f, 1.0f, true, 0.0f, R) ? 1.0f : 0.0f;    // environment endpoint
        Material layered = matte; layered.type = OPENPBR;
        out[10] = (pt_rough(layered, 2.0f) ? 1.0f : 0.0f) + (pt_rough(layered, 2.5f) ? 2.0f : 0.0f);
    }
    // Pixel p's n-th partner q has p as its n-th partner, for every frame transform.
    kernel void pt_pairs(constant Uniforms &u [[buffer(0)]], const device char2 *pairing [[buffer(1)]],
                         device uint4 *out [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.width || gid.y >= u.height) return;
        uint inside = 0, inverse = 0; float distance = 0.0f;
        for (uint n = 0; n < PT_NEIGHBORS; ++n) {
            int2 q = pt_partner(int2(gid), n, u, pairing);
            if (!pt_in_frame(q, u)) continue;
            ++inside;
            if (all(pt_partner(q, n, u, pairing) == int2(gid))) ++inverse;
            distance += length(float2(q - int2(gid)));
        }
        out[gid.y * u.width + gid.x] = uint4(inside, inverse, as_type<uint>(distance), 0);
    }
    // Identity: each pixel's reservoir shifted into its own pixel. Round trip: shifted to the
    // pixel `offset` away and back, which must return the base path and invert the Jacobian.
    kernel void pt_round_trip(texture2d<float, access::read> positions [[texture(0)]],
        texture2d<float, access::read> normals [[texture(1)]],
        constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],
        constant MaterialResources &images [[buffer(2)]], const device PrimarySurface *surfaces [[buffer(3)]],
        const device PTReservoir *reservoirs [[buffer(5)]], constant int2 &offset [[buffer(6)]],
        device float4 *identity [[buffer(7)]], device float4 *trip [[buffer(8)]], uint2 gid [[thread_position_in_grid]]) {
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
        PTShift s = pt_shift(r, y, view, threshold, cone, u, settings, images);
        float J = pt_rc_index(r) > 0u ? s.jacobian / r.rcJacobian : 1.0f;
        identity[i] = float4(pt_luminance(s.FJ), pt_luminance(r.F), J, float(pt_rc_index(r)));
        int2 q = int2(gid) + offset;
        if (!pt_in_frame(q, u)) return;
        float4 qp = positions.read(uint2(q));
        if (!pt_pair_compatible(p, normals.read(gid), qp, normals.read(uint2(q)))) return;
        uint qi = uint(q.y) * u.width + uint(q.x);
        HitRecord z = load_primary_surface(surfaces[qi], qp);
        float3 zView = float3(surfaces[qi].view);
        PTShift forward = pt_shift(r, z, zView, pt_footprint_threshold(qp.w, z.geometricNormal, zView), cone, u, settings, images);
        if (!(pt_luminance(forward.FJ) > 0.0f)) { trip[i] = float4(0, 0, 0, float(pt_rc_index(r))); return; }
        PTReservoir shifted = r;
        float J1 = pt_rc_index(r) > 0u ? forward.jacobian / r.rcJacobian : 1.0f;
        shifted.F = forward.FJ / J1;
        if (pt_rc_index(r) > 0u) shifted.rcJacobian = forward.jacobian;
        PTShift back = pt_shift(shifted, y, view, threshold, cone, u, settings, images);
        float J2 = pt_rc_index(r) > 0u ? back.jacobian / shifted.rcJacobian : 1.0f;
        trip[i] = float4(pt_luminance(back.FJ / J2), pt_luminance(r.F), J1 * J2, float(pt_rc_index(r)) + 1000.0f);
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  func run(_ name: String, width: Int, height: Int = 1, _ bind: (MTLComputeCommandEncoder) -> Void) throws {
    let state = try gpu.makeComputePipelineState(function: library.makeFunction(name: name)!)
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(state)
    bind(encoder)
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: height > 1 ? 8 : 1, height: height > 1 ? 8 : 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) completes: \(String(describing: command.error))")
  }
  let layout = gpu.makeBuffer(length: 16, options: .storageModeShared)!
  try run("pt_layout", width: 1) { $0.setBuffer(layout, offset: 0, index: 0) }
  let sizes = (0..<4).map { layout.contents().load(fromByteOffset: $0 * 4, as: UInt32.self) }
  require(sizes == [304, 228, 64, 128], "MSL Uniforms.indirectReuse, PTReservoir and PrimarySurface match the Swift layout: \(sizes)")

  let units = gpu.makeBuffer(length: 11 * 4, options: .storageModeShared)!
  try run("pt_units", width: 1) { $0.setBuffer(units, offset: 0, index: 0) }
  let v = (0..<11).map { units.contents().load(fromByteOffset: $0 * 4, as: Float.self) }
  print("ReSTIR PT units: octahedral error \(v[0]) rad, Talbot/pairwise partition error \(v[1]) / \(v[2]), criteria \(Array(v[3...]))")
  require(v[0] < 1e-4, "octahedral 2 x 16-bit directions round-trip within 1e-4 rad")
  require(v[1] < 1e-5 && v[2] < 1e-5, "generalized Talbot and defensive pairwise MIS weights sum to one at every path")
  require(v[3] == 1 && v[4] == 0 && v[5] == 0 && v[6] == 1 && v[7] == 0 && v[8] == 0 && v[9] == 1,
    "reconnection criteria: footprints, inverse footprint, roughness guard, delta and environment endpoints")
  require(v[10] == 1, "layered materials pass the PDF roughness proxy for p <= 1 / sqrt(0.2) only")
  print("PASS: fix-restir-pt layout, octahedral directions, MIS partitions of unity and reconnection criteria")

  // Pairing textures (RESTIRPTE2026 Sec. 3.1): self-inverse, tileable, mean offset near sigma sqrt(pi / 2).
  var start = 0
  for side in ReSTIRPTPairing.sides {
    let deltas = Array(ReSTIRPTPairing.deltas[start..<(start + side * side)])
    var inverse = true, total = 0.0
    for y in 0..<side { for x in 0..<side {
      let d = deltas[y * side + x]
      let px = ((x + Int(d.x)) % side + side) % side, py = ((y + Int(d.y)) % side + side) % side
      let back = deltas[py * side + px]
      inverse = inverse && back == SIMD2(-d.x, -d.y) && d != SIMD2(0, 0)
      total += (Double(d.x) * Double(d.x) + Double(d.y) * Double(d.y)).squareRoot()
    }}
    let meanDistance = total / Double(side * side), expected = ReSTIRPTPairing.sigma * (Double.pi / 2).squareRoot()
    print("Pairing texture \(side): mean offset \(meanDistance) pixels (sigma sqrt(pi/2) = \(expected))")
    require(inverse, "pairing texture \(side) links every texel to a distinct texel that links back")
    require(abs(meanDistance - expected) < 0.15 * expected, "pairing texture \(side) offsets follow sigma = \(ReSTIRPTPairing.sigma)")
    start += side * side
  }
  let pairing = ReSTIRPTPairing.deltas.withUnsafeBytes { gpu.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
  let pw = 300, ph = 200
  let pairs = gpu.makeBuffer(length: pw * ph * 16, options: .storageModeShared)!
  var inside = 0, inverse = 0, distance = 0.0
  for frame in UInt32(1)...8 {
    var pu = makeUniforms(scene: 1, mode: 0, width: pw, height: ph)
    pu.sampleIndex = frame * 7919
    try run("pt_pairs", width: pw, height: ph) {
      $0.setBytes(&pu, length: MemoryLayout<Uniforms>.stride, index: 0)
      $0.setBuffer(pairing, offset: 0, index: 1); $0.setBuffer(pairs, offset: 0, index: 2)
    }
    for i in 0..<(pw * ph) {
      let o = pairs.contents().load(fromByteOffset: i * 16, as: SIMD4<UInt32>.self)
      inside += Int(o.x); inverse += Int(o.y); distance += Double(Float(bitPattern: o.z))
    }
  }
  print("Paired partners: \(inside) in frame, \(inverse) self-inverse, mean distance \(distance / Double(inside)) pixels")
  require(inside == inverse && inside > 8 * pw * ph * 3 * 8 / 10, "every in-frame partner pairs back under the per-frame flips, transposes and offsets")
  print("PASS: fix-restir-pt pairing textures and per-frame transforms are self-inverse")

  // Identity and round-trip shifts on rendered reservoirs (temporal-pass output of frame 1).
  let rw = 160, rh = 120
  func shiftChecks(_ view: Uniforms, label: String) throws {
    for (reuse, offsets) in [(IndirectReuse.restirPT, [SIMD2<Int32>(2, 1), SIMD2<Int32>(-5, 3)]),
                             (IndirectReuse.restirPTUnified, [SIMD2<Int32>(1, -2), SIMD2<Int32>(7, 0)])] {
      renderer.indirectReuse = reuse
      _ = render(view, samples: 1)
      var u = lastRenderUniforms!
      let identity = gpu.makeBuffer(length: rw * rh * 16, options: .storageModeShared)!
      let trip = gpu.makeBuffer(length: rw * rh * 16, options: .storageModeShared)!
      var identityTotal = 0, identityMatch = 0, tripTotal = 0, tripMatch = 0, tripFailed = 0, byKind = [Int: Int]()
      for (index, o) in offsets.enumerated() {
        var offset = o
        try run("pt_round_trip", width: rw, height: rh) {
          // renderFrame swapped the G-buffer; the spatial pass copied this frame's surfaces.
          $0.setTexture(renderer.historyPosDepth!, index: 0); $0.setTexture(renderer.historyNormalMat!, index: 1)
          renderer.materials.bind($0)
          $0.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
          $0.setBuffer(renderer.historyPrimarySurfaces!, offset: 0, index: 3)
          $0.setBuffer(renderer.ptReservoirs!, offset: 0, index: 5)
          $0.setBytes(&offset, length: 8, index: 6)
          $0.setBuffer(identity, offset: 0, index: 7); $0.setBuffer(trip, offset: 0, index: 8)
        }
        for i in 0..<(rw * rh) {
          let a = identity.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
          if index == 0 && a.w >= 0 {
            identityTotal += 1
            if abs(a.x - a.y) <= 1e-3 * a.y && abs(a.z - 1) <= 1e-3 { identityMatch += 1 }
          }
          let b = trip.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
          if b.w >= 1000 {
            tripTotal += 1
            byKind[Int(b.w) - 1000 == 0 ? 0 : 1, default: 0] += 1
            if b.x == 0 { tripFailed += 1 }
            else if abs(b.x - b.y) <= 2e-3 * b.y && abs(b.z - 1) <= 2e-3 { tripMatch += 1 }
          }
        }
      }
      print("\(label) \(reuse): identity \(identityMatch)/\(identityTotal); round trips \(tripMatch)/\(tripTotal) (\(tripFailed) inverse shifts undefined; replay-only \(byKind[0] ?? 0), reconnection \(byKind[1] ?? 0))")
      require(identityTotal > 1000 && Double(identityMatch) >= 0.99 * Double(identityTotal),
        "\(label) \(reuse): a path shifted into its own pixel keeps its integrand and a unit Jacobian")
      require(tripTotal > 500 && Double(tripMatch) >= 0.97 * Double(tripTotal) && Double(tripFailed) <= 0.02 * Double(tripTotal),
        "\(label) \(reuse): shifting to another pixel and back recovers the path, and the two Jacobians multiply to one")
    }
  }
  renderer.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  try shiftChecks(makeUniforms(scene: 1, mode: 0, width: rw, height: rh), label: "Cornell")
  try shiftChecks(makeUniforms(scene: 3, mode: 0, width: rw, height: rh), label: "Cornell glass & mirror")
  try shiftChecks(makeUniforms(scene: 0, mode: 0, width: rw, height: rh), label: "Pavilion")
  var coated = SurfaceSettings(); coated.enabled = 1; coated.surface = SIMD4<Float>(0.4, 0, 0.5, 0)
  renderer.materials.settings[1] = coated
  try shiftChecks(makeUniforms(scene: 0, mode: 0, width: rw, height: rh), label: "Pavilion, coated floor")
  renderer.materials.settings = savedSettings
  print("PASS: fix-restir-pt hybrid shift identity, invertibility and Jacobians")

  // Temporal reuse runs while the view changes; a static accumulation reuses spatially only.
  func meanConfidence(_ buffer: MTLBuffer) -> Float {
    let shared = gpu.makeBuffer(length: buffer.length, options: .storageModeShared)!
    let command = renderer.commandQueue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
    blit.copy(from: buffer, sourceOffset: 0, to: shared, destinationOffset: 0, size: buffer.length)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    let f = shared.contents().bindMemory(to: Float.self, capacity: buffer.length / 4)
    var sum: Float = 0, count: Float = 0
    for i in 0..<(buffer.length / 64) where f[i * 16 + 7] > 0 { sum += f[i * 16 + 7]; count += 1 }
    return sum / max(count, 1)
  }
  renderer.indirectReuse = .restirPTUnified
  let staticView = makeUniforms(scene: 1, mode: 0, width: 64, height: 48)
  _ = render(staticView, samples: 6)
  let staticM = meanConfidence(renderer.ptReservoirs!)
  _ = render(staticView, samples: 6, orbit: true)
  let movingM = meanConfidence(renderer.ptReservoirs!)
  renderer.ptTemporalWhileAccumulating = true
  _ = render(staticView, samples: 6)
  let alwaysM = meanConfidence(renderer.ptReservoirs!)
  renderer.ptTemporalWhileAccumulating = false
  print("Temporal-pass confidence: static \(staticM), orbiting \(movingM), temporal while accumulating \(alwaysM)")
  require(staticM == 1 && movingM > 10 && alwaysM > 10,
    "temporal reuse runs while the camera moves (and on request while accumulating), not over a static accumulation")
  print("PASS: fix-restir-pt temporal reuse policy")

  // Memory: placeholders and full-size reservoirs per mode; the plan matches the resident frame.
  let mw = 256, mh = 192
  for reuse in [IndirectReuse.restirGI, .restirPT, .restirPTUnified] {
    renderer.indirectReuse = reuse
    _ = render(makeUniforms(scene: 1, mode: 0, width: mw, height: mh), samples: 1)
    let pt = reuse != .restirGI
    require((renderer.resPosDirA?.width == mw) == (reuse != .restirPTUnified) && (renderer.giPosPdfA?.width == mw) == !pt
        && (renderer.ptIndirect?.width == mw) == pt && (renderer.ptDuplication?.width == mw) == pt
        && (renderer.ptReservoirs?.length ?? 0) == (pt ? mw * mh * 64 : 0) && (renderer.ptShifts?.length ?? 0) == (pt ? mw * mh * (renderer.activeSpatialNeighbors == .stochasticPairwise
            ? PathTracerRenderer.spmisShiftBytesPerPixel : 48) : 0)
        && (renderer.historyPrimarySurfaces?.length ?? 0) == (pt ? mw * mh * 128 : 0)
        && (renderer.ptControls?.length ?? 0) == (pt ? mw * mh * 16 : 0),
      "\(reuse) allocates exactly its reservoir sets; the others are placeholders")
    let plan = PathTracerRenderer.FrameResourcePlan(width: mw, height: mh, usesReSTIR: true, usesMetalFX: false, indirectReuse: reuse)
    let resident = Double(renderer.residentFrameBytes), planned = Double(plan.bytes!)
    print("\(reuse): resident frame \(Int(resident)) B, plan \(Int(planned)) B")
    require(resident >= 0.95 * planned && resident <= 1.1 * planned, "\(reuse): the resource plan matches the resident frame")
  }
  // 322 B of ReSTIR PT resources and the 16 B ReSTCV estimate (RESTCV2026).
  require(PathTracerRenderer.FrameResourcePlan.reservoirBytesPerPixel(.restirPT) == 96 + 338
      && PathTracerRenderer.FrameResourcePlan.reservoirBytesPerPixel(.restirPTUnified) == 338
      && PathTracerRenderer.FrameResourcePlan.reservoirBytesPerPixel(.restirGI) == 208
      && PathTracerRenderer.FrameResourcePlan.reservoirBytesPerPixel(.automatic) == 338, "reservoir bytes per pixel per mode")
  renderer.indirectReuse = .restirGI
  _ = render(makeUniforms(scene: 1, mode: 0, width: mw, height: mh), samples: 1)
  renderer.indirectReuse = .restirPTUnified
  _ = render(makeUniforms(scene: 1, mode: 0, width: mw, height: mh), samples: 2)
  require(renderer.ptReservoirs?.length == mw * mh * 64, "switching the indirect reuse reallocates the reservoirs")
  print("PASS: fix-restir-pt reservoir memory and placeholders")

  // Fallback equivalence: the other strategies ignore the indirect reuse; ReSTIR GI keeps its
  // output after ReSTIR PT frames (no state leaks between modes).
  for mode in UInt32(1)...3 {
    renderer.indirectReuse = .restirGI
    let gi = render(makeUniforms(scene: 3, mode: mode, width: 64, height: 48), samples: 3)
    renderer.indirectReuse = .restirPTUnified
    let pt = render(makeUniforms(scene: 3, mode: mode, width: 64, height: 48), samples: 3)
    require(gi == pt, "strategy \(mode) renders identically whatever the indirect reuse")
  }
  renderer.indirectReuse = .restirGI
  let before = render(makeUniforms(scene: 1, mode: 0, width: 64, height: 48), samples: 3)
  renderer.indirectReuse = .restirPT
  _ = render(makeUniforms(scene: 1, mode: 0, width: 64, height: 48), samples: 3)
  renderer.indirectReuse = .restirGI
  require(render(makeUniforms(scene: 1, mode: 0, width: 64, height: 48), samples: 3) == before, "ReSTIR GI output is unchanged by earlier ReSTIR PT frames")
  print("PASS: fix-restir-pt fallback equivalence of MIS, light, BSDF and ReSTIR GI")

  // MetalFX and OIDN guides in ReSTIR PT mode, and the duplication map.
  renderer.indirectReuse = .restirPTUnified
  renderer.ptDecorrelation = true
  _ = render(makeUniforms(scene: 0, mode: 0, width: 96, height: 72), samples: 6, denoise: true)
  require(lastDisplay.contains { $0.x > 0 }, "unified ReSTIR PT presents through MetalFX (or its raw fallback)")
  let duplication = readTexture(renderer.ptDuplication!)
  require(duplication.allSatisfy { $0.x >= 0 && $0.x <= 1 } && duplication.contains { $0.x > 0 },
    "the duplication map counts shifted copies of a pixel's path in [0, 1]")
  renderer.ptDecorrelation = false
  print("PASS: fix-restir-pt MetalFX presentation and duplication map")

  // Mean radiance against MIS (bias check), tile-clustered standard errors.
  func agreement(_ view: Uniforms, label: String, modes: [IndirectReuse]) {
    var mis = view; mis.samplingMode = 1
    let reference = render(mis, samples: 768)
    let w = Int(view.width)
    for reuse in modes {
      renderer.indirectReuse = reuse
      var pt = view; pt.samplingMode = 0
      let image = render(pt, samples: 384)
      let d = pairedDifference(image, reference, width: w, pixels: Array(0..<image.count), block: 8)
      print("\(label) \(reuse) - MIS: \(d.mean / d.reference) ± \(d.se / d.reference) (relative)")
      require(abs(d.mean) < 4 * d.se + 0.004 * d.reference, "\(label): \(reuse) agrees with MIS in mean radiance")
    }
  }
  agreement(makeUniforms(scene: 1, mode: 0, width: 128, height: 96), label: "Cornell", modes: [.restirPT, .restirPTUnified])
  agreement(makeUniforms(scene: 3, mode: 0, width: 128, height: 96), label: "Cornell glass & mirror", modes: [.restirPT, .restirPTUnified])
  agreement(makeUniforms(scene: 0, mode: 0, width: 128, height: 96), label: "Pavilion", modes: [.restirPTUnified])
  renderer.ptTemporalWhileAccumulating = true
  agreement(makeUniforms(scene: 1, mode: 0, width: 128, height: 96), label: "Cornell, temporal on every frame", modes: [.restirPTUnified])
  renderer.ptTemporalWhileAccumulating = false
  print("PASS: fix-restir-pt mean radiance agrees with MIS")

  // Error gains over ReSTIR GI. Imported UV sphere on a floor (scene 6): equal-sample MSE of
  // accumulations from independent seed sequences against a 1,024-sample MIS reference.
  var obj = "v -3 -1 -3\nv 3 -1 -3\nv 3 -1 3\nv -3 -1 3\nf 1 4 3 2\n"
  let rings = 32, segments = 32
  for i in 0...rings { for j in 0..<segments {
    let theta = Float.pi * Float(i) / Float(rings), phi = 2 * Float.pi * Float(j) / Float(segments)
    obj += "v \(0.6 * sin(theta) * cos(phi)) \(-0.4 + 0.6 * cos(theta)) \(0.6 * sin(theta) * sin(phi))\n"
  }}
  for i in 0..<rings { for j in 0..<segments {
    let a = 5 + i * segments + j, b = 5 + i * segments + (j + 1) % segments
    obj += "f \(a) \(b) \(b + segments) \(a + segments)\n"
  }}
  renderer.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  try renderer.materials.setMesh(try OBJMesh.load(obj))
  renderer.materials.hasSceneGraph = false
  func squaredError(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
    zip(a, b).reduce(0.0) { sum, pair in let d = pair.0 - pair.1; return sum + Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3 } / Double(a.count)
  }
  var mesh = makeUniforms(scene: 6, mode: 1, width: 160, height: 120)
  mesh.environment.w = Float(renderer.materials.nodeCount)
  let meshReference = render(mesh, samples: 1024)
  mesh.samplingMode = 0
  var ratios = [Double]()
  for trial in 0..<4 {
    var errors = [Double]()
    for reuse in [IndirectReuse.restirGI, .restirPTUnified] {
      renderer.indirectReuse = reuse
      applyTestView(mesh); renderer.resetAccumulation(); renderer.restartSampleSequence(at: UInt32(trial) * 5000)
      errors.append(squaredError(accumulateFrames(mesh, frames: 32), meshReference))
    }
    ratios.append(errors[1] / errors[0])
  }
  let meanRatio = ratios.reduce(0, +) / Double(ratios.count)
  print("Imported mesh 32-frame MSE ratio (unified ReSTIR PT / ReSTIR GI): \(ratios) mean \(meanRatio)")
  require(ratios.allSatisfy { $0 < 0.9 } && meanRatio < 0.8, "unified ReSTIR PT lowers equal-sample MSE on the imported mesh by more than 20%")
  try renderer.materials.setMesh([])
  renderer.materials.settings = savedSettings

  // Interactive preview: after 12 orbiting frames (accumulation reset each frame, ReSTIR history
  // kept), the tone-mapped error of the last frame against MIS at that view. Display-referred: the
  // display clamps the negative values a ReSTCV frame can hold (RESTCV2026) to black.
  func toneMapped(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
    zip(a, b).reduce(0.0) { sum, pair in
      let p = simd_max(pair.0, .zero), q = simd_max(pair.1, .zero)
      let x = p / (p + 1), y = q / (q + 1), d = x - y
      return sum + Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3 } / Double(a.count)
  }
  // Measured ratios at this size: about 0.8 (Cornell) and 0.46 (Pavilion).
  for (scene, label, bound) in [(UInt32(1), "Cornell", 0.92), (UInt32(0), "Pavilion", 0.7)] {
    var errors = [IndirectReuse: Double]()
    var reference = [SIMD4<Float>]()
    for reuse in [IndirectReuse.restirGI, .restirPTUnified] {
      renderer.indirectReuse = reuse
      let frame = render(makeUniforms(scene: scene, mode: 0, width: 128, height: 96), samples: 12, orbit: true)
      if reference.isEmpty {
        var view = lastRenderUniforms!; view.samplingMode = 1
        reference = render(view, samples: 768)
      }
      errors[reuse] = toneMapped(frame, reference)
    }
    print("\(label) orbiting-frame tone-mapped MSE: ReSTIR GI \(errors[.restirGI]!), unified ReSTIR PT \(errors[.restirPTUnified]!)")
    require(errors[.restirPTUnified]! < bound * errors[.restirGI]!, "\(label): ReSTIR PT lowers the per-frame error of the interactive preview")
  }
  print("PASS: fix-restir-pt equal-sample and interactive error gains over ReSTIR GI")
  (renderer.indirectReuse, renderer.ptDecorrelation, renderer.ptTemporalWhileAccumulating) = saved
}
// Accumulates frames through renderFrame from the renderer's current sample index (render()
// always restarts it), for independent seed sequences.
@MainActor func accumulateFrames(_ view: Uniforms, frames: Int) -> [SIMD4<Float>] {
  let r = testRenderer
  let w = Int(view.width), h = Int(view.height)
  let output = renderOutputs[SIMD2(w, h)] ?? {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
    return gpu.makeTexture(descriptor: d)!
  }()
  renderOutputs[SIMD2(w, h)] = output
  let saved = r.onFrameUpdate
  var completed = 0
  r.onFrameUpdate = { _ in completed += 1 }
  r.denoiserEnabled = false
  for frame in 1...frames {
    r.renderFrame(output: output)
    let deadline = Date().addingTimeInterval(60)
    while completed < frame && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
    require(completed >= frame, "accumulateFrames completes frame \(frame)")
  }
  r.onFrameUpdate = saved
  return readTexture(r.accumTexture!)
}
try fixRestirPTChecks()
