// Measures Metal hardware acceleration structures for candidate mesh layouts
// (docs/SCENE_STORAGE_DESIGN.md, phase 0). Not part of the app or the test suite.
//
//   xcrun swiftc -O -swift-version 6 scripts/measure_acceleration.swift -o build/measure_acceleration
//   build/measure_acceleration [triangles...]        (default: 1000000 10000000)
//
// 1. Watertightness: rays aimed at every shared edge and vertex of a curved patch, from six eyes,
//    through an identity instance and a rotated, scaled, translated one (the METALRT gate of
//    Sources/Acceleration.swift), for each layout and usage flag. Any miss is a leak.
// 2. Size and speed: a welded, displaced grid of N triangles. Per layout and flag: the compacted
//    BLAS size (bytes per triangle), the build and compaction time, and closest-hit throughput
//    for random rays from inside the grid's bounding box.
import Foundation
import Metal
import simd

struct Layout {
  let name: String
  let welded: Bool       // shared vertices through an index buffer
  let stride: Int        // vertex stride in bytes
  let indexed: Bool      // index buffer present (unwelded layouts may still index)
  let production: Bool   // the MeshTriangle layout: stride 16, indices 8k, 8k+1, 8k+2
}
let layouts = [
  Layout(name: "unwelded-meshtriangle (production)", welded: false, stride: 16, indexed: true, production: true),
  Layout(name: "unwelded-packed12", welded: false, stride: 12, indexed: false, production: false),
  Layout(name: "unwelded-packed12-indexed", welded: false, stride: 12, indexed: true, production: false),
  Layout(name: "welded-packed12", welded: true, stride: 12, indexed: true, production: false),
  Layout(name: "welded-stride16", welded: true, stride: 16, indexed: true, production: false),
]
var usages: [(String, MTLAccelerationStructureUsage)] = [("none", [])]
if #available(macOS 26.0, *) {
  usages.append(("minimizeMemory", .minimizeMemory))
  usages.append(("preferFastIntersection", .preferFastIntersection))
}

guard let device = MTLCreateSystemDefaultDevice(), device.supportsRaytracing, let queue = device.makeCommandQueue() else {
  print("No Metal device with ray tracing."); exit(1)
}
print("Device: \(device.name), \(ProcessInfo.processInfo.operatingSystemVersionString)")

// MARK: Geometry
struct Mesh { var positions: [SIMD3<Float>]; var indices: [UInt32] }
// A (cells+1)^2 grid on [-1,1]^2, displaced into a smooth curved surface, alternating diagonals.
func grid(_ cells: Int, amplitude: Float = 0.15) -> Mesh {
  var p: [SIMD3<Float>] = []
  p.reserveCapacity((cells + 1) * (cells + 1))
  for i in 0...cells {
    for j in 0...cells {
      let x = Float(i) / Float(cells) * 2 - 1, z = Float(j) / Float(cells) * 2 - 1
      p.append(SIMD3(x, amplitude * sin(1.7 * x + 0.3) * cos(1.3 * z) + 0.05 * x, z))
    }
  }
  var idx: [UInt32] = []
  idx.reserveCapacity(cells * cells * 6)
  let w = UInt32(cells + 1)
  for i in 0..<UInt32(cells) {
    for j in 0..<UInt32(cells) {
      let a = i * w + j, b = (i + 1) * w + j, c = (i + 1) * w + j + 1, d = i * w + j + 1
      idx += (i + j) % 2 == 0 ? [a, b, c, a, c, d] : [a, b, d, b, c, d]
    }
  }
  return Mesh(positions: p, indices: idx)
}

func buffer<T>(_ array: [T]) -> MTLBuffer {
  array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(16, $0.count), options: .storageModeShared)! }
}

