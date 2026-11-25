"""Profiles the frame's GPU passes: GPU time per pass and, optionally, register spills.

Usage: python3 scripts/measure_passes.py [--frames N] [--moving N] [--size WxH] [--only NAME ...] [--large]
                                         [--depth N] [--rgb] [--reuse RAW] [--define NAME=VALUE ...] [--spills]

For each case, renders --frames still (accumulating) frames and then --moving frames while the
camera orbits, one sample per frame, at --size and preview scale 1, and prints the GPU time per
frame (the median over the frames, since the M4 changes its GPU clock under sustained load)
of each compute pass that PathTracerRenderer.encodeSample encodes (PassTimer: timestamps at
encoder boundaries, summed per encoder label). Time outside those passes (blits, the MetalFX and
display passes) is the difference from the command buffer's GPU time.

The default cases are small fixtures that render in seconds: the procedural Cornell box and
Pavilion (ReSTIR GI), a generated UV sphere with a glossy OBJ material on a matte floor (8,192
triangles; unified ReSTIR PT through the layered OpenPBR BSDF), 25 instances of a bumpy patch
(499,200 rendered triangles, as in tests/benchmark.py) and, when build/reference-scenes holds it,
the ASWF Shader Ball project. --large adds Sponza and two of Bitterli's Mitsuba scenes from
build/scenes. --depth, --rgb and --reuse override the path depth, light transport and indirect reuse;
--define puts a #define before all shader source (for example VIBE_OPENPBR_EnableMetallic=0).

The compiled binary is cached in build/measure-passes by the hash of its Swift source. The shaders
are not part of that source: the binary reads the MSL of main.swift's `metalSource` literal from a
file at run time, so an edit to the shaders alone reuses the binary. With --spills, each case runs in
its own process under `xctrace record --template 'Metal System Trace'` and the script lists the
register spill sizes the trace reports per encoder (the trace merges consecutive compute encoders'
labels).

A development tool (docs/KERNEL_SPLIT_DESIGN.md); it compiles the production sources like
tests/benchmark.py and is not part of the suite. Cases whose files are missing are skipped.
"""
import argparse
import collections
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
import harness  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('--frames', type=int, default=24)
parser.add_argument('--moving', type=int, default=12)
parser.add_argument('--size', default='480x270')
parser.add_argument('--only', nargs='*', default=[])
parser.add_argument('--large', action='store_true', help='add Sponza, Kitchen and Living Room')
parser.add_argument('--depth', type=int, help='path depth override (StudioOptions.depth)')
parser.add_argument('--rgb', action='store_true', help='RGB instead of the default spectral transport')
parser.add_argument('--reuse', type=int, help='IndirectReuse raw value override (ProjectDocument.indirectReuse)')
parser.add_argument('--define', action='append', default=[], metavar='NAME=VALUE',
                    help='a #define before all shader source, OpenPBR included (repeatable)')
parser.add_argument('--spills', action='store_true')
parser.add_argument('--keep', help='folder that keeps the traces')
arguments = parser.parse_args()
width, height = (int(v) for v in arguments.size.split('x'))

ROOT = harness.ROOT
SCENES = ROOT / 'build' / 'scenes'
REFERENCE = ROOT / 'build' / 'reference-scenes'
CASES = [
    {'name': 'cornell', 'scene': 1},
    {'name': 'pavilion', 'scene': 0},
    {'name': 'sphere', 'fixture': 'sphere'},
    {'name': 'patches', 'fixture': 'patches'},
    {'name': 'shaderball', 'project': str(REFERENCE / 'StandardShaderBall.vtrace')},
]
LARGE = [
    {'name': 'sponza', 'obj': str(SCENES / 'sponza/sponza.obj'),
     'target': [-300, 350, -30], 'yaw': -1.5708, 'pitch': 0.05, 'distance': 1000, 'fov': 65},
    {'name': 'kitchen', 'mitsuba': str(SCENES / 'kitchen/kitchen/scene_v3.xml')},
    {'name': 'living-room', 'mitsuba': str(SCENES / 'living-room/living-room/scene_v3.xml')},
]
cases = CASES + (LARGE if arguments.large or any(c['name'] in arguments.only for c in LARGE) else [])
cases = [c for c in cases if not arguments.only or c['name'] in arguments.only]
cases = [c for c in cases if all(Path(c[k]).exists() for k in ('obj', 'mitsuba', 'project') if k in c)]

# The UV sphere of tests/benchmark.py on a floor quad, with a glossy (layered OpenPBR) sphere material.
SPHERE_MTL = 'newmtl Floor\nKd 0.6 0.6 0.6\n\nnewmtl Glossy\nKd 0.7 0.25 0.1\nKs 0.5 0.5 0.5\nNs 250\n'


