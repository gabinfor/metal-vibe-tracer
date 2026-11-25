"""Equal-time comparison of the PCG and Z++ samplers (SamplerMode; REFERENCES.md ZPP2026).

Usage: python3 scripts/measure_sampler.py [--only NAME ...] [--strategies mis gi pt unified] [--transports rgb spectral]
                                          [--width W] [--height H] [--frames N] [--reference N] [--sequences S]
                                          [--dump DIR]

For each scene (the procedural scenes and two imported USD scenes, with the cameras of scripts/showcase.json where the
shot exists), each strategy (Standard MIS, ReSTIR GI, ReSTIR PT, unified ReSTIR PT) and each light transport, renders the
raw accumulation through the production renderFrame path (one sample per pixel per frame, preview scale 1): a reference
of --reference frames per sampler, averaged, then --sequences independent accumulations of --frames frames per sampler,
alternating the two. Reports, at 16, 64 and --frames frames, linear MSE against the reference, the change of the
tone-mapped (x / (1 + x)) MSE, the median GPU frame time, and the equal-time ratios (Z++ MSE x time) / (PCG MSE x time),
below 1 where Z++ wins. Also reports the block statistics of the tone-mapped luma error after 64 frames (the structured
artefact that the 2026-10-04 key-layout fix removed; tests/Fix_zsampler-blocks.swift): the energy of the mean error of
aligned s x s pixel blocks relative to independent noise (1 without block correlation) at s = 2, 4, 8, and the
correlation of horizontally adjacent pixels' errors. With --dump DIR, writes each case's 64-frame accumulation and error
image as PPM files. Reference noise adds the same amount to both MSEs, which pulls the ratios toward 1.
A development tool like scripts/measure_light_sampling.py; it is not part of the suite.
"""
import argparse
import json
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
import harness  # noqa: E402

STRATEGIES = ['mis', 'gi', 'pt', 'unified']
parser = argparse.ArgumentParser()
parser.add_argument('--only', nargs='*', default=[])
parser.add_argument('--strategies', nargs='*', default=STRATEGIES, choices=STRATEGIES)
parser.add_argument('--transports', nargs='*', default=['rgb', 'spectral'], choices=['rgb', 'spectral'])
parser.add_argument('--width', type=int, default=320)
parser.add_argument('--height', type=int, default=180)
parser.add_argument('--frames', type=int, default=256)
parser.add_argument('--reference', type=int, default=768)
parser.add_argument('--sequences', type=int, default=3)
parser.add_argument('--dump', type=Path)
arguments = parser.parse_args()
if arguments.frames < 64:
    raise SystemExit('measure_sampler.py: --frames must be at least 64')

showcase = {s['name']: s for s in json.loads((harness.ROOT / 'scripts/showcase.json').read_text())}


def shot(name, source, showcase_name=None):
    entry = {k: v for k, v in showcase.get(showcase_name or '', {}).items()
             if k in ('yaw', 'pitch', 'distance', 'fov', 'target', 'exposure', 'sky', 'aperture', 'focusDistance')}
    return {'name': name, **source, **entry}


shots = [
    shot('Pavilion', {'scene': 0}),
    shot('Pavilion, showcase view', {'scene': 0}, 'pavilion-hdri'),
    shot('Cornell box', {'scene': 1}),
    shot('Cornell glass & mirror', {'scene': 3}, 'cornell-glass-mirror'),
    shot('Veach MIS benchmark', {'scene': 2}),
    shot('Reflective ring', {'scene': 5}),
    shot('Shader ball (USD)', {'usd': 'build/reference-scenes/ShaderBall-triangulated.usda'}, 'shaderball-loft'),
    shot('Lantern arcade (USD)', {'usd': 'Examples/Spectral/LanternArcade.usda'}, 'spectral-lantern-arcade'),
]
if arguments.only:
    shots = [s for s in shots if s['name'] in arguments.only]
shots = [s for s in shots if 'usd' not in s or (harness.ROOT / s['usd']).exists()]
if not shots:
    raise SystemExit('measure_sampler.py: no scene to measure')

