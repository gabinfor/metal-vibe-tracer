import Cocoa
import simd

// REFERENCES.md: GLTF2, GLTFEXT, MATERIALX, OPENPBR. glTF 2.0 scenes (.gltf with embedded or external
// buffers and images, and binary .glb) open like OpenUSD stages: GLTFImporter builds a USDImportSnapshot
// and USDImporter.document turns it into the project. Nodes keep their hierarchy and local matrices, each
// glTF mesh is one asset with a material subset per primitive (triangles, strips and fans), perspective
// cameras become saved views ("glTF: name"), and a KHR_lights_punctual directional light is the sun.
// Materials become one OpenPBR MaterialX document each, compiled like any other graph:
//   baseColorFactor x baseColorTexture       base_color (texture sRGB)
//   metallicRoughnessTexture B, G x factors   base_metalness, specular_roughness (linear)
//   normalTexture, scale                      normalmap (tangent space, +Y up), scale
//   emissiveFactor x emissiveTexture          emission_color; KHR_materials_emissive_strength (else 1) is
//                                             emission_luminance (glTF emission is in nits, as OpenPBR's)
//   alphaMode MASK / BLEND                    geometry_opacity: alpha >= alphaCutoff, or alpha as coverage
//   KHR_materials_ior                         specular_ior
//   KHR_materials_transmission                transmission_weight; a constant base colour tints it
//                                             (transmission_color) on thin walls and media without attenuation
//   KHR_materials_volume                      thicknessFactor 0 is geometry_thin_walled; otherwise
//                                             attenuationColor and attenuationDistance are transmission_color
//                                             and transmission_depth (both sigma = -ln(c) / d)
//   KHR_materials_specular                    specular_weight (x texture A), specular_color (constant)
//   KHR_materials_clearcoat                   coat_weight, coat_roughness (x textures R, G); OpenPBR's coat IOR
//                                             1.6 stays (glTF's is 1.5)
//   KHR_materials_sheen                       fuzz_weight = max(sheenColorFactor) (OpenPBR's fuzz colour and
//                                             roughness keep their defaults)
//   KHR_materials_anisotropy                  OpenPBR roughness and specular_roughness_anisotropy with glTF's
//                                             alpha_t = mix(alpha, 1, strength^2), alpha_b = alpha (baked per
//                                             texel from a roughness texture); anisotropyRotation rotates
//                                             geometry_tangent about the normal (as MaterialX gltf_pbr)
//   KHR_materials_iridescence                 thin_film_weight, thin_film_ior, thin_film_thickness =
//                                             iridescenceThicknessMaximum in micrometres
//   KHR_materials_dispersion                  transmission_dispersion_abbe_number = 20 / dispersion
//   KHR_materials_unlit                       emission_color = base colour at luminance 1, no reflection
//   KHR_texture_transform                     offset, rotation and scale of the texture coordinates
// Samplers map clamp-to-edge and repeat to MaterialX addressing. Everything else the file uses, and the
// approximations above, are listed in the import report.
enum GLTFImporter {
  static let fileExtensions = ["gltf", "glb"]
  static func isGLTF(_ url: URL) -> Bool { fileExtensions.contains(url.pathExtension.lowercased()) }

  static func load(_ url: URL, into source: ProjectDocument, progress: OperationProgress? = nil) throws -> USDImportResult {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-gltf-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    progress?.begin("Reading \(url.lastPathComponent)")
    var reader = try Reader(url: url, folder: folder)
    let (snapshot, assets) = try reader.snapshot(progress: progress)
    return try USDImporter.document(snapshot, assets: assets, folder: folder, url: url, into: source,
      format: "glTF", lights: "KHR_lights_punctual")
  }

  static func error(_ message: String) -> Error { MaterialLibrary.error("glTF: " + message) }

  // One parsed file: its JSON, the GLB binary chunk, and caches of decoded buffers and written images.
  struct Reader {
    let url: URL
    let folder: URL
    let json: [String: Any]
    // The top-level arrays, bridged once (a cast re-bridges the whole array each time).
    private let lists: [String: [[String: Any]]]
    let binary: Data?
    private var buffers: [Int: Data] = [:]
    private var imageFiles: [Int: URL?] = [:]
    private var bakes = 0
    var report: [String] = []
    private var reported = Set<String>()

