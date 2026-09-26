// Appended after the full suite by verify.py: ReSTIR DI/GI and path-integrator regressions.
func fixIntegratorChecks() throws {
    let kernels = """
    kernel void fix_integrator_units(device float4 *out [[buffer(0)]], constant Uniforms &u [[buffer(1)]],
        constant Uniforms &graph [[buffer(2)]]) {
        // Uniform ABI and the named scene-graph flag.
        uint historyOffset = uint((constant char *)&u.reservoirHistory - (constant char *)&u);
        out[0] = float4(float(sizeof(Uniforms)), float(historyOffset),
            uses_scene_graph(graph) ? 1 : 0, uses_scene_graph(u) ? 1 : 0);
        // Depth predicates share one scattering budget.
        uint agree = 0;
        for (int depth = 1; depth <= 6; ++depth) {
            int limit = scattering_limit(float(depth));
            agree += limit == depth - 1 && restir_gi_enabled(float(depth)) == (depth >= 2) &&
                restir_gi_has_complementary_bsdf(float(depth)) == (depth >= 3) ? 1 : 0;
        }
        out[1] = float4(float(agree), scattering_limit(0.0f), scattering_limit(16.0f), 0);
        // Reconnection Jacobian: identity shift, a contact-corner shift, and a
        // shift that reaches the back of x2.
        float3 x2 = float3(0, 0, 0), n2 = float3(0, 1, 0);
        float identity = restir_gi_jacobian(float3(0.3f, 1, 0), float3(0.3f, 1, 0), x2, n2);
        float corner = restir_gi_jacobian(float3(0.01f, 0.02f, 0), float3(0, 1, 0), x2, n2);
        float back = restir_gi_jacobian(float3(0, -1, 0), float3(0, 1, 0), x2, n2);
        float3 a = float3(0.4f, 0.8f, 0.2f), b = float3(-0.3f, 0.6f, 0.1f);
        float expected = (dot(n2, normalize(a)) / dot(n2, normalize(b))) * dot(b, b) / dot(a, a);
        float general = restir_gi_jacobian(a, b, x2, n2);
        out[2] = float4(identity, corner, back, abs(general - expected) / expected);
        out[3] = float4(restir_gi_accepts_shift(float3(0.3f, 1, 0), float3(0.3f, 1, 0), x2, n2) ? 1 : 0,
            restir_gi_accepts_shift(float3(0.01f, 0.02f, 0), float3(0, 1, 0), x2, n2) ? 1 : 0,
            restir_gi_accepts_shift(float3(0, -1, 0), float3(0, 1, 0), x2, n2) ? 1 : 0, 0);
        // Pass 2 must not replay pass 1's candidate draws after lens_ray.
        uint replayed = 0;
        for (uint pixel = 0; pixel < 4096; ++pixel) {
            uint first = pixel ^ (7u * 1999999973u), second = first;
            decorrelate_shading_seed(second);
            float2 candidate = rand_f2(first), offset = rand_f2(second);
            replayed += all(candidate == offset) ? 1 : 0;
        }
        out[4] = float4(float(replayed), 0, 0, 0);
        // Every resolved field survives the primary-surface cache.
        HitRecord hit = {};
        hit.t = 2.5f; hit.position = float3(0.1f, -0.2f, 0.3f); hit.front_face = false;
        hit.normal = normalize(float3(0.2f, 0.9f, 0.1f)); hit.geometricNormal = normalize(float3(0, 1, 0.1f));
        hit.tangent = normalize(float3(1, 0, 0.3f));
        Material m = { OPENPBR, float3(0.8f, 0.5f, 0.2f), float3(0), 0.37f, 1.45f };
        m.slot = 5; m.metalness = 0.61f; m.coat = 0.23f; m.anisotropy = 0.71f; m.fuzz = 0.19f;
        m.transmission = 0.43f; m.tangent = hit.tangent; m.coatRoughness = 0.29f; m.specularWeight = 0.83f;
        m.baseWeight = 0.91f; m.diffuseRoughness = 0.13f; m.usesMaterialX = 1; m.inside = true;
        m.geometricNormal = hit.geometricNormal;
        hit.mat = m;
        HitRecord r = load_primary_surface(store_primary_surface(hit), float4(hit.position, hit.t));
        Material q = r.mat;
        bool same = r.t == hit.t && all(r.position == hit.position) && r.front_face == hit.front_face &&
            all(r.normal == hit.normal) && all(r.geometricNormal == hit.geometricNormal) && all(r.tangent == hit.tangent) &&
            q.type == m.type && all(q.albedo == m.albedo) && q.roughness == m.roughness && q.ior == m.ior &&
            q.slot == m.slot && q.metalness == m.metalness && q.coat == m.coat && q.anisotropy == m.anisotropy &&
            q.fuzz == m.fuzz && q.transmission == m.transmission && all(q.tangent == m.tangent) &&
            q.coatRoughness == m.coatRoughness && q.specularWeight == m.specularWeight &&
            q.baseWeight == m.baseWeight && q.diffuseRoughness == m.diffuseRoughness &&
            q.usesMaterialX == m.usesMaterialX && q.inside == m.inside && all(q.geometricNormal == m.geometricNormal);
        HitRecord light = hit; light.front_face = true;
        light.mat.type = EMISSIVE; light.mat.emission = float3(18, 15, 9); light.mat.usesMaterialX = 0;
        HitRecord e = load_primary_surface(store_primary_surface(light), float4(light.position, light.t));
        out[5] = float4(same ? 1 : 0, e.mat.type == EMISSIVE && all(e.mat.emission == light.mat.emission) &&
            e.front_face && !e.mat.inside ? 1 : 0, 0, 0);
    }

    // Retrace pass 1's camera rays for the last rendered frame and compare the cache.
    kernel void fix_integrator_primary_cache(constant Uniforms &uniforms [[buffer(0)]],
        constant SurfaceSettings *surfaceSettings [[buffer(1)]],
        constant MaterialResources &materialImages [[buffer(2)]],
        const device PrimarySurface *primarySurfaces [[buffer(3)]],
        const device float4 *positions [[buffer(4)]], device atomic_uint *counts [[buffer(5)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uniforms.width || gid.y >= uniforms.height) return;
        uint index = gid.y * uniforms.width + gid.x;
        uint seed = index ^ (uniforms.sampleIndex * 1999999973u);
        float aspect = float(uniforms.width) / float(uniforms.height);
        float fov_scale = tan((uniforms.cameraPos.w * 0.5f) * PI / 180.0f);
        float2 jitter = uniforms.jitter + 0.5f;
        float x = (((float(gid.x) + jitter.x) / float(uniforms.width)) * 2.0f - 1.0f) * aspect * fov_scale;
        float y = -(((float(gid.y) + jitter.y) / float(uniforms.height)) * 2.0f - 1.0f) * fov_scale;
        float3 forward = normalize(uniforms.cameraTarget.xyz - uniforms.cameraPos.xyz);
        float3 right = normalize(cross(forward, uniforms.cameraUp.xyz));
        float3 up = cross(right, forward);
        Ray ray = { uniforms.cameraPos.xyz, normalize(forward + x * right + y * up) };
        lens_ray(ray, forward, right, up, uniforms, seed);
        HitRecord rec;
        bool hit = trace_scene(ray, uniforms.sceneIndex, rec, materialImages, uniforms);
        float4 p = positions[index];
        if (hit != (p.w > 0.0f)) { atomic_fetch_add_explicit(&counts[0], 1, memory_order_relaxed); return; }
        if (!hit) return;
        resolve_material(rec, ray, uniforms, surfaceSettings, materialImages, rec.t * 2.0f * fov_scale / float(uniforms.height));
        HitRecord c = load_primary_surface(primarySurfaces[index], p);
        Material a = rec.mat, b = c.mat;
        float3 colorA = a.type == EMISSIVE ? a.emission : a.albedo, colorB = b.type == EMISSIVE ? b.emission : b.albedo;
        float error = max(max(length(rec.normal - c.normal), length(rec.geometricNormal - c.geometricNormal)),
            max(length(colorA - colorB) / max(1.0f, length(colorA)), abs(rec.t - c.t) / rec.t));
        error = max(error, max(max(abs(a.roughness - b.roughness), abs(a.ior - b.ior)), max(abs(a.metalness - b.metalness),
            abs(a.transmission - b.transmission))));
        error = max(error, max(max(abs(a.coat - b.coat), abs(a.anisotropy - b.anisotropy)), length(a.tangent - b.tangent)));
        bool same = a.type == b.type && rec.front_face == c.front_face && a.inside == b.inside &&
            a.usesMaterialX == b.usesMaterialX && error < 1e-4f;
        atomic_fetch_add_explicit(&counts[same ? 1 : 0], 1, memory_order_relaxed);
        if (b.type == OPENPBR) atomic_fetch_add_explicit(&counts[2], 1, memory_order_relaxed);
    }
    """
    let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            fputs("FAIL: missing \(name)\n", stderr); exit(1)
        }
        return try gpu.makeComputePipelineState(function: function)
    }
    func run(_ state: MTLComputePipelineState, width: Int, height: Int, _ bind: (MTLComputeCommandEncoder) -> Void) {
        let command = testRenderer.commandQueue.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(state)
        bind(encoder)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        require(command.status == .completed, "integrator check command: \(String(describing: command.error))")
    }

    // Unit checks: ABI, depth predicates, Jacobian, RNG streams, cache packing.
    var units = makeUniforms(scene: 1, mode: 0, width: 1, height: 1)
    var swiftGraph = units
    swiftGraph.sceneGraphMode = true
    require(swiftGraph.lens.z == 1 && swiftGraph.sceneGraphMode && !units.sceneGraphMode, "Swift scene-graph flag accessor")
    require(MemoryLayout<Uniforms>.stride == 304 && MemoryLayout<Uniforms>.offset(of: \.reservoirHistory) == 248,
        "Swift reservoir history occupies the former alignment gap")
    let unitOut = gpu.makeBuffer(length: 6 * 16, options: .storageModeShared)!
    run(try pipeline("fix_integrator_units"), width: 1, height: 1) {
        $0.setBuffer(unitOut, offset: 0, index: 0)
        $0.setBytes(&units, length: MemoryLayout<Uniforms>.stride, index: 1)
        $0.setBytes(&swiftGraph, length: MemoryLayout<Uniforms>.stride, index: 2)
    }
    let unit = (0..<6).map { unitOut.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
    print("Integrator unit checks: \(unit)")
    require(unit[0] == SIMD4<Float>(304, 248, 1, 0), "MSL uniform layout and uses_scene_graph")
    require(unit[1] == SIMD4<Float>(6, 0, 15, 0), "scattering_limit drives every depth predicate; depth 1 is direct only")
    require(abs(unit[2].x - 1) < 1e-5 && unit[2].y > 10 && unit[2].z == 0 && unit[2].w < 1e-4,
        "ReSTIR GI reconnection Jacobian (Ouyang et al. 2021, Eq. 11)")
    require(unit[3].x == 1 && unit[3].y == 0 && unit[3].z == 0, "degenerate short and back-facing GI shifts are rejected")
    require(unit[4].x == 0, "shading pass does not replay pass-1 candidate draws")
    require(unit[5].x == 1 && unit[5].y == 1, "primary-surface cache preserves resolved hits")
    print("PASS: uniform ABI, scene-graph flag, depth predicates, GI Jacobian bounds, pass RNG streams, primary cache packing")

    // Primary cache against a fresh trace, with thin lens, OpenPBR anisotropy and transmission.
    let savedSettings = testRenderer.materials.settings
    var anisotropic = SurfaceSettings(); anisotropic.enabled = 1
    anisotropic.color = SIMD4<Float>(0.9, 0.6, 0.4, 1); anisotropic.surface = SIMD4<Float>(0.35, 1, 0.4, 0.7)
    var transmissive = SurfaceSettings(); transmissive.enabled = 1
    transmissive.detail = SIMD4<Float>(0.2, 1.45, 1, 1)
    testRenderer.materials.settings[2] = anisotropic
    testRenderer.materials.settings[4] = transmissive
    var cacheView = makeUniforms(scene: 0, mode: 0, width: 64, height: 48)
    cacheView.lens = SIMD4<Float>(0.06, 3.5, 0, 0)
    let cacheSamples = 3
    let lensImage = render(cacheView, samples: cacheSamples, denoise: true)
    require(mean(lensImage) > 0.01, "cached primary hits shade the thin-lens OpenPBR view")
    var lastFrame = cacheView
    lastFrame.frameIndex = UInt32(cacheSamples); lastFrame.reservoirHistory = UInt32(cacheSamples)
    lastFrame.sampleIndex = UInt32(cacheSamples); lastFrame.jitter = frameJitter(lastFrame.sampleIndex)
    var positions = lastPositions
    let positionBuffer = gpu.makeBuffer(bytes: &positions, length: positions.count * 16, options: .storageModeShared)!
    let counts = gpu.makeBuffer(length: 12, options: .storageModeShared)!
    memset(counts.contents(), 0, 12)
    run(try pipeline("fix_integrator_primary_cache"), width: 64, height: 48) {
        testRenderer.materials.bind($0)
        $0.setBytes(&lastFrame, length: MemoryLayout<Uniforms>.stride, index: 0)
        $0.setBuffer(testRenderer.primarySurfaces!, offset: 0, index: 3)
        $0.setBuffer(positionBuffer, offset: 0, index: 4)
        $0.setBuffer(counts, offset: 0, index: 5)
    }
    let cacheCounts = (0..<3).map { counts.contents().load(fromByteOffset: $0 * 4, as: UInt32.self) }
    print("Primary cache vs retrace (mismatch, match, OpenPBR): \(cacheCounts)")
    require(cacheCounts[0] == 0 && cacheCounts[1] > 1000 && cacheCounts[2] > 20,
        "shading and guide passes reuse pass-1 primary hits instead of retracing")
    testRenderer.materials.settings = savedSettings
    print("PASS: primary-surface cache matches a fresh primary trace")

    // Low-depth radiance: every strategy agrees at depths 1-3, ReSTIR GI's
    // terminal weighting included, and depth 1 is distinct from depth 2.
    var energy = [[Float]]()
    for depth in 1...3 {
        var row = [Float]()
        for mode in UInt32(0)...3 {
            var view = makeUniforms(scene: 1, mode: mode, width: 48, height: 32)
            view.cameraTarget.w = Float(depth)
            row.append(mean(render(view, samples: 256)))
        }
        print("Cornell depth \(depth) mean radiance (ReSTIR, MIS, NEE, BSDF): \(row)")
        energy.append(row)
    }
    for (index, row) in energy.enumerated() {
        let depth = index + 1
        require(abs(row[2] - row[1]) / row[1] < 0.03, "NEE matches MIS at depth \(depth)")
        require(abs(row[3] - row[1]) / row[1] < 0.12, "BSDF sampling matches MIS at depth \(depth)")
        require(abs(row[0] - row[1]) / row[1] < 0.06, "ReSTIR matches MIS at depth \(depth)")
    }
    require(energy[0][1] < energy[1][1] * 0.9 && energy[1][1] < energy[2][1], "each added depth adds indirect light")
    for depth in 1...2 {
        let restirIncrement = energy[depth][0] - energy[depth - 1][0]
        let misIncrement = energy[depth][1] - energy[depth - 1][1]
        print("Depth \(depth)->\(depth + 1) increment: ReSTIR=\(restirIncrement), MIS=\(misIncrement)")
        require(abs(restirIncrement - misIncrement) / misIncrement < 0.15,
            "ReSTIR GI conserves the depth \(depth + 1) indirect increment")
    }
    print("PASS: depth 1-3 radiance agrees across ReSTIR, MIS, NEE and BSDF sampling")

    // Temporal reuse continues while the camera orbits. The reprojection
    // tolerance (1% of hit distance) needs pixels smaller than 64x48 gives.
    let orbitFrames = 8
    let orbitStart = makeUniforms(scene: 1, mode: 0, width: 160, height: 120)
    _ = render(orbitStart, samples: orbitFrames, orbit: true)
    let valid = lastGIWeights.filter { $0.y > 0 }
    let reused = valid.filter { $0.y > 1.5 }
    print("Orbit GI reservoirs: \(reused.count) of \(valid.count) valid reuse history")
    require(valid.count > 1000 && Float(reused.count) > 0.5 * Float(valid.count),
        "ReSTIR temporal reuse survives camera motion")
    let orbitSample = mean(lastSamples)
    var orbitEnd = orbitStart
    orbitEnd.cameraPos.x += 0.025 * Float(orbitFrames - 1)
    let eye = SIMD3<Float>(orbitEnd.cameraPos.x, orbitEnd.cameraPos.y, orbitEnd.cameraPos.z)
    let target = SIMD3<Float>(orbitEnd.cameraTarget.x, orbitEnd.cameraTarget.y, orbitEnd.cameraTarget.z)
    orbitEnd.currentViewProj = makePerspective(fovyRadians: orbitEnd.cameraPos.w * .pi / 180, aspect: 160.0 / 120.0,
        near: 0.05, far: 100) * makeLookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
    orbitEnd.prevViewProj = orbitEnd.currentViewProj
    orbitEnd.samplingMode = 1
    let orbitReference = mean(render(orbitEnd, samples: 128))
    print("Orbit final ReSTIR frame mean \(orbitSample), MIS reference \(orbitReference)")
    require(abs(orbitSample - orbitReference) / orbitReference < 0.15, "moving-camera ReSTIR frame energy")

    // Host history lifecycle: orbits keep it; cuts and inspection frames clear it.
    let savedMode = testRenderer.samplingMode, savedViewport = testRenderer.viewportMode
    let output = studioOutput
    func frame() {
        var done = false
        testRenderer.onFrameUpdate = { _ in done = true }
        testRenderer.renderFrame(output: output)
        waitUntil({ done })
    }
    testRenderer.samplingMode = 0; testRenderer.viewportMode = 0
    frame(); frame()
    require(testRenderer.reservoirHistory == 2, "consecutive ReSTIR frames build history")
    testRenderer.yaw += 0.01
    require(testRenderer.frameIndex == 0 && testRenderer.reservoirHistory == 2, "camera motion keeps ReSTIR history")
    frame()
    require(testRenderer.reservoirHistory == 3 && testRenderer.frameIndex == 1, "orbit frame reuses history")
    testRenderer.viewportMode = 1; frame(); testRenderer.viewportMode = 0
    require(testRenderer.reservoirHistory == 0, "inspection frames invalidate reservoirs")
    frame(); testRenderer.resetAccumulation()
    require(testRenderer.reservoirHistory == 0, "scene cuts clear ReSTIR history")
    testRenderer.samplingMode = savedMode; testRenderer.viewportMode = savedViewport
    print("PASS: ReSTIR temporal reuse across camera motion and history reset lifecycle")
}
do { try fixIntegratorChecks() } catch { fputs("FAIL: integrator checks: \(error)\n", stderr); exit(1) }
