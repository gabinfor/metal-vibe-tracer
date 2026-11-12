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
  @MainActor init(_ r: PathTracerRenderer) {
    yaw = r.yaw
    pitch = r.pitch
    distance = r.distance
    fov = r.fov
    target = r.target
  }
  @MainActor func apply(_ r: PathTracerRenderer) {
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
  // Path vertices, 1 (direct light only) to 64.
  @WholeNumber var depth = 16
  var exposure: Float = 0
  var whiteBalance: Float = 0
  // Display curve: 0 filmic fit, 1 Reinhard, 2 linear / clip.
  @WholeNumber var toneMap = 0
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
  // Spectral transport's emitter spectra (Illuminant raw values): the area and sphere lights and
  // imported emitters, and the sun. nil (projects written before the Lighting panel offered them)
  // is the RGB colour, which spectral transport renders as D65-shaped light; RGB transport ignores both.
  var lightSpectrum: UInt32?
  var sunSpectrum: UInt32?
  // The luminance cap of a sample's indirect light (MSL indirect_clamped; biased, removes fireflies); nil or 0
  // is off, as in projects written before the clamp.
  var indirectClamp: Float?
  static let indirectClampRange: ClosedRange<Float> = 0...100_000
}
// An integer option that projects written before it was an integer stored as a float. Such a float
// decodes truncated toward zero, as the path tracer reads path depth; the option is written as a JSON integer.
@propertyWrapper struct WholeNumber: Codable, Equatable {
  var wrappedValue: Int
  init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Int.self) {
      wrappedValue = value
      return
    }
    let value = try container.decode(Double.self)
    guard value.isFinite, abs(value) < 1e9 else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(value) is not a whole number.")
    }
    wrappedValue = Int(value.rounded(.towardZero))
  }
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wrappedValue)
  }
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
extension StudioOptions {
  // Sample and time limits, output/export settings, exposure, white balance, tone map
  // and the divider are display- or output-only; every other option changes radiance.
  func sameRadiance(as o: StudioOptions) -> Bool {
    previewScale == o.previewScale && depth == o.depth && sunAzimuth == o.sunAzimuth
      && sunElevation == o.sunElevation && sunIntensity == o.sunIntensity
      && environmentIntensity == o.environmentIntensity
      && environmentRotation == o.environmentRotation && lightColor == o.lightColor
      && lightIntensity == o.lightIntensity && lightSize == o.lightSize && aperture == o.aperture
      && focusDistance == o.focusDistance && sunAngle == o.sunAngle
      && Illuminant.resolved(lightSpectrum) == Illuminant.resolved(o.lightSpectrum)
      && Illuminant.resolved(sunSpectrum) == Illuminant.resolved(o.sunSpectrum)
      && (indirectClamp ?? 0) == (o.indirectClamp ?? 0)
  }
}
// The ReSTIR strategy's reuse modes, the sampler, the light transport, the light sampling and the caustic mode
// (Render inspector; the last four apply to every strategy). Each one changes the image, so a
// difference restarts accumulation like a radiance-affecting option (StudioController.applyProject).
struct ReSTIRModes: Equatable, Sendable {
  var indirectReuse: IndirectReuse
  var spatialNeighbors: SpatialNeighborSelection
  var temporalReuse: TemporalReuse
  var controlVariates: ControlVariates
  var sampler: SamplerMode
  var lightTransport: LightTransport
  var lightSampling: LightSampling
  var caustics: CausticMode
  // Projects without a stored choice use these: .automatic, or in -D VIBE_TESTING builds the
  // VIBE_INDIRECT_REUSE / VIBE_SPATIAL_NEIGHBORS / VIBE_TEMPORAL_REUSE / VIBE_CONTROL_VARIATES /
  // VIBE_SAMPLER / VIBE_LIGHT_TRANSPORT / VIBE_LIGHT_SAMPLING / VIBE_CAUSTICS override. A stored choice wins.
  static var defaults: ReSTIRModes {
    ReSTIRModes(
      indirectReuse: PathTracerRenderer.defaultIndirectReuse,
      spatialNeighbors: PathTracerRenderer.defaultSpatialNeighbors,
      temporalReuse: PathTracerRenderer.defaultTemporalReuse,
      controlVariates: PathTracerRenderer.defaultControlVariates,
      sampler: PathTracerRenderer.defaultSampler,
      lightTransport: PathTracerRenderer.defaultLightTransport,
      lightSampling: PathTracerRenderer.defaultLightSampling,
      caustics: PathTracerRenderer.defaultCaustics)
  }
  init(indirectReuse: IndirectReuse, spatialNeighbors: SpatialNeighborSelection, temporalReuse: TemporalReuse,
       controlVariates: ControlVariates = PathTracerRenderer.defaultControlVariates,
       sampler: SamplerMode = PathTracerRenderer.defaultSampler,
       lightTransport: LightTransport = PathTracerRenderer.defaultLightTransport,
       lightSampling: LightSampling = PathTracerRenderer.defaultLightSampling,
       caustics: CausticMode = PathTracerRenderer.defaultCaustics) {
    self.indirectReuse = indirectReuse
    self.spatialNeighbors = spatialNeighbors
    self.temporalReuse = temporalReuse
    self.controlVariates = controlVariates
    self.sampler = sampler
    self.lightTransport = lightTransport
    self.lightSampling = lightSampling
    self.caustics = caustics
  }
  @MainActor init(_ r: PathTracerRenderer) {
    self.init(indirectReuse: r.indirectReuse, spatialNeighbors: r.spatialNeighbors, temporalReuse: r.temporalReuse,
              controlVariates: r.controlVariates, sampler: r.sampler, lightTransport: r.lightTransport,
              lightSampling: r.lightSampling, caustics: r.caustics)
  }
  @MainActor func apply(_ r: PathTracerRenderer) {
    r.indirectReuse = indirectReuse
    r.spatialNeighbors = spatialNeighbors
    r.temporalReuse = temporalReuse
    r.controlVariates = controlVariates
    r.sampler = sampler
    r.lightTransport = lightTransport
    r.lightSampling = lightSampling
    r.caustics = caustics
  }
}
struct OIDNOptions: Codable, Equatable {
  // UI indices map to OIDN FAST (4), BALANCED (5), and HIGH (6).
  var quality: UInt32 = 2
  // 0 = color only, 1 = albedo, 2 = albedo + normal.
  var guides: UInt32 = 2
  var treatGuidesAsNoisy = true
  // Off: OIDN computes its own HDR input scale (inputScale = NaN).
  var robustInputScale = false
  var suppressDiffuseFireflies = true
}
struct SceneState: Codable {
  var surfaces = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  var objects = Array(repeating: ObjectSettings(), count: SceneLimits.materials)
  var maps = [Data?](repeating: nil, count: SceneLimits.materials * 4)
  var names = Array(repeating: "None", count: SceneLimits.materials * 4)
  var materialX: [Int: MaterialXProgram]?
  var emissions: [Int: SIMD3<Float>]?
  // Imported lights' spectra and spot cones (EmitterLight); optional so earlier projects open unchanged.
  var emitterLights: [Int: EmitterLight]?
}
struct AutosaveRecovery: Codable {
  var projectPath: String?
  var edited: Bool
}
struct ProjectDocument: Codable {
  var version = 2
  var scene: UInt32 = 0, strategy: UInt32 = 0, sky: UInt32 = 0, fog: UInt32 = 0, ring: UInt32 = 0
  // MetalFX in the preview: off by default (the raw accumulation), on in projects that saved it on.
  var denoise = false
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
  // Raw values of IndirectReuse, SpatialNeighborSelection, TemporalReuse, ControlVariates,
  // SamplerMode, LightTransport and LightSampling; optional so projects written before the Render
  // inspector exposed them open with the default (automatic).
  var indirectReuse: UInt32?
  var spatialNeighbors: UInt32?
  var temporalReuse: UInt32?
  var controlVariates: UInt32?
  var sampler: UInt32?
  var lightTransport: UInt32?
  var lightSampling: UInt32?
  // CausticMode raw value; nil (projects before caustic light tracing) is the default.
  var caustics: UInt32?
  // The scene medium (SceneMedium); nil is clear air, as in projects written before media.
  var medium: SceneMedium?
  // Written only into autosaves: the document's file association and unsaved state.
  var recovery: AutosaveRecovery?

