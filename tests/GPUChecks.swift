// Appended to production definitions by verify.py; no copied renderer implementation.
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
guard let gpu = MTLCreateSystemDefaultDevice() else {
    fputs("GPU tests require access to a Metal device.\n", stderr)
    exit(2)
}
let testRenderer = try PathTracerRenderer(device: gpu)
require(MemoryLayout<Uniforms>.stride == 304, "Swift/Metal uniform layout")
print("PASS: runtime shader compilation on \(gpu.name)")

let checks = """
kernel void regression_checks(device uint *results [[buffer(0)]], constant Uniforms &u [[buffer(1)]], constant MaterialResources &materialImages [[buffer(2)]]) {
    Material matte = { DIFFUSE, float3(0.8f), float3(0), 0.0f, 1.0f };
    HitRecord hit;
    Ray inside = { float3(0), float3(1, 0, 0) };
    results[0] = sizeof(Uniforms) == 304 && intersect_box(inside, float3(0), float3(1), 0, matte, 0.001f, 100, hit)
        && abs(hit.t - 1.0f) < 1e-5f && !hit.front_face && hit.normal.x < -0.99f;
    Ray parallel = { float3(2, 0, 0), float3(0, 1, 0) };
    results[1] = !intersect_box(parallel, float3(0), float3(1), 0, matte, 0.001f, 100, hit);
    uint seed = 17;
    bool bounded = true;
    for (int i = 0; i < 100000; ++i) { float v = rand_f(seed); bounded = bounded && v >= 0.0f && v < 1.0f; }
    // This seed makes the second PCG draw exactly zero. The radial sample
    // must stay above the tangent plane to avoid enormous GI reuse weights.
    uint grazingSeed = 890625759u;
    float3 grazingNormal = normalize(float3(0.31456656f, 0, -0.9492354f));
    float3 grazingSample = sample_cosine_hemisphere(grazingNormal, grazingSeed);
    results[2] = bounded && dot(grazingNormal, grazingSample) > 0.0001f;
    results[3] = abs(power_heuristic(1e-10f, 1e-10f) - 0.5f) < 1e-6f;
    Material glass = { DIELECTRIC, float3(1), float3(0), 0, 1.52f };
    float3 direction, weight; float pdf;
    results[4] = sample_bsdf(glass, float3(0, 0, -1), normalize(float3(0.9f, 0, 0.435f)),
        false, seed, direction, weight, pdf) && direction.z < 0 && all(weight == 1.0f);
    results[5] = emission_weight(false, true, false, 0.2f, 1.0f) == 0.0f &&
        emission_weight(true, true, true, 0.0f, 1.0f) == 1.0f &&
        emission_weight(false, false, false, 0.2f, 1.0f) == 1.0f;
    bool onEmitter = true;
    for (int i = 0; i < 1000; ++i) {
        LightSample ls = sample_direct_light(float3(0, -0.9f, 0), float3(0, 1, 0), u, seed, materialImages);
        float xs[4] = { -2.4f, -0.8f, 0.8f, 2.4f };
        float radii[4] = { 0.55f, 0.18f, 0.055f, 0.016f };
        float error = 100.0f;
        for (int j = 0; j < 4; ++j) error = min(error, abs(length(ls.position - float3(xs[j], 1.8f, 1.2f)) - radii[j]));
        onEmitter = onEmitter && error < 0.001f && isfinite(ls.pdf) && ls.pdf > 0.0f;
    }
    results[6] = onEmitter;
    // The visible gold ring must use the finite-roughness OpenPBR path. A
    // colored delta cavity compounds its tint over dozens of wall bounces.
    Ray grazing = { float3(0.7f, -0.44f, -0.5f), normalize(float3(0, -0.01f, 1)) };
    results[7] = trace_scene(grazing, 0, hit) && hit.mat.type == GLOSSY && !is_delta(hit.mat);
    Uniforms terminal = u;
    terminal.cameraTarget.w = 1;
    bool depth1 = !restir_gi_has_complementary_bsdf(terminal.cameraTarget.w);
    terminal.cameraTarget.w = 2;
    bool depth2 = !restir_gi_has_complementary_bsdf(terminal.cameraTarget.w);
    terminal.cameraTarget.w = 3;
    results[8] = depth1 && depth2 && restir_gi_has_complementary_bsdf(terminal.cameraTarget.w);
}
"""
// Direct kernel dispatches use the production defaults: StudioOptions' sun and the
// renderer's clip planes (the projection MetalFX receives), not a test-only projection.
@MainActor func makeUniforms(scene: UInt32, mode: UInt32, width: Int, height: Int, fog: UInt32 = 0) -> Uniforms {
    testRenderer.sceneIndex = scene
    let r = testRenderer, defaults = StudioOptions(), clip = r.cameraClipPlanes()
    let eye = r.target + SIMD3<Float>(r.distance * cos(r.pitch) * sin(r.yaw),
        r.distance * sin(r.pitch), -r.distance * cos(r.pitch) * cos(r.yaw))
    let vp = makePerspective(fovyRadians: r.fov * .pi / 180, aspect: Float(width) / Float(height), near: clip.near, far: clip.far)
        * makeLookAt(eye: eye, target: r.target, up: SIMD3<Float>(0, 1, 0))
    let az = defaults.sunAzimuth * .pi / 180, el = defaults.sunElevation * .pi / 180
    return Uniforms(cameraPos: SIMD4<Float>(eye, r.fov), cameraTarget: SIMD4<Float>(r.target, defaults.depth),
        cameraUp: SIMD4<Float>(0, 1, 0, 0), sunParams: SIMD4<Float>(sin(az) * cos(el), sin(el), cos(az) * cos(el), defaults.sunIntensity),
        currentViewProj: vp, prevViewProj: vp, frameIndex: 1, sceneIndex: scene, samplingMode: mode,
        enableSMS: 0, skyMode: 0, enableFog: fog, viewportMode: 0, width: UInt32(width), height: UInt32(height))
}
let library = try gpu.makeLibrary(source: metalSource + checks, options: shaderCompileOptions())
let checkPipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "regression_checks")!)
let results = gpu.makeBuffer(length: 9 * 4, options: .storageModeShared)!
var checkUniforms = makeUniforms(scene: 2, mode: 1, width: 1, height: 1)
let checkCommand = testRenderer.commandQueue.makeCommandBuffer()!
let checkEncoder = checkCommand.makeComputeCommandEncoder()!
checkEncoder.setComputePipelineState(checkPipeline)
testRenderer.materials.bind(checkEncoder)
checkEncoder.setBuffer(results, offset: 0, index: 0)
checkEncoder.setBytes(&checkUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
checkEncoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
checkEncoder.endEncoding()
checkCommand.commit(); checkCommand.waitUntilCompleted()
require(checkCommand.status == .completed, "GPU regression command: \(String(describing: checkCommand.error))")
let names = ["inside-box exit", "parallel-box miss", "random endpoints", "small-PDF MIS", "glass total internal reflection", "emission weighting", "sphere emitter endpoints", "finite-roughness grazing cylinder", "terminal ReSTIR GI weighting"]
for i in names.indices { require(results.contents().load(fromByteOffset: i * 4, as: UInt32.self) == 1, names[i]) }
print("PASS: \(names.joined(separator: ", "))")

var lastDisplay = [SIMD4<Float>]()
var lastNormals = [SIMD4<Float>]()
var lastMaterials = [SIMD4<Float>]()
var lastPositions = [SIMD4<Float>]()
var lastSamples = [SIMD4<Float>]()
var lastMotion = [SIMD4<Float>]()
var lastGIWeights = [SIMD4<Float>]()
var lastResets = [Bool]()
var lastDenoiseMilliseconds = 0.0
// GPU command-buffer time of every frame render() traced (tests/benchmark.py reads it).
var frameMilliseconds = [Double]()
// Production uniforms of the final frame of the last render().
var lastRenderUniforms: Uniforms?
// Fixtures, previews and exports go to the per-run directory verify.py passes in.
let testOutputDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VIBE_TEST_OUTPUT"] ?? "build/checks",
    isDirectory: true)

