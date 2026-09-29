// Compatibility-guided ReSTIR spatial neighbour selection (REFERENCES.md COMPATRESTIR2026):
// Uniforms layout and mode plumbing; the Eq. 14-15 score and the concentric disk map;
// A-ES selection probabilities, validity, uniqueness and early stopping on synthetic
// G-buffers; the uniform (RESTIR2020) fallback taps against the pre-change formula; mean
// radiance against MIS in both modes; and the equal-sample MSE gain on an imported mesh.
@MainActor func fixCompatNeighborsChecks() throws {
  let renderer = testRenderer
  let savedMode = renderer.spatialNeighbors

  // Layout: the mode occupies former padding, so the 304-byte stride is unchanged.
  require(MemoryLayout<Uniforms>.stride == 304 && MemoryLayout<Uniforms>.offset(of: \Uniforms.spatialNeighbors) == 252,
    "Uniforms.spatialNeighbors sits at offset 252 of the 304-byte uniforms")
  let blank = makeUniforms(scene: 1, mode: 0, width: 1, height: 1)
  require(blank.spatialNeighbors == SpatialNeighborSelection.compatibility.rawValue,
    "uniforms default to compatibility-guided selection")
  let environmentDefault: SpatialNeighborSelection =
    ProcessInfo.processInfo.environment["VIBE_SPATIAL_NEIGHBORS"] == "uniform" ? .uniform : .compatibility
  require(PathTracerRenderer.defaultSpatialNeighbors == environmentDefault,
    "the default selection follows the VIBE_SPATIAL_NEIGHBORS test seam")

  let kernels = """
    kernel void compat_layout(device uint *out [[buffer(0)]]) {
        Uniforms v;
        out[0] = sizeof(Uniforms);
        out[1] = uint((thread char *)&v.spatialNeighbors - (thread char *)&v);
    }
    // Eq. 14-15 cases and the disk map.
    kernel void compat_score(device float *out [[buffer(0)]]) {
        float3 n = float3(0, 0, 1);
        float d = 2.0f, s = d * sqrt(0.05f / PI);
        float c = cos(0.3f);
        out[0] = restir_compatibility(float3(1, 2, 3), n, d, float3(1, 2, 3), n);
        out[1] = restir_compatibility(float3(0), n, d, float3(0), float3(sin(0.3f), 0, c));
        out[2] = pow(c, 8.0f);
        out[3] = restir_compatibility(float3(0), n, d, float3(0.1f, 0, 0), n);
        out[4] = exp(-0.1f / s);
        out[5] = restir_compatibility(float3(0), n, d, float3(0), -n);
        out[6] = restir_compatibility(float3(0), n, 0.0f, float3(0), n);
        // Fraction of a 256x256 grid mapped inside radius 0.5 (area preserving: 1/4),
        // largest radius, and the sign balance of x (symmetric: 0).
        uint inside = 0; float largest = 0, balance = 0;
        for (uint i = 0; i < 256; ++i) for (uint j = 0; j < 256; ++j) {
            float2 p = concentric_disk((float2(i, j) + 0.5f) / 256.0f);
            inside += length(p) < 0.5f ? 1 : 0;
            largest = max(largest, length(p));
            balance += sign(p.x);
        }
        out[7] = float(inside) / 65536.0f;
        out[8] = largest;
        out[9] = balance / 65536.0f;
    }
    // One selection per thread for `center`, plus an independent replay of the candidate
    // list (same start draw, same compat_candidate taps, same validity rules and early
    // stop) that yields the A-ES first-rank probability of class A (h > 0.25).
    kernel void compat_trials(texture2d<float, access::read> positions [[texture(0)]],
                              texture2d<float, access::read> normals [[texture(1)]],
                              constant Uniforms &u [[buffer(0)]], constant uint2 &center [[buffer(1)]],
                              device uint4 *outcome [[buffer(2)]], device float4 *expected [[buffer(3)]],
                              uint id [[thread_position_in_grid]]) {
        uint seed = pcg_hash(id * 7919u + 17u), replay = seed;
        float4 p0 = positions.read(center), n0 = normals.read(center);
        SpatialNeighbors chosen = select_compatible_neighbors(center, p0.xyz, n0.xyz, p0.w, positions, normals, u, seed);
        float2 start = rand_f2(replay);
        int2 taps[COMPAT_CANDIDATES];
        uint valid = 0, strong = 0, duplicates = 0, fifthStrong = COMPAT_CANDIDATES;
        float sumA = 0, sumB = 0;
        for (uint k = 0; k < COMPAT_CANDIDATES && strong <= SPATIAL_NEIGHBORS; ++k) {
            int2 c = compat_candidate(center, start, k);
            if (all(c == int2(center)) || c.x < 0 || c.y < 0 || c.x >= int(u.width) || c.y >= int(u.height)) continue;
            float4 p = positions.read(uint2(c)), n = normals.read(uint2(c));
            if (p.w <= 0 || n.w != float(DIFFUSE)) continue;
            float h = restir_compatibility(p0.xyz, n0.xyz, p0.w, p.xyz, n.xyz);
            if (!(h > 0)) continue;
            bool repeated = false;
            for (uint i = 0; i < valid; ++i) repeated = repeated || all(taps[i] == c);
            if (repeated) { ++duplicates; continue; }
            if (h > 0.5f && ++strong == SPATIAL_NEIGHBORS + 1) fifthStrong = valid;
            taps[valid++] = c;
            if (h > 0.25f) sumA += h; else sumB += h;
        }
        bool listed = true, unique = true;
        uint latest = 0, firstClass = 3;
        for (uint i = 0; i < chosen.count; ++i) {
            bool found = false;
            for (uint j = 0; j < valid; ++j) if (all(taps[j] == chosen.coord[i])) { found = true; latest = max(latest, j); }
            listed = listed && found;
            for (uint j = 0; j < i; ++j) unique = unique && any(chosen.coord[j] != chosen.coord[i]);
        }
        if (chosen.count > 0) {
            int2 c = chosen.coord[0];
            float4 p = positions.read(uint2(c)), n = normals.read(uint2(c));
            firstClass = restir_compatibility(p0.xyz, n0.xyz, p0.w, p.xyz, n.xyz) > 0.25f ? 0 : 1;
        }
        outcome[id] = uint4(chosen.count, firstClass, (listed ? 1u : 0u) | (unique ? 2u : 0u), latest);
        expected[id] = float4(sumA / max(sumA + sumB, 1e-30f), float(valid), float(fifthStrong), float(duplicates));
    }
    // The uniform fallback taps and binary test against the pre-change code (d5a449f),
    // written out here as it stood in shading_kernel.
    kernel void compat_uniform_taps(device uint *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        uint seed = pcg_hash(id + 5u), before = seed;
        uint2 gid = uint2(id % 97u, id / 97u);
        bool same = true;
        for (int i = 0; i < 4; ++i) {
            float2 offset = (rand_f2(before) * 2.0f - 1.0f) * 16.0f;
            int2 old = int2(gid) + int2(offset);
            same = same && all(uniform_neighbor(gid, seed) == old);
        }
        same = same && seed == before;
        float4 posDepth = float4(0, 0, 0, 1.0f + rand_f(seed));
        float3 norm = normalize(float3(0.4f * (rand_f(seed) - 0.5f), 0.4f * (rand_f(seed) - 0.5f), 1.0f));
        float depth = posDepth.w * (0.9f + 0.2f * rand_f(seed)) * (rand_f(seed) < 0.1f ? -1.0f : 1.0f);
        float4 nPosDepth = float4(0, 0, 0, depth);
        float4 nNormMat = float4(normalize(float3(0.4f * (rand_f(seed) - 0.5f), 0.4f * (rand_f(seed) - 0.5f), 1.0f)),
                                 rand_f(seed) < 0.2f ? 1.0f : 0.0f);
        bool oldTest = nPosDepth.w > 0.0f && nNormMat.w == float(DIFFUSE) && dot(norm, nNormMat.xyz) > 0.95f &&
            abs(posDepth.w - nPosDepth.w) < 0.05f * posDepth.w;
        out[id] = (same ? 1u : 0u) |
            (restir2020_compatible(posDepth, norm, DIFFUSE, nPosDepth, nNormMat) == oldTest ? 2u : 0u) | (oldTest ? 4u : 0u);
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  func pipeline(_ name: String) throws -> MTLComputePipelineState {
    try gpu.makeComputePipelineState(function: library.makeFunction(name: name)!)
  }
  func run(_ name: String, threads: Int, _ bind: (MTLComputeCommandEncoder) -> Void) throws {
    let state = try pipeline(name)
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(state)
    bind(encoder)
    encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: min(threads, state.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) completes: \(String(describing: command.error))")
  }

  let layout = gpu.makeBuffer(length: 8, options: .storageModeShared)!
  try run("compat_layout", threads: 1) { $0.setBuffer(layout, offset: 0, index: 0) }
  require(layout.contents().load(as: UInt32.self) == 304 && layout.contents().load(fromByteOffset: 4, as: UInt32.self) == 252,
    "MSL Uniforms.spatialNeighbors matches the Swift offset")

  let scores = gpu.makeBuffer(length: 10 * 4, options: .storageModeShared)!
  try run("compat_score", threads: 1) { $0.setBuffer(scores, offset: 0, index: 0) }
  let s = (0..<10).map { scores.contents().load(fromByteOffset: $0 * 4, as: Float.self) }
  print("Compatibility score cases: \(s)")
  require(abs(s[0] - 1) < 1e-6, "identical primary hits score 1")
  require(abs(s[1] - s[2]) < 1e-4 * s[2], "normal term is max(n . n', 0)^8")
  require(abs(s[3] - s[4]) < 1e-4 * s[4], "position term is exp(-|x - y| / s), s = d sqrt(0.05 / pi)")
  require(s[5] == 0 && s[6] == 0, "opposed normals and a zero hit distance score 0")
  require(abs(s[7] - 0.25) < 0.01 && s[8] <= 1.0001 && abs(s[9]) < 0.01, "concentric map is area preserving onto the unit disk")
  print("PASS: fix-compat-neighbors layout, Eq. 14-15 score and concentric disk map")

  // Synthetic G-buffers, 64 x 48. Every hit shares the centre's position (position term 1).
  // Columns 0, 2 mod 4: class A, h = 0.4; column 1 mod 4: class B, h = 0.1; column 3 mod 4:
  // glossy on even rows, a miss on odd rows (never selectable). The centre sits near the
  // left edge, so some candidates fall off-screen. Class weights below 0.5 disable early
  // stopping; the second buffer (all h = 1) exercises it.
  let w = 64, h = 48, center = SIMD2<UInt32>(6, 24)
  func texture(_ format: MTLPixelFormat, _ values: [SIMD4<Float>]) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead]; d.storageMode = .shared
    let t = gpu.makeTexture(descriptor: d)!
    if format == .rgba16Float {
      let bits = values.flatMap { v in (0..<4).map { Float16(v[$0]).bitPattern } }
      t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bits, bytesPerRow: w * 8)
    } else {
      t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: values, bytesPerRow: w * 16)
    }
    return t
  }
  func tilt(_ weight: Float) -> SIMD3<Float> { let c = pow(weight, 0.125); return SIMD3(sqrt(1 - c * c), 0, c) }
  var classPositions = [SIMD4<Float>](), classNormals = [SIMD4<Float>]()
  for y in 0..<h { for x in 0..<w {
    let column = x % 4
    classPositions.append(SIMD4(0.3, -0.2, 1, column == 3 && y % 2 == 1 ? -1 : 2))
    let n = column == 1 ? tilt(0.1) : tilt(0.4)
    classNormals.append(SIMD4(n, column == 3 ? 1 : 0))
  }}
  let centerIndex = Int(center.y) * w + Int(center.x)
  classNormals[centerIndex] = SIMD4(0, 0, 1, 0)
  var trialUniforms = makeUniforms(scene: 1, mode: 0, width: w, height: h)
  func trials(_ positions: [SIMD4<Float>], _ normals: [SIMD4<Float>], count: Int) throws -> ([SIMD4<UInt32>], [SIMD4<Float>]) {
    let p = texture(.rgba32Float, positions), n = texture(.rgba16Float, normals)
    let outcome = gpu.makeBuffer(length: count * 16, options: .storageModeShared)!
    let expected = gpu.makeBuffer(length: count * 16, options: .storageModeShared)!
    var c = center
    try run("compat_trials", threads: count) {
      $0.setTexture(p, index: 0); $0.setTexture(n, index: 1)
      $0.setBytes(&trialUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
      $0.setBytes(&c, length: 8, index: 1)
      $0.setBuffer(outcome, offset: 0, index: 2); $0.setBuffer(expected, offset: 0, index: 3)
    }
    return ((0..<count).map { outcome.contents().load(fromByteOffset: $0 * 16, as: SIMD4<UInt32>.self) },
            (0..<count).map { expected.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) })
  }
  let count = 1 << 16
  let (outcome, expected) = try trials(classPositions, classNormals, count: count)
  require(outcome.indices.allSatisfy { outcome[$0].z == 3 }, "every selected neighbour is a valid, distinct candidate tap")
  require(outcome.indices.allSatisfy { Float(outcome[$0].x) == min(4, expected[$0].y) },
    "without early stopping, min(4, valid candidates) neighbours are selected")
  require(expected.allSatisfy { $0.w == 0 }, "the R2 taps of a 24-pixel disk do not repeat pixels")
  // First-rank A-ES outcome versus the replayed h_A / (h_A + h_B) of each trial's candidate set.
  var observed = 0.0, predicted = 0.0, variance = 0.0, uniformPrediction = 0.0
  for i in 0..<count where outcome[i].x > 0 {
    let p = Double(expected[i].x)
    observed += outcome[i].y == 0 ? 1 : 0; predicted += p; variance += p * (1 - p)
    // Share of class A among the same taps if chosen with equal weight (h_A = 4 h_B).
    uniformPrediction += p / (4 - 3 * p)
  }
  let z = (observed - predicted) / variance.squareRoot(), zUniform = (observed - uniformPrediction) / variance.squareRoot()
  print("A-ES first rank: class A observed \(observed / Double(count)), predicted \(predicted / Double(count)) (z = \(z)); uniform choice would give \(uniformPrediction / Double(count)) (z = \(zUniform))")
  require(abs(z) < 5, "neighbours are selected in proportion to the compatibility score (A-Chao/A-ES first rank)")
  require(abs(zUniform) > 50, "the proportionality check distinguishes weighted from uniform selection")

  // Early stopping: all h = 1 (> 0.5). The search ends once a fifth strong candidate is
  // seen, so all four neighbours come from the first five valid taps.
  let strongNormals = classNormals.map { SIMD4<Float>(0, 0, 1, $0.w == 1 ? 1 : 0) }
  let (strong, strongExpected) = try trials(classPositions, strongNormals, count: 4096)
  require(strong.indices.allSatisfy { strong[$0].x == 4 && strong[$0].z == 3 && Float(strong[$0].w) <= strongExpected[$0].z
      && strongExpected[$0].z <= 4 }, "early stopping after more than four taps score above 0.5")
  print("PASS: fix-compat-neighbors A-ES selection probabilities, validity, uniqueness and early stopping")

  let taps = gpu.makeBuffer(length: 97 * 61 * 4, options: .storageModeShared)!
  try run("compat_uniform_taps", threads: 97 * 61) { $0.setBuffer(taps, offset: 0, index: 0) }
  let tapResults = (0..<(97 * 61)).map { taps.contents().load(fromByteOffset: $0 * 4, as: UInt32.self) }
  let accepted = tapResults.filter { $0 & 4 != 0 }.count
  require(tapResults.allSatisfy { $0 & 3 == 3 } && accepted > 100 && accepted < tapResults.count - 100,
    "uniform mode keeps the pre-change box taps, random stream and binary normal/depth/material test")
  print("PASS: fix-compat-neighbors uniform fallback reproduces the RESTIR2020 taps and test (\(accepted) of \(tapResults.count) accepted)")

  // renderFrame passes the mode through to the shaders.
  for mode in [SpatialNeighborSelection.uniform, .compatibility] {
    renderer.spatialNeighbors = mode
    _ = render(makeUniforms(scene: 1, mode: 0, width: 16, height: 12), samples: 1)
    require(lastRenderUniforms?.spatialNeighbors == mode.rawValue, "renderFrame writes spatialNeighbors = \(mode)")
  }

  // Imported mesh (scene 6): a UV sphere on a floor quad seen at a grazing angle, where the
  // binary depth test rejects most uniform taps. Equal-sample MSE against an independent MIS
  // reference, paired over trials that share seeds; then long-run mean radiance against MIS.
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
  let savedSettings = renderer.materials.settings
  renderer.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  try renderer.materials.setMesh(try OBJMesh.load(obj))
  renderer.materials.hasSceneGraph = false
  let mw = 160, mh = 120
  func mseAgainst(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
    zip(a, b).reduce(0.0) { sum, pair in
      let d = pair.0 - pair.1
      return sum + Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3
    } / Double(a.count)
  }
  // render() replays one seed sequence, so independent trials are distinct orbit views,
  // each against its own 1024-sample MIS reference.
  var meshView = makeUniforms(scene: 6, mode: 1, width: mw, height: mh)
  meshView.environment.w = Float(renderer.materials.nodeCount)
  let orbitTarget = SIMD3<Float>(meshView.cameraTarget.x, meshView.cameraTarget.y, meshView.cameraTarget.z)
  let orbitOffset = SIMD3<Float>(meshView.cameraPos.x, meshView.cameraPos.y, meshView.cameraPos.z) - orbitTarget
  var ratios = [Double](), meshReference = [SIMD4<Float>](), meshPixels = [Int](), firstView = meshView
  for trial in 0..<6 {
    let angle = Float(trial) * 0.35 - 0.9
    let rotated = SIMD3<Float>(orbitOffset.x * cos(angle) + orbitOffset.z * sin(angle), orbitOffset.y,
                               -orbitOffset.x * sin(angle) + orbitOffset.z * cos(angle))
    var view = meshView
    view.cameraPos = SIMD4(orbitTarget + rotated, meshView.cameraPos.w)
    view.samplingMode = 1
    let reference = render(view, samples: 1024)
    if trial == 0 {
      meshReference = reference; firstView = view
      meshPixels = lastPositions.indices.filter { lastPositions[$0].w > 0 && Int(lastNormals[$0].w) == 0 }
    }
    view.samplingMode = 0
    renderer.spatialNeighbors = .uniform
    let uniformError = mseAgainst(render(view, samples: 16), reference)
    renderer.spatialNeighbors = .compatibility
    let compatError = mseAgainst(render(view, samples: 16), reference)
    ratios.append(compatError / uniformError)
    print("Imported mesh view \(trial): 16-frame MSE uniform \(uniformError), compatibility \(compatError)")
  }
  let meanRatio = ratios.reduce(0, +) / Double(ratios.count)
  let ratioSE = (ratios.map { ($0 - meanRatio) * ($0 - meanRatio) }.reduce(0, +) / Double(ratios.count - 1)
    / Double(ratios.count)).squareRoot()
  print("Imported-mesh equal-sample MSE ratio (compatibility / uniform): \(meanRatio) ± \(ratioSE) over \(ratios.count) views")
  require(ratios.allSatisfy { $0 < 1 } && meanRatio + 4 * ratioSE < 0.8,
    "compatibility-guided selection lowers equal-sample MSE on the imported mesh by more than 20% in every view")
  firstView.samplingMode = 0

  // Mean radiance: ReSTIR in both modes against MIS over diffuse primary hits (the pixels
  // spatial reuse touches), with tile-clustered standard errors. The 1/Z normalization of
  // compatibility mode must not move the estimate further from MIS than uniform mode does.
  func agreement(_ view: Uniforms, reference: [SIMD4<Float>], pixels: [Int], width: Int, label: String) {
    var deviations = [SpatialNeighborSelection: (mean: Float, se: Float, reference: Float)]()
    for mode in [SpatialNeighborSelection.uniform, .compatibility] {
      renderer.spatialNeighbors = mode
      let image = render(view, samples: 512)
      let d = pairedDifference(image, reference, width: width, pixels: pixels)
      deviations[mode] = d
      print("\(label) ReSTIR (\(mode)) - MIS over \(pixels.count) diffuse pixels: \(d.mean / d.reference) ± \(d.se / d.reference) (relative)")
      // Uniform mode keeps the earlier allowance of the strategy energy check (3%);
      // compatibility mode, with its 1/Z normalization, must stay within 1.5%.
      let allowance: Float = mode == .uniform ? 0.03 : 0.015
      require(abs(d.mean) < 4 * d.se + allowance * d.reference, "\(label): \(mode) ReSTIR agrees with MIS in mean radiance")
    }
    let u = deviations[.uniform]!, c = deviations[.compatibility]!
    require(abs(c.mean) < abs(u.mean) + 4 * (c.se * c.se + u.se * u.se).squareRoot() + 0.001 * c.reference,
      "\(label): compatibility mode is no more biased than uniform mode")
  }
  agreement(firstView, reference: meshReference, pixels: meshPixels, width: mw, label: "Imported mesh")
  try renderer.materials.setMesh([])
  renderer.materials.settings = savedSettings
  var cornell = makeUniforms(scene: 1, mode: 1, width: 192, height: 128)
  let cornellReference = render(cornell, samples: 1024)
  let cornellPixels = lastPositions.indices.filter { lastPositions[$0].w > 0 && Int(lastNormals[$0].w) == 0 }
  cornell.samplingMode = 0
  agreement(cornell, reference: cornellReference, pixels: cornellPixels, width: 192, label: "Cornell")
  print("PASS: fix-compat-neighbors equal-sample MSE gain and mean radiance agreement in both modes")

  // MetalFX display error (tone-mapped, against a 1,024-sample MIS reference) after 4
  // frames at 640x480: compatibility reuse must not degrade the denoised preview.
  if renderer.supportsMetalFX {
    func display(_ pixels: [SIMD4<Float>]) -> [SIMD3<Float>] {
      pixels.map { p in SIMD3((0..<3).map { c -> Float in
        let v = p[c], m = max(0, min(1, (v * (v + 0.0245786) - 0.000090537) / (v * (0.983729 * v + 0.4329510) + 0.238081)))
        return m <= 0.0031308 ? 12.92 * m : 1.055 * pow(m, 1 / 2.4) - 0.055 }) }
    }
    func displayError(_ a: [SIMD4<Float>], _ b: [SIMD3<Float>]) -> Double {
      zip(display(a), b).reduce(0.0) { $0 + Double(simd_length_squared($1.0 - $1.1)) / 3 } / Double(b.count)
    }
    for (scene, label) in [(UInt32(1), "Cornell"), (UInt32(0), "Pavilion")] {
      var view = makeUniforms(scene: scene, mode: 1, width: 640, height: 480)
      let reference = display(render(view, samples: 1024))
      view.samplingMode = 0
      var errors = [SpatialNeighborSelection: Double]()
      for mode in [SpatialNeighborSelection.uniform, .compatibility] {
        renderer.spatialNeighbors = mode
        _ = render(view, samples: 4, denoise: true)
        errors[mode] = displayError(lastDisplay, reference)
      }
      print("\(label) 4-frame MetalFX display MSE: uniform \(errors[.uniform]!), compatibility \(errors[.compatibility]!)")
      require(errors[.compatibility]! < 1.15 * errors[.uniform]!, "\(label): compatibility reuse keeps the MetalFX preview error")
    }
    print("PASS: fix-compat-neighbors MetalFX preview error in both modes")
  }
  renderer.spatialNeighbors = savedMode
}
try fixCompatNeighborsChecks()