    init(url: URL, folder: URL) throws {
      self.url = url
      self.folder = folder
      let data = try Data(contentsOf: url, options: .alwaysMapped)
      var text = data
      var binary: Data?
      if data.prefix(4) == Data("glTF".utf8) {
        // GLB: a 12-byte header, then chunks of (length, type, payload): JSON first, then an optional BIN.
        guard data.count >= 20, Self.u32(data, 4) == 2, Int(Self.u32(data, 8)) <= data.count else {
          throw GLTFImporter.error("unsupported or truncated GLB header.")
        }
        var offset = 12
        var chunks: [UInt32: Data] = [:]
        while offset + 8 <= data.count {
          let length = Int(Self.u32(data, offset)), type = Self.u32(data, offset + 4)
          guard offset + 8 + length <= data.count else { throw GLTFImporter.error("truncated GLB chunk.") }
          if chunks[type] == nil {
            chunks[type] = data[data.startIndex + offset + 8..<data.startIndex + offset + 8 + length]
          }
          offset += 8 + (length + 3) / 4 * 4
        }
        guard let json = chunks[0x4E4F_534A] else { throw GLTFImporter.error("GLB has no JSON chunk.") }
        text = json
        binary = chunks[0x004E_4942]
      }
      guard let object = try? JSONSerialization.jsonObject(with: text), let json = object as? [String: Any] else {
        throw GLTFImporter.error("the file is not valid glTF JSON.")
      }
      // asset.minVersion is the version a reader must support; a mislabelled asset.version (some exporters
      // write their own) is read as 2.0 and reported.
      let asset = json["asset"] as? [String: Any] ?? [:]
      if let minimum = asset["minVersion"] as? String, !minimum.hasPrefix("2.") {
        throw GLTFImporter.error("the file requires glTF \(minimum); only glTF 2.0 is supported.")
      }
      self.json = json
      lists = json.compactMapValues { $0 as? [[String: Any]] }
      self.binary = binary
      let version = asset["version"] as? String ?? "(none)"
      if !version.hasPrefix("2.") { note("asset.version is \(version), not 2.0; the file is read as glTF 2.0.") }
      let supported: Set<String> = [
        "KHR_materials_emissive_strength", "KHR_materials_ior", "KHR_materials_transmission", "KHR_materials_volume",
        "KHR_materials_specular", "KHR_materials_clearcoat", "KHR_materials_sheen", "KHR_materials_anisotropy",
        "KHR_materials_iridescence", "KHR_materials_dispersion", "KHR_materials_unlit", "KHR_texture_transform",
        "KHR_lights_punctual", "KHR_mesh_quantization", "EXT_texture_webp",
      ]
      let required = (json["extensionsRequired"] as? [String] ?? []).filter { !supported.contains($0) }
      if !required.isEmpty {
        throw GLTFImporter.error("the file requires unsupported extensions: \(required.joined(separator: ", ")).")
      }
      for name in (json["extensionsUsed"] as? [String] ?? []) where !supported.contains(name) {
        note("Extension \(name) is not supported and is ignored.")
      }
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
      data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    mutating func note(_ line: String) {
      if reported.insert(line).inserted { report.append(line) }
    }
    func list(_ key: String) -> [[String: Any]] { lists[key] ?? [] }
    static func float(_ v: Any?) -> Float? { (v as? NSNumber).map { $0.floatValue } }
    static func int(_ v: Any?) -> Int? { (v as? NSNumber).map { $0.intValue } }
    static func floats(_ v: Any?) -> [Float]? { (v as? [Any])?.compactMap { float($0) } }

    // MARK: Buffers and accessors

    mutating func buffer(_ index: Int) throws -> Data {
      if let data = buffers[index] { return data }
      let buffers = list("buffers")
      guard buffers.indices.contains(index) else { throw GLTFImporter.error("missing buffer \(index).") }
      let entry = buffers[index]
      let data: Data
      if let uri = entry["uri"] as? String {
        data = try resource(uri, what: "buffer \(index)")
      } else if index == 0, let binary {
        data = binary
      } else {
        throw GLTFImporter.error("buffer \(index) has no data.")
      }
      guard data.count >= (Self.int(entry["byteLength"]) ?? 0) else {
        throw GLTFImporter.error("buffer \(index) is shorter than its byteLength.")
      }
      self.buffers[index] = data
      return data
    }
    // A data: URI's bytes, or a file relative to the glTF file.
    func resource(_ uri: String, what: String) throws -> Data {
      if uri.hasPrefix("data:") {
        guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
          let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]), options: .ignoreUnknownCharacters)
        else { throw GLTFImporter.error("\(what) has an unsupported data URI.") }
        return data
      }
      let path = uri.removingPercentEncoding ?? uri
      let file = URL(fileURLWithPath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
      do { return try Data(contentsOf: file, options: .alwaysMapped) } catch {
        throw GLTFImporter.error("\(what) file \(path) could not be read.")
      }
    }
    // The bytes of a buffer view.
    mutating func view(_ index: Int) throws -> (data: Data, stride: Int?) {
      let views = list("bufferViews")
      guard views.indices.contains(index), let b = Self.int(views[index]["buffer"]),
        let length = Self.int(views[index]["byteLength"])
      else { throw GLTFImporter.error("invalid buffer view \(index).") }
      let offset = Self.int(views[index]["byteOffset"]) ?? 0
      let data = try buffer(b)
      guard offset >= 0, length >= 0, offset + length <= data.count else {
        throw GLTFImporter.error("buffer view \(index) exceeds its buffer.")
      }
      // A slice: accessors of one view share its bytes.
      return (data[data.startIndex + offset..<data.startIndex + offset + length], Self.int(views[index]["byteStride"]))
    }
    static let componentSizes = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4]
    static let typeComponents = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4]
    // Reads `count` elements of `components` values from bytes, as Double (exact for indices).
    static func read(_ data: Data, offset: Int, stride: Int, count: Int, components: Int, type: Int,
                     normalized: Bool) throws -> [Double] {
      guard let size = componentSizes[type] else { throw GLTFImporter.error("unsupported component type \(type).") }
      let element = components * size
      guard offset >= 0, stride > 0, count >= 0,
        count == 0 || (data.count - offset >= element && count - 1 <= (data.count - offset - element) / stride)
      else {
        throw GLTFImporter.error("accessor exceeds its buffer view.")
      }
      var out = [Double](repeating: 0, count: count * components)
      data.withUnsafeBytes { raw in
        for i in 0..<count {
          for c in 0..<components {
            let o = offset + i * stride + c * size
            var v: Double
            switch type {
            case 5120: let x = Double(raw.loadUnaligned(fromByteOffset: o, as: Int8.self)); v = normalized ? max(x / 127, -1) : x
            case 5121: let x = Double(raw.loadUnaligned(fromByteOffset: o, as: UInt8.self)); v = normalized ? x / 255 : x
            case 5122: let x = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self))); v = normalized ? max(x / 32767, -1) : x
            case 5123: let x = Double(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))); v = normalized ? x / 65535 : x
            case 5125: v = Double(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)))
            default: v = Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))))
            }
            out[i * components + c] = v
          }
        }
      }
      return out
    }
    // An accessor's values (sparse substitution applied) and its component count.
    mutating func accessor(_ index: Int) throws -> (values: [Double], components: Int, count: Int) {
      let accessors = list("accessors")
      guard accessors.indices.contains(index), let type = Self.int(accessors[index]["componentType"]),
        let count = Self.int(accessors[index]["count"]), count >= 0,
        let components = Self.typeComponents[accessors[index]["type"] as? String ?? ""],
        let size = Self.componentSizes[type]
      else { throw GLTFImporter.error("invalid or unsupported accessor \(index).") }
      let a = accessors[index]
      let normalized = a["normalized"] as? Bool ?? false
      var values: [Double]
      if let v = Self.int(a["bufferView"]) {
        let (data, stride) = try view(v)
        values = try Self.read(data, offset: Self.int(a["byteOffset"]) ?? 0, stride: stride ?? components * size,
          count: count, components: components, type: type, normalized: normalized)
      } else {
        guard (0...3 * SceneLimits.triangles).contains(count) else { throw GLTFImporter.error("accessor \(index) is too large.") }
        values = [Double](repeating: 0, count: count * components)
      }
      if let sparse = a["sparse"] as? [String: Any], let n = Self.int(sparse["count"]), n > 0,
        let ix = sparse["indices"] as? [String: Any], let vx = sparse["values"] as? [String: Any],
        let iv = Self.int(ix["bufferView"]), let it = Self.int(ix["componentType"]), let vv = Self.int(vx["bufferView"])
      {
        let (id, _) = try view(iv), (vd, _) = try view(vv)
        let indices = try Self.read(id, offset: Self.int(ix["byteOffset"]) ?? 0, stride: Self.componentSizes[it] ?? 4,
          count: n, components: 1, type: it, normalized: false)
        let replaced = try Self.read(vd, offset: Self.int(vx["byteOffset"]) ?? 0, stride: components * size,
          count: n, components: components, type: type, normalized: normalized)
        for (k, i) in indices.enumerated() {
          guard let i = Int(exactly: i), (0..<count).contains(i) else {
            throw GLTFImporter.error("sparse accessor \(index) index out of range.")
          }
          for c in 0..<components { values[i * components + c] = replaced[k * components + c] }
        }
      }
      return (values, components, count)
    }

    // MARK: Scene

    mutating func snapshot(progress: OperationProgress?) throws -> (USDImportSnapshot, [MeshAsset]) {
      let materials = list("materials")
      var materialIDs: [UUID] = []
      var snapshotMaterials: [USDImportSnapshot.Material] = []
      for (i, m) in materials.enumerated() {
        progress?.update("Translating glTF materials", completed: i, of: materials.count)
        let name = m["name"] as? String ?? "Material \(i)"
        let id = UUID()
        materialIDs.append(id)
        let factor = Self.floats((m["pbrMetallicRoughness"] as? [String: Any])?["baseColorFactor"]) ?? [1, 1, 1, 1]
        let mtlx = try material(m, name: name, index: i)
        snapshotMaterials.append(USDImportSnapshot.Material(
          id: id, name: name, color: Array(factor.prefix(3)) + Array(repeating: 1, count: max(0, 3 - factor.count)),
          path: "materials/\(i) \(name)", mtlx: mtlx))
      }
      // Primitives without a material use glTF's default (white, metallic 1, roughness 1).
      var defaultMaterial: UUID?
      func fallback() throws -> UUID {
        if let id = defaultMaterial { return id }
        let id = UUID()
        defaultMaterial = id
        snapshotMaterials.append(USDImportSnapshot.Material(
          id: id, name: "glTF default", color: [1, 1, 1], path: "materials/default",
          mtlx: try material([:], name: "glTF default", index: materials.count)))
        return id
      }
      // Meshes: one asset per glTF mesh, a subset per primitive.
      var assets: [MeshAsset?] = []
      var bindings: [[UUID]] = []
      let meshes = list("meshes")
      var stored = 0
      for (i, mesh) in meshes.enumerated() {
        progress?.update("Reading glTF meshes", completed: i, of: meshes.count)
        var vertices: [MeshVertex] = [], faces: [MeshFace] = [], subsets: [String] = [], bound: [UUID] = []
        for primitive in mesh["primitives"] as? [[String: Any]] ?? [] {
          let mode = Self.int(primitive["mode"]) ?? 4
          guard [4, 5, 6].contains(mode) else {
            note("\(mesh["name"] as? String ?? "Mesh \(i)"): points and lines (mode \(mode)) are not rendered.")
            continue
          }
          if primitive["targets"] != nil { note("Morph targets are not applied; meshes use their base shape.") }
          let tag = UInt32(subsets.count)
          let before = faces.count
          try triangles(primitive, mode: mode, tag: tag, vertices: &vertices, faces: &faces)
          guard faces.count > before else { continue }
          let m = Self.int(primitive["material"])
          let material: UUID
          if let m, materialIDs.indices.contains(m) {
            material = materialIDs[m]
            subsets.append(materials[m]["name"] as? String ?? "Material \(m)")
          } else {
            material = try fallback()
            subsets.append("glTF default")
          }
          bound.append(material)
        }
        stored += faces.count
        guard stored <= SceneLimits.triangles else {
          throw GLTFImporter.error("the meshes exceed the \(SceneLimits.triangles.formatted()) triangle limit.")
        }
        if faces.isEmpty {
          assets.append(nil)
        } else {
          assets.append(MeshAsset(name: mesh["name"] as? String ?? "Mesh \(i)",
            geometry: MeshGeometry(vertices: vertices, faces: faces), subsets: subsets))
        }
        bindings.append(bound)
      }
      if !list("skins").isEmpty { note("Skins are not applied; skinned meshes keep their bind pose.") }
      if !list("animations").isEmpty { note("Animations are not imported; the scene opens at its rest pose.") }

      // Nodes: the scene's hierarchy under one root named after the file.
      let nodes = list("nodes")
      let root = SceneNode(name: url.lastPathComponent)
      var sceneNodes = [root]
      var cameras: [USDImportSnapshot.Camera] = []
      var sun: USDImportSnapshot.Sun?
      let scenes = list("scenes")
      var roots: [Int]
      if let s = Self.int(json["scene"]) ?? (scenes.isEmpty ? nil : 0), scenes.indices.contains(s) {
        roots = (scenes[s]["nodes"] as? [Any] ?? []).compactMap { Self.int($0) }
      } else {
        let children = Set(nodes.flatMap { ($0["children"] as? [Any] ?? []).compactMap { Self.int($0) } })
        roots = nodes.indices.filter { !children.contains($0) }
      }
      let lights = (json["extensions"] as? [String: Any]).flatMap { $0["KHR_lights_punctual"] as? [String: Any] }
        .flatMap { $0["lights"] as? [[String: Any]] } ?? []
      var visited = Set<Int>()
      var stack: [(index: Int, parent: UUID, world: simd_float4x4)] = roots.reversed().map { ($0, root.id, matrix_identity_float4x4) }
      while let (index, parent, parentWorld) = stack.popLast() {
        guard nodes.indices.contains(index), visited.insert(index).inserted else {
          throw GLTFImporter.error("invalid or cyclic node \(index).")
        }
        guard sceneNodes.count < SceneLimits.nodes else {
          throw GLTFImporter.error("the scene exceeds \(SceneLimits.nodes) nodes.")
        }
        let n = nodes[index]
        let local = try Self.localMatrix(n)
        let world = parentWorld * local
        let name = n["name"] as? String ?? "Node \(index)"
        var node = SceneNode(name: name, parent: parent)
        node.matrix = (0..<4).flatMap { c in (0..<4).map { r in local[c][r] } }
        // As usd_bridge.py's singular(): a collapsed basis (scale 0 hides an object) cannot be rendered, so the
        // subtree is hidden instead of failing the import (SceneGraph.forEachRenderTriangle).
        let scale = simd_length(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z))
        if !(abs(simd_determinant(world)) > 1e-18) || !(0.000001...1_000_000).contains(scale) {
          node.transform.rotationHidden.w = 1
          note("\(name): zero or singular scale; the node and its children are hidden.")
        }
        if let m = Self.int(n["mesh"]), assets.indices.contains(m), let asset = assets[m] {
          node.mesh = asset.id
          node.bindings = bindings[m]
        }
        sceneNodes.append(node)
        if let c = Self.int(n["camera"]) { camera(c, name: name, world: world, into: &cameras) }
        if let l = (n["extensions"] as? [String: Any]).flatMap({ $0["KHR_lights_punctual"] as? [String: Any] })
          .flatMap({ Self.int($0["light"]) }), lights.indices.contains(l)
        {
          light(lights[l], name: name, world: world, sun: &sun)
        }
        for child in (n["children"] as? [Any] ?? []).compactMap({ Self.int($0) }).reversed() {
          stack.append((child, node.id, world))
        }
      }
      let snapshot = USDImportSnapshot(
        nodes: sceneNodes, assets: [], materials: snapshotMaterials, cameras: cameras, environment: nil, sun: sun,
        report: report, fallbackColors: nil, medium: nil)
      return (snapshot, assets.compactMap { $0 })
    }
    // A node's local transform: its matrix, or translation x rotation x scale.
    static func localMatrix(_ n: [String: Any]) throws -> simd_float4x4 {
      if let m = floats(n["matrix"]) {
        guard m.count == 16 else { throw GLTFImporter.error("invalid node matrix.") }
        return simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                       SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
      }
      let t = floats(n["translation"]) ?? [0, 0, 0], r = floats(n["rotation"]) ?? [0, 0, 0, 1]
      let s = floats(n["scale"]) ?? [1, 1, 1]
      guard t.count == 3, r.count == 4, s.count == 3 else { throw GLTFImporter.error("invalid node transform.") }
      let q = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
      let rotation = simd_float4x4(simd_length(q.vector) > 0 ? simd_normalize(q) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
      var m = rotation * simd_float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1))
      m.columns.3 = SIMD4(t[0], t[1], t[2], 1)
      return m
    }
    mutating func camera(_ index: Int, name: String, world: simd_float4x4, into cameras: inout [USDImportSnapshot.Camera]) {
      let list = self.list("cameras")
      guard list.indices.contains(index), let p = list[index]["perspective"] as? [String: Any],
        let yfov = Self.float(p["yfov"])
      else {
        note("\(name): orthographic cameras are not supported.")
        return
      }
      let eye = world.columns.3
      let forward = simd_normalize(SIMD3(-world.columns.2.x, -world.columns.2.y, -world.columns.2.z))
      let up = simd_normalize(SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z))
      let label = list[index]["name"] as? String ?? name
      cameras.append(USDImportSnapshot.Camera(name: label, eye: [eye.x, eye.y, eye.z], direction: [forward.x, forward.y, forward.z],
        up: [up.x, up.y, up.z], fov: yfov * 180 / .pi, focus: nil))
    }
    // KHR_lights_punctual: a directional light (lux, shining down its local -Z) becomes the sun.
    mutating func light(_ l: [String: Any], name: String, world: simd_float4x4, sun: inout USDImportSnapshot.Sun?) {
      guard l["type"] as? String == "directional" else {
        note("\(name): KHR_lights_punctual \(l["type"] as? String ?? "") lights are not supported; only directional lights are imported (as the sun).")
        return
      }
      guard sun == nil else { note("\(name): only the first directional light is imported."); return }
      let toward = simd_normalize(SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
      if let c = Self.floats(l["color"]), c.count == 3, c != [1, 1, 1] {
        note("\(name): the directional light's colour is not imported; the sun spectrum applies.")
      }
      sun = USDImportSnapshot.Sun(direction: [toward.x, toward.y, toward.z], intensity: Self.float(l["intensity"]) ?? 1,
        angle: nil, normalize: true)
    }
    // Appends a primitive's triangles: positions, normals (face normals when absent) and TEXCOORD_0.
    mutating func triangles(_ primitive: [String: Any], mode: Int, tag: UInt32, vertices: inout [MeshVertex],
                            faces: inout [MeshFace]) throws {
      guard let attributes = primitive["attributes"] as? [String: Any], let p = Self.int(attributes["POSITION"]) else {
        throw GLTFImporter.error("a primitive has no POSITION attribute.")
      }
      let position = try accessor(p)
      guard position.components == 3 else { throw GLTFImporter.error("POSITION must be VEC3.") }
      let count = position.count
      let normal = try Self.int(attributes["NORMAL"]).map { try accessor($0) }
      let uv = try Self.int(attributes["TEXCOORD_0"]).map { try accessor($0) }
      if attributes["COLOR_0"] != nil { note("Vertex colours (COLOR_0) are not imported; materials use their base colour.") }
      guard normal.map({ $0.components == 3 && $0.count == count }) ?? true,
        uv.map({ $0.components == 2 && $0.count == count }) ?? true
      else { throw GLTFImporter.error("vertex attributes do not match POSITION.") }
      let indices: [Int]
      if let i = Self.int(primitive["indices"]) {
        let a = try accessor(i)
        indices = try a.values.map { v in
          guard let i = Int(exactly: v), (0..<count).contains(i) else { throw GLTFImporter.error("index out of range.") }
          return i
        }
      } else {
        indices = Array(0..<count)
      }
      var corners: [(Int, Int, Int)] = []
      switch mode {
      case 5:
        if indices.count >= 3 {
          for i in 0..<indices.count - 2 {
            corners.append(i % 2 == 0 ? (indices[i], indices[i + 1], indices[i + 2]) : (indices[i + 1], indices[i], indices[i + 2]))
          }
        }
      case 6:
        if indices.count >= 3 { for i in 1..<indices.count - 1 { corners.append((indices[0], indices[i], indices[i + 1])) } }
      default:
        for i in stride(from: 0, to: indices.count - 2, by: 3) { corners.append((indices[i], indices[i + 1], indices[i + 2])) }
      }
      func point(_ i: Int) -> SIMD3<Float> {
        SIMD3(Float(position.values[3 * i]), Float(position.values[3 * i + 1]), Float(position.values[3 * i + 2]))
      }
      // Shared glTF vertices map to one stored vertex; without normals each triangle keeps its own corners.
      var map = [Int32](repeating: -1, count: normal == nil ? 0 : count)
      var skipped = 0
      for (a, b, c) in corners {
        let pa = point(a), pb = point(b), pc = point(c)
        let n = simd_cross(pb - pa, pc - pa)
        guard a != b, b != c, a != c, simd_length_squared(n) > 0 else { skipped += 1; continue }
        var face = MeshFace(0, 0, 0, tag)
        for (k, i) in [a, b, c].enumerated() {
          if normal != nil, map[i] >= 0 { face[k] = UInt32(map[i]); continue }
          let q = point(i)
          let nn = normal.map { SIMD3(Float($0.values[3 * i]), Float($0.values[3 * i + 1]), Float($0.values[3 * i + 2])) }
            ?? simd_normalize(n)
          let t = uv.map { SIMD2(Float($0.values[2 * i]), Float($0.values[2 * i + 1])) } ?? .zero
          face[k] = UInt32(vertices.count)
          if normal != nil { map[i] = Int32(vertices.count) }
          vertices.append(MeshVertex(q.x, q.y, q.z, nn.x, nn.y, nn.z, t.x, t.y))
        }
        faces.append(face)
      }
      if skipped > 0 { note("\(skipped) degenerate triangles were skipped.") }
    }

    // MARK: Images

    // The image file a texture samples, written beside the generated MaterialX (nil when unreadable).
    mutating func imageFile(texture index: Int, owner: String) throws -> URL? {
      let textures = list("textures")
      guard textures.indices.contains(index) else { note("\(owner): missing texture \(index); its factor is used."); return nil }
      let t = textures[index]
      let ext = t["extensions"] as? [String: Any]
      var source = Self.int(t["source"])
      if let webp = (ext?["EXT_texture_webp"] as? [String: Any]).flatMap({ Self.int($0["source"]) }) { source = webp }
      if source == nil, ext?["KHR_texture_basisu"] != nil {
        note("\(owner): KTX2 (KHR_texture_basisu) textures are not supported; its factor is used.")
        return nil
      }
      guard let source else { note("\(owner): texture \(index) has no image; its factor is used."); return nil }
      if let cached = imageFiles[source] { return cached }
      let images = list("images")
      guard images.indices.contains(source) else { throw GLTFImporter.error("missing image \(source).") }
      let image = images[source]
      let data: Data
      if let uri = image["uri"] as? String {
        data = try resource(uri, what: "image \(source)")
      } else if let v = Self.int(image["bufferView"]) {
        data = try view(v).data
      } else {
        throw GLTFImporter.error("image \(source) has no data.")
      }
      let mime = image["mimeType"] as? String ?? ""
      let ext2 = mime == "image/jpeg" ? "jpg" : mime == "image/webp" ? "webp" : mime == "image/ktx2" ? "ktx2" : "png"
      guard ext2 != "ktx2", CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) != nil else {
        note("\(owner): image \(image["name"] as? String ?? String(source)) could not be decoded; its factor is used.")
        imageFiles[source] = .some(nil)
        return nil
      }
      let file = folder.appendingPathComponent("image\(source).\(ext2)")
      try data.write(to: file)
      imageFiles[source] = file
      return file
    }

    // Writes a 16-bit grey PNG of f(texel) over an image's channels (stored values, no colour conversion).
    mutating func bake(_ file: URL, owner: String, _ f: (SIMD4<Float>) -> Float) throws -> URL {
      guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { throw GLTFImporter.error("\(owner): could not decode \(file.lastPathComponent).") }
      let w = image.width, h = image.height
      let gray = image.colorSpace?.model == .monochrome
      let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
      var texels = [UInt16](repeating: 0, count: (gray ? 1 : 4) * w * h)
      try texels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 16,
          bytesPerRow: (gray ? 2 : 8) * w, space: space,
          bitmapInfo: (gray ? CGImageAlphaInfo.none : CGImageAlphaInfo.noneSkipLast).rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        else { throw GLTFImporter.error("\(owner): could not read \(file.lastPathComponent).") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      }
      var out = [UInt16](repeating: 0, count: w * h)
      for i in 0..<w * h {
        let t = gray ? SIMD4(repeating: Float(texels[i]) / 65535)
          : SIMD4(Float(texels[4 * i]), Float(texels[4 * i + 1]), Float(texels[4 * i + 2]), 65535) / 65535
        out[i] = UInt16((min(1, max(0, f(t))) * 65535).rounded()).bigEndian
      }
      let provider = CGDataProvider(data: Data(bytes: out, count: 2 * w * h) as CFData)!
      guard let result = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: 2 * w,
        space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
      else { throw GLTFImporter.error("\(owner): could not bake \(file.lastPathComponent).") }
      bakes += 1
      let output = folder.appendingPathComponent("bake\(bakes).png")
      guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
        throw GLTFImporter.error("\(owner): could not write a baked map.")
      }
      CGImageDestinationAddImage(destination, result, nil)
      guard CGImageDestinationFinalize(destination) else { throw GLTFImporter.error("\(owner): could not write a baked map.") }
      return output
    }

    // MARK: Materials

    // glTF's anisotropy as OpenPBR inputs: alpha_t = mix(alpha, 1, s^2) and alpha_b = alpha (glTF) equal
    // OpenPBR's alpha' sqrt(2 / (1 + (1 - a)^2)) and (1 - a) times that, so a = 1 - alpha / alpha_t and
    // alpha' = alpha_t / sqrt(2 / (1 + (alpha / alpha_t)^2)). Returns (roughness sqrt(alpha'), anisotropy a).
    static func anisotropic(roughness r: Float, strength s: Float) -> (roughness: Float, anisotropy: Float) {
      let alpha = r * r, alphaT = alpha + s * s * (1 - alpha)
      guard alphaT > 0 else { return (r, 0) }
      let ratio = alpha / alphaT
      return ((alphaT / (2 / (1 + ratio * ratio)).squareRoot()).squareRoot(), 1 - ratio)
    }

    mutating func material(_ m: [String: Any], name owner: String, index: Int) throws -> String {
      var w = Writer(prefix: "m\(index)")
      let pbr = m["pbrMetallicRoughness"] as? [String: Any] ?? [:]
      let ext = m["extensions"] as? [String: Any] ?? [:]
      for key in ext.keys where ![
        "KHR_materials_emissive_strength", "KHR_materials_ior", "KHR_materials_transmission", "KHR_materials_volume",
        "KHR_materials_specular", "KHR_materials_clearcoat", "KHR_materials_sheen", "KHR_materials_anisotropy",
        "KHR_materials_iridescence", "KHR_materials_dispersion", "KHR_materials_unlit",
      ].contains(key) {
        note("\(owner): \(key) is not supported and is ignored.")
      }
      func number(_ d: [String: Any]?, _ key: String, _ fallback: Float) -> Float { Self.float(d?[key]) ?? fallback }
      // A texture reference: the MaterialX image node name for `type` (nil without a readable image).
      func texture(_ info: Any?, _ type: String, srgb: Bool) throws -> String? {
        guard let info = info as? [String: Any], let t = Self.int(info["index"]) else { return nil }
        guard let file = try imageFile(texture: t, owner: owner) else { return nil }
        return try image(file, info: info, type: type, srgb: srgb, texture: t)
      }
      func image(_ file: URL, info: [String: Any], type: String, srgb: Bool, texture t: Int) throws -> String {
        var coordinates: String?
        let transform = (info["extensions"] as? [String: Any])?["KHR_texture_transform"] as? [String: Any]
        let set = Self.int(transform?["texCoord"]) ?? Self.int(info["texCoord"]) ?? 0
        if set != 0 { note("\(owner): texture coordinate set \(set) is read from TEXCOORD_0 (one UV set is imported).") }
        if let transform { coordinates = w.transform(transform) }
        let textures = list("textures"), samplers = list("samplers")
        let sampler = Self.int(textures[t]["sampler"]).flatMap { samplers.indices.contains($0) ? samplers[$0] : nil }
        func mode(_ key: String) -> String {
          switch Self.int(sampler?[key]) ?? 10497 {
          case 33071: return "clamp"
          case 33648: note("\(owner): mirrored-repeat wrapping is rendered as repeat."); return "periodic"
          default: return "periodic"
          }
        }
        return w.image(file.path, type: type, colorspace: srgb ? "srgb_texture" : "raw", uv: coordinates,
          u: mode("wrapS"), v: mode("wrapT"))
      }
      func scaled(_ node: String, _ factor: Float) -> Writer.Value {
        factor == 1 ? .node(node, "float") : .node(w.op("multiply", "float", [("in1", .node(node, "float")), ("in2", .float(factor))]), "float")
      }
      var inputs: [(String, Writer.Value)] = []
      let unlit = ext["KHR_materials_unlit"] != nil

      // Base colour and alpha.
      let factor = Self.floats(pbr["baseColorFactor"]) ?? [1, 1, 1, 1]
      let rgb = SIMD3(factor.count > 0 ? factor[0] : 1, factor.count > 1 ? factor[1] : 1, factor.count > 2 ? factor[2] : 1)
      let alphaFactor = factor.count > 3 ? factor[3] : 1
      var baseColor: Writer.Value = .color(rgb)
      var colorTextured = false
      if let n = try texture(pbr["baseColorTexture"], "color3", srgb: true) {
        colorTextured = true
        baseColor = rgb == SIMD3(repeating: 1) ? .node(n, "color3")
          : .node(w.op("multiply", "color3", [("in1", .node(n, "color3")), ("in2", .color(rgb))]), "color3")
      }
      let alphaMode = m["alphaMode"] as? String ?? "OPAQUE"
      if alphaMode != "OPAQUE" {
        var alpha: Writer.Value = .float(alphaFactor)
        if let info = pbr["baseColorTexture"] as? [String: Any], let t = Self.int(info["index"]),
          let file = try imageFile(texture: t, owner: owner)
        {
          let rgba = try image(file, info: info, type: "color4", srgb: false, texture: t)
          alpha = scaled(w.op("extract", "float", [("in", .node(rgba, "color4")), ("index", .integer(3))]), alphaFactor)
        }
        if alphaMode == "MASK" {
          let cutoff = number(m, "alphaCutoff", 0.5)
          if case .float(let a) = alpha {
            alpha = .float(a >= cutoff ? 1 : 0)
          } else {
            // alpha >= cutoff as a steep ramp that reaches 1 at the cutoff and 0 just below it.
            let shifted = w.op("subtract", "float", [("in1", alpha), ("in2", .float(cutoff))])
            let steep = w.op("multiply", "float", [("in1", .node(shifted, "float")), ("in2", .float(10000))])
            let ramp = w.op("add", "float", [("in1", .node(steep, "float")), ("in2", .float(1))])
            alpha = .node(w.op("clamp", "float", [("in", .node(ramp, "float"))]), "float")
          }
        }
        if case .float(let a) = alpha, a >= 1 {} else { inputs.append(("geometry_opacity", alpha)) }
      }
      if unlit {
        // KHR_materials_unlit: the base colour as emitted radiance, with no reflection.
        inputs += [("base_weight", .float(0)), ("specular_weight", .float(0)), ("emission_color", baseColor),
                   ("emission_luminance", .float(1))]
        note("\(owner): KHR_materials_unlit is rendered as emission of the base colour.")
        return w.document(inputs)
      }
      inputs.append(("base_color", baseColor))

      // Metalness and roughness (G roughness, B metalness).
      let metallic = number(pbr, "metallicFactor", 1), roughnessFactor = number(pbr, "roughnessFactor", 1)
      var roughness: Writer.Value = .float(roughnessFactor)
      var roughnessImage: (file: URL, info: [String: Any], texture: Int)?
      if let info = pbr["metallicRoughnessTexture"] as? [String: Any], let t = Self.int(info["index"]),
        let file = try imageFile(texture: t, owner: owner)
      {
        let n = try image(file, info: info, type: "color3", srgb: false, texture: t)
        roughness = scaled(w.op("extract", "float", [("in", .node(n, "color3")), ("index", .integer(1))]), roughnessFactor)
        inputs.append(("base_metalness", scaled(w.op("extract", "float", [("in", .node(n, "color3")), ("index", .integer(2))]), metallic)))
        roughnessImage = (file, info, t)
      } else {
        inputs.append(("base_metalness", .float(metallic)))
      }

      // Anisotropy: OpenPBR roughness and anisotropy that reproduce glTF's two roughnesses.
      if let a = ext["KHR_materials_anisotropy"] as? [String: Any] {
        let strength = number(a, "anisotropyStrength", 0), rotation = number(a, "anisotropyRotation", 0)
        if a["anisotropyTexture"] != nil {
          note("\(owner): the anisotropy texture (per-texel direction and strength) is not supported; the constant strength and rotation are used.")
        }
        if strength > 0 {
          if case .float(let r) = roughness {
            let converted = Self.anisotropic(roughness: r, strength: strength)
            roughness = .float(converted.roughness)
            inputs.append(("specular_roughness_anisotropy", .float(converted.anisotropy)))
          } else if let source = roughnessImage {
            let k = roughnessFactor
            let rFile = try bake(source.file, owner: owner) { Self.anisotropic(roughness: $0.y * k, strength: strength).roughness }
            let aFile = try bake(source.file, owner: owner) { Self.anisotropic(roughness: $0.y * k, strength: strength).anisotropy }
            roughness = .node(try image(rFile, info: source.info, type: "float", srgb: false, texture: source.texture), "float")
            inputs.append(("specular_roughness_anisotropy",
              .node(try image(aFile, info: source.info, type: "float", srgb: false, texture: source.texture), "float")))
          }
          // glTF does not bound the rotation; the tangent rotation takes one turn at most.
          let turn = rotation.truncatingRemainder(dividingBy: 2 * .pi)
          if turn != 0 { inputs.append(("geometry_tangent", .node(w.rotatedTangent(degrees: -turn * 180 / .pi), "vector3"))) }
        }
      }
      inputs.append(("specular_roughness", roughness))

      // Normal map.
      if let info = m["normalTexture"] as? [String: Any], let n = try texture(info, "vector3", srgb: false) {
        let scale = number(info, "scale", 1)
        inputs.append(("geometry_normal", .node(w.op("normalmap", "vector3",
          [("in", .node(n, "vector3"))] + (scale == 1 ? [] : [("scale", .float(scale))])), "vector3")))
      }
      if m["occlusionTexture"] != nil { note("Occlusion textures are not used; the path tracer computes occlusion.") }

      // Emission (nits).
      let emissive = Self.floats(m["emissiveFactor"]) ?? [0, 0, 0]
      if emissive.count == 3, emissive.contains(where: { $0 > 0 }) {
        let e = SIMD3(emissive[0], emissive[1], emissive[2])
        var color: Writer.Value = .color(e)
        if let n = try texture(m["emissiveTexture"], "color3", srgb: true) {
          color = .node(w.op("multiply", "color3", [("in1", .node(n, "color3")), ("in2", .color(e))]), "color3")
        }
        let strength = number(ext["KHR_materials_emissive_strength"] as? [String: Any], "emissiveStrength", 1)
        inputs += [("emission_color", color), ("emission_luminance", .float(strength))]
      }

      // IOR, specular.
      if let i = ext["KHR_materials_ior"] as? [String: Any] {
        let ior = number(i, "ior", 1.5)
        if ior < 1.01 || ior > 2.5 { note("\(owner): IOR \(ior) is clamped to the renderer's 1.01–2.5.") }
        inputs.append(("specular_ior", .float(min(2.5, max(1.01, ior)))))
      }
      if let s = ext["KHR_materials_specular"] as? [String: Any] {
        var weight: Writer.Value = .float(number(s, "specularFactor", 1))
        if let info = s["specularTexture"] as? [String: Any], let t = Self.int(info["index"]), let file = try imageFile(texture: t, owner: owner) {
          let n = try image(file, info: info, type: "color4", srgb: false, texture: t)
          weight = scaled(w.op("extract", "float", [("in", .node(n, "color4")), ("index", .integer(3))]), number(s, "specularFactor", 1))
        }
        inputs.append(("specular_weight", weight))
        if let c = Self.floats(s["specularColorFactor"]), c.count == 3, c != [1, 1, 1] {
          if c.contains(where: { $0 > 1 }) { note("\(owner): specularColorFactor above 1 is clamped to 1.") }
          inputs.append(("specular_color", .color(simd_clamp(SIMD3(c[0], c[1], c[2]), .zero, SIMD3(repeating: 1)))))
        }
        if s["specularColorTexture"] != nil { note("\(owner): the specular colour texture is not supported; its factor is used.") }
      }

      // Transmission and volume.
      var transmits = false
      if let t = ext["KHR_materials_transmission"] as? [String: Any] {
        var weight: Writer.Value = .float(number(t, "transmissionFactor", 0))
        if let info = t["transmissionTexture"] as? [String: Any], let n = try texture(info, "color3", srgb: false) {
          weight = scaled(w.op("extract", "float", [("in", .node(n, "color3")), ("index", .integer(0))]), number(t, "transmissionFactor", 0))
        }
        if case .float(let x) = weight, x == 0 {} else {
          transmits = true
          inputs.append(("transmission_weight", weight))
        }
      }
      if transmits {
        let volume = ext["KHR_materials_volume"] as? [String: Any]
        let thick = number(volume, "thicknessFactor", 0) > 0
        let distance = number(volume, "attenuationDistance", .infinity)
        let attenuation = Self.floats(volume?["attenuationColor"]) ?? [1, 1, 1]
        if !thick {
          inputs.append(("geometry_thin_walled", .boolean(true)))
        }
        if thick, distance.isFinite, distance > 0, attenuation.count == 3, attenuation != [1, 1, 1] {
          let c = simd_clamp(SIMD3(attenuation[0], attenuation[1], attenuation[2]), .zero, SIMD3(repeating: 1))
          inputs += [("transmission_color", .color(c)), ("transmission_depth", .float(distance))]
          if rgb != SIMD3(repeating: 1) || colorTextured {
            note("\(owner): the base colour's tint of transmitted light is not applied with volume attenuation.")
          }
        } else if colorTextured {
          note("\(owner): a textured base colour does not tint transmitted light (OpenPBR's transmission colour is constant).")
        } else if rgb != SIMD3(repeating: 1) {
          inputs.append(("transmission_color", .color(simd_clamp(rgb, .zero, SIMD3(repeating: 1)))))
        }
        if let d = ext["KHR_materials_dispersion"] as? [String: Any], let dispersion = Self.float(d["dispersion"]), dispersion > 0 {
          inputs += [("transmission_dispersion_scale", .float(1)), ("transmission_dispersion_abbe_number", .float(20 / dispersion))]
        }
      }

      // Clearcoat, sheen.
      if let c = ext["KHR_materials_clearcoat"] as? [String: Any] {
        var weight: Writer.Value = .float(number(c, "clearcoatFactor", 0))
        if let info = c["clearcoatTexture"] as? [String: Any], let n = try texture(info, "color3", srgb: false) {
          weight = scaled(w.op("extract", "float", [("in", .node(n, "color3")), ("index", .integer(0))]), number(c, "clearcoatFactor", 0))
        }
        var roughness: Writer.Value = .float(number(c, "clearcoatRoughnessFactor", 0))
        if let info = c["clearcoatRoughnessTexture"] as? [String: Any], let n = try texture(info, "color3", srgb: false) {
          roughness = scaled(w.op("extract", "float", [("in", .node(n, "color3")), ("index", .integer(1))]), number(c, "clearcoatRoughnessFactor", 0))
        }
        inputs += [("coat_weight", weight), ("coat_roughness", roughness)]
        note("\(owner): the clearcoat uses OpenPBR's coat IOR 1.6 (glTF's is 1.5).")
        if c["clearcoatNormalTexture"] != nil { note("\(owner): the clearcoat normal texture is not supported; the coat follows the surface normal.") }
      }
      if let s = ext["KHR_materials_sheen"] as? [String: Any], let c = Self.floats(s["sheenColorFactor"]), let x = c.max(), x > 0 {
        inputs.append(("fuzz_weight", .float(min(1, x))))
        note("\(owner): KHR_materials_sheen is rendered as OpenPBR fuzz of weight max(sheenColorFactor), with fuzz's default colour and roughness.")
      }

      // Iridescence (thin film; spectral transport).
      if let i = ext["KHR_materials_iridescence"] as? [String: Any], number(i, "iridescenceFactor", 0) > 0 {
        let thickness = number(i, "iridescenceThicknessMaximum", 400)
        if i["iridescenceTexture"] != nil || i["iridescenceThicknessTexture"] != nil {
          note("\(owner): iridescence textures are not supported; the factor and maximum thickness are used.")
        }
        inputs += [("thin_film_weight", .float(min(1, number(i, "iridescenceFactor", 0)))),
                   ("thin_film_thickness", .float(min(100, max(0, thickness / 1000)))),
                   ("thin_film_ior", .float(max(1, number(i, "iridescenceIor", 1.3))))]
      }
      return w.document(inputs)
    }
  }

  // A MaterialX 1.39 document: top-level nodes and one open_pbr_surface.
  struct Writer {
    enum Value {
      case float(Float), color(SIMD3<Float>), integer(Int), boolean(Bool), node(String, String)
      var type: String {
        switch self {
        case .float: return "float"
        case .color: return "color3"
        case .integer: return "integer"
        case .boolean: return "boolean"
        case .node(_, let t): return t
        }
      }
      var attribute: String {
        switch self {
        case .float(let x): return "value=\"\(x)\""
        case .color(let c): return "value=\"\(c.x), \(c.y), \(c.z)\""
        case .integer(let i): return "value=\"\(i)\""
        case .boolean(let b): return "value=\"\(b)\""
        case .node(let n, _): return "nodename=\"\(n)\""
        }
      }
    }
    let prefix: String
    private var body = ""
    private var count = 0
    private var images: [String: String] = [:]
    private var transforms: [String: String] = [:]
    init(prefix: String) { self.prefix = prefix }
    static func escape(_ s: String) -> String {
      s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    mutating func op(_ category: String, _ type: String, _ inputs: [(String, Value)], extra: [(String, String, String)] = []) -> String {
      count += 1
      let name = "\(prefix)_n\(count)"
      body += "  <\(category) name=\"\(name)\" type=\"\(type)\">\n"
      for (input, v) in inputs { body += "    <input name=\"\(input)\" type=\"\(v.type)\" \(v.attribute)/>\n" }
      for (input, t, v) in extra { body += "    <input name=\"\(input)\" type=\"\(t)\" value=\"\(v)\"/>\n" }
      body += "  </\(category)>\n"
      return name
    }
    mutating func image(_ path: String, type: String, colorspace: String, uv: String?, u: String, v: String) -> String {
      let key = "\(path)|\(type)|\(colorspace)|\(uv ?? "")|\(u)|\(v)"
      if let name = images[key] { return name }
      count += 1
      let name = "\(prefix)_n\(count)"
      body += "  <image name=\"\(name)\" type=\"\(type)\">\n"
      // A colour space applies to colour images only (MaterialX ignores it on float and vector images).
      let space = type.hasPrefix("color") ? " colorspace=\"\(colorspace)\"" : ""
      body += "    <input name=\"file\" type=\"filename\" value=\"\(Self.escape(path))\"\(space)/>\n"
      if let uv { body += "    <input name=\"texcoord\" type=\"vector2\" nodename=\"\(uv)\"/>\n" }
      body += "    <input name=\"uaddressmode\" type=\"string\" value=\"\(u)\"/>\n"
      body += "    <input name=\"vaddressmode\" type=\"string\" value=\"\(v)\"/>\n"
      body += "  </image>\n"
      images[key] = name
      return name
    }
    // KHR_texture_transform in glTF's texture space (origin at the top left): g' = offset + R(rotation) S g.
    // MaterialX coordinates are t = (u, 1 - v), so with M = R S the transformed t' = (g'x, 1 - g'y) is
    // tx (M00, -M10) + ty (-M01, M11) + (M01 + ox, 1 - M11 - oy). One graph per distinct transform.
    mutating func transform(_ t: [String: Any]) -> String? {
      let offset = Reader.floats(t["offset"]) ?? [0, 0], scale = Reader.floats(t["scale"]) ?? [1, 1]
      let rotation = Reader.float(t["rotation"]) ?? 0
      guard offset.count == 2, scale.count == 2, offset != [0, 0] || scale != [1, 1] || rotation != 0 else { return nil }
      let key = "\(offset)|\(scale)|\(rotation)"
      if let name = transforms[key] { return name }
      let c = cos(rotation), s = sin(rotation)
      let m00 = c * scale[0], m01 = -s * scale[1], m10 = s * scale[0], m11 = c * scale[1]
      func v2(_ x: Float, _ y: Float) -> String { "\(x), \(y)" }
      let uv = op("texcoord", "vector2", [])
      let x = op("extract", "float", [("in", .node(uv, "vector2")), ("index", .integer(0))])
      let y = op("extract", "float", [("in", .node(uv, "vector2")), ("index", .integer(1))])
      let xx = op("convert", "vector2", [("in", .node(x, "float"))])
      let yy = op("convert", "vector2", [("in", .node(y, "float"))])
      let a = op("multiply", "vector2", [("in1", .node(xx, "vector2"))], extra: [("in2", "vector2", v2(m00, -m10))])
      let b = op("multiply", "vector2", [("in1", .node(yy, "vector2"))], extra: [("in2", "vector2", v2(-m01, m11))])
      let sum = op("add", "vector2", [("in1", .node(a, "vector2")), ("in2", .node(b, "vector2"))])
      let name = op("add", "vector2", [("in1", .node(sum, "vector2"))],
        extra: [("in2", "vector2", v2(m01 + offset[0], 1 - m11 - offset[1]))])
      transforms[key] = name
      return name
    }
    // The world tangent rotated about the world normal, as MaterialX gltf_pbr writes anisotropy_rotation.
    mutating func rotatedTangent(degrees: Float) -> String {
      let tangent = op("tangent", "vector3", [], extra: [("space", "string", "world")])
      let normal = op("normal", "vector3", [], extra: [("space", "string", "world")])
      let rotated = op("rotate3d", "vector3", [("in", .node(tangent, "vector3")), ("amount", .float(degrees)),
                                               ("axis", .node(normal, "vector3"))])
      return op("normalize", "vector3", [("in", .node(rotated, "vector3"))])
    }
    func document(_ inputs: [(String, Value)]) -> String {
      var text = "<?xml version=\"1.0\"?>\n<materialx version=\"1.39\">\n" + body
      text += "  <open_pbr_surface name=\"\(prefix)\" type=\"surfaceshader\">\n"
      for (input, v) in inputs { text += "    <input name=\"\(input)\" type=\"\(v.type)\" \(v.attribute)/>\n" }
      text += "  </open_pbr_surface>\n</materialx>\n"
      return text
    }
  }
}