@MainActor func readTexture(_ texture: MTLTexture) -> [SIMD4<Float>] {
    let half: Bool, channels: Int
    switch texture.pixelFormat {
    case .rgba16Float: half = true; channels = 4
    case .rg16Float: half = true; channels = 2
    case .r16Float: half = true; channels = 1
    case .r32Float: half = false; channels = 1
    case .rgba32Float: half = false; channels = 4
    default: fatalError("Unsupported readback format")
    }
    let width = texture.width, height = texture.height
    let stride = (half ? 2 : 4) * channels
    let rowBytes = (width * stride + 255) & ~255
    let buffer = gpu.makeBuffer(length: rowBytes * height, options: .storageModeShared)!
    let command = testRenderer.commandQueue.makeCommandBuffer()!
    let blit = command.makeBlitCommandEncoder()!
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
        destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "texture readback")
    return (0..<(width * height)).map { i in
        var pixel = SIMD4<Float>(0, 0, 0, 1)
        let offset = (i / width) * rowBytes + (i % width) * stride
        for c in 0..<channels {
            pixel[c] = half ? Float(Float16(bitPattern: buffer.contents().load(fromByteOffset: offset + c * 2, as: UInt16.self)))
                : buffer.contents().load(fromByteOffset: offset + c * 4, as: Float.self)
        }
        return pixel
    }
}

