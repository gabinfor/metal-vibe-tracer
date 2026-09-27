#!/usr/bin/env python3
"""GPU timing of the production renderFrame path on fixed scenes, optionally interleaved
with the shaders of a previous main.swift compiled against the current host code.

Usage: python3 tests/benchmark.py [--baseline /path/to/previous/main.swift] [--report FILE]
                                  [--frames 12] [--rounds 2] [--output-tolerance 0.05]

Timings are median GPU command-buffer times (tracing, MetalFX and display, no readback)
of each run's frames after the first four. A baseline is accepted only when its Uniforms
size and field offsets, material argument-buffer length and kernel bindings match what
the current host code binds, and each scenario's mean raw radiance agrees with the current
shaders within --output-tolerance; otherwise no timings are printed.
"""
from pathlib import Path
import argparse
import datetime
import os
import platform
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--baseline', type=Path, help='previous main.swift whose shaders are compared')
parser.add_argument('--report', type=Path, help='also write the raw report to this file')
parser.add_argument('--frames', type=int, default=12)
parser.add_argument('--rounds', type=int, default=2)
parser.add_argument('--output-tolerance', type=float, default=0.05)
arguments = parser.parse_args()
if arguments.frames < 6 or arguments.rounds < 1:
    raise SystemExit('benchmark.py: need at least 6 frames and one round')

root = harness.ROOT
source = harness.production_source()
source = harness.replace_once(source, 'let metalSource = loadOpenPBRSource()', 'var metalSource = loadOpenPBRSource()', 'main.swift')
source = harness.replace_once(source, 'options.mathMode = .relaxed', 'options.mathMode = benchmarkSafeMath ? .safe : .relaxed', 'main.swift')
source = harness.replace_once(source, 'func shaderCompileOptions()', 'var benchmarkSafeMath = false\nfunc shaderCompileOptions()', 'main.swift')
helpers = harness.replace_once(harness.gpu_helpers(), 'let testRenderer = try PathTracerRenderer(device: gpu)',
                               'var testRenderer = try PathTracerRenderer(device: gpu)', 'tests/GPUChecks.swift')
baseline_shader, baseline_safe = '', False
if arguments.baseline:
    previous = arguments.baseline.read_text()
    marker = 'let metalSource = loadOpenPBRSource() + """\n'
    if previous.count(marker) != 1:
        raise SystemExit(f'{arguments.baseline}: expected one embedded shader starting with {marker!r}')
    baseline_shader = previous.split(marker, 1)[1].split('\n"""', 1)[0]
    baseline_safe = 'options.mathMode = .safe' in previous
