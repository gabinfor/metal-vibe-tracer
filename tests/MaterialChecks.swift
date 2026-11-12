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
        if (!sample_bsdf(m, n, -wo, !m.inside, seed, direction, weight, pdf, Wavelengths())) continue;
        ++valid; if (direction.z < 0) ++below;
        float3 expected = eval_bsdf(m, n, wo, direction, Wavelengths()) * abs(direction.z) / pdf;
        float combinedPdf;
        float3 combined = eval_bsdf_with_pdf(m,n,wo,direction,combinedPdf,Wavelengths()) * abs(direction.z) / pdf;
        maximumError = max(maximumError, length(combined - expected) / max(1.0f,length(expected)));
        pdfError = max(pdfError, abs(combinedPdf-pdf)/max(1e-5f,pdf));
        if (index == 6) {
            OpenPBR_PreparedBsdf full = prepare_openpbr(m,n,wo);
            float3 reference = openpbr_get_sum_of_diffuse_specular(openpbr_eval(full,direction)) / pdf;
            maximumError = max(maximumError, length(reference-expected)/max(1.0f,length(expected)));
            pdfError = max(pdfError,abs(openpbr_pdf(full,direction)-pdf)/max(1e-5f,pdf));
        }
        maximumError = max(maximumError, length(expected - weight) / max(1.0f, length(weight)));
        pdfError = max(pdfError, abs(pdf - eval_bsdf_pdf(m,n,wo,direction,Wavelengths())) / max(1e-5f,pdf));
    }
    out[index] = float4(maximumError, pdfError, float(valid), float(below));
}
kernel void texture_value_checks(device float4 *out [[buffer(0)]],
    constant MaterialResources &images [[buffer(2)]]) {
    TextureFootprint point = {}, whole = { float2(1, 0), float2(0, 1) };
    out[0] = sample_material_map(images, 1, 0, float2(0.25f), point);
    out[1] = sample_material_map(images, 1, 1, float2(0.25f), point);
    out[2] = sample_material_map(images, 1, 0, float2(1.25f), point);
    out[3] = sample_material_map(images, 1, 0, float2(0.25f), whole);
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
let fixtureDirectory = testOutputDirectory.appendingPathComponent("material-fixtures", isDirectory: true)
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

// Every mip level keeps level 0's linear mean, whatever the texture's size: noise over a brighter centre,
// which a filter that skips or under-weights texels of odd-sized levels moves at the coarse levels (Metal's
// own mip generation is off by 7–52% at the odd sizes' coarsest levels and by up to 0.85% at the power of two).
// sRGB means are taken as the mip filter defines them: each texel's 8-bit code decoded with the IEC formula.
let mipLibrary = try gpu.makeLibrary(source: """
    #include <metal_stdlib>
    using namespace metal;
    kernel void mip_row_sums(texture2d<float, access::read> image [[texture(0)]], device float4 *rows [[buffer(0)]],
        constant uint2 &options [[buffer(1)]], uint y [[thread_position_in_grid]]) {
        uint level = options.x, width = max(1u, image.get_width() >> level), height = max(1u, image.get_height() >> level);
        if (y >= height) return;
        float4 sum = 0;
        for (uint x = 0; x < width; ++x) {
            float4 texel = image.read(uint2(x, y), level);
            if (options.y != 0) {
                float3 v = texel.rgb;
                float3 c = rint(255.0f * select(1.055f * powr(v, 1.0f / 2.4f) - 0.055f, 12.92f * v, v <= 0.0031308f)) / 255.0f;
                texel.rgb = select(powr((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
            }
            sum += texel;
        }
        rows[y] = sum;
    }
    kernel void srgb_code_round_trip(texture2d<float, access::read> image [[texture(0)]], device float *codes [[buffer(0)]],
        uint x [[thread_position_in_grid]]) {
        float v = image.read(uint2(x, 0)).r;
        codes[x] = 255.0f * select(1.055f * powr(v, 1.0f / 2.4f) - 0.055f, 12.92f * v, v <= 0.0031308f);
    }
    """, options: nil)
let mipPipeline = try gpu.makeComputePipelineState(function: mipLibrary.makeFunction(name: "mip_row_sums")!)
// area_mipmap recovers each sRGB texel's code from the hardware decode; that must be exact for every code.
do {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 256, height: 1, mipmapped: false)
    descriptor.storageMode = .shared
    let ramp = gpu.makeTexture(descriptor: descriptor)!
    let bytes = (0..<256).flatMap { c -> [UInt8] in [UInt8(c), UInt8(c), UInt8(c), 255] }
    ramp.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 1024)
    let codes = gpu.makeBuffer(length: 1024, options: .storageModeShared)!
    let command = testRenderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(try gpu.makeComputePipelineState(function: mipLibrary.makeFunction(name: "srgb_code_round_trip")!))
    encoder.setTexture(ramp, index: 0); encoder.setBuffer(codes, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    let recovered = codes.contents().bindMemory(to: Float.self, capacity: 256)
    let worst = (0..<256).map { abs(recovered[$0] - Float($0)) }.max()!
    print(String(format: "sRGB code recovery from the hardware decode: worst %.3f codes", worst))
    require(worst < 0.45, "every 8-bit sRGB code is recovered from the hardware decode")
}
func mipFixture(width: Int, height: Int, bits: Int, gray: Bool = false, dark: Bool = false) -> Data {
    let channels = gray ? 2 : 3
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: bits, samplesPerPixel: channels, hasAlpha: gray, isPlanar: false,
        colorSpaceName: gray ? .deviceWhite : .deviceRGB, bytesPerRow: width * channels * bits / 8,
        bitsPerPixel: channels * bits)!
    let top = Double((1 << bits) - 1)
    for y in 0..<height { for x in 0..<width { for c in 0..<channels {
        let i = (y * width + x) * channels + c
        var h = UInt32(truncatingIfNeeded: i) &* 0x9E3779B1
        h ^= h >> 15; h = h &* 0x85EBCA77; h ^= h >> 13
        let centre = abs(2 * x - width) < width / 3 && abs(2 * y - height) < height / 3
        let noise = Double(h >> 8) / 16_777_216
        // Near black: codes 1–16, whose hardware sRGB decode is up to 20% off the IEC formula.
        let value = (dark ? 0.005 + 0.04 * noise + (centre ? 0.02 : 0) : 0.5 + 0.3 * noise + (centre ? 0.15 : 0)) * top
        if gray && c == 1 { bitmap.bitmapData![i] = 255; continue }
        if bits == 16 {
            bitmap.bitmapData!.withMemoryRebound(to: UInt16.self, capacity: width * height * channels) { $0[i] = UInt16(value) }
        } else { bitmap.bitmapData![i] = UInt8(value) }
    }}}
    return bitmap.representation(using: .png, properties: [:])!
}
func mipMeans(_ texture: MTLTexture) -> [SIMD3<Double>] {
    let srgb: Set<MTLPixelFormat> = [.rgba8Unorm_srgb, .bgra8Unorm_srgb, .r8Unorm_srgb, .rg8Unorm_srgb]
    return (0..<texture.mipmapLevelCount).map { level in
        let height = max(1, texture.height >> level)
        let rows = gpu.makeBuffer(length: height * 16, options: .storageModeShared)!
        var options = SIMD2<UInt32>(UInt32(level), srgb.contains(texture.pixelFormat) ? 1 : 0)
        let command = testRenderer.commandQueue.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(mipPipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(rows, offset: 0, index: 0)
        encoder.setBytes(&options, length: 8, index: 1)
        encoder.dispatchThreads(MTLSize(width: height, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        let sums = rows.contents().bindMemory(to: SIMD4<Float>.self, capacity: height)
        let total = (0..<height).reduce(SIMD3<Double>()) { $0 + SIMD3<Double>(Double(sums[$1].x), Double(sums[$1].y), Double(sums[$1].z)) }
        return total / Double(max(1, texture.width >> level) * height)
    }
}
// The 8-bit gray+alpha sRGB image takes MaterialLibrary.expandedSRGB (RGBA8 sRGB). A level of nearly uniform texels
// rounds them all alike, so an 8-bit level can be off by up to half a code: 0.5% is wider than that above code 100,
// and the near-black image (codes 1–16, where half a code is 3–50%) is held to half a code of level 0's mean instead.
let mipCases = try [("894² 8-bit sRGB", 894, 894, 8, true, false, false), ("300×200 16-bit sRGB", 300, 200, 16, true, false, false),
        ("300×200 8-bit linear", 300, 200, 8, false, false, false), ("300×200 8-bit gray+alpha sRGB", 300, 200, 8, true, true, false),
        ("894² 8-bit sRGB near black", 894, 894, 8, true, false, true),
        ("512² 8-bit sRGB (power-of-two control)", 512, 512, 8, true, false, false)]
    .map { name, width, height, bits, srgb, gray, dark in
        let texture = try testRenderer.materials.decodeTexture(
            mipFixture(width: width, height: height, bits: bits, gray: gray, dark: dark), srgb: srgb)
        let means = mipMeans(texture)
        let error = means.map { simd_reduce_max(simd_abs($0 / means[0] - 1)) }
        let code = { (v: SIMD3<Double>) in v.replacing(with: 12.92 * v, where: v .<= 0.0031308)
            .replacing(with: 1.055 * SIMD3(pow(v.x, 1 / 2.4), pow(v.y, 1 / 2.4), pow(v.z, 1 / 2.4)) - 0.055, where: v .> 0.0031308) * 255 }
        let codeError = means.map { simd_reduce_max(simd_abs(code($0) - code(means[0]))) }
        print("Mip mean error, \(name) (format \(texture.pixelFormat.rawValue)): "
            + zip(error, codeError).enumerated().map { String(format: "L%d %.3f%% (%.2f codes)", $0, $1.0 * 100, $1.1) }
                .joined(separator: " "))
        return (name, texture.mipmapLevelCount == Int(log2(Double(max(width, height)))) + 1,
            dark ? codeError.allSatisfy { $0 <= 0.5 } : error.allSatisfy { $0 <= 0.005 })
    }
for (name, chain, kept) in mipCases {
    require(chain, "full mip chain, \(name)")
    require(kept, "every mip level keeps level 0's mean within 0.5% (near black: half a code), \(name)")
}
print("PASS: mip levels keep the texture's mean at odd and power-of-two sizes, near black and through every decode path")

// KTX files: levels the file stores are kept (a full or a partial chain); a single stored level gets a filtered chain.
func ktxFixture(levels: Int) -> Data {
    var data = Data([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A])
    func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    // Endianness, GL_UNSIGNED_BYTE, type size 1, GL_RGBA, GL_RGBA8, GL_RGBA, 8 × 8, depth 0, 0 array elements, 1 face.
    for value: UInt32 in [0x0403_0201, 0x1401, 1, 0x1908, 0x8058, 0x1908, 8, 8, 0, 0, 1] { word(value) }
    word(UInt32(levels)); word(0)
    for level in 0..<levels {
        let side = 8 >> level
        word(UInt32(side * side * 4))
        data.append(contentsOf: (0..<(side * side * 4)).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ level * 50) })
    }
    return data
}
func levelBytes(_ texture: MTLTexture, _ level: Int) -> [UInt8] {
    let side = max(1, texture.width >> level)
    let buffer = gpu.makeBuffer(length: side * side * 4, options: .storageModeShared)!
    let command = testRenderer.commandQueue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: side, height: side, depth: 1),
        to: buffer, destinationOffset: 0, destinationBytesPerRow: side * 4, destinationBytesPerImage: side * side * 4)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt8.self, capacity: side * side * 4), count: side * side * 4))
}
for stored in [4, 2] {
    let file = ktxFixture(levels: stored)
    require(MaterialLibrary.ktxMipmapLevels(file) == stored, "KTX stored mip level count read")
    let texture = try testRenderer.materials.decodeTexture(file, srgb: false)
    require(texture.mipmapLevelCount == stored, "a KTX file's \(stored) stored levels make the chain")
    let level1 = levelBytes(texture, 1)
    require(level1 == (0..<level1.count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 50) }, "a KTX file's level 1 is kept (\(stored) levels)")
}
let singleKTX = try testRenderer.materials.decodeTexture(ktxFixture(levels: 1), srgb: false)
let single0 = levelBytes(singleKTX, 0), single1 = levelBytes(singleKTX, 1)
// Texel (0, 0) of level 1 averages texels (0, 0), (1, 0), (0, 1) and (1, 1) of level 0, channel by channel.
let boxed = (0..<4).map { c in Int(([0, 4, 32, 36].map { Double(single0[$0 + c]) }.reduce(0, +) / 4).rounded()) }
require(singleKTX.mipmapLevelCount == 4 && zip(boxed, single1.prefix(4)).allSatisfy { abs($0 - Int($1)) <= 1 },
    "a single-level KTX gets a box-filtered chain (\(boxed), \(Array(single1.prefix(4))))")
print("PASS: KTX mip levels: stored levels kept, a single level filtered")

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
if let fx = testRenderer.metalFX {
    let materialGuides = readTexture(fx.diffuse)
    require(materialGuides.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "finite textured MetalFX guides")
}
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