// A test view (Uniforms fields) becomes production renderer state: camera, strategy,
// scene toggles and StudioOptions. renderFrame then derives the frame uniforms itself.
@MainActor func applyTestView(_ u: Uniforms) {
    let r = testRenderer
    r.sceneIndex = u.sceneIndex
    r.samplingMode = u.samplingMode; r.enableSMS = u.enableSMS; r.skyMode = u.skyMode; r.enableFog = u.enableFog
    r.viewportMode = u.viewportMode
    let eye = SIMD3<Float>(u.cameraPos.x, u.cameraPos.y, u.cameraPos.z)
    let target = SIMD3<Float>(u.cameraTarget.x, u.cameraTarget.y, u.cameraTarget.z)
    let offset = eye - target, distance = simd_length(offset)
    require(distance > 0 && abs(offset.y) < distance * 0.99999, "test view is an orbit camera (not straight up/down)")
    r.target = target; r.distance = distance; r.fov = u.cameraPos.w
    r.pitch = asin(offset.y / distance); r.yaw = atan2(offset.x, -offset.z)
    var o = StudioOptions()
    o.previewScale = 1; o.depth = u.cameraTarget.w
    let sun = SIMD3<Float>(u.sunParams.x, u.sunParams.y, u.sunParams.z)
    if simd_length(sun) > 0 {
        o.sunElevation = asin(sun.y / simd_length(sun)) * 180 / .pi
        o.sunAzimuth = atan2(sun.x, sun.z) * 180 / .pi
    }
    o.sunIntensity = u.sunParams.w
    o.sunAngle = u.lens.w > 0 ? Float(720 / Double.pi * asin((Double(u.lens.w) / 2).squareRoot())) : nil
    o.environmentIntensity = u.environment.x; o.environmentRotation = u.environment.y * 180 / .pi
    o.aperture = u.lens.x; o.focusDistance = u.lens.y
    o.lightColor = SIMD3<Float>(u.light.x, u.light.y, u.light.z); o.lightIntensity = 1; o.lightSize = u.light.w
    r.options = o
    require((u.environment.z > 0.5) == (r.materials.environmentData != nil),
        "test view environment flag matches the loaded environment")
    require(u.sceneIndex != 6 || u.sceneGraphMode == r.materials.hasSceneGraph,
        "test view scene-graph flag matches the loaded library")
}
var renderOutputs = [SIMD2<Int>: MTLTexture]()
// Renders `samples` frames of a view through PathTracerRenderer.renderFrame, starting
// from a reset accumulation and the first jitter/seed of the sequence, and reads back
// the raw accumulation (returned), display, G-buffer, samples, GI reservoirs and motion.
@MainActor func render(_ input: Uniforms, samples: Int, denoise: Bool = false, orbit: Bool = false) -> [SIMD4<Float>] {
    let r = testRenderer
    let camera = (r.yaw, r.pitch, r.distance, r.target, r.fov)
    let modes = (r.samplingMode, r.enableSMS, r.skyMode, r.enableFog, r.viewportMode)
    let savedOptions = r.options, savedFrameUpdate = r.onFrameUpdate, savedError = r.onError
    // Run main-queue work queued before this render (e.g. controller publication), so it
    // cannot reset the accumulation while a frame is in flight.
    var drained = false
    DispatchQueue.main.async { drained = true }
    while !drained { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    applyTestView(input)
    r.denoiserEnabled = denoise
    r.resetAccumulation()
    r.restartSampleSequence()
    lastResets = []
    var completed = 0, failure: String?
    r.onFrameUpdate = { _ in completed += 1 }
    r.onError = { failure = $0 }
    let w = Int(input.width), h = Int(input.height)
    let output = renderOutputs[SIMD2(w, h)] ?? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        return gpu.makeTexture(descriptor: d)!
    }()
    renderOutputs[SIMD2(w, h)] = output
    let usesMetalFX = denoise && input.samplingMode == 0 && input.viewportMode == 0
    var eye = SIMD3<Float>(input.cameraPos.x, input.cameraPos.y, input.cameraPos.z)
    let label = "scene \(input.sceneIndex), strategy \(input.samplingMode), view \(input.viewportMode)"
    for frame in 1...samples {
        if orbit && frame > 1 {
            // Production camera controls reset accumulation but keep MetalFX and ReSTIR history.
            eye.x += 0.025
            let offset = eye - r.target
            r.distance = simd_length(offset); r.pitch = asin(offset.y / r.distance); r.yaw = atan2(offset.x, -offset.z)
        }
        let target = completed + 1, submitted = r.frameIndex, generation = r.interactionGeneration
        r.renderFrame(output: output)
        require(r.frameIndex == submitted + 1, "\(label): renderFrame did not submit a frame")
        if usesMetalFX && r.supportsMetalFX {
            require(r.lastPresentationUsedMetalFX, "native MetalFX is used, not a fallback (\(label))")
            lastResets.append(r.lastMetalFXReset)
        } else if usesMetalFX {
            require(!r.lastPresentationUsedMetalFX && r.lastDisplay === r.accumTexture, "MetalFX-unavailable fallback shows the raw render")
        }
        let deadline = Date().addingTimeInterval(60)
        while completed < target && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        require(failure == nil && completed >= target, "\(label): \(failure ?? "renderFrame did not complete a frame")"
            + (r.interactionGeneration != generation ? " (accumulation was reset while the frame was in flight)" : ""))
        lastDenoiseMilliseconds = r.gpuMilliseconds
        frameMilliseconds.append(r.gpuMilliseconds)
    }
    require(simd_length(SIMD3(r.lastUniforms!.cameraPos.x, r.lastUniforms!.cameraPos.y, r.lastUniforms!.cameraPos.z) - eye)
        < 1e-4 * max(1, r.distance), "production camera reproduces the test view")
    lastRenderUniforms = r.lastUniforms
    lastDisplay = readTexture(r.lastDisplay!)
    lastMaterials = readTexture(r.gbufferAlbedoRough!)
    // renderFrame swaps G-buffer and GI reservoirs after encoding: the "history" and
    // "B" textures hold what the final frame wrote.
    lastNormals = readTexture(r.historyNormalMat!)
    lastPositions = readTexture(r.historyPosDepth!)
    lastSamples = readTexture(r.sampleTexture!)
    lastGIWeights = readTexture(r.giWeightsB!)
    if usesMetalFX, let fx = r.metalFX { lastMotion = readTexture(fx.motion) }
    require(lastDisplay.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "finite denoised image")
    let pixels = readTexture(r.accumTexture!)
    require(pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.x >= 0 && $0.y >= 0 && $0.z >= 0 }, "finite nonnegative pixels")
    r.onFrameUpdate = savedFrameUpdate; r.onError = savedError
    (r.samplingMode, r.enableSMS, r.skyMode, r.enableFog, r.viewportMode) = modes
    (r.yaw, r.pitch, r.distance, r.target, r.fov) = camera
    r.options = savedOptions
    return pixels
}
func mean(_ pixels: [SIMD4<Float>]) -> Float {
    pixels.reduce(Float(0)) { $0 + ($1.x + $1.y + $1.z) / 3 } / Float(pixels.count)
}
// Mean and cluster-robust standard error of a - b (channel mean) over `pixels`, with
// `block`x`block` tiles as clusters so that correlated neighbours (ReSTIR spatial reuse)
// are not treated as independent samples; `reference` is the mean of b.
func pairedDifference(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>], width: Int, pixels: [Int], block: Int = 4)
    -> (mean: Float, se: Float, reference: Float) {
    var tiles = [Int: (difference: Double, reference: Double, count: Double)]()
    for i in pixels {
        let x = Double(a[i].x + a[i].y + a[i].z) / 3, y = Double(b[i].x + b[i].y + b[i].z) / 3
        let key = (i / width / block) * 65536 + (i % width) / block
        let t = tiles[key] ?? (0, 0, 0)
        tiles[key] = (t.difference + x - y, t.reference + y, t.count + 1)
    }
    let n = Double(pixels.count), k = Double(tiles.count)
    require(k > 10, "paired comparison has enough independent tiles")
    let mean = tiles.values.reduce(0) { $0 + $1.difference } / n
    let variance = k / (k - 1) * tiles.values.reduce(0) { $0 + pow($1.difference - mean * $1.count, 2) } / (n * n)
    return (Float(mean), Float(variance.squareRoot()), Float(tiles.values.reduce(0) { $0 + $1.reference } / n))
}
func savePreview(_ panels: [[SIMD4<Float>]], width: Int, height: Int, name: String) {
    let scale = 3, totalWidth = width * panels.count * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: totalWidth, pixelsHigh: height * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: totalWidth * 4, bitsPerPixel: 32)!
    let bytes = rep.bitmapData!
    for (panel, pixels) in panels.enumerated() {
        for y in 0..<height { for x in 0..<width {
            let p = pixels[y * width + x]
            let color = [p.x, p.y, p.z].map { value -> UInt8 in
                let a = value * (value + 0.0245786) - 0.000090537
                let b = value * (0.983729 * value + 0.4329510) + 0.238081
                let x = max(0, min(1, a / b))
                return UInt8((x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / Float(2.4)) - 0.055) * 255)
            }
            for sy in 0..<scale { for sx in 0..<scale {
                let index = ((y * scale + sy) * totalWidth + (panel * width + x) * scale + sx) * 4
                bytes[index] = color[0]; bytes[index+1] = color[1]; bytes[index+2] = color[2]; bytes[index+3] = 255
            }}
        }}
    }
    let directory = testOutputDirectory
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}
// verify.py: end of shared GPU helpers
for scene in UInt32(0)...5 {
    for mode in UInt32(0)...3 {
        let pixels = render(makeUniforms(scene: scene, mode: mode, width: 49, height: 33), samples: 8)
        require(mean(pixels) > 0.001, "nonblack scene \(scene), strategy \(mode)")
    }
}
print("PASS: all six scenes and four strategies at a non-threadgroup-aligned size")
var lightView = makeUniforms(scene: 1, mode: 1, width: 3, height: 3)
lightView.cameraPos = SIMD4<Float>(0, 0.5, 0, 10)
// Nearly vertical: production orbit cameras keep +Y up.
lightView.cameraTarget = SIMD4<Float>(0, 0.999, 0.01, 16)
let lightPixels = render(lightView, samples: 1)
require(abs(lightPixels[4].x - 18) < 0.02 && abs(lightPixels[4].y - 15) < 0.02, "primary visible emission survives G-buffer")
let clear = render(makeUniforms(scene: 4, mode: 1, width: 49, height: 33), samples: 16)
let fog = render(makeUniforms(scene: 4, mode: 1, width: 49, height: 33, fog: 1), samples: 16)
require(abs(mean(clear) - mean(fog)) > 0.001, "fog toggle changes rendered output")
print("PASS: visible emitter radiance and fog toggle")
// Strategies must agree within Monte Carlo error. Directly visible emitters (identical
// in every strategy) are excluded rather than diluting the comparison, and each estimate
// is paired per pixel against MIS with a tile-clustered standard error (SE). Unbiased
// pairs must agree within 4 SE, and 512 samples keep 4 SE below 5% of the mean, so a
// few-percent MIS/weighting regression fails. ReSTIR's approximate reuse measured
// +1.2% (±0.2%) here; it may deviate by up to 3% beyond 4 SE.
var strategyImages = [[SIMD4<Float>]]()
for mode in UInt32(0)...3 {
    strategyImages.append(render(makeUniforms(scene: 1, mode: mode, width: 48, height: 32), samples: 512))
}
let strategyPixels = lastPositions.indices.filter { lastPositions[$0].w > 0 && Int(lastNormals[$0].w) != 3 }
print("Cornell mean radiance (ReSTIR, MIS, NEE, BSDF): \(strategyImages.map(mean))")
for (other, name) in [(2, "NEE"), (3, "BSDF"), (0, "ReSTIR")] {
    let d = pairedDifference(strategyImages[other], strategyImages[1], width: 48, pixels: strategyPixels)
    print("Cornell \(name) - MIS over \(strategyPixels.count) non-emitter pixels: \(d.mean) ± \(d.se) (MIS \(d.reference))")
    require(4 * d.se < 0.05 * d.reference, "\(name)/MIS comparison resolves a 5% energy difference")
    require(abs(d.mean) < 4 * d.se + (other == 0 ? 0.03 * d.reference : 0), "\(name) and MIS agree in mean radiance")
}
print("PASS: sampling strategy energy checks")

