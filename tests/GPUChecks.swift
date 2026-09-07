// Appended to production definitions by verify.py; no copied renderer implementation.
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
guard let gpu = MTLCreateSystemDefaultDevice() else {
    fputs("GPU tests require access to a Metal device.\n", stderr)
    exit(2)
}
let testRenderer = try PathTracerRenderer(device: gpu)
require(MemoryLayout<Uniforms>.stride == 288, "Swift/Metal uniform layout")
print("PASS: runtime shader compilation on \(gpu.name)")

let checks = """
kernel void regression_checks(device uint *results [[buffer(0)]], constant Uniforms &u [[buffer(1)]], constant MaterialResources &materialImages [[buffer(2)]]) {
    Material matte = { DIFFUSE, float3(0.8f), float3(0), 0.0f, 1.0f };
    HitRecord hit;
    Ray inside = { float3(0), float3(1, 0, 0) };
    results[0] = intersect_box(inside, float3(0), float3(1), 0, matte, 0.001f, 100, hit)
        && abs(hit.t - 1.0f) < 1e-5f && !hit.front_face && hit.normal.x < -0.99f;
    Ray parallel = { float3(2, 0, 0), float3(0, 1, 0) };
    results[1] = !intersect_box(parallel, float3(0), float3(1), 0, matte, 0.001f, 100, hit);
    uint seed = 17;
    bool bounded = true;
    for (int i = 0; i < 100000; ++i) { float v = rand_f(seed); bounded = bounded && v >= 0.0f && v < 1.0f; }
    results[2] = bounded;
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
}
"""
func makeUniforms(scene: UInt32, mode: UInt32, width: Int, height: Int, fog: UInt32 = 0) -> Uniforms {
    testRenderer.sceneIndex = scene
    let r = testRenderer
    let eye = r.target + SIMD3<Float>(r.distance * cos(r.pitch) * sin(r.yaw),
        r.distance * sin(r.pitch), -r.distance * cos(r.pitch) * cos(r.yaw))
    let vp = makePerspective(fovyRadians: r.fov * .pi / 180, aspect: Float(width) / Float(height), near: 0.05, far: 100)
        * makeLookAt(eye: eye, target: r.target, up: SIMD3<Float>(0, 1, 0))
    return Uniforms(cameraPos: SIMD4<Float>(eye, r.fov), cameraTarget: SIMD4<Float>(r.target, 16),
        cameraUp: SIMD4<Float>(0, 1, 0, 0), sunParams: SIMD4<Float>(0.65, 0.45, -0.60, 850),
        currentViewProj: vp, prevViewProj: vp, frameIndex: 1, sceneIndex: scene, samplingMode: mode,
        enableSMS: 0, skyMode: 0, enableFog: fog, viewportMode: 0, width: UInt32(width), height: UInt32(height))
}
let library = try gpu.makeLibrary(source: metalSource + checks, options: shaderCompileOptions())
let checkPipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "regression_checks")!)
let results = gpu.makeBuffer(length: 8 * 4, options: .storageModeShared)!
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
let names = ["inside-box exit", "parallel-box miss", "random endpoints", "small-PDF MIS", "glass total internal reflection", "emission weighting", "sphere emitter endpoints", "finite-roughness grazing cylinder"]
for i in 0..<8 { require(results.contents().load(fromByteOffset: i * 4, as: UInt32.self) == 1, names[i]) }
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

