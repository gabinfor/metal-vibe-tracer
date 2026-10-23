"""Renders the README showcase images through the production export path.

Usage: python3 scripts/render_showcase.py [--shots FILE] [--only NAME ...] [--scale S] [--samples N] [--out DIR]

Each shot in the JSON file (default scripts/showcase.json) selects a built-in scene, imports an OpenUSD
file, opens a .vtrace project or imports an OBJ with its MTL materials, optionally loads an HDRI, sets the camera, lens and render modes, and exports
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

# The shot schema and its settings (ShowcaseShot, with the emission scaling) are production code in
# Sources/ExampleScenes.swift, which File > Open Example Scene applies to the same shots.
driver = r'''
func waitFor(_ condition: () -> Bool, seconds: Double) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  return condition()
}
let shotData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let outputFolder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
for shot in try JSONDecoder().decode([ShowcaseShot].self, from: shotData) {
  var p: ProjectDocument
  if let path = shot.usd {
    p = try USDImporter.load(URL(fileURLWithPath: path), into: ProjectDocument()).document
  } else if let path = shot.obj {
    let url = URL(fileURLWithPath: path)
    var skipped = 0, report: [String] = []
    let start = Date()
    p = ProjectDocument()
    _ = try p.appendOBJ(try Data(contentsOf: url, options: .alwaysMapped), name: url.lastPathComponent,
      folder: url.deletingLastPathComponent(), skipped: &skipped, report: &report)
    print("\(url.lastPathComponent): imported in \(String(format: "%.1f", Date().timeIntervalSince(start))) s, "
      + "\(p.graph?.assets.reduce(0) { $0 + $1.geometry.count } ?? 0) triangles, \(skipped) degenerate faces skipped, "
      + "\(p.scenes[6]?.materialX?.count ?? 0) MaterialX materials")
    for line in report { print("  " + line) }
  } else if let path = shot.project {
    let url = URL(fileURLWithPath: path)
    p = try ProjectDocument.decodeProject(try Data(contentsOf: url), near: url)
  } else {
    p = ProjectDocument()
    p.scene = shot.scene ?? 0
    testRenderer.sceneIndex = p.scene
    p.camera = CameraState(testRenderer)
  }
  if let k = shot.emissionScale { print("\(shot.name): imported emission scaled by \(k)") }
  if let hdri = shot.hdri {
    p.environmentData = try Data(contentsOf: URL(fileURLWithPath: hdri))
    p.environmentName = URL(fileURLWithPath: hdri).lastPathComponent
  }
  shot.apply(to: &p)
  if shot.samples == nil { p.options.exportSamples = 1024 }
  try controller.restore(p)
  if let side = testRenderer.materials.graphTextureSide {
    let materials = testRenderer.materials
    let sizes = Dictionary(grouping: materials.graphTextures, by: { max($0.width, $0.height) }).mapValues(\.count).sorted { $0.key > $1.key }
    print("\(shot.name): large textures decoded at reduced size (down to \(side) px) for the GPU texture budget; "
      + "\(materials.uniqueTextureBytes(materials.graphTextures) >> 20) MiB of \(materials.textureBudget >> 20) MiB; longer sides "
      + sizes.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
  }
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
  print("\(shot.name): \(p.options.outputWidth)x\(p.options.outputHeight), \(p.options.exportSamples) spp, "
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
