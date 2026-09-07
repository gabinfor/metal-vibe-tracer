#!/usr/bin/env python3
"""Interleaved GPU comparison with a previous main.swift; timings exclude readback.
Usage: python3 tests/benchmark.py /path/to/previous/main.swift
Both versions must use the current shader resources and host buffer layout.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import platform
root = Path(__file__).resolve().parents[1]
previous = Path(sys.argv[1]).read_text()
source = (root / 'main.swift').read_text().split('// 5. App Entry Point')[0]
source += '\n' + '\n'.join(p.read_text() for p in sorted((root / 'Sources').glob('*.swift')))
if 'float4 environment;' not in previous or 'array<texture2d<float>, 256>' not in previous or 'emitters [[id(391)]]' not in previous:
    raise SystemExit('Baseline must use the current 288-byte uniforms and scene/MaterialX argument-buffer layout.')
old_shader = previous.split('let metalSource = loadOpenPBRSource() + """\n', 1)[1].split('\n"""', 1)[0]
old_safe = 'options.mathMode = .safe' in previous
source = source.replace('func shaderCompileOptions()', 'var benchmarkSafe = false\nfunc shaderCompileOptions()')
source = source.replace('options.mathMode = .relaxed', 'options.mathMode = benchmarkSafe ? .safe : .relaxed')
source = source.replace('let metalSource = loadOpenPBRSource()', 'var metalSource = loadOpenPBRSource()', 1)
helpers = (root / 'tests/GPUChecks.swift').read_text().split('for scene in UInt32(0)...5')[0]
helpers = helpers.replace('let testRenderer = try PathTracerRenderer(device: gpu)', '''
let optimizedShader = metalSource
metalSource = loadOpenPBRSource() + (try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))
benchmarkSafe = ''' + str(old_safe).lower() + '''
let baselineRenderer = try PathTracerRenderer(device: gpu)
metalSource = optimizedShader
benchmarkSafe = false
let optimizedRenderer = try PathTracerRenderer(device: gpu)
var testRenderer = optimizedRenderer
''')
helpers = helpers.replace('var lastDenoiseMilliseconds = 0.0', 'var lastDenoiseMilliseconds = 0.0\nvar gpuTimes = [Double]()')
helpers = helpers.replace('        swap(&pos,', '        if frame > 4 { gpuTimes.append(lastDenoiseMilliseconds) }\n        swap(&pos,')
benchmark = r'''
var observations = [String: [Double]]()
// Warm both renderer/MetalFX instances before collecting interleaved observations.
for renderer in [baselineRenderer, optimizedRenderer] {
    testRenderer = renderer
    _ = render(makeUniforms(scene: 0, mode: 0, width: 640, height: 480), samples: 8, denoise: true)
}
for round in 0..<2 {
    for scenario in 0..<3 {
        for fx in [false, true] {
            for variant in (round == 0 ? [0,1] : [1,0]) {
                testRenderer = variant == 0 ? baselineRenderer : optimizedRenderer
                testRenderer.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
                if scenario == 1 {
                    var material = SurfaceSettings(); material.enabled = 1
                    material.surface = SIMD4<Float>(0.4,0,0.5,0)
                    testRenderer.materials.settings[1] = material
                }
                gpuTimes = []
                let output = render(makeUniforms(scene: scenario == 2 ? 1 : 0, mode: 0, width: 640, height: 480), samples: 12, denoise: fx)
                let key = "scenario=" + String(scenario) + " MetalFX=" + String(fx) + " variant=" + String(variant)
                observations[key, default: []] += gpuTimes
                print("RUN", round, key, "meanRadiance=", mean(output))
                fflush(stdout)
            }
        }
    }
}
for key in observations.keys.sorted() {
    let values = observations[key]!.sorted()
    print("RESULT", key, "medianMS=", values[values.count/2])
}
print("Thermal state:", ProcessInfo.processInfo.thermalState.rawValue)
'''
with tempfile.TemporaryDirectory(prefix='vibe-benchmark-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source + helpers + benchmark)
    (folder / 'before.metal').write_text(old_shader)
    subprocess.run(['xcrun','swiftc','-O','-target',platform.machine()+'-apple-macosx26.0',str(folder/'main.swift'),'-o',str(folder/'benchmark')],check=True)
    sys.exit(subprocess.run([str(folder/'benchmark'),str(folder/'before.metal')],cwd=root).returncode)