// White-furnace integration catches angular energy loss that scene averages miss.
let furnaceSource = """
kernel void furnace_check(device float4 *results [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float roughnesses[4] = { 0.04f, 0.1f, 0.45f, 0.9f };
    float angles[5] = { 1.0f, 0.5f, 0.1f, 0.05f, 0.02f };
    float roughness = roughnesses[id / 5], cosine = angles[id % 5];
    Material white = { GLOSSY, float3(1), float3(0), roughness, 1 };
    float3 wo = float3(sqrt(1.0f - cosine * cosine), 0, cosine), normal = float3(0, 0, 1);
    uint seed = pcg_hash(id + 19);
    float sum = 0, maxWeight = 0, quadrature = 0;
    for (int i = 0; i < 65536; ++i) {
        float3 direction, weight; float pdf;
        if (sample_bsdf(white, normal, -wo, true, seed, direction, weight, pdf)) {
            sum += weight.x;
            maxWeight = max(maxWeight, weight.x);
        }
        // Independent hemisphere integration of the evaluated BRDF (rough cases).
        float2 r = rand_f2(seed);
        float z = r.x, phi = TWO_PI * r.y;
        float3 wi = float3(sqrt(1.0f - z*z) * cos(phi), sqrt(1.0f - z*z) * sin(phi), z);
        quadrature += eval_bsdf(white, normal, wo, wi).x * z * TWO_PI;
    }
    results[id] = float4(sum / 65536.0f, maxWeight, 0, quadrature / 65536.0f);
}
"""
let furnaceLibrary = try gpu.makeLibrary(source: metalSource + furnaceSource, options: shaderCompileOptions())
let furnacePipeline = try gpu.makeComputePipelineState(function: furnaceLibrary.makeFunction(name: "furnace_check")!)
let furnaceBuffer = gpu.makeBuffer(length: 20 * 16, options: .storageModeShared)!
let furnaceCommand = testRenderer.commandQueue.makeCommandBuffer()!
let furnaceEncoder = furnaceCommand.makeComputeCommandEncoder()!
furnaceEncoder.setComputePipelineState(furnacePipeline)
furnaceEncoder.setBuffer(furnaceBuffer, offset: 0, index: 0)
furnaceEncoder.dispatchThreads(MTLSize(width: 20, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 20, height: 1, depth: 1))
furnaceEncoder.endEncoding(); furnaceCommand.commit(); furnaceCommand.waitUntilCompleted()
require(furnaceCommand.status == .completed, "white furnace GPU completion")
for i in 0..<20 {
    let r = furnaceBuffer.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
    print("OpenPBR furnace \(i): mean=\(r.x), maximum sample=\(r.y), independent=\(r.w)")
    require(r.x.isFinite && abs(r.x - 1) < 0.015, "OpenPBR white-metal furnace retains unit energy, case \(i)")
    if i >= 10 { require(abs(r.x - r.w) < 0.035, "independent BRDF integration agrees with VNDF sampling, case \(i)") }
    // Grazing cases (N·V down to 0.02) are covered by the production unit-energy bound above.
    if i == 8 { print("White furnace, roughness 0.1 at N·V=0.05: GGX=\(r.x)") }
}
print("PASS: 20 angular/roughness energy cases and independent BRDF integration")