// Vertex and index buffers for a layout.
func geometry(_ mesh: Mesh, _ layout: Layout) -> MTLAccelerationStructureTriangleGeometryDescriptor {
  let g = MTLAccelerationStructureTriangleGeometryDescriptor()
  let triangles = mesh.indices.count / 3
  var floats: [Float] = []
  var indices: [UInt32] = []
  if layout.welded {
    let per = layout.stride / 4
    floats.reserveCapacity(mesh.positions.count * per)
    for v in mesh.positions { floats += [v.x, v.y, v.z]; if per == 4 { floats.append(1) } }
    indices = mesh.indices
  } else if layout.production {
    // MeshTriangle records: a, b, c then five unused float4s, 128 bytes per triangle.
    floats.reserveCapacity(triangles * 32)
    for t in 0..<triangles {
      for k in 0..<3 { let v = mesh.positions[Int(mesh.indices[3 * t + k])]; floats += [v.x, v.y, v.z, 1] }
      floats += [Float](repeating: 0, count: 20)
    }
    indices.reserveCapacity(triangles * 3)
    for t in 0..<UInt32(triangles) { indices += [8 * t, 8 * t + 1, 8 * t + 2] }
  } else {
    floats.reserveCapacity(triangles * 9)
    for i in mesh.indices { let v = mesh.positions[Int(i)]; floats += [v.x, v.y, v.z] }
    if layout.indexed { indices = (0..<UInt32(triangles * 3)).map { $0 } }
  }
  g.vertexBuffer = buffer(floats)
  g.vertexStride = layout.stride
  g.vertexFormat = .float3
  if !indices.isEmpty { g.indexBuffer = buffer(indices); g.indexType = .uint32 }
  g.triangleCount = triangles
  g.opaque = true
  return g
}

// MARK: Building
func run(_ body: (MTLCommandBuffer) -> Void) -> Double {
  let command = queue.makeCommandBuffer()!
  body(command)
  command.commit(); command.waitUntilCompleted()
  precondition(command.status == .completed, "command failed: \(String(describing: command.error))")
  return command.gpuEndTime - command.gpuStartTime
}
// Builds and compacts; returns the compacted structure, its size and GPU build + compaction time.
func build(_ descriptor: MTLAccelerationStructureDescriptor) -> (MTLAccelerationStructure, Int, Double) {
  let sizes = device.accelerationStructureSizes(descriptor: descriptor)
  let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize)!
  let scratch = device.makeBuffer(length: max(16, sizes.buildScratchBufferSize), options: .storageModePrivate)!
  let sizeBuffer = device.makeBuffer(length: 8, options: .storageModeShared)!
  var time = run { c in
    let e = c.makeAccelerationStructureCommandEncoder()!
    e.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
    e.writeCompactedSize(accelerationStructure: structure, buffer: sizeBuffer, offset: 0, sizeDataType: .ulong)
    e.endEncoding()
  }
  let compactedSize = Int(sizeBuffer.contents().load(as: UInt64.self))
  let compacted = device.makeAccelerationStructure(size: compactedSize)!
  time += run { c in
    let e = c.makeAccelerationStructureCommandEncoder()!
    e.copyAndCompact(sourceAccelerationStructure: structure, destinationAccelerationStructure: compacted)
    e.endEncoding()
  }
  return (compacted, compacted.allocatedSize, time)
}
func primitive(_ g: MTLAccelerationStructureTriangleGeometryDescriptor, _ usage: MTLAccelerationStructureUsage) -> MTLPrimitiveAccelerationStructureDescriptor {
  let d = MTLPrimitiveAccelerationStructureDescriptor()
  d.geometryDescriptors = [g]
  d.usage = usage
  return d
}
func scene(_ blas: MTLAccelerationStructure, transforms: [simd_float4x4]) -> MTLAccelerationStructure {
  var instances = transforms.map { m -> MTLAccelerationStructureInstanceDescriptor in
    var i = MTLAccelerationStructureInstanceDescriptor()
    i.transformationMatrix = MTLPackedFloat4x3(columns: (
      MTLPackedFloat3Make(m.columns.0.x, m.columns.0.y, m.columns.0.z), MTLPackedFloat3Make(m.columns.1.x, m.columns.1.y, m.columns.1.z),
      MTLPackedFloat3Make(m.columns.2.x, m.columns.2.y, m.columns.2.z), MTLPackedFloat3Make(m.columns.3.x, m.columns.3.y, m.columns.3.z)))
    i.options = .opaque; i.mask = 0xff; i.accelerationStructureIndex = 0
    return i
  }
  let top = MTLInstanceAccelerationStructureDescriptor()
  top.instancedAccelerationStructures = [blas]
  top.instanceCount = instances.count
  top.instanceDescriptorBuffer = device.makeBuffer(bytes: &instances, length: MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride * instances.count, options: .storageModeShared)
  return build(top).0
}