driver = r'''
let current = testRenderer
let frames = Int(CommandLine.arguments[2])!, rounds = Int(CommandLine.arguments[3])!
let outputTolerance = Float(CommandLine.arguments[4])!
var renderers = [("current", current)]
if !CommandLine.arguments[1].isEmpty {
    let optimizedShader = metalSource
    metalSource = loadOpenPBRSource() + (try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))
    benchmarkSafeMath = CommandLine.arguments[5] == "safe"
    let baselineLibrary: MTLLibrary
    do { baselineLibrary = try gpu.makeLibrary(source: metalSource, options: shaderCompileOptions()) }
    catch { fputs("INCOMPATIBLE: the baseline shaders do not compile with the current OpenPBR resources: \(error)\n", stderr); exit(3) }
    // Uniforms layout, material argument buffer and every binding the baseline kernels read.
    let fields = ["cameraPos", "cameraTarget", "cameraUp", "sunParams", "currentViewProj", "prevViewProj", "frameIndex",
        "sceneIndex", "samplingMode", "enableSMS", "skyMode", "enableFog", "viewportMode", "width", "height", "jitter",
        "sampleIndex", "reservoirHistoryReset", "reservoirHistory", "environment", "lens", "light"]
    let paths: [PartialKeyPath<Uniforms>] = [\Uniforms.cameraPos, \Uniforms.cameraTarget, \Uniforms.cameraUp, \Uniforms.sunParams,
        \Uniforms.currentViewProj, \Uniforms.prevViewProj, \Uniforms.frameIndex, \Uniforms.sceneIndex, \Uniforms.samplingMode,
        \Uniforms.enableSMS, \Uniforms.skyMode, \Uniforms.enableFog, \Uniforms.viewportMode, \Uniforms.width, \Uniforms.height,
        \Uniforms.jitter, \Uniforms.sampleIndex, \Uniforms.reservoirHistoryReset, \Uniforms.reservoirHistory,
        \Uniforms.environment, \Uniforms.lens, \Uniforms.light]
    let expected = [MemoryLayout<Uniforms>.stride] + paths.map { MemoryLayout<Uniforms>.offset(of: $0)! }
    let probe = "kernel void benchmark_layout(device uint *out [[buffer(0)]]) { Uniforms v; out[0] = sizeof(Uniforms);"
        + fields.enumerated().map { " out[\($0.offset + 1)] = uint((thread char *)&v.\($0.element) - (thread char *)&v);" }.joined() + " }"
    func layout(_ shader: String) -> [Int]? {
        guard let library = try? gpu.makeLibrary(source: shader + probe, options: shaderCompileOptions()),
              let function = library.makeFunction(name: "benchmark_layout"),
              let pipeline = try? gpu.makeComputePipelineState(function: function),
              let buffer = gpu.makeBuffer(length: expected.count * 4, options: .storageModeShared),
              let command = current.commandQueue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        return (0..<expected.count).map { Int(buffer.contents().load(fromByteOffset: $0 * 4, as: UInt32.self)) }
    }
    guard let baselineLayout = layout(metalSource) else {
        fputs("INCOMPATIBLE: the baseline MSL Uniforms lacks fields the host writes (\(fields.joined(separator: ", ")))\n", stderr)
        exit(3)
    }
    guard baselineLayout == expected else {
        fputs("INCOMPATIBLE: baseline Uniforms layout \(baselineLayout) differs from the host's \(expected) (size, then \(fields.joined(separator: ", ")))\n", stderr)
        exit(3)
    }
    func bindings(_ library: MTLLibrary, _ name: String) -> Set<String>? {
        guard let function = library.makeFunction(name: name) else { return nil }
        var reflection: MTLComputePipelineReflection?
        guard (try? gpu.makeComputePipelineState(function: function, options: [.bindingInfo], reflection: &reflection)) != nil else { return nil }
        return Set((reflection?.bindings ?? []).map { "\($0.type.rawValue):\($0.index)" })
    }
    for kernel in ["restir_temporal_kernel", "shading_kernel", "metalfx_guides_kernel", "present_kernel", "pick_kernel"] {
        guard let old = bindings(baselineLibrary, kernel), let new = bindings(current.shaderLibrary, kernel), old.isSubset(of: new) else {
            fputs("INCOMPATIBLE: \(kernel) is missing or reads bindings the current host code does not provide\n", stderr); exit(3)
        }
    }
    let oldLength = baselineLibrary.makeFunction(name: "restir_temporal_kernel")!.makeArgumentEncoder(bufferIndex: 2).encodedLength
    let newLength = current.materialFunction.makeArgumentEncoder(bufferIndex: 2).encodedLength
    guard oldLength == newLength else {
        fputs("INCOMPATIBLE: material argument buffer is \(oldLength) B in the baseline, \(newLength) B now\n", stderr); exit(3)
    }
    let baseline = try PathTracerRenderer(device: gpu)
    metalSource = optimizedShader
    benchmarkSafeMath = false
    renderers.insert(("baseline", baseline), at: 0)
    print("Baseline layout: Uniforms \(expected[0]) B and offsets, material arguments \(newLength) B, kernel bindings: compatible")
}
// An imported-mesh fixture (scene 6): a UV sphere (about 8,100 triangles) resting on a floor quad.
var obj = "v -3 -1 -3\nv 3 -1 -3\nv 3 -1 3\nv -3 -1 3\n"
let rings = 64, segments = 64
for i in 0...rings { for j in 0..<segments {
    let theta = Float.pi * Float(i) / Float(rings), phi = 2 * Float.pi * Float(j) / Float(segments)
    obj += "v \(0.6 * sin(theta) * cos(phi)) \(-0.4 + 0.6 * cos(theta)) \(0.6 * sin(theta) * sin(phi))\n"
}}
obj += "f 1 4 3 2\n"
for i in 0..<rings { for j in 0..<segments {
    let a = 5 + i * segments + j, b = 5 + i * segments + (j + 1) % segments
    obj += "f \(a) \(b) \(b + segments) \(a + segments)\n"
}}
let mesh = try OBJMesh.load(obj)
let scenarios: [(String, UInt32, UInt32)] = [("Default Pavilion", 0, 0), ("Pavilion with coated OpenPBR floor", 0, 0),
    ("Cornell box", 1, 0), ("Imported mesh (scene 6, \(mesh.count) triangles)", 6, 0), ("Default Pavilion, MIS", 0, 1)]
func prepare(_ renderer: PathTracerRenderer, _ scenario: Int) throws {
    renderer.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
    if scenario == 1 {
        var coated = SurfaceSettings(); coated.enabled = 1
        coated.surface = SIMD4<Float>(0.4, 0, 0.5, 0)
        renderer.materials.settings[1] = coated
    }
    try renderer.materials.setMesh(scenarios[scenario].1 == 6 ? mesh : [])
}
func view(_ scenario: Int) -> Uniforms {
    var u = makeUniforms(scene: scenarios[scenario].1, mode: scenarios[scenario].2, width: 640, height: 480)
    u.environment.w = Float(testRenderer.materials.nodeCount)
    return u
}
// Warm every renderer and MetalFX instance before collecting interleaved observations.
for (_, renderer) in renderers {
    testRenderer = renderer
    try prepare(renderer, 0)
    _ = render(view(0), samples: 8, denoise: true)
}
var timings = [String: [Double]](), radiance = [String: [String: [Float]]]()
for round in 0..<rounds {
    for scenario in scenarios.indices {
        for fx in [false, true] where !(fx && scenarios[scenario].2 != 0) {
            for (name, renderer) in (round % 2 == 0 ? renderers : renderers.reversed()) {
                testRenderer = renderer
                try prepare(renderer, scenario)
                frameMilliseconds = []
                let output = render(view(scenario), samples: frames, denoise: fx)
                let key = "\(scenarios[scenario].0) | MetalFX \(fx ? "on" : "off")"
                timings[key + " | " + name, default: []] += frameMilliseconds.dropFirst(4)
                radiance[key, default: [:]][name, default: []].append(mean(output))
                print("RUN round=\(round) \(key) variant=\(name) meanRadiance=\(mean(output))")
                fflush(stdout)
            }
        }
    }
}
testRenderer = current
if renderers.count == 2 {
    // Same host code, seeds and frames: compatible shaders give matching raw radiance.
    for (key, values) in radiance.sorted(by: { $0.key < $1.key }) {
        for (a, b) in zip(values["baseline"]!, values["current"]!) where abs(a - b) > outputTolerance * max(abs(b), 1e-6) {
            fputs("OUTPUT MISMATCH: \(key): baseline \(a), current \(b) (tolerance \(outputTolerance)); timings withheld\n", stderr)
            exit(4)
        }
    }
}
func median(_ values: [Double]) -> Double { let s = values.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
for key in timings.keys.sorted() {
    let values = timings[key]!
    print("RESULT \(key) | medianMS=\(String(format: "%.2f", median(values))) min=\(String(format: "%.2f", values.min()!)) max=\(String(format: "%.2f", values.max()!)) n=\(values.count)")
}
print("Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue) (0 nominal, 1 fair, 2 serious, 3 critical)")
'''


