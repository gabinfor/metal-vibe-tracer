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
// A displaced (cells+1)^2 grid with shared vertices, built as indexed geometry directly.
func grid(_ cells: Int) -> MeshGeometry {
  var g = MeshGeometry()
  g.vertices.reserveCapacity((cells + 1) * (cells + 1))
  for i in 0...cells { for j in 0...cells {
    let x = Float(i) / Float(cells) * 2 - 1, z = Float(j) / Float(cells) * 2 - 1
    g.vertices.append(MeshVertex(x, 0.3 * sin(1.7 * x + 0.3) * cos(1.3 * z) + 0.05 * x, z, 0, 1, 0, Float(i) / Float(cells), Float(j) / Float(cells)))
  } }
  g.faces.reserveCapacity(2 * cells * cells)
  let w = UInt32(cells + 1)
  for i in 0..<UInt32(cells) { for j in 0..<UInt32(cells) {
    let a = i * w + j, b = (i + 1) * w + j, c = (i + 1) * w + j + 1, d = i * w + j + 1
    if (i + j) % 2 == 0 { g.faces += [MeshFace(a, b, c, 0), MeshFace(a, c, d, 0)] }
    else { g.faces += [MeshFace(a, b, d, 0), MeshFace(b, c, d, 0)] }
  } }
  return g
}
for requested in CommandLine.arguments.dropFirst().compactMap({ Int($0) }) {
  let cells = Int((Double(requested) / 2).squareRoot().rounded())
  let geometry = grid(cells)
  var graph = SceneGraph()
  let material = try graph.addMaterial("M")
  let asset = MeshAsset(name: "grid", geometry: geometry, subsets: ["S"])
  graph.assets.append(asset)
  graph.nodes.append(SceneNode(name: "grid", mesh: asset.id, transform: ObjectSettings(positionScale: SIMD4(0, 0, 0, 1)), bindings: [material.id]))
  for mode in [MeshAcceleration.twoLevel, .hardware] where mode != .hardware || gpu.supportsRaytracing {
    let library = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
    library.acceleration = mode
    library.meshBudgetOverride = 12 << 30
    let start = Date()
    try library.setMesh(graph)
    let seconds = Date().timeIntervalSince(start)
    let s = library.meshStreams!, n = Double(geometry.count)
    let structures = library.meshLayout!.structures.reduce(0) { $0 + $1.allocatedSize }
    let vertices = library.meshLayout!.assets[0].vertexCount
    print(String(format: "%@ %d triangles, %d vertices (%.2f per triangle): document %.1f; GPU faces %.1f, vertices %.1f, BLAS nodes %.1f, hardware %.1f, total meshBytes %.1f B/triangle (%.0f MiB); publish %.2f s",
      "\(mode)", geometry.count, vertices, Double(vertices) / n, Double(geometry.bytes) / n, Double(s.faces.length) / n, Double(s.vertices.length) / n,
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