driver = r'''
let shots = try JSONDecoder().decode([ShowcaseShot].self, from: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let width = Int(CommandLine.arguments[2])!, height = Int(CommandLine.arguments[3])!
let frames = Int(CommandLine.arguments[4])!, referenceFrames = Int(CommandLine.arguments[5])!, sequences = Int(CommandLine.arguments[6])!
let strategies = CommandLine.arguments[7].split(separator: ",").map(String.init)
let transports = CommandLine.arguments[8].split(separator: ",").map(String.init)
let dumpDirectory = CommandLine.arguments[9]
let checkpoints = [16, 64, frames]
let r = testRenderer
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
let output = gpu.makeTexture(descriptor: descriptor)!
@MainActor func drain(_ seconds: Double = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
@MainActor func frame() -> Double {
  var done = false
  r.onFrameUpdate = { _ in done = true }
  r.renderFrame(output: output)
  let deadline = Date().addingTimeInterval(300)
  while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
  require(done, "frame completed")
  return r.gpuMilliseconds
}
// A fresh accumulation of n frames; the sample sequence continues, so repeats are independent. Images at the checkpoints.
@MainActor func accumulate(_ mode: SamplerMode, _ n: Int, at points: [Int]) -> (images: [Int: [SIMD4<Float>]], milliseconds: [Double]) {
  r.sampler = mode
  drain(0.05)
  r.resetAccumulation()
  var times = [Double](), images = [Int: [SIMD4<Float>]]()
  for i in 1...n {
    times.append(frame())
    if points.contains(i) { images[i] = readTexture(r.accumTexture!) }
  }
  return (images, times)
}
func tone(_ x: Float) -> Double { x.isFinite ? Double(x / (1 + x)) : 0 }
func mse(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>], tone toned: Bool) -> Double {
  var sum = 0.0, count = 0
  for (x, y) in zip(a, b) {
    for c in 0..<3 {
      var u = Double(x[c]), v = Double(y[c])
      guard u.isFinite, v.isFinite else { continue }
      if toned { u = u / (1 + u); v = v / (1 + v) }
      sum += (u - v) * (u - v); count += 1
    }
  }
  return sum / Double(max(1, count))
}
func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
// Tone-mapped luma error and its block statistics: the energy of s x s block means times s^2 over the pixel energy
// (1 for independent noise), and the correlation of horizontally adjacent pixels.
func lumaError(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> [Double] {
  zip(a, b).map { x, y in
    0.2126 * (tone(x.x) - tone(y.x)) + 0.7152 * (tone(x.y) - tone(y.y)) + 0.0722 * (tone(x.z) - tone(y.z))
  }
}
func blockExcess(_ e: [Double], _ s: Int) -> Double {
  var pixel = 0.0
  for v in e { pixel += v * v }
  pixel /= Double(e.count)
  var blocks = 0.0, count = 0
  for by in 0..<(height / s) { for bx in 0..<(width / s) {
    var m = 0.0
    for y in 0..<s { for x in 0..<s { m += e[(by * s + y) * width + bx * s + x] } }
    m /= Double(s * s)
    blocks += m * m * Double(s * s); count += 1
  } }
  return pixel > 0 ? blocks / Double(count) / pixel : 0
}
func adjacent(_ e: [Double]) -> Double {
  var xy = 0.0, xx = 0.0
  for y in 0..<height { for x in 0..<(width - 1) { xy += e[y * width + x] * e[y * width + x + 1]; xx += e[y * width + x] * e[y * width + x] } }
  return xx > 0 ? xy / xx : 0
}
func writePPM(_ image: [SIMD4<Float>], _ path: String, toneMap: Bool) {
  var bytes = [UInt8]()
  for v in image { for c in 0..<3 {
    let x = v[c].isFinite ? max(0, v[c]) : 0
    let t = powf(toneMap ? x / (1 + x) : min(1, x), 1 / 2.2)
    bytes.append(UInt8(max(0, min(1, t)) * 255 + 0.5))
  } }
  var data = Data("P6\n\(width) \(height)\n255\n".utf8); data.append(contentsOf: bytes)
  try? data.write(to: URL(fileURLWithPath: path))
}
let strategyDefinitions: [String: (String, UInt32, IndirectReuse)] = [
  "mis": ("MIS", 1, .restirGI), "gi": ("ReSTIR GI", 0, .restirGI), "pt": ("ReSTIR PT", 0, .restirPT), "unified": ("Unified PT", 0, .restirPTUnified)]
print("| Scene | Strategy | Transport | Frames | MSE PCG | MSE Z++ | Tone-mapped | PCG ms | Z++ ms | Equal time | Tone-mapped equal time | Mean Z++ / PCG | Block excess PCG 2/4/8 | Block excess Z++ 2/4/8 | Adjacent corr. PCG / Z++ |")
print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
for shot in shots {
  var p: ProjectDocument
  if let path = shot.usd {
    p = try USDImporter.load(URL(fileURLWithPath: path), into: ProjectDocument()).document
  } else {
    p = ProjectDocument()
    p.scene = shot.scene ?? 0
    r.sceneIndex = p.scene
    p.camera = CameraState(r)
  }
  shot.apply(to: &p)
  p.options.previewScale = 1
  try controller.restore(p)
  drain(1)
  r.denoiserEnabled = false
  for key in strategies {
    let (strategyName, samplingMode, reuse) = strategyDefinitions[key]!
    for transport in transports {
      r.samplingMode = samplingMode
      r.indirectReuse = reuse
      r.lightTransport = transport == "spectral" ? .spectral : .rgb
      drain(0.1)
      let pcgReference = accumulate(.pcg, referenceFrames, at: [referenceFrames]).images[referenceFrames]!
      let zReference = accumulate(.zSampling, referenceFrames, at: [referenceFrames]).images[referenceFrames]!
      let reference = zip(pcgReference, zReference).map { 0.5 * ($0 + $1) }
      func mean(_ image: [SIMD4<Float>]) -> Double {
        image.reduce(0.0) { s, v in s + (0..<3).reduce(0.0) { $0 + (v[$1].isFinite ? Double(v[$1]) : 0) } } / Double(3 * image.count)
      }
      var linear = [SamplerMode: [Int: Double]](), toned = [SamplerMode: [Int: Double]](), times = [SamplerMode: [Double]]()
      var blocks = [SamplerMode: [Double]](), adjacentCorrelation = [SamplerMode: Double]()
      for mode in [SamplerMode.pcg, .zSampling] {
        linear[mode] = [:]; toned[mode] = [:]; times[mode] = []; blocks[mode] = [0, 0, 0]; adjacentCorrelation[mode] = 0
        for c in checkpoints { linear[mode]![c] = 0; toned[mode]![c] = 0 }
      }
      for sequence in 0..<sequences {
        for mode in [SamplerMode.pcg, .zSampling] {
          let run = accumulate(mode, frames, at: checkpoints)
          for c in checkpoints {
            linear[mode]![c]! += mse(run.images[c]!, reference, tone: false) / Double(sequences)
            toned[mode]![c]! += mse(run.images[c]!, reference, tone: true) / Double(sequences)
          }
          times[mode]! += run.milliseconds.dropFirst(2)
          let e = lumaError(run.images[64]!, reference)
          for (i, s) in [2, 4, 8].enumerated() { blocks[mode]![i] += blockExcess(e, s) / Double(sequences) }
          adjacentCorrelation[mode]! += adjacent(e) / Double(sequences)
          if sequence == 0 && !dumpDirectory.isEmpty {
            let name = "\(shot.name.filter { $0.isLetter || $0.isNumber })-\(key)-\(transport)-\(mode == .pcg ? "pcg" : "z")"
            writePPM(run.images[64]!, "\(dumpDirectory)/\(name)-64.ppm", toneMap: true)
            writePPM(zip(run.images[64]!, reference).map { x, y in SIMD4<Float>(repeating: 0.5) + 4 * (x - y) }, "\(dumpDirectory)/\(name)-64-error.ppm", toneMap: false)
          }
        }
      }
      let tp = median(times[.pcg]!), tz = median(times[.zSampling]!)
      func percent(_ a: Double, _ b: Double) -> String { String(format: "%+.0f%%", 100 * (a / b - 1)) }
      func triple(_ v: [Double]) -> String { v.map { String(format: "%.2f", $0) }.joined(separator: "/") }
      for c in checkpoints {
        let lp = linear[.pcg]![c]!, lz = linear[.zSampling]![c]!, tp2 = toned[.pcg]![c]!, tz2 = toned[.zSampling]![c]!
        let showBlocks = c == 64
        print("| \(shot.name) | \(strategyName) | \(transport) | \(c) | \(String(format: "%.4g", lp)) | \(String(format: "%.4g", lz)) (\(percent(lz, lp)))"
          + " | \(percent(tz2, tp2)) | \(String(format: "%.2f", tp)) | \(String(format: "%.2f", tz))"
          + " | \(String(format: "%.2f", lz * tz / (lp * tp))) | \(String(format: "%.2f", tz2 * tz / (tp2 * tp)))"
          + " | \(String(format: "%.4f", mean(zReference) / mean(pcgReference)))"
          + " | \(showBlocks ? triple(blocks[.pcg]!) : "") | \(showBlocks ? triple(blocks[.zSampling]!) : "")"
          + " | \(showBlocks ? String(format: "%.3f / %.3f", adjacentCorrelation[.pcg]!, adjacentCorrelation[.zSampling]!) : "") |")
      }
      fflush(stdout)
    }
  }
}
'''