func readTexture(_ texture: MTLTexture) -> [SIMD4<Float>] {
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

func render(_ input: Uniforms, samples: Int, denoise: Bool = false, orbit: Bool = false) -> [SIMD4<Float>] {
    testRenderer.resetAccumulation()
    testRenderer.denoiserEnabled = denoise
    lastResets = []
    var u = input
    var accumulationFrames: UInt32 = 0
    let w = Int(u.width), h = Int(u.height)
    func texture(_ format: MTLPixelFormat) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
        return gpu.makeTexture(descriptor: d)!
    }
    var pos = texture(.rgba32Float), previousPos = texture(.rgba32Float)
    var normal = texture(.rgba16Float), previousNormal = texture(.rgba16Float)
    let albedo = texture(.rgba16Float), accum = texture(.rgba32Float), noisy = texture(.rgba32Float), output = texture(.rgba32Float)
    var current = (0..<3).map { _ in texture(.rgba32Float) }
    var history = (0..<3).map { _ in texture(.rgba32Float) }
    var giCurrent = [texture(.rgba32Float), texture(.rgba16Float), texture(.rgba32Float), texture(.rgba32Float)]
    var giHistory = [texture(.rgba32Float), texture(.rgba16Float), texture(.rgba32Float), texture(.rgba32Float)]
    let oidnAlbedo = texture(.rgba32Float), oidnNormal = texture(.rgba32Float)
    var display = accum
    for frame in 1...samples {
        u.prevViewProj = u.currentViewProj
        if orbit && frame > 1 {
            u.cameraPos.x += 0.025
            let eye = SIMD3<Float>(u.cameraPos.x, u.cameraPos.y, u.cameraPos.z)
            let target = SIMD3<Float>(u.cameraTarget.x, u.cameraTarget.y, u.cameraTarget.z)
            u.currentViewProj = makePerspective(fovyRadians: u.cameraPos.w * .pi / 180,
                aspect: Float(w) / Float(h), near: 0.05, far: 100) * makeLookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
            accumulationFrames = 0
            testRenderer.resetAccumulation(resetDenoiser: false)
        }
        accumulationFrames += 1
        u.frameIndex = accumulationFrames
        u.sampleIndex = UInt32(frame)
        u.jitter = frameJitter(u.sampleIndex)
        let cb = testRenderer.commandQueue.makeCommandBuffer()!
        let e1 = cb.makeComputeCommandEncoder()!
        e1.setComputePipelineState(testRenderer.restirTemporalPipeline)
        let first = [pos, normal, albedo] + current + history + [previousPos, previousNormal]
            + giCurrent + giHistory
        for (i, t) in first.enumerated() { e1.setTexture(t, index: i) }
        testRenderer.materials.bind(e1)
        e1.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e1.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        e1.endEncoding()
        let e2 = cb.makeComputeCommandEncoder()!
        e2.setComputePipelineState(testRenderer.shadingPipeline)
        let second = [pos, normal, albedo] + current + [accum, noisy] + giCurrent
            + [oidnAlbedo, oidnNormal]
        for (i, t) in second.enumerated() { e2.setTexture(t, index: i) }
        testRenderer.materials.bind(e2)
        e2.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e2.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        e2.endEncoding()
        display = testRenderer.encodePresentation(commandBuffer: cb, accumulation: accum, samples: noisy,
            positions: pos, normals: normal, materials: albedo, output: output, uniforms: u)!
        if denoise && u.samplingMode == 0 {
            require(testRenderer.lastPresentationUsedMetalFX, "native MetalFX is used, not a fallback")
            lastResets.append(testRenderer.lastMetalFXReset)
        }
        cb.commit(); cb.waitUntilCompleted()
        require(cb.status == .completed, "scene \(u.sceneIndex), strategy \(u.samplingMode): \(String(describing: cb.error))")
        lastDenoiseMilliseconds = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        swap(&pos, &previousPos); swap(&normal, &previousNormal); swap(&current, &history)
        swap(&giCurrent, &giHistory)
    }
    lastDisplay = readTexture(display)
    lastMaterials = readTexture(albedo)
    lastNormals = readTexture(previousNormal)
    lastPositions = readTexture(previousPos)
    lastSamples = readTexture(noisy)
    lastGIWeights = readTexture(giHistory[3])
    if denoise && u.samplingMode == 0 { lastMotion = readTexture(testRenderer.metalFX!.motion) }
    require(lastDisplay.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "finite denoised image")
    let pixels = readTexture(accum)
    require(pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.x >= 0 && $0.y >= 0 && $0.z >= 0 }, "finite nonnegative pixels")
    return pixels
}
func mean(_ pixels: [SIMD4<Float>]) -> Float {
    pixels.reduce(Float(0)) { $0 + ($1.x + $1.y + $1.z) / 3 } / Float(pixels.count)
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
                return UInt8(pow(max(0, min(1, a / b)), 1 / Float(2.2)) * 255)
            }
            for sy in 0..<scale { for sx in 0..<scale {
                let index = ((y * scale + sy) * totalWidth + (panel * width + x) * scale + sx) * 4
                bytes[index] = color[0]; bytes[index+1] = color[1]; bytes[index+2] = color[2]; bytes[index+3] = 255
            }}
        }}
    }
    let directory = URL(fileURLWithPath: "build/checks", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}

