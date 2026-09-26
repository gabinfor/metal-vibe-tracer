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
  // Angular diameter, in degrees, of an imported UsdLux DistantLight. When set, the
  // Imported Mesh Studio sun is a directional emitter independent of the environment
  // and sunIntensity is its irradiance at normal incidence; nil keeps the sky's disc.
  var sunAngle: Float?
}
extension StudioOptions {
  static let sunAngleRange: ClosedRange<Float> = 0.1...90
  // 1 - cos(half angle) for Uniforms.lens.w, formed as 2 sin^2(angle/4); 0 = procedural sun.
  var independentSunCone: Float {
    guard let sunAngle else { return 0 }
    let s = sin(Double(sunAngle) * .pi / 720)
    return Float(2 * s * s)
  }
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

  // Aggregate embedded asset bytes (maps, MaterialX images, environment) across all scenes.
  static let embeddedAssetLimit = 512 * 1024 * 1024
  // Open accepts everything validate() accepts: JSON embeds assets as base64
  // (4/3 size), each of up to 500,000 flat and 500,000 graph triangles encodes in
  // at most ~600 bytes (507 measured with worst-case floats), and 64 MiB covers
  // settings, graphs and names. Saving refuses anything larger, so every saved
  // project reopens.
  static let maximumFileBytes =
    embeddedAssetLimit / 3 * 4 + 2 * SceneLimits.triangles * 600 + 64 * 1024 * 1024

  var embeddedAssetBytes: Int {
    scenes.values.reduce(environmentData?.count ?? 0) { total, state in
      total + state.maps.reduce(0) { $0 + ($1?.count ?? 0) }
        + (state.materialX ?? [:]).values.reduce(0) { sum, program in
          sum + program.images.reduce(0) { $0 + $1.data.count }
        }
    }
  }

