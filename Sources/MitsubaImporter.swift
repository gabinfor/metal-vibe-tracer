import Cocoa
import Compression
import simd
import Synchronization

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
//                                             a BSDF are linearized into <rgb>
//   #rrggbb, #rgb                             an sRGB hex colour in <rgb> or <srgb> (SRGB1999 transfer
//                                             function), read as linear RGB
//   lookat without a usable up                an up vector parallel to the view direction, or none, is
//                                             replaced by the world axis least aligned with it (y when tied)
// A missing version counts as Mitsuba 3.
enum MitsubaImporter {
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
    // A string property as a file URL (nil when empty): relative paths start at the folder of the file that holds this element.
    func url(_ name: String) -> URL? {
      string(name).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, relativeTo: folder).standardizedFileURL }
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
    guard digits.hasPrefix("#"), digits.count == 4 || digits.count == 7, digits.dropFirst().allSatisfy(\.isHexDigit),
          let hex = Int(digits.dropFirst(), radix: 16) else { return nil }
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
        if tag == "bsdf" { children = children.map(Self.linearized) }
      }
      if tag == "lookat" {
        // An absent origin or target is the point 0 0 0.
        func point(_ key: String) -> [Float]? {
          guard let text = attributes[key] else { return [0, 0, 0] }
          return MitsubaImporter.numbers(text)
        }
        if let origin = point("origin"), origin == point("target") { throw MitsubaImporter.error("lookat needs distinct origin and target") }
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

// The scene as a project document. REFERENCES.md: MITSUBA3, BITTERLI2016, OPENUSD (the dome's orientation). As in
// GLTFImporter, a USDImportSnapshot goes through USDImporter.document (format "Mitsuba"):
//   shape        one mesh asset and one node per shape (MitsubaImporter.mesh, world space, identity node transform),
//                named by its id, else <type><index>; one material per BSDF, area-emitter radiance and interior
//                medium (MitsubaImporter.material), shared by the shapes that reference the same BSDF id with the same
//                emission; zero-area triangles are dropped. A shape whose dielectric (wrapped or not) has an IOR
//                ratio below 1 is reversed (reversesFacing), unless it emits
//   sensor       the first perspective or thinlens sensor is the saved view "Mitsuba: camera" and the active camera.
//                Mitsuba's camera looks along +z with x to the left, so its to_world times diag(-1, 1, -1, 1) is a
//                camera looking along -z (eye: the origin, direction: to_world's z, up: its y). The vertical field
//                of view comes from fov and fov_axis (x by default; smaller and larger resolved against the film,
//                diagonal over the film's diagonal) or, without fov, focal_length (50mm by default, over a 35 mm
//                film's 43.2666 mm diagonal), and the film's width and height (768 x 576 by default), which are also
//                the render size. A thinlens's aperture_radius (at most 0.5) and focus_distance (10000 by default,
//                Mitsuba's far clip) are the lens.
//   integrator   max_depth sets the path depth, max_depth - 1 from 1 to 64; -1 (unbounded) or none gives 64. A
//                wrapper (aov, moment) gives its inner integrator's; an integrator other than path, volpath and
//                volpathmis contributes only its depth.
//   envmap       the environment: its file, scale as the intensity, and its turn about +y minus 90 degrees as the
//                rotation (Mitsuba's envmap, like USD's dome, puts +z at the image centre; the app puts +x there)
//   constant     a uniform 8 x 4 latlong Radiance HDR image of its radiance, at intensity 1
// A film crop, a principal point offset and a near_clip other than 0.01 are reported and ignored.
// Other emitters and sensors, further ones, media outside a shape's interior and unknown elements are reported and
// skipped. A scene without a supported emitter stays unlit, as Mitsuba renders it without them (no inspection sky).
extension MitsubaImporter {
  static let fileExtensions = ["xml"]

  static func load(_ url: URL, into source: ProjectDocument, progress: OperationProgress? = nil) throws -> USDImportResult {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-mitsuba-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    progress?.begin("Reading \(url.lastPathComponent)")
    var scene = try Scene(url: url)
    var shapes: [Node] = [], sensors: [Node] = [], emitters: [Node] = [], media: [Node] = []
    var integrator: Node?
    for node in scene.root.children {
      switch node.tag {
      case "shape": shapes.append(node)
      case "sensor": sensors.append(node)
      case "emitter": emitters.append(node)
      case "medium": media.append(node)
      case "integrator":
        if integrator == nil { integrator = node } else { scene.note("additional integrator \(node.type ?? "(no type)") skipped") }
      case "bsdf", "texture":
        break  // Definitions, read where a shape references them.
      default:
        scene.note("element <\(node.tag)> is not supported; ignored")
      }
    }
    let interiors = Set(shapes.compactMap { $0.child("interior")?.id })
    for medium in media where !(medium.id.map(interiors.contains) ?? false) {
      scene.note("medium \(medium.type ?? "(no type)") outside a shape's interior is not supported; ignored")
    }

    var meshes = try loadMeshes(shapes, scene: &scene, progress: progress)
    let triangles = meshes.reduce(0) { $0 + ($1?.triangles.count ?? 0) }
    guard triangles <= SceneLimits.triangles else {
      throw error("the meshes exceed the \(SceneLimits.triangles.formatted()) triangle limit")
    }

    // Materials, in shape order: the first shape with a material passes its mesh (a bump map's UV stretch).
    var materials: [USDImportSnapshot.Material] = [], materialIndex: [String: Int] = [:], bindings: [Int?] = []
    var materialNames = Set<String>()
    for (i, shape) in shapes.enumerated() {
      progress?.update("Building Mitsuba materials", completed: i, of: shapes.count)
      guard var mesh = meshes[i] else { bindings.append(nil); continue }
      let type = shape.type ?? "(no type)"
      let label = shape.id.flatMap { $0.isEmpty ? nil : $0 } ?? "\(type)\(i)"
      let bsdf = shape.child("bsdf"), interior = shape.child("interior")
      if shape.child("exterior") != nil { scene.note("shape '\(label)': exterior medium is not supported; ignored") }
      let emission = areaEmission(shape, label: label, scene: &scene)
      // A dielectric whose IOR ratio is below 1 is imported as 1 / eta (MitsubaImporter.material) from the other side.
      if reversesFacing(bsdf, emits: emission != nil) {
        mesh = mesh.flipped()
        meshes[i] = mesh
      }
      let key = [bsdf?.id ?? "shape \(i)", emission.map { "\($0)" } ?? "", interior.map { $0.id ?? "shape \(i)" } ?? ""]
        .joined(separator: "|")
      if let index = materialIndex[key] { bindings.append(index); continue }
      // One BSDF id with different radiances or interiors gives several materials: the second and later get " 2", " 3" ...
      let base = (bsdf?.id ?? "\(type)\(i)") + (emission == nil ? "" : "_emitter")
      var name = base, copy = 1
      while !materialNames.insert(name).inserted { copy += 1; name = "\(base) \(copy)" }
      let mtlx = try material(bsdf: bsdf, emission: emission, interior: interior, name: name, scene: &scene, folder: folder, mesh: mesh)
      materialIndex[key] = materials.count
      bindings.append(materials.count)
      materials.append(USDImportSnapshot.Material(id: UUID(), name: name, color: [0.5, 0.5, 0.5], path: "materials/\(name)", mtlx: mtlx))
    }

    progress?.begin("Building Mitsuba meshes")
    let built = geometries(meshes)
    let degenerate = built.reduce(0) { $0 + $1.dropped }
    if degenerate > 0 { scene.note("\(degenerate) zero-area triangles dropped") }
    let root = SceneNode(name: url.lastPathComponent)
    var nodes = [root], assets: [MeshAsset] = []
    for (i, shape) in shapes.enumerated() {
      guard let material = bindings[i], let geometry = built[i].geometry, !geometry.isEmpty else { continue }
      let name = shape.id.flatMap { $0.isEmpty ? nil : $0 } ?? "\(shape.type ?? "shape")\(i)"
      let asset = MeshAsset(name: name, geometry: geometry, subsets: [materials[material].name])
      var node = SceneNode(name: name, parent: root.id)
      node.mesh = asset.id
      node.bindings = [materials[material].id]
      assets.append(asset)
      nodes.append(node)
    }

    let view = try camera(sensors, scene: &scene)
    let depth = pathDepth(integrator, scene: &scene)
    let environment = try sceneEnvironment(emitters, folder: folder, scene: &scene)
    let snapshot = USDImportSnapshot(
      nodes: nodes, assets: [], materials: materials, cameras: view.map { [$0.camera] } ?? [], environment: environment, sun: nil,
      report: scene.report, fallbackColors: nil, medium: nil)
    var result = try USDImporter.document(snapshot, assets: assets, folder: folder, url: url, into: source,
      format: "Mitsuba", lights: "envmap or constant", inspectionSky: false)
    if let view {
      result.document.options.outputWidth = view.width
      result.document.options.outputHeight = view.height
      if let aperture = view.aperture { result.document.options.aperture = aperture }
    }
    result.document.options.depth = depth
    try result.document.validate()
    return result
  }

  // Each shape's world-space mesh (nil for a skipped shape), read in parallel; report lines in shape order, and the
  // first shape's error in shape order.
  private static func loadMeshes(_ shapes: [Node], scene: inout Scene, progress: OperationProgress?) throws -> [Mesh?] {
    guard !shapes.isEmpty else { return [] }
    var results = [(mesh: Mesh?, report: [String], error: Error?)](repeating: (nil, [], nil), count: shapes.count)
    var base = scene
    base.report = []
    let shared = base
    results.withUnsafeMutableBufferPointer { buffer in
      let output = DisjointWrites(base: buffer.baseAddress!)  // Each worker writes only its own shape's entry.
      DispatchQueue.concurrentPerform(iterations: shapes.count) { i in
        var local = shared
        do {
          output.base[i] = (try mesh(shapes[i], scene: &local), local.report, nil)
        } catch {
          output.base[i] = (nil, local.report, error)
        }
        progress?.advance("Loading Mitsuba meshes", total: shapes.count)
      }
    }
    for result in results {
      for line in result.report { scene.note(line) }
      if let error = result.error { throw error }
    }
    return results.map(\.mesh)
  }

  // The meshes as indexed geometry, in parallel: vertices with their normals (a face normal per triangle corner for a
  // mesh without normals) and uvs (0 without them); zero-area triangles are dropped and counted.
  private static func geometries(_ meshes: [Mesh?]) -> [(geometry: MeshGeometry?, dropped: Int)] {
    guard !meshes.isEmpty else { return [] }
    var results = [(geometry: MeshGeometry?, dropped: Int)](repeating: (nil, 0), count: meshes.count)
    results.withUnsafeMutableBufferPointer { buffer in
      let output = DisjointWrites(base: buffer.baseAddress!)  // Each worker writes only its own mesh's entry.
      DispatchQueue.concurrentPerform(iterations: meshes.count) { i in
        guard let mesh = meshes[i] else { return }
        var vertices: [MeshVertex] = [], faces: [MeshFace] = []
        faces.reserveCapacity(mesh.triangles.count)
        var dropped = 0
        if let normals = mesh.normals {
          vertices = mesh.positions.indices.map { k in
            let p = mesh.positions[k], n = normals[k], uv = mesh.uvs?[k] ?? .zero
            return MeshVertex(p.x, p.y, p.z, n.x, n.y, n.z, uv.x, uv.y)
          }
        } else {
          vertices.reserveCapacity(3 * mesh.triangles.count)
        }
        for t in mesh.triangles {
          let a = mesh.positions[Int(t.x)], b = mesh.positions[Int(t.y)], c = mesh.positions[Int(t.z)]
          let cross = simd_cross(b - a, c - a), length = simd_length(cross)
          guard length > 0, length.isFinite else { dropped += 1; continue }
          if mesh.normals != nil {
            faces.append(MeshFace(t.x, t.y, t.z, 0))
          } else {
            let n = cross / length, first = UInt32(vertices.count)
            for k in [t.x, t.y, t.z] {
              let p = mesh.positions[Int(k)], uv = mesh.uvs?[Int(k)] ?? .zero
              vertices.append(MeshVertex(p.x, p.y, p.z, n.x, n.y, n.z, uv.x, uv.y))
            }
            faces.append(MeshFace(first, first + 1, first + 2, 0))
          }
        }
        output.base[i] = (MeshGeometry(vertices: vertices, faces: faces), dropped)
      }
    }
    return results
  }

  // The radiance of the shape's area emitter (1 when not given); nil without one. Other emitters are reported.
  private static func areaEmission(_ shape: Node, label: String, scene: inout Scene) -> SIMD3<Float>? {
    var radiance: SIMD3<Float>?
    for emitter in shape.children where emitter.tag == "emitter" {
      guard emitter.type == "area" else {
        scene.note("shape '\(label)': emitter \(emitter.type ?? "(no type)") unsupported; skipped")
        continue
      }
      guard radiance == nil else {
        scene.note("shape '\(label)': additional area emitter skipped")
        continue
      }
      if emitter.child("radiance") == nil {
        radiance = SIMD3(repeating: 1)
      } else if let value = emitter.rgb("radiance") {
        radiance = simd_max(value, .zero)
      } else {
        scene.note("shape '\(label)': area emitter radiance is not read (a texture or a sampled spectrum); 1 used")
        radiance = SIMD3(repeating: 1)
      }
    }
    return radiance
  }

  // The first perspective or thinlens sensor as a camera, with its film size and a thinlens's aperture radius.
  private static func camera(_ sensors: [Node], scene: inout Scene) throws
    -> (camera: USDImportSnapshot.Camera, width: Int, height: Int, aperture: Float?)? {
    var chosen: Node?
    for sensor in sensors {
      let type = sensor.type ?? "(no type)"
      guard type == "perspective" || type == "thinlens" else { scene.note("sensor \(type) unsupported; skipped"); continue }
      if chosen == nil { chosen = sensor } else { scene.note("additional sensor \(type) skipped") }
    }
    guard let sensor = chosen else {
      scene.note("no supported sensor: the default camera is used")
      return nil
    }
    if sensor.children.contains(where: { $0.tag == "medium" }) { scene.note("the sensor's medium is not supported; ignored") }
    // The film's size: whole numbers of pixels; the render size is clamped to the app's 16...8192.
    let film = sensor.child("film")
    func size(_ name: String, _ fallback: Int) throws -> Int {
      guard let value = film?.float(name) else { return fallback }
      guard value.isFinite, value >= 1, value < 1_000_000, value == value.rounded() else {
        throw error("the film's \(name) must be a positive whole number")
      }
      return Int(value)
    }
    let width = try size("width", 768), height = try size("height", 576)
    // Settings that change the image and are not represented.
    let cropped = ["crop_offset_x", "crop_offset_y", "crop_width", "crop_height"].contains { name in
      guard let value = film?.float(name) else { return false }
      return value != (name == "crop_width" ? Float(width) : name == "crop_height" ? Float(height) : 0)
    }
    if cropped { scene.note("film crop is not supported; the full frame is rendered") }
    if ["principal_point_offset_x", "principal_point_offset_y"].contains(where: { (sensor.float($0) ?? 0) != 0 }) {
      scene.note("principal point offset is not supported; ignored")
    }
    if let nearClip = sensor.float("near_clip"), nearClip != 0.01 { scene.note("near_clip \(nearClip) is not supported; ignored") }
    let aspect = Float(width) / Float(height)
    // tan of half the horizontal field of view.
    var tanX: Float
    if let fov = sensor.float("fov") {
      guard fov.isFinite, fov > 0, fov < 180 else { throw error("the sensor's fov must be between 0 and 180 degrees") }
      let t = tan(fov * .pi / 360)
      var axis = sensor.string("fov_axis") ?? "x"
      if axis == "smaller" { axis = aspect > 1 ? "y" : "x" } else if axis == "larger" { axis = aspect > 1 ? "x" : "y" }
      switch axis {
      case "x": tanX = t
      case "y": tanX = t * aspect
      case "diagonal": tanX = t / (1 + 1 / (aspect * aspect)).squareRoot()
      default:
        scene.note("sensor fov_axis '\(axis)' unknown; x used")
        tanX = t
      }
    } else {
      let text = sensor.string("focal_length") ?? "50mm"
      var millimetres = Float(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "mm", with: "")) ?? 0
      if !(millimetres.isFinite && millimetres > 0) {
        scene.note("sensor focal_length '\(text)' is not read; 50mm used")
        millimetres = 50
      }
      tanX = 43.2666 / 2 / millimetres / (1 + 1 / (aspect * aspect)).squareRoot()
    }
    let toWorld = sensor.transform("to_world")
    let linear = simd_float3x3(columns: (toWorld.columns.0.xyz, toWorld.columns.1.xyz, toWorld.columns.2.xyz))
    if simd_determinant(linear) < 0 { scene.note("sensor: a mirroring to_world is not represented; the image is not mirrored") }
    let eye = toWorld.columns.3.xyz, direction = simd_normalize(toWorld.columns.2.xyz), up = simd_normalize(toWorld.columns.1.xyz)
    var focus: Float?, aperture: Float?
    if sensor.type == "thinlens" {
      if let radius = sensor.float("aperture_radius"), radius.isFinite, radius >= 0 {
        if radius > 0.5 { scene.note("thinlens aperture_radius \(radius) rendered as 0.5, the app's largest") }
        aperture = min(radius, 0.5)
      } else {
        scene.note("thinlens has no usable aperture_radius; a pinhole is used")
      }
      focus = sensor.float("focus_distance") ?? 10000
    }
    let camera = USDImportSnapshot.Camera(name: "camera", eye: [eye.x, eye.y, eye.z], direction: [direction.x, direction.y, direction.z],
      up: [up.x, up.y, up.z], fov: 2 * atan(tanX / aspect) * 180 / .pi, focus: focus)
    func clamped(_ pixels: Int, _ name: String) -> Int {
      if !(16...8192).contains(pixels) { scene.note("film \(name) \(pixels) rendered as \(min(max(pixels, 16), 8192)), the app's limit") }
      return min(max(pixels, 16), 8192)
    }
    return (camera, clamped(width, "width"), clamped(height, "height"), aperture)
  }

  // The app's path depth from the integrator's max_depth.
  private static func pathDepth(_ integrator: Node?, scene: inout Scene) -> Int {
    var node = integrator
    while let current = node, current.child("max_depth") == nil, let inner = current.children.first(where: { $0.tag == "integrator" }) {
      node = inner
    }
    if let type = node?.type, !["path", "volpath", "volpathmis"].contains(type) {
      scene.note("integrator \(type) is not supported; the path tracer renders with its max_depth")
    }
    guard let maxDepth = node?.float("max_depth"), maxDepth >= 0 else { return 64 }
    let depth = Int(min(maxDepth, 1000)) - 1
    if depth < 1 { scene.note("max_depth \(Int(maxDepth)) rendered at path depth 1, the app's smallest") }
    if depth > 64 { scene.note("max_depth \(Int(maxDepth)) rendered at path depth 64, the app's largest") }
    return min(max(depth, 1), 64)
  }

  // The first envmap or constant emitter as the environment; other scene emitters are reported.
  private static func sceneEnvironment(_ emitters: [Node], folder: URL, scene: inout Scene) throws -> USDImportSnapshot.Environment? {
    var environment: USDImportSnapshot.Environment?
    for emitter in emitters {
      let kind = emitter.type ?? "(no type)"
      guard kind == "envmap" || kind == "constant" else {
        scene.note("emitter \(kind) unsupported; skipped")
        continue
      }
      guard environment == nil else {
        scene.note("additional \(kind) skipped")
        continue
      }
      if kind == "constant" {
        var radiance = SIMD3<Float>(repeating: 1)
        if emitter.child("radiance") != nil {
          if let value = emitter.rgb("radiance") { radiance = value } else { scene.note("constant radiance is not read; 1 used") }
        }
        environment = USDImportSnapshot.Environment(file: try constantEnvironment(radiance, folder: folder).path, intensity: 1, rotation: nil)
        continue
      }
      guard let file = emitter.url("filename") else { throw error("an envmap has no filename") }
      guard FileManager.default.fileExists(atPath: file.path) else { throw error("envmap file \(file.lastPathComponent) is missing") }
      let toWorld = emitter.transform("to_world")
      let linear = simd_float3x3(columns: (toWorld.columns.0.xyz, toWorld.columns.1.xyz, toWorld.columns.2.xyz))
      let front = linear * SIMD3(0, 0, 1)
      let turn = atan2(front.x, front.z)
      let pure = simd_float3x3(simd_quatf(angle: turn, axis: SIMD3(0, 1, 0)))
      if (0..<3).contains(where: { simd_length(linear[$0] - pure[$0]) > 1e-3 }) {
        scene.note("envmap: to_world is not a turn about +y; only its turn about +y is applied")
      }
      let degrees = turn * 180 / .pi - 90
      let scale = emitter.float("scale") ?? 1
      if !(0...100).contains(scale) { scene.note("envmap scale \(scale) rendered as \(min(max(scale, 0), 100)), the app's limit") }
      environment = USDImportSnapshot.Environment(file: file.path, intensity: scale,
        rotation: degrees < -180 ? degrees + 360 : degrees)
    }
    return environment
  }

  // A uniform latlong Radiance HDR (RGBE) image of a linear colour, as scripts/usd_bridge.py writes an untextured dome.
  private static func constantEnvironment(_ colour: SIMD3<Float>, folder: URL) throws -> URL {
    // Clamped to the emission limit of USDImporter.document, so the exponent fits its byte.
    let c = simd_clamp(colour, .zero, SIMD3(repeating: 1e8))
    var pixel: [UInt8] = [0, 0, 0, 0]
    let m = c.max()
    if m > 1e-32 {
      let (fraction, exponent) = frexp(Double(m))
      let s = fraction * 256 / Double(m)
      pixel = (0..<3).map { UInt8(min(255, Int(Double(c[$0]) * s))) } + [UInt8(exponent + 128)]
    }
    var data = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 4 +X 8\n".utf8)
    for _ in 0..<32 { data.append(contentsOf: pixel) }
    let file = folder.appendingPathComponent("constant.hdr")
    try data.write(to: file)
    return file
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
//   coordinates  the other formats' coordinates and the analytic shapes' (Mitsuba's) are kept.
//   rectangle    (-1, -1, 0) to (1, 1, 0), normal +z, uv 0 to 1.
//   disk         radius 1, 64 triangles around the centre, normal +z, uv = 0.5 + 0.5 (x, y) (a planar mapping;
//                Mitsuba's own is polar).
//   cube         -1 to 1 in 24 vertices (Mitsuba's order, one uv square per face), 12 triangles, no normals.
//   sphere       center and radius (0 and 1) applied before to_world; 64 segments by 32 rings from the +z pole,
//                smooth normals, uv (angle about z / 2 pi, angle from +z / pi).
//   A to_world with a negative determinant reverses the winding of the analytic shapes, whose front side is the
//   analytic normal's; file meshes keep their winding, as Mitsuba does.
//   flip_normals reverses the winding and negates the normals of any shape, so an area emitter emits from the other
//   side; MitsubaImporter.load reverses a shape again for a dielectric whose int_ior / ext_ior is below 1
//   (reversesFacing), so the two cancel. A to_uv on a shape other than the identity is reported and ignored.
extension MitsubaImporter {
  struct Mesh {
    var positions: [SIMD3<Float>]
    // nil: the renderer uses face normals.
    var normals: [SIMD3<Float>]?
    // v already flipped to this project's convention.
    var uvs: [SIMD2<Float>]?
    var triangles: [SIMD3<UInt32>]

    // The other side as the front: reversed winding and negated normals.
    func flipped() -> Mesh {
      var mesh = self
      mesh.triangles = triangles.map { SIMD3($0.x, $0.z, $0.y) }
      mesh.normals = normals?.map { -$0 }
      return mesh
    }
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
    let label = shape.id.flatMap { $0.isEmpty ? nil : $0 } ?? type
    let toWorld = shape.transform("to_world")
    let linear = simd_float3x3(columns: (toWorld.columns.0.xyz, toWorld.columns.1.xyz, toWorld.columns.2.xyz))
    let determinant = simd_determinant(linear)
    guard determinant.isFinite, determinant != 0 else {
      scene.note("shape \(type) has a singular to_world; skipped")
      return nil
    }
    var mesh: Mesh
    switch type {
    case "obj", "ply", "serialized":
      let faceNormals = shape.bool("face_normals") ?? false
      var fileName = ""
      let local: Mesh
      do {
        guard let url = shape.url("filename") else { throw ReadError("the shape has no filename") }
        let name = url.lastPathComponent
        fileName = name
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
        throw error("shape '\(label)': \(failure.message)")
      }
      var invalidNormals = false
      mesh = world(local, toWorld, smoothNormals: !faceNormals, invalidNormals: &invalidNormals)
      if invalidNormals { scene.note("shape '\(label)': invalid normals in \(fileName); smooth normals computed") }
    case "rectangle", "disk", "cube", "sphere":
      var unused = false
      mesh = world(unitShape(type, shape), toWorld, smoothNormals: false, invalidNormals: &unused)
      if determinant < 0 { mesh.triangles = mesh.triangles.map { SIMD3($0.x, $0.z, $0.y) } }
    default:
      scene.note("shape \(type) is not supported; skipped")
      return nil
    }
    if shape.bool("flip_normals") == true { mesh = mesh.flipped() }
    if shape.child("to_uv")?.tag == "transform", shape.transform("to_uv") != matrix_identity_float4x4 {
      scene.note("shape '\(label)': to_uv is not supported; ignored")
    }
    return mesh
  }

  // MARK: Placement and normals

  // The mesh in world space. A mesh without usable normals gets smooth ones when asked; one with them has them
  // transformed by the inverse transpose of the matrix's 3 x 3 and renormalized.
  // `invalidNormals` is set when the file's normals were dropped for a zero or non-finite one.
  fileprivate static func world(_ local: Mesh, _ matrix: simd_float4x4, smoothNormals: Bool, invalidNormals: inout Bool) -> Mesh {
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
      if transformed.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) { mesh.normals = transformed } else { invalidNormals = true }
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
      // The declared count must fit the importer's limits and the bytes left in the file, before anything is
      // reserved: a binary element takes at least its properties' sizes (a list its length's), an ASCII value
      // at least two bytes (a digit and a separator).
      let limit = element.name == "face" ? SceneLimits.triangles : 3 * SceneLimits.triangles
      let minimum = ascii ? 2 * element.properties.count : element.properties.reduce(0) { $0 + ($1.count ?? $1.type).size }
      guard element.count <= limit, element.count * minimum <= bytes.count - reader.cursor + (ascii ? 1 : 0) else {
        throw failure("the PLY declares more \(element.name == "vertex" ? "vertices" : element.name == "face" ? "faces" : element.name + " elements") than the file holds")
      }
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

  // The most a serialized sub-mesh may declare: a quarter of this Mac's memory. (The renderer's own mesh budget,
  // `MaterialLibrary.meshBudget`'s GPU working-set figure, needs a Metal device, which the importer has not.)
  fileprivate static let serializedBudget = ProcessInfo.processInfo.physicalMemory / 4

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
    guard UInt64(size) <= serializedBudget else {
      throw ReadError("\(name): the serialized sub-mesh declares \(size >> 20) MiB of data, over the memory budget")
    }
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
    // The sub-mesh's compressed bytes end where the next one starts, or at the offset table. A file whose table
    // cannot be read this way (the first sub-mesh does not need it) extends to the end of the file.
    var end = raw.count
    if let count = try? integer(UInt32.self, in: raw, at: raw.count - 4), index < count {
      let entry = version == 4 ? 8 : 4
      let tableStart = raw.count - 4 - entry * count
      var next: Int? = tableStart
      if index + 1 < count {
        let at = tableStart + entry * (index + 1)
        next = try? (version == 4 ? integer(UInt64.self, in: raw, at: at) : integer(UInt32.self, in: raw, at: at))
      }
      if let next, next > start + 4, next <= raw.count { end = next } else if index != 0 { throw failure("the serialized offset table is damaged") }
    } else if index != 0 {
      throw failure("the serialized offset table is damaged")
    }
    let input = UnsafeRawBufferPointer(rebasing: raw[(start + 4)..<end])
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

// REFERENCES.md: MITSUBA3. Values Mitsuba computes when it loads a BSDF, which the importer computes itself:
//   ior            a number, or a name of include/mitsuba/render/ior.h's table (MitsubaTables.ior, any case)
//   conductor      F0 and the OpenPBR 82-degree edge tint: a material preset from MitsubaTables.conductors, or
//                  fresnel_conductor (fresnel.h) at the given eta and k (eta 0 and k 1 by default) when eta is
//                  given or the material is none, Mitsuba's default (a perfect mirror)
//   plasticRatio   Mitsuba's plastic diffuse albedo over rho (1 - its specular albedo), averaged over incidence
//                  cosines 0.3, 0.5, 0.7 and 0.9, from the formulas of plastic.cpp and roughplastic.cpp at
//                  tag v3.9.1 (with microfacet.h's eval_reflectance and eval_transmittance and their
//                  Gauss-Legendre quadrature over visible normals) in double precision
extension MitsubaImporter {
  // The BSDFs that wrap another, their first <bsdf> child. MaterialBuilder.inputs maps a wrapper's inner BSDF through
  // innerBSDF and invertedDielectric decides from leafBSDF, so the material and the shape's facing follow one chain.
  static let wrapperBSDFs: Set<String> = ["twosided", "mask", "bumpmap", "normalmap"]

  static func innerBSDF(_ node: Node) -> Node? { node.children.first { $0.tag == "bsdf" } }

  // The BSDF a chain of wrappers ends in (the node itself when it wraps nothing).
  static func leafBSDF(_ node: Node) -> Node {
    var leaf = node
    while wrapperBSDFs.contains(leaf.type ?? ""), let inner = innerBSDF(leaf) { leaf = inner }
    return leaf
  }

  // A dielectric or roughdielectric, wrapped or not, with int_ior / ext_ior below 1 (an air bubble in ice, with the
  // denser side outside). The app's IOR is at least 1.01, and each surface uses only its own relative IOR, so the
  // interface is imported from its other side: 1 / eta with the shape's facing reversed (reversesFacing). A
  // thindielectric is not reversed: it is imported as 1 / eta, which loses its total internal reflection beyond the
  // critical angle (MaterialBuilder.dielectric reports it).
  static func invertedDielectric(_ bsdf: Node?) -> Bool {
    guard let bsdf = bsdf.map(leafBSDF), bsdf.type == "dielectric" || bsdf.type == "roughdielectric",
      let eta = try? ior(bsdf, "int_ior", default: 1.5046) / ior(bsdf, "ext_ior", default: 1.000277)
    else { return false }
    return eta.isFinite && eta > 0 && eta < 1
  }

  // Whether a shape is imported from its other side: an inverted dielectric without an area emitter. The app's
  // emission is one-sided by winding, so an emitting one keeps its facing and its interface is rendered
  // index-matched instead (MaterialBuilder.dielectric).
  static func reversesFacing(_ bsdf: Node?, emits: Bool) -> Bool { !emits && invertedDielectric(bsdf) }

  static func ior(_ node: Node, _ name: String, default fallback: Float) throws -> Float {
    guard node.child(name) != nil else { return fallback }
    if let value = node.float(name) { return value }
    guard let text = node.string(name) else { throw error("\(name) must be a number or an IOR name") }
    guard let value = MitsubaTables.ior[text.lowercased()] else { throw error("unknown IOR '\(text)'") }
    return value
  }

  static func conductor(_ node: Node) throws -> (f0: SIMD3<Float>, tint: SIMD3<Float>) {
    let material = node.string("material") ?? "none"
    guard node.child("eta") != nil || material == "none" else {
      guard let entry = MitsubaTables.conductors[material] else { throw error("unknown conductor '\(material)'") }
      return entry
    }
    if material != "none" { throw error("a conductor takes eta and k or a material, not both") }
    guard let eta = node.child("eta") == nil ? SIMD3(repeating: 0) : node.rgb("eta"),
      let k = node.child("k") == nil ? SIMD3(repeating: 1) : node.rgb("k") else {
      throw error("a conductor's eta and k must be numbers or RGB values")
    }
    var f0 = SIMD3<Float>(), tint = SIMD3<Float>()
    for c in 0..<3 {
      let eta = Double(eta[c]), k = Double(k[c])
      var normal = conductorFresnel(1, eta: eta, k: k)
      // eta = k = 0 makes the formula 0 / 0 at exactly normal incidence and 1 at every other angle.
      if normal.isNaN { normal = conductorFresnel(0.99999, eta: eta, k: k) }
      let mu = 1.0 / 7, schlick = normal + (1 - normal) * pow(1 - mu, 5)
      f0[c] = Float(min(max(normal, 0), 1))
      tint[c] = Float(min(max(conductorFresnel(mu, eta: eta, k: k) / max(schlick, 1e-6), 0), 1))
    }
    return (f0, tint)
  }

  // alpha nil: the smooth plastic; an alpha below 1e-4 is 1e-4, as microfacet.h clamps it. Rough plastics cache
  // their integrals per (eta, clamped alpha, distribution): the first call for a combination integrates, later ones
  // (another rho or nonlinear) only combine the cached values. A non-finite or non-positive eta, or a non-finite
  // alpha, gives the neutral ratio 1 (the caller reports the property).
  static func plasticRatio(eta: Float, alpha: Float?, ggx: Bool, nonlinear: Bool, rho: Float) -> Float {
    guard eta.isFinite, eta > 0, alpha?.isFinite ?? true else { return 1 }
    let rho = Double(rho)
    guard let alpha = alpha.map({ max($0, 1e-4) }) else {
      // plastic.cpp: diffuse albedo rho / (1 - x Fdr_int) / eta^2 (1 - F(mu_i)) times the cosine-weighted mean of
      // 1 - F(mu_o), specular albedo F(mu_i); the ratio does not depend on mu_i.
      let eta = Double(eta), fdrInt = fresnelDiffuseReflectance(1 / eta)
      let transmitted = gaussLegendre64.nodes.indices.reduce(0.0) { sum, i in
        let mu = 0.5 + 0.5 * gaussLegendre64.nodes[i]
        return sum + 0.5 * gaussLegendre64.weights[i] * (1 - fresnel(mu, eta).r) * 2 * mu
      }
      return Float(transmitted / (eta * eta) / (1 - (nonlinear ? rho * fdrInt : fdrInt)))
    }
    let key = RoughPlasticKey(eta: eta, alpha: alpha, ggx: ggx)
    let integrals: RoughPlasticIntegrals
    if let cached = roughPlasticCache.withLock({ $0[key] }) {
      integrals = cached
    } else {
      integrals = RoughPlasticIntegrals(eta: Double(eta), alpha: Double(alpha), ggx: ggx)
      roughPlasticCache.withLock { $0[key] = integrals }
    }
    // roughplastic.cpp: diffuse albedo rho / (1 - x R_int) / eta^2 t(mu_i) times the cosine-weighted mean of
    // t(mu_o), the external transmittance table interpolated as lerp_gather does; specular albedo E(mu_i).
    let internalScattering = nonlinear ? rho * integrals.internalReflectance : integrals.internalReflectance
    let sum = RoughPlasticIntegrals.incidences.indices.reduce(0.0) { sum, i in
      sum + integrals.transmittance(RoughPlasticIntegrals.incidences[i]) / (1 - integrals.specularAlbedo[i])
    }
    let eta = Double(eta)
    return Float(sum / 4 * integrals.meanTransmittance / (eta * eta) / (1 - internalScattering))
  }

  fileprivate struct RoughPlasticKey: Hashable { let eta: Float, alpha: Float, ggx: Bool }
  fileprivate static let roughPlasticCache = Mutex<[RoughPlasticKey: RoughPlasticIntegrals]>([:])

  fileprivate struct RoughPlasticIntegrals {
    static let incidences: [Double] = [0.3, 0.5, 0.7, 0.9]
    static let resolution = 64 // MI_ROUGH_TRANSMITTANCE_RES
    // eval_transmittance at mu = max(1e-6, k / 63), k = 0...63.
    let table: [Double]
    // m_internal_reflectance: twice the mean over the table's mu of eval_reflectance(1 / eta) mu.
    let internalReflectance: Double
    // The cosine-weighted hemispherical mean of the interpolated table.
    let meanTransmittance: Double
    // The specular lobe's albedo at each of `incidences`: eval_reflectance(eta) with 128 x 128 nodes. Mitsuba's
    // BSDF integrates this lobe exactly (no table), and 32 x 32 nodes are 2.5e-4 off at eta 1.9, alpha 0.1, GGX.
    let specularAlbedo: [Double]

    init(eta: Double, alpha: Double, ggx: Bool) {
      let microfacet = Microfacet(alpha: alpha, ggx: ggx)
      let n = Self.resolution
      var rows = [SIMD2<Double>](repeating: .zero, count: n)
      rows.withUnsafeMutableBufferPointer { buffer in
        let output = DisjointWrites(base: buffer.baseAddress!) // Each worker writes only its own table entry.
        DispatchQueue.concurrentPerform(iterations: n) { k in
          let mu = max(1e-6, Double(k) / Double(n - 1)), wi = SIMD3(sqrt(1 - mu * mu), 0, mu)
          output.base[k] = SIMD2(microfacet.transmittance(wi, eta: eta), microfacet.reflectance(wi, eta: 1 / eta) * wi.z)
        }
      }
      table = rows.map(\.x)
      internalReflectance = rows.reduce(0) { $0 + $1.y } / Double(n) * 2
      // The table is linear in mu between nodes, so 2 mu t(mu) integrates exactly per segment.
      meanTransmittance = (0..<(n - 1)).reduce(0.0) { sum, k in
        let a = Double(k) / Double(n - 1), b = Double(k + 1) / Double(n - 1), slope = (rows[k + 1].x - rows[k].x) / (b - a)
        return sum + rows[k].x * (b * b - a * a) + slope * (2.0 / 3 * (b * b * b - a * a * a) - a * (b * b - a * a))
      }
      specularAlbedo = Self.incidences.map { microfacet.reflectance(SIMD3(sqrt(1 - $0 * $0), 0, $0), eta: eta, fine: true) }
    }

    // lerp_gather: linear interpolation of the table at mu.
    func transmittance(_ mu: Double) -> Double {
      let x = mu * Double(Self.resolution - 1), index = min(Int(x), Self.resolution - 2)
      return table[index] + (table[index + 1] - table[index]) * (x - Double(index))
    }
  }

  // microfacet.h's isotropic MicrofacetDistribution with visible-normal sampling, and its eval_reflectance and
  // eval_transmittance.
  fileprivate struct Microfacet {
    let alpha: Double, ggx: Bool

    // Gauss-Legendre nodes on [0, 1]^2: Mitsuba's 32 x 32 for eta > 1, else 128 x 128; `fine` always takes 128 x 128.
    private func integrate(eta: Double, fine: Bool, _ f: (SIMD2<Double>) -> Double) -> Double {
      let rule = eta > 1 && !fine ? MitsubaImporter.gaussLegendre32 : MitsubaImporter.gaussLegendre128
      var sum = 0.0
      for i in rule.nodes.indices {
        for j in rule.nodes.indices {
          sum += f(SIMD2(rule.nodes[j], rule.nodes[i]) * 0.5 + 0.5) * rule.weights[i] * rule.weights[j] * 0.25
        }
      }
      return sum
    }

    // eval_reflectance: the albedo of the specular lobe, F G1(wo) over visible normals.
    func reflectance(_ wi: SIMD3<Double>, eta: Double, fine: Bool = false) -> Double {
      integrate(eta: eta, fine: fine) { sample in
        let m = self.sample(wi, sample), wo = 2 * simd_dot(wi, m) * m - wi
        guard wo.z > 0, wi.z > 0 else { return 0 }
        return smithG1(wo, m) * MitsubaImporter.fresnel(simd_dot(wi, m), eta).r
      }
    }

    // eval_transmittance: the share refracted through the rough interface, (1 - F) G1(wt) over visible normals.
    func transmittance(_ wi: SIMD3<Double>, eta: Double) -> Double {
      integrate(eta: eta, fine: false) { sample in
        let m = self.sample(wi, sample), cosine = simd_dot(wi, m)
        let (r, cosT, etaTi) = MitsubaImporter.fresnel(cosine, eta)
        let wt = m * (cosine * etaTi + cosT) - wi * etaTi
        guard wt.z * wi.z < 0 else { return 0 }
        return smithG1(wt, m) * (1 - r)
      }
    }

    func smithG1(_ v: SIMD3<Double>, _ m: SIMD3<Double>) -> Double {
      let xyAlpha2 = (alpha * v.x) * (alpha * v.x) + (alpha * v.y) * (alpha * v.y)
      guard simd_dot(v, m) * v.z > 0 else { return 0 }
      guard xyAlpha2 != 0 else { return 1 }
      let tanThetaAlpha2 = xyAlpha2 / (v.z * v.z)
      if ggx { return 2 / (1 + sqrt(1 + tanThetaAlpha2)) }
      // Beckmann: the rational approximation of the shadowing-masking function.
      let a = 1 / sqrt(tanThetaAlpha2)
      return a >= 1.6 ? 1 : (3.535 * a + 2.181 * a * a) / (1 + 2.276 * a + 2.577 * a * a)
    }

    // sample() with sample_visible: stretch wi, sample the alpha = 1 slopes, rotate and unstretch.
    func sample(_ wi: SIMD3<Double>, _ u: SIMD2<Double>) -> SIMD3<Double> {
      let stretched = simd_normalize(SIMD3(alpha * wi.x, alpha * wi.y, wi.z))
      let sinTheta2 = 1 - stretched.z * stretched.z
      var phi = SIMD2<Double>(1, 0) // (cos, sin), Frame3f::sincos_phi
      if abs(sinTheta2) > 4 * 0x1p-24 { phi = simd_clamp(SIMD2(stretched.x, stretched.y) / sqrt(sinTheta2), SIMD2(-1, -1), SIMD2(1, 1)) }
      let slope = visibleSlope(stretched.z, u)
      let x = (phi.x * slope.x - phi.y * slope.y) * alpha, y = (phi.y * slope.x + phi.x * slope.y) * alpha
      return simd_normalize(SIMD3(-x, -y, 1))
    }

    // sample_visible_11.
    func visibleSlope(_ cosThetaI: Double, _ u: SIMD2<Double>) -> SIMD2<Double> {
      if ggx {
        var p = MitsubaImporter.concentricDisk(u)
        let s = 0.5 * (1 + cosThetaI)
        p.y = sqrt(max(0, 1 - p.x * p.x)) * (1 - s) + p.y * s
        let z = sqrt(max(0, 1 - simd_length_squared(p))), sinThetaI = sqrt(max(0, 1 - cosThetaI * cosThetaI))
        let norm = 1 / (sinThetaI * p.y + cosThetaI * z)
        return SIMD2(cosThetaI * p.y - sinThetaI * z, p.x) * norm
      }
      // Beckmann: Newton iterations in the erf domain.
      let invSqrtPi = 1 / Double.pi.squareRoot()
      let tanThetaI = sqrt(max(0, 1 - cosThetaI * cosThetaI)) / cosThetaI, cotThetaI = 1 / tanThetaI
      let maxval = erf(cotThetaI)
      var u = simd_clamp(u, SIMD2(repeating: 1e-6), SIMD2(repeating: 1 - 1e-6))
      var x = maxval - (maxval + 1) * erf(sqrt(-log(u.x)))
      u.x *= 1 + maxval + invSqrtPi * tanThetaI * exp(-cotThetaI * cotThetaI)
      for _ in 0..<3 {
        let slope = MitsubaImporter.erfinv(x)
        let value = 1 + x + invSqrtPi * tanThetaI * exp(-slope * slope) - u.x, derivative = 1 - slope * tanThetaI
        x -= value / derivative
      }
      return SIMD2(MitsubaImporter.erfinv(x), MitsubaImporter.erfinv(2 * u.y - 1))
    }
  }

  // fresnel.h fresnel: the unpolarized dielectric Fresnel reflectance, the transmitted cosine (negative on the
  // other side) and eta_ti.
  fileprivate static func fresnel(_ cosThetaI: Double, _ eta: Double) -> (r: Double, cosThetaT: Double, etaTi: Double) {
    let outside = cosThetaI >= 0
    let etaIt = outside ? eta : 1 / eta, etaTi = outside ? 1 / eta : eta
    let cosThetaTSqr = 1 - (1 - cosThetaI * cosThetaI) * etaTi * etaTi
    let cosIAbs = abs(cosThetaI), cosTAbs = sqrt(max(0, cosThetaTSqr))
    var r: Double
    if eta == 1 {
      r = 0
    } else if cosIAbs == 0 {
      r = 1
    } else {
      let s = (cosIAbs - etaIt * cosTAbs) / (cosIAbs + etaIt * cosTAbs), p = (cosTAbs - etaIt * cosIAbs) / (cosTAbs + etaIt * cosIAbs)
      r = 0.5 * (s * s + p * p)
    }
    return (r, outside ? -cosTAbs : cosTAbs, etaTi)
  }

  // fresnel.h fresnel_conductor: the unpolarized reflectance of a conductor with complex IOR eta + i k.
  fileprivate static func conductorFresnel(_ cosThetaI: Double, eta: Double, k: Double) -> Double {
    let cos2 = cosThetaI * cosThetaI, sin2 = 1 - cos2, sin4 = sin2 * sin2
    let temp1 = eta * eta - k * k - sin2
    let a2pb2 = sqrt(max(0, temp1 * temp1 + 4 * k * k * eta * eta)), a = sqrt(max(0, 0.5 * (a2pb2 + temp1)))
    let term1 = a2pb2 + cos2, term2 = 2 * cosThetaI * a
    let rs = (term1 - term2) / (term1 + term2)
    let term3 = a2pb2 * cos2 + sin4, term4 = term2 * sin2
    let rp = rs * (term3 - term4) / (term3 + term4)
    return 0.5 * (rs + rp)
  }

  // fresnel.h fresnel_diffuse_reflectance: Egan and Hilgeman's fit for eta < 1, d'Eon and Irving's otherwise.
  fileprivate static func fresnelDiffuseReflectance(_ eta: Double) -> Double {
    let inv = 1 / eta
    if eta < 1 { return 0.0636 * inv + eta * (eta * -1.4399 + 0.7099) + 0.6681 }
    return 0.919317 + inv * (-3.4793 + inv * (6.75335 + inv * (-7.80989 + inv * (4.98554 + inv * -1.36881))))
  }

  // Dr.Jit's erfinv (Giles' approximation, include/drjit/math.h at v1.5.0).
  fileprivate static func erfinv(_ x: Double) -> Double {
    let w = -log((1 - x) * (1 + x))
    if w < 5 {
      let v = w - 2.5
      var p = 2.81022636e-08
      p = p * v + 3.43273939e-07; p = p * v - 3.5233877e-06; p = p * v - 4.39150654e-06; p = p * v + 0.00021858087
      p = p * v - 0.00125372503; p = p * v - 0.00417768164; p = p * v + 0.246640727; p = p * v + 1.50140941
      return x * p
    }
    let v = sqrt(w) - 3
    var p = -0.000200214257
    p = p * v + 0.000100950558; p = p * v + 0.00134934322; p = p * v - 0.00367342844; p = p * v + 0.00573950773
    p = p * v - 0.0076224613; p = p * v + 0.00943887047; p = p * v + 1.00167406; p = p * v + 2.83297682
    return x * p
  }

  // warp.h square_to_uniform_disk_concentric.
  fileprivate static func concentricDisk(_ u: SIMD2<Double>) -> SIMD2<Double> {
    let x = 2 * u.x - 1, y = 2 * u.y - 1
    if x == 0 && y == 0 { return .zero }
    let swapped = abs(x) < abs(y)
    let r = swapped ? y : x, rp = swapped ? x : y
    var phi = 0.25 * Double.pi * rp / r
    if swapped { phi = 0.5 * Double.pi - phi }
    return SIMD2(r * cos(phi), r * sin(phi))
  }

  // n-point Gauss-Legendre nodes and weights on [-1, 1] (Newton iteration on the Legendre polynomial).
  fileprivate static func gaussLegendre(_ n: Int) -> (nodes: [Double], weights: [Double]) {
    var nodes = [Double](repeating: 0, count: n), weights = nodes
    for i in 0..<n {
      var x = cos(Double.pi * (Double(i) + 0.75) / (Double(n) + 0.5)), derivative = 0.0
      for _ in 0..<100 {
        var p0 = 1.0, p1 = x
        for k in 2...n { (p0, p1) = (p1, ((2 * Double(k) - 1) * x * p1 - Double(k - 1) * p0) / Double(k)) }
        derivative = Double(n) * (x * p1 - p0) / (x * x - 1)
        let step = p1 / derivative
        x -= step
        if abs(step) < 1e-15 { break }
      }
      nodes[i] = x
      weights[i] = 2 / ((1 - x * x) * derivative * derivative)
    }
    return (nodes, weights)
  }
  fileprivate static let gaussLegendre32 = gaussLegendre(32)
  fileprivate static let gaussLegendre64 = gaussLegendre(64)
  fileprivate static let gaussLegendre128 = gaussLegendre(128)
}

extension SIMD4 where Scalar == Float {
  fileprivate var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