// MetalFX checks run only where the device supports it; the fallback path (raw
// accumulation) is covered by Fix_tests.swift on every device.
let metalFXAvailable = testRenderer.supportsMetalFX
if !metalFXAvailable { print("SKIP: MetalFX checks (\(gpu.name) does not support the temporal denoised scaler)") }
// Region-mean MetalFX output versus the raw accumulation of the same frames.
func metalFXEnergyRatio(_ output: [SIMD4<Float>], _ raw: [SIMD4<Float>], _ pixels: [Int]) -> Float {
    mean(pixels.map { output[$0] }) / max(1e-6, mean(pixels.map { raw[$0] }))
}
let denoiseUniforms = makeUniforms(scene: 1, mode: 0, width: 128, height: 96)
// The 0.8 error-ratio gate below was calibrated on uniform spatial neighbours; at this
// size compatibility-guided reuse lowers the raw error itself by 18% (MetalFX is compared
// in both modes at 640x480 in tests/Fix_compat-neighbors.swift).
testRenderer.spatialNeighbors = .uniform
let lowSamples = render(denoiseUniforms, samples: 4)
require(lastGIWeights.contains { $0.y > 0 && $0.z > 0 }, "first-bounce ReSTIR GI produces valid reservoirs")
let rawDisplay = lastDisplay
let lowWithFilter = render(denoiseUniforms, samples: 4, denoise: true)
if metalFXAvailable {
    require(lastResets == [true, false, false, false], "stationary MetalFX temporal history")
    require(lastMotion.allSatisfy { abs($0.x) < 0.001 && abs($0.y) < 0.001 }, "jitter is excluded from static motion vectors")
}
let filtered = lastDisplay
require(lowSamples == lowWithFilter && rawDisplay == lowSamples, "denoise does not alter raw accumulation")
let reference = render(denoiseUniforms, samples: 256)
testRenderer.spatialNeighbors = PathTracerRenderer.defaultSpatialNeighbors
func mse(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
    zip(a, b).reduce(Float(0)) { sum, pair in
        let delta = SIMD3<Float>(pair.0.x - pair.1.x, pair.0.y - pair.1.y, pair.0.z - pair.1.z)
        return sum + dot(delta, delta) / 3
    } / Float(a.count)
}
let rawError = mse(lowSamples, reference), filteredError = mse(filtered, reference)
print("4-sample Cornell MSE vs 256-sample reference: raw=\(rawError), denoised=\(filteredError)")
func displayPixels(_ pixels: [SIMD4<Float>]) -> [SIMD4<Float>] {
    pixels.map { pixel in
        var result = SIMD4<Float>(0, 0, 0, 1)
        for c in 0..<3 {
            let v = pixel[c]
            let mapped = (v * (v + 0.0245786) - 0.000090537) / (v * (0.983729 * v + 0.4329510) + 0.238081)
            let x = max(0, min(1, mapped))
            result[c] = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / Float(2.4)) - 0.055
        }
        return result
    }
}
let displayRawError = mse(displayPixels(lowSamples), displayPixels(reference))
let displayFilteredError = mse(displayPixels(filtered), displayPixels(reference))
print("Display-space MSE: raw=\(displayRawError), denoised=\(displayFilteredError)")
// MetalFX reconstructs subpixel coverage and is a biased display estimator.
// Track linear error too; gate the quality of the actual tone-mapped display.
require(filteredError.isFinite, "finite MetalFX linear image error")
if metalFXAvailable {
    print("MetalFX display error ratio: \(displayFilteredError / displayRawError)")
    require(displayFilteredError < displayRawError * 0.8, "MetalFX reduces low-sample displayed image error")
}
savePreview([lowSamples, filtered, reference], width: 128, height: 96, name: "denoiser-check.png")
if metalFXAvailable {
    // Diffuse Cornell radiance: MetalFX region means track the raw accumulation within 8%.
    let cornell32 = render(denoiseUniforms, samples: 32, denoise: true)
    let cornellTypes = lastNormals.map { Int($0.w) }
    let cornellSurfaces = cornellTypes.indices.filter { cornellTypes[$0] != 3 && lastPositions[$0].w > 0 }
    let cornellEmitters = cornellTypes.indices.filter { cornellTypes[$0] == 3 }
    let cornellRatio = metalFXEnergyRatio(lastDisplay, cornell32, cornellSurfaces)
    print("Cornell 32-frame MetalFX/raw energy: surfaces \(cornellRatio), visible emitters \(metalFXEnergyRatio(lastDisplay, cornell32, cornellEmitters))")
    require(abs(cornellRatio - 1) < 0.08, "MetalFX preserves diffuse Cornell radiance within 8%")
}
let bypass = render(makeUniforms(scene: 0, mode: 1, width: 47, height: 31), samples: 2, denoise: true)
require(bypass == lastDisplay, "non-ReSTIR denoiser bypass")
_ = render(makeUniforms(scene: 0, mode: 0, width: 64, height: 48), samples: 2, denoise: true)
print("PASS: raw invariance, non-ReSTIR bypass, and resize")