  // Encodes a snapshot for save or autosave only if the open path accepts it.
  func encodeForSaving() throws -> Data {
    let embedded = embeddedAssetBytes
    guard embedded <= Self.embeddedAssetLimit else {
      throw MaterialLibrary.error(
        "Embedded images total \(embedded / 1_048_576) MiB across all scenes, above the \(Self.embeddedAssetLimit / 1_048_576) MiB project limit. Remove or downsize maps, MaterialX images or the environment before saving."
      )
    }
    do { try validate() } catch {
      throw MaterialLibrary.error(
        "This project could not be reopened, so it was not written: \(error.localizedDescription)")
    }
    let data = try JSONEncoder().encode(self)
    guard data.count <= Self.maximumFileBytes else {
      throw MaterialLibrary.error(
        "This project would be \(data.count / 1_048_576) MiB, above the \(Self.maximumFileBytes / 1_048_576) MiB file limit. Reduce embedded images or geometry before saving."
      )
    }
    return data
  }

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
      options.sunAngle.map({ StudioOptions.sunAngleRange.contains($0) }) ?? true,
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
    guard embeddedBytes <= Self.embeddedAssetLimit else { try bad(); return }
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
    var skipped = 0
    return try parts(text, skipped: &skipped)
  }
  // skipped counts faces left out because their edges are (numerically) collinear.
  static func parts(_ text: String, skipped: inout Int) throws -> [OBJPart] {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var result: [OBJPart] = []
    var object = "Object"
    var group = "Mesh"
    var material = "Default"
    var total = 0
    var lineNumber = 0, physicalLine = 0, pending = ""
    func failure(_ message: String) -> Error {
      MaterialLibrary.error("\(message.dropLast()) on line \(lineNumber).")
    }
    func number(_ s: Substring) throws -> Float {
      guard let n = Float(s), n.isFinite, abs(n) < 1e8 else {
        throw failure("OBJ contains an invalid number.")
      }
      return n
    }
    func index(_ s: Substring, count: Int) throws -> Int {
      guard let n = Int(s), n != 0, n != Int.min else {
        throw failure("Invalid OBJ index.")
      }
      let i = n > 0 ? n - 1 : count + n
      guard i >= 0 && i < count else { throw failure("OBJ index is out of bounds.") }
      return i
    }
    // The empty tail flushes a continuation on the file's last line.
    let physicalLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for raw in [physicalLines, [""]].joined() {
      physicalLine += 1
      if pending.isEmpty { lineNumber = physicalLine }
      // A trailing backslash outside a comment continues the statement.
      if let last = raw.lastIndex(where: { !$0.isWhitespace }), raw[last] == "\\",
        !raw[..<last].contains("#")
      {
        pending += raw[..<last] + " "
        continue
      }
      let line = pending.isEmpty ? raw : Substring(pending + raw)
      pending = ""
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
        guard fields.count >= 4 else { throw failure("Incomplete OBJ vertex.") }
        let v = try SIMD3<Float>(number(fields[1]), number(fields[2]), number(fields[3]))
        if kind == "v" {
          positions.append(v)
        } else {
          normals.append(simd_length_squared(v) > 1e-12 ? simd_normalize(v) : SIMD3<Float>(0, 1, 0))
        }
      } else if kind == "vt" {
        // "vt u" is valid OBJ; v defaults to 0.
        guard fields.count >= 2 else { throw failure("Incomplete OBJ UV.") }
        uvs.append(try SIMD2<Float>(number(fields[1]), 1 - (fields.count >= 3 ? number(fields[2]) : 0)))
      } else if kind == "f" {
        guard fields.count >= 4, fields.count <= 4097 else {
          throw failure("OBJ face must contain 3–4096 vertices.")
        }
        var vertices: [(SIMD3<Float>, SIMD2<Float>, SIMD3<Float>?)] = []
        for f in fields.dropFirst() {
          let parts = f.split(separator: "/", omittingEmptySubsequences: false)
          guard parts.count <= 3 else { throw failure("Invalid OBJ face.") }
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
          let e1 = b.0 - a.0, e2 = c.0 - a.0
          let cross = simd_cross(e1, e2)
          // Relative test, matching the GPU determinant test: sub-millimetre
          // faces in meter units stay; only collinear or coincident edges go.
          let area = simd_length(cross)
          guard area.isFinite, area > 1e-7 * simd_length(e1) * simd_length(e2) else {
            skipped += 1
            continue
          }
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
            throw failure("OBJ exceeds the 500,000-triangle import limit.")
          }
        }
      }
    }
    guard !result.isEmpty else {
      throw MaterialLibrary.error(
        skipped > 0 ? "OBJ contains no usable faces (\(skipped) degenerate faces skipped)." : "OBJ contains no usable faces.")
    }
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
        // links.z keeps the split axis for near-first GPU traversal.
        nodes[index].links = SIMD4(Int32(left), Int32(right), Int32(axis), 0)
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
    guard state.surfaces.count <= SceneLimits.materials,
      state.objects.count <= SceneLimits.materials,
      state.maps.count <= SceneLimits.materials * 4,
      state.names.count <= SceneLimits.materials * 4
    else { throw Self.error("Scene state exceeds the material capacity.") }
    // Build all textures (maps and MaterialX images) before publishing a restored
    // scene, and budget them together as one candidate set.
    var replacement = (0..<(SceneLimits.materials * 4)).map { defaultTexture(channel: $0 % 4) }
    for i in state.maps.indices {
      guard let bytes = state.maps[i] else { continue }
      if payloads.indices.contains(i), payloads[i] == bytes {
        replacement[i] = images[i]
      } else if external.payloads.indices.contains(i), external.payloads[i] == bytes {
        replacement[i] = external.images[i]
      } else {
        replacement[i] = try texture(data: bytes, channel: i % 4, pending: replacement)
      }
      try validateCandidateTextures(images: replacement)
    }
    let programs = state.materialX ?? [:]
    let graph = try materialXCandidate(programs, images: replacement)
    try validateCandidateTextures(images: replacement, graph: graph.textures)
    let oldSettings = settings, oldObjects = objects, oldPayloads = payloads, oldNames = fileNames
    let oldEmissions = emissions, oldMaterialX = materialX, oldImages = images
    let oldGraphTextures = graphTextures, oldGraphInstructions = graphInstructionBuffer
    let oldGraphHeaders = graphHeaderBuffer, oldArgument = argumentBuffer
    let oldObjectBuffer = objectBuffer, oldEmissionBuffer = emissionBuffer, oldEmitterBuffer = emitterBuffer
    let oldBindingsDirty = bindingsDirty
    do {
      settings = state.surfaces
        + Array(repeating: SurfaceSettings(), count: SceneLimits.materials - state.surfaces.count)
      objects = state.objects
        + Array(repeating: ObjectSettings(), count: SceneLimits.materials - state.objects.count)
      emissions = state.emissions ?? [:]
      graphInstructionBuffer = graph.instructions
      graphHeaderBuffer = graph.headers
      graphTextures = graph.textures
      materialX = programs
      try rebuildArguments(replacement)
      payloads = state.maps + Array(repeating: nil, count: SceneLimits.materials * 4 - state.maps.count)
      fileNames = state.names + Array(repeating: "None", count: SceneLimits.materials * 4 - state.names.count)
    } catch {
      settings = oldSettings; objects = oldObjects; payloads = oldPayloads; fileNames = oldNames
      emissions = oldEmissions; materialX = oldMaterialX; images = oldImages
      graphTextures = oldGraphTextures; graphInstructionBuffer = oldGraphInstructions
      graphHeaderBuffer = oldGraphHeaders; argumentBuffer = oldArgument
      objectBuffer = oldObjectBuffer; emissionBuffer = oldEmissionBuffer; emitterBuffer = oldEmitterBuffer
      // Pending object or emission edits were never uploaded; keep them pending.
      bindingsDirty = oldBindingsDirty
      throw error
    }
  }
  func texture(data: Data, channel: Int, pending: [MTLTexture] = []) throws -> MTLTexture {
    try validateEncodedImage(data, pending: pending)
    let result = try decodeTexture(data, srgb: channel == 0)
    try validateDecodedTexture(result, encodedBytes: data.count, pending: pending)
    return result
  }
  // Material images always sample as RGBA. MTKTextureLoader keeps gray and gray+alpha
  // files as R/RG, so those become swizzled views (RRR1, RRRG). sRGB cases the formats
  // cannot express (16-bit data; RG8 sRGB, which would also decode alpha) are expanded
  // to RGBA on the CPU.
  func decodeTexture(_ data: Data, srgb: Bool) throws -> MTLTexture {
    let texture = try loader.newTexture(
      data: data,
      options: [
        .SRGB: srgb, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft,
        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
      ])
    let format = texture.pixelFormat
    if srgb, [.r8Unorm, .r16Unorm, .rg16Unorm, .rgba16Unorm, .rg8Unorm, .rg8Unorm_srgb].contains(format) {
      return try expandedSRGB(data)
    }
    let swizzle: MTLTextureSwizzleChannels
    switch format {
    case .r8Unorm, .r8Unorm_srgb, .r16Unorm, .r16Float, .r32Float:
      swizzle = MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .one)
    case .rg8Unorm, .rg8Unorm_srgb, .rg16Unorm, .rg16Float, .rg32Float:
      swizzle = MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .green)
    default: return texture
    }
    guard
      let view = texture.makeTextureView(
        pixelFormat: format, textureType: texture.textureType, levels: 0..<texture.mipmapLevelCount,
        slices: 0..<max(1, texture.arrayLength), swizzle: swizzle)
    else { throw Self.error("Could not create a grayscale texture view.") }
    return view
  }
  // 16-bit data becomes linear RGBA16Float (sRGB EOTF, IEC 61966-2-1, on color only);
  // 8-bit gray (+alpha) becomes RGBA8 sRGB, whose hardware decode leaves alpha linear.
  private func expandedSRGB(_ data: Data) throws -> MTLTexture {
    let source = try loader.newTexture(
      data: data,
      options: [
        .SRGB: false, .generateMipmaps: false, .origin: MTKTextureLoader.Origin.topLeft,
        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
      ])
    let layouts: [MTLPixelFormat: Int] = [
      .r16Unorm: 1, .rg16Unorm: 2, .rgba16Unorm: 4, .r8Unorm: 1, .rg8Unorm: 2,
    ]
    guard let channels = layouts[source.pixelFormat] else {
      throw Self.error("Unexpected texture format for sRGB expansion.")
    }
    let wide = source.pixelFormat != .r8Unorm && source.pixelFormat != .rg8Unorm
    let width = source.width, height = source.height, pixelBytes = wide ? 8 : 4
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: wide ? .rgba16Float : .rgba8Unorm_srgb, width: width, height: height, mipmapped: true)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor),
      let staging = device.makeBuffer(length: width * height * pixelBytes, options: .storageModeShared)
    else { throw Self.error("Could not allocate the expanded sRGB texture.") }
    let eotf = wide ? (0...65535).map { i -> Float16 in
      let x = Float(i) / 65535
      return Float16(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
    } : []
    let sampleBytes = wide ? 2 : 1
    let rows = max(1, min(height, 4_194_304 / (width * channels)))
    var band = [UInt8](repeating: 0, count: rows * width * channels * sampleBytes)
    for y0 in stride(from: 0, to: height, by: rows) {
      let count = min(rows, height - y0)
      band.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        source.getBytes(
          base, bytesPerRow: width * channels * sampleBytes,
          from: MTLRegionMake2D(0, y0, width, count), mipmapLevel: 0)
        if wide {
          let samples = raw.bindMemory(to: UInt16.self)
          let pixels = staging.contents().bindMemory(to: Float16.self, capacity: width * height * 4)
          for i in 0..<(count * width) {
            let s = i * channels, d = ((y0 * width) + i) * 4
            let gray = eotf[Int(samples[s])]
            pixels[d] = gray
            pixels[d + 1] = channels == 4 ? eotf[Int(samples[s + 1])] : gray
            pixels[d + 2] = channels == 4 ? eotf[Int(samples[s + 2])] : gray
            pixels[d + 3] = channels == 1 ? 1 : Float16(Float(samples[s + channels - 1]) / 65535)
          }
        } else {
          let pixels = staging.contents().bindMemory(to: UInt8.self, capacity: width * height * 4)
          for i in 0..<(count * width) {
            let d = ((y0 * width) + i) * 4
            let gray = raw[i * channels]
            pixels[d] = gray
            pixels[d + 1] = gray
            pixels[d + 2] = gray
            pixels[d + 3] = channels == 2 ? raw[i * 2 + 1] : 255
          }
        }
      }
    }
    guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
      let blit = command.makeBlitCommandEncoder()
    else { throw Self.error("Could not upload the expanded sRGB texture.") }
    blit.copy(
      from: staging, sourceOffset: 0, sourceBytesPerRow: width * pixelBytes,
      sourceBytesPerImage: width * height * pixelBytes,
      sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0,
      destinationLevel: 0, destinationOrigin: MTLOrigin())
    blit.generateMipmaps(for: texture)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else {
      throw Self.error("Could not upload the expanded sRGB texture.")
    }
    return texture
  }

  func environmentImportance(_ pixels: UnsafeBufferPointer<Float>, width: Int, height: Int) throws -> (MTLTexture, MTLTexture) {
    guard pixels.count == width * height * 4, width > 0, height > 0 else {
      throw Self.error("Invalid environment sampling dimensions.")
    }
    var rowWeights = Array(repeating: Float(0), count: height)
    var columnWeights = Array(repeating: Float(0), count: width * height)
    for y in 0..<height {
      let theta = (.pi * (Float(y) + 0.5)) / Float(height)
      let sinTheta = max(1e-4, sin(theta))
      for x in 0..<width {
        let offset = (y * width + x) * 4
        let luminance = max(0, 0.2126 * pixels[offset] + 0.7152 * pixels[offset + 1] + 0.0722 * pixels[offset + 2])
        let weight = max(1e-6, luminance) * sinTheta
        rowWeights[y] += weight
        columnWeights[y * width + x] = weight
      }
    }
    // Convert weights to CDFs in place; no second full-size CPU copy.
    func cdf(_ weights: inout [Float], count: Int, rows: Int) {
      for row in 0..<rows {
        let start = row * count
        let total = max(1e-12, weights[start..<start + count].reduce(0, +))
        var sum: Float = 0
        for index in 0..<count {
          sum += weights[start + index] / total
          weights[start + index] = index == count - 1 ? 1 : sum
        }
      }
    }
    cdf(&rowWeights, count: height, rows: 1)
    cdf(&columnWeights, count: width, rows: height)
    let rows = rowWeights, columns = columnWeights
    let rowDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r32Float, width: 1, height: height, mipmapped: false)
    rowDescriptor.storageMode = .shared
    rowDescriptor.usage = .shaderRead
    let columnDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
    columnDescriptor.storageMode = .shared
    columnDescriptor.usage = .shaderRead
    guard let rowTexture = device.makeTexture(descriptor: rowDescriptor),
      let columnTexture = device.makeTexture(descriptor: columnDescriptor) else {
      throw Self.error("Could not allocate environment sampling data.")
    }
    rowTexture.replace(region: MTLRegionMake2D(0, 0, 1, height), mipmapLevel: 0,
      withBytes: rows, bytesPerRow: MemoryLayout<Float>.stride)
    columnTexture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
      withBytes: columns, bytesPerRow: width * MemoryLayout<Float>.stride)
    return (rowTexture, columnTexture)
  }

  // A decoded environment image followed by its row and column sampling CDFs.
  struct EnvironmentCandidate {
    let data: Data
    let textures: [MTLTexture]
  }

  // Decodes without publishing, so callers may run it off the main thread.
  // `residentBytes` is the live texture total, captured where the published
  // library is owned; the image and both CDFs are budgeted before allocation.
  func makeEnvironment(_ bytes: Data, residentBytes: UInt64) throws -> EnvironmentCandidate {
    guard bytes.count <= 256 * 1024 * 1024,
      let image = CIImage(data: bytes), image.extent.width > 0, image.extent.height > 0,
      image.extent.width <= 16384, image.extent.height <= 8192,
      image.extent.width * image.extent.height <= 33_554_432
    else { throw Self.error("Could not decode the environment image (maximum 16384×8192).") }
    let w = Int(image.extent.width)
    let h = Int(image.extent.height)
    // RGBA32F image and R32F column CDF per pixel, plus an R32F row CDF.
    let required = UInt64(w) * UInt64(h) * 20 + UInt64(h) * 4
    guard residentBytes + required <= textureBudget
    else { throw Self.error("Environment image exceeds the safe GPU memory budget.") }
    var pixels = Array(repeating: Float(0), count: w * h * 4)
    let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    CIContext().render(
      image, toBitmap: &pixels, rowBytes: w * 16, bounds: image.extent, format: .RGBAf,
      colorSpace: color)
    // Color-space conversion may produce negative RGB; radiance is nonnegative.
    // Clamp in place rather than making a second full-size copy.
    for i in pixels.indices {
      guard pixels[i].isFinite else { throw Self.error("Environment pixels must be finite.") }
      if pixels[i] < 0 { pixels[i] = 0 }
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
    desc.storageMode = .shared
    desc.usage = .shaderRead
    guard let imageTexture = device.makeTexture(descriptor: desc) else {
      throw Self.error("Could not allocate environment image.")
    }
    imageTexture.replace(
      region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: w * 16)
    let (rowSampling, columnSampling) = try pixels.withUnsafeBufferPointer {
      try environmentImportance($0, width: w, height: h)
    }
    return EnvironmentCandidate(data: bytes, textures: [imageTexture, rowSampling, columnSampling])
  }

  func publishEnvironment(_ candidate: EnvironmentCandidate) throws {
    guard candidate.textures.count == 3 else { throw Self.error("Invalid environment sampling data.") }
    try validateCandidateTextures(images: images, environment: candidate.textures)
    let oldTexture = environmentTexture, oldRows = environmentRows, oldColumns = environmentColumns,
      oldData = environmentData, oldArgument = argumentBuffer
    environmentTexture = candidate.textures[0]; environmentRows = candidate.textures[1]
    environmentColumns = candidate.textures[2]
    environmentData = candidate.data
    do { try rebuildArguments(images) }
    catch {
      environmentTexture = oldTexture; environmentRows = oldRows; environmentColumns = oldColumns
      environmentData = oldData; argumentBuffer = oldArgument
      throw error
    }
  }

  func setEnvironment(_ bytes: Data?) throws {
    guard let bytes else {
      let oldTexture = environmentTexture, oldRows = environmentRows, oldColumns = environmentColumns,
        oldData = environmentData, oldArgument = argumentBuffer
      // A dedicated placeholder, never a material map that could later be cleared.
      environmentTexture = defaultTexture(channel: 0); environmentRows = defaultEnvironmentSampling
      environmentColumns = defaultEnvironmentSampling; environmentData = nil
      do { try rebuildArguments(images) }
      catch {
        environmentTexture = oldTexture; environmentRows = oldRows; environmentColumns = oldColumns
        environmentData = oldData; argumentBuffer = oldArgument
        throw error
      }
      return
    }
    if environmentData == bytes { return }
    if external.environment.count == 3, external.environmentData == bytes {
      try publishEnvironment(EnvironmentCandidate(data: bytes, textures: external.environment))
      return
    }
    try publishEnvironment(
      makeEnvironment(bytes, residentBytes: uniqueTextureBytes(residentTextures + external.textures)))
  }
  func setMesh(_ triangles: [MeshTriangle]) throws {
    meshBuildCount += 1
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
    let oldTriangles = triangleBuffer, oldNodes = nodeBuffer
    let oldMesh = meshTriangles, oldNodeCount = nodeCount, oldArgument = argumentBuffer
    triangleBuffer = t; nodeBuffer = n
    meshTriangles = triangles; nodeCount = nodes.count
    do { try rebuildArguments(images) }
    catch {
      triangleBuffer = oldTriangles; nodeBuffer = oldNodes
      meshTriangles = oldMesh; nodeCount = oldNodeCount; argumentBuffer = oldArgument
      throw error
    }
  }

  func setMeshBindings(_ graph: SceneGraph) throws {
    try graph.validate()
    let slots = Dictionary(uniqueKeysWithValues: graph.materials.map { ($0.id, $0.slot) })
    func rebound(_ triangle: MeshTriangle) throws -> MeshTriangle {
      var result = triangle
      let nodeIndex = Int(result.uvc.w) - 1
      let subset = Int(result.na.w)
      guard graph.nodes.indices.contains(nodeIndex),
        graph.nodes[nodeIndex].bindings.indices.contains(subset),
        let slot = slots[graph.nodes[nodeIndex].bindings[subset]]
      else { throw Self.error("Scene binding no longer matches flattened geometry.") }
      result.uvc.z = Float(slot)
      return result
    }
    // Rebind straight from the shared buffer into its replacement; the BVH order is unchanged.
    let ordered = orderedTriangles
    guard let candidateBuffer = device.makeBuffer(
      length: max(128, ordered.count * MemoryLayout<MeshTriangle>.stride), options: .storageModeShared)
    else { throw Self.error("Could not allocate imported mesh bindings.") }
    let target = candidateBuffer.contents().bindMemory(to: MeshTriangle.self, capacity: max(1, ordered.count))
    for (i, triangle) in ordered.enumerated() { target[i] = try rebound(triangle) }
    let candidateMesh = try meshTriangles.map(rebound)
    let oldMesh = meshTriangles
    let oldTriangleBuffer = triangleBuffer, oldArgument = argumentBuffer
    meshTriangles = candidateMesh
    triangleBuffer = candidateBuffer
    do { try rebuildArguments(images) }
    catch {
      meshTriangles = oldMesh
      triangleBuffer = oldTriangleBuffer
      argumentBuffer = oldArgument
      throw error
    }
  }
}
