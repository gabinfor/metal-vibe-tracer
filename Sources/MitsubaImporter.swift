import Cocoa
import simd

// REFERENCES.md: MITSUBA3, BITTERLI2016, OPENPBR, MATERIALX. Mitsuba scene files (.xml whose root element is
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
// A missing version counts as Mitsuba 3.
enum MitsubaImporter {
  static func isMitsuba(_ url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "xml", let document = try? XMLDocument(contentsOf: url, options: []) else { return false }
    return document.rootElement()?.name == "scene"
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

    // The child with this name attribute, or else an unnamed child with this tag (a shape's BSDF is
    // `child("bsdf")`, whether nested or referenced).
    func child(_ name: String) -> Node? {
      children.first { $0.name == name } ?? children.first { $0.name == nil && $0.tag == name }
    }
    func float(_ name: String) -> Float? {
      guard let node = child(name), node.tag == "float" || node.tag == "integer" else { return nil }
      return node.attributes["value"].flatMap { Float($0) }
    }
    func string(_ name: String) -> String? {
      guard let node = child(name), node.tag == "string" else { return nil }
      return node.attributes["value"]
    }
    func bool(_ name: String) -> Bool? {
      guard let node = child(name), node.tag == "boolean" else { return nil }
      switch node.attributes["value"]?.lowercased() {
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
        guard let values = MitsubaImporter.numbers(text) else { return nil }
        if values.count == 1 { return SIMD3(repeating: values[0]) }
        return values.count == 3 ? SIMD3(values[0], values[1], values[2]) : nil
      case "float":
        return Float(text).map { SIMD3(repeating: $0) }
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
        return SIMD3(attributes["x"].flatMap { Float($0) } ?? fallback, attributes["y"].flatMap { Float($0) } ?? fallback,
                     attributes["z"].flatMap { Float($0) } ?? fallback)
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
        let angle = (attributes["angle"].flatMap { Float($0) } ?? 0) * .pi / 180
        guard simd_length(axis) > 0 else { return matrix_identity_float4x4 }
        return simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(axis)))
      case "lookat":
        guard let origin = vector("origin", 0), let target = vector("target", 0), let up = vector("up", 0) else { return matrix_identity_float4x4 }
        let direction = simd_normalize(target - origin)
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

  fileprivate static func numbers(_ text: String) -> [Float]? {
    let parts = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
    let values = parts.compactMap { Float($0) }
    return values.count == parts.count && !values.isEmpty ? values : nil
  }

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
      do { return try XMLDocument(contentsOf: url, options: []) } catch {
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
        let included = try Loader.document(url).rootElement()
        return try nodes(included?.children, folder: url.deletingLastPathComponent())
      default:
        break
      }
      var children = try nodes(element.children, folder: folder)
      if legacy {
        if let renamed = attributes["name"].flatMap({ MitsubaImporter.legacyNames[$0] }) { attributes["name"] = renamed }
        if tag == "lookAt" { tag = "lookat" }
        if tag == "texture" { children = Self.uvScale(children) }
        if tag == "bsdf", attributes["type"] == "diffuse" { children = children.map(Self.linearized) }
      }
      let node = Node(tag: tag, type: attributes["type"], name: attributes["name"], id: attributes["id"],
                      attributes: attributes, children: children)
      if let id = node.id, tag != "ref", definitions[id] == nil { definitions[id] = node }
      return [node]
    }

    mutating func nodes(_ list: [XMLNode]?, folder: URL) throws -> [Node] {
      var result: [Node] = []
      for case let child as XMLElement in list ?? [] { result += try node(child, folder: folder) }
      return result
    }

    // Mitsuba 0.6's uscale and vscale on a texture are a scale of its uv transform.
    static func uvScale(_ children: [Node]) -> [Node] {
      func scale(_ name: String) -> Float? {
        children.first { $0.name == name && $0.tag == "float" }?.attributes["value"].flatMap { Float($0) }
      }
      let u = scale("uscale"), v = scale("vscale")
      guard u != nil || v != nil else { return children }
      let step = Node(tag: "scale", type: nil, name: nil, id: nil,
                      attributes: ["x": "\(u ?? 1)", "y": "\(v ?? 1)", "z": "1"], children: [])
      var rest = children.filter { $0.name != "uscale" && $0.name != "vscale" }
      if let index = rest.firstIndex(where: { $0.tag == "transform" && $0.name == "to_uv" }) {
        let existing = rest[index]
        rest[index] = Node(tag: existing.tag, type: existing.type, name: existing.name, id: existing.id,
                           attributes: existing.attributes, children: existing.children + [step])
      } else {
        rest.append(Node(tag: "transform", type: nil, name: "to_uv", id: nil, attributes: ["name": "to_uv"], children: [step]))
      }
      return rest
    }

    // Mitsuba 0.6's <srgb> is gamma encoded ("#rrggbb" or floats); the result is a linear <rgb>.
    static func linearized(_ node: Node) -> Node {
      guard node.tag == "srgb", let text = node.attributes["value"] else { return node }
      var values: [Float]?
      if text.hasPrefix("#"), text.count == 7, let hex = Int(text.dropFirst(), radix: 16) {
        values = [Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255]
      } else {
        values = MitsubaImporter.numbers(text)
      }
      guard let encoded = values else { return node }
      let linear = encoded.map { $0 <= 0.04045 ? $0 / 12.92 : powf(($0 + 0.055) / 1.055, 2.4) }
      var attributes = node.attributes
      attributes["value"] = linear.map { "\($0)" }.joined(separator: ", ")
      return Node(tag: "rgb", type: node.type, name: node.name, id: node.id, attributes: attributes, children: node.children)
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
        return Node(tag: target.tag, type: target.type, name: node.name, id: target.id, attributes: attributes, children: target.children)
      }
      var children: [Node] = []
      for child in node.children { children.append(try resolved(child)) }
      return Node(tag: node.tag, type: node.type, name: node.name, id: node.id, attributes: node.attributes, children: children)
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