// Check the motion/history contract while the camera moves, then an explicit cut.
_ = render(makeUniforms(scene: 0, mode: 0, width: 128, height: 96), samples: 4, denoise: true, orbit: true)
if metalFXAvailable {
    require(lastResets == [true, false, false, false], "orbit preserves MetalFX history")
    require(lastMotion.contains { abs($0.x) + abs($0.y) > 0.01 }, "camera movement produces pixel motion vectors")
}
testRenderer.resetAccumulation()
require(testRenderer.metalFXHistoryNeedsReset, "scene cut clears history")
testRenderer.denoiserEnabled = false; testRenderer.denoiserEnabled = true
require(testRenderer.metalFXHistoryNeedsReset, "reenabling MetalFX resets history")
print("PASS: camera motion, temporal history, and reset lifecycle")

// A view of the reported copper sphere and its surrounding floor, saved for review.
var pavilion = makeUniforms(scene: 0, mode: 0, width: 320, height: 240)
let previewEye = SIMD3<Float>(1.2, 0.6, -0.9), previewTarget = SIMD3<Float>(0.05, -0.55, 0.85)
pavilion.cameraPos = SIMD4<Float>(previewEye, 50)
pavilion.cameraTarget = SIMD4<Float>(previewTarget, 16)
let pavilionRaw = render(pavilion, samples: 8, denoise: true)
let pavilionFiltered = lastDisplay
print("320x240 render + MetalFX GPU time: \(lastDenoiseMilliseconds) ms")
let pavilionReference = render(pavilion, samples: 128)
savePreview([pavilionRaw, pavilionFiltered, pavilionReference], width: 320, height: 240, name: "pavilion-check.png")