// MARK: Kernels
let source = """
  #include <metal_stdlib>
  #include <metal_raytracing>
  using namespace metal;
  using namespace raytracing;
  // gid.y: eye (0-5) for instance 0, eye (6-11) for instance 1 with its transform applied.
  kernel void leaks(instance_acceleration_structure scene [[buffer(0)]], device atomic_uint *out [[buffer(1)]],
      device const float4 *targets [[buffer(2)]], constant uint &count [[buffer(3)]], constant float4x4 &rotated [[buffer(4)]],
      uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= count) return;
      float3 eyes[6] = {float3(0.3f,3,0.2f), float3(4,3.5f,-3), float3(-7,6,5), float3(0.05f,20,0.01f), float3(2.5f,1.8f,1.7f), float3(-0.4f,9,-12)};
      float4x4 m = gid.y < 6 ? float4x4(1) : rotated;
      float3 eye = (m * float4(eyes[gid.y % 6], 1)).xyz, target = (m * float4(targets[gid.x].xyz, 1)).xyz;
      ray r(eye, normalize(target - eye), 0.0f, length(target - eye) * 1.001f + 1e-3f);
      intersector<instancing> closest; closest.assume_geometry_type(geometry_type::triangle);
      intersector<instancing> any; any.assume_geometry_type(geometry_type::triangle); any.accept_any_intersection(true);
      atomic_fetch_add_explicit(&out[0], 1, memory_order_relaxed);
      if (closest.intersect(r, scene).type != intersection_type::triangle) atomic_fetch_add_explicit(&out[1], 1, memory_order_relaxed);
      if (any.intersect(r, scene).type != intersection_type::triangle) atomic_fetch_add_explicit(&out[2], 1, memory_order_relaxed);
  }
  // Incoherent closest-hit rays: origins inside the grid's box, uniform directions.
  uint pcg(thread uint &s) { s = s * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
  float rnd(thread uint &s) { return float(pcg(s) >> 8) * (1.0f / 16777216.0f); }
  kernel void throughput(instance_acceleration_structure scene [[buffer(0)]], device atomic_uint *hits [[buffer(1)]],
      constant uint &pass [[buffer(2)]], uint gid [[thread_position_in_grid]]) {
      uint s = gid * 9781u + pass * 6271u + 1u;
      float3 o = float3(rnd(s) * 2 - 1, rnd(s) * 0.6f - 0.3f, rnd(s) * 2 - 1);
      float z = rnd(s) * 2 - 1, a = rnd(s) * 6.2831853f, q = sqrt(max(0.0f, 1 - z * z));
      ray r(o, float3(q * cos(a), z, q * sin(a)), 1e-4f, 10.0f);
      intersector<instancing> closest; closest.assume_geometry_type(geometry_type::triangle);
      if (closest.intersect(r, scene).type == intersection_type::triangle) atomic_fetch_add_explicit(hits, 1, memory_order_relaxed);
  }
  """
let library = try! device.makeLibrary(source: source, options: nil)
let leakPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "leaks")!)
let throughputPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "throughput")!)

