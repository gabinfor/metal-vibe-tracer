// Runs the generated SpectralTables.metal include on the GPU for tests/SpectralTables.py.
// Usage: SpectralGPU <SpectralTables.metal> <moments.bin> <samples.bin> <output-directory>
// moments.bin: n x ushort4 (quantized c0, c1, c2, unused); samples.bin: n x (float u, uint illuminant).
// Writes colour.bin (n x float4 linear sRGB under D65, float32 1 nm sums), lagrange.bin
// (n x float4) and wavelength.bin (n x float2 lambda, pdf).
import Foundation
import Metal

let kernels = """
kernel void spectral_colour(device const ushort4 *moments [[buffer(0)]], device float4 *colour [[buffer(1)]],
                            device float4 *lagrangeOut [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    float3 lagrange = vibe_fourier_lagrange(vibe_decode_fourier_moments(moments[id].xyz));
    float3 xyz = float3(0.0f);
    for (uint i = 0; i < VIBE_SPECTRAL_SAMPLES; ++i) {
        float lambda = VIBE_LAMBDA_MIN + float(i);
        float g = vibe_fourier_reflectance(lagrange, vibe_fourier_phase(lambda));
        xyz += g * vibe_illuminant_spd[VIBE_ILLUMINANT_D65][i] * vibe_cmf_xyz(lambda);
    }
    colour[id] = float4(vibe_xyz_to_linear_srgb(xyz), 0.0f);
    lagrangeOut[id] = float4(lagrange, 0.0f);
}
kernel void spectral_sample(device const float2 *inputs [[buffer(0)]], device float2 *outputs [[buffer(1)]],
                            uint id [[thread_position_in_grid]]) {
    float pdf;
    float lambda = vibe_sample_wavelength(as_type<uint>(inputs[id].y), inputs[id].x, pdf);
    outputs[id] = float2(lambda, pdf);
}
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else { fail("usage: SpectralGPU include moments samples output") }
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fail("no Metal device") }
let include = try String(contentsOfFile: arguments[1], encoding: .utf8)
let options = MTLCompileOptions()
options.mathMode = .relaxed  // as shaderCompileOptions() in main.swift
let library: MTLLibrary
do { library = try device.makeLibrary(source: include + kernels, options: options) } catch { fail("compile: \(error)") }
let moments = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let samples = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
let output = URL(fileURLWithPath: arguments[4])

func buffer(_ data: Data) -> MTLBuffer {
    data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(data.count, 16), options: .storageModeShared)! }
}

func run(_ name: String, _ buffers: [MTLBuffer], _ count: Int) {
    guard let function = library.makeFunction(name: name),
          let pipeline = try? device.makeComputePipelineState(function: function),
          let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { fail("pipeline \(name)") }
    encoder.setComputePipelineState(pipeline)
    for (index, item) in buffers.enumerated() { encoder.setBuffer(item, offset: 0, index: index) }
    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    if let error = commands.error { fail("\(name): \(error)") }
}

let colourCount = moments.count / 8
let colour = device.makeBuffer(length: max(colourCount * 16, 16), options: .storageModeShared)!
let lagrange = device.makeBuffer(length: max(colourCount * 16, 16), options: .storageModeShared)!
run("spectral_colour", [buffer(moments), colour, lagrange], colourCount)
let sampleCount = samples.count / 8
let wavelengths = device.makeBuffer(length: max(sampleCount * 8, 16), options: .storageModeShared)!
run("spectral_sample", [buffer(samples), wavelengths], sampleCount)
try Data(bytes: colour.contents(), count: colourCount * 16).write(to: output.appendingPathComponent("colour.bin"))
try Data(bytes: lagrange.contents(), count: colourCount * 16).write(to: output.appendingPathComponent("lagrange.bin"))
try Data(bytes: wavelengths.contents(), count: sampleCount * 8).write(to: output.appendingPathComponent("wavelength.bin"))
print("SpectralGPU: \(colourCount) colours, \(sampleCount) wavelength samples on \(device.name)")
