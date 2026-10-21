"""Measures how much rendering the GPU delivers: export and interactive viewport throughput.

Usage: python3 scripts/measure_throughput.py [--tick EXPR] [--seconds S] [--export-samples N] [--only NAME ...]

For each case (a built-in scene, an OBJ import or a .vtrace project), reports:
- export: wall time and samples per second of a raw 1920x1080 export (no denoiser) through
  StudioController.startExport, from the start of the export to the written file;
- viewport: completed samples per second while a simulated display calls the viewport's
  per-frame work (--tick, default what PathTracerRenderer.draw encodes) 60 times per second for
  --seconds, on a 1280x800 drawable at the project's preview scale and at full scale, with the
  camera still (accumulating).
A development tool (docs/SCENE_STORAGE_DESIGN.md); it compiles the production sources like
tests/benchmark.py and is not part of the suite. Cases whose files are missing are skipped.
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
parser.add_argument('--tick', default='renderer.renderFrame(output: out, samples: renderer.samplesPerFrame('
                    'targetMilliseconds: 800.0 / 60, limit: Int.max))',
                    help='Swift expression run once per simulated display refresh (out: the drawable texture); '
                         'the default is what PathTracerRenderer.draw does at 60 Hz')
parser.add_argument('--seconds', type=float, default=4)
parser.add_argument('--export-samples', type=int, default=32)
parser.add_argument('--only', nargs='*', default=[])
arguments = parser.parse_args()

ROOT = harness.ROOT
CASES = [
    {'name': 'pavilion (scene 0), ReSTIR', 'scene': 0},
    {'name': 'pavilion (scene 0), Standard MIS', 'scene': 0, 'strategy': 1},
    {'name': 'cornell (scene 1), Standard MIS', 'scene': 1, 'strategy': 1},
    {'name': 'sponza (OBJ, 262k triangles)', 'obj': 'build/scenes/sponza/sponza.obj',
     'target': [-300, 350, -30], 'yaw': -1.5708, 'pitch': 0.05, 'distance': 1000, 'fov': 65},
    {'name': 'bistro exterior (project, 2.8M triangles)', 'project': 'build/bistro/exterior.vtrace',
     'target': [-500, 200, 0], 'yaw': 0.0, 'pitch': 0.05, 'distance': 1500, 'fov': 65},
]
cases = [c for c in CASES if not arguments.only or any(o in c['name'] for o in arguments.only)]
cases = [c for c in cases if all((ROOT / c[k]).exists() for k in ('obj', 'project') if k in c)]

driver = r'''
struct Case: Decodable {
  var name: String, scene: UInt32?, obj: String?, project: String?, strategy: UInt32?
  var target: [Float]?, yaw: Float?, pitch: Float?, distance: Float?, fov: Float?
}
func waitFor(_ condition: () -> Bool, seconds: Double) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
  return condition()
}
let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let cases = try JSONDecoder().decode([Case].self, from: JSONSerialization.data(withJSONObject: config["cases"]!))
let seconds = config["seconds"] as! Double, exportSamples = config["exportSamples"] as! Int
let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let renderer = controller.renderer
for c in cases {
  var p = ProjectDocument()
  if let path = c.obj {
    let url = URL(fileURLWithPath: path); var skipped = 0, report: [String] = []
    _ = try p.appendOBJ(try Data(contentsOf: url, options: .alwaysMapped), name: url.lastPathComponent,
      folder: url.deletingLastPathComponent(), skipped: &skipped, report: &report)
  } else if let path = c.project {
    let url = URL(fileURLWithPath: path)
    p = try ProjectDocument.decodeProject(try Data(contentsOf: url, options: .alwaysMapped), near: url)
  } else {
    p.scene = c.scene ?? 0
    testRenderer.sceneIndex = p.scene
    p.camera = CameraState(testRenderer)
  }
  if let v = c.strategy { p.strategy = v }
  if let v = c.target { p.camera.target = SIMD3(v[0], v[1], v[2]) }
  if let v = c.yaw { p.camera.yaw = v }
  if let v = c.pitch { p.camera.pitch = v }
  if let v = c.distance { p.camera.distance = v }
  if let v = c.fov { p.camera.fov = v }
  p.options.outputWidth = 1920; p.options.outputHeight = 1080
  p.options.exportSamples = UInt32(exportSamples)
  p.options.maxSamples = 0; p.options.timeLimit = 0
  try controller.restore(p)
  // Viewport: a still camera, accumulating, at the project's preview scale and at full scale.
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1280, height: 800, mipmapped: false)
  descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
  let out = renderer.device.makeTexture(descriptor: descriptor)!
  var viewport: [String] = []
  for scale in [Float(0.25), p.options.previewScale, Float(1)] {
    renderer.options.previewScale = scale
    renderer.paused = false
    renderer.resetAccumulation()
    // Warm-up: allocation and the first frames.
    for _ in 0..<10 { TICK; _ = waitFor({ false }, seconds: 1.0 / 60) }
    _ = waitFor({ renderer.completedSamples == renderer.frameIndex }, seconds: 10)
    let first = renderer.completedSamples, start = Date()
    var next = start
    while Date().timeIntervalSince(start) < seconds {
      TICK
      next = next.addingTimeInterval(1.0 / 60)
      _ = waitFor({ Date() >= next }, seconds: 1)
    }
    let elapsed = Date().timeIntervalSince(start)
    let done = Double(renderer.completedSamples &- first)
    viewport.append(String(format: "scale %.2f (%dx%d): %.0f samples/s, %.1f ms GPU per frame",
      scale, Int(1280 * scale), Int(800 * scale), done / elapsed, renderer.gpuMilliseconds))
  }
  renderer.paused = true
  // Export: raw 1920x1080 through the production export path.
  controller.exportDenoise = false
  controller.exportRaw = true
  let url = folder.appendingPathComponent("throughput.exr")
  try? FileManager.default.removeItem(at: url)
  let start = Date()
  controller.startExport(url: url, hdr: true)
  var lastReport = Date()
  guard waitFor({
    if Date().timeIntervalSince(lastReport) > 5 {
      lastReport = Date()
      fputs("  export progress: \(controller.exportRenderer?.completedSamples ?? 0) samples, status \(controller.status.stringValue)\n", stderr)
    }
    return controller.exportRenderer == nil && controller.exportDenoiseJob == nil
  }, seconds: 3600),
    FileManager.default.fileExists(atPath: url.path)
  else { fputs("FAIL: \(c.name) did not export\n", stderr); exit(1) }
  let exportSeconds = Date().timeIntervalSince(start)
  print("\(c.name)\n  export 1920x1080 \(exportSamples) spp: \(String(format: "%.2f s, %.1f samples/s", exportSeconds, Double(exportSamples) / exportSeconds))")
  for line in viewport { print("  viewport " + line) }
  renderer.paused = false
}
'''.replace('TICK', arguments.tick)

for script in ('prepare_shaders.py', 'generate_spectral_tables.py'):
    subprocess.run([sys.executable, str(ROOT / 'scripts' / script)], check=True, stdout=subprocess.DEVNULL)
subprocess.run([sys.executable, str(ROOT / 'scripts/prepare_oidn.py'), '--arch', platform.machine()], check=True,
               stdout=subprocess.DEVNULL)
source = (harness.production_source() + '\nsetvbuf(stdout, nil, _IOLBF, 0)\n' + harness.gpu_helpers() + '\n'
          + harness.studio_controller() + driver)
with tempfile.TemporaryDirectory(prefix='vibe-tracer-throughput-') as directory:
    binary = harness.compile_swift(source, Path(directory), 'Throughput')
    config = Path(directory) / 'config.json'
    config.write_text(json.dumps({'cases': cases, 'seconds': arguments.seconds,
                                  'exportSamples': arguments.export_samples}))
    environment = {**os.environ, 'VIBE_TRACER_REPOSITORY': str(ROOT), harness.OUTPUT_VARIABLE: str(Path(directory) / 'output')}
    sys.exit(subprocess.run([str(binary), str(config), directory], cwd=ROOT, env=environment).returncode)