for scene in UInt32(0)...5 {
    for mode in UInt32(0)...3 {
        let pixels = render(makeUniforms(scene: scene, mode: mode, width: 49, height: 33), samples: 8)
        require(mean(pixels) > 0.001, "nonblack scene \(scene), strategy \(mode)")
    }
}
print("PASS: all six scenes and four strategies at a non-threadgroup-aligned size")
var lightView = makeUniforms(scene: 1, mode: 1, width: 3, height: 3)
lightView.cameraPos = SIMD4<Float>(0, 0.5, 0, 10)
lightView.cameraTarget = SIMD4<Float>(0, 0.999, 0, 16)
lightView.cameraUp = SIMD4<Float>(0, 0, 1, 0)
let lightPixels = render(lightView, samples: 1)
require(abs(lightPixels[4].x - 18) < 0.02 && abs(lightPixels[4].y - 15) < 0.02, "primary visible emission survives G-buffer")
let clear = render(makeUniforms(scene: 4, mode: 1, width: 49, height: 33), samples: 16)
let fog = render(makeUniforms(scene: 4, mode: 1, width: 49, height: 33, fog: 1), samples: 16)
require(abs(mean(clear) - mean(fog)) > 0.001, "fog toggle changes rendered output")
print("PASS: visible emitter radiance and fog toggle")
var energy = [Float]()
for mode in UInt32(0)...3 {
    energy.append(mean(render(makeUniforms(scene: 1, mode: mode, width: 48, height: 32), samples: 128)))
}
print("Cornell mean radiance (ReSTIR, MIS, NEE, BSDF): \(energy)")
require(abs(energy[1] - energy[2]) / energy[1] < 0.12, "MIS and NEE agree in mean radiance")
require(abs(energy[1] - energy[3]) / energy[1] < 0.18, "MIS and BSDF agree in mean radiance")
// ReSTIR uses approximate reuse; guard against major energy regressions.
require(abs(energy[0] - energy[1]) / energy[1] < 0.25, "ReSTIR energy sanity")
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
    float sum = 0, maxWeight = 0, oldSum = 0, quadrature = 0;
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
        // Previous normalized Phong model, for a direct grazing-angle regression.
        float exponent = max(0.0f, 2.0f / (roughness * roughness + 1e-5f) - 2.0f);
        float cosTheta = pow(1.0f - rand_f(seed), 1.0f / (exponent + 1.0f));
        float azimuth = TWO_PI * rand_f(seed);
        float3 reflection = reflect(-wo, normal), t, b;
        make_basis(reflection, t, b);
        float3 oldDirection = t * cos(azimuth) * sqrt(1.0f - cosTheta*cosTheta) +
            b * sin(azimuth) * sqrt(1.0f - cosTheta*cosTheta) + reflection * cosTheta;
        oldSum += (exponent + 2.0f) / (exponent + 1.0f) * max(0.0f, oldDirection.z);
    }
    results[id] = float4(sum / 65536.0f, maxWeight, oldSum / 65536.0f, quadrature / 65536.0f);
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
    if i == 8 {
        print("White furnace, roughness 0.1 at N·V=0.05: old=\(r.z), GGX=\(r.x)")
        require(r.x > 0.85 && r.z < 0.12, "grazing black-rim regression")
    }
}
print("PASS: 20 angular/roughness energy cases and independent BRDF integration")

let denoiseUniforms = makeUniforms(scene: 1, mode: 0, width: 128, height: 96)
let lowSamples = render(denoiseUniforms, samples: 4)
require(lastGIWeights.contains { $0.y > 0 && $0.z > 0 }, "first-bounce ReSTIR GI produces valid reservoirs")
let rawDisplay = lastDisplay
let lowWithFilter = render(denoiseUniforms, samples: 4, denoise: true)
require(lastResets == [true, false, false, false], "stationary MetalFX temporal history")
require(lastMotion.allSatisfy { abs($0.x) < 0.001 && abs($0.y) < 0.001 }, "jitter is excluded from static motion vectors")
let filtered = lastDisplay
require(lowSamples == lowWithFilter && rawDisplay == lowSamples, "denoise does not alter raw accumulation")
let reference = render(denoiseUniforms, samples: 256)
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
            result[c] = pow(max(0, min(1, mapped)), 1 / Float(2.2))
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
print("MetalFX display error ratio: \(displayFilteredError / displayRawError)")
require(displayFilteredError < displayRawError * 0.8, "MetalFX reduces low-sample displayed image error")
savePreview([lowSamples, filtered, reference], width: 128, height: 96, name: "denoiser-check.png")
let bypass = render(makeUniforms(scene: 0, mode: 1, width: 47, height: 31), samples: 2, denoise: true)
require(bypass == lastDisplay, "non-ReSTIR denoiser bypass")
_ = render(makeUniforms(scene: 0, mode: 0, width: 64, height: 48), samples: 2, denoise: true)
print("PASS: raw invariance, non-ReSTIR bypass, and resize")

