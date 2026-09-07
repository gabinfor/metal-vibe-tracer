import Cocoa
import CoreImage
import MetalKit
import simd

struct ObjectSettings: Codable {
  var positionScale = SIMD4<Float>(0, 0, 0, 1)
  var rotationHidden = SIMD4<Float>(repeating: 0)
  var uvTransform = SIMD4<Float>(repeating: 0)
  var channels = SIMD4<UInt32>(repeating: 0)
}
struct MeshTriangle: Codable {
  var a, b, c, na, nb, nc, uvab, uvc: SIMD4<Float>
}
struct MeshNode: Codable {
  var lo, hi: SIMD4<Float>
  var links: SIMD4<Int32>
}
struct CameraState: Codable {
  var yaw: Float = 0.42, pitch: Float = 0.22, distance: Float = 4.6, fov: Float = 38
  var target = SIMD3<Float>(0.15, -0.25, 0.7)
  init() {}
  init(_ r: PathTracerRenderer) {
    yaw = r.yaw
    pitch = r.pitch
    distance = r.distance
    fov = r.fov
    target = r.target
  }
  func apply(_ r: PathTracerRenderer) {
    r.yaw = yaw
    r.pitch = pitch
    r.distance = distance
    r.fov = fov
    r.target = target
  }
}
struct StudioOptions: Codable {
  var maxSamples: UInt32 = 0
  var timeLimit: Double = 0
  var previewScale: Float = 0.5
  var outputWidth = 1920, outputHeight = 1080
  var exportSamples: UInt32 = 128
  var depth: Float = 16
  var exposure: Float = 0
  var whiteBalance: Float = 0
  var toneMap: Float = 0
  var compare: Float = 0
  var sunAzimuth: Float = 133, sunElevation: Float = 27, sunIntensity: Float = 850
  var environmentIntensity: Float = 1, environmentRotation: Float = 0
  var lightColor = SIMD3<Float>(repeating: 1)
  var lightIntensity: Float = 1, lightSize: Float = 1
  var aperture: Float = 0, focusDistance: Float = 4.6
}
struct OIDNOptions: Codable, Equatable {
  // UI indices map to OIDN FAST (4), BALANCED (5), and HIGH (6).
  var quality: UInt32 = 2
  // 0 = color only, 1 = albedo, 2 = albedo + normal.
  var guides: UInt32 = 2
  var treatGuidesAsNoisy = true
  var robustInputScale = true
  var suppressDiffuseFireflies = true
}
struct SceneState: Codable {
  var surfaces = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  var objects = Array(repeating: ObjectSettings(), count: SceneLimits.materials)
  var maps = [Data?](repeating: nil, count: SceneLimits.materials * 4)
  var names = Array(repeating: "None", count: SceneLimits.materials * 4)
  var materialX: [Int: MaterialXProgram]?
  var emissions: [Int: SIMD3<Float>]?
}
struct ProjectDocument: Codable {
  var version = 2
  var scene: UInt32 = 0, strategy: UInt32 = 0, sky: UInt32 = 0, fog: UInt32 = 0, ring: UInt32 = 0
  var denoise = true
  var options = StudioOptions()
  var camera = CameraState()
  var views: [String: CameraState] = [:]
  var scenes: [Int: SceneState] = [:]
  var environmentData: Data?
  var environmentName = "Procedural sky"
  var triangles: [MeshTriangle] = []
  var meshName = "No mesh"
  var graph: SceneGraph?
  var importReport: [String]?
  // Optional so version 1/2 projects written before these controls remain readable.
  var oidn: OIDNOptions?
  var viewportMode: UInt32?