def sphere_obj() -> str:
    lines = ['mtllib sphere.mtl', 'v -3 -1 -3', 'v 3 -1 -3', 'v 3 -1 3', 'v -3 -1 3']
    rings = segments = 64
    for i in range(rings + 1):
        for j in range(segments):
            theta, phi = math.pi * i / rings, 2 * math.pi * j / segments
            lines.append(f'v {0.6 * math.sin(theta) * math.cos(phi):.6f} {-0.4 + 0.6 * math.cos(theta):.6f} '
                         f'{0.6 * math.sin(theta) * math.sin(phi):.6f}')
    lines += ['usemtl Floor', 'f 1 4 3 2', 'usemtl Glossy']
    for i in range(rings):
        for j in range(segments):
            a, b = 5 + i * segments + j, 5 + i * segments + (j + 1) % segments
            lines.append(f'f {a} {b} {b + segments} {a + segments}')
    return '\n'.join(lines) + '\n'


driver = r'''
struct Case: Decodable {
  var name: String, scene: UInt32?, obj: String?, mitsuba: String?, project: String?, fixture: String?
  var target: [Float]?, yaw: Float?, pitch: Float?, distance: Float?, fov: Float?
}
@MainActor func waitFor(_ condition: () -> Bool, seconds: Double) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
  return condition()
}
// 25 rotated instances of one bumpy 19,968-triangle patch (tests/benchmark.py).
func instancedPatches() throws -> SceneGraph {
  var graph = SceneGraph()
  let cells = 100
  var grid: [[SIMD3<Float>]] = []
  for i in 0...cells { grid.append((0...cells).map { j in
    let x = Float(i) / Float(cells) * 2 - 1, z = Float(j) / Float(cells) * 2 - 1
    return SIMD3(x, 0.12 * sin(9 * x) * cos(7 * z) + 0.05 * sin(23 * x + 17 * z), z) }) }
  func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> MeshTriangle {
    let n = simd_normalize(simd_cross(b - a, c - a))
    return MeshTriangle(a: SIMD4(a, 1), b: SIMD4(b, 1), c: SIMD4(c, 1), na: SIMD4(n, 0), nb: SIMD4(n, 0), nc: SIMD4(n, 0),
                        uvab: SIMD4(a.x, a.z, b.x, b.z), uvc: SIMD4(c.x, c.z, 0, 0))
  }
  var patch: [MeshTriangle] = []
  for i in 0..<cells { for j in 0..<cells {
    let a = grid[i][j], b = grid[i + 1][j], c = grid[i + 1][j + 1], d = grid[i][j + 1]
    patch += [triangle(a, b, c), triangle(a, c, d)]
  }}
  let material = try graph.addMaterial("Patch")
  let asset = MeshAsset(name: "patch", triangles: patch, subsets: ["Patch"])
  graph.assets.append(asset)
  for k in 0..<25 {
    var o = ObjectSettings()
    o.positionScale = SIMD4(Float(k % 5) * 0.9 - 1.6, -0.75 + 0.1 * Float(k % 3), Float(k / 5) * 0.9 - 1.1, 0.42)
    o.rotationHidden = SIMD4(0, Float(k) * 0.61, 0, 0)
    graph.nodes.append(SceneNode(name: "patch \(k)", mesh: asset.id, transform: o, bindings: [material.id]))
  }
  try graph.validate()
  return graph
}
let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let cases = try JSONDecoder().decode([Case].self, from: JSONSerialization.data(withJSONObject: config["cases"]!))
let frames = config["frames"] as! Int, moving = config["moving"] as! Int
let width = config["width"] as! Int, height = config["height"] as! Int
let renderer = controller.renderer
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
let out = renderer.device.makeTexture(descriptor: descriptor)!
@MainActor func frame() {
  renderer.renderFrame(output: out, samples: 1)
  _ = waitFor({ renderer.completedSamples == renderer.frameIndex }, seconds: 30)
}
for c in cases {
  var p = ProjectDocument()
  if c.fixture == "patches" {
    p.scene = 6
    p.graph = try instancedPatches()
  } else if let path = c.obj {
    let url = URL(fileURLWithPath: path); var skipped = 0, report: [String] = []
    _ = try p.appendOBJ(try Data(contentsOf: url, options: .alwaysMapped), name: url.lastPathComponent,
      folder: url.deletingLastPathComponent(), skipped: &skipped, report: &report)
  } else if let path = c.mitsuba {
    p = try MitsubaImporter.load(URL(fileURLWithPath: path), into: ProjectDocument()).document
  } else if let path = c.project {
    let url = URL(fileURLWithPath: path)
    p = try ProjectDocument.decodeProject(try Data(contentsOf: url, options: .alwaysMapped), near: url)
  } else {
    p.scene = c.scene ?? 0
    testRenderer.sceneIndex = p.scene
    p.camera = CameraState(testRenderer)
  }
  if let v = c.target { p.camera.target = SIMD3(v[0], v[1], v[2]) }
  if let v = c.yaw { p.camera.yaw = v }
  if let v = c.pitch { p.camera.pitch = v }
  if let v = c.distance { p.camera.distance = v }
  if let v = c.fov { p.camera.fov = v }
  p.options.previewScale = 1
  p.options.maxSamples = 0; p.options.timeLimit = 0
  if let v = config["depth"] as? Int { p.options.depth = v }
  if config["rgb"] as? Bool == true { p.lightTransport = LightTransport.rgb.rawValue }
  if let v = config["reuse"] as? Int { p.indirectReuse = UInt32(v) }
  try controller.restore(p)
  renderer.paused = false
  // Background pipeline groups (ReSTIR PT, splatting, SPMIS, caustics, spectral) compile while frames render.
  let ready = waitFor({
    frame()
    return (renderer.sceneIndex != 6 || renderer.sceneKernels.pt != nil) && renderer.spectralShaders.kernels != nil
      && !renderer.spectralShaders.compiling
  }, seconds: 600)
  for _ in 0..<4 { frame() }
  let timer = PassTimer(device: renderer.device)!
  renderer.passTimer = timer
  var phases: [String: Any] = [:]
  for (phase, count) in [("still", frames), ("moving", moving)] {
    if phase == "still" { renderer.resetAccumulation() }
    // Per-frame times, so that the report can take medians: the M4 changes its GPU clock under sustained load.
    var passes: [String: [Double]] = [:], frameMs: [Double] = []
    for _ in 0..<count {
      if phase == "moving" { renderer.yaw += 0.01 }
      timer.reset()
      frame()
      timer.collect()
      for (label, ns) in timer.nanoseconds { passes[label, default: []].append(ns / 1e6) }
      frameMs.append(renderer.gpuMilliseconds)
    }
    phases[phase] = ["passes": passes, "frameMs": frameMs]
  }
  renderer.passTimer = nil
  let info: [String: Any] = ["name": c.name, "ready": ready, "spectral": renderer.spectralFrame,
    "indirectReuse": "\(renderer.activeIndirectReuse)", "phases": phases]
  print("INFO " + String(data: try JSONSerialization.data(withJSONObject: info), encoding: .utf8)!)
}
exit(0)
'''

