"""Measures the resident GPU memory of a published two-level mesh (docs/SCENE_STORAGE_DESIGN.md).

Usage: python3 scripts/measure_mesh_memory.py [triangles ...]   (default: 1000000)

Publishes one scene-graph asset (a welded, displaced grid of about N triangles, every interior
vertex shared by six triangles) through the production MaterialLibrary, with software two-level
and with hardware traversal, and prints the bytes per triangle of the faces, vertices, BLAS nodes
and hardware structures, the total `meshBytes`, and the publish time. A development tool; it
compiles the production sources like tests/benchmark.py and is not part of the suite.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
import harness  # noqa: E402

counts = [int(a) for a in sys.argv[1:]] or [1_000_000]
driver = r'''
import Foundation
func grid(_ cells: Int) -> [MeshTriangle] {
  func p(_ i: Int, _ j: Int) -> SIMD4<Float> {
    let x = Float(i) / Float(cells) * 2 - 1, z = Float(j) / Float(cells) * 2 - 1
    return SIMD4(x, 0.3 * sin(1.7 * x + 0.3) * cos(1.3 * z) + 0.05 * x, z, 1)
  }
  let up = SIMD4<Float>(0, 1, 0, 0)
  func uv(_ i: Int, _ j: Int) -> SIMD2<Float> { SIMD2(Float(i) / Float(cells), Float(j) / Float(cells)) }
  var t: [MeshTriangle] = []
  t.reserveCapacity(2 * cells * cells)
  func tri(_ a: (Int, Int), _ b: (Int, Int), _ c: (Int, Int)) -> MeshTriangle {
    let ua = uv(a.0, a.1), ub = uv(b.0, b.1), uc = uv(c.0, c.1)
    return MeshTriangle(a: p(a.0, a.1), b: p(b.0, b.1), c: p(c.0, c.1), na: up, nb: up, nc: up,
      uvab: SIMD4(ua.x, ua.y, ub.x, ub.y), uvc: SIMD4(uc.x, uc.y, 0, 0))
  }
  for i in 0..<cells { for j in 0..<cells {
    if (i + j) % 2 == 0 { t += [tri((i, j), (i + 1, j), (i + 1, j + 1)), tri((i, j), (i + 1, j + 1), (i, j + 1))] }
    else { t += [tri((i, j), (i + 1, j), (i, j + 1)), tri((i + 1, j), (i + 1, j + 1), (i, j + 1))] }
  } }
  return t
}
for requested in CommandLine.arguments.dropFirst().compactMap({ Int($0) }) {
  let cells = Int((Double(requested) / 2).squareRoot().rounded())
  let triangles = grid(cells)
  var graph = SceneGraph()
  let material = try graph.addMaterial("M")
  let asset = MeshAsset(name: "grid", triangles: triangles, subsets: ["S"])
  graph.assets.append(asset)
  graph.nodes.append(SceneNode(name: "grid", mesh: asset.id, transform: ObjectSettings(positionScale: SIMD4(0, 0, 0, 1)), bindings: [material.id]))
  for mode in [MeshAcceleration.twoLevel, .hardware] where mode != .hardware || gpu.supportsRaytracing {
    let library = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
    library.acceleration = mode
    library.meshBudgetOverride = 12 << 30
    let start = Date()
    try library.setMesh(graph)
    let seconds = Date().timeIntervalSince(start)
    let s = library.meshStreams!, n = Double(triangles.count)
    let structures = library.meshLayout!.structures.reduce(0) { $0 + $1.allocatedSize }
    let vertices = library.meshLayout!.assets[0].vertexCount
    print(String(format: "%@ %d triangles, %d vertices (%.2f per triangle): faces %.1f, vertices %.1f, BLAS nodes %.1f, hardware %.1f, total meshBytes %.1f B/triangle (%.0f MiB); publish %.2f s",
      "\(mode)", triangles.count, vertices, Double(vertices) / n, Double(s.faces.length) / n, Double(s.vertices.length) / n,
      Double(s.nodes.length) / n, Double(structures) / n, Double(library.meshBytes) / n, Double(library.meshBytes) / 1_048_576, seconds))
  }
}
'''
source = (harness.production_source() + '\n' + harness.gpu_helpers() + '\n'
          + harness.replace_once(driver, 'import Foundation\n', '', 'driver'))
with tempfile.TemporaryDirectory(prefix='vibe-tracer-memory-') as directory:
    binary = harness.compile_swift(source, Path(directory), 'MeshMemory')
    environment = {**os.environ, 'VIBE_TRACER_REPOSITORY': str(harness.ROOT),
                   harness.OUTPUT_VARIABLE: str(Path(directory) / 'output')}
    sys.exit(subprocess.run([str(binary)] + [str(c) for c in counts], cwd=harness.ROOT, env=environment).returncode)