  func validate() throws {
    func bad() throws { throw MaterialLibrary.error("Invalid or unsupported project data.") }
    guard (1...2).contains(version), scene <= 6, strategy <= 3, sky <= 2, fog <= 1, ring <= 1,
      options.maxSamples <= 16_777_214, options.exportSamples > 0,
      options.exportSamples <= 16_777_214,
      (16...8192).contains(options.outputWidth), (16...8192).contains(options.outputHeight),
      (0.1...1).contains(options.previewScale), (1...64).contains(options.depth),
      options.timeLimit.isFinite, options.timeLimit >= 0,
      (-16...16).contains(options.exposure), (-1...1).contains(options.whiteBalance),
      (0...2).contains(options.toneMap), (0...1).contains(options.compare),
      (0...0.5).contains(options.aperture), (0.0001...1_000_000).contains(options.focusDistance),
      (0.05...4).contains(options.lightSize), (0...100).contains(options.environmentIntensity),
      (0...100).contains(options.lightIntensity), (0...10000).contains(options.sunIntensity),
      options.sunAzimuth.isFinite, options.sunElevation.isFinite,
      options.environmentRotation.isFinite,
      triangles.count <= 500_000
    else {
      try bad()
      return
    }
    if let oidn {
      guard oidn.quality <= 2, oidn.guides <= 2 else { try bad(); return }
    }
    if let viewportMode {
      guard viewportMode <= 4 else { try bad(); return }
    }
    func cameraOK(_ c: CameraState) -> Bool {
      c.yaw.isFinite && (-1.5...1.5).contains(c.pitch) && (0.0001...1_000_000).contains(c.distance)
        && (5...150).contains(c.fov) && (0..<3).allSatisfy { c.target[$0].isFinite }
    }
    guard cameraOK(camera), views.values.allSatisfy(cameraOK),
      (0..<3).allSatisfy({
        options.lightColor[$0].isFinite && options.lightColor[$0] >= 0
          && options.lightColor[$0] <= 1
      })
    else {
      try bad()
      return
    }
    var embeddedBytes = environmentData?.count ?? 0
    guard embeddedBytes <= 256 * 1024 * 1024 else { try bad(); return }
    for (index, state) in scenes {
      guard (0...6).contains(index), [8, SceneLimits.materials].contains(state.surfaces.count),
        state.objects.count == state.surfaces.count,
        state.maps.count == state.surfaces.count * 4, state.names.count == state.maps.count
      else {
        try bad()
        return
      }
      for (slot, e) in state.emissions ?? [:] {
        guard (8..<SceneLimits.materials).contains(slot),
          (0..<3).allSatisfy({ e[$0].isFinite && e[$0] >= 0 && e[$0] <= 1e8 })
        else {
          try bad()
          return
        }
      }
      for (slot, program) in state.materialX ?? [:] {
        guard (0..<state.surfaces.count).contains(slot) else {
          try bad()
          return
        }
        try program.validate()
        for image in program.images {
          guard image.data.count <= 128 * 1024 * 1024 else { try bad(); return }
          embeddedBytes += image.data.count
        }
      }
      for i in state.maps.indices {
        if let data = state.maps[i] {
          guard data.count <= 128 * 1024 * 1024 else { try bad(); return }
          embeddedBytes += data.count
        }
        guard state.surfaces[i / 4].mapMask & (1 << (i % 4)) == 0 || state.maps[i] != nil else {
          try bad()
          return
        }
      }
      for surface in state.surfaces {
        let v = [surface.color, surface.surface, surface.detail]
        guard v.allSatisfy({ x in (0..<4).allSatisfy { x[$0].isFinite } }),
          surface.normalStrength.isFinite,
          (0...4).contains(surface.normalStrength), surface.mapMask < 16,
          (0.01...100).contains(surface.detail.w), (1.01...2.5).contains(surface.detail.y),
          (0..<4).allSatisfy({ (0...1).contains(surface.surface[$0]) }),
          (0...1).contains(surface.detail.x), (0...1).contains(surface.detail.z),
          (0..<3).allSatisfy({ (0...1).contains(surface.color[$0]) })
        else {
          try bad()
          return
        }
      }
      for object in state.objects {
        guard (0.01...100).contains(object.positionScale.w),
          [object.positionScale, object.rotationHidden, object.uvTransform].allSatisfy({ x in
            (0..<4).allSatisfy { x[$0].isFinite }
          }), object.channels.x < 4, object.channels.y < 4
        else {
          try bad()
          return
        }
      }
    }
    guard embeddedBytes <= 512 * 1024 * 1024 else { try bad(); return }
    try graph?.validate()
    for t in triangles {
      guard
        [t.a, t.b, t.c, t.na, t.nb, t.nc, t.uvab, t.uvc].allSatisfy({ x in
          (0..<4).allSatisfy { x[$0].isFinite }
        })
      else {
        try bad()
        return
      }
    }
  }
}