// Check the motion/history contract while the camera moves, then an explicit cut.
_ = render(makeUniforms(scene: 0, mode: 0, width: 128, height: 96), samples: 4, denoise: true, orbit: true)
require(lastResets == [true, false, false, false], "orbit preserves MetalFX history")
require(lastMotion.contains { abs($0.x) + abs($0.y) > 0.01 }, "camera movement produces pixel motion vectors")
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
pavilion.currentViewProj = makePerspective(fovyRadians: 50 * .pi / 180, aspect: 320.0 / 240.0, near: 0.05, far: 100)
    * makeLookAt(eye: previewEye, target: previewTarget, up: SIMD3<Float>(0, 1, 0))
pavilion.prevViewProj = pavilion.currentViewProj
let pavilionRaw = render(pavilion, samples: 8, denoise: true)
let pavilionFiltered = lastDisplay
print("320x240 render + MetalFX GPU time: \(lastDenoiseMilliseconds) ms")
let pavilionReference = render(pavilion, samples: 128)
savePreview([pavilionRaw, pavilionFiltered, pavilionReference], width: 320, height: 240, name: "pavilion-check.png")

// Check reflection guides and quantify specular-region quality against the same view.
let pavilionRaw32 = render(pavilion, samples: 32, denoise: true)
let metalFXReflection = lastDisplay
let reflectionNormals = lastNormals
let specularHits = readTexture(testRenderer.metalFX!.hitDistance)
let roughnessGuide = readTexture(testRenderer.metalFX!.roughness)
let specularGuide = readTexture(testRenderer.metalFX!.specular)
let diffuseGuide = readTexture(testRenderer.metalFX!.diffuse)
let types = reflectionNormals.map { Int($0.w) }
let specularIndices = types.indices.filter { types[$0] == 1 || types[$0] == 2 }
require(!specularIndices.isEmpty, "preview contains reflective surfaces")
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
cylinder.currentViewProj = makePerspective(fovyRadians: 30 * .pi / 180, aspect: 1.5, near: 0.05, far: 100)
    * makeLookAt(eye: cylinderEye, target: cylinderTarget, up: SIMD3<Float>(0, 1, 0))
cylinder.prevViewProj = cylinder.currentViewProj
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
for (name, pixels) in [("raw", cylinderRaw), ("MetalFX", cylinderFX)] {
    let lit = cylinderInside.filter { max(pixels[$0].x, max(pixels[$0].y, pixels[$0].z)) > 0.05 }.count
    require(Float(lit) / Float(cylinderInside.count) > 0.95, "\(name): grazing cylinder interior receives light")
    let color = cylinderInside.reduce(SIMD3<Float>(repeating: 0)) {
        $0 + SIMD3<Float>(pixels[$1].x, pixels[$1].y, pixels[$1].z)
    } / Float(cylinderInside.count)
    print("Grazing gold \(name) mean RGB: \(color)")
    require(color.y > color.x * 0.35 && color.y > color.z,
      "\(name): grazing gold interior stays gold rather than collapsing to red")
}
cylinder.cameraTarget.w = 64
let cylinderDeep = render(cylinder, samples: 64)
let cylinderRelativeError = abs(cylinderMean(cylinderRaw) - cylinderMean(cylinderDeep)) / cylinderMean(cylinderDeep)
require(cylinderRelativeError < 0.05, "cylinder brightness is independent of a larger scattering budget")
savePreview([cylinderRaw, cylinderFX, cylinderDeep], width: 240, height: 160, name: "cylinder-grazing.png")
print("PASS: grazing cylinder interior, \(cylinderInside.count) pixels, raw/MetalFX/deep means \(cylinderMean(cylinderRaw))/\(cylinderMean(cylinderFX))/\(cylinderMean(cylinderDeep))")
