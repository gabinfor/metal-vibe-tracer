import Cocoa
import Compression
import simd

// REFERENCES.md: MITSUBA3, BITTERLI2016, OPENPBR, MATERIALX, SRGB1999, OBJ2026, PLY1994, OPENEXRLAYOUT. Mitsuba scene files (.xml whose root element is
// <scene>) open like OpenUSD stages. This layer reads and resolves the XML into a tree of Nodes; later
// stages map the shapes, BSDFs and sensor onto the project. The XML layer's rules:
//   <default name value>                      a $name variable, substituted in every attribute value, also
//                                             inside longer strings ("models/$name.obj"); the first
//                                             definition of a name wins, an undefined variable is an error
//   <include filename>                        the included file's children are spliced in place (paths
//                                             relative to the including file, the variables in scope); a
//                                             cycle is an error
//   <ref id>                                  replaced by the node that carries that id, wherever the file
//                                             defines it (ids are global, also inside another BSDF); the ref's
//                                             own name attribute is kept; an unknown id or a cycle is an error
//   <transform> operations                    composed in document order, each applied after the previous:
//                                             matrix (16 values row-major, or 9 for a uv transform),
//                                             translate, rotate (angle in degrees about x, y, z), scale
//                                             (uniform or per axis) and lookat (the camera looks along +z)
//   version below 2 (Mitsuba 0.6)             camelCase property names take their Mitsuba 3 names
//                                             (MitsubaImporter.legacyNames), <lookAt> is <lookat>, a texture's
//                                             uscale and vscale become a to_uv scale, and the <srgb> values of
//                                             the diffuse plugin are linearized into <rgb>
//   #rrggbb, #rgb                             an sRGB hex colour in <rgb> or <srgb> (SRGB1999 transfer
//                                             function), read as linear RGB
//   lookat without a usable up                an up vector parallel to the view direction, or none, is
//                                             replaced by the world axis least aligned with it (y when tied)
// A missing version counts as Mitsuba 3.
enum MitsubaImporter {
  // Reads only up to the first element, so a large file is not parsed whole.
  static func isMitsuba(_ url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "xml", let parser = XMLParser(contentsOf: url) else { return false }
    let finder = RootFinder()
    parser.delegate = finder
    parser.shouldResolveExternalEntities = false
    parser.parse()
    return finder.root == "scene"
  }