  // The stored ReSTIR modes; a missing (or, before validate(), unknown) value is the default.
  var restirModes: ReSTIRModes {
    get {
      let fallback = ReSTIRModes.defaults
      return ReSTIRModes(
        indirectReuse: indirectReuse.flatMap(IndirectReuse.init(rawValue:)) ?? fallback.indirectReuse,
        spatialNeighbors: spatialNeighbors.flatMap(SpatialNeighborSelection.init(rawValue:)) ?? fallback.spatialNeighbors,
        temporalReuse: temporalReuse.flatMap(TemporalReuse.init(rawValue:)) ?? fallback.temporalReuse,
        controlVariates: controlVariates.flatMap(ControlVariates.init(rawValue:)) ?? fallback.controlVariates,
        sampler: sampler.flatMap(SamplerMode.init(rawValue:)) ?? fallback.sampler,
        lightTransport: lightTransport.flatMap(LightTransport.init(rawValue:)) ?? fallback.lightTransport,
        lightSampling: lightSampling.flatMap(LightSampling.init(rawValue:)) ?? fallback.lightSampling,
        caustics: caustics.flatMap(CausticMode.init(rawValue:)) ?? fallback.caustics)
    }
    set {
      indirectReuse = newValue.indirectReuse.rawValue
      spatialNeighbors = newValue.spatialNeighbors.rawValue
      temporalReuse = newValue.temporalReuse.rawValue
      controlVariates = newValue.controlVariates.rawValue
      sampler = newValue.sampler.rawValue
      lightTransport = newValue.lightTransport.rawValue
      lightSampling = newValue.lightSampling.rawValue
      caustics = newValue.caustics.rawValue
    }
  }

  // Aggregate embedded asset bytes (maps, MaterialX images, environment) across all scenes.
  static let embeddedAssetLimit = 1024 * 1024 * 1024
  // Open accepts everything validate() accepts: JSON embeds assets as base64 (4/3 size).
  // Formats 1-3 held at most SceneLimits.flatTriangles flat and graph triangles each, at most
  // ~600 bytes per JSON triangle (507 measured with worst-case floats; format 3's 128-byte
  // records are 171 as base64). Format 4 stores graph meshes as MeshGeometry payloads, at most
  // 112 bytes per face (three unshared 32-byte vertices and the face; 150 as base64), and its
  // legacy flat mesh as format 3 does. 64 MiB covers settings, graphs and names. Saving
  // refuses anything larger, so every saved project reopens.
  static let perFormat4Face = 160
  static let maximumFileBytes =
    embeddedAssetLimit / 3 * 4 + 2 * SceneLimits.flatTriangles * 600 + SceneLimits.triangles * perFormat4Face
    + 64 * 1024 * 1024

  // Identical payloads (a map or image shared by several slots, programs or scenes) are
  // stored once in the asset table and count once.
  var embeddedAssetBytes: Int {
    ProjectAssets.distinct(imagePayloads).reduce(0) { $0 + $1.count }
  }

  // Encodes a self-contained snapshot for Save only if the open path accepts it.
  func encodeForSaving() throws -> Data { try encodedForWriting(inline: true).json }
  // Autosave JSON plus the payloads it references, stored as sidecars (writeAutosave).
  func encodeForAutosave() throws -> (json: Data, payloads: [String: Data]) {
    try encodedForWriting(inline: false)
  }
  private func encodedForWriting(inline: Bool) throws -> (json: Data, payloads: [String: Data]) {
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
    let encoded = try encodedProject(inline: inline)
    let data = encoded.json
    guard data.count <= Self.maximumFileBytes else {
      throw MaterialLibrary.error(
        "This project would be \(data.count / 1_048_576) MiB, above the \(Self.maximumFileBytes / 1_048_576) MiB file limit. Reduce embedded images or geometry before saving."
      )
    }
    return encoded
  }

