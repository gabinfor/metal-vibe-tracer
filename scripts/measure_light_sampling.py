"""Equal-time comparison of power and light-tree emitter selection (LightSampling; docs/LIGHT_TREE_DESIGN.md).

Usage: python3 scripts/measure_light_sampling.py [--only NAME ...] [--width W] [--height H] [--frames N]
                                               [--reference N] [--sequences S] [--strategy K]

For each shot of scripts/showcase.json (the README scenes, with their camera, lighting and render modes), renders
the raw accumulation through the production renderFrame path (one sample per pixel per frame, preview scale 1):
a reference of --reference frames with each selection, averaged, then --sequences independent accumulations of
--frames frames per selection, alternating the two. Reports linear and tone-mapped (x / (1 + x)) MSE against the
reference, the light tree's node count (0: power sampling, for few emitters), the median GPU frame time, the equal-time ratio (tree MSE x time) / (power MSE x time), below 1 where the
light tree wins, the same ratio for tone-mapped MSE (what the display shows: in scenes with visible lamps the
linear MSE is dominated by the lamps' own anti-aliasing noise), the ratio of the two references' mean radiance (1 without bias) and, over all sequences, the
pixel channels whose tone-mapped value is more than 0.1 off the reference (fireflies). Reference noise adds the same amount to both MSEs, which pulls the ratio toward 1.
A development tool like scripts/measure_throughput.py; it is not part of the suite. Shots whose files are missing
are skipped.
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

parser = argparse.ArgumentParser()
parser.add_argument('--only', nargs='*', default=[])
parser.add_argument('--width', type=int, default=320)
parser.add_argument('--height', type=int, default=180)
parser.add_argument('--frames', type=int, default=64)
parser.add_argument('--reference', type=int, default=1024)
parser.add_argument('--sequences', type=int, default=3)
parser.add_argument('--strategy', type=int, help='override every shot\'s strategy (0 ReSTIR, 1 Standard MIS)')
arguments = parser.parse_args()

shots = json.loads((harness.ROOT / 'scripts/showcase.json').read_text())
if arguments.only:
    shots = [s for s in shots if s['name'] in arguments.only]
# Only imported scenes have an emitter list; the procedural scenes render identically with either selection.
shots = [s for s in shots if any(k in s for k in ('usd', 'obj', 'project'))
         and all((harness.ROOT / s[k]).exists() for k in ('usd', 'obj', 'project', 'hdri') if k in s)]
if not shots:
    raise SystemExit('measure_light_sampling.py: no shot to measure')
if arguments.strategy is not None:
    for shot in shots:
        shot['strategy'] = arguments.strategy

driver = r'''
let shots = try JSONDecoder().decode([ShowcaseShot].self, from: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let width = Int(CommandLine.arguments[2])!, height = Int(CommandLine.arguments[3])!
let frames = Int(CommandLine.arguments[4])!, referenceFrames = Int(CommandLine.arguments[5])!, sequences = Int(CommandLine.arguments[6])!
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
// A fresh accumulation of n frames; the sample sequence continues, so repeats are independent.
@MainActor func accumulate(_ mode: LightSampling, _ n: Int) -> (image: [SIMD4<Float>], milliseconds: [Double]) {
  r.lightSampling = mode
  drain(0.05)
  r.resetAccumulation()
  let times = (0..<n).map { _ in frame() }
  return (readTexture(r.accumTexture!), times)
}
func mse(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>], tone: Bool) -> Double {
  var sum = 0.0, count = 0
  for (x, y) in zip(a, b) {
    for c in 0..<3 {
      var u = Double(x[c]), v = Double(y[c])
      guard u.isFinite, v.isFinite else { continue }
      if tone { u = u / (1 + u); v = v / (1 + v) }
      sum += (u - v) * (u - v); count += 1
    }
  }
  return sum / Double(max(1, count))
}
func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
print("| Scene | Emitters | Tree nodes | MSE power | MSE tree | Tone-mapped | Power ms | Tree ms | Equal time | Tone-mapped equal time | Mean tree / power | Outliers power / tree |")
print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
for shot in shots {
  var p: ProjectDocument
  if let path = shot.usd {
    p = try USDImporter.load(URL(fileURLWithPath: path), into: ProjectDocument()).document
  } else if let path = shot.obj {
    let url = URL(fileURLWithPath: path)
    var skipped = 0, report: [String] = []
    p = ProjectDocument()
    _ = try p.appendOBJ(try Data(contentsOf: url, options: .alwaysMapped), name: url.lastPathComponent,
      folder: url.deletingLastPathComponent(), skipped: &skipped, report: &report)
  } else if let path = shot.project {
    let url = URL(fileURLWithPath: path)
    p = try ProjectDocument.decodeProject(try Data(contentsOf: url), near: url)
  } else {
    p = ProjectDocument()
    p.scene = shot.scene ?? 0
    r.sceneIndex = p.scene
    p.camera = CameraState(r)
  }
  if let hdri = shot.hdri {
    p.environmentData = try Data(contentsOf: URL(fileURLWithPath: hdri))
    p.environmentName = URL(fileURLWithPath: hdri).lastPathComponent
  }
  shot.apply(to: &p)
  p.options.previewScale = 1
  try controller.restore(p)
  drain(1)
  r.denoiserEnabled = false
  let emitters = Int(r.materials.emitterBuffer.map { $0.contents().load(as: UInt32.self) } ?? 0)
  let powerReference = accumulate(.power, referenceFrames).image, treeReference = accumulate(.tree, referenceFrames).image
  let words = r.materials.emitterBuffer.contents().assumingMemoryBound(to: UInt32.self)
  let nodes = emitters > 0 ? Int(words[2 * emitters + 2]) : 0
  let reference = zip(powerReference, treeReference).map { 0.5 * ($0 + $1) }
  func mean(_ image: [SIMD4<Float>]) -> Double {
    image.reduce(0.0) { s, v in s + (0..<3).reduce(0.0) { $0 + (v[$1].isFinite ? Double(v[$1]) : 0) } } / Double(3 * image.count)
  }
  var errors: [LightSampling: (linear: Double, tone: Double)] = [.power: (0, 0), .tree: (0, 0)]
  var times: [LightSampling: [Double]] = [.power: [], .tree: []]
  // Firefly count: pixel channels whose tone-mapped value is off the reference by more than 0.1.
  var outliers: [LightSampling: Int] = [.power: 0, .tree: 0]
  for _ in 0..<sequences {
    for mode in [LightSampling.power, .tree] {
      let run = accumulate(mode, frames)
      errors[mode]!.linear += mse(run.image, reference, tone: false) / Double(sequences)
      errors[mode]!.tone += mse(run.image, reference, tone: true) / Double(sequences)
      times[mode]! += run.milliseconds.dropFirst(2)
      for (x, y) in zip(run.image, reference) {
        for c in 0..<3 where x[c].isFinite && y[c].isFinite && abs(x[c] / (1 + x[c]) - y[c] / (1 + y[c])) > 0.1 { outliers[mode]! += 1 }
      }
    }
  }
  let tp = median(times[.power]!), tt = median(times[.tree]!)
  let ep = errors[.power]!, et = errors[.tree]!
  func percent(_ a: Double, _ b: Double) -> String { String(format: "%+.0f%%", 100 * (a / b - 1)) }
  print("| \(shot.name) | \(emitters) | \(nodes) | \(String(format: "%.4g", ep.linear)) | \(String(format: "%.4g", et.linear)) (\(percent(et.linear, ep.linear)))"
    + " | \(percent(et.tone, ep.tone)) | \(String(format: "%.2f", tp)) | \(String(format: "%.2f", tt))"
    + " | \(String(format: "%.2f", et.linear * tt / (ep.linear * tp))) | \(String(format: "%.2f", et.tone * tt / (ep.tone * tp)))"
    + " | \(String(format: "%.4f", mean(treeReference) / mean(powerReference))) | \(outliers[.power]!) / \(outliers[.tree]!) |")
  fflush(stdout)
}
'''

for script in ('prepare_shaders.py', 'generate_spectral_tables.py'):
    subprocess.run([sys.executable, str(harness.ROOT / 'scripts' / script)], check=True)
subprocess.run(['/usr/bin/python3', str(harness.ROOT / 'scripts/prepare_usd.py')], check=True)
subprocess.run([sys.executable, str(harness.ROOT / 'scripts/prepare_oidn.py'), '--arch', platform.machine()], check=True)
source = harness.production_source() + '\n' + harness.gpu_helpers() + '\n' + harness.studio_controller() + driver
with tempfile.TemporaryDirectory(prefix='vibe-tracer-light-sampling-') as directory:
    binary = harness.compile_swift(source, Path(directory), 'LightSampling')
    shot_file = Path(directory) / 'shots.json'
    shot_file.write_text(json.dumps(shots))
    environment = {**os.environ, 'VIBE_TRACER_REPOSITORY': str(harness.ROOT),
                   harness.OUTPUT_VARIABLE: str(Path(directory) / 'output')}
    sys.exit(subprocess.run([str(binary), str(shot_file), str(arguments.width), str(arguments.height),
                             str(arguments.frames), str(arguments.reference), str(arguments.sequences)],
                            cwd=harness.ROOT, env=environment).returncode)
