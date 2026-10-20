import Foundation
import simd

// REFERENCES.md: OBJ2026, OPENUSD. The document's indexed mesh (docs/SCENE_STORAGE_DESIGN.md,
// phase 3). Vertices hold position, normal and UV as exact floats (MeshVertex, 32 bytes); faces
// hold three vertex indices and their subset (MeshFace, 16 bytes) — the encoding the GPU streams
// use, so publishing copies vertices and permutes faces instead of re-encoding triangles. A face
// rebuilds the MeshTriangle the renderer reads (corners w = 1, normals w = 0, uvc.z the subset,
// uvc.w and na.w 0), which is every field a scene-graph asset may carry (SceneGraph.validate).
struct MeshGeometry {
  var vertices: [MeshVertex] = []
  var faces: [MeshFace] = []
  var count: Int { faces.count }
  var isEmpty: Bool { faces.isEmpty }

  init() {}
  init(vertices: [MeshVertex], faces: [MeshFace]) {
    self.vertices = vertices
    self.faces = faces
  }
  // Welds triangles whose corner attributes are bit-identical (0 and -0 stay distinct).
  init<C: Collection>(triangles: C) where C.Element == MeshTriangle {
    var builder = Builder(reserving: triangles.count)
    for t in triangles { builder.add(t) }
    self = builder.geometry
  }
  func triangle(_ i: Int) -> MeshTriangle {
    vertices.withUnsafeBufferPointer { MeshTriangle(face: faces[i], vertices: $0.baseAddress!) }
  }
  var triangles: [MeshTriangle] { (0..<count).map(triangle) }
  // Equal vertex and face bytes (shared storage compares in constant time).
  func same(as other: MeshGeometry) -> Bool { sameBytes(vertices, other.vertices) && sameBytes(faces, other.faces) }
  var bytes: Int { vertices.count * MemoryLayout<MeshVertex>.stride + faces.count * MemoryLayout<MeshFace>.stride }

  // Incremental welding: corners with identical attribute bits share a vertex.
  struct Builder {
    private var index: [SIMD8<UInt32>: UInt32] = [:]
    var geometry = MeshGeometry()
    init(reserving triangles: Int = 0) {
      index.reserveCapacity(triangles)
      geometry.vertices.reserveCapacity(triangles)
      geometry.faces.reserveCapacity(triangles)
    }
    mutating func vertex(_ value: MeshVertex) -> UInt32 {
      let key = unsafeBitCast(value, to: SIMD8<UInt32>.self)
      if let i = index[key] { return i }
      let i = UInt32(geometry.vertices.count)
      geometry.vertices.append(value)
      index[key] = i
      return i
    }
    mutating func add(_ t: MeshTriangle) {
      let subset = t.uvc.z.isFinite && t.uvc.z >= 0 && t.uvc.z < 4e9 ? UInt32(t.uvc.z) : 0
      geometry.faces.append(MeshFace(
        vertex(MeshVertex(t.a.x, t.a.y, t.a.z, t.na.x, t.na.y, t.na.z, t.uvab.x, t.uvab.y)),
        vertex(MeshVertex(t.b.x, t.b.y, t.b.z, t.nb.x, t.nb.y, t.nb.z, t.uvab.z, t.uvab.w)),
        vertex(MeshVertex(t.c.x, t.c.y, t.c.z, t.nc.x, t.nc.y, t.nc.z, t.uvc.x, t.uvc.y)), subset))
    }
  }

  // Project format 4 payload: "VTMESH01", vertex and face counts (UInt32 LE), then the vertices
  // (8 x Float32 LE each) and faces (4 x UInt32 LE each).
  static let magic = Data("VTMESH01".utf8)
  var payload: Data {
    var data = Self.magic
    var counts = [UInt32(vertices.count).littleEndian, UInt32(faces.count).littleEndian]
    data.append(Data(bytes: &counts, count: 8))
    vertices.withUnsafeBytes { data.append(contentsOf: $0) }
    faces.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
  }
  init(payload data: Data, maximumFaces: Int) throws {
    func invalid(_ reason: String) -> Error { MaterialLibrary.error("Invalid mesh data: \(reason)") }
    guard data.count >= 16, data.prefix(8) == Self.magic else { throw invalid("missing header.") }
    let counts = data.subdata(in: data.startIndex + 8..<data.startIndex + 16).withUnsafeBytes {
      (Int(UInt32(littleEndian: $0.load(as: UInt32.self))), Int(UInt32(littleEndian: $0.load(fromByteOffset: 4, as: UInt32.self))))
    }
    let (vertexCount, faceCount) = counts
    guard faceCount <= maximumFaces, vertexCount <= 3 * faceCount,
      data.count == 16 + vertexCount * MemoryLayout<MeshVertex>.stride + faceCount * MemoryLayout<MeshFace>.stride
    else { throw invalid("counts do not match the payload.") }
    let base = data.startIndex + 16
    vertices = [MeshVertex](unsafeUninitializedCapacity: vertexCount) { b, initialized in
      data.copyBytes(to: UnsafeMutableRawBufferPointer(b), from: base..<base + vertexCount * MemoryLayout<MeshVertex>.stride)
      initialized = vertexCount
    }
    let faceBase = base + vertexCount * MemoryLayout<MeshVertex>.stride
    faces = [MeshFace](unsafeUninitializedCapacity: faceCount) { b, initialized in
      data.copyBytes(to: UnsafeMutableRawBufferPointer(b), from: faceBase..<faceBase + faceCount * MemoryLayout<MeshFace>.stride)
      initialized = faceCount
    }
  }
}