// MARK: 1. Watertightness
var rotated = simd_float4x4(simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3)))) * simd_float4x4(diagonal: SIMD4(3, 3, 3, 1))
rotated.columns.3 = SIMD4(10, 0, 0, 1)
let patchCells = 16
let patch = grid(patchCells)
var targets: [SIMD4<Float>] = []
let w = patchCells + 1
for i in 0..<patchCells {
  for j in 0..<patchCells {
    let a = patch.positions[i * w + j], b = patch.positions[(i + 1) * w + j], c = patch.positions[(i + 1) * w + j + 1], d = patch.positions[i * w + j + 1]
    if i > 0 && j > 0 { targets.append(SIMD4(a, 0)) }
    for f in [Float(0.25), 0.5, 0.75] {
      if j > 0 { targets.append(SIMD4(a + (b - a) * f, 0)) }
      if i > 0 { targets.append(SIMD4(a + (d - a) * f, 0)) }
      targets.append(SIMD4((i + j) % 2 == 0 ? a + (c - a) * f : b + (d - b) * f, 0))
    }
  }
}
let targetBuffer = buffer(targets)
print("\n1. Watertightness: \(targets.count) shared-edge/vertex targets x 6 eyes x 2 instances = \(targets.count * 12) rays per case")
print("layout | usage | closest-hit leaks | any-hit leaks")
for layout in layouts {
  for (usageName, usage) in usages {
    let (blas, _, _) = build(primitive(geometry(patch, layout), usage))
    let tlas = scene(blas, transforms: [matrix_identity_float4x4, rotated])
    let out = device.makeBuffer(length: 16, options: .storageModeShared)!
    memset(out.contents(), 0, 16)
    var count = UInt32(targets.count), m = rotated
    _ = run { c in
      let e = c.makeComputeCommandEncoder()!
      e.setComputePipelineState(leakPipeline)
      e.setAccelerationStructure(tlas, bufferIndex: 0); e.useResource(blas, usage: .read)
      e.setBuffer(out, offset: 0, index: 1); e.setBuffer(targetBuffer, offset: 0, index: 2)
      e.setBytes(&count, length: 4, index: 3); e.setBytes(&m, length: 64, index: 4)
      e.dispatchThreads(MTLSize(width: targets.count, height: 12, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
      e.endEncoding()
    }
    let r = (0..<3).map { out.contents().load(fromByteOffset: 4 * $0, as: UInt32.self) }
    precondition(r[0] == UInt32(targets.count * 12))
    print("\(layout.name) | \(usageName) | \(r[1]) | \(r[2])")
  }
}

// MARK: 2. Size, build time, throughput
let sizes = CommandLine.arguments.dropFirst().compactMap { Int($0) }
for requested in sizes.isEmpty ? [1_000_000, 10_000_000] : sizes {
  let cells = Int((Double(requested) / 2).squareRoot().rounded())
  let mesh = grid(cells, amplitude: 0.3)
  let triangles = mesh.indices.count / 3
  print("\n2. \(triangles) triangles (\(mesh.positions.count) welded vertices)")
  print("layout | usage | compacted MiB | B/triangle | build+compact ms | Mrays/s")
  for layout in layouts {
    let g = geometry(mesh, layout)
    let input = g.vertexBuffer!.length + (g.indexBuffer?.length ?? 0)
    for (usageName, usage) in usages {
      let (blas, bytes, seconds) = build(primitive(g, usage))
      let tlas = scene(blas, transforms: [matrix_identity_float4x4])
      let hits = device.makeBuffer(length: 4, options: .storageModeShared)!
      let rays = 1 << 22
      var best = Double.infinity
      for pass in 0..<4 {
        var p = UInt32(pass)
        let t = run { c in
          let e = c.makeComputeCommandEncoder()!
          e.setComputePipelineState(throughputPipeline)
          e.setAccelerationStructure(tlas, bufferIndex: 0); e.useResource(blas, usage: .read)
          e.setBuffer(hits, offset: 0, index: 1); e.setBytes(&p, length: 4, index: 2)
          e.dispatchThreads(MTLSize(width: rays, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
          e.endEncoding()
        }
        if pass > 0 { best = min(best, t) }  // pass 0 warms caches
      }
      print(String(format: "%@ | %@ | %.1f | %.1f | %.0f | %.0f   (input buffers %.1f MiB)",
        layout.name, usageName, Double(bytes) / 1_048_576, Double(bytes) / Double(triangles), seconds * 1000,
        Double(rays) / best / 1e6, Double(input) / 1_048_576))
    }
  }
}
