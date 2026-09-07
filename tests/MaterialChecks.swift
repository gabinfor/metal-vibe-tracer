// Appended after GPUChecks.swift; tests the real adapter, loader, and Metal kernels.
require(MemoryLayout<SurfaceSettings>.stride == 64, "Swift/Metal material layout")
let adapterChecks = """
kernel void openpbr_adapter_checks(device float4 *out [[buffer(0)]], uint index [[thread_position_in_grid]]) {
    if (index >= 7) return;
    Material m = { OPENPBR, float3(0.8f,0.5f,0.2f), float3(0), 0.4f, 1.52f };
    m.metalness = index == 0 ? 1.0f : 0.0f;
    m.coat = index == 1 ? 1.0f : 0.0f;
    m.fuzz = index == 2 ? 0.8f : 0.0f;
    m.anisotropy = index == 3 ? 0.8f : 0.0f;
    m.transmission = (index == 4 || index == 5) ? 1.0f : 0.0f;
    m.inside = index == 5;
    if (index == 6) m.type = DIFFUSE;
    float3 n = float3(0,0,1), wo = normalize(float3(0.6f,0,0.8f));
    uint seed = index + 291;
    float maximumError = 0, pdfError = 0; uint valid = 0, below = 0;
    for (int i = 0; i < 4096; ++i) {
        float3 direction, weight; float pdf;
        if (!sample_bsdf(m, n, -wo, !m.inside, seed, direction, weight, pdf)) continue;
        ++valid; if (direction.z < 0) ++below;
        float3 expected = eval_bsdf(m, n, wo, direction) * abs(direction.z) / pdf;
        float combinedPdf;
        float3 combined = eval_bsdf_with_pdf(m,n,wo,direction,combinedPdf) * abs(direction.z) / pdf;
        maximumError = max(maximumError, length(combined - expected) / max(1.0f,length(expected)));
        pdfError = max(pdfError, abs(combinedPdf-pdf)/max(1e-5f,pdf));
        if (index == 6) {
            OpenPBR_PreparedBsdf full = prepare_openpbr(m,n,wo);
            float3 reference = openpbr_get_sum_of_diffuse_specular(openpbr_eval(full,direction)) / pdf;
            maximumError = max(maximumError, length(reference-expected)/max(1.0f,length(expected)));
            pdfError = max(pdfError,abs(openpbr_pdf(full,direction)-pdf)/max(1e-5f,pdf));
        }
        maximumError = max(maximumError, length(expected - weight) / max(1.0f, length(weight)));
        pdfError = max(pdfError, abs(pdf - eval_bsdf_pdf(m,n,wo,direction)) / max(1e-5f,pdf));
    }
    out[index] = float4(maximumError, pdfError, float(valid), float(below));
}
kernel void texture_value_checks(device float4 *out [[buffer(0)]],
    constant MaterialResources &images [[buffer(2)]]) {
    out[0] = sample_material_map(images, 1, 0, float2(0.25f), float2(1), 0);
    out[1] = sample_material_map(images, 1, 1, float2(0.25f), float2(1), 0);
    out[2] = sample_material_map(images, 1, 0, float2(1.25f), float2(1), 0);
    out[3] = sample_material_map(images, 1, 0, float2(0.25f), float2(1), 1);
}
"""
let adapterLibrary = try gpu.makeLibrary(source: metalSource + adapterChecks, options: shaderCompileOptions())
let adapterPipeline = try gpu.makeComputePipelineState(function: adapterLibrary.makeFunction(name: "openpbr_adapter_checks")!)
let adapterOutput = gpu.makeBuffer(length: 7 * 16, options: .storageModeShared)!
let adapterCommand = testRenderer.commandQueue.makeCommandBuffer()!
let adapterEncoder = adapterCommand.makeComputeCommandEncoder()!
adapterEncoder.setComputePipelineState(adapterPipeline)
adapterEncoder.setBuffer(adapterOutput, offset: 0, index: 0)
adapterEncoder.dispatchThreads(MTLSize(width: 7, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 7, height: 1, depth: 1))
adapterEncoder.endEncoding(); adapterCommand.commit(); adapterCommand.waitUntilCompleted()
require(adapterCommand.status == .completed, "OpenPBR adapter GPU completion")
for i in 0..<7 {
    let value = adapterOutput.contents().load(fromByteOffset: i * 16, as: SIMD4<Float>.self)
    print("OpenPBR adapter case \(i): \(value)")
    require(value.x < 0.005 && value.y < 0.005 && value.z > 2000, "OpenPBR eval/sample/PDF agreement, case \(i)")
    if i == 4 || i == 5 { require(value.w > 100, "rough glass transmission is sampled") }
}