  func validate() throws {
    func bad() throws { throw MaterialLibrary.error("Invalid or unsupported project data.") }
    guard (1...ProjectAssets.formatVersion).contains(version), scene <= 6, strategy <= 3, sky <= 2, fog <= 1, ring <= 1,
      medium?.isValid ?? true, StudioOptions.indirectClampRange.contains(options.indirectClamp ?? 0),
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
      triangles.count <= SceneLimits.triangles
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
    guard indirectReuse.map({ IndirectReuse(rawValue: $0) != nil }) ?? true,
      spatialNeighbors.map({ SpatialNeighborSelection(rawValue: $0) != nil }) ?? true,
      temporalReuse.map({ TemporalReuse(rawValue: $0) != nil }) ?? true,
      controlVariates.map({ ControlVariates(rawValue: $0) != nil }) ?? true,
      sampler.map({ SamplerMode(rawValue: $0) != nil }) ?? true,
      lightTransport.map({ LightTransport(rawValue: $0) != nil }) ?? true,
      lightSampling.map({ LightSampling(rawValue: $0) != nil }) ?? true,
      caustics.map({ CausticMode(rawValue: $0) != nil }) ?? true,
      options.lightSpectrum.map({ Illuminant(rawValue: $0) != nil }) ?? true,
      options.sunSpectrum.map({ Illuminant(rawValue: $0) != nil }) ?? true
    else { try bad(); return }
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
    guard (environmentData?.count ?? 0) <= 256 * 1024 * 1024 else { try bad(); return }
    for (index, state) in scenes {
      guard (0...6).contains(index),
        state.surfaces.count == 8 || (SceneLimits.storedMaterials...SceneLimits.materials).contains(state.surfaces.count),
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
      for (slot, light) in state.emitterLights ?? [:] {
        guard (8..<SceneLimits.materials).contains(slot), light.isValid else {
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
        }
      }
      for i in state.maps.indices {
        if let data = state.maps[i] {
          guard data.count <= 128 * 1024 * 1024 else { try bad(); return }
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
    guard embeddedAssetBytes <= Self.embeddedAssetLimit else { try bad(); return }
    try graph?.validate()
    // Legacy meshes use the scene-graph bounds; uvc.z is converted to an integer slot.
    for t in triangles {
      guard
        [t.a, t.b, t.c, t.na, t.nb, t.nc, t.uvab, t.uvc].allSatisfy({ x in
          (0..<4).allSatisfy { x[$0].isFinite && abs(x[$0]) < 1e8 }
        }),
        t.uvc.z >= 0, t.uvc.z < Float(SceneLimits.materials), t.uvc.z.rounded() == t.uvc.z
      else {
        try bad()
        return
      }
    }
  }
}

// REFERENCES.md: OBJ2026, PBRT2023. Independent OBJ reader; no external importer.
private extension CChar { var isWhitespaceByte: Bool { self == 0x20 || (self >= 0x09 && self <= 0x0D) } }
enum OBJMesh {
  static func load(_ text: String) throws -> [MeshTriangle] { try parts(text).flatMap(\.triangles) }
  static func parts(_ text: String) throws -> [OBJPart] {
    var skipped = 0
    return try parts(text, skipped: &skipped)
  }
  static func parts(_ text: String, skipped: inout Int, nodeBudget: Int = Int.max) throws -> [OBJPart] {
    var libraries: [String] = []
    return try parts(Data(text.utf8), skipped: &skipped, nodeBudget: nodeBudget, libraries: &libraries)
  }
  // Streams the file's bytes (a memory-mapped file is never copied into a String), so files of
  // several GB parse within the triangle limit. skipped counts faces left out because their edges
  // are (numerically) collinear. `nodeBudget` bounds the scene nodes the parts create (one per
  // object, one per object/group part) so oversized hierarchies fail before the whole file is
  // parsed. `libraries` receives each `mtllib` statement's argument text.
  static func parts(_ data: Data, skipped: inout Int, nodeBudget: Int = Int.max, libraries: inout [String],
                    progress: OperationProgress? = nil) throws -> [OBJPart]
  {
    try data.withUnsafeBytes { raw in
      try parts(raw.bindMemory(to: UInt8.self), skipped: &skipped, nodeBudget: nodeBudget, libraries: &libraries,
                progress: progress)
    }
  }
  private static func parts(_ bytes: UnsafeBufferPointer<UInt8>, skipped: inout Int, nodeBudget: Int,
                            libraries: inout [String], progress: OperationProgress?) throws -> [OBJPart] {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var result: [OBJPart] = []
    var object = "Object"
    var group = "Mesh"
    var material = "Default"
    var total = 0
    var lineNumber = 0
    func failure(_ message: String) -> Error {
      MaterialLibrary.error("\(message.dropLast()) on line \(lineNumber).")
    }
    // Part and subset lookups stay constant-time for group-heavy files.
    var partIndices: [String: [String: Int]] = [:]
    var subsetIndices: [[String: Int]] = []
    var objects = Set<String>()
    var current: (part: Int, subset: Int)?
    var builders: [MeshGeometry.Builder] = []
    var scratch = [CChar](repeating: 0, count: 64)
    var fields: [Range<Int>] = []
    var corners: [(SIMD3<Float>, SIMD2<Float>, SIMD3<Float>?)] = []
    func number(_ line: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) throws -> Float {
      var value: Float?
      if r.count < scratch.count {
        value = scratch.withUnsafeMutableBufferPointer { s -> Float? in
          for (k, i) in r.enumerated() { s[k] = CChar(bitPattern: line[i]) }
          s[r.count] = 0
          var end: UnsafeMutablePointer<CChar>?
          let n = strtof(s.baseAddress!, &end)
          return end == s.baseAddress! + r.count && !s[0].isWhitespaceByte ? n : nil
        }
      }
      guard let n = value, n.isFinite, abs(n) < 1e8 else { throw failure("OBJ contains an invalid number.") }
      return n
    }
    func index(_ line: UnsafeBufferPointer<UInt8>, _ r: Range<Int>, count: Int) throws -> Int {
      var i = r.lowerBound, negative = false, n = 0
      if i < r.upperBound, line[i] == 0x2B || line[i] == 0x2D { negative = line[i] == 0x2D; i += 1 }
      guard i < r.upperBound, r.upperBound - i <= 18 else { throw failure("Invalid OBJ index.") }
      while i < r.upperBound {
        let d = Int(line[i]) - 0x30
        guard d >= 0 && d <= 9 else { throw failure("Invalid OBJ index.") }
        n = n * 10 + d
        i += 1
      }
      guard n != 0 else { throw failure("Invalid OBJ index.") }
      let k = negative ? count - n : n - 1
      guard k >= 0 && k < count else { throw failure("OBJ index is out of bounds.") }
      return k
    }
    func rest(_ line: UnsafeBufferPointer<UInt8>) -> String {
      fields.dropFirst().map { String(decoding: UnsafeBufferPointer(rebasing: line[$0]), as: UTF8.self) }
        .joined(separator: " ")
    }
    func keyword(_ line: UnsafeBufferPointer<UInt8>, _ word: StaticString) -> Bool {
      let r = fields[0]
      guard r.count == word.utf8CodeUnitCount else { return false }
      for k in 0..<r.count where line[r.lowerBound + k] != word.utf8Start[k] { return false }
      return true
    }
    func statement(_ line: UnsafeBufferPointer<UInt8>) throws {
      // Fields are whitespace-separated, up to a comment.
      fields.removeAll(keepingCapacity: true)
      var i = 0
      while i < line.count, line[i] != 0x23 {
        if line[i] == 0x20 || line[i] == 0x09 { i += 1; continue }
        let start = i
        while i < line.count, line[i] != 0x20, line[i] != 0x09, line[i] != 0x23 { i += 1 }
        fields.append(start..<i)
      }
      guard !fields.isEmpty else { return }
      if keyword(line, "o") {
        object = rest(line)
        group = "Mesh"
        current = nil
      } else if keyword(line, "g") {
        group = rest(line)
        current = nil
      } else if keyword(line, "usemtl") {
        material = rest(line)
        current = nil
      } else if keyword(line, "mtllib") {
        if fields.count > 1 { libraries.append(rest(line)) }
      } else if keyword(line, "v") || keyword(line, "vn") {
        guard fields.count >= 4 else { throw failure("Incomplete OBJ vertex.") }
        let v = try SIMD3<Float>(number(line, fields[1]), number(line, fields[2]), number(line, fields[3]))
        if fields[0].count == 1 {
          positions.append(v)
        } else {
          normals.append(simd_length_squared(v) > 1e-12 ? simd_normalize(v) : SIMD3<Float>(0, 1, 0))
        }
      } else if keyword(line, "vt") {
        // "vt u" is valid OBJ; v defaults to 0.
        guard fields.count >= 2 else { throw failure("Incomplete OBJ UV.") }
        uvs.append(try SIMD2<Float>(number(line, fields[1]), 1 - (fields.count >= 3 ? number(line, fields[2]) : 0)))
      } else if keyword(line, "f") {
        guard fields.count >= 4, fields.count <= 4097 else {
          throw failure("OBJ face must contain 3–4096 vertices.")
        }
        corners.removeAll(keepingCapacity: true)
        for f in fields.dropFirst() {
          // v, v/vt, v//vn or v/vt/vn.
          var slashes: [Int] = []
          for k in f where line[k] == 0x2F { slashes.append(k) }
          guard slashes.count <= 2 else { throw failure("Invalid OBJ face.") }
          let ends = slashes + [f.upperBound]
          let p = positions[try index(line, f.lowerBound..<ends[0], count: positions.count)]
          let uvRange = slashes.count >= 1 ? slashes[0] + 1..<ends[1] : 0..<0
          let uv = uvRange.isEmpty ? SIMD2<Float>.zero : uvs[try index(line, uvRange, count: uvs.count)]
          let nRange = slashes.count == 2 ? slashes[1] + 1..<ends[2] : 0..<0
          let n = nRange.isEmpty ? nil : normals[try index(line, nRange, count: normals.count)]
          corners.append((p, uv, n))
        }
        // Convex polygons use fan triangulation; triangulate concave faces before import.
        for i in 1..<(corners.count - 1) {
          let a = corners[0]
          let b = corners[i]
          let c = corners[i + 1]
          let e1 = b.0 - a.0, e2 = c.0 - a.0
          let cross = simd_cross(e1, e2)
          // Relative test: sub-millimetre faces in meter units stay; only collinear
          // or coincident edges go (the GPU's watertight test rejects only det = 0).
          let area = simd_length(cross)
          guard area.isFinite, area > 1e-7 * simd_length(e1) * simd_length(e2) else {
            skipped += 1
            continue
          }
          let n = simd_normalize(cross)
          let part: Int, subset: Int
          if let current {
            (part, subset) = current
          } else {
            if let existing = partIndices[object]?[group] {
              part = existing
            } else {
              let newObject = !objects.contains(object)
              guard objects.count + result.count + (newObject ? 2 : 1) <= nodeBudget else {
                throw failure(
                  "OBJ has too many objects and groups: the scene holds at most \(SceneLimits.nodes) nodes (\(max(0, nodeBudget)) available). Merge groups before importing."
                )
              }
              objects.insert(object)
              part = result.count
              result.append(OBJPart(object: object, group: group))
              builders.append(MeshGeometry.Builder())
              subsetIndices.append([:])
              partIndices[object, default: [:]][group] = part
            }
            if let existing = subsetIndices[part][material] {
              subset = existing
            } else {
              subset = result[part].subsets.count
              result[part].subsets.append(material)
              subsetIndices[part][material] = subset
            }
            current = (part, subset)
          }
          // Corners with the same position, UV and normal (OBJ's shared v/vt/vn) weld.
          builders[part].add(
            MeshTriangle(
              a: SIMD4(a.0, 1), b: SIMD4(b.0, 1), c: SIMD4(c.0, 1), na: SIMD4(a.2 ?? n, 0),
              nb: SIMD4(b.2 ?? n, 0), nc: SIMD4(c.2 ?? n, 0),
              uvab: SIMD4(a.1.x, a.1.y, b.1.x, b.1.y), uvc: SIMD4(c.1.x, c.1.y, Float(subset), 0)))
          total += 1
          guard total <= SceneLimits.triangles else {
            throw failure("OBJ exceeds the \(SceneLimits.triangles.formatted())-triangle import limit.")
          }
        }
      }
    }
    // Physical lines end at LF, CR, CR LF, VT or FF (Swift's newline characters in ASCII). A
    // trailing backslash outside a comment continues the statement on the next line.
    var pending: [UInt8] = []
    var physical = 0, start = 0, reported = 0
    while start <= bytes.count {
      // The parse reports its byte position every 4 MB.
      if let progress, start - reported >= 1 << 22 {
        reported = start
        progress.update("Parsing OBJ geometry", fraction: Double(start) / Double(bytes.count))
      }
      var end = start
      while end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D, bytes[end] != 0x0B, bytes[end] != 0x0C { end += 1 }
      physical += 1
      if pending.isEmpty { lineNumber = physical }
      let raw = UnsafeBufferPointer(rebasing: bytes[start..<end])
      var last = raw.count - 1
      while last >= 0, raw[last] == 0x20 || raw[last] == 0x09 { last -= 1 }
      if last >= 0, raw[last] == 0x5C, !raw[..<last].contains(0x23) {
        pending += raw[..<last]
        pending.append(0x20)
      } else if pending.isEmpty {
        try statement(raw)
      } else {
        pending += raw
        try pending.withUnsafeBufferPointer { try statement($0) }
        pending.removeAll(keepingCapacity: true)
      }
      if end == bytes.count { break }
      start = end + (bytes[end] == 0x0D && end + 1 < bytes.count && bytes[end + 1] == 0x0A ? 2 : 1)
    }
    // A continuation on the file's last line still ends its statement.
    if !pending.isEmpty { try pending.withUnsafeBufferPointer { try statement($0) } }
    guard !result.isEmpty else {
      throw MaterialLibrary.error(
        skipped > 0 ? "OBJ contains no usable faces (\(skipped) degenerate faces skipped)." : "OBJ contains no usable faces.")
    }
    for i in result.indices { result[i].geometry = builders[i].geometry }
    return result
  }
  static func build(_ input: [MeshTriangle]) -> ([MeshTriangle], [MeshNode]) {
    let (order, nodes) = input.withUnsafeBufferPointer { hierarchy($0) }
    return (order.map { input[$0] }, nodes)
  }
  // Builds the hierarchy and reorders `triangles` into BVH order in place (following the
  // permutation's cycles), so the GPU buffer needs no second, reordered host copy.
  static func buildInPlace(_ triangles: UnsafeMutableBufferPointer<MeshTriangle>) -> [MeshNode] {
    let (order, nodes) = hierarchy(UnsafeBufferPointer(triangles))
    var placed = [Bool](repeating: false, count: order.count)
    for start in order.indices where !placed[start] {
      let first = triangles[start]
      var slot = start
      while true {
        placed[slot] = true
        let source = order[slot]
        if source == start { triangles[slot] = first; break }
        triangles[slot] = triangles[source]
        slot = source
      }
    }
    return nodes
  }
  // Returns the BVH triangle order (ordered[i] = input[order[i]]) and the nodes.
  static func hierarchy(_ input: UnsafeBufferPointer<MeshTriangle>) -> ([Int], [MeshNode]) {
    guard !input.isEmpty else { return ([], []) }
    // Partition integer references in place, without copying triangles or fully sorting at
    // every node, which would dominate large imported-scene edits.
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
    return (order, nodes)
  }

}

// Immutable GPU resources captured from the live library on the main thread. A
// candidate library prepared off the main thread adopts them, so unchanged maps,
// MaterialX images, the environment and the flattened mesh are reused rather than
// decoded, converted or rebuilt again.
// @unchecked Sendable: Metal objects may be referenced from any thread, and these are
// never written by the CPU once published (edits allocate replacement textures and
// buffers), so the preparing thread and the main thread only ever read them.
struct ReusableResources: @unchecked Sendable {
  var payloads: [Data?]
  var images: [MTLTexture]
  var materialX: [Int: MaterialXProgram]
  var graphTextures: [MTLTexture]
  var environmentData: Data?
  var environment: (texture: MTLTexture, rows: MTLTexture, columns: MTLTexture)?
  var meshTriangles: [MeshTriangle]
  // BVH-ordered triangles live only in triangleBuffer (flat) or meshStreams (two-level);
  // MaterialLibrary.orderedTriangles reads either.
  var triangleBuffer: MTLBuffer
  var meshStreams: MeshStreams?
  var triangleCount: Int
  var nodeBuffer: MTLBuffer
  var nodeCount: Int
  var meshLayout: MeshSceneLayout?
  var acceleration: MeshAcceleration
  var hasSceneGraph: Bool
  var graph: SceneGraph?
  // The published texture set, which stays live while the candidate is prepared;
  // it becomes the candidate's `external` budget and sharing source.
  var resident: MaterialLibrary.ResidentTextures
}
func sameBytes<T>(_ a: [T], _ b: [T]) -> Bool {
  guard a.count == b.count else { return false }
  return a.withUnsafeBytes { x in
    b.withUnsafeBytes { y in
      guard let p = x.baseAddress, let q = y.baseAddress else { return true }
      return p == q || memcmp(p, q, x.count) == 0
    }
  }
}
extension SceneState {
  // The slots up to the last one in use, and at least SceneLimits.storedMaterials: what a
  // project file stores (decoding pads it back with `padded`).
  var trimmed: SceneState {
    let defaultSurface = SurfaceSettings(), defaultObject = ObjectSettings()
    var used = -1
    for i in surfaces.indices where !sameBytes([surfaces[i]], [defaultSurface]) { used = max(used, i) }
    for i in objects.indices where !sameBytes([objects[i]], [defaultObject]) { used = max(used, i) }
    for i in maps.indices where maps[i] != nil || (names.indices.contains(i) && names[i] != "None") { used = max(used, i / 4) }
    for slot in (emissions ?? [:]).keys { used = max(used, slot) }
    for slot in (materialX ?? [:]).keys { used = max(used, slot) }
    let count = min(surfaces.count, max(SceneLimits.storedMaterials, used + 1))
    guard count < surfaces.count, objects.count == surfaces.count, maps.count == 4 * surfaces.count,
      names.count == maps.count
    else { return self }
    var s = self
    s.surfaces.removeLast(surfaces.count - count)
    s.objects.removeLast(objects.count - count)
    s.maps.removeLast(maps.count - 4 * count)
    s.names.removeLast(names.count - 4 * count)
    return s
  }
  // Legacy eight-slot and trimmed states compare and restore as full-capacity states.
  var padded: SceneState {
    var s = self
    s.surfaces += Array(repeating: SurfaceSettings(), count: max(0, SceneLimits.materials - s.surfaces.count))
    s.objects += Array(repeating: ObjectSettings(), count: max(0, SceneLimits.materials - s.objects.count))
    s.maps += Array(repeating: nil, count: max(0, SceneLimits.materials * 4 - s.maps.count))
    s.names += Array(repeating: "None", count: max(0, SceneLimits.materials * 4 - s.names.count))
    return s
  }
  // True when publishing `other` needs no image decoding: every map and MaterialX
  // image of `other` is already resident in this state at the same index.
  func hasImages(of other: SceneState) -> Bool {
    let a = padded, b = other.padded
    for i in b.maps.indices where b.maps[i] != nil && b.maps[i] != a.maps[i] { return false }
    for (slot, program) in b.materialX ?? [:] where !program.images.isEmpty {
      guard let old = a.materialX?[slot], old.images.count >= program.images.count else { return false }
      for (i, image) in program.images.enumerated()
      where old.images[i].srgb != image.srgb || old.images[i].data != image.data {
        return false
      }
    }
    return true
  }
  func sameResources(as other: SceneState) -> Bool {
    let a = padded, b = other.padded
    guard sameBytes(a.surfaces, b.surfaces), sameBytes(a.objects, b.objects), a.names == b.names,
      a.maps == b.maps, (a.emissions ?? [:]) == (b.emissions ?? [:]), (a.emitterLights ?? [:]) == (b.emitterLights ?? [:])
    else { return false }
    let x = a.materialX ?? [:], y = b.materialX ?? [:]
    guard Set(x.keys) == Set(y.keys) else { return false }
    return x.allSatisfy { slot, program in y[slot].map { program.sameProgram(as: $0) } ?? false }
  }
}
extension MaterialXProgram {
  func sameProgram(as other: MaterialXProgram) -> Bool {
    guard name == other.name, source == other.source, roots == other.roots,
      diffuseRoughness == other.diffuseRoughness, emission == other.emission, opacity == other.opacity,
      specularColor == other.specularColor, transmissionColor == other.transmissionColor,
      thinWalled == other.thinWalled, subsurfaceWeight == other.subsurfaceWeight,
      subsurfaceColor == other.subsurfaceColor, subsurfaceAnisotropy == other.subsurfaceAnisotropy, medium == other.medium, mediumAnisotropy == other.mediumAnisotropy,
      mediumBoundary == other.mediumBoundary, mediumRayleigh == other.mediumRayleigh,
      anisotropyRotation == other.anisotropyRotation,
      sameBytes(instructions, other.instructions),
      images.count == other.images.count, parameters.count == other.parameters.count,
      zip(images, other.images).allSatisfy({ $0.name == $1.name && $0.srgb == $1.srgb && $0.data == $1.data })
    else { return false }
    return zip(parameters, other.parameters).allSatisfy {
      $0.name == $1.name && $0.instruction == $1.instruction && $0.components == $1.components
        && $0.defaultValue == $1.defaultValue
    }
  }
}

extension MaterialLibrary {
  func reusableResources(graph: SceneGraph?) -> ReusableResources {
    ReusableResources(
      payloads: payloads, images: images, materialX: materialX, graphTextures: graphTextures,
      environmentData: environmentData,
      environment: environmentData == nil
        ? nil : (environmentTexture, environmentRows, environmentColumns),
      meshTriangles: meshTriangles,
      triangleBuffer: triangleBuffer, meshStreams: meshStreams, triangleCount: triangleCount, nodeBuffer: nodeBuffer,
      nodeCount: nodeCount, meshLayout: meshLayout, acceleration: acceleration, hasSceneGraph: hasSceneGraph, graph: graph, resident: residentSnapshot())
  }
  // Seed a freshly created candidate. It is published only after restore,
  // setEnvironment and the mesh step have rebuilt its bindings.
  func adopt(_ r: ReusableResources) {
    payloads = r.payloads
    images = r.images
    materialX = r.materialX
    graphTextures = r.graphTextures
    if let environment = r.environment {
      environmentData = r.environmentData
      environmentTexture = environment.texture
      environmentRows = environment.rows
      environmentColumns = environment.columns
    }
    meshTriangles = r.meshTriangles
    triangleBuffer = r.triangleBuffer
    meshStreams = r.meshStreams
    triangleCount = r.triangleCount
    nodeBuffer = r.nodeBuffer
    nodeCount = r.nodeCount
    meshLayout = r.meshLayout
    acceleration = r.acceleration
    hasSceneGraph = r.hasSceneGraph
  }
  func state() -> SceneState {
    SceneState(
      surfaces: settings, objects: objects, maps: payloads, names: fileNames, materialX: materialX,
      emissions: emissions, emitterLights: emitterLights.isEmpty ? nil : emitterLights)
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
    let maps = state.maps.compactMap { $0 }.count
    var decoded = 0
    for i in state.maps.indices {
      guard let bytes = state.maps[i] else { continue }
      if payloads.indices.contains(i), payloads[i] == bytes {
        replacement[i] = images[i]
      } else if external.payloads.indices.contains(i), external.payloads[i] == bytes {
        replacement[i] = external.images[i]
      } else {
        progress?.update("Decoding material textures", completed: decoded, of: maps)
        decoded += 1
        replacement[i] = try texture(data: bytes, channel: i % 4, pending: replacement)
      }
      try validateCandidateTextures(images: replacement)
    }
    let programs = state.materialX ?? [:]
    if !programs.isEmpty { progress?.begin("Preparing \(programs.count) MaterialX materials") }
    let graph = try materialXCandidate(programs, images: replacement)
    try validateCandidateTextures(images: replacement, graph: graph.textures)
    let oldSettings = settings, oldObjects = objects, oldPayloads = payloads, oldNames = fileNames
    let oldEmissions = emissions, oldEmitterLights = emitterLights, oldMaterialX = materialX, oldImages = images
    let oldGraphTextures = graphTextures, oldGraphInstructions = graphInstructionBuffer
    let oldGraphHeaders = graphHeaderBuffer, oldArgument = argumentBuffer
    let oldObjectBuffer = objectBuffer, oldEmissionBuffer = emissionBuffer, oldEmitterBuffer = emitterBuffer
    let oldBindingsDirty = bindingsDirty, oldSide = graphTextureSide
    do {
      graphTextureSide = graph.side
      settings = state.surfaces
        + Array(repeating: SurfaceSettings(), count: SceneLimits.materials - state.surfaces.count)
      objects = state.objects
        + Array(repeating: ObjectSettings(), count: SceneLimits.materials - state.objects.count)
      emissions = state.emissions ?? [:]
      emitterLights = state.emitterLights ?? [:]
      graphInstructionBuffer = graph.instructions
      graphHeaderBuffer = graph.headers
      graphTextures = graph.textures
      materialX = programs
      try rebuildArguments(replacement)
      try refreshInstanceOpacity()
      payloads = state.maps + Array(repeating: nil, count: SceneLimits.materials * 4 - state.maps.count)
      fileNames = state.names + Array(repeating: "None", count: SceneLimits.materials * 4 - state.names.count)
    } catch {
      settings = oldSettings; objects = oldObjects; payloads = oldPayloads; fileNames = oldNames
      emissions = oldEmissions; emitterLights = oldEmitterLights; materialX = oldMaterialX; images = oldImages
      graphTextures = oldGraphTextures; graphInstructionBuffer = oldGraphInstructions
      graphHeaderBuffer = oldGraphHeaders; argumentBuffer = oldArgument
      objectBuffer = oldObjectBuffer; emissionBuffer = oldEmissionBuffer; emitterBuffer = oldEmitterBuffer
      // Pending object or emission edits were never uploaded; keep them pending.
      bindingsDirty = oldBindingsDirty
      graphTextureSide = oldSide
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
  // to RGBA on the CPU. Mip levels are box-filtered in linear space (encodeMipmaps).
  func decodeTexture(_ data: Data, srgb: Bool, maximumSide: Int? = nil) throws -> MTLTexture {
    // Budget downscaling (materialXCandidate): an ImageIO thumbnail at most `maximumSide` texels
    // long, passed on as uncompressed TIFF so every format path below still applies.
    if let side = maximumSide, let header = Self.imageHeader(data), max(header.width, header.height) > side {
      let output = NSMutableData()
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: false,
        ] as CFDictionary),
        let destination = CGImageDestinationCreateWithData(output, "public.tiff" as CFString, 1, nil)
      else { throw Self.error("Could not downscale a texture.") }
      CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]
      ] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw Self.error("Could not downscale a texture.") }
      return try decodeTexture(output as Data, srgb: srgb)
    }
    let options: [MTKTextureLoader.Option: Any] = [
      .SRGB: srgb, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft,
      .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
      .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
    ]
    let texture: MTLTexture
    do {
      texture = try loader.newTexture(data: data, options: options)
    } catch {
      // MTKTextureLoader rejects some PNG layouts (8-bit palette images, as in Bistro's MTL
      // textures); Core Graphics decodes them to RGBA8 with their stored values.
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: 4 * image.width, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw error }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard let rgba = context.makeImage() else { throw error }
      let texture = try loader.newTexture(cgImage: rgba, options: options)
      try refilterMipmaps(texture)
      return texture
    }
    let format = texture.pixelFormat
    if srgb, [.r8Unorm, .r16Unorm, .rg16Unorm, .rgba16Unorm, .rg8Unorm, .rg8Unorm_srgb].contains(format) {
      return try expandedSRGB(data)
    }
    try refilterMipmaps(texture)
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
    blit.endEncoding()
    try encodeMipmaps(texture, into: command)
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else {
      throw Self.error("Could not upload the expanded sRGB texture.")
    }
    return texture
  }

  // Mip levels come from MSL area_mipmap: each texel is the area-weighted mean, in linear space, of the
  // footprint it covers in the level above (a box filter over the exact footprint: 2×2 texels, up to 3×3
  // below an odd side). sRGB textures are read decoded and written re-encoded through a linear view.
  // Metal's own mip generation (the blit's generateMipmaps, and MTKTextureLoader's .generateMipmaps, measured
  // the same) takes one bilinear tap per texel below an odd side instead, which skips some source texels and
  // under-weights others; the error compounds level by level (Bitterli's 894² Modern Hall floor: up to +11% at
  // 6×6 and +86% at 1×1). At power-of-two sides its levels drift upward by about 0.1% a level on bright sRGB
  // images. Formats the kernel cannot write keep the blit's levels (REFERENCES.md METALTEXTURES).
  private static let areaMipmapSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void area_mipmap(texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]], constant uint &srgb [[buffer(0)]],
        uint2 id [[thread_position_in_grid]]) {
      uint2 size = uint2(destination.get_width(), destination.get_height());
      uint2 sourceSize = uint2(source.get_width(), source.get_height());
      if (any(id >= size)) return;
      float2 lo = float2(id * sourceSize) / float2(size);
      float2 hi = min(float2((id + 1) * sourceSize) / float2(size), float2(sourceSize));
      float4 sum = 0;
      float total = 0;
      for (uint y = uint(lo.y); float(y) < hi.y; ++y) {
        float wy = min(hi.y, float(y + 1)) - max(lo.y, float(y));
        for (uint x = uint(lo.x); float(x) < hi.x; ++x) {
          float w = wy * (min(hi.x, float(x + 1)) - max(lo.x, float(x)));
          sum += w * source.read(uint2(x, y));
          total += w;
        }
      }
      float4 c = sum / total;
      if (srgb != 0) {
        float3 v = saturate(c.rgb);
        c.rgb = select(1.055f * powr(v, 1.0f / 2.4f) - 0.055f, 12.92f * v, v <= 0.0031308f);
      }
      destination.write(c, id);
    }
    """
  // The pixel format area_mipmap writes for each format it filters (sRGB formats through their linear twin).
  private static let areaMipmapWriteFormats: [MTLPixelFormat: MTLPixelFormat] = [
    .rgba8Unorm_srgb: .rgba8Unorm, .bgra8Unorm_srgb: .bgra8Unorm, .r8Unorm_srgb: .r8Unorm, .rg8Unorm_srgb: .rg8Unorm,
    .rgba8Unorm: .rgba8Unorm, .bgra8Unorm: .bgra8Unorm, .r8Unorm: .r8Unorm, .rg8Unorm: .rg8Unorm,
    .r16Unorm: .r16Unorm, .rg16Unorm: .rg16Unorm, .rgba16Unorm: .rgba16Unorm,
    .r16Float: .r16Float, .rg16Float: .rg16Float, .rgba16Float: .rgba16Float,
    .r32Float: .r32Float, .rg32Float: .rg32Float, .rgba32Float: .rgba32Float,
  ]
  // Replaces the levels MTKTextureLoader generated.
  private func refilterMipmaps(_ texture: MTLTexture) throws {
    guard texture.mipmapLevelCount > 1 else { return }
    guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer() else {
      throw Self.error("Could not filter the texture's mip levels.")
    }
    try encodeMipmaps(texture, into: command)
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { throw Self.error("Could not filter the texture's mip levels.") }
  }
  // Encodes levels 1... of a 2D texture from its level 0 with area_mipmap (the blit for formats it cannot
  // write). Levels are written to a scratch chain and copied in, so the texture needs no shader-write usage.
  private func encodeMipmaps(_ texture: MTLTexture, into command: MTLCommandBuffer) throws {
    let levels = texture.mipmapLevelCount
    guard levels > 1 else { return }
    guard texture.textureType == .type2D, let writeFormat = Self.areaMipmapWriteFormats[texture.pixelFormat]
    else {
      guard let blit = command.makeBlitCommandEncoder() else { throw Self.error("Could not generate mip levels.") }
      blit.generateMipmaps(for: texture)
      blit.endEncoding()
      return
    }
    if areaMipmapPipeline == nil {
      let library = try device.makeLibrary(source: Self.areaMipmapSource, options: nil)
      guard let function = library.makeFunction(name: "area_mipmap") else {
        throw Self.error("Could not compile the mip filter.")
      }
      areaMipmapPipeline = try device.makeComputePipelineState(function: function)
    }
    // Scratch level k holds the texture's level k + 1.
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: texture.pixelFormat, width: max(1, texture.width / 2), height: max(1, texture.height / 2),
      mipmapped: true)
    descriptor.usage = writeFormat == texture.pixelFormat ? [.shaderRead, .shaderWrite]
      : [.shaderRead, .shaderWrite, .pixelFormatView]
    descriptor.storageMode = .private
    guard let pipeline = areaMipmapPipeline, let scratch = device.makeTexture(descriptor: descriptor),
      scratch.mipmapLevelCount == levels - 1, let encoder = command.makeComputeCommandEncoder()
    else { throw Self.error("Could not generate mip levels.") }
    var srgb = UInt32(writeFormat == texture.pixelFormat ? 0 : 1)
    encoder.setComputePipelineState(pipeline)
    encoder.setBytes(&srgb, length: 4, index: 0)
    for level in 0..<(levels - 1) {
      guard
        let source = level == 0 ? texture.makeTextureView(
          pixelFormat: texture.pixelFormat, textureType: .type2D, levels: 0..<1, slices: 0..<1)
          : scratch.makeTextureView(
            pixelFormat: texture.pixelFormat, textureType: .type2D, levels: (level - 1)..<level, slices: 0..<1),
        let destination = scratch.makeTextureView(
          pixelFormat: writeFormat, textureType: .type2D, levels: level..<(level + 1), slices: 0..<1)
      else { throw Self.error("Could not generate mip levels.") }
      encoder.setTexture(source, index: 0)
      encoder.setTexture(destination, index: 1)
      encoder.dispatchThreads(
        MTLSize(width: destination.width, height: destination.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }
    encoder.endEncoding()
    guard let blit = command.makeBlitCommandEncoder() else { throw Self.error("Could not generate mip levels.") }
    blit.copy(
      from: scratch, sourceSlice: 0, sourceLevel: 0, to: texture, destinationSlice: 0, destinationLevel: 1,
      sliceCount: 1, levelCount: levels - 1)
    blit.endEncoding()
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
  // A graph-less (legacy) mesh. The document's array is retained as meshTriangles by
  // reference (copy-on-write storage is shared, not duplicated) for snapshots.
  func setMesh(_ triangles: [MeshTriangle]) throws {
    if acceleration != .flat {
      guard triangles.count <= SceneLimits.triangles else {
        throw Self.error("The mesh exceeds the \(SceneLimits.triangles.formatted()) triangle limit.")
      }
      var layout = MeshSceneLayout()
      progress?.begin("Building the mesh hierarchy")
      try publishTwoLevel(
        assets: [(MeshSceneLayout.legacyAsset, MeshGeometry(triangles: triangles))], document: triangles,
        legacyExtras: triangles.map(MeshStreams.extra), layout: &layout
      ) { layout in
        if !triangles.isEmpty { try layout.addInstance(node: -1, asset: 0, world: matrix_identity_float4x4, slots: []) }
      }
      return
    }
    progress?.begin("Building the mesh hierarchy")
    let t = try triangleStorage(triangles.count)
    if !triangles.isEmpty {
      triangles.withUnsafeBytes { t.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }
    try publishMesh(t, count: triangles.count, document: triangles)
  }
  // A scene-graph mesh, flattened straight into the shared GPU buffer and reordered there:
  // the graph's assets stay the only other host copy, and no flattened array is retained.
  func setMesh(_ graph: SceneGraph) throws {
    if acceleration != .flat {
      try graph.validate()
      var layout = MeshSceneLayout()
      try publishTwoLevel(assets: graph.assets.map { ($0.id, $0.geometry) }, document: [], layout: &layout) { layout in
        try layout.addInstances(graph)
      }
      return
    }
    progress?.begin("Building the mesh hierarchy")
    let count = try graph.renderTriangleCount()
    guard count <= SceneLimits.flatTriangles else {
      throw Self.error("The flat BVH renders at most \(SceneLimits.flatTriangles.formatted()) triangles.")
    }
    let t = try triangleStorage(count)
    let target = t.contents().bindMemory(to: MeshTriangle.self, capacity: max(1, count))
    var written = 0
    try graph.forEachRenderTriangle { triangle in
      guard written < count else { throw Self.error("Flattened scene size changed while building the mesh.") }
      target[written] = triangle
      written += 1
    }
    guard written == count else { throw Self.error("Flattened scene size changed while building the mesh.") }
    try publishMesh(t, count: count, document: [])
  }
  func setMesh(_ p: ProjectDocument) throws {
    if let graph = p.graph { try setMesh(graph) } else { try setMesh(p.triangles) }
  }
  // The published mesh buffers, for an exact rollback that neither flattens nor rebuilds.
  struct MeshResources {
    let triangles: [MeshTriangle], triangleBuffer: MTLBuffer, triangleCount: Int
    let nodeBuffer: MTLBuffer, nodeCount: Int
    var layout: MeshSceneLayout? = nil
    // Two-level: the faces, vertices and BLAS nodes (triangleBuffer is then a placeholder).
    var streams: MeshStreams? = nil
  }
  var meshResources: MeshResources {
    MeshResources(triangles: meshTriangles, triangleBuffer: triangleBuffer, triangleCount: triangleCount,
      nodeBuffer: nodeBuffer, nodeCount: nodeCount, layout: meshLayout, streams: meshStreams)
  }
  func restoreMesh(_ m: MeshResources) throws {
    let old = meshResources, oldArgument = argumentBuffer
    apply(m)
    do { try rebuildArguments(images) }
    catch { apply(old); argumentBuffer = oldArgument; throw error }
  }
  private func apply(_ m: MeshResources) {
    triangleBuffer = m.triangleBuffer; triangleCount = m.triangleCount
    meshStreams = m.streams
    nodeBuffer = m.nodeBuffer; nodeCount = m.nodeCount
    meshTriangles = m.triangles
    meshLayout = m.layout
  }
  private func triangleStorage(_ count: Int) throws -> MTLBuffer {
    let bytes = count.multipliedReportingOverflow(by: MemoryLayout<MeshTriangle>.stride)
    guard !bytes.overflow,
      let b = device.makeBuffer(length: max(128, bytes.partialValue), options: .storageModeShared)
    else { throw Self.error("Could not allocate imported mesh.") }
    return b
  }
  private func publishMesh(_ t: MTLBuffer, count: Int, document: [MeshTriangle]) throws {
    meshBuildCount += 1
    let nodes = OBJMesh.buildInPlace(UnsafeMutableBufferPointer(
      start: count == 0 ? nil : t.contents().bindMemory(to: MeshTriangle.self, capacity: count), count: count))
    let n: MTLBuffer
    if nodes.isEmpty {
      guard let b = device.makeBuffer(length: 128, options: .storageModeShared) else {
        throw Self.error("Could not allocate imported mesh.")
      }
      n = b
    } else {
      guard
        let b = nodes.withUnsafeBytes({
          device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
      else { throw Self.error("Could not allocate imported mesh.") }
      n = b
    }
    try restoreMesh(MeshResources(triangles: document, triangleBuffer: t, triangleCount: count,
      nodeBuffer: n, nodeCount: nodes.count))
  }

  func setMeshBindings(_ graph: SceneGraph) throws {
    try graph.validate()
    if let current = meshLayout, current.assets.first?.id != MeshSceneLayout.legacyAsset {
      // Two-level: bindings live in the scene's slot table; no hierarchy is rebuilt.
      var layout = current
      layout.instances = []
      layout.renderedTriangles = 0
      layout.lo = SIMD3(repeating: .greatestFiniteMagnitude); layout.hi = -layout.lo
      try layout.addInstances(graph)
      guard layout.instances.count == current.instances.count,
        zip(layout.instances, current.instances).allSatisfy({ $0.node == $1.node && $0.asset == $1.asset && $0.world == $1.world })
      else { throw Self.error("Scene binding no longer matches the published geometry.") }
      // Same instances and transforms: the hardware instance structure is kept too.
      guard let streams = meshStreams else { throw Self.error("Scene binding no longer matches the published geometry.") }
      try publishScene(layout, streams: streams, document: meshTriangles, keepScene: true)
      return
    }
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
    // A two-level graph-less mesh of flattened triangles: new faces with rebound tags; the
    // vertices, hierarchy, extras and hardware structures are kept.
    if var layout = meshLayout, let streams = meshStreams {
      let ordered = orderedTriangles
      guard let faces = device.makeBuffer(length: streams.faces.length, options: .storageModeShared)
      else { throw Self.error("Could not allocate imported mesh bindings.") }
      let source = streams.faces.contents().bindMemory(to: MeshFace.self, capacity: max(1, ordered.count))
      let target = faces.contents().bindMemory(to: MeshFace.self, capacity: max(1, ordered.count))
      for (i, triangle) in ordered.enumerated() {
        var face = source[i]
        face.w = UInt32(try rebound(triangle).uvc.z)
        target[i] = face
      }
      var rebuilt = streams
      rebuilt.faces = faces
      // The rebound triangles no longer equal the document array the layout remembers.
      layout.assets[0].source = MeshGeometry()
      try restoreMesh(MeshResources(triangles: [], triangleBuffer: placeholderTriangles, triangleCount: ordered.count,
        nodeBuffer: nodeBuffer, nodeCount: nodeCount, layout: layout, streams: rebuilt))
      return
    }
    // Flat: rebind straight from the shared buffer into its replacement; the BVH order is unchanged.
    let ordered = orderedTriangles
    let length = ordered.count * MemoryLayout<MeshTriangle>.stride
    guard let candidateBuffer = device.makeBuffer(length: max(128, length), options: .storageModeShared)
    else { throw Self.error("Could not allocate imported mesh bindings.") }
    let target = candidateBuffer.contents().bindMemory(to: MeshTriangle.self, capacity: max(1, ordered.count))
    for (i, triangle) in ordered.enumerated() { target[i] = try rebound(triangle) }
    // Bindings belong to a scene-graph mesh, which retains no document-order copy.
    try restoreMesh(MeshResources(triangles: [], triangleBuffer: candidateBuffer, triangleCount: ordered.count,
      nodeBuffer: nodeBuffer, nodeCount: nodeCount))
  }
}
