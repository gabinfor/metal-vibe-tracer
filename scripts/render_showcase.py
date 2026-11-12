"""Renders the README showcase images through the production export path.

Usage: python3 scripts/render_showcase.py [--shots FILE] [--only NAME ...] [--scale S] [--samples N] [--out DIR]
       python3 scripts/render_showcase.py --thumbnails [--only ID ...]

Each shot in the JSON file (default scripts/showcase.json) selects a built-in scene, imports an OpenUSD,
glTF or Mitsuba file, opens a .vtrace project or imports an OBJ with its MTL materials, optionally loads an HDRI, sets the camera
(or picks an imported camera's saved view with "view"), lens and render modes, and exports
through StudioController.startExport, exactly like Export in the app, from the raw accumulation: documentation
and test images are not denoised. A shot with "denoise": true uses Open Image Denoise instead (on request, or
for a high-sample showcase render); "indirectClamp": c caps each sample's indirect luminance at c, a biased
firefly control that the image notes must state; "raw": true exports linear radiance as OpenEXR (renderer comparisons);
"keepRaw": true with "denoise": true also saves the undenoised image of the same render as NAME-raw.png.
--scale and --samples override every shot for quick framing previews. Images go to --out
(default build/showcase); copy the chosen ones to docs/images by hand.

--thumbnails renders the scene browser's thumbnails instead: for each entry of SceneCatalog.entries (read by the Swift
driver, so there is no second list here) but the SceneCatalog.thumbnailExempt scenes, the entry's shot (a built-in
scene: its scene index at the default view) at 960 x 540 with at most 256 spp and no denoiser, downsampled to
480 x 270 and written as JPEG (quality 0.85) to Examples/Thumbnails/<id>.jpg, with the ids in
Examples/Thumbnails/scene-ids.txt for scripts/check_bundle.py. --only then names catalog ids. A scene whose files are
not installed is skipped, and one whose render fails is reported, and both are listed at the end while the run goes
on. A failed render removes that id's old JPEG and makes the exit status non-zero after every entry was tried; a
skipped scene keeps its JPEG and the exit status is 0.
The run always rewrites scene-ids.txt with every id that has a thumbnail, also with --only.
Each line of progress is samples done / target and elapsed time.
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
parser.add_argument('--thumbnails', action='store_true')
arguments = parser.parse_args()
thumbnail_folder = harness.ROOT / 'Examples/Thumbnails'

shots = json.loads(arguments.shots.read_text())
if arguments.only and not arguments.thumbnails:
    shots = [s for s in shots if s['name'] in arguments.only]
    if not shots:
        raise SystemExit('render_showcase.py: no shot matches --only')
for shot in ([] if arguments.thumbnails else shots):
    shot['width'] = max(16, int(shot.get('width', 1920) * arguments.scale))
    shot['height'] = max(16, int(shot.get('height', 1080) * arguments.scale))
    if arguments.samples:
        shot['samples'] = arguments.samples
arguments.out.mkdir(parents=True, exist_ok=True)

# The shot schema and its settings (ShowcaseShot, with the emission scaling) are production code in
# Sources/ExampleScenes.swift, which the scene browser applies to the same shots.
driver = r'''
// Every `every` seconds while waiting, `report` prints a progress line (flushed, so it shows while running).
func waitFor(_ condition: () -> Bool, seconds: Double, every: Double = 0, report: () -> Void = {}) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  var next = Date().addingTimeInterval(every)
  while !condition() && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    if every > 0 && Date() >= next { report(); fflush(stdout); next = Date().addingTimeInterval(every) }
  }
  return condition()
}
let shotData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let outputFolder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
// A shot that did not export, reported on stderr; thumbnail mode records it and goes on, showcase mode stops.
struct ExportFailure: LocalizedError {
  var errorDescription: String?
}

// Imports the shot's scene, applies its settings and exports it to outputFolder (PNG, or EXR for a raw shot).
@MainActor func render(_ shot: ShowcaseShot) throws -> URL {
  var p: ProjectDocument
  if let path = shot.usd {
    p = try USDImporter.load(URL(fileURLWithPath: path), into: ProjectDocument()).document
  } else if let path = shot.gltf {
    let start = Date()
    let imported = try GLTFImporter.load(URL(fileURLWithPath: path), into: ProjectDocument())
    p = imported.document
    print("\(URL(fileURLWithPath: path).lastPathComponent): imported in \(String(format: "%.1f", Date().timeIntervalSince(start))) s, "
      + "\(p.graph?.assets.reduce(0) { $0 + $1.geometry.count } ?? 0) triangles, \(p.scenes[6]?.materialX?.count ?? 0) MaterialX materials, "
      + "views: \(p.views.keys.sorted().joined(separator: ", "))")
    for line in imported.report { print("  " + line) }
  } else if let path = shot.mitsuba {
    let start = Date()
    let imported = try MitsubaImporter.load(URL(fileURLWithPath: path), into: ProjectDocument())
    p = imported.document
    print("\(URL(fileURLWithPath: path).lastPathComponent): imported in \(String(format: "%.1f", Date().timeIntervalSince(start))) s, "
      + "\(p.graph?.assets.reduce(0) { $0 + $1.geometry.count } ?? 0) triangles, \(p.scenes[6]?.materialX?.count ?? 0) MaterialX materials, "
      + "views: \(p.views.keys.sorted().joined(separator: ", "))")
    for line in imported.report { print("  " + line) }
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
  let raw = shot.raw ?? false, denoise = !raw && (shot.denoise ?? false)
  // Raw accumulation (no OIDN, no MetalFX) unless the shot asks for Open Image Denoise.
  controller.exportDenoise = denoise
  controller.exportRaw = !denoise
  let url = outputFolder.appendingPathComponent(shot.name + (raw ? ".exr" : ".png"))
  try? FileManager.default.removeItem(at: url)
  let start = Date()
  controller.startExport(url: url, hdr: raw)
  // Progress every 30 s: samples over the target and elapsed time.
  let report = {
    let done = controller.exportRenderer?.completedSamples ?? p.options.exportSamples
    print("\(shot.name): \(done) / \(p.options.exportSamples) spp, \(Int(Date().timeIntervalSince(start))) s elapsed")
  }
  // keepRaw: once sampling ends and OIDN starts, the export output still holds the raw display image.
  if denoise && shot.keepRaw == true {
    guard waitFor({ controller.exportDenoiseJob != nil || controller.exportRenderer == nil }, seconds: 3600, every: 30, report: report),
      let display = controller.exportOutput
    else { throw ExportFailure(errorDescription: "FAIL: \(shot.name) did not reach denoising") }
    let rawURL = outputFolder.appendingPathComponent(shot.name + "-raw.png")
    try RenderImage.write(texture: display, url: rawURL, hdr: false)
    print("\(shot.name): raw accumulation saved as \(rawURL.lastPathComponent)")
  }
  guard waitFor({ controller.exportRenderer == nil && controller.exportDenoiseJob == nil }, seconds: 3600, every: 30, report: report),
    FileManager.default.fileExists(atPath: url.path)
  else { throw ExportFailure(errorDescription: "FAIL: \(shot.name) did not export") }
  print("\(shot.name): \(p.options.outputWidth)x\(p.options.outputHeight), \(p.options.exportSamples) spp, "
    + "\(Int(Date().timeIntervalSince(start))) s, camera yaw \(p.camera.yaw) pitch \(p.camera.pitch) "
    + "distance \(p.camera.distance) fov \(p.camera.fov) target \(p.camera.target)")
  return url
}

// Averages a 960 x 540 render down to 480 x 270 and writes it as a JPEG of quality 0.85.
func writeThumbnail(_ png: URL, to jpeg: URL) throws {
  guard let source = CGImageSourceCreateWithURL(png as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let context = CGContext(data: nil, width: 480, height: 270, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { throw MaterialLibrary.error("\(png.lastPathComponent) cannot be read") }
  context.interpolationQuality = .high
  context.draw(image, in: CGRect(x: 0, y: 0, width: 480, height: 270))
  guard let small = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil)
  else { throw MaterialLibrary.error("\(jpeg.lastPathComponent) cannot be written") }
  CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { throw MaterialLibrary.error("\(jpeg.lastPathComponent) cannot be written") }
}

let shots = try JSONDecoder().decode([ShowcaseShot].self, from: shotData)
if CommandLine.arguments.count > 4, CommandLine.arguments[3] == "--thumbnails" {
  let thumbnailFolder = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
  let only = Set(CommandLine.arguments.dropFirst(5))
  let ids = SceneCatalog.entries.map(\.id).filter { !SceneCatalog.thumbnailExempt.contains($0) }
  try FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
  try (ids.joined(separator: "\n") + "\n").write(to: thumbnailFolder.appendingPathComponent("scene-ids.txt"), atomically: true,
    encoding: .utf8)
  var skipped: [String] = [], failed: [String] = []
  for entry in SceneCatalog.entries where ids.contains(entry.id) && (only.isEmpty || only.contains(entry.id)) {
    var shot: ShowcaseShot
    if case .builtIn(let index) = entry.source {
      shot = try JSONDecoder().decode(ShowcaseShot.self, from: Data("{\"name\": \"\(entry.id)\", \"scene\": \(index)}".utf8))
    } else if let found = shots.first(where: { $0.name == entry.shot }) {
      shot = found
    } else {
      fputs("FAIL: \(entry.id) names no shot in showcase.json\n", stderr); exit(1)
    }
    if let path = shot.usd ?? shot.mitsuba ?? shot.obj, !FileManager.default.fileExists(atPath: path) {
      print("\(entry.id): skipped, \(path) is missing")
      skipped.append(entry.id)
      continue
    }
    shot.name = "thumbnail-" + entry.id
    (shot.width, shot.height, shot.samples) = (960, 540, min(shot.samples ?? 256, 256))
    (shot.denoise, shot.raw, shot.keepRaw) = (false, false, nil)
    // A failed render leaves no image, so the bundle check and the tests see it instead of a stale one.
    let jpeg = thumbnailFolder.appendingPathComponent(entry.id + ".jpg")
    try? FileManager.default.removeItem(at: jpeg)
    do {
      let png = try render(shot)
      try writeThumbnail(png, to: jpeg)
      try? FileManager.default.removeItem(at: png)
      print("\(entry.id): wrote Examples/Thumbnails/\(entry.id).jpg")
    } catch {
      print("\(entry.id): failed, \(error.localizedDescription)")
      failed.append(entry.id)
    }
  }
  if !skipped.isEmpty { print("Skipped (files not installed): " + skipped.joined(separator: ", ")) }
  if !failed.isEmpty { print("FAILED: " + failed.joined(separator: ", ")); exit(1) }
  if skipped.isEmpty { print("All thumbnails rendered") }
} else {
  for shot in shots {
    do { _ = try render(shot) } catch let failure as ExportFailure {
      fputs((failure.errorDescription ?? "FAIL") + "\n", stderr)
      exit(1)
    }
  }
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
    mode = ['--thumbnails', str(thumbnail_folder), *arguments.only] if arguments.thumbnails else []
    sys.exit(subprocess.run([str(binary), str(shot_file), str(arguments.out.resolve()), *mode],
                            cwd=harness.ROOT, env=environment).returncode)