OPENING = 'let metalSource = loadOpenPBRSource() + """\n'


def split_shaders(source: str) -> tuple:
    """(Swift source reading the MSL from $VIBE_MSL_PREFIX and $VIBE_MSL_SOURCE, the MSL of the metalSource literal)."""
    head, rest = harness.split_once(source, OPENING, 'main.swift')
    body, tail = rest.split('\n"""\n', 1)
    if '\\(' in body or re.search(r'\\[^\n]', body):
        raise SystemExit('measure_passes.py: the metalSource literal holds escapes other than line continuations')
    # A backslash before a newline continues the line in a Swift multi-line string literal.
    msl = body.replace('\\\n', '')
    reader = ('let metalSource = (try! String(contentsOfFile: ProcessInfo.processInfo.environment["VIBE_MSL_PREFIX"]!, '
              'encoding: .utf8)) + loadOpenPBRSource() + (try! String(contentsOfFile: '
              'ProcessInfo.processInfo.environment["VIBE_MSL_SOURCE"]!, encoding: .utf8))\n')
    return head + reader + tail, msl


def table(trace: Path, schema: str):
    """Rows of one xctrace table as {column: (text, formatted)}; xctrace's ref= duplicates are resolved."""
    xml = subprocess.run(['xcrun', 'xctrace', 'export', '--input', str(trace), '--xpath',
                          f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                         capture_output=True, text=True, check=True).stdout
    root = ET.fromstring(xml)
    ids = {e.get('id'): e for e in root.iter() if e.get('id')}
    columns = [c.findtext('mnemonic') for c in root.find('.//schema').findall('col')]
    for row in root.iter('row'):
        cells = {}
        for name, e in zip(columns, list(row)):
            e = ids.get(e.get('ref'), e)
            cells[name] = (e.text, e.get('fmt'))
        yield cells


def spill_summary(trace: Path) -> str:
    labels = {r['encoder-id'][0]: r['encoder-label'][1] for r in table(trace, 'metal-application-encoders-list')
              if 'encoder-id' in r and 'encoder-label' in r}
    sizes = collections.defaultdict(set)
    for r in table(trace, 'graphics-compiler-spill-events'):
        if 'Passes' in (r['process'][1] or ''):
            sizes[labels.get(r['encoder-id'][0], 'unlabelled')].add(int(r['spilled-bytes'][0]))
    lines = [f'      {max(v):>6} B spilled  {k}' for k, v in sorted(sizes.items(), key=lambda kv: -max(kv[1]))]
    return '   register spills:\n' + ('\n'.join(lines) if lines else '      none')


def report(info: dict):
    print(f'\n== {info["name"]}: {width}x{height}, reuse {info["indirectReuse"]}, spectral {info["spectral"]}, '
          f'kernels ready {info["ready"]}')
    for phase in ('still', 'moving'):
        data = info['phases'][phase]
        if not data['frameMs']:
            continue
        frame = statistics.median(data['frameMs'])
        spread = max(data['frameMs']) / max(min(data['frameMs']), 1e-9)
        passes = {label: statistics.median(v) for label, v in data['passes'].items()}
        print(f'   {phase}: median {frame:.2f} ms GPU per frame (max/min {spread:.2f}), '
              f'{sum(passes.values()):.2f} ms in timed passes')
        for label, ms in sorted(passes.items(), key=lambda kv: -kv[1]):
            print(f'      {ms:7.2f} ms  {100 * ms / max(frame, 1e-9):5.1f}%  {label}')


for script in ('prepare_shaders.py', 'generate_spectral_tables.py'):
    subprocess.run([sys.executable, str(ROOT / 'scripts' / script)], check=True, stdout=subprocess.DEVNULL)
subprocess.run([sys.executable, str(ROOT / 'scripts/prepare_oidn.py'), '--arch', platform.machine()], check=True,
               stdout=subprocess.DEVNULL)
swift, msl = split_shaders(harness.production_source() + '\nsetvbuf(stdout, nil, _IOLBF, 0)\n' + harness.gpu_helpers()
                           + '\n' + harness.studio_controller() + driver)
cache = ROOT / 'build' / 'measure-passes' / hashlib.sha256(swift.encode()).hexdigest()[:16]
binary = cache / 'Passes'
if not binary.exists():
    shutil.rmtree(ROOT / 'build' / 'measure-passes', ignore_errors=True)
    cache.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='vibe-tracer-passes-') as directory:
        shutil.copy(harness.compile_swift(swift, Path(directory), 'Passes'), binary)