// REFERENCES.md: OBJ2026, PBRT2023. Independent OBJ reader; no external importer.
enum OBJMesh {
  static func load(_ text: String) throws -> [MeshTriangle] { try parts(text).flatMap(\.triangles) }
  static func parts(_ text: String) throws -> [OBJPart] {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var result: [OBJPart] = []
    var object = "Object"
    var group = "Mesh"
    var material = "Default"
    var total = 0
    func number(_ s: Substring) throws -> Float {
      guard let n = Float(s), n.isFinite, abs(n) < 1e8 else {
        throw MaterialLibrary.error("OBJ contains an invalid number.")
      }
      return n
    }
    func index(_ s: Substring, count: Int) throws -> Int {
      guard let n = Int(s), n != 0, n != Int.min else {
        throw MaterialLibrary.error("Invalid OBJ index.")
      }
      let i = n > 0 ? n - 1 : count + n
      guard i >= 0 && i < count else { throw MaterialLibrary.error("OBJ index is out of bounds.") }
      return i
    }
    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .split(whereSeparator: \.isWhitespace)
      guard let kind = fields.first else { continue }
      if kind == "o" {
        object = fields.dropFirst().joined(separator: " ")
        group = "Mesh"
        continue
      }
      if kind == "g" {
        group = fields.dropFirst().joined(separator: " ")
        continue
      }
      if kind == "usemtl" {
        material = fields.dropFirst().joined(separator: " ")
        continue
      }
      if kind == "v" || kind == "vn" {
        guard fields.count >= 4 else { throw MaterialLibrary.error("Incomplete OBJ vertex.") }
        let v = try SIMD3<Float>(number(fields[1]), number(fields[2]), number(fields[3]))
        if kind == "v" {
          positions.append(v)
        } else {
          normals.append(simd_length_squared(v) > 1e-12 ? simd_normalize(v) : SIMD3<Float>(0, 1, 0))
        }
      } else if kind == "vt" {
        guard fields.count >= 3 else { throw MaterialLibrary.error("Incomplete OBJ UV.") }
        uvs.append(try SIMD2<Float>(number(fields[1]), 1 - number(fields[2])))
      } else if kind == "f" {
        guard fields.count >= 4, fields.count <= 4097 else {
          throw MaterialLibrary.error("OBJ face must contain 3–4096 vertices.")
        }
        var vertices: [(SIMD3<Float>, SIMD2<Float>, SIMD3<Float>?)] = []
        for f in fields.dropFirst() {
          let parts = f.split(separator: "/", omittingEmptySubsequences: false)
          guard parts.count <= 3 else { throw MaterialLibrary.error("Invalid OBJ face.") }
          let p = positions[try index(parts[0], count: positions.count)]
          let uv =
            parts.count > 1 && !parts[1].isEmpty
            ? uvs[try index(parts[1], count: uvs.count)] : .zero
          let n =
            parts.count > 2 && !parts[2].isEmpty
            ? normals[try index(parts[2], count: normals.count)] : nil
          vertices.append((p, uv, n))
        }
        // Convex polygons use fan triangulation; triangulate concave faces before import.
        for i in 1..<(vertices.count - 1) {
          let a = vertices[0]
          let b = vertices[i]
          let c = vertices[i + 1]
          let cross = simd_cross(b.0 - a.0, c.0 - a.0)
          if simd_length_squared(cross) < 1e-16 { continue }
          let n = simd_normalize(cross)
          if !result.contains(where: { $0.object == object && $0.group == group }) {
            result.append(OBJPart(object: object, group: group))
          }
          let part = result.firstIndex(where: { $0.object == object && $0.group == group })!
          if !result[part].subsets.contains(material) { result[part].subsets.append(material) }
          let subset = result[part].subsets.firstIndex(of: material)!
          result[part].triangles.append(
            MeshTriangle(
              a: SIMD4(a.0, 1), b: SIMD4(b.0, 1), c: SIMD4(c.0, 1), na: SIMD4(a.2 ?? n, 0),
              nb: SIMD4(b.2 ?? n, 0), nc: SIMD4(c.2 ?? n, 0),
              uvab: SIMD4(a.1.x, a.1.y, b.1.x, b.1.y), uvc: SIMD4(c.1.x, c.1.y, Float(subset), 0)))
          total += 1
          guard total <= 500_000 else {
            throw MaterialLibrary.error("OBJ exceeds the 500,000-triangle import limit.")
          }
        }
      }
    }
    guard !result.isEmpty else { throw MaterialLibrary.error("OBJ contains no usable faces.") }
    return result
  }
  static func build(_ input: [MeshTriangle]) -> ([MeshTriangle], [MeshNode]) {
    guard !input.isEmpty else { return ([], []) }
    // Partition integer references in place. Recursive triangle copies and a
    // full sort at every node used to dominate large imported-scene edits.
    let centers = input.map { ($0.a + $0.b + $0.c) / 3 }
    var order = Array(input.indices)
    var nodes: [MeshNode] = []
    nodes.reserveCapacity(input.count)
    func partition(_ start: Int, _ end: Int, _ middle: Int, _ axis: Int) {
      var low = start, high = end - 1, iterations = 0
      func less(_ a: Int, _ b: Int) -> Bool {
        centers[a][axis] == centers[b][axis] ? a < b : centers[a][axis] < centers[b][axis]
      }
      while low < high {
        // Bound worst-case selection time on adversarial geometry.
        if iterations >= 64 {
          order.replaceSubrange(low...high, with: order[low...high].sorted(by: less))
          return
        }
        iterations += 1
        let pivot = order[(low + high) / 2]
        var i = low, j = high
        while i <= j {
          while i <= high && less(order[i], pivot) { i += 1 }
          while j >= low && less(pivot, order[j]) { j -= 1 }
          if i <= j { order.swapAt(i, j); i += 1; j -= 1 }
        }
        if middle <= j { high = j }
        else if middle >= i { low = i }
        else { return }
      }
    }
    func buildNode(_ start: Int, _ end: Int) -> Int {
      var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
      for i in start..<end {
        let t = input[order[i]]
        for p in [t.a, t.b, t.c] {
          let v = SIMD3(p.x, p.y, p.z)
          lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
      }
      let index = nodes.count
      nodes.append(MeshNode(lo: SIMD4(lo, 0), hi: SIMD4(hi, 0), links: .zero))
      if end - start <= 4 {
        nodes[index].links = SIMD4(0, 0, Int32(start), Int32(end - start))
      } else {
        let e = hi - lo
        let axis = e.x > e.y ? (e.x > e.z ? 0 : 2) : (e.y > e.z ? 1 : 2)
        let middle = (start + end) / 2
        partition(start, end, middle, axis)
        let left = buildNode(start, middle), right = buildNode(middle, end)
        nodes[index].links = SIMD4(Int32(left), Int32(right), 0, 0)
      }
      return index
    }
    _ = buildNode(0, input.count)
    return (order.map { input[$0] }, nodes)
  }

}