// Check reflection guides and quantify specular-region quality against the same view.
let pavilionRaw32 = render(pavilion, samples: 32, denoise: true)
let metalFXReflection = lastDisplay
let reflectionNormals = lastNormals
let types = reflectionNormals.map { Int($0.w) }
let specularIndices = types.indices.filter { types[$0] == 1 || types[$0] == 2 }
require(!specularIndices.isEmpty, "preview contains reflective surfaces")
if let fx = testRenderer.metalFX {
    let specularHits = readTexture(fx.hitDistance)
    let roughnessGuide = readTexture(fx.roughness)
    let specularGuide = readTexture(fx.specular)
    let diffuseGuide = readTexture(fx.diffuse)
    require(specularIndices.contains { specularHits[$0].x > 0 }, "reflection distance is populated")
    require(specularIndices.allSatisfy { roughnessGuide[$0].x >= 0 && roughnessGuide[$0].x <= 1 && (specularGuide[$0].x + diffuseGuide[$0].x) >= 0 }, "valid specular guides")
    let specularReference = specularIndices.map { pavilionReference[$0] }
    let specularNoisy = specularIndices.map { pavilionRaw32[$0] }
    let specularDenoised = specularIndices.map { metalFXReflection[$0] }
    let reflectionError8 = mse(displayPixels(specularIndices.map { pavilionFiltered[$0] }), displayPixels(specularReference))
    let reflectionRawError8 = mse(displayPixels(specularIndices.map { pavilionRaw[$0] }), displayPixels(specularReference))
    print("Reflective region 8-frame display error: raw=\(reflectionRawError8), MetalFX=\(reflectionError8)")
    require(reflectionError8 < reflectionRawError8 * 0.8, "MetalFX improves low-sample reflective-region error")
    print("Reflective region display error: raw32=\(mse(displayPixels(specularNoisy), displayPixels(specularReference))), MetalFX32=\(mse(displayPixels(specularDenoised), displayPixels(specularReference)))")
    // MetalFX output is a display estimate; its region means must still track the raw
    // radiance of the same frames (diffuse surfaces, sky and emitters excluded).
    let diffuseIndices = types.indices.filter { types[$0] == 0 && lastPositions[$0].w > 0 }
    let pavilionDiffuseRatio = metalFXEnergyRatio(metalFXReflection, pavilionRaw32, diffuseIndices)
    let pavilionReflectiveRatio = metalFXEnergyRatio(metalFXReflection, pavilionRaw32, specularIndices)
    print("Pavilion 32-frame MetalFX/raw energy: diffuse \(pavilionDiffuseRatio), reflective \(pavilionReflectiveRatio), whole image \(mean(metalFXReflection) / mean(pavilionRaw32))")
    // MetalFX dims high-variance (caustic, glossy) radiance, so its output and EXR
    // exports are not radiometric. These floors sit under the measured M4/macOS 26
    // ratios (0.87, 0.69) and catch regressions of the earlier 29% class.
    require(pavilionDiffuseRatio > 0.82 && pavilionReflectiveRatio > 0.6, "MetalFX pavilion energy stays above its measured floor")
}
savePreview([pavilionRaw32, metalFXReflection, pavilionReference], width: 320, height: 240, name: "metalfx-reflections.png")