for script in ('prepare_shaders.py', 'generate_spectral_tables.py'):
    subprocess.run([sys.executable, str(harness.ROOT / 'scripts' / script)], check=True)
subprocess.run(['/usr/bin/python3', str(harness.ROOT / 'scripts/prepare_usd.py')], check=True)
subprocess.run([sys.executable, str(harness.ROOT / 'scripts/prepare_oidn.py'), '--arch', platform.machine()], check=True)
source = harness.production_source() + '\n' + harness.gpu_helpers() + '\n' + harness.studio_controller() + driver
with tempfile.TemporaryDirectory(prefix='vibe-tracer-sampler-') as directory:
    binary = harness.compile_swift(source, Path(directory), 'SamplerMeasure')
    shot_file = Path(directory) / 'shots.json'
    shot_file.write_text(json.dumps(shots))
    if arguments.dump:
        arguments.dump.mkdir(parents=True, exist_ok=True)
    environment = {**os.environ, 'VIBE_TRACER_REPOSITORY': str(harness.ROOT),
                   harness.OUTPUT_VARIABLE: str(Path(directory) / 'output')}
    sys.exit(subprocess.run([str(binary), str(shot_file), str(arguments.width), str(arguments.height),
                             str(arguments.frames), str(arguments.reference), str(arguments.sequences),
                             ','.join(arguments.strategies), ','.join(arguments.transports),
                             str(arguments.dump.resolve()) if arguments.dump else ''],
                            cwd=harness.ROOT, env=environment).returncode)