  private final class RootFinder: NSObject, XMLParserDelegate {
    var root: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
      root = elementName
      parser.abortParsing()
    }
  }

  static func error(_ message: String) -> Error { MaterialLibrary.error("Mitsuba: " + message) }

  // Mitsuba 0.6 property and element names and their Mitsuba 3 names. Other camelCase names stay as they are.
  static let legacyNames: [String: String] = [
    "toWorld": "to_world", "toUV": "to_uv", "intIOR": "int_ior", "extIOR": "ext_ior", "maxDepth": "max_depth",
    "sampleCount": "sample_count", "faceNormals": "face_normals", "fovAxis": "fov_axis",
    "diffuseReflectance": "diffuse_reflectance", "specularReflectance": "specular_reflectance",
    "specularTransmittance": "specular_transmittance", "sigmaT": "sigma_t", "sigmaA": "sigma_a", "sigmaS": "sigma_s",
    "focusDistance": "focus_distance", "lookAt": "lookat",
  ]

  // One resolved XML element: its attributes after $ substitution and the 0.6 rename, and its children with
  // every <ref> replaced by its target.
  struct Node {
    let tag: String
    let type: String?
    let name: String?
    let id: String?
    let attributes: [String: String]
    let children: [Node]
    // The folder of the file this element was read from (an included file's own folder), for relative paths.
    let folder: URL

    // The child with this name attribute, or else an unnamed child with this tag (a shape's BSDF is
    // `child("bsdf")`, whether nested or referenced).
    func child(_ name: String) -> Node? {
      children.first { $0.name == name } ?? children.first { $0.name == nil && $0.tag == name }
    }
    func float(_ name: String) -> Float? {
      guard let node = child(name), node.tag == "float" || node.tag == "integer" else { return nil }
      return node.attributes["value"].flatMap { MitsubaImporter.number($0) }
    }
    func string(_ name: String) -> String? {
      guard let node = child(name), node.tag == "string" else { return nil }
      return node.attributes["value"]
    }
    // A string property as a file URL: relative paths start at the folder of the file that holds this element.
    func url(_ name: String) -> URL? {
      string(name).map { URL(fileURLWithPath: $0, relativeTo: folder).standardizedFileURL }
    }
    func bool(_ name: String) -> Bool? {
      guard let node = child(name), node.tag == "boolean" else { return nil }
      switch node.attributes["value"]?.trimmingCharacters(in: .whitespaces).lowercased() {
      case "true": return true
      case "false": return false
      default: return nil
      }
    }
    // An <rgb> or <spectrum> of one value (grey) or three, or a <float> (grey). Wavelength-sampled spectra are nil.
    func rgb(_ name: String) -> SIMD3<Float>? {
      guard let node = child(name), let text = node.attributes["value"] else { return nil }
      switch node.tag {
      case "rgb", "spectrum":
        if let linear = MitsubaImporter.hexColor(text) { return SIMD3(linear[0], linear[1], linear[2]) }
        guard let values = MitsubaImporter.numbers(text) else { return nil }
        if values.count == 1 { return SIMD3(repeating: values[0]) }
        return values.count == 3 ? SIMD3(values[0], values[1], values[2]) : nil
      case "float":
        return MitsubaImporter.number(text).map { SIMD3(repeating: $0) }
      default:
        return nil
      }
    }
    func transform(_ name: String) -> simd_float4x4 {
      guard let node = child(name), node.tag == "transform" else { return matrix_identity_float4x4 }
      return node.children.reduce(matrix_identity_float4x4) { $1.operation * $0 }
    }

    // This <transform> child as a matrix; unknown elements are the identity.
    fileprivate var operation: simd_float4x4 {
      func vector(_ key: String, _ fallback: Float) -> SIMD3<Float>? {
        if let text = attributes[key] {
          guard let values = MitsubaImporter.numbers(text) else { return nil }
          if values.count == 1 { return SIMD3(repeating: values[0]) }
          return values.count == 3 ? SIMD3(values[0], values[1], values[2]) : nil
        }
        return SIMD3(repeating: fallback)
      }
      func axes(_ fallback: Float) -> SIMD3<Float> {
        if let v = attributes["value"].flatMap({ MitsubaImporter.numbers($0) }), v.count == 3 { return SIMD3(v[0], v[1], v[2]) }
        return SIMD3(attributes["x"].flatMap { MitsubaImporter.number($0) } ?? fallback,
                     attributes["y"].flatMap { MitsubaImporter.number($0) } ?? fallback,
                     attributes["z"].flatMap { MitsubaImporter.number($0) } ?? fallback)
      }
      switch tag {
      case "matrix":
        guard let v = attributes["value"].flatMap({ MitsubaImporter.numbers($0) }) else { return matrix_identity_float4x4 }
        if v.count == 16 {
          return simd_float4x4(rows: (0..<4).map { SIMD4(v[4 * $0], v[4 * $0 + 1], v[4 * $0 + 2], v[4 * $0 + 3]) })
        }
        if v.count == 9 {
          // A uv transform acts on (u, v, 1): its third row and column are the homogeneous ones.
          var m = matrix_identity_float4x4
          let index = [0, 1, 3]
          for r in 0..<3 { for c in 0..<3 { m[index[c]][index[r]] = v[3 * r + c] } }
          return m
        }
        return matrix_identity_float4x4
      case "translate":
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(axes(0), 1)
        return m
      case "scale":
        let s = attributes["value"] != nil ? (vector("value", 1) ?? SIMD3(repeating: 1)) : axes(1)
        return simd_float4x4(diagonal: SIMD4(s, 1))
      case "rotate":
        let axis = attributes["value"] != nil ? (vector("value", 0) ?? .zero) : axes(0)
        let angle = (attributes["angle"].flatMap { MitsubaImporter.number($0) } ?? 0) * .pi / 180
        guard simd_length(axis) > 0 else { return matrix_identity_float4x4 }
        return simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(axis)))
      case "lookat":
        guard let origin = vector("origin", 0), let target = vector("target", 0), let given = vector("up", 0) else { return matrix_identity_float4x4 }
        let direction = simd_normalize(target - origin)
        var up = given
        if simd_length(simd_cross(up, direction)) < 1e-6 * max(simd_length(up), 1) {
          // No usable up: take the world axis least aligned with the direction (y when tied).
          let a = simd_abs(direction)
          up = a.y <= a.x && a.y <= a.z ? SIMD3(0, 1, 0) : (a.x <= a.z ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1))
        }
        let left = simd_normalize(simd_cross(up, direction))
        let newUp = simd_cross(direction, left)
        return simd_float4x4(columns: (SIMD4(left, 0), SIMD4(newUp, 0), SIMD4(direction, 0), SIMD4(origin, 1)))
      default:
        return matrix_identity_float4x4
      }
    }
  }

  // The parsed file: its resolved root <scene> node, the folder that relative paths start from, the Mitsuba
  // major version and the import report.
  struct Scene {
    let root: Node
    let folder: URL
    let version: Int
    var report: [String] = []

    init(url: URL) throws {
      var loader = Loader()
      let document = try Loader.document(url)
      guard let element = document.rootElement(), element.name == "scene" else {
        throw MitsubaImporter.error("\(url.lastPathComponent) is not a Mitsuba scene (its root element is not <scene>)")
      }
      folder = url.deletingLastPathComponent()
      version = element.attribute(forName: "version")?.stringValue.flatMap { $0.split(separator: ".").first }.flatMap { Int($0) } ?? 3
      loader.legacy = version < 2
      loader.includeStack = [url.standardizedFileURL]
      let raw = try loader.node(element, folder: folder)[0]
      root = try loader.resolved(raw)
    }

    mutating func note(_ line: String) {
      if !report.contains(line) { report.append(line) }
    }
  }

  // A number with surrounding whitespace allowed.
  fileprivate static func number(_ text: String) -> Float? {
    Float(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  // A list separated by commas, whitespace or both.
  fileprivate static func numbers(_ text: String) -> [Float]? {
    let parts = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
    let values = parts.compactMap { Float($0) }
    return values.count == parts.count && !values.isEmpty ? values : nil
  }

  // "#rrggbb" or "#rgb" as gamma-encoded components in 0...1; nil for anything else.
  fileprivate static func hexComponents(_ text: String) -> [Float]? {
    let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard digits.hasPrefix("#"), digits.count == 4 || digits.count == 7, let hex = Int(digits.dropFirst(), radix: 16) else { return nil }
    if digits.count == 4 { return [Float((hex >> 8) & 15) / 15, Float((hex >> 4) & 15) / 15, Float(hex & 15) / 15] }
    return [Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255]
  }

  // The sRGB electro-optical transfer function (SRGB1999) per component.
  fileprivate static func linearized(_ encoded: [Float]) -> [Float] {
    encoded.map { $0 <= 0.04045 ? $0 / 12.92 : powf(($0 + 0.055) / 1.055, 2.4) }
  }

  // A hex colour decoded from sRGB to linear RGB.
  fileprivate static func hexColor(_ text: String) -> [Float]? { hexComponents(text).map(linearized) }

  // The tree in one pass: variables, includes and renames applied in document order, with every element that
  // carries an id recorded, then a second pass replaces <ref> nodes (an id may be defined after its use).
  fileprivate struct Loader {
    var legacy = false
    var variables: [String: String] = [:]
    var includeStack: [URL] = []
    var definitions: [String: Node] = [:]
    var resolvedDefinitions: [String: Node] = [:]
    var resolving: Set<String> = []

    static func document(_ url: URL) throws -> XMLDocument {
      do { return try XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]) } catch {
        throw MitsubaImporter.error("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
      }
    }

    func substitute(_ text: String) throws -> String {
      guard text.contains("$") else { return text }
      var result = ""
      var rest = Substring(text)
      while let dollar = rest.firstIndex(of: "$") {
        result += rest[..<dollar]
        let after = rest[rest.index(after: dollar)...]
        let name = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty, let value = variables[String(name)] else {
          throw MitsubaImporter.error("undefined variable '$\(name)'")
        }
        result += value
        rest = after.dropFirst(name.count)
      }
      return result + rest
    }

    // The nodes one element stands for: none for <default>, the included file's children for <include>,
    // otherwise the element itself.
    mutating func node(_ element: XMLElement, folder: URL) throws -> [Node] {
      var tag = element.name ?? ""
      var attributes: [String: String] = [:]
      for attribute in element.attributes ?? [] {
        if let name = attribute.name { attributes[name] = try substitute(attribute.stringValue ?? "") }
      }
      switch tag {
      case "default":
        guard let name = attributes["name"], let value = attributes["value"] else {
          throw MitsubaImporter.error("<default> needs a name and a value")
        }
        if variables[name] == nil { variables[name] = value }
        return []
      case "include":
        guard let filename = attributes["filename"] else { throw MitsubaImporter.error("<include> needs a filename") }
        let url = URL(fileURLWithPath: filename, relativeTo: folder).standardizedFileURL
        guard !includeStack.contains(url) else { throw MitsubaImporter.error("include cycle at '\(filename)'") }
        includeStack.append(url)
        defer { includeStack.removeLast() }
        guard let included = try Loader.document(url).rootElement(), included.name == "scene" else {
          throw MitsubaImporter.error("included file \(url.lastPathComponent) is not a Mitsuba scene")
        }
        return try nodes(included.children, folder: url.deletingLastPathComponent())
      default:
        break
      }
      var children = try nodes(element.children, folder: folder)
      if legacy {
        if let renamed = attributes["name"].flatMap({ MitsubaImporter.legacyNames[$0] }) { attributes["name"] = renamed }
        if tag == "lookAt" { tag = "lookat" }
        if tag == "texture" { children = Self.uvScale(children, folder: folder) }
        if tag == "bsdf", attributes["type"] == "diffuse" { children = children.map(Self.linearized) }
      }
      if tag == "lookat", let origin = attributes["origin"].flatMap({ MitsubaImporter.numbers($0) }),
         origin == attributes["target"].flatMap({ MitsubaImporter.numbers($0) }) {
        throw MitsubaImporter.error("lookat needs distinct origin and target")
      }
      let node = Node(tag: tag, type: attributes["type"], name: attributes["name"], id: attributes["id"],
                      attributes: attributes, children: children, folder: folder)
      if let id = node.id, tag != "ref" {
        guard definitions[id] == nil else { throw MitsubaImporter.error("duplicate id '\(id)'") }
        definitions[id] = node
      }
      return [node]
    }

    mutating func nodes(_ list: [XMLNode]?, folder: URL) throws -> [Node] {
      var result: [Node] = []
      for case let child as XMLElement in list ?? [] { result += try node(child, folder: folder) }
      return result
    }

    // Mitsuba 0.6's uscale and vscale on a texture are a scale of its uv transform.
    static func uvScale(_ children: [Node], folder: URL) -> [Node] {
      func scale(_ name: String) -> Float? {
        children.first { $0.name == name && $0.tag == "float" }?.attributes["value"].flatMap { MitsubaImporter.number($0) }
      }
      let u = scale("uscale"), v = scale("vscale")
      guard u != nil || v != nil else { return children }
      let step = Node(tag: "scale", type: nil, name: nil, id: nil,
                      attributes: ["x": "\(u ?? 1)", "y": "\(v ?? 1)", "z": "1"], children: [], folder: folder)
      var rest = children.filter { $0.name != "uscale" && $0.name != "vscale" }
      if let index = rest.firstIndex(where: { $0.tag == "transform" && $0.name == "to_uv" }) {
        let existing = rest[index]
        rest[index] = Node(tag: existing.tag, type: existing.type, name: existing.name, id: existing.id,
                           attributes: existing.attributes, children: existing.children + [step], folder: existing.folder)
      } else {
        rest.append(Node(tag: "transform", type: nil, name: "to_uv", id: nil, attributes: ["name": "to_uv"], children: [step], folder: folder))
      }
      return rest
    }

    // Mitsuba 0.6's <srgb> is gamma encoded ("#rrggbb", "#rgb" or floats); the result is a linear <rgb>.
    static func linearized(_ node: Node) -> Node {
      guard node.tag == "srgb", let text = node.attributes["value"],
            let encoded = MitsubaImporter.hexComponents(text) ?? MitsubaImporter.numbers(text) else { return node }
      var attributes = node.attributes
      attributes["value"] = MitsubaImporter.linearized(encoded).map { "\($0)" }.joined(separator: ", ")
      return Node(tag: "rgb", type: node.type, name: node.name, id: node.id, attributes: attributes,
                  children: node.children, folder: node.folder)
    }

    // The node with every <ref> below it replaced by the resolved node it names.
    mutating func resolved(_ node: Node) throws -> Node {
      if node.tag == "ref" {
        guard let id = node.attributes["id"], definitions[id] != nil else {
          throw MitsubaImporter.error("undefined reference '\(node.attributes["id"] ?? "")'")
        }
        let target = try resolvedDefinition(id)
        var attributes = target.attributes
        attributes["name"] = node.name
        return Node(tag: target.tag, type: target.type, name: node.name, id: target.id, attributes: attributes, children: target.children, folder: target.folder)
      }
      var children: [Node] = []
      for child in node.children { children.append(try resolved(child)) }
      return Node(tag: node.tag, type: node.type, name: node.name, id: node.id, attributes: node.attributes, children: children, folder: node.folder)
    }

    mutating func resolvedDefinition(_ id: String) throws -> Node {
      if let done = resolvedDefinitions[id] { return done }
      guard resolving.insert(id).inserted else { throw MitsubaImporter.error("reference cycle through '\(id)'") }
      defer { resolving.remove(id) }
      let done = try resolved(definitions[id]!)
      resolvedDefinitions[id] = done
      return done
    }
  }
}