// Generated fixture files exercise the image loader, including sRGB mip generation.
let fixtureDirectory = URL(fileURLWithPath: "build/checks/material-fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
func materialFixture(_ name: String, _ pixel: (Int, Int) -> [UInt8]) throws -> URL {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 64 * 4, bitsPerPixel: 32)!
    for y in 0..<32 { for x in 0..<64 {
        let p = pixel(x,y)
        for c in 0..<4 { bitmap.bitmapData![(y * 64 + x) * 4 + c] = p[c] }
    }}
    let url = fixtureDirectory.appendingPathComponent(name + ".png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    return url
}
let grayMap = try materialFixture("gray") { _,_ in [128,128,128,255] }
let checkerMap = try materialFixture("checker") { x,y in ((x/8 + y/8) % 2 == 0) ? [230,180,60,255] : [20,60,180,255] }
let normalMap = try materialFixture("normal") { x,_ in x < 32 ? [180,128,240,255] : [76,128,240,255] }
try testRenderer.materials.load(url: grayMap, slot: 1, channel: 0)
try testRenderer.materials.load(url: grayMap, slot: 1, channel: 1)
require([MTLPixelFormat.rgba8Unorm_srgb, .bgra8Unorm_srgb].contains(testRenderer.materials.images[4].pixelFormat), "base color is sRGB")
require([MTLPixelFormat.rgba8Unorm, .bgra8Unorm].contains(testRenderer.materials.images[5].pixelFormat), "roughness remains linear")
require(testRenderer.materials.images[4].mipmapLevelCount > 1, "texture mip chain generated")
let valuePipeline = try gpu.makeComputePipelineState(function: adapterLibrary.makeFunction(name: "texture_value_checks")!)
let valueOutput = gpu.makeBuffer(length: 4 * 16, options: .storageModeShared)!
let valueCommand = testRenderer.commandQueue.makeCommandBuffer()!
let valueEncoder = valueCommand.makeComputeCommandEncoder()!
valueEncoder.setComputePipelineState(valuePipeline)
testRenderer.materials.bind(valueEncoder)
valueEncoder.setBuffer(valueOutput, offset: 0, index: 0)
valueEncoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
valueEncoder.endEncoding(); valueCommand.commit(); valueCommand.waitUntilCompleted()
require(valueCommand.status == .completed, "texture sampling GPU completion")
let sampled = (0..<4).map { valueOutput.contents().load(fromByteOffset: $0*16, as: SIMD4<Float>.self) }
require(abs(sampled[0].x - 0.21586) < 0.002 && abs(sampled[1].x - 0.50196) < 0.002, "sRGB color versus linear data decode")
require(simd_length(sampled[0] - sampled[2]) < 0.001, "texture repeat wrapping")
require(abs(sampled[3].x - sampled[0].x) < 0.002, "constant-color mip values stay linear")
let previousImage = testRenderer.materials.images[4]
do {
    try testRenderer.materials.load(url: fixtureDirectory.appendingPathComponent("missing.png"), slot: 1, channel: 0)
    require(false, "missing texture reports error")
} catch { require(testRenderer.materials.images[4] === previousImage, "failed load preserves current texture") }
for channel in 0..<4 { try testRenderer.materials.clear(slot: 1, channel: channel) }

// Real scene: textured floor, reflected by chrome and gold, and mapped rough copper.
var materialView = makeUniforms(scene: 0, mode: 0, width: 240, height: 180)
let materialEye = SIMD3<Float>(1.4,0.9,-1.3), materialTarget = SIMD3<Float>(0.2,-0.45,0.9)
materialView.cameraPos = SIMD4<Float>(materialEye, 52)
materialView.cameraTarget = SIMD4<Float>(materialTarget, 16)
materialView.currentViewProj = makePerspective(fovyRadians: 52 * .pi / 180, aspect: 4.0/3.0, near: 0.05, far: 100)
    * makeLookAt(eye: materialEye, target: materialTarget, up: SIMD3<Float>(0,1,0))
materialView.prevViewProj = materialView.currentViewProj
let materialBaseline = render(materialView, samples: 32)
try testRenderer.materials.load(url: checkerMap, slot: 1, channel: 0)
testRenderer.materials.settings[1].detail.w = 12
let mappedFloor = render(materialView, samples: 32)
let mappedNormals = lastNormals
let reflectionMask = mappedNormals.indices.filter { Int(mappedNormals[$0].w) == 1 }
let reflectionDelta = reflectionMask.reduce(Float(0)) { $0 + simd_length(mappedFloor[$1] - materialBaseline[$1]) } / Float(max(1, reflectionMask.count))
require(reflectionDelta > 0.01, "floor texture appears in secondary reflections")
try testRenderer.materials.load(url: grayMap, slot: 2, channel: 1)
try testRenderer.materials.load(url: normalMap, slot: 2, channel: 3)
try testRenderer.materials.load(url: grayMap, slot: 2, channel: 2)
var copperSettings = SurfaceSettings()
copperSettings.enabled = 1; copperSettings.mapMask = 14
copperSettings.color = SIMD4<Float>(0.95,0.64,0.54,1)
copperSettings.surface = SIMD4<Float>(0.2,1,0.6,0.5)
testRenderer.materials.settings[2] = copperSettings
let materialRaw = render(materialView, samples: 32, denoise: true)
let materialFiltered = lastDisplay
require(lastNormals.contains { Int($0.w) == 4 }, "OpenPBR materials reach the primary G-buffer")
let materialGuides = readTexture(testRenderer.metalFX!.diffuse)
require(materialGuides.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "finite textured MetalFX guides")
savePreview([materialBaseline, materialRaw, materialFiltered], width: 240, height: 180, name: "openpbr-textures.png")

// Parameter coverage through production kernels, plus transmitting surfaces.
for mode in UInt32(0)...3 {
    var study = makeUniforms(scene: 0, mode: mode, width: 48, height: 36)
    study.skyMode = 1
    for preset in 0..<4 {
        var setting = SurfaceSettings(); setting.enabled = 1
        setting.color = SIMD4<Float>(0.8,0.5,0.2,1)
        setting.surface = SIMD4<Float>(0.3, preset == 0 ? 1 : 0, preset == 1 ? 1 : 0, 0.5)
        setting.detail.x = preset == 2 ? 0.8 : 0
        setting.detail.z = preset == 3 ? 1 : 0
        testRenderer.materials.settings[4] = setting
        let result = render(study, samples: 8)
        require(mean(result) > 0.01, "OpenPBR preset \(preset), strategy \(mode)")
    }
}
testRenderer.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
print("PASS: OpenPBR adapters, material presets, texture decoding/mips/repeat, failed-load preservation, secondary reflections, and MetalFX")