def describe() -> list:
    def run(*command):
        try:
            return subprocess.run(command, capture_output=True, text=True, cwd=root, timeout=30).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ''
    status = run('git', 'status', '--porcelain', '--untracked-files=no')
    return [
        'Date: ' + datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
        'Source: ' + (run('git', 'rev-parse', 'HEAD') or 'unknown') + (' with uncommitted changes' if status else ''),
        'Baseline: ' + (str(arguments.baseline) if arguments.baseline else 'none'),
        'Machine: ' + (run('sysctl', '-n', 'machdep.cpu.brand_string') or platform.machine())
        + ', ' + str(int(run('sysctl', '-n', 'hw.memsize') or 0) // 2**30) + ' GB',
        'macOS: ' + (run('sw_vers', '-productVersion') or platform.mac_ver()[0]) + ' (' + run('sw_vers', '-buildVersion') + ')',
        'Compiler: ' + run('xcrun', 'swiftc', '--version').splitlines()[0] if run('xcrun', 'swiftc', '--version') else 'Compiler: unknown',
        f'Settings: 640x480, previewScale 1, {arguments.frames} frames per run (first 4 untimed), {arguments.rounds} rounds, depth 16, sampling from tests/GPUChecks.swift render()',
    ]


with tempfile.TemporaryDirectory(prefix='vibe-benchmark-') as directory:
    folder = Path(directory)
    (folder / 'baseline.metal').write_text(baseline_shader)
    binary = harness.compile_swift(source + '\n' + helpers + driver, folder, 'benchmark')
    environment = {**os.environ, 'VIBE_TRACER_REPOSITORY': str(root), harness.OUTPUT_VARIABLE: str(folder / 'output')}
    result = subprocess.run([str(binary), str(folder / 'baseline.metal') if arguments.baseline else '', str(arguments.frames),
                             str(arguments.rounds), str(arguments.output_tolerance), 'safe' if baseline_safe else 'relaxed'],
                            cwd=root, env=environment, capture_output=True, text=True)
    report = '\n'.join(describe()) + '\n' + result.stdout + result.stderr
    print(report)
    if arguments.report:
        arguments.report.write_text(report)
    sys.exit(result.returncode)