// Shapes as world-space triangles. REFERENCES.md: MITSUBA3 (the shape plugins and Mesh::recompute_vertex_normals,
// v3.9.1), OBJ2026, PLY1994, OPENEXRLAYOUT (zlib streams).
//   obj          v, vt, vn and f statements (negative indices count back from the last element read; polygons
//                fan-triangulate); every other statement is ignored and the whole file is one mesh. Corners with
//                the same (position, uv, normal) index triple share a vertex, and vertices no face uses are dropped,
//                as in Mitsuba. Texture coordinates are flipped (1 - v) unless flip_tex_coords is false.
//   ply          ascii and binary_little_endian; vertex x y z, optional nx ny nz and u v (or texture_u texture_v,
//                or s t); face lists named vertex_indices or vertex_index, fan-triangulated. Texture coordinates
//                are kept unless flip_tex_coords is true.
//   serialized   format 0x041C, version 3 or 4; shape_index picks the sub-mesh through the offset table at the
//                end of the file; positions, normals and texture coordinates in single or double precision.
//                Texture coordinates are kept.
//   normals      face_normals true gives none (the renderer uses face normals); a file or sub-mesh without
//                normals gets Mitsuba's angle-weighted vertex normals; otherwise the file's normals, transformed
//                by the inverse transpose of to_world's 3 x 3 and renormalized.
//   texture      This project's v runs from the top of the image, as Mitsuba's does after its own OBJ flip, so
//   coordinates  the other formats' coordinates and the analytic shapes' (Mitsuba's, and the converter's) are kept.
//   rectangle    (-1, -1, 0) to (1, 1, 0), normal +z, uv 0 to 1.
//   disk         radius 1, 64 triangles around the centre, normal +z, uv = 0.5 + 0.5 (x, y) (the converter's
//                planar mapping; Mitsuba's own is polar).
//   cube         -1 to 1 in 24 vertices (Mitsuba's order, one uv square per face), 12 triangles, no normals.
//   sphere       center and radius (0 and 1) applied before to_world; 64 segments by 32 rings from the +z pole,
//                smooth normals, uv (angle about z / 2 pi, angle from +z / pi).
//   A to_world with a negative determinant reverses the winding of the analytic shapes, whose front side is the
//   analytic normal's; file meshes keep their winding, as Mitsuba does.
extension MitsubaImporter {
  struct Mesh {
    var positions: [SIMD3<Float>]
    // nil: the renderer uses face normals.
    var normals: [SIMD3<Float>]?
    // v already flipped to this project's convention.
    var uvs: [SIMD2<Float>]?
    var triangles: [SIMD3<UInt32>]
  }

