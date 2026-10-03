// Spectral light transport (REFERENCES.md PETERSBLOG2025, PETERS2019, FOURIERSRGB2019, HERO2014, CIEDATA;
// docs/SPECTRAL_DESIGN.md, Sec. 9): the transport seam, Automatic (spectral) and the RGB kernels; the runtime colour
// conversion's round trip over every 8-bit code (the coarse grid replacing FourierSRGB256); the
// four-wavelength estimator under a monochromatic spectrum; grey-world parity with RGB; colour round
// trips in renders; illuminant presets; Cauchy dispersion and the hero wavelength's unbiasedness;
// ReSTIR consistency and path shifts that reproduce their wavelengths; MaterialX inputs; project
// persistence and the Render / Lighting controls; MetalFX input; frame times.
@MainActor func fixSpectralChecks() throws {
  let r = testRenderer
  let suite = ProcessInfo.processInfo.environment["VIBE_SUITE_MODE"] ?? "full"
  let saved = (r.lightTransport, r.materials.settings, r.materials.spectralOverrides, r.indirectReuse, r.spatialNeighbors,
               r.controlVariates, r.sampler, r.options)
  defer {
    (r.lightTransport, r.materials.settings, r.materials.spectralOverrides, r.indirectReuse, r.spatialNeighbors,
     r.controlVariates, r.sampler, r.options) = saved
    try? r.materials.restore(SceneState())
  }
  let folder = testOutputDirectory.appendingPathComponent("fix-spectral", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

  // --- Seam, Automatic, resources -------------------------------------------------------------
  let seam: LightTransport = ["rgb": .rgb, "spectral": .spectral][ProcessInfo.processInfo.environment["VIBE_LIGHT_TRANSPORT"] ?? ""]
    ?? .automatic
  require(PathTracerRenderer.defaultLightTransport == seam, "the default light transport follows the VIBE_LIGHT_TRANSPORT seam")
  require(LightTransport.automatic.resolved() == .spectral && LightTransport.rgb.resolved() == .rgb
    && LightTransport.spectral.resolved() == .spectral, "Automatic is spectral; explicit choices are kept")
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  r.materials.spectralOverrides = [:]
  r.lightTransport = .automatic
  r.sceneIndex = 1
  var o = StudioOptions()
  r.options = o
  require(r.activeLightTransport == .spectral && r.spectralIlluminantWeights() == [0, 1, 0, 0, 0, 0],
    "an RGB Cornell box traces spectrally under Automatic, sampling D65")
  o.lightSpectrum = Illuminant.hp1.rawValue; r.options = o
  require(r.activeLightTransport == .spectral && r.spectralIlluminantWeights() == [0, 0, 0, 0, 1, 0], "a sodium light is sampled alone")
  r.sceneIndex = 0
  o.lightSpectrum = Illuminant.fl11.rawValue; r.options = o
  require(r.spectralIlluminantWeights() == [0, 1, 0, 0, 0, 0], "the Pavilion has no area light, so the light spectrum does not matter there")
  o.sunSpectrum = Illuminant.a.rawValue; r.options = o
  require(r.spectralIlluminantWeights() == [0, 1, 1, 0, 0, 0], "an incandescent sun samples D65 (sky) and A (sun) equally")
  r.options = StudioOptions()
  require(Illuminant.resolved(nil) == .d65 && Illuminant.resolved(9) == .d65 && Illuminant.resolved(4) == .hp1,
    "a missing or unknown preset is the RGB colour (D65)")
  require(PathTracerRenderer.spectralGridNodes.count == 86 && PathTracerRenderer.spectralGridNodes[0] == 0
    && PathTracerRenderer.spectralGridNodes[85] == 1, "the grid nodes are the sRGB codes 0, 3, ..., 255 in linear light")
  print("PASS: fix-spectral seam, Automatic resolution and illuminant weights")

  // --- Project persistence --------------------------------------------------------------------
  var project = ProjectDocument()
  project.restirModes = ReSTIRModes(indirectReuse: .automatic, spatialNeighbors: .automatic, temporalReuse: .automatic,
                                    lightTransport: .spectral)
  project.options.lightSpectrum = Illuminant.fl11.rawValue
  project.options.sunSpectrum = Illuminant.ledB3.rawValue
  let encoded = try project.encodeForSaving()
  let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
  require(object["lightTransport"] as? Int == 1 && (object["options"] as? [String: Any])?["lightSpectrum"] as? Int == 3
    && (object["options"] as? [String: Any])?["sunSpectrum"] as? Int == 5, "projects store the light transport and the spectra")
  let reopened = try ProjectDocument.decodeProject(encoded, near: nil)
  try reopened.validate()
  require(reopened.restirModes.lightTransport == .spectral && reopened.options.lightSpectrum == 3
    && reopened.options.sunSpectrum == 5, "a saved project reopens with its light transport and spectra")
  var legacy = object
  legacy["lightTransport"] = nil
  var legacyOptions = legacy["options"] as! [String: Any]
  legacyOptions["lightSpectrum"] = nil; legacyOptions["sunSpectrum"] = nil
  legacy["options"] = legacyOptions
  let old = try ProjectDocument.decodeProject(JSONSerialization.data(withJSONObject: legacy), near: nil)
  require(old.lightTransport == nil && old.restirModes.lightTransport == ReSTIRModes.defaults.lightTransport
    && old.options.lightSpectrum == nil && old.options.sunSpectrum == nil,
    "projects written before the fields open with the default transport and RGB-coloured lights")
  require(seam != .automatic || old.restirModes.lightTransport.resolved() == .spectral,
    "projects written before the field (or with Automatic) now render spectrally")
  for (key, value, inOptions) in [("lightTransport", 3, false), ("lightSpectrum", 6, true), ("sunSpectrum", 99, true)] {
    var bad = object
    if inOptions { var opts = bad["options"] as! [String: Any]; opts[key] = value; bad["options"] = opts } else { bad[key] = value }
    var rejected = false
    do { try ProjectDocument.decodeProject(JSONSerialization.data(withJSONObject: bad), near: nil).validate() } catch { rejected = true }
    require(rejected, "an out-of-range \(key) is rejected")
  }
  var a = StudioOptions(), b = StudioOptions()
  b.lightSpectrum = Illuminant.d65.rawValue
  require(a.sameRadiance(as: b), "an explicit D65 preset renders like the RGB colour")
  a.sunSpectrum = Illuminant.hp1.rawValue
  require(!a.sameRadiance(as: b), "a different sun spectrum restarts accumulation")
  print("PASS: fix-spectral project round trips, legacy files and validation")

  // --- MaterialX dispersion and thin film -----------------------------------------------------
  let mx = try MaterialXImporter.read(Data("""
    <materialx version="1.39">
    <open_pbr_surface name="Prism" type="surfaceshader">
      <input name="transmission_weight" type="float" value="1"/>
      <input name="transmission_dispersion_scale" type="float" value="1"/>
      <input name="transmission_dispersion_abbe_number" type="float" value="25"/>
      <input name="thin_film_weight" type="float" value="0.5"/>
      <input name="thin_film_thickness" type="float" value="0.4"/>
      <input name="thin_film_ior" type="float" value="1.33"/>
    </open_pbr_surface>
    </materialx>
    """.utf8), baseURL: folder, source: "Prism.mtlx")
  require(mx.materials.count == 1, "a MaterialX surface with dispersion and thin film compiles: \(mx.report)")
  let spectralInputs = mx.materials[0].spectral ?? .zero
  require(abs(spectralInputs.x - 0.8) < 1e-6 && spectralInputs.y == 0.5 && abs(spectralInputs.z - 0.4) < 1e-6
    && abs(spectralInputs.w - 1.33) < 1e-6, "dispersion 20 x scale / Abbe and the thin-film constants reach the spectral material: \(spectralInputs)")
  let plainMX = try MaterialXImporter.read(Data("""
    <materialx version="1.39"><open_pbr_surface name="Plain" type="surfaceshader"/></materialx>
    """.utf8), baseURL: folder, source: "Plain.mtlx")
  require(plainMX.materials.first?.spectral == nil, "default inputs leave no spectral material")
  print("PASS: fix-spectral MaterialX dispersion and thin-film inputs")

  // The Render and Lighting controls run with the studio controller (full and studio suites).
  try fixSpectralControllerChecks(folder: folder)
  if suite != "full" { return }

  // --- RGB kernels unchanged ------------------------------------------------------------------
  r.lightTransport = .rgb
  let cornell = makeUniforms(scene: 1, mode: 0, width: 48, height: 32)
  let rgbImage = render(cornell, samples: 4)
  require(!r.spectralFrame && r.sceneKernels.shading === r.proceduralKernels.shading,
    "RGB frames use the RGB pipelines")
  r.lightTransport = .spectral
  let spectralImage = render(cornell, samples: 4)
  require(r.spectralFrame && r.spectralShaders.kernels != nil && r.sceneKernels.shading !== r.proceduralKernels.shading,
    "Spectral frames use the spectral pipelines")
  r.lightTransport = .automatic
  let automaticImage = render(cornell, samples: 4)
  require(r.spectralFrame && zip(spectralImage, automaticImage).allSatisfy { $0 == $1 } && !zip(rgbImage, automaticImage).allSatisfy { $0 == $1 },
    "Automatic renders spectrally, bit for bit like Spectral")
  require(r.spectralShaders.grid?.length == Int(PathTracerRenderer.spectralGridBytes) && r.spectralShaders.refined
    && r.spectralShaders.refinedCells > 0 && r.spectralShaders.refinedCells < PathTracerRenderer.spectralRefinedCapacity,
    "the moment grid (86^3 float4 and refined blocks) is loaded and refined (\(r.spectralShaders.refinedCells) cells)")
  print("Spectral grid: \(r.spectralShaders.refinedCells) of 614,125 cells refined (0.35-step threshold)")
  print("PASS: fix-spectral RGB keeps the RGB kernels; Spectral and Automatic share the spectral ones")

  // --- Kernel checks in a spectral library ----------------------------------------------------
  let tables = try loadSpectralTablesSource()
  func table(_ name: String) -> [Float] {
    guard let start = tables.range(of: "constant float \(name)["), let open = tables.range(of: "{", range: start.upperBound..<tables.endIndex),
          let end = tables.range(of: "\n};", range: open.upperBound..<tables.endIndex) else { fatalError("table \(name)") }
    let body = tables[open.upperBound..<end.lowerBound]
    return body.split(whereSeparator: { ",{} \n".contains($0) }).compactMap { Float($0.replacingOccurrences(of: "f", with: "")) }
  }
  let cmf = [table("vibe_cmf_x"), table("vibe_cmf_y"), table("vibe_cmf_z")]
  let spd = table("vibe_illuminant_spd")
  require(cmf.allSatisfy { $0.count == 471 } && spd.count == 6 * 471, "the include's CMF and illuminant tables parse")
  // XYZ -> linear sRGB from the include, as written (columns).
  let matrixText = tables.components(separatedBy: "VIBE_XYZ_TO_LINEAR_SRGB = float3x3(")[1].components(separatedBy: ");")[0]
  let m = matrixText.replacingOccurrences(of: "float3", with: " ").split(whereSeparator: { "(), \n".contains($0) })
    .compactMap { Float($0.replacingOccurrences(of: "f", with: "")) }
  require(m.count == 9, "the include's XYZ to sRGB matrix parses")
  func toRGB(_ xyz: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(Double(m[0]) * xyz.x + Double(m[3]) * xyz.y + Double(m[6]) * xyz.z,
          Double(m[1]) * xyz.x + Double(m[4]) * xyz.y + Double(m[7]) * xyz.z,
          Double(m[2]) * xyz.x + Double(m[5]) * xyz.y + Double(m[8]) * xyz.z)
  }
  // Exact linear sRGB of each preset (luminance one): M sum_lambda S(lambda) xyz(lambda).
  let presetRGB = (0..<6).map { k -> SIMD3<Double> in
    var xyz = SIMD3<Double>(0, 0, 0)
    for i in 0..<471 { xyz += Double(spd[k * 471 + i]) * SIMD3(Double(cmf[0][i]), Double(cmf[1][i]), Double(cmf[2][i])) }
    return toRGB(xyz)
  }
  require(simd_length(presetRGB[1] - SIMD3(1, 1, 1)) < 1e-4, "D65 is the sRGB white: \(presetRGB[1])")

  let kernels = """
    // The runtime conversion of every 8-bit code: linear sRGB -> grid moments -> bounded MESE ->
    // reflectance at 1 nm -> XYZ under D65 -> sRGB; the largest channel error in 8-bit steps.
    kernel void spectral_round_trip(constant Uniforms &u [[buffer(1)]], constant MaterialResources &images [[buffer(2)]],
                                    device float *error [[buffer(0)]] SPECTRAL_BUFFERS, uint tid [[thread_position_in_grid]]) {
        if (tid >= 16777216u) return;
        float3 code = float3(float(tid >> 16), float((tid >> 8) & 255u), float(tid & 255u));
        float3 v = code / 255.0f;
        float3 lin = select(pow((v + 0.055f) / 1.055f, float3(2.4f)), v / 12.92f, v <= 0.04045f);
        Wavelengths wl = SPECTRAL_CONTEXT(u, images);
        float4 L = spectral_lagrange(lin, wl);
        float3 xyz = float3(0.0f);
        for (uint i = 0u; i < VIBE_SPECTRAL_SAMPLES; ++i) {
            float rho = L.w == 2.0f ? L.x : vibe_fourier_reflectance(L.xyz, vibe_fourier_phase(VIBE_LAMBDA_MIN + float(i)));
            xyz += rho * vibe_illuminant_spd[VIBE_ILLUMINANT_D65][i] * float3(vibe_cmf_x[i], vibe_cmf_y[i], vibe_cmf_z[i]);
        }
        float3 c = saturate(VIBE_XYZ_TO_LINEAR_SRGB * xyz);
        float3 back = select(1.055f * pow(c, float3(1.0f / 2.4f)) - 0.055f, 12.92f * c, c <= 0.0031308f) * 255.0f;
        float3 d = abs(back - code);
        error[tid] = max(d.x, max(d.y, d.z));
    }
    // The four-wavelength estimator of a 1 nm box spectrum at 500 nm (value one): stratified over u.
    kernel void spectral_monochromatic(constant Uniforms &u [[buffer(1)]], constant MaterialResources &images [[buffer(2)]],
                                       device float4 *out [[buffer(0)]] SPECTRAL_BUFFERS, uint tid [[thread_position_in_grid]]) {
        float3 sum = float3(0.0f);
        Wavelengths context = SPECTRAL_CONTEXT(u, images);
        for (uint j = 0u; j < 256u; ++j) {
            Wavelengths wl = spectral_wavelengths((float(tid * 256u + j) + 0.5f) / 1048576.0f, 0.5f, context);
            sum += spectrum_rgb(select(Spectrum(0.0f), Spectrum(1.0f), abs(spectral_lambdas(wl) - 500.0f) <= 0.5f), wl);
        }
        out[tid] = float4(sum, 0.0f);
    }
    // The Cauchy fit at the F, d and C lines, and the refraction of a hero path's wavelength (from its
    // number u) at a dispersive dielectric (slot 5): sin(theta_t), n(lambda_hero), n(line), cos(theta_t).
    kernel void spectral_dispersion(constant Uniforms &u [[buffer(1)]], constant MaterialResources &images [[buffer(2)]],
                                    device float4 *out [[buffer(0)]] SPECTRAL_BUFFERS, uint tid [[thread_position_in_grid]]) {
        if (tid >= 3u) return;
        float lines[3] = { 486.1f, 587.6f, 656.3f };
        Wavelengths wl = spectral_wavelengths(0.15f + 0.3f * float(tid), 0.1f + 0.3f * float(tid), SPECTRAL_CONTEXT(u, images));
        wl.heroOnly = true;
        Material glass = { DIELECTRIC, float3(1), float3(0), 0.0f, 1.5f };
        glass.slot = 5u; glass.geometricNormal = float3(0, 0, 1);
        float3 incoming = normalize(float3(sin(0.6f), 0.0f, -cos(0.6f)));
        uint seed = 7u;
        float3 d = float3(0); Spectrum w; float pdf;
        for (int i = 0; i < 256; ++i) if (sample_bsdf(glass, float3(0, 0, 1), incoming, true, seed, d, w, pdf, wl) && d.z < 0.0f) break;
        float n = openpbr_dispersion_adjusted_ior(1.5f, 1.0f, spectral_lambda(wl, spectral_hero(wl)));
        out[tid] = float4(length(d.xy), n, openpbr_dispersion_adjusted_ior(1.5f, 1.0f, lines[tid]), d.z);
    }
    // The emission basis (spectral_emission): the 1 nm colour of an upsampled RGB emitter under D65,
    // and the smallest value of its spectrum.
    kernel void spectral_emission_colour(constant float4 *colours [[buffer(0)]], device float4 *out [[buffer(3)]]
                                         SPECTRAL_BUFFERS, uint tid [[thread_position_in_grid]]) {
        SpectralEmissionWeights w = spectral_emission_weights(colours[tid].xyz);
        const device float4 *basis = (const device float4 *)spectralSampling + SPECTRAL_BASIS;
        float3 xyz = float3(0.0f);
        float lowest = INFINITY;
        for (uint i = 0u; i < VIBE_SPECTRAL_SAMPLES; ++i) {
            float v = spectral_emission_basis(w, basis, i);
            lowest = min(lowest, v);
            xyz += v * vibe_illuminant_spd[VIBE_ILLUMINANT_D65][i] * float3(vibe_cmf_x[i], vibe_cmf_y[i], vibe_cmf_z[i]);
        }
        out[tid] = float4(VIBE_XYZ_TO_LINEAR_SRGB * xyz, lowest);
    }
    // One interreflection between two Cornell red walls under D65: sum rho^2 S xyz at 1 nm.
    kernel void spectral_interreflection(constant Uniforms &u [[buffer(1)]], constant MaterialResources &images [[buffer(2)]],
                                         device float4 *out [[buffer(0)]] SPECTRAL_BUFFERS, uint tid [[thread_position_in_grid]]) {
        float3 colours[3] = { float3(0.65f, 0.05f, 0.05f), float3(0.12f, 0.45f, 0.15f), float3(0.95f, 0.64f, 0.54f) };
        if (tid >= 3u) return;
        Wavelengths wl = SPECTRAL_CONTEXT(u, images);
        float4 L = spectral_lagrange(colours[tid], wl);
        float3 one = float3(0.0f), two = float3(0.0f);
        for (uint i = 0u; i < VIBE_SPECTRAL_SAMPLES; ++i) {
            float rho = vibe_fourier_reflectance(L.xyz, vibe_fourier_phase(VIBE_LAMBDA_MIN + float(i)));
            float3 c = vibe_illuminant_spd[VIBE_ILLUMINANT_D65][i] * float3(vibe_cmf_x[i], vibe_cmf_y[i], vibe_cmf_z[i]);
            one += rho * c; two += rho * rho * c;
        }
        out[2u * tid] = float4(VIBE_XYZ_TO_LINEAR_SRGB * one, 0.0f);
        out[2u * tid + 1u] = float4(VIBE_XYZ_TO_LINEAR_SRGB * two, 0.0f);
    }
    // ReSTIR PT paths shifted into their own pixel: F and the shifted integrand at the path's
    // wavelengths (re-derived from its seed), and the Jacobian.
    kernel void spectral_pt_identity(texture2d<float, access::read> positions [[texture(0)]],
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
        out[i] = float4(length(s.FJ - float3(r.F)), length(float3(r.F)), J, float(pt_rc_index(r)));
    }
    """
  let spectralLibrary = try rendererShaderLibrary(kernels, spectral: true)
  func run(_ name: String, width: Int, height: Int = 1, _ bind: (MTLComputeCommandEncoder) -> Void) throws {
    let state = try gpu.makeComputePipelineState(function: spectralLibrary.makeFunction(name: name)!)
    let command = r.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(state)
    bind(encoder)
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: height > 1 ? 8 : 64, height: height > 1 ? 8 : 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) completes: \(String(describing: command.error))")
  }
  var unitUniforms = makeUniforms(scene: 1, mode: 1, width: 1, height: 1)
  func bindUnits(_ encoder: MTLComputeCommandEncoder) {
    encoder.setBytes(&unitUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    r.materials.bind(encoder)
    bindRendererSpectral(encoder)
  }

  // Colour round trip of the runtime conversion (docs/SPECTRAL_DESIGN.md, Decisions: the coarse grid at
  // render time replaces the 96 MiB FourierSRGB256 table).
  let errors = gpu.makeBuffer(length: 16_777_216 * 4, options: .storageModeShared)!
  let started = Date()
  try run("spectral_round_trip", width: 16_777_216) { encoder in bindUnits(encoder); encoder.setBuffer(errors, offset: 0, index: 0) }
  let e = errors.contents().bindMemory(to: Float.self, capacity: 16_777_216)
  var worst: Float = 0, worstCode = 0, total = 0.0, above = [0, 0, 0]
  for i in 0..<16_777_216 {
    let v = e[i]
    total += Double(v)
    if v > worst { worst = v; worstCode = i }
    if v > 0.25 { above[0] += 1 }; if v > 0.4 { above[1] += 1 }; if v > 0.5 { above[2] += 1 }
  }
  print(String(format: "Spectral runtime colour round trip, all 16,777,216 codes (float32, relaxed math, %.1f s): max %.3f 8-bit steps at (%d, %d, %d), mean %.4f; %d codes above 0.25, %d above 0.4, %d above 0.5",
               Date().timeIntervalSince(started), worst, worstCode >> 16, (worstCode >> 8) & 255, worstCode & 255, total / 16_777_216,
               above[0], above[1], above[2]))
  require(worst <= 0.5, "every 8-bit code round-trips within half an 8-bit step through the runtime conversion")

  // Monochromatic light: the estimator converges to the CMFs' colour of 500 nm, out of gamut.
  let mono = gpu.makeBuffer(length: 4096 * 16, options: .storageModeShared)!
  try run("spectral_monochromatic", width: 4096) { encoder in bindUnits(encoder); encoder.setBuffer(mono, offset: 0, index: 0) }
  var monoSum = SIMD3<Double>(0, 0, 0)
  for i in 0..<4096 { let v = mono.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self); monoSum += SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
  monoSum /= 1_048_576
  func cmfAt(_ k: Int, _ lambda: Double) -> Double {
    let x = lambda - 360, i = Int(x), f = x - Double(i)
    return Double(cmf[k][i]) * (1 - f) + Double(cmf[k][i + 1]) * f
  }
  // The renderer evaluates the CMFs per 1 nm bin: the box [499.5, 500.5] nm is the 500 nm node.
  let boxXYZ = SIMD3((0..<3).map { k in cmfAt(k, 500) })
  let monoExpected = toRGB(boxXYZ)
  print("Monochromatic 500 nm (1 nm box): estimate \(monoSum), CMF colour \(monoExpected)")
  require(simd_length(monoSum - monoExpected) <= 2e-3 * simd_length(monoExpected) && monoSum.x < 0,
    "four stratified wavelengths estimate a monochromatic spectrum's colour, negative red included")

  // Dispersion: Snell's law with the Cauchy fit of n_d = 1.5, V_d = 20 (dispersion 1) at F, d and C.
  r.materials.spectralOverrides = [5: SIMD4(1, 0, 0.5, 1.4)]
  let refraction = gpu.makeBuffer(length: 3 * 16, options: .storageModeShared)!
  try run("spectral_dispersion", width: 3) { encoder in bindUnits(encoder); encoder.setBuffer(refraction, offset: 0, index: 0) }
  let rays = (0..<3).map { refraction.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  let nF = Double(rays[0].z), nd = Double(rays[1].z), nC = Double(rays[2].z)
  print("Dispersion: n(F, d, C) = \(nF), \(nd), \(nC); V_d = \((nd - 1) / (nF - nC)); sin(theta_t) n(lambda_hero) = \(rays.map { $0.x * $0.y }), sin(theta_i) = \(sin(Float(0.6)))")
  require(abs(nd - 1.5) < 1e-5 && abs((nd - 1) / (nF - nC) - 20) < 1e-3 && nF > nd && nd > nC,
    "the Cauchy fit reproduces n_d and the Abbe number")
  require(rays.allSatisfy { abs($0.x * $0.y - sin(0.6)) < 2e-5 && $0.w < 0 } && Set(rays.map { $0.y }).count == 3,
    "each hero wavelength refracts by Snell's law with n(lambda)")
  r.materials.spectralOverrides = [:]

  // Emission basis: white is the illuminant itself, and every upsampled RGB emitter (corners, mixtures,
  // greys, unbounded values) has a nonnegative spectrum whose colour is the RGB value within half an
  // 8-bit step at its brightest channel's scale.
  var emitters: [SIMD4<Float>] = [SIMD4(1, 1, 1, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1, 1, 0),
    SIMD4(1, 0, 1, 0), SIMD4(1, 1, 0, 0), SIMD4(18, 15, 10, 0), SIMD4(24, 20, 15, 0), SIMD4(0.3, 0.5, 0.9, 0), SIMD4(2, 0.2, 0.6, 0)]
  var generator = SystemRandomNumberGenerator()
  for _ in 0..<500 { emitters.append(SIMD4(Float.random(in: 0...1, using: &generator), Float.random(in: 0...1, using: &generator),
                                           Float.random(in: 0...1, using: &generator), 0) * Float.random(in: 0.1...50, using: &generator)) }
  let emitterBuffer = gpu.makeBuffer(bytes: emitters, length: emitters.count * 16, options: .storageModeShared)!
  let emitterColours = gpu.makeBuffer(length: emitters.count * 16, options: .storageModeShared)!
  try run("spectral_emission_colour", width: emitters.count) { encoder in
    bindUnits(encoder); encoder.setBuffer(emitterBuffer, offset: 0, index: 0); encoder.setBuffer(emitterColours, offset: 0, index: 3)
  }
  var emissionWorst = 0.0, emissionLowest = Float.infinity
  func code(_ v: Double) -> Double { (v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255 }
  for (i, e) in emitters.enumerated() {
    let v = emitterColours.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
    let s = Double(max(e.x, e.y, e.z))
    for c in 0..<3 { emissionWorst = max(emissionWorst, abs(code(Double(v[c]) / s) - code(Double(e[c]) / s))) }
    emissionLowest = min(emissionLowest, v.w / Float(s))
    if i == 0 { require(abs(v.x - 1) < 1e-4 && abs(v.y - 1) < 1e-4 && abs(v.z - 1) < 1e-4 && v.w == 1, "white emission is D65 exactly: \(v)") }
  }
  print(String(format: "Emission basis: %d emitters, colour error max %.3f 8-bit steps (relative to the brightest channel), smallest spectral value %.4f",
               emitters.count, emissionWorst, emissionLowest))
  require(emissionWorst <= 0.5 && emissionLowest >= 0, "upsampled emitters keep their colour and a nonnegative spectrum")

  // Saturated interreflection: one bounce between two walls of the same colour under D65.
  let bounce = gpu.makeBuffer(length: 6 * 16, options: .storageModeShared)!
  try run("spectral_interreflection", width: 3) { encoder in bindUnits(encoder); encoder.setBuffer(bounce, offset: 0, index: 0) }
  for (k, name) in ["Cornell red", "Cornell green", "copper"].enumerated() {
    let once = bounce.contents().load(fromByteOffset: 2 * k * 16, as: SIMD4<Float>.self)
    let twice = bounce.contents().load(fromByteOffset: (2 * k + 1) * 16, as: SIMD4<Float>.self)
    let rgbTwice = SIMD3(once.x * once.x, once.y * once.y, once.z * once.z)
    print("Interreflection, \(name): spectral rho^2 = \(SIMD3(twice.x, twice.y, twice.z)), RGB rho^2 = \(rgbTwice)")
    // Squaring a spectrum saturates its colour (out of gamut for the red wall); RGB squares channels.
    require(twice.x.isFinite && twice.y.isFinite && twice.z.isFinite && abs(once.x - [0.65, 0.12, 0.95][k]) < 0.01,
      "\(name): the conversion reproduces the colour and its double bounce is finite")
  }
  print("PASS: fix-spectral conversion round trip, monochromatic estimator, Cauchy dispersion and interreflections")

  // --- Renders ------------------------------------------------------------------------------
  func channels(_ image: [SIMD4<Float>], _ pixels: [Int]) -> SIMD3<Double> {
    pixels.reduce(SIMD3<Double>(0, 0, 0)) { $0 + SIMD3(Double(image[$1].x), Double(image[$1].y), Double(image[$1].z)) } / Double(pixels.count)
  }
  // Mean and tile-clustered standard error of a - b per channel.
  func difference(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>], _ pixels: [Int], width: Int) -> (mean: SIMD3<Double>, se: SIMD3<Double>) {
    var tiles = [Int: (SIMD3<Double>, Double)]()
    for i in pixels {
      let d = SIMD3(Double(a[i].x - b[i].x), Double(a[i].y - b[i].y), Double(a[i].z - b[i].z))
      let key = (i / width / 4) * 65536 + (i % width) / 4
      let t = tiles[key] ?? (SIMD3(0, 0, 0), 0)
      tiles[key] = (t.0 + d, t.1 + 1)
    }
    let n = Double(pixels.count), k = Double(tiles.count)
    let mean = tiles.values.reduce(SIMD3<Double>(0, 0, 0)) { $0 + $1.0 } / n
    let variance = tiles.values.reduce(SIMD3<Double>(0, 0, 0)) { $0 + ($1.0 - mean * $1.1) * ($1.0 - mean * $1.1) } * (k / (k - 1)) / (n * n)
    return (mean, SIMD3(variance.x.squareRoot(), variance.y.squareRoot(), variance.z.squareRoot()))
  }
  // Cornell with a white (D65) light: the scene light (18, 15, 10) times this tint.
  var whiteLight = makeUniforms(scene: 1, mode: 1, width: 48, height: 32)
  whiteLight.light = SIMD4(1, 1.2, 1.8, 1)
  func nonEmissive() -> [Int] { lastNormals.indices.filter { lastNormals[$0].w >= 0 && Int(lastNormals[$0].w) != 3 } }

  // Grey world: grey OpenPBR room, white boxes, white light; spectral equals RGB within noise for MIS,
  // ReSTIR GI and unified ReSTIR PT (flat spectra integrate exactly; the light is D65).
  var greyRoom = SurfaceSettings(); greyRoom.enabled = 1; greyRoom.color = SIMD4(0.55, 0.55, 0.55, 1); greyRoom.surface = SIMD4(0.45, 0, 0, 0)
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  r.materials.settings[0] = greyRoom
  for (mode, reuse, label) in [(UInt32(1), IndirectReuse.restirGI, "MIS"), (0, .restirGI, "ReSTIR GI"), (0, .restirPTUnified, "unified ReSTIR PT")] {
    r.indirectReuse = reuse
    var view = whiteLight; view.samplingMode = mode
    r.lightTransport = .rgb
    let rgb = render(view, samples: 512)
    let pixels = nonEmissive()
    r.lightTransport = .spectral
    let spectral = render(view, samples: 512)
    require(r.spectralFrame, "\(label): the grey-world render is spectral")
    let d = difference(spectral, rgb, pixels, width: 48), ref = channels(rgb, pixels)
    print("Grey world, \(label): spectral - RGB = \(d.mean) ± \(d.se) of \(ref)")
    for c in 0..<3 { require(abs(d.mean[c]) <= 4 * d.se[c] + 2e-3 * ref[c], "\(label): grey-world parity, channel \(c)") }
  }
  r.indirectReuse = saved.3

  // Colour round trips in renders: direct light only (depth 1) on a Lambertian floor of albedo
  // 0.73 x code (a colour map on the room slot), under the white light. Spectral / RGB per channel
  // recovers the colour the conversion renders; it must stay within half an 8-bit step plus noise.
  func png(_ name: String, _ pixel: [UInt8]) throws -> URL {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
    for i in 0..<16 { for c in 0..<4 { bitmap.bitmapData![i * 4 + c] = pixel[c] } }
    let url = folder.appendingPathComponent(name + ".png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    return url
  }
  func encode(_ v: Double) -> Double { (v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255 }
  func decode(_ c: Double) -> Double { let v = c / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  var direct = whiteLight; direct.cameraTarget.w = 1
  var roundTripWorst = 0.0
  for code in [[18, 239, 253], [224, 172, 105], [200, 30, 30], [30, 60, 200], [250, 220, 20], [128, 128, 128]] {
    try r.materials.restore(SceneState())
    try r.materials.load(url: try png("colour-\(code[0])-\(code[1])-\(code[2])", code.map(UInt8.init) + [255]), slot: 0, channel: 0)
    r.materials.settings[0].mapMask = 1
    r.lightTransport = .rgb
    let rgb = render(direct, samples: 1024)
    let floor = lastPositions.indices.filter { lastPositions[$0].w > 0 && lastPositions[$0].y < -0.99 && Int(lastNormals[$0].w) == 0 }
    r.lightTransport = .spectral
    let spectral = render(direct, samples: 1024)
    let d = difference(spectral, rgb, floor, width: 48), ref = channels(rgb, floor)
    var steps = SIMD3<Double>(0, 0, 0), noise = SIMD3<Double>(0, 0, 0)
    for c in 0..<3 {
      let albedo = 0.73 * decode(Double(code[c]))
      steps[c] = abs(encode(albedo * (1 + d.mean[c] / ref[c])) - encode(albedo))
      noise[c] = abs(encode(albedo * (1 + 3 * d.se[c] / ref[c])) - encode(albedo))
      roundTripWorst = max(roundTripWorst, steps[c] - noise[c])
    }
    print("Render round trip \(code): spectral / RGB - 1 = \(d.mean / ref), error \(steps) 8-bit steps (3 SE: \(noise))")
    for c in 0..<3 { require(steps[c] <= 0.5 + noise[c], "colour \(code) channel \(c) renders within half an 8-bit step") }
  }
  print(String(format: "PASS: fix-spectral grey-world parity and colour round trips in renders (worst beyond noise %.2f steps)", roundTripWorst))
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  try r.materials.restore(SceneState())

  // Illuminant presets: a grey room under each preset light (direct only) is the RGB image under the
  // white light times the preset's exact linear sRGB (luminance one).
  r.materials.settings[0] = greyRoom
  r.lightTransport = .rgb
  let white = render(direct, samples: 256)
  let lit = nonEmissive()
  let whiteMean = channels(white, lit)
  r.lightTransport = .spectral
  for preset in [Illuminant.e, .a, .fl11, .hp1, .ledB3] {
    r.options.lightSpectrum = preset.rawValue
    let image = render(direct, samples: 1024)
    require(r.spectralFrame && r.spectralSamplingWeights == (0..<6).map { $0 == Int(preset.rawValue) ? 1 : 0 },
      "\(preset): the light's preset is sampled alone")
    let mean = channels(image, lit), expected = whiteMean * presetRGB[Int(preset.rawValue)]
    let scaled = white.map { SIMD4($0.x * Float(presetRGB[Int(preset.rawValue)].x), $0.y * Float(presetRGB[Int(preset.rawValue)].y),
                                   $0.z * Float(presetRGB[Int(preset.rawValue)].z), $0.w) }
    let d = difference(image, scaled, lit, width: 48)
    let luminance = { (c: SIMD3<Double>) in 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    print("Preset \(preset): mean \(mean), expected \(expected) (difference \(d.mean) ± \(d.se)); luminance \(luminance(mean)) vs \(luminance(whiteMean))")
    for c in 0..<3 { require(abs(d.mean[c]) <= 4 * d.se[c] + 3e-3 * abs(expected[c]) + 1e-4, "\(preset): channel \(c) is the preset's colour") }
  }
  r.options.lightSpectrum = nil
  print("PASS: fix-spectral illuminant presets render their exact colours")

  // Hero wavelength: a glass sphere with a vanishing dispersion terminates every path through it
  // to one wavelength (times four); the image keeps its mean (HERO2014's unbiasedness).
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  let glass = makeUniforms(scene: 3, mode: 1, width: 48, height: 32)
  let plain = render(glass, samples: 1024)
  let all = Array(0..<plain.count)
  r.materials.spectralOverrides = [5: SIMD4(1e-6, 0, 0.5, 1.4)]
  let hero = render(glass, samples: 1024)
  let sphere = lastNormals.indices.filter { Int(lastNormals[$0].w) == 2 }
  let dHero = difference(hero, plain, all, width: 48), refGlass = channels(plain, all)
  let dSphere = difference(hero, plain, sphere, width: 48)
  print("Hero termination (dispersion 1e-6): image \(dHero.mean) ± \(dHero.se) of \(refGlass); glass pixels \(dSphere.mean) ± \(dSphere.se) (\(sphere.count))")
  for c in 0..<3 { require(abs(dHero.mean[c]) <= 4 * dHero.se[c] + 1e-3 * refGlass[c], "the hero wavelength keeps the mean, channel \(c)") }
  require(sphere.count > 20, "the glass sphere covers pixels")
  // Abbe 20: the caustic and the refracted image spread into colours; the image stays finite.
  r.materials.spectralOverrides = [5: SIMD4(1, 0, 0.5, 1.4)]
  let dispersed = render(glass, samples: 256)
  savePreview([plain, hero, dispersed], width: 48, height: 32, name: "fix-spectral-dispersion.png")
  require(dispersed.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "a strongly dispersive sphere renders finite values")
  r.materials.spectralOverrides = [:]
  print("PASS: fix-spectral hero-wavelength termination is unbiased")

  // ReSTIR consistency: coloured Cornell (red and green walls, warm light) against spectral MIS, with
  // the same comparison in RGB printed for reference (each mode's own bias, e.g. RESTIRGI2021's).
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  r.lightTransport = .rgb
  let rgbReference = render(makeUniforms(scene: 1, mode: 1, width: 48, height: 32), samples: 1024)
  r.lightTransport = .spectral
  let reference = render(makeUniforms(scene: 1, mode: 1, width: 48, height: 32), samples: 1024)
  let room = nonEmissive()
  let refMean = channels(reference, room)
  let rgbRoom = channels(rgbReference, room)
  print("Coloured Cornell, MIS: RGB \(rgbRoom), spectral \(refMean) (RGB / spectral - 1 = \(rgbRoom / refMean - 1))")
  for (reuse, neighbours, shading, label, allowance) in [
    (IndirectReuse.restirGI, SpatialNeighborSelection.uniform, ControlVariates.off, "ReSTIR GI", 0.012),
    (.restirPT, .uniform, .off, "ReSTIR PT", 0.003), (.restirPTUnified, .uniform, .off, "unified ReSTIR PT", 0.003),
    (.restirPTUnified, .uniform, .restcv, "unified ReSTIR PT + ReSTCV", 0.003),
    (.restirPTUnified, .stochasticPairwise, .off, "unified ReSTIR PT, stochastic pairwise MIS", 0.003),
    (.restirGI, .stochasticPairwise, .off, "ReSTIR GI, stochastic pairwise MIS", 0.012)] {
    r.indirectReuse = reuse; r.spatialNeighbors = neighbours; r.controlVariates = shading
    r.lightTransport = .rgb
    let rgbImage = render(makeUniforms(scene: 1, mode: 0, width: 48, height: 32), samples: 1024)
    let rgbBias = difference(rgbImage, rgbReference, room, width: 48)
    r.lightTransport = .spectral
    let image = render(makeUniforms(scene: 1, mode: 0, width: 48, height: 32), samples: 1024)
    let d = difference(image, reference, room, width: 48)
    print("Spectral \(label) - spectral MIS: \(d.mean / refMean) ± \(d.se / refMean) (relative); RGB: \(rgbBias.mean / rgbRoom) ± \(rgbBias.se / rgbRoom)")
    for c in 0..<3 { require(abs(d.mean[c]) <= 4 * d.se[c] + allowance * refMean[c], "spectral \(label) agrees with spectral MIS, channel \(c)") }
  }
  (r.indirectReuse, r.spatialNeighbors, r.controlVariates) = (saved.3, saved.4, saved.5)

  // Path shifts reproduce their wavelengths: spectral ReSTIR PT paths shifted into their own pixel.
  for (scene, label) in [(UInt32(1), "Cornell"), (0, "Pavilion")] {
    for reuse in [IndirectReuse.restirPT, .restirPTUnified] {
      r.indirectReuse = reuse
      _ = render(makeUniforms(scene: scene, mode: 0, width: 96, height: 64), samples: 1)
      var u = lastRenderUniforms!
      let out = gpu.makeBuffer(length: 96 * 64 * 16, options: .storageModeShared)!
      try run("spectral_pt_identity", width: 96, height: 64) { encoder in
        encoder.setTexture(r.historyPosDepth!, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        r.materials.bind(encoder)
        encoder.setBuffer(r.historyPrimarySurfaces!, offset: 0, index: 3)
        encoder.setBuffer(r.ptReservoirs!, offset: 0, index: 5)
        encoder.setBuffer(out, offset: 0, index: 7)
        bindRendererSpectral(encoder)
      }
      var total = 0, match = 0
      for i in 0..<(96 * 64) {
        let v = out.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
        if v.w < 0 { continue }
        total += 1
        if v.x <= 1e-3 * v.y && abs(v.z - 1) <= 1e-3 { match += 1 }
      }
      print("Spectral \(label) \(reuse): \(match) of \(total) paths shifted into their pixel keep F (wavelengths from the seed)")
      require(total > 500 && Double(match) >= 0.985 * Double(total), "\(label) \(reuse): spectral identity shifts reproduce the path")
    }
  }
  r.indirectReuse = saved.3
  print("PASS: fix-spectral ReSTIR DI, GI, PT, ReSTCV and stochastic pairwise MIS agree with spectral MIS; shifts keep wavelengths")

  // MetalFX receives linear sRGB, clamped at zero, and denoises a spectral frame.
  r.materials.settings[0] = greyRoom
  let denoised = render(makeUniforms(scene: 1, mode: 0, width: 64, height: 48), samples: 8, denoise: true)
  require(lastSamples.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.z >= 0 } && lastDisplay.allSatisfy { $0.x.isFinite } && mean(denoised) > 0,
    "spectral frames reach MetalFX as nonnegative linear sRGB and display finite")
  r.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  print("PASS: fix-spectral MetalFX input")

  // Frame time (printed; tests/PERFORMANCE.md records interleaved measurements).
  for (scene, mode, label) in [(UInt32(1), UInt32(0), "Cornell, ReSTIR GI"), (0, 0, "Pavilion, ReSTIR GI"), (0, 1, "Pavilion, MIS")] {
    var times = [LightTransport: Double]()
    for transport in [LightTransport.rgb, .spectral] {
      r.lightTransport = transport
      frameMilliseconds = []
      _ = render(makeUniforms(scene: scene, mode: mode, width: 320, height: 240), samples: 12)
      times[transport] = frameMilliseconds.dropFirst(4).sorted()[4]
    }
    print(String(format: "Frame time, %@ (320 x 240): RGB %.2f ms, spectral %.2f ms (%+.0f%%)", label, times[.rgb]!, times[.spectral]!,
                 (times[.spectral]! / times[.rgb]! - 1) * 100))
    require(times[.spectral]! < 3 * times[.rgb]!, "\(label): spectral transport costs less than three RGB frames")
  }
  print("PASS: fix-spectral frame times")
}

// The Render page's Light transport popup and the Lighting panel's spectrum popups: items, the
// Automatic label, one undo step per change, renderer state and the export renderer's copy.
@MainActor func fixSpectralControllerChecks(folder: URL) throws {
  let history = controller.history
  let wasGroupingByEvent = history.groupsByEvent
  history.groupsByEvent = false
  let savedModes = ReSTIRModes(testRenderer), savedOptions = testRenderer.options
  defer { history.groupsByEvent = wasGroupingByEvent; savedModes.apply(testRenderer); testRenderer.options = savedOptions }
  func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
  }
  func popup(_ label: String) -> ActionPopup {
    let found = views(ActionPopup.self, in: controller.stack).filter { $0.accessibilityLabel() == label }
    require(found.count == 1, "one “\(label)” popup")
    return found[0]
  }
  func pick(_ label: String, _ index: Int) {
    let control = popup(label)
    control.selectItem(at: index)
    history.beginUndoGrouping(); control.invoke(); history.endUndoGrouping()
  }
  var cornell = ProjectDocument()
  cornell.scene = 1
  try controller.restore(cornell)
  controller.associate(nil, edited: false, replaced: true)
  history.removeAllActions()
  controller.page = 0
  controller.rebuild()
  require(testRenderer.resolvedLightTransport(.automatic) == .spectral, "Automatic resolves to Spectral")
  let automatic = "Spectral"
  require(popup("Light transport").itemTitles == ["Automatic (currently: \(automatic))", "Spectral", "RGB"]
    && popup("Light transport").isEnabled && !(popup("Light transport").toolTip ?? "").isEmpty,
    "the Render page offers Automatic, Spectral and RGB light transport")
  for (index, mode) in [(2, LightTransport.rgb), (1, .spectral)] where testRenderer.lightTransport != mode {
    history.removeAllActions()
    let generation = testRenderer.interactionGeneration, before = testRenderer.lightTransport
    pick("Light transport", index)
    require(testRenderer.lightTransport == mode && testRenderer.interactionGeneration != generation
      && history.canUndo && history.undoActionName == "Light transport",
      "choosing \(mode) sets the renderer, restarts accumulation and records one undo step")
    history.undo()
    require(testRenderer.lightTransport == before, "one undo restores the light transport")
    history.redo()
  }
  controller.page = 2
  controller.rebuild()
  require(popup("Light spectrum").itemTitles == StudioController.illuminantTitles && popup("Sun spectrum").itemTitles.count == 7,
    "the Lighting panel offers the light and sun spectra")
  history.removeAllActions()
  testRenderer.lightTransport = .automatic
  pick("Light spectrum", 5)
  require(testRenderer.options.lightSpectrum == Illuminant.hp1.rawValue && testRenderer.activeLightTransport == .spectral
    && history.undoActionName == "Light spectrum", "a sodium light spectrum keeps Automatic spectral, with one undo step")
  history.undo()
  require(testRenderer.options.lightSpectrum == nil, "undo restores the RGB colour")
  pick("Sun spectrum", 3)
  require(testRenderer.options.sunSpectrum == Illuminant.a.rawValue, "the sun spectrum popup sets the sun's preset")
  // Exports copy the light transport.
  controller.page = 0
  controller.rebuild()
  pick("Light transport", 2)
  let savedOutput = (testRenderer.options.outputWidth, testRenderer.options.outputHeight, testRenderer.options.exportSamples)
  let savedExport = (controller.exportDenoise, controller.exportRaw)
  testRenderer.options.outputWidth = 32; testRenderer.options.outputHeight = 24; testRenderer.options.exportSamples = 2
  controller.exportDenoise = false; controller.exportRaw = true
  let url = folder.appendingPathComponent("transport.png")
  controller.startExport(url: url, hdr: false)
  require(controller.exportRenderer?.lightTransport == .rgb && controller.exportRenderer?.spectralShaders === testRenderer.spectralShaders,
    "the export renderer copies the light transport and shares the spectral shaders")
  let deadline = Date().addingTimeInterval(60)
  while controller.exportRenderer != nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  require(FileManager.default.fileExists(atPath: url.path), "the export completes")
  (testRenderer.options.outputWidth, testRenderer.options.outputHeight, testRenderer.options.exportSamples) = savedOutput
  (controller.exportDenoise, controller.exportRaw) = savedExport
  try controller.restore(ProjectDocument())
  history.removeAllActions()
  print("PASS: fix-spectral Render and Lighting controls, undo and exports")
}
try fixSpectralChecks()
