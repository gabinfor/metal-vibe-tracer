// Dispersion sampling (REFERENCES.md HERO2014, CMIS2020; docs/SPECTRAL_DESIGN.md §13): spectral MIS
// at rough dispersive lobes and lane splitting at the camera's delta dispersive vertices, against the
// earlier hero-wavelength termination (DispersionSampling.hero). Unit checks: the balance weights over
// the four hero techniques sum to one, sampling and evaluation agree, delta vertices keep one lane or
// split. Renders: each mode agrees with a high-sample reference, splitting and spectral MIS lower the
// error, non-dispersive scenes are unchanged, ReSTIR PT replays dispersive paths, and a thin film
// colours an ideal mirror.
@MainActor func fixSpectralMISChecks() throws {
  let r = testRenderer
  let saved = (r.lightTransport, r.materials.settings, r.materials.spectralOverrides, r.dispersionSampling, r.sampler, r.indirectReuse)
  defer {
    (r.lightTransport, r.materials.settings, r.materials.spectralOverrides, r.dispersionSampling, r.sampler, r.indirectReuse) = saved
  }
  r.lightTransport = .spectral
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  require(DispersionSampling.automatic.resolved() == .spectralMISSplit, "Automatic dispersion sampling resolves to spectral MIS with splitting")
  func roughGlass(_ roughness: Float) -> SurfaceSettings {
    var s = SurfaceSettings(); s.enabled = 1; s.color = SIMD4(1, 1, 1, 1); s.surface = SIMD4(roughness, 0, 0, 0); s.detail = SIMD4(0, 1.52, 1, 1)
    return s
  }

  // --- Unit checks (slot 5: rough OpenPBR glass, OpenPBR dispersion 1 = Abbe 20) ---------------
  let kernels = """
    Material spectral_mis_glass(float roughness) {
        Material m = {};
        m.type = OPENPBR; m.albedo = float3(1.0f); m.roughness = roughness; m.ior = 1.52f; m.transmission = 1.0f;
        m.slot = 5u; m.geometricNormal = float3(0, 0, 1); m.inside = false;
        return m;
    }
    // Per direction pair (tid): out[4 tid + k] = (sum over heroes h of the lane-k balance weight
    // (value / f) / sum R^h, with a random prefix q; the same without prefix (R = 1); f_k; 0).
    kernel void spectral_mis_weights(constant Uniforms &u [[buffer(1)]], constant MaterialResources &images [[buffer(2)]],
                                     device float4 *out [[buffer(0)]] SPECTRAL_BUFFERS, uint tid [[thread_position_in_grid]]) {
        uint seed = 977u * tid + 13u;
        Material glass = spectral_mis_glass(tid % 2u == 0u ? 0.2f : 0.08f);
        float3 n = float3(0, 0, 1);
        float3 wo = normalize(float3(rand_f(seed) - 0.5f, rand_f(seed) - 0.5f, 0.3f + rand_f(seed)));
        float3 wi = normalize(float3(-wo.x, -wo.y, -wo.z) * 0.7f + 0.3f * (float3(rand_f(seed), rand_f(seed), rand_f(seed)) - 0.5f));
        if (tid % 3u == 0u) wi.z = -wi.z;   // some reflections too
        float4 q = float4(0.2f + rand_f(seed), 0.2f + rand_f(seed), 0.2f + rand_f(seed), 0.2f + rand_f(seed));
        Wavelengths context = SPECTRAL_CONTEXT(u, images);
        float u0 = rand_f(seed);
        float4 withPrefix = float4(0.0f), plain = float4(0.0f), f = float4(0.0f);
        for (uint h = 0u; h < 4u; ++h) {
            Wavelengths wl = spectral_wavelengths(u0, (float(h) + 0.5f) * 0.25f, context);
            if (h == 0u) {
                Spectrum rho = spectral_albedo(glass, glass.albedo, wl);
                for (uint k = 0u; k < 4u; ++k)
                    f[k] = openpbr_get_sum_of_diffuse_specular(openpbr_eval(spectral_mis_lane(glass, n, wo, rho[k], k, wl), wi)).x
                        / abs(dot(n, wi));
            }
            float pdf;
            Spectrum R = q / q[h];
            Spectrum v = spectral_mis_eval(glass, n, wo, wi, pdf, wl, R);
            Spectrum v1 = spectral_mis_eval(glass, n, wo, wi, pdf, wl, Spectrum(1.0f));
            withPrefix += select(float4(0.0f), v / f / (R.x + R.y + R.z + R.w), f > 0.0f);
            plain += select(float4(0.0f), v1 / f * 0.25f, f > 0.0f);
        }
        for (uint k = 0u; k < 4u; ++k) out[4u * tid + k] = float4(withPrefix[k], plain[k], f[k], 0.0f);
    }
    // Sampling against evaluation: out[2 tid] = (max relative difference of weight and eval cos / pdf,
    // relative pdf difference to the hero lane's own PDF, max relative laneRatio difference, ok);
    // out[2 tid + 1] = (spectral_mis(glass), spectral_mis(dielectric), split lane mask sum, arrive factor).
    kernel void spectral_mis_sampling(constant Uniforms &u [[buffer(1)]], constant MaterialResources &images [[buffer(2)]],
                                      device float4 *out [[buffer(0)]] SPECTRAL_BUFFERS, uint tid [[thread_position_in_grid]]) {
        uint seed = 31u * tid + 5u;
        Material glass = spectral_mis_glass(0.2f);
        float3 n = float3(0, 0, 1);
        float3 incoming = -normalize(float3(rand_f(seed) - 0.5f, rand_f(seed) - 0.5f, 0.4f + rand_f(seed)));
        Wavelengths wl = spectral_wavelengths(rand_f(seed), rand_f(seed), SPECTRAL_CONTEXT(u, images));
        Spectrum R = Spectrum(0.5f + rand_f(seed), 0.5f + rand_f(seed), 0.5f + rand_f(seed), 0.5f + rand_f(seed));
        R[spectral_hero(wl)] = 1.0f;
        Spectrum before = R;
        float3 d; Spectrum w; float pdf;
        bool ok = spectral_mis_sample(glass, n, incoming, true, seed, d, w, pdf, wl, R);
        float4 result = float4(0.0f, 0.0f, 0.0f, ok ? 1.0f : 0.0f);
        if (ok) {
            float evalPdf;
            Spectrum v = spectral_mis_eval(glass, n, -incoming, d, evalPdf, wl, before) * abs(dot(n, d)) / pdf;
            result.x = spectrum_max(abs(v - w)) / max(spectrum_max(w), 1e-6f);
            Spectrum rho = spectral_albedo(glass, glass.albedo, wl);
            uint hero = spectral_hero(wl);
            float own = openpbr_pdf(spectral_mis_lane(glass, n, -incoming, rho[hero], hero, wl), d);
            result.y = abs(own - pdf) / pdf;
            Spectrum p;
            for (uint k = 0u; k < 4u; ++k) p[k] = openpbr_pdf(spectral_mis_lane(glass, n, -incoming, rho[k], k, wl), d);
            result.z = spectrum_max(abs(R - before * p / pdf) / max(before * p / pdf, 1e-6f));
        }
        out[2u * tid] = result;
        Material dielectric = { DIELECTRIC, float3(1), float3(0), 0.0f, 1.52f };
        dielectric.slot = 5u;
        Wavelengths fresh = spectral_wavelengths(0.3f, 0.6f, SPECTRAL_CONTEXT(u, images));
        Spectrum t = Spectrum(1.0f);
        bool split = spectral_split(dielectric, t, fresh, tid % 4u);
        Spectrum a = Spectrum(1.0f);
        Wavelengths other = spectral_wavelengths(0.3f, 0.6f, SPECTRAL_CONTEXT(u, images));
        spectral_arrive_lanes(dielectric, a, other, Spectrum(1.0f, 0.5f, 2.0f, 0.25f));
        out[2u * tid + 1u] = float4(spectral_mis(glass, fresh) ? 1.0f : 0.0f,
            spectral_mis(dielectric, spectral_wavelengths(0.3f, 0.6f, SPECTRAL_CONTEXT(u, images))) ? 1.0f : 0.0f,
            split && fresh.heroOnly && spectral_hero(fresh) == tid % 4u && t[tid % 4u] == 1.0f ? t.x + t.y + t.z + t.w : -1.0f,
            other.heroOnly ? a.x + a.y + a.z + a.w : -1.0f);
    }
    // Thin film on the ideal mirror (slot 4): (film-free value, film value, thin-film weight 0 value) of lane 0..3 at cos 0.8.
    kernel void spectral_mirror_film(constant Uniforms &u [[buffer(1)]], constant MaterialResources &images [[buffer(2)]],
                                     device float4 *out [[buffer(0)]] SPECTRAL_BUFFERS, uint tid [[thread_position_in_grid]]) {
        Material mirror = { GLOSSY, float3(0.95f), float3(0), 0.001f, 1.0f };
        mirror.slot = tid == 0u ? 4u : 6u;   // slot 6 has no film
        mirror.geometricNormal = float3(0, 0, 1);
        Wavelengths wl = spectral_wavelengths(0.37f, 0.5f, SPECTRAL_CONTEXT(u, images));
        uint seed = 3u;
        float3 d; Spectrum w; float pdf;
        bool ok = sample_bsdf(mirror, float3(0, 0, 1), normalize(float3(0.6f, 0.0f, -0.8f)), true, seed, d, w, pdf, wl);
        out[tid] = ok ? w : Spectrum(-1.0f);
    }
    """
  let library = try rendererShaderLibrary(kernels, spectral: true)
  func run(_ name: String, width: Int, _ buffer: MTLBuffer) throws {
    var unit = makeUniforms(scene: 3, mode: 1, width: 1, height: 1)
    let state = try gpu.makeComputePipelineState(function: library.makeFunction(name: name)!)
    let command = r.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(state)
    encoder.setBytes(&unit, length: MemoryLayout<Uniforms>.stride, index: 1)
    r.materials.bind(encoder)
    bindRendererSpectral(encoder)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: width, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) completes: \(String(describing: command.error))")
  }
  // The spectral state (dispersion overrides, mode word) reaches the buffers with a rendered frame.
  r.materials.spectralOverrides = [5: SIMD4(1, 0, 0.5, 1.4), 4: SIMD4(0, 1, 0.45, 1.33)]
  r.dispersionSampling = .spectralMISSplit
  _ = render(makeUniforms(scene: 3, mode: 1, width: 16, height: 12), samples: 1)
  let pairs = 512
  let weights = gpu.makeBuffer(length: pairs * 4 * 16, options: .storageModeShared)!
  try run("spectral_mis_weights", width: pairs, weights)
  var worstPrefix = 0.0, worstPlain = 0.0, counted = 0
  for i in 0..<(pairs * 4) {
    let v = weights.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
    guard v.z > 1e-4 && v.z.isFinite else { continue }
    counted += 1
    worstPrefix = max(worstPrefix, Double(abs(v.x - 1))); worstPlain = max(worstPlain, Double(abs(v.y - 1)))
  }
  print(String(format: "Spectral MIS balance weights over the four hero techniques (%d lane values): |sum - 1| max %.2e with a random prefix, %.2e without",
               counted, worstPrefix, worstPlain))
  require(counted > 1000 && worstPrefix < 2e-3 && worstPlain < 2e-3, "spectral MIS balance weights sum to one over the wavelengths")
  let sampling = gpu.makeBuffer(length: 256 * 2 * 16, options: .storageModeShared)!
  try run("spectral_mis_sampling", width: 256, sampling)
  var sampled = 0, worstWeight: Float = 0, worstPdf: Float = 0, worstRatio: Float = 0
  for i in 0..<256 {
    let a = sampling.contents().load(fromByteOffset: 2 * i * 16, as: SIMD4<Float>.self)
    let b = sampling.contents().load(fromByteOffset: (2 * i + 1) * 16, as: SIMD4<Float>.self)
    if a.w > 0 { sampled += 1; worstWeight = max(worstWeight, a.x); worstPdf = max(worstPdf, a.y); worstRatio = max(worstRatio, a.z) }
    require(b.x == 1 && b.y == 0, "rough dispersive glass uses spectral MIS, the delta dielectric does not")
    require(b.z == 1, "a delta dispersive vertex splits into one lane of weight one")
    require(abs(b.w - 3.75) < 1e-5, "terminating after spectral MIS keeps the hero lane times sum R")
  }
  print(String(format: "Spectral MIS sampling (%d of 256 sampled): weight vs evaluation %.2e, hero PDF %.2e, lane ratios %.2e (relative)",
               sampled, worstWeight, worstPdf, worstRatio))
  require(sampled > 200 && worstWeight < 1e-3 && worstPdf < 1e-4 && worstRatio < 1e-3,
    "spectral MIS sampling agrees with its evaluation, the hero lane's PDF and the lane ratios")
  let film = gpu.makeBuffer(length: 2 * 16, options: .storageModeShared)!
  try run("spectral_mirror_film", width: 2, film)
  let filmed = film.contents().load(fromByteOffset: 0, as: SIMD4<Float>.self), bare = film.contents().load(fromByteOffset: 16, as: SIMD4<Float>.self)
  print("Ideal mirror reflectance at lanes 0-3: thin film 450 nm \(filmed), none \(bare)")
  require(filmed.min() >= 0 && filmed.max() <= 1 && bare.min() > 0.9, "mirror reflectances are bounded")
  require((filmed - bare).max() > 0.05 || (bare - filmed).max() > 0.05, "a thin film changes the ideal mirror's reflectance per wavelength")
  print("PASS: fix-spectral-mis balance weights, sampling, delta-vertex lanes and mirror thin film")

  // --- Renders: unbiasedness and noise (PCG sampler: independent sequences) -----------------------
  let w = 64, h = 48
  let all = Array(0..<(w * h))
  func mse(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>], _ pixels: [Int]) -> Double {
    pixels.reduce(0.0) { s, i in let d = a[i] - b[i]; return s + Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3 } / Double(pixels.count)
  }
  // Per-channel mean difference and tile-clustered standard error.
  func difference(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> (mean: SIMD3<Double>, se: SIMD3<Double>, reference: SIMD3<Double>) {
    var tiles = [Int: (SIMD3<Double>, Double)]()
    var ref = SIMD3<Double>(0, 0, 0)
    for i in all {
      let d = SIMD3(Double(a[i].x - b[i].x), Double(a[i].y - b[i].y), Double(a[i].z - b[i].z))
      ref += SIMD3(Double(b[i].x), Double(b[i].y), Double(b[i].z))
      let key = (i / w / 4) * 1000 + (i % w) / 4
      let t = tiles[key] ?? (SIMD3(0, 0, 0), 0)
      tiles[key] = (t.0 + d, t.1 + 1)
    }
    let n = Double(all.count), k = Double(tiles.count)
    let m = tiles.values.reduce(SIMD3<Double>(0, 0, 0)) { $0 + $1.0 } / n
    var v = SIMD3<Double>(0, 0, 0)
    for t in tiles.values { let e = t.0 - m * t.1; v += e * e }
    v = v * (k / (k - 1)) / (n * n)
    return (m, SIMD3(v.x.squareRoot(), v.y.squareRoot(), v.z.squareRoot()), ref / n)
  }
  r.sampler = .pcg
  for (label, rough, dispersion) in [("smooth glass, Abbe 20", Float(0), Float(1)), ("rough glass 0.2, Abbe 20", 0.2, 1),
                                     ("rough glass 0.2, Abbe 40", 0.2, 0.5)] {
    r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
    if rough > 0 { r.materials.settings[5] = roughGlass(rough) }
    r.materials.spectralOverrides = [5: SIMD4(dispersion, 0, 0.5, 1.4)]
    let view = makeUniforms(scene: 3, mode: 1, width: w, height: h)
    r.dispersionSampling = .spectralMISSplit
    let reference = render(view, samples: 2048)
    let glass = lastNormals.indices.filter { Int(lastNormals[$0].w) == 2 || Int(lastNormals[$0].w) == 4 }
    var errors = [DispersionSampling: Double]()
    for mode in [DispersionSampling.hero, .spectralMIS, .split, .spectralMISSplit] {
      r.dispersionSampling = mode
      let long = render(view, samples: 512)
      let d = difference(long, reference)
      print(String(format: "%@, %@: mean - reference %+.3f%% ± %.3f, %+.3f%% ± %.3f, %+.3f%% ± %.3f", label, String(describing: mode),
                   d.mean.x / d.reference.x * 100, d.se.x / d.reference.x * 100, d.mean.y / d.reference.y * 100,
                   d.se.y / d.reference.y * 100, d.mean.z / d.reference.z * 100, d.se.z / d.reference.z * 100))
      for c in 0..<3 { require(abs(d.mean[c]) <= 4 * d.se[c] + 2e-3 * d.reference[c], "\(label), \(mode): mean agrees with the reference, channel \(c)") }
      let short = render(view, samples: 32)
      errors[mode] = mse(short, reference, glass)
    }
    print(String(format: "%@: glass-pixel MSE at 32 samples, relative to hero: spectral MIS %.3f, split %.3f, both %.3f (%d pixels)", label,
                 errors[.spectralMIS]! / errors[.hero]!, errors[.split]! / errors[.hero]!, errors[.spectralMISSplit]! / errors[.hero]!, glass.count))
    require(glass.count > 100, "\(label): the glass sphere covers pixels")
    if rough > 0 {
      require(errors[.spectralMIS]! < 0.85 * errors[.hero]!, "\(label): spectral MIS lowers the glass error")
      require(abs(errors[.split]! / errors[.hero]! - 1) < 1e-9, "\(label): splitting leaves rough glass unchanged")
    } else {
      require(errors[.split]! < 0.8 * errors[.hero]!, "\(label): lane splitting lowers the glass error")
      require(abs(errors[.spectralMIS]! / errors[.hero]! - 1) < 1e-9, "\(label): spectral MIS leaves the delta dielectric unchanged")
    }
  }
  // Without dispersion every mode renders the same image (the earlier code path).
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  r.materials.settings[5] = roughGlass(0.2)
  r.materials.spectralOverrides = [:]
  r.sampler = saved.4
  for scene in [UInt32(3), 1] {
    var images = [[SIMD4<Float>]]()
    for mode in [DispersionSampling.hero, .spectralMIS, .split, .spectralMISSplit] {
      r.dispersionSampling = mode
      images.append(render(makeUniforms(scene: scene, mode: 0, width: 48, height: 32), samples: 4))
    }
    require(images.dropFirst().allSatisfy { $0 == images[0] }, "scene \(scene) without dispersion: every dispersion mode renders identically")
  }
  print("PASS: fix-spectral-mis modes agree with the reference, lower the dispersion error and leave other scenes unchanged")

  // --- ReSTIR PT replays dispersive paths (its paths keep the hero termination) -------------------
  let identity = """
    kernel void spectral_mis_pt_identity(texture2d<float, access::read> positions [[texture(0)]],
        constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],
        constant MaterialResources &images [[buffer(2)]], const device PrimarySurface *surfaces [[buffer(3)]],
        const device PTReservoir *reservoirs [[buffer(5)]], device float4 *out [[buffer(7)]]
        SPECTRAL_BUFFERS, uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.width || gid.y >= u.height) return;
        uint i = gid.y * u.width + gid.x;
        out[i] = float4(-1);
        PTReservoir r = reservoirs[i];
        float4 p = positions.read(gid);
        if (pt_length(r) == 0u || !(p.w > 0.0f) || !(pt_luminance(r.F) > 0.0f)) return;
        HitRecord y = load_primary_surface(surfaces[i], p);
        float3 view = float3(surfaces[i].view);
        PTShift s = pt_shift(r, y, view, pt_footprint_threshold(p.w, y.geometricNormal, view), pt_primary_cone(u), u, settings,
                             images, SPECTRAL_CONTEXT(u, images));
        float J = pt_rc_index(r) > 0u ? s.jacobian / r.rcJacobian : 1.0f;
        out[i] = float4(length(s.FJ - float3(r.F)), length(float3(r.F)), J, (r.flags & PT_RC_DISPERSIVE) != 0u ? 1.0f : 0.0f);
    }
    """
  let ptLibrary = try rendererShaderLibrary(identity, spectral: true)
  let ptState = try gpu.makeComputePipelineState(function: ptLibrary.makeFunction(name: "spectral_mis_pt_identity")!)
  r.dispersionSampling = .automatic
  for (label, rough) in [("smooth", Float(0)), ("rough 0.2", 0.2)] {
    r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
    if rough > 0 { r.materials.settings[5] = roughGlass(rough) }
    r.materials.spectralOverrides = [5: SIMD4(1, 0, 0.5, 1.4)]
    for reuse in [IndirectReuse.restirPT, .restirPTUnified] {
      r.indirectReuse = reuse
      _ = render(makeUniforms(scene: 3, mode: 0, width: 96, height: 64), samples: 1)
      var u = lastRenderUniforms!
      let out = gpu.makeBuffer(length: 96 * 64 * 16, options: .storageModeShared)!
      let command = r.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
      encoder.setComputePipelineState(ptState)
      encoder.setTexture(r.historyPosDepth!, index: 0)
      encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
      r.materials.bind(encoder)
      encoder.setBuffer(r.historyPrimarySurfaces!, offset: 0, index: 3)
      encoder.setBuffer(r.ptReservoirs!, offset: 0, index: 5)
      encoder.setBuffer(out, offset: 0, index: 7)
      bindRendererSpectral(encoder)
      encoder.dispatchThreads(MTLSize(width: 96, height: 64, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
      encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
      var total = 0, match = 0, dispersive = 0
      for i in 0..<(96 * 64) {
        let v = out.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
        if v.x < 0 && v.y < 0 { continue }
        total += 1
        if v.w > 0 { dispersive += 1 }
        if v.x <= 1e-3 * v.y && abs(v.z - 1) <= 1e-3 { match += 1 }
      }
      print("Dispersive \(label) glass, \(reuse): \(match) of \(total) paths shifted into their pixel keep F (\(dispersive) with a dispersive suffix)")
      require(total > 500 && Double(match) >= 0.985 * Double(total), "\(label) \(reuse): dispersive paths replay exactly")
    }
    // ReSTIR PT against MIS (same transport) on the dispersive scene.
    r.indirectReuse = .restirPT
    r.sampler = .pcg
    let mis = render(makeUniforms(scene: 3, mode: 1, width: w, height: h), samples: 1024)
    let pt = render(makeUniforms(scene: 3, mode: 0, width: w, height: h), samples: 1024)
    r.sampler = saved.4
    let d = difference(pt, mis)
    print(String(format: "Dispersive %@ glass, ReSTIR PT - MIS: %+.2f%% ± %.2f, %+.2f%% ± %.2f, %+.2f%% ± %.2f", label,
                 d.mean.x / d.reference.x * 100, d.se.x / d.reference.x * 100, d.mean.y / d.reference.y * 100, d.se.y / d.reference.y * 100,
                 d.mean.z / d.reference.z * 100, d.se.z / d.reference.z * 100))
    for c in 0..<3 { require(abs(d.mean[c]) <= 4 * d.se[c] + 0.012 * d.reference[c], "\(label): ReSTIR PT agrees with MIS on dispersive glass, channel \(c)") }
  }
  r.indirectReuse = saved.5

  // --- Thin film on the ideal mirror in a render: the mirror's reflection changes colour ----------
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  r.materials.spectralOverrides = [:]
  let mirrorView = makeUniforms(scene: 3, mode: 1, width: w, height: h)
  let plainMirror = render(mirrorView, samples: 64)
  let mirrorPixels = lastNormals.indices.filter { Int(lastNormals[$0].w) == 1 && lastPositions[$0].x > 0.1 }
  r.materials.spectralOverrides = [4: SIMD4(0, 1, 0.45, 1.33)]
  let filmMirror = render(mirrorView, samples: 64)
  func chroma(_ image: [SIMD4<Float>]) -> SIMD3<Double> {
    let s = mirrorPixels.reduce(SIMD3<Double>(0, 0, 0)) { $0 + SIMD3(Double(image[$1].x), Double(image[$1].y), Double(image[$1].z)) }
    return s / max(s.x + s.y + s.z, 1e-9)
  }
  let shift = chroma(filmMirror) - chroma(plainMirror)
  print("Mirror chromaticity with a 450 nm film minus without: \(shift) (\(mirrorPixels.count) pixels)")
  require(mirrorPixels.count > 50 && max(abs(shift.x), abs(shift.y), abs(shift.z)) > 0.01, "a thin film colours the ideal mirror")
  print("PASS: fix-spectral-mis ReSTIR PT replay of dispersive paths and the mirror thin film")
}
try fixSpectralMISChecks()
