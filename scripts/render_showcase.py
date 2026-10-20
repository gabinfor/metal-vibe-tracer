"""Renders the README showcase images through the production export path.

Usage: python3 scripts/render_showcase.py [--shots FILE] [--only NAME ...] [--scale S] [--samples N] [--out DIR]

Each shot in the JSON file (default scripts/showcase.json) selects a built-in scene, imports an OpenUSD
file or opens a .vtrace project, optionally loads an HDRI, sets the camera, lens and render modes, and exports
through StudioController.startExport with Open Image Denoise, exactly like Export in the app. A shot with
"raw": true exports linear radiance as OpenEXR without a denoiser instead (renderer comparisons).
--scale and --samples override every shot for quick framing previews. Images go to --out
(default build/showcase); copy the chosen ones to docs/images by hand.
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
parser.add_argument('--shots', type=Path, default=harness.ROOT / 'scripts/showcase.json')
parser.add_argument('--only', nargs='*', default=[])
parser.add_argument('--scale', type=float, default=1.0)
parser.add_argument('--samples', type=int, default=0)
parser.add_argument('--out', type=Path, default=harness.ROOT / 'build/showcase')
arguments = parser.parse_args()

shots = json.loads(arguments.shots.read_text())
if arguments.only:
    shots = [s for s in shots if s['name'] in arguments.only]
    if not shots:
        raise SystemExit('render_showcase.py: no shot matches --only')
for shot in shots:
    shot['width'] = max(16, int(shot.get('width', 1920) * arguments.scale))
    shot['height'] = max(16, int(shot.get('height', 1080) * arguments.scale))
    if arguments.samples:
        shot['samples'] = arguments.samples
arguments.out.mkdir(parents=True, exist_ok=True)

driver = r'''
struct Shot: Decodable {
  var name: String
  var scene: UInt32?
  var project: String?
  var usd: String?
  var hdri: String?
  var sky: UInt32?
  var fog: UInt32?
  var ring: UInt32?
  var strategy: UInt32?
  var lightTransport: UInt32?
  var yaw: Float?, pitch: Float?, distance: Float?, fov: Float?
  var target: [Float]?
  var aperture: Float?, focusDistance: Float?
  var exposure: Float?, toneMap: Float?
  var sunAzimuth: Float?, sunElevation: Float?, sunIntensity: Float?
  var environmentIntensity: Float?, environmentRotation: Float?
  var lightIntensity: Float?, lightSize: Float?
  var lightSpectrum: UInt32?, sunSpectrum: UInt32?
  var lightColor: [Float]?
  var width: Int, height: Int
  var samples: UInt32?
  var depth: Float?
  // Raw linear radiance as OpenEXR, without a denoiser (renderer comparisons).
  var raw: Bool?
}
func waitFor(_ condition: () -> Bool, seconds: Double) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  return condition()
}
let shotData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let outputFolder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
for shot in try JSONDecoder().decode([Shot].self, from: shotData) {
  var p: ProjectDocument
  if let path = shot.usd {
    p = try USDImporter.load(URL(fileURLWithPath: path), into: ProjectDocument()).document
  } else if let path = shot.project {
    let url = URL(fileURLWithPath: path)
    p = try ProjectDocument.decodeProject(try Data(contentsOf: url), near: url)
  } else {
    p = ProjectDocument()
    p.scene = shot.scene ?? 0
    testRenderer.sceneIndex = p.scene
    p.camera = CameraState(testRenderer)
  }
  if let hdri = shot.hdri {
    p.environmentData = try Data(contentsOf: URL(fileURLWithPath: hdri))
    p.environmentName = URL(fileURLWithPath: hdri).lastPathComponent
  }
  if let v = shot.sky { p.sky = v }
  if let v = shot.fog { p.fog = v }
  if let v = shot.ring { p.ring = v }
  if let v = shot.strategy { p.strategy = v }
  if let v = shot.lightTransport { p.lightTransport = v }
  if let v = shot.yaw { p.camera.yaw = v }
  if let v = shot.pitch { p.camera.pitch = v }
  if let v = shot.distance { p.camera.distance = v }
  if let v = shot.fov { p.camera.fov = v }
  if let v = shot.target { p.camera.target = SIMD3<Float>(v[0], v[1], v[2]) }
  if let v = shot.aperture { p.options.aperture = v }
  if let v = shot.focusDistance { p.options.focusDistance = v }
  if let v = shot.exposure { p.options.exposure = v }
  if let v = shot.toneMap { p.options.toneMap = v }
  if let v = shot.sunAzimuth { p.options.sunAzimuth = v }
  if let v = shot.sunElevation { p.options.sunElevation = v }
  if let v = shot.sunIntensity { p.options.sunIntensity = v }
  if let v = shot.environmentIntensity { p.options.environmentIntensity = v }
  if let v = shot.environmentRotation { p.options.environmentRotation = v }
  if let v = shot.lightIntensity { p.options.lightIntensity = v }
  if let v = shot.lightSize { p.options.lightSize = v }
  if let v = shot.lightSpectrum { p.options.lightSpectrum = v }
  if let v = shot.sunSpectrum { p.options.sunSpectrum = v }
  if let v = shot.lightColor { p.options.lightColor = SIMD3<Float>(v[0], v[1], v[2]) }
  p.options.outputWidth = shot.width
  p.options.outputHeight = shot.height
  p.options.exportSamples = shot.samples ?? 1024
  if let v = shot.depth { p.options.depth = v }
  try controller.restore(p)
  let raw = shot.raw ?? false
  controller.exportDenoise = !raw
  controller.exportRaw = raw
  let url = outputFolder.appendingPathComponent(shot.name + (raw ? ".exr" : ".png"))
  try? FileManager.default.removeItem(at: url)
  let start = Date()
  controller.startExport(url: url, hdr: raw)
  guard waitFor({ controller.exportRenderer == nil && controller.exportDenoiseJob == nil }, seconds: 3600),
    FileManager.default.fileExists(atPath: url.path)
  else { fputs("FAIL: \(shot.name) did not export\n", stderr); exit(1) }
  print("\(shot.name): \(shot.width)x\(shot.height), \(p.options.exportSamples) spp, "
    + "\(Int(Date().timeIntervalSince(start))) s, camera yaw \(p.camera.yaw) pitch \(p.camera.pitch) "
    + "distance \(p.camera.distance) fov \(p.camera.fov) target \(p.camera.target)")
}
'''

for script in ('prepare_shaders.py', 'generate_spectral_tables.py'):
    subprocess.run([sys.executable, str(harness.ROOT / 'scripts' / script)], check=True)
subprocess.run(['/usr/bin/python3', str(harness.ROOT / 'scripts/prepare_usd.py')], check=True)
subprocess.run([sys.executable, str(harness.ROOT / 'scripts/prepare_oidn.py'), '--arch', platform.machine()], check=True)
source = harness.production_source() + '\n' + harness.gpu_helpers() + '\n' + harness.studio_controller() + driver
with tempfile.TemporaryDirectory(prefix='vibe-tracer-showcase-') as directory:
    binary = harness.compile_swift(source, Path(directory), 'Showcase')
    shot_file = Path(directory) / 'shots.json'
    shot_file.write_text(json.dumps(shots))
    environment = {**os.environ, 'VIBE_TRACER_REPOSITORY': str(harness.ROOT),
                   harness.OUTPUT_VARIABLE: str(Path(directory) / 'output')}
    sys.exit(subprocess.run([str(binary), str(shot_file), str(arguments.out.resolve())],
                            cwd=harness.ROOT, env=environment).returncode)