// Resolve the SDK/header versus video mask-convention discrepancy empirically.
if let fx = testRenderer.metalFX {
    let originalMask = fx.scaler.denoiseStrengthMaskTexture
    var masks = [[SIMD4<Float>]]()
    for value: UInt8 in [0, 255] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 320, height: 240, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead]
        let mask = gpu.makeTexture(descriptor: d)!
        let bytes = [UInt8](repeating: value, count: 320 * 240)
        bytes.withUnsafeBytes { mask.replace(region: MTLRegionMake2D(0, 0, 320, 240), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 320) }
        fx.scaler.denoiseStrengthMaskTexture = mask
        fx.scaler.shouldResetHistory = true
        let command = testRenderer.commandQueue.makeCommandBuffer()!
        fx.scaler.encode(commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        require(command.status == .completed, "denoise mask probe")
        let pixels = readTexture(fx.output)
        print("Mask \(value): MSE vs input=\(mse(displayPixels(pixels), displayPixels(lastSamples)))")
        masks.append(pixels)
    }
    savePreview(masks, width: 320, height: 240, name: "metalfx-mask-probe.png")
    fx.scaler.denoiseStrengthMaskTexture = originalMask
}

// A near-horizontal camera reproduces the black opening caused by the former
// 16-bounce cap. Identify the inside wall geometrically, excluding the exterior.
var cylinder = makeUniforms(scene: 0, mode: 0, width: 240, height: 160)
let cylinderEye = SIMD3<Float>(0.70, -0.40, -2.0), cylinderTarget = SIMD3<Float>(0.70, -0.65, 0.1)
cylinder.cameraPos = SIMD4<Float>(cylinderEye, 30)
cylinder.cameraTarget = SIMD4<Float>(cylinderTarget, 16)
let cylinderRaw = render(cylinder, samples: 64, denoise: true)
let cylinderFX = lastDisplay
let cylinderInside = cylinderRaw.indices.filter { i in
    let p = lastPositions[i], n = lastNormals[i]
    let radial = SIMD3<Float>(p.x - 0.7, 0, p.z - 0.1)
    return Int(n.w) == 1 && abs(simd_length(radial) - 0.42) < 0.002 && p.y > -0.995 && p.y < -0.445
        && simd_dot(radial, SIMD3<Float>(n.x, n.y, n.z)) < -0.4
}
require(cylinderInside.count > 30, "grazing view covers the cylinder's inner wall")
func cylinderMean(_ pixels: [SIMD4<Float>]) -> Float { mean(cylinderInside.map { pixels[$0] }) }
for (name, pixels) in metalFXAvailable ? [("raw", cylinderRaw), ("MetalFX", cylinderFX)] : [("raw", cylinderRaw)] {
    let lit = cylinderInside.filter { max(pixels[$0].x, max(pixels[$0].y, pixels[$0].z)) > 0.05 }.count
    require(Float(lit) / Float(cylinderInside.count) > 0.95, "\(name): grazing cylinder interior receives light")
    let color = cylinderInside.reduce(SIMD3<Float>(repeating: 0)) {
        $0 + SIMD3<Float>(pixels[$1].x, pixels[$1].y, pixels[$1].z)
    } / Float(cylinderInside.count)
    print("Grazing gold \(name) mean RGB: \(color)")
    require(color.y > color.x * 0.35 && color.y > color.z,
      "\(name): grazing gold interior stays gold rather than collapsing to red")
}
if metalFXAvailable {
    let cylinderRatio = metalFXEnergyRatio(cylinderFX, cylinderRaw, cylinderInside)
    print("Cylinder 64-frame MetalFX/raw energy: \(cylinderRatio)")
    require(cylinderRatio > 0.72, "MetalFX grazing-cylinder energy stays above its measured floor (0.77)")
}
// Depth 64 versus the default 16 on the same sample sequence: the paired difference
// isolates the energy of the extra bounces (measured +4.3% ± 0.6%). Fail only when the
// gain exceeds 5% by more than 3 standard errors, a one-sided test that noise cannot trip.
cylinder.cameraTarget.w = 64
let cylinderDeep = render(cylinder, samples: 64)
let cylinderBudget = pairedDifference(cylinderDeep, cylinderRaw, width: 240, pixels: cylinderInside)
let cylinderDeepMean = cylinderMean(cylinderDeep)
print("Cylinder energy gained from depth 16 to 64: \(cylinderBudget.mean / cylinderDeepMean) ± \(cylinderBudget.se / cylinderDeepMean)")
require(cylinderBudget.se < 0.01 * cylinderDeepMean, "cylinder budget comparison resolves 1% differences")
require(cylinderBudget.mean - 3 * cylinderBudget.se < 0.05 * cylinderDeepMean,
    "cylinder brightness is independent of a larger scattering budget")
savePreview([cylinderRaw, cylinderFX, cylinderDeep], width: 240, height: 160, name: "cylinder-grazing.png")
print("PASS: grazing cylinder interior, \(cylinderInside.count) pixels, raw/MetalFX/deep means \(cylinderMean(cylinderRaw))/\(cylinderMean(cylinderFX))/\(cylinderMean(cylinderDeep))")