extension MaterialLibrary {
  func state() -> SceneState {
    SceneState(
      surfaces: settings, objects: objects, maps: payloads, names: fileNames, materialX: materialX,
      emissions: emissions)
  }
  func restore(_ state: SceneState) throws {
    // Build all textures before publishing a restored scene.
    var replacement = images
    for i in state.maps.indices {
      if let bytes = state.maps[i] { replacement[i] = try texture(data: bytes, channel: i % 4) }
    }
    let oldSettings = settings, oldObjects = objects, oldPayloads = payloads, oldNames = fileNames
    let oldEmissions = emissions, oldMaterialX = materialX, oldImages = images
    let oldGraphTextures = graphTextures, oldGraphInstructions = graphInstructionBuffer
    let oldGraphHeaders = graphHeaderBuffer, oldArgument = argumentBuffer
    let oldObjectBuffer = objectBuffer, oldEmissionBuffer = emissionBuffer, oldEmitterBuffer = emitterBuffer
    do {
      settings = state.surfaces
        + Array(repeating: SurfaceSettings(), count: SceneLimits.materials - state.surfaces.count)
      objects = state.objects
        + Array(repeating: ObjectSettings(), count: SceneLimits.materials - state.objects.count)
      emissions = state.emissions ?? [:]
      try prepareMaterialX(state.materialX ?? [:])
      try rebuildArguments(replacement)
      payloads = state.maps + Array(repeating: nil, count: SceneLimits.materials * 4 - state.maps.count)
      fileNames = state.names + Array(repeating: "None", count: SceneLimits.materials * 4 - state.names.count)
    } catch {
      settings = oldSettings; objects = oldObjects; payloads = oldPayloads; fileNames = oldNames
      emissions = oldEmissions; materialX = oldMaterialX; images = oldImages
      graphTextures = oldGraphTextures; graphInstructionBuffer = oldGraphInstructions
      graphHeaderBuffer = oldGraphHeaders; argumentBuffer = oldArgument
      objectBuffer = oldObjectBuffer; emissionBuffer = oldEmissionBuffer; emitterBuffer = oldEmitterBuffer
      bindingsDirty = false
      throw error
    }
  }
  func texture(data: Data, channel: Int) throws -> MTLTexture {
    guard data.count <= 128 * 1024 * 1024 else {
      throw Self.error("Texture file exceeds the 128 MiB import limit.")
    }
    let result = try loader.newTexture(
      data: data,
      options: [
        .SRGB: channel == 0, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft,
        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
      ])
    try validateDecodedTexture(result, encodedBytes: data.count)
    return result
  }
  func setEnvironment(_ bytes: Data?) throws {
    guard let bytes else {
      let oldTexture = environmentTexture, oldData = environmentData, oldArgument = argumentBuffer
      environmentTexture = images[0]; environmentData = nil
      do { try rebuildArguments(images) }
      catch {
        environmentTexture = oldTexture; environmentData = oldData; argumentBuffer = oldArgument
        throw error
      }
      return
    }
    guard bytes.count <= 256 * 1024 * 1024,
      let image = CIImage(data: bytes), image.extent.width > 0, image.extent.height > 0,
      image.extent.width <= 16384, image.extent.height <= 8192,
      image.extent.width * image.extent.height <= 33_554_432
    else { throw Self.error("Could not decode the environment image (maximum 16384×8192).") }
    let w = Int(image.extent.width)
    let h = Int(image.extent.height)
    var pixels = Array(repeating: Float(0), count: w * h * 4)
    let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    CIContext().render(
      image, toBitmap: &pixels, rowBytes: w * 16, bounds: image.extent, format: .RGBAf,
      colorSpace: color)
    guard pixels.allSatisfy({ $0.isFinite }) else {
      throw Self.error("Environment pixels must be finite.")
    }
    // Color-space conversion may produce negative RGB; radiance is nonnegative.
    pixels = pixels.map { max(0, $0) }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
    desc.storageMode = .shared
    desc.usage = .shaderRead
    guard let imageTexture = device.makeTexture(descriptor: desc) else {
      throw Self.error("Could not allocate environment image.")
    }
    imageTexture.replace(
      region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: w * 16)
    let oldTexture = environmentTexture, oldData = environmentData, oldArgument = argumentBuffer
    environmentTexture = imageTexture; environmentData = bytes
    do { try rebuildArguments(images) }
    catch {
      environmentTexture = oldTexture; environmentData = oldData; argumentBuffer = oldArgument
      throw error
    }
  }
  func setMesh(_ triangles: [MeshTriangle]) throws {
    let (ordered, nodes) = OBJMesh.build(triangles)
    func buffer<T>(_ values: [T]) throws -> MTLBuffer {
      if values.isEmpty {
        guard let b = device.makeBuffer(length: 128, options: .storageModeShared) else {
          throw Self.error("Could not allocate imported mesh.")
        }
        return b
      }
      guard
        let b = values.withUnsafeBytes({
          device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
      else { throw Self.error("Could not allocate imported mesh.") }
      return b
    }
    let t = try buffer(ordered)
    let n = try buffer(nodes)
    let oldOrdered = orderedTriangles, oldTriangles = triangleBuffer, oldNodes = nodeBuffer
    let oldMesh = meshTriangles, oldNodeCount = nodeCount, oldArgument = argumentBuffer
    orderedTriangles = ordered; triangleBuffer = t; nodeBuffer = n
    meshTriangles = triangles; nodeCount = nodes.count
    do { try rebuildArguments(images) }
    catch {
      orderedTriangles = oldOrdered; triangleBuffer = oldTriangles; nodeBuffer = oldNodes
      meshTriangles = oldMesh; nodeCount = oldNodeCount; argumentBuffer = oldArgument
      throw error
    }
  }
}