with tempfile.TemporaryDirectory(prefix='vibe-tracer-passes-') as directory:
    work = Path(directory)
    (work / 'shaders.metal').write_text(msl)
    (work / 'prefix.metal').write_text(''.join(f'#define {d.replace("=", " ", 1)}\n' for d in arguments.define))
    (work / 'sphere.obj').write_text(sphere_obj())
    (work / 'sphere.mtl').write_text(SPHERE_MTL)
    for c in cases:
        if c.get('fixture') == 'sphere':
            c['obj'] = str(work / 'sphere.obj')
    folder = Path(arguments.keep) if arguments.keep else work
    folder.mkdir(parents=True, exist_ok=True)
    output = work / 'output'
    environment = {**os.environ, 'VIBE_TRACER_REPOSITORY': str(ROOT), harness.OUTPUT_VARIABLE: str(output),
                   'VIBE_MSL_SOURCE': str(work / 'shaders.metal'), 'VIBE_MSL_PREFIX': str(work / 'prefix.metal')}
    settings = {'frames': arguments.frames, 'moving': arguments.moving, 'width': width, 'height': height,
                'depth': arguments.depth, 'rgb': arguments.rgb, 'reuse': arguments.reuse}
    # One process for every case; one per case under xctrace, so that each trace holds one scene.
    for group in ([[c] for c in cases] if arguments.spills else [cases]):
        config = work / 'config.json'
        config.write_text(json.dumps({**settings, 'cases': group}))
        command = [str(binary), str(config)]
        trace = folder / f'{group[0]["name"]}.trace'
        if arguments.spills:
            shutil.rmtree(trace, ignore_errors=True)
            command = ['xcrun', 'xctrace', 'record', '--template', 'Metal System Trace', '--output', str(trace),
                       '--target-stdout', '-'] + [a for k, v in environment.items() if k.startswith('VIBE')
                                                  for a in ('--env', f'{k}={v}')] + ['--launch', '--'] + command
        result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, text=True)
        infos = [json.loads(m) for m in re.findall(r'^INFO (\{.*\})$', result.stdout, re.M)]
        for info in infos:
            report(info)
        if len(infos) < len(group):
            print(f'FAILED after {len(infos)} of {len(group)} cases\n{result.stdout[-3000:]}\n{result.stderr[-3000:]}')
        elif arguments.spills:
            print(spill_summary(trace))