  // A mesh file that cannot be read, with the file's name; `mesh` adds the shape's.
  fileprivate struct ReadError: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  // The shape as one world-space mesh; nil, with a report line, for a shape type that is not read. An error for
  // a mesh file names the shape (its id, else its type) and the file.
  static func mesh(_ shape: Node, scene: inout Scene) throws -> Mesh? {
    let type = shape.type ?? "(no type)"
    let toWorld = shape.transform("to_world")
    let linear = simd_float3x3(columns: (toWorld.columns.0.xyz, toWorld.columns.1.xyz, toWorld.columns.2.xyz))
    let determinant = simd_determinant(linear)
    guard determinant.isFinite, determinant != 0 else {
      scene.note("shape \(type) has a singular to_world; skipped")
      return nil
    }
    switch type {
    case "obj", "ply", "serialized":
      let faceNormals = shape.bool("face_normals") ?? false
      let local: Mesh
      do {
        guard let url = shape.url("filename") else { throw ReadError("the shape has no filename") }
        let name = url.lastPathComponent
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch {
          throw ReadError("cannot read \(name): \(error.localizedDescription)")
        }
        // shape_index: a non-negative whole number, below Int32.max.
        var index = 0
        if type == "serialized", let value = shape.float("shape_index") {
          guard value.isFinite, value >= 0, value < 2_147_483_648, value == value.rounded() else {
            throw ReadError("shape_index must be a non-negative integer")
          }
          index = Int(value)
        }
        local = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
          switch type {
          case "obj":
            return try readOBJ(raw.bindMemory(to: UInt8.self), name: name, normals: !faceNormals, flipV: shape.bool("flip_tex_coords") ?? true)
          case "ply":
            return try readPLY(raw, name: name, normals: !faceNormals, flipV: shape.bool("flip_tex_coords") ?? false)
          default:
            return try readSerialized(raw, name: name, normals: !faceNormals, index: index)
          }
        }
      } catch let failure as ReadError {
        throw error("shape '\(shape.id ?? type)': \(failure.message)")
      }
      return world(local, toWorld, smoothNormals: !faceNormals)
    case "rectangle", "disk", "cube", "sphere":
      var mesh = world(unitShape(type, shape), toWorld, smoothNormals: false)
      if determinant < 0 { mesh.triangles = mesh.triangles.map { SIMD3($0.x, $0.z, $0.y) } }
      return mesh
    default:
      scene.note("shape \(type) is not supported; skipped")
      return nil
    }
  }

  // MARK: Placement and normals

  // The mesh in world space. A mesh without usable normals gets smooth ones when asked; one with them has them
  // transformed by the inverse transpose of the matrix's 3 x 3 and renormalized.
  fileprivate static func world(_ local: Mesh, _ matrix: simd_float4x4, smoothNormals: Bool) -> Mesh {
    var mesh = local
    mesh.positions = local.positions.map { (matrix * SIMD4($0, 1)).xyz }
    mesh.normals = nil
    if let normals = local.normals {
      let linear = simd_float3x3(columns: (matrix.columns.0.xyz, matrix.columns.1.xyz, matrix.columns.2.xyz))
      let normalMatrix = linear.inverse.transpose
      let transformed = normals.map { n -> SIMD3<Float> in
        let t = normalMatrix * n
        return t / simd_length(t)
      }
      // One zero or non-finite normal (a zero vn, a near-singular to_world) drops them all, and smooth normals
      // are computed instead.
      if transformed.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) { mesh.normals = transformed }
    }
    if mesh.normals == nil, smoothNormals {
      mesh.normals = vertexNormals(mesh.positions, mesh.triangles)
    }
    return mesh
  }

  // Mitsuba's Mesh::recompute_vertex_normals: each triangle's unit normal weighted by its angle at the vertex.
  // A vertex without a usable normal gets (1, 0, 0).
  fileprivate static func vertexNormals(_ positions: [SIMD3<Float>], _ triangles: [SIMD3<UInt32>]) -> [SIMD3<Float>] {
    func angle(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Float {
      simd_dot(u, v) < 0 ? .pi - 2 * asin(min(1, simd_length(v + u) / 2)) : 2 * asin(min(1, simd_length(v - u) / 2))
    }
    var sums = [SIMD3<Float>](repeating: .zero, count: positions.count)
    for t in triangles {
      let a = positions[Int(t.x)], b = positions[Int(t.y)], c = positions[Int(t.z)]
      let n = simd_cross(b - a, c - a)
      let lengthSquared = simd_length_squared(n)
      guard lengthSquared > 0 else { continue }
      let unit = n / lengthSquared.squareRoot()
      let ab = simd_normalize(b - a), ac = simd_normalize(c - a), bc = simd_normalize(c - b)
      sums[Int(t.x)] += unit * angle(ab, ac)
      sums[Int(t.y)] += unit * angle(bc, -ab)
      sums[Int(t.z)] += unit * angle(-ac, -bc)
    }
    return sums.map { sum in
      let length = simd_length(sum)
      return length != 0 ? sum / length : SIMD3(1, 0, 0)
    }
  }

  // MARK: Analytic shapes

  // Mitsuba's cube plugin's 24 vertices (outward counter-clockwise quads, four per face) and each quad's
  // corner uvs; faces (0 1 2) (3 0 2) of every quad.
  fileprivate static let cubePositions: [SIMD3<Float>] = [
    [1, -1, -1], [1, -1, 1], [-1, -1, 1], [-1, -1, -1],
    [1, 1, -1], [-1, 1, -1], [-1, 1, 1], [1, 1, 1],
    [1, -1, -1], [1, 1, -1], [1, 1, 1], [1, -1, 1],
    [1, -1, 1], [1, 1, 1], [-1, 1, 1], [-1, -1, 1],
    [-1, -1, 1], [-1, 1, 1], [-1, 1, -1], [-1, -1, -1],
    [1, 1, -1], [1, -1, -1], [-1, -1, -1], [-1, 1, -1],
  ]

  // The unit shape in its own space (the shape's center and radius applied to a sphere), before to_world.
  fileprivate static func unitShape(_ type: String, _ shape: Node) -> Mesh {
    switch type {
    case "rectangle":
      return Mesh(positions: [[-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0]], normals: Array(repeating: [0, 0, 1], count: 4),
                  uvs: [[0, 0], [1, 0], [1, 1], [0, 1]], triangles: [[0, 1, 2], [0, 2, 3]])
    case "disk":
      let segments = 64
      var positions: [SIMD3<Float>] = [[0, 0, 0]], uvs: [SIMD2<Float>] = [[0.5, 0.5]]
      for i in 0..<segments {
        let angle = 2 * Float.pi * Float(i) / Float(segments)
        positions.append([cos(angle), sin(angle), 0])
        uvs.append([0.5 + 0.5 * cos(angle), 0.5 + 0.5 * sin(angle)])
      }
      return Mesh(positions: positions, normals: Array(repeating: [0, 0, 1], count: segments + 1), uvs: uvs,
                  triangles: (0..<segments).map { [0, UInt32(1 + $0), UInt32(1 + ($0 + 1) % segments)] })
    case "cube":
      let corners: [SIMD2<Float>] = [[0, 1], [1, 1], [1, 0], [0, 0]]
      return Mesh(positions: cubePositions, normals: nil, uvs: (0..<24).map { corners[$0 % 4] },
                  triangles: (0..<6).flatMap { f -> [SIMD3<UInt32>] in
                    let b = UInt32(4 * f)
                    return [[b, b + 1, b + 2], [b + 3, b, b + 2]]
                  })
    default:
      let segments = 64, rings = 32
      var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
      for i in 0...rings {
        let theta = Float.pi * Float(i) / Float(rings)
        for j in 0...segments {
          let phi = 2 * Float.pi * Float(j) / Float(segments)
          positions.append([sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)])
          uvs.append([Float(j) / Float(segments), Float(i) / Float(rings)])
        }
      }
      var triangles: [SIMD3<UInt32>] = []
      for i in 0..<rings {
        for j in 0..<segments {
          // The quad a b c d is two triangles; at a pole two of its corners coincide and one triangle is dropped.
          let a = UInt32(i * (segments + 1) + j), d = a + 1
          let b = a + UInt32(segments + 1), c = b + 1
          if i > 0 { triangles.append([a, c, d]) }
          if i < rings - 1 { triangles.append([a, b, c]) }
        }
      }
      let center = point(shape.child("center")) ?? .zero, radius = shape.float("radius") ?? 1
      return Mesh(positions: positions.map { center + radius * $0 }, normals: positions, uvs: uvs, triangles: triangles)
    }
  }

  // A <point> or <vector> as three numbers (value="x, y, z" or x, y and z attributes, missing ones 0).
  fileprivate static func point(_ node: Node?) -> SIMD3<Float>? {
    guard let node, node.tag == "point" || node.tag == "vector" else { return nil }
    if let value = node.attributes["value"] {
      guard let v = numbers(value), v.count == 3 else { return nil }
      return SIMD3(v[0], v[1], v[2])
    }
    func axis(_ name: String) -> Float { node.attributes[name].flatMap { number($0) } ?? 0 }
    return SIMD3(axis("x"), axis("y"), axis("z"))
  }

  // MARK: Number scanning

  fileprivate static let powersOfTen: [Double] = {
    var powers = [1.0]
    for _ in 1...22 { powers.append(powers[powers.count - 1] * 10) }
    return powers
  }()

  @inline(__always) fileprivate static func isBlank(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }

  // The decimal number at p[i], advancing i past it; nil when none starts there. A value of at most 15
  // significant digits and a decimal exponent within +-22 is one correctly rounded division or product; others
  // go through Float(String).
  fileprivate static func scanFloat(_ p: UnsafeBufferPointer<UInt8>, _ i: inout Int, _ end: Int) -> Float? {
    var j = i
    var negative = false
    if j < end, p[j] == 0x2D || p[j] == 0x2B { negative = p[j] == 0x2D; j += 1 }
    var mantissa: UInt64 = 0, significant = 0, exponent = 0, digits = 0
    while j < end, p[j] &- 0x30 < 10 {
      if significant < 19 {
        mantissa = mantissa * 10 + UInt64(p[j] &- 0x30)
        if mantissa != 0 { significant += 1 }
      } else {
        exponent += 1
      }
      digits += 1
      j += 1
    }
    if j < end, p[j] == 0x2E {
      j += 1
      while j < end, p[j] &- 0x30 < 10 {
        if significant < 19 {
          mantissa = mantissa * 10 + UInt64(p[j] &- 0x30)
          if mantissa != 0 { significant += 1 }
          exponent -= 1
        }
        digits += 1
        j += 1
      }
    }
    guard digits > 0 else { return nil }
    if j < end, p[j] | 0x20 == 0x65 {
      var k = j + 1, exponentNegative = false, value = 0, exponentDigits = 0
      if k < end, p[k] == 0x2D || p[k] == 0x2B { exponentNegative = p[k] == 0x2D; k += 1 }
      while k < end, p[k] &- 0x30 < 10 {
        if value < 10000 { value = value * 10 + Int(p[k] &- 0x30) }
        exponentDigits += 1
        k += 1
      }
      if exponentDigits > 0 {
        exponent += exponentNegative ? -value : value
        j = k
      }
    }
    let start = i
    i = j
    if mantissa == 0 { return negative ? -0.0 : 0 }
    if significant <= 15, exponent >= -22, exponent <= 22 {
      let m = Double(mantissa)
      let value = exponent < 0 ? m / powersOfTen[-exponent] : m * powersOfTen[exponent]
      return Float(negative ? -value : value)
    }
    return Float(String(decoding: UnsafeBufferPointer(rebasing: p[start..<j]), as: UTF8.self))
  }

  // The optionally signed integer at p[i], advancing i past it; nil when none starts there.
  fileprivate static func scanInt(_ p: UnsafeBufferPointer<UInt8>, _ i: inout Int, _ end: Int) -> Int? {
    var j = i
    var negative = false
    if j < end, p[j] == 0x2D || p[j] == 0x2B { negative = p[j] == 0x2D; j += 1 }
    var value = 0, digits = 0
    while j < end, p[j] &- 0x30 < 10 {
      guard value < (Int.max - 9) / 10 else { return nil }
      value = value * 10 + Int(p[j] &- 0x30)
      digits += 1
      j += 1
    }
    guard digits > 0 else { return nil }
    i = j
    return negative ? -value : value
  }

  // MARK: OBJ

  fileprivate static func readOBJ(_ p: UnsafeBufferPointer<UInt8>, name: String, normals wantNormals: Bool, flipV: Bool) throws -> Mesh {
    var fileVertices: [SIMD3<Float>] = [], fileNormals: [SIMD3<Float>] = [], fileUVs: [SIMD2<Float>] = []
    var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
    var triangles: [SIMD3<UInt32>] = []
    var welded: [SIMD3<UInt32>: UInt32] = [:]
    var corners: [UInt32] = []
    var missingNormal = false
    let size = p.count
    var line = 0, cursor = 0
    while cursor < size {
      line += 1
      var end = size
      if let base = p.baseAddress, let hit = memchr(base + cursor, 0x0A, size - cursor) {
        end = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
      }
      defer { cursor = end + 1 }
      var i = cursor
      func failure(_ what: String) -> Error { ReadError("\(name): line \(line): \(what)") }
      func number() throws -> Float {
        while i < end, isBlank(p[i]) { i += 1 }
        // A number ends at a blank, a comment or the end of the line.
        guard let value = scanFloat(p, &i, end), value.isFinite, i >= end || isBlank(p[i]) || p[i] == 0x23 else {
          throw failure("cannot read a number")
        }
        return value
      }
      // A 1-based element index (0 for none) for an index that counts from the start or, when negative, back
      // from the end of the `count` elements read so far.
      func resolve(_ value: Int, _ count: Int, _ what: String) throws -> UInt32 {
        let k = value > 0 ? value - 1 : count + value
        guard value != 0, k >= 0, k < count else { throw failure("invalid \(what) index \(value)") }
        return UInt32(k + 1)
      }
      while i < end, isBlank(p[i]) { i += 1 }
      guard i + 1 < end else { continue }
      let c0 = p[i], c1 = p[i + 1]
      if c0 == 0x76 /* v */ {
        if isBlank(c1) {
          i += 2
          let v = SIMD3(try number(), try number(), try number())
          fileVertices.append(v)
        } else if c1 == 0x6E /* n */, i + 2 < end, isBlank(p[i + 2]) {
          guard wantNormals else { continue }
          i += 3
          fileNormals.append(SIMD3(try number(), try number(), try number()))
        } else if c1 == 0x74 /* t */, i + 2 < end, isBlank(p[i + 2]) {
          i += 3
          let u = try number(), v = try number()
          fileUVs.append(SIMD2(u, flipV ? 1 - v : v))
        }
      } else if c0 == 0x66 /* f */, isBlank(c1) {
        i += 2
        corners.removeAll(keepingCapacity: true)
        while true {
          while i < end, isBlank(p[i]) { i += 1 }
          if i >= end || p[i] == 0x23 { break }
          guard let v = scanInt(p, &i, end) else { throw failure("cannot read a face") }
          var vt: Int?, vn: Int?
          if i < end, p[i] == 0x2F {
            i += 1
            vt = scanInt(p, &i, end)
            if i < end, p[i] == 0x2F {
              i += 1
              guard let n = scanInt(p, &i, end) else { throw failure("cannot read a face") }
              vn = n
            }
          }
          guard i >= end || isBlank(p[i]) || p[i] == 0x23 else { throw failure("cannot read a face") }
          let key = SIMD3(try resolve(v, fileVertices.count, "vertex"),
                          try vt.map { try resolve($0, fileUVs.count, "texture coordinate") } ?? 0,
                          wantNormals ? try vn.map { try resolve($0, fileNormals.count, "normal") } ?? 0 : 0)
          if let id = welded[key] {
            corners.append(id)
          } else {
            guard positions.count < Int(UInt32.max) else { throw failure("too many vertices") }
            let id = UInt32(positions.count)
            welded[key] = id
            positions.append(fileVertices[Int(key.x) - 1])
            uvs.append(key.y != 0 ? fileUVs[Int(key.y) - 1] : .zero)
            if key.z != 0 { normals.append(fileNormals[Int(key.z) - 1]) } else { normals.append(.zero); missingNormal = true }
            corners.append(id)
          }
        }
        if corners.count >= 3 {
          for k in 1..<(corners.count - 1) { triangles.append([corners[0], corners[k], corners[k + 1]]) }
        }
      }
    }
    guard !triangles.isEmpty else { throw ReadError("\(name) contains no triangles") }
    return Mesh(positions: positions, normals: wantNormals && !fileNormals.isEmpty && !missingNormal ? normals : nil,
                uvs: fileUVs.isEmpty ? nil : uvs, triangles: triangles)
  }

  // MARK: PLY

  fileprivate enum PLYType {
    case int8, uint8, int16, uint16, int32, uint32, float32, float64
    init?(_ name: String) {
      switch name {
      case "char", "int8": self = .int8
      case "uchar", "uint8": self = .uint8
      case "short", "int16": self = .int16
      case "ushort", "uint16": self = .uint16
      case "int", "int32": self = .int32
      case "uint", "uint32": self = .uint32
      case "float", "float32": self = .float32
      case "double", "float64": self = .float64
      default: return nil
      }
    }
    var isFloat: Bool { self == .float32 || self == .float64 }
    var size: Int {
      switch self {
      case .int8, .uint8: return 1
      case .int16, .uint16: return 2
      case .int32, .uint32, .float32: return 4
      case .float64: return 8
      }
    }
  }

  // A scalar property, or a list property (`count` is the type of its length, `type` that of its items).
  fileprivate struct PLYProperty {
    let name: String
    let type: PLYType
    let count: PLYType?
  }

  fileprivate struct PLYElement {
    let name: String
    let count: Int
    var properties: [PLYProperty] = []
  }

  // Values of the body, as text or as little-endian binary (the host is little-endian).
  fileprivate struct PLYReader {
    let bytes: UnsafeBufferPointer<UInt8>
    let ascii: Bool
    let name: String
    var cursor: Int

    func truncated() -> Error { ReadError("\(name): the PLY data is truncated or malformed") }

    mutating func scalar(_ type: PLYType) throws -> Float {
      if ascii {
        while cursor < bytes.count, bytes[cursor] <= 0x20 { cursor += 1 }
        guard let value = MitsubaImporter.scanFloat(bytes, &cursor, bytes.count) else { throw truncated() }
        return value
      }
      guard cursor + type.size <= bytes.count else { throw truncated() }
      let raw = UnsafeRawBufferPointer(bytes)
      defer { cursor += type.size }
      switch type {
      case .int8: return Float(raw.loadUnaligned(fromByteOffset: cursor, as: Int8.self))
      case .uint8: return Float(raw.loadUnaligned(fromByteOffset: cursor, as: UInt8.self))
      case .int16: return Float(raw.loadUnaligned(fromByteOffset: cursor, as: Int16.self))
      case .uint16: return Float(raw.loadUnaligned(fromByteOffset: cursor, as: UInt16.self))
      case .int32: return Float(raw.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
      case .uint32: return Float(raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
      case .float32: return raw.loadUnaligned(fromByteOffset: cursor, as: Float.self)
      case .float64: return Float(raw.loadUnaligned(fromByteOffset: cursor, as: Double.self))
      }
    }

    mutating func integer(_ type: PLYType) throws -> Int {
      if ascii {
        while cursor < bytes.count, bytes[cursor] <= 0x20 { cursor += 1 }
        guard let value = MitsubaImporter.scanInt(bytes, &cursor, bytes.count) else { throw truncated() }
        return value
      }
      guard cursor + type.size <= bytes.count else { throw truncated() }
      let raw = UnsafeRawBufferPointer(bytes)
      defer { cursor += type.size }
      switch type {
      case .int8: return Int(raw.loadUnaligned(fromByteOffset: cursor, as: Int8.self))
      case .uint8: return Int(raw.loadUnaligned(fromByteOffset: cursor, as: UInt8.self))
      case .int16: return Int(raw.loadUnaligned(fromByteOffset: cursor, as: Int16.self))
      case .uint16: return Int(raw.loadUnaligned(fromByteOffset: cursor, as: UInt16.self))
      case .int32: return Int(raw.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
      case .uint32: return Int(raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
      case .float32, .float64: throw truncated()
      }
    }

    // Reads and discards a property.
    mutating func skip(_ property: PLYProperty) throws {
      if let count = property.count {
        for _ in 0..<max(0, try integer(count)) { _ = try scalar(property.type) }
      } else {
        _ = try scalar(property.type)
      }
    }
  }

  fileprivate static func readPLY(_ raw: UnsafeRawBufferPointer, name: String, normals wantNormals: Bool, flipV: Bool) throws -> Mesh {
    func failure(_ what: String) -> Error { ReadError("\(name): \(what)") }
    let bytes = raw.bindMemory(to: UInt8.self)
    var elements: [PLYElement] = []
    var ascii = false, cursor = 0, first = true, finished = false
    while cursor < bytes.count, !finished {
      var end = bytes.count
      if let base = bytes.baseAddress, let hit = memchr(base + cursor, 0x0A, bytes.count - cursor) {
        end = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
      }
      let words = String(decoding: UnsafeBufferPointer(rebasing: bytes[cursor..<end]), as: UTF8.self)
        .split(whereSeparator: { $0.isWhitespace }).map(String.init)
      cursor = end + 1
      if first {
        guard words == ["ply"] else { throw failure("is not a PLY file") }
        first = false
        continue
      }
      guard let keyword = words.first else { continue }
      switch keyword {
      case "format":
        switch words.dropFirst().first {
        case "ascii": ascii = true
        case "binary_little_endian": ascii = false
        case "binary_big_endian": throw failure("binary big-endian PLY is not supported")
        default: throw failure("unknown PLY format")
        }
      case "element":
        guard words.count == 3, let count = Int(words[2]), count >= 0 else { throw failure("malformed PLY element line") }
        elements.append(PLYElement(name: words[1], count: count))
      case "property":
        guard !elements.isEmpty else { throw failure("a PLY property outside an element") }
        if words.count == 5, words[1] == "list", let count = PLYType(words[2]), let item = PLYType(words[3]) {
          // List lengths and vertex indices are integers; a float one is not a valid file.
          guard !count.isFloat, !(item.isFloat && (words[4] == "vertex_indices" || words[4] == "vertex_index")) else {
            throw failure("PLY list lengths and vertex indices must have integer types")
          }
          elements[elements.count - 1].properties.append(PLYProperty(name: words[4], type: item, count: count))
        } else if words.count == 3, let type = PLYType(words[1]) {
          elements[elements.count - 1].properties.append(PLYProperty(name: words[2], type: type, count: nil))
        } else {
          throw failure("unsupported PLY property '\(words.dropFirst().joined(separator: " "))'")
        }
      case "end_header":
        finished = true
      default:
        break
      }
    }
    guard finished else { throw failure("the PLY header is truncated") }

    var reader = PLYReader(bytes: bytes, ascii: ascii, name: name, cursor: cursor)
    var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
    var triangles: [SIMD3<UInt32>] = []
    var hasNormals = false, hasUVs = false, maxIndex = -1
    for element in elements {
      guard element.count <= bytes.count else { throw reader.truncated() }
      if element.name == "vertex" {
        // Property index -> slot of (x y z nx ny nz u v).
        let names = element.properties.map(\.name)
        let uvPair = [("u", "v"), ("texture_u", "texture_v"), ("s", "t")].first { names.contains($0.0) && names.contains($0.1) }
        let slots = ["x", "y", "z", "nx", "ny", "nz", uvPair?.0 ?? "", uvPair?.1 ?? ""]
        guard names.contains("x"), names.contains("y"), names.contains("z") else { throw failure("the PLY vertices have no x, y, z") }
        hasNormals = wantNormals && names.contains("nx") && names.contains("ny") && names.contains("nz")
        hasUVs = uvPair != nil
        let roles = element.properties.map { property in property.count == nil ? slots.firstIndex(of: property.name) : nil }
        positions.reserveCapacity(element.count)
        if hasNormals { normals.reserveCapacity(element.count) }
        if hasUVs { uvs.reserveCapacity(element.count) }
        var row = [Float](repeating: 0, count: 8)
        for _ in 0..<element.count {
          for (k, property) in element.properties.enumerated() {
            if let slot = roles[k] { row[slot] = try reader.scalar(property.type) } else { try reader.skip(property) }
          }
          guard row.allSatisfy({ $0.isFinite }) else { throw failure("mesh contains invalid vertex data") }
          positions.append(SIMD3(row[0], row[1], row[2]))
          if hasNormals { normals.append(SIMD3(row[3], row[4], row[5])) }
          if hasUVs { uvs.append(SIMD2(row[6], flipV ? 1 - row[7] : row[7])) }
        }
      } else if element.name == "face" {
        guard let listIndex = element.properties.firstIndex(where: { $0.count != nil && ($0.name == "vertex_indices" || $0.name == "vertex_index") }) else {
          throw failure("the PLY faces have no vertex_indices or vertex_index list")
        }
        var corners: [UInt32] = []
        for _ in 0..<element.count {
          for (k, property) in element.properties.enumerated() {
            guard k == listIndex, let countType = property.count else { try reader.skip(property); continue }
            let n = try reader.integer(countType)
            guard n >= 0 else { throw reader.truncated() }
            corners.removeAll(keepingCapacity: true)
            for _ in 0..<n {
              let index = try reader.integer(property.type)
              guard index >= 0, index <= Int(UInt32.max) else { throw failure("the PLY face has an invalid vertex index") }
              maxIndex = max(maxIndex, index)
              corners.append(UInt32(index))
            }
            if n >= 3 { for j in 1..<(n - 1) { triangles.append([corners[0], corners[j], corners[j + 1]]) } }
          }
        }
      } else {
        for _ in 0..<element.count { for property in element.properties { try reader.skip(property) } }
      }
    }
    guard !positions.isEmpty, !triangles.isEmpty else { throw failure("contains no triangles") }
    guard maxIndex < positions.count else { throw failure("a PLY face refers to a vertex that does not exist") }
    return Mesh(positions: positions, normals: hasNormals ? normals : nil, uvs: hasUVs ? uvs : nil, triangles: triangles)
  }

  // MARK: Serialized

  // A sub-mesh's header inside its decompressed stream, and the exact size of the stream it declares.
  fileprivate struct SerializedHeader {
    let flags: Int
    let dataStart: Int
    let vertexCount: Int
    let faceCount: Int
    let size: Int
  }

  // The header at the start of the decompressed bytes `data`; nil while more bytes are needed. Counts above the
  // scene limits, and sizes that the compressed stream (`compressed` bytes) could not hold (DEFLATE expands at
  // most about 1032 to 1), are errors.
  fileprivate static func serializedHeader(_ data: UnsafeRawBufferPointer, version: Int, compressed: Int, name: String) throws -> SerializedHeader? {
    guard data.count >= 4 else { return nil }
    let flags = Int(data.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
    var cursor = 4
    if version == 4 {
      // The sub-mesh's name, null-terminated.
      guard let terminator = data[4...].firstIndex(of: 0) else {
        if data.count > 4 + 4096 { throw ReadError("\(name): the serialized sub-mesh name is too long") }
        return nil
      }
      cursor = terminator + 1
    }
    guard data.count >= cursor + 16 else { return nil }
    let vertices = data.loadUnaligned(fromByteOffset: cursor, as: UInt64.self), faces = data.loadUnaligned(fromByteOffset: cursor + 8, as: UInt64.self)
    guard faces > 0, faces <= UInt64(SceneLimits.triangles), vertices <= 3 * UInt64(SceneLimits.triangles) else {
      throw ReadError("\(name): the serialized sub-mesh declares \(vertices) vertices and \(faces) triangles, outside the importer's limits")
    }
    let vertexCount = Int(vertices), faceCount = Int(faces)
    let width = flags & 0x2000 != 0 ? 8 : 4
    let components = 3 + (flags & 0x1 != 0 ? 3 : 0) + (flags & 0x2 != 0 ? 2 : 0) + (flags & 0x8 != 0 ? 3 : 0)
    let size = cursor + 16 + width * vertexCount * components + 12 * faceCount
    guard size <= 1032 * compressed + 1024 else {
      throw ReadError("\(name): the serialized sub-mesh declares more data than its compressed size can hold")
    }
    return SerializedHeader(flags: flags, dataStart: cursor + 16, vertexCount: vertexCount, faceCount: faceCount, size: size)
  }

  // The zlib stream (RFC 1950: a two-byte header, DEFLATE data, a checksum) at the start of `input`, which may be
  // followed by other data; Compression's zlib decoder reads the raw DEFLATE data after the header. `expectedSize`
  // sees the bytes decoded so far and returns the exact size the stream must have once it can tell (nil: not
  // yet); decoding stops there, and a stream that ends before or runs past it is an error.
  fileprivate static func inflate(_ input: UnsafeRawBufferPointer, name: String,
                                  expectedSize: (UnsafeRawBufferPointer) throws -> Int?) throws -> [UInt8] {
    func failure(_ what: String = "is damaged") -> Error { ReadError("\(name): the compressed mesh data \(what)") }
    guard input.count > 2, input[0] & 0x0F == 8, (Int(input[0]) << 8 | Int(input[1])) % 31 == 0, input[1] & 0x20 == 0 else { throw failure() }
    let chunk = 1 << 20
    let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
    defer { scratch.deallocate() }
    let body = input.baseAddress!.assumingMemoryBound(to: UInt8.self) + 2
    var stream = compression_stream(dst_ptr: scratch, dst_size: 0, src_ptr: body, src_size: 0, state: nil)
    guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw failure() }
    defer { compression_stream_destroy(&stream) }
    stream.src_ptr = body
    stream.src_size = input.count - 2
    var output: [UInt8] = []
    var expected: Int?
    while true {
      // Until the header is known, small steps; then no more than one byte past the declared size.
      let room = expected.map { min(chunk, $0 - output.count + 1) } ?? 4096
      stream.dst_ptr = scratch
      stream.dst_size = room
      let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
      let produced = room - stream.dst_size
      output.append(contentsOf: UnsafeBufferPointer(start: scratch, count: produced))
      if expected == nil { expected = try output.withUnsafeBytes { try expectedSize($0) } }
      if let expected {
        if output.count > expected { throw failure("has more data than its header declares") }
        if status == COMPRESSION_STATUS_END {
          guard output.count == expected else { throw failure("ends before the data its header declares") }
          return output
        }
      } else if status == COMPRESSION_STATUS_END {
        throw failure("ends inside its header")
      }
      guard status == COMPRESSION_STATUS_OK, produced > 0 else { throw failure() }
    }
  }

  fileprivate static func readSerialized(_ raw: UnsafeRawBufferPointer, name: String, normals wantNormals: Bool, index: Int) throws -> Mesh {
    func failure(_ what: String) -> Error { ReadError("\(name): \(what)") }
    // A little-endian integer at `offset`, compared without overflow.
    func integer<T: FixedWidthInteger>(_ type: T.Type, in bytes: UnsafeRawBufferPointer, at offset: Int) throws -> Int {
      guard offset >= 0, bytes.count >= MemoryLayout<T>.size, offset <= bytes.count - MemoryLayout<T>.size else {
        throw failure("the serialized data is truncated")
      }
      return Int(truncatingIfNeeded: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
    }
    guard try integer(UInt16.self, in: raw, at: 0) == 0x041C else { throw failure("is not a Mitsuba serialized file") }
    let version = try integer(UInt16.self, in: raw, at: 2)
    guard version == 3 || version == 4 else { throw failure("serialized version \(version) is not supported (3 and 4 are)") }
    guard index >= 0 else { throw failure("the shape index must not be negative") }
    var start = 0
    if index != 0 {
      let count = try integer(UInt32.self, in: raw, at: raw.count - 4)
      guard index < count else { throw failure("shape index \(index) is out of range (the file holds \(count))") }
      start = version == 4
        ? try integer(UInt64.self, in: raw, at: raw.count - 8 * (count - index) - 4)
        : try integer(UInt32.self, in: raw, at: raw.count - 4 * (count - index + 1))
      guard start >= 0, start < raw.count - 4 else { throw failure("the serialized offset table is damaged") }
    }
    let input = UnsafeRawBufferPointer(rebasing: raw[(start + 4)...])
    var header: SerializedHeader?
    let body = try inflate(input, name: name) { prefix in
      header = try serializedHeader(prefix, version: version, compressed: input.count - 2, name: name)
      return header?.size
    }
    guard let header else { throw failure("the serialized sub-mesh has no header") }
    return try body.withUnsafeBytes { (data: UnsafeRawBufferPointer) in
      // The stream has exactly the declared size, so every read below is inside it.
      let vertexCount = header.vertexCount, faceCount = header.faceCount
      let double = header.flags & 0x2000 != 0, hasNormals = header.flags & 0x1 != 0, hasUVs = header.flags & 0x2 != 0
      let hasColors = header.flags & 0x8 != 0
      let width = double ? 8 : 4
      var cursor = header.dataStart
      func floats(_ components: Int) throws -> [Float] {
        let values = (0..<vertexCount * components).map { k -> Float in
          let offset = cursor + k * width
          return double ? Float(data.loadUnaligned(fromByteOffset: offset, as: Double.self)) : data.loadUnaligned(fromByteOffset: offset, as: Float.self)
        }
        cursor += vertexCount * components * width
        guard values.allSatisfy({ $0.isFinite }) else { throw failure("mesh contains invalid vertex data") }
        return values
      }
      let p = try floats(3), n = hasNormals ? try floats(3) : [], uv = hasUVs ? try floats(2) : []
      if hasColors { cursor += vertexCount * 3 * width }
      var triangles: [SIMD3<UInt32>] = []
      triangles.reserveCapacity(faceCount)
      for f in 0..<faceCount {
        let at = cursor + 12 * f
        let t = SIMD3(data.loadUnaligned(fromByteOffset: at, as: UInt32.self), data.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self),
                      data.loadUnaligned(fromByteOffset: at + 8, as: UInt32.self))
        guard Int(t.max()) < vertexCount else { throw failure("a serialized face refers to a vertex that does not exist") }
        triangles.append(t)
      }
      return Mesh(positions: (0..<vertexCount).map { SIMD3(p[3 * $0], p[3 * $0 + 1], p[3 * $0 + 2]) },
                  normals: hasNormals && wantNormals ? (0..<vertexCount).map { SIMD3(n[3 * $0], n[3 * $0 + 1], n[3 * $0 + 2]) } : nil,
                  uvs: hasUVs ? (0..<vertexCount).map { SIMD2(uv[2 * $0], uv[2 * $0 + 1]) } : nil, triangles: triangles)
    }
  }
}

extension SIMD4 where Scalar == Float {
  fileprivate var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
