import Cocoa
import MetalKit
import simd

// MATERIALX: a deliberately bounded MaterialX 1.38/1.39 graph compiler, not the SDK.
// Compiled expressions feed the existing Adobe OpenPBR BSDF at every surface hit.
struct GraphInstruction: Codable {
  var code = SIMD4<Int32>(repeating: 0)  // opcode, input A/B/C registers
  var value = SIMD4<Float>(repeating: 0)
  var extra = SIMD4<Float>(repeating: 0)
  var auxiliary = SIMD4<Float>(repeating: 0)
}
struct GraphHeader {
  var roots0 = SIMD4<Int32>(repeating: -1)
  var roots1 = SIMD4<Int32>(repeating: -1)
  var roots2 = SIMD4<Int32>(repeating: -1)
  var info = SIMD4<Int32>(repeating: 0)
}
struct MaterialXImage: Codable {
  var name: String
  var data: Data
  var srgb: Bool
}
struct MaterialXParameter: Codable {
  var name: String
  var instruction: Int
  var components: Int
  var defaultValue: SIMD4<Float>?
}
struct MaterialXProgram: Codable {
  var name: String
  var source: String
  var instructions: [GraphInstruction]
  var roots: [Int32]
  var images: [MaterialXImage]
  var parameters: [MaterialXParameter]
  var diffuseRoughness: Int32?
  // Register holding emission_color x emission_luminance (OpenPBR nits), or nil when the
  // shader authors neither input; see REFERENCES.md MATERIALX (graph emission).
  var emission: Int32?
  func validate() throws {
    guard !instructions.isEmpty, instructions.count <= 64, roots.count == 12,
      roots.enumerated().allSatisfy({ i, r in r >= (i == 8 ? -1 : 0) && r < instructions.count }),
      images.count <= SceneLimits.graphImages
    else { throw MaterialLibrary.error("Invalid MaterialX program capacity or outputs.") }
    if let root = diffuseRoughness, !(0..<instructions.count).contains(Int(root)) {
      throw MaterialLibrary.error("Invalid diffuse roughness output.")
    }
    if let root = emission, !(0..<instructions.count).contains(Int(root)) {
      throw MaterialLibrary.error("Invalid emission output.")
    }
    for (i, n) in instructions.enumerated() {
      guard (0...11).contains(n.code.x),
        [n.value, n.extra, n.auxiliary].allSatisfy({ v in
          (0..<4).allSatisfy { v[$0].isFinite && abs(v[$0]) < 1e8 }
        })
      else { throw MaterialLibrary.error("Invalid MaterialX instruction.") }
      let inputs =
        n.code.x <= 1
        ? 0 : [2, 6, 8, 10, 11].contains(n.code.x) ? 1 : [3, 4, 9].contains(n.code.x) ? 2 : 3
      for c in 1...3 {
        guard n.code[c] >= 0 && n.code[c] < max(1, i) else {
          throw MaterialLibrary.error("Invalid graph register.")
        }
      }
      for c in 1...3 where c <= inputs {
        guard n.code[c] >= 0 && n.code[c] < i else {
          throw MaterialLibrary.error("MaterialX graph is not acyclic.")
        }
      }
      if n.code.x == 2 {
        guard n.value.x >= 0 && n.value.x < Float(images.count) && n.value.x.rounded() == n.value.x,
          [0, 1].contains(n.value.z), [0, 1].contains(n.value.w)
        else { throw MaterialLibrary.error("Missing MaterialX image.") }
      }
      if n.code.x == 6 {
        guard (0...3).contains(n.value.x), n.value.x.rounded() == n.value.x else {
          throw MaterialLibrary.error("Invalid channel index.")
        }
      }
    }
    guard
      parameters.allSatisfy({
        $0.instruction >= 0 && $0.instruction < instructions.count
          && instructions[$0.instruction].code.x == 0 && (1...4).contains($0.components)
      })
    else { throw MaterialLibrary.error("Invalid MaterialX parameter.") }
  }
}
extension MaterialXProgram {
  // Host-side light-selection weight of graph emission: the program's Rec. 709 emission
  // luminance evaluated with every image replaced by 1 (the maximum of an LDR map) and UV
  // (0.5, 0.5). It only has to be positive where emission can be nonzero: the GPU
  // evaluates the real radiance for light samples and BSDF hits alike, and both use this
  // weight's PDF, so the estimate affects noise, not the expected image. A slot whose
  // estimate is zero is left to BSDF sampling (MIS weight 1). REFERENCES.md: MATERIALX.
  var emissionWeight: Double {
    guard let root = emission, instructions.indices.contains(Int(root)) else { return 0 }
    var values: [SIMD4<Float>] = []
    for (i, n) in instructions.enumerated() {
      func input(_ k: Int) -> SIMD4<Float> {
        i > 0 && values.indices.contains(Int(n.code[k])) ? values[Int(n.code[k])] : .zero
      }
      let a = input(1), b = input(2), c = input(3)
      var v: SIMD4<Float>
      switch n.code.x {
      case 0: v = n.value
      case 1: v = SIMD4(0.5, 0.5, 0, 0)
      case 2: v = SIMD4(repeating: 1)
      case 3: v = a * b
      case 4: v = a + b
      case 5: v = a + (b - a) * c
      case 6: v = SIMD4(repeating: a[min(3, max(0, Int(n.value.x)))])
      case 7: v = simd_min(simd_max(a, b), c)
      case 8: v = SIMD4(0, 0, 1, 0)
      case 9: v = a - b
      case 10:
        let s = sin(n.value.x), k = cos(n.value.x)
        v = SIMD4(k * a.x + s * a.y, -s * a.x + k * a.y, 0, 0)
      default: v = a
      }
      values.append((0..<4).allSatisfy { v[$0].isFinite } ? v : .zero)
    }
    let e = simd_max(values[Int(root)], .zero)
    let luminance = 0.2126 * Double(e.x) + 0.7152 * Double(e.y) + 0.0722 * Double(e.z)
    return luminance.isFinite ? min(1e8, luminance) : 0
  }
}
struct MaterialXImport {
  var materials: [MaterialXProgram] = []
  var report: [String] = []
}
private final class MXElement {
  var category: String
  var attributes: [String: String]
  var children: [MXElement] = []
  weak var parent: MXElement?
  init(_ category: String, _ attributes: [String: String]) {
    self.category = category
    self.attributes = attributes
  }
  var name: String { attributes["name"] ?? category }
  var path: String {
    parent?.category == "materialx" || parent == nil ? name : (parent!.path + "/" + name)
  }
  func input(_ name: String) -> MXElement? {
    children.first { $0.category == "input" && $0.name == name }
  }
  func inherited(_ attribute: String) -> String? {
    attributes[attribute] ?? parent?.inherited(attribute)
  }
}
private final class MXParser: NSObject, XMLParserDelegate {
  var root: MXElement?, stack: [MXElement] = [], failure: String?, elementCount = 0
  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    if stack.count >= 64 {
      failure = "XML nesting exceeds 64 levels at line \(parser.lineNumber)."
      parser.abortParsing()
      return
    }
    elementCount += 1
    if elementCount > 4096 {
      failure = "MaterialX document exceeds 4096 XML elements at line \(parser.lineNumber)."
      parser.abortParsing()
      return
    }
    let node = MXElement(name, attributes)
    node.parent = stack.last
    if let parent = stack.last { parent.children.append(node) } else { root = node }
    stack.append(node)
  }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) { if !stack.isEmpty { stack.removeLast() } }
  // DTD declarations are rejected even when a declared encoding hides them from the text scan.
  func rejectDeclaration(_ parser: XMLParser) {
    failure = "MaterialX must not contain DTD declarations (line \(parser.lineNumber))."
    parser.abortParsing()
  }
  func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
    rejectDeclaration(parser)
  }
  func parser(
    _ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String,
    forElement elementName: String, type: String?, defaultValue: String?
  ) { rejectDeclaration(parser) }
  func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
    rejectDeclaration(parser)
  }
  func parser(
    _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
    systemID: String?
  ) { rejectDeclaration(parser) }
  func parser(
    _ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?,
    systemID: String?
  ) { rejectDeclaration(parser) }
  func parser(
    _ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
    systemID: String?, notationName: String?
  ) { rejectDeclaration(parser) }
}
// Shared by every shader compiled from one document, so each image file is read once.
private final class MXDocumentState {
  var imageData: [String: Data] = [:], imageBytes = 0, notes: [String] = []
  func note(_ message: String) { if !notes.contains(message) { notes.append(message) } }
}
enum MaterialXImporter {
  static func load(_ url: URL) throws -> MaterialXImport {
    // Check the size before reading so an oversized file is never loaded.
    let file = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard file.isRegularFile == true, let size = file.fileSize, size <= 16_000_000 else {
      throw MaterialLibrary.error("MaterialX must be a regular UTF-8 XML file (maximum 16 MB).")
    }
    return try read(
      Data(contentsOf: url, options: .mappedIfSafe), baseURL: url.deletingLastPathComponent(),
      source: url.lastPathComponent
    )
  }
  static func read(_ bytes: Data, baseURL: URL, source: String) throws -> MaterialXImport {
    guard bytes.count <= 16_000_000, let text = String(data: bytes, encoding: .utf8),
      !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY")
    else {
      throw MaterialLibrary.error(
        "MaterialX must be UTF-8 XML without external entities (maximum 16 MB).")
    }
    // libxml2 honours a declared encoding; the text checks above hold only for UTF-8/ASCII.
    let declaration = try NSRegularExpression(
      pattern: #"^\x{FEFF}?\s*<\?xml[^>]*?\bencoding\s*=\s*["']([^"']*)["']"#)
    let head = String(text.prefix(512))
    if let match = declaration.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
      let range = Range(match.range(at: 1), in: head),
      !["utf-8", "us-ascii", "ascii"].contains(head[range].lowercased())
    {
      throw MaterialLibrary.error(
        "MaterialX must be UTF-8 XML; the declared encoding '\(head[range])' is not supported.")
    }
    let reader = MXParser()
    let parser = XMLParser(data: bytes)
    parser.delegate = reader
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), let root = reader.root, root.category == "materialx",
      ["1.38", "1.39"].contains(root.attributes["version"] ?? "")
    else {
      throw MaterialLibrary.error(
        reader.failure
          ?? parser.parserError.map {
            "Invalid MaterialX XML at line \(parser.lineNumber), column \(parser.columnNumber): \($0.localizedDescription)"
          }
          ?? "Expected a MaterialX 1.38 or 1.39 document.")
    }
    func descendants(_ e: MXElement) -> [MXElement] { [e] + e.children.flatMap(descendants) }
    let elements = descendants(root)
    guard
      !elements.contains(where: {
        $0.category.contains("include") || $0.category == "nodedef"
          || $0.category == "implementation"
      })
    else {
      throw MaterialLibrary.error(
        "Inline node definitions, implementations and XInclude are not supported. Export a self-contained graph using standard nodes."
      )
    }
    var indexed: [String: MXElement] = [:]
    for e in elements where e.attributes["name"] != nil {
      guard indexed[e.path] == nil else {
        throw MaterialLibrary.error("Duplicate MaterialX name: \(e.path)")
      }
      indexed[e.path] = e
    }
    var result = MaterialXImport()
    let document = MXDocumentState()
    let shaders = elements.filter {
      $0.attributes["type"] == "surfaceshader" && $0.category != "input" && $0.category != "output"
    }
    guard !shaders.isEmpty else {
      throw MaterialLibrary.error("No surface shaders were found in this MaterialX document.")
    }
    for shader in shaders {
      do {
        guard shader.category == "open_pbr_surface" else {
          throw MaterialLibrary.error(
            "Unsupported surface model \(shader.category); this importer supports open_pbr_surface."
          )
        }
        let compiler = MXCompiler(root: root, elements: indexed, baseURL: baseURL, document: document)
        let program = try compiler.compile(shader, source: source)
        result.materials.append(program)
        result.report.append(
          "\(shader.name): imported \(program.instructions.count) expression instructions, \(program.images.count) images."
        )
      } catch {
        result.report.append("\(shader.name): NOT imported — \(error.localizedDescription)")
      }
    }
    result.report += document.notes
    for e in elements where ["look", "collection", "materialassign"].contains(e.category) {
      result.report.append(
        "\(e.name): look/collection assignments are not imported; assign materials in the inspector."
      )
    }
    return result
  }
}
private final class MXCompiler {
  let root: MXElement, elements: [String: MXElement], baseURL: URL, document: MXDocumentState
  var nodes: [GraphInstruction] = [], images: [MaterialXImage] = [],
    parameters: [MaterialXParameter] = []
  var cache: [String: Int32] = [:], active = Set<String>(), imageKeys: [String: Int] = [:]
  init(root: MXElement, elements: [String: MXElement], baseURL: URL, document: MXDocumentState) {
    self.root = root
    self.elements = elements
    self.baseURL = baseURL
    self.document = document
  }
  func fail(_ message: String) throws -> Never { throw MaterialLibrary.error(message) }
  func append(_ instruction: GraphInstruction) throws -> Int32 {
    guard nodes.count < 64 else { try fail("Graph exceeds 64 expression instructions.") }
    nodes.append(instruction)
    return Int32(nodes.count - 1)
  }
  func constant(_ v: SIMD4<Float>, name: String? = nil, components: Int = 1) throws -> Int32 {
    let i = try append(GraphInstruction(value: v))
    if let name {
      parameters.append(MaterialXParameter(name: name, instruction: Int(i), components: components, defaultValue: v))
    }
    return i
  }
  func numbers(_ e: MXElement, fallback: SIMD4<Float>) throws -> SIMD4<Float> {
    guard let value = e.attributes["value"] else { return fallback }
    if value == "true" || value == "false" {
      guard e.attributes["type"] == "boolean" else {
        try fail("Boolean literal requires boolean type at \(e.path).")
      }
      return SIMD4(repeating: value == "true" ? 1 : 0)
    }
    let parts = value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    let components = e.attributes["type"]?.last.flatMap { Int(String($0)) } ?? 1
    guard parts.count == components, parts.count <= 4 else {
      try fail("Invalid value at \(e.path).")
    }
    let floats = try parts.map { part -> Float in
      guard let f = Float(part), f.isFinite, abs(f) < 1e8 else {
        try fail("Non-finite or invalid value at \(e.path).")
      }
      return f
    }
    if e.attributes["type"] == "integer", floats[0].rounded() != floats[0] {
      try fail("Integer value required at \(e.path).")
    }
    if floats.count == 1 { return SIMD4(repeating: floats[0]) }
    var result = SIMD4<Float>(repeating: 0)
    for i in floats.indices { result[i] = floats[i] }
    return result
  }
  func linked(_ e: MXElement) -> Bool {
    e.attributes["nodename"] != nil || e.attributes["nodegraph"] != nil
      || e.attributes["interfacename"] != nil
  }
  func resolve(_ name: String, from e: MXElement, graph: Bool = false) throws -> MXElement {
    // Connections name nodes beside the consuming node, never that node's own ports.
    func candidate(_ c: MXElement) -> Bool {
      c.attributes["name"] == name
        && (graph ? c.category == "nodegraph" : c.category != "input" && c.category != "output")
    }
    var scope = e.category == "input" ? e.parent?.parent : e.parent
    while let current = scope {
      if let found = current.children.first(where: candidate) { return found }
      scope = current.parent
    }
    if let found = elements[name], candidate(found) { return found }
    try fail("Unresolved connection '\(name)' at \(e.path).")
  }
  func value(_ input: MXElement?, default v: SIMD4<Float>, label: String? = nil) throws -> Int32 {
    guard let e = input else {
      return try constant(
        v, name: label,
        components: label.map { $0.hasSuffix("base_color") || $0.hasSuffix("emission_color") } == true ? 3 : 1)
    }
    if e.attributes["channels"] != nil || e.attributes["unit"] != nil {
      try fail(
        "Channel swizzles and unit conversions are unsupported at \(e.path). Use extract for channels."
      )
    }
    if let name = e.attributes["nodegraph"] {
      let graph = try resolve(name, from: e, graph: true)
      guard graph.category == "nodegraph",
        let output = graph.children.first(where: {
          $0.category == "output" && $0.name == (e.attributes["output"] ?? "out")
        })
      else { try fail("Missing nodegraph output at \(e.path).") }
      try connection(e, output)
      return try node(output)
    }
    if let name = e.attributes["nodename"] {
      if let output = e.attributes["output"], output != "out" {
        try fail("Named multi-output nodes are not supported at \(e.path).")
      }
      let target = try resolve(name, from: e)
      try connection(e, target)
      return try node(target)
    }
    if let name = e.attributes["interfacename"] {
      guard let graph = e.parent?.parent, graph.category == "nodegraph",
        let interface = graph.input(name)
      else { try fail("Missing graph interface at \(e.path).") }
      try connection(e, interface)
      return try node(interface)
    }
    if e.attributes["defaultgeomprop"] != nil {
      try fail("Explicit geometric properties are not supported at \(e.path).")
    }
    let type = e.attributes["type"] ?? "float"
    guard
      ["float", "integer", "boolean", "vector2", "vector3", "vector4", "color3", "color4"].contains(
        type)
    else { try fail("Unsupported value type \(type) at \(e.path).") }
    let components = (type.last.flatMap { Int(String($0)) }) ?? 1
    var result = try numbers(e, fallback: v)
    if type.hasPrefix("color"), let color = e.inherited("colorspace"), color != "lin_rec709",
      color != "linear", color != "none", color != "raw"
    {
      guard color == "srgb_texture" || color == "srgb" else {
        try fail("Unsupported MaterialX color space '\(color)'; use linear, raw, or sRGB, or convert with OCIO before import.")
      }
      for i in 0..<3 {
        let x = result[i]
        result[i] = x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
      }
    }
    return try constant(result, name: label ?? e.path, components: components)
  }
  func connection(_ input: MXElement, _ output: MXElement) throws {
    guard input.attributes["type"] == output.attributes["type"] else {
      try fail("Connection type mismatch at \(input.path). Use an explicit convert node.")
    }
    if input.attributes["colorspace"] != nil {
      try fail(
        "Color conversion on a connection is unsupported at \(input.path). Specify colorspace on the source image or constant."
      )
    }
  }
  func literal(_ e: MXElement?, _ fallback: SIMD4<Float>) throws -> SIMD4<Float> {
    guard let e else { return fallback }
    guard !linked(e) else { try fail("\(e.path) must be a constant in this importer.") }
    return try numbers(e, fallback: fallback)
  }
  func allowed(_ e: MXElement, _ names: Set<String>) throws {
    for i in e.children where i.category == "input" && !names.contains(i.name) {
      try fail("Unsupported input \(i.path).")
    }
    if let type = e.attributes["type"],
      !(["float", "integer", "boolean", "vector2", "vector3", "vector4", "color3", "color4"]
        .contains(type))
    {
      try fail("Unsupported node type \(type) at \(e.path).")
    }
  }
  // Files are checked before reading; out-of-folder images are reported because they are embedded.
  func imageData(_ url: URL, at e: MXElement) throws -> Data {
    if let bytes = document.imageData[url.path] { return bytes }
    let file: URLResourceValues
    do { file = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) } catch {
      try fail("Missing image \(url.lastPathComponent): \(error.localizedDescription)")
    }
    guard file.isRegularFile == true, let size = file.fileSize else {
      try fail("Image \(url.lastPathComponent) at \(e.path) is not a regular file.")
    }
    guard size <= 128 * 1024 * 1024 else {
      try fail("Image \(url.lastPathComponent) exceeds the 128 MiB import limit.")
    }
    guard document.imageBytes + size <= 1 << 30 else {
      try fail("MaterialX images exceed 1 GiB in total.")
    }
    let bytes: Data
    do { bytes = try Data(contentsOf: url) } catch {
      try fail("Missing image \(url.lastPathComponent): \(error.localizedDescription)")
    }
    guard bytes.count <= 128 * 1024 * 1024 else {
      try fail("Image \(url.lastPathComponent) exceeds the 128 MiB import limit.")
    }
    let folder = baseURL.standardizedFileURL.resolvingSymlinksInPath().path
    if !url.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") {
      document.note(
        "\(e.path): image \(url.path) is outside the document folder and is embedded in the project.")
    }
    document.imageBytes += bytes.count
    document.imageData[url.path] = bytes
    return bytes
  }
  func node(_ e: MXElement) throws -> Int32 {
    if let i = cache[e.path] { return i }
    guard active.count < 64 else { try fail("MaterialX graph exceeds 64 expression levels.") }
    guard active.insert(e.path).inserted else { try fail("Cycle at \(e.path).") }
    defer { active.remove(e.path) }
    var instruction = GraphInstruction()
    let result: Int32
    let type = e.attributes["type"] ?? ""
    if e.category == "texcoord" {
      guard type == "vector2" else { try fail("Only vector2 UV coordinates are supported.") }
    }
    if e.category == "normalmap" {
      guard type == "vector3" else { try fail("normalmap output must be vector3.") }
    }
    if e.category == "extract" {
      guard type == "float" else { try fail("Only scalar channel extraction is supported.") }
    }
    if ["image", "multiply", "add", "subtract", "mix", "clamp"].contains(e.category) {
      guard ["float", "color3", "color4", "vector2", "vector3", "vector4"].contains(type) else {
        try fail("Unsupported numeric node type at \(e.path).")
      }
    }
    for input in e.children where input.category == "input" {
      let inputType = input.attributes["type"] ?? ""
      var expected: [String] = []
      switch e.category {
      case "constant": expected = [type]
      case "texcoord": expected = ["integer"]
      case "image":
        expected =
          input.name == "texcoord"
          ? ["vector2"]
          : input.name == "file" ? ["filename"] : input.name == "default" ? [type] : ["string"]
      case "normalmap":
        expected =
          input.name == "scale" ? ["float", "vector2"] : input.name == "space" ? ["string"] : ["vector3"]
      case "extract":
        expected =
          input.name == "index"
          ? ["integer"] : ["color3", "color4", "vector2", "vector3", "vector4"]
      case "multiply", "add", "subtract": expected = input.name == "in1" ? [type] : [type, "float"]
      case "mix": expected = input.name == "mix" ? [type, "float"] : [type]
      case "clamp": expected = input.name == "in" ? [type] : [type, "float"]
      default: break
      }
      if !expected.isEmpty && !expected.contains(inputType) {
        try fail("Invalid input type at \(input.path).")
      }
    }
    switch e.category {
    case "input", "output": result = try value(e, default: .zero)
    case "constant":
      try allowed(e, ["value"])
      result = try value(e.input("value"), default: .zero, label: e.path)
    case "texcoord":
      try allowed(e, ["index"])
      guard try literal(e.input("index"), .zero).x == 0 else {
        try fail("Only UV set 0 is supported.")
      }
      instruction.code.x = 1
      result = try append(instruction)
    case "image":
      try allowed(e, ["file", "texcoord", "default", "uaddressmode", "vaddressmode", "filtertype"])
      // MaterialX "clamp" clamps coordinates to 0-1 before sampling: clamp-to-edge.
      var clamped = SIMD2<Float>(repeating: 0)
      for (axis, name) in ["uaddressmode", "vaddressmode"].enumerated() {
        guard let i = e.input(name) else { continue }
        guard !linked(i), ["periodic", "clamp"].contains(i.attributes["value"] ?? "") else {
          try fail("Only periodic or clamp image addressing is supported at \(e.path).")
        }
        clamped[axis] = i.attributes["value"] == "clamp" ? 1 : 0
      }
      if let f = e.input("filtertype"), f.attributes["value"] != "linear" {
        try fail("Only linear image filtering is supported at \(e.path).")
      }
      // An empty file reference cannot be resolved, so the node outputs its `default`
      // input (zero when unauthored), per the MaterialX 1.39 <image> definition.
      if !(e.input("file").map(linked) ?? false), (e.input("file")?.attributes["value"] ?? "").isEmpty {
        document.note("\(e.path): image has no file and evaluates to its default value.")
        result = try constant(try literal(e.input("default"), .zero))
        break
      }
      guard let input = e.input("file"), let path = input.attributes["value"], !path.isEmpty,
        !linked(input), !path.contains("<UDIM>"), !path.contains("<UVTILE>"), !path.contains("://")
      else { try fail("Image needs a local, non-UDIM filename at \(e.path).") }
      let prefix = input.inherited("fileprefix") ?? ""
      let url = URL(fileURLWithPath: prefix + path, relativeTo: baseURL).standardizedFileURL
        .resolvingSymlinksInPath()
      // MaterialX color-manages only color3/color4 values; other image types stay raw.
      let linear = ["lin_rec709", "linear", "raw", "none"]
      let color: String
      if type.hasPrefix("color") {
        color = input.attributes["colorspace"] ?? e.inherited("colorspace") ?? "lin_rec709"
        guard linear.contains(color) || color == "srgb_texture" || color == "srgb" else {
          try fail("Unsupported MaterialX image color space '\(color)'; OCIO/ACES transforms are not available in this importer.")
        }
      } else {
        color = "raw"
        if let tag = input.attributes["colorspace"] ?? e.attributes["colorspace"], !linear.contains(tag) {
          document.note(
            "\(e.path): colorspace '\(tag)' ignored on \(type) image; MaterialX color-manages only color3/color4 images.")
        }
      }
      let srgb = color == "srgb_texture" || color == "srgb"
      let key = url.path + "|" + String(srgb)
      let imageIndex: Int
      if let i = imageKeys[key] {
        imageIndex = i
      } else {
        guard images.count < SceneLimits.graphImages else { try fail("Too many MaterialX images.") }
        let bytes = try imageData(url, at: e)
        imageIndex = images.count
        imageKeys[key] = imageIndex
        images.append(MaterialXImage(name: url.lastPathComponent, data: bytes, srgb: srgb))
      }
      let uv: Int32
      if let input = e.input("texcoord") {
        uv = try value(input, default: .zero)
      } else {
        uv = try append(GraphInstruction(code: SIMD4(1, 0, 0, 0)))
      }
      instruction.code = SIMD4(2, uv, 0, 0)
      instruction.value.x = Float(imageIndex)
      instruction.value.y = e.attributes["type"] == "float" ? 1 : 0
      instruction.value.z = clamped.x
      instruction.value.w = clamped.y
      result = try append(instruction)
    case "multiply", "add", "subtract", "mix", "clamp":
      let names: Set<String> =
        e.category == "mix"
        ? ["fg", "bg", "mix"] : e.category == "clamp" ? ["in", "low", "high"] : ["in1", "in2"]
      try allowed(e, names)
      let a = try value(
        e.input(e.category == "mix" ? "bg" : e.category == "clamp" ? "in" : "in1"), default: .zero)
      let b = try value(
        e.input(e.category == "mix" ? "fg" : e.category == "clamp" ? "low" : "in2"),
        default: e.category == "multiply" ? SIMD4(repeating: 1) : .zero)
      let c: Int32 =
        e.category == "mix" || e.category == "clamp"
        ? try value(
          e.input(e.category == "mix" ? "mix" : "high"),
          default: SIMD4(repeating: e.category == "mix" ? 0 : 1)) : 0
      instruction.code = SIMD4(
        e.category == "multiply"
          ? 3 : e.category == "add" ? 4 : e.category == "mix" ? 5 : e.category == "clamp" ? 7 : 9,
        a, b, c)
      result = try append(instruction)
    case "extract":
      try allowed(e, ["in", "index"])
      let a = try value(e.input("in"), default: .zero)
      let index = try literal(e.input("index"), .zero).x
      let width = e.input("in")?.attributes["type"]?.last.flatMap { Int(String($0)) } ?? 0
      guard index >= 0, index < Float(width), index.rounded() == index else {
        try fail("Channel index must be 0–3.")
      }
      instruction.code = SIMD4(6, a, 0, 0)
      instruction.value.x = index
      result = try append(instruction)
    case "normalmap":
      try allowed(e, ["in", "scale", "space", "normal", "tangent", "bitangent"])
      // MaterialX 1.38 authors space="tangent" explicitly; frames must keep their geometric defaults.
      if let space = e.input("space") {
        let mode = space.attributes["value"] ?? "tangent"
        guard !linked(space), mode == "tangent" else {
          try fail(
            mode == "object"
              ? "Object-space normal maps are unsupported at \(e.path); use a tangent-space normal map."
              : "Invalid normalmap space at \(e.path).")
        }
      }
      for name in ["normal", "tangent", "bitangent"] {
        if let frame = e.input(name), linked(frame) || frame.attributes["value"] != nil {
          try fail("Custom normalmap \(name) is unsupported at \(e.path); leave it at its geometric default.")
        }
      }
      let a = try value(e.input("in"), default: SIMD4(0.5, 0.5, 1, 0))
      let scale = try literal(e.input("scale"), SIMD4(repeating: 1))
      instruction.code = SIMD4(8, a, 0, 0)
      instruction.value = scale
      result = try append(instruction)
    case "rotate2d":
      try allowed(e, ["in", "amount"])
      guard type == "vector2" else { try fail("rotate2d requires vector2.") }
      let a = try value(e.input("in"), default: .zero)
      let angle = try literal(e.input("amount"), .zero).x
      instruction.code = SIMD4(10, a, 0, 0)
      instruction.value.x = angle * .pi / 180
      result = try append(instruction)
    case "convert":
      try allowed(e, ["in"])
      guard let input = e.input("in"), let sourceType = input.attributes["type"],
        let targetType = e.attributes["type"],
        sourceType == targetType || sourceType == "float"
          || (sourceType.last == targetType.last
            && ["color3", "vector3", "color4", "vector4"].contains(sourceType)
            && ["color3", "vector3", "color4", "vector4"].contains(targetType))
      else { try fail("Only scalar broadcasts and matching-width conversions are supported.") }
      let a = try value(input, default: .zero)
      instruction.code = SIMD4(11, a, 0, 0)
      result = try append(instruction)
    default: try fail("Unsupported node \(e.category) at \(e.path).")
    }
    cache[e.path] = result
    return result
  }
  func compile(_ shader: MXElement, source: String) throws -> MaterialXProgram {
    let inputs: [(String, SIMD4<Float>)] = [
      ("base_color", SIMD4(0.8, 0.8, 0.8, 0)), ("specular_roughness", SIMD4(repeating: 0.3)),
      ("base_metalness", .zero), ("coat_weight", .zero), ("specular_roughness_anisotropy", .zero),
      ("fuzz_weight", .zero), ("specular_ior", SIMD4(repeating: 1.5)),
      ("transmission_weight", .zero), ("geometry_normal", .zero), ("coat_roughness", .zero),
      ("specular_weight", SIMD4(repeating: 1)), ("base_weight", SIMD4(repeating: 1)),
    ]
    let defaults: [String: SIMD4<Float>] = [
      "specular_color": SIMD4(repeating: 1),
      "transmission_color": SIMD4(repeating: 1), "transmission_depth": .zero,
      "transmission_scatter": .zero, "transmission_scatter_anisotropy": .zero,
      "transmission_dispersion_scale": .zero,
      "transmission_dispersion_abbe_number": SIMD4(repeating: 20), "subsurface_weight": .zero,
      "subsurface_color": SIMD4(0.8, 0.8, 0.8, 0), "subsurface_radius": SIMD4(repeating: 1),
      "subsurface_radius_scale": SIMD4(1, 0.5, 0.25, 0), "subsurface_scatter_anisotropy": .zero,
      "fuzz_color": SIMD4(repeating: 1), "fuzz_roughness": SIMD4(repeating: 0.5),
      "coat_color": SIMD4(repeating: 1), "coat_roughness_anisotropy": .zero,
      "coat_ior": SIMD4(repeating: 1.6), "coat_darkening": SIMD4(repeating: 1),
      "thin_film_weight": .zero, "thin_film_thickness": SIMD4(repeating: 0.5),
      "thin_film_ior": SIMD4(repeating: 1.4), "geometry_opacity": SIMD4(repeating: 1),
      "geometry_thin_walled": .zero,
    ]
    for i in shader.children
    where i.category == "input" && !["base_diffuse_roughness", "emission_luminance", "emission_color"].contains(i.name)
      && !inputs.contains(where: { $0.0 == i.name })
    {
      // These default to geometric frames (Tworld/Nworld), which the renderer already uses.
      let frames = ["geometry_tangent": "Tworld", "geometry_coat_normal": "Nworld", "geometry_coat_tangent": "Tworld"]
      if let frame = frames[i.name] {
        guard !linked(i), i.attributes["value"] == nil,
          (i.attributes["defaultgeomprop"] ?? frame) == frame
        else {
          try fail("\(i.name) must keep its geometric default; connected or constant values are unsupported.")
        }
        continue
      }
      guard let fallback = defaults[i.name], !linked(i) else {
        try fail("Unsupported surface input \(i.name).")
      }
      let v = try numbers(i, fallback: fallback)
      let n = i.attributes["type"] == "color3" ? 3 : 1
      guard (0..<n).allSatisfy({ abs(v[$0] - fallback[$0]) < 1e-6 }) else {
        try fail("Non-default \(i.name) is not supported.")
      }
    }
    var roots: [Int32] = []
    for (name, fallback) in inputs {
      if let input = shader.input(name) {
        let expected =
          name == "base_color" ? "color3" : name == "geometry_normal" ? "vector3" : "float"
        guard input.attributes["type"] == expected else {
          try fail("Invalid surface input type for \(name).")
        }
      }
      if name == "geometry_normal", shader.input(name) == nil {
        roots.append(-1)
        continue
      }
      roots.append(
        try value(shader.input(name), default: fallback, label: shader.name + "/" + name))
    }
    var diffuseRoot: Int32?
    if let input = shader.input("base_diffuse_roughness") {
      guard input.attributes["type"] == "float" else { try fail("Diffuse roughness must be float.") }
      diffuseRoot = try value(input, default: .zero, label: shader.name + "/base_diffuse_roughness")
    }
    // OpenPBR emission: emission_color x emission_luminance (nits), constant or connected.
    // Unauthored inputs keep the default of no emission and add no instructions.
    var emissionRoot: Int32?
    let luminance = shader.input("emission_luminance"), color = shader.input("emission_color")
    if luminance != nil || color != nil {
      guard luminance.map({ $0.attributes["type"] == "float" }) ?? true,
        color.map({ $0.attributes["type"] == "color3" }) ?? true
      else { try fail("Invalid surface input type for emission.") }
      let l = try value(luminance, default: .zero, label: shader.name + "/emission_luminance")
      let c = try value(color, default: SIMD4(1, 1, 1, 0), label: shader.name + "/emission_color")
      emissionRoot = try append(GraphInstruction(code: SIMD4(3, c, l, 0)))
    }
    let program = MaterialXProgram(
      name: shader.name, source: source, instructions: nodes, roots: roots, images: images,
      parameters: parameters, diffuseRoughness: diffuseRoot, emission: emissionRoot)
    try program.validate()
    return program
  }
}

extension MaterialLibrary {
  func prepareMaterialX(_ programs: [Int: MaterialXProgram]) throws {
    let candidate = try materialXCandidate(programs, images: images)
    let old = (graphInstructionBuffer, graphHeaderBuffer, graphTextures, materialX)
    let oldArgument = argumentBuffer
    graphInstructionBuffer = candidate.instructions
    graphHeaderBuffer = candidate.headers
    graphTextures = candidate.textures
    materialX = programs
    do { try rebuildArguments(images) } catch {
      (graphInstructionBuffer, graphHeaderBuffer, graphTextures, materialX) = old
      argumentBuffer = oldArgument
      throw error
    }
  }
  // Builds graph resources without publishing them. Texture checks count
  // `candidateImages` as the map set that will be published alongside.
  func materialXCandidate(_ programs: [Int: MaterialXProgram], images candidateImages: [MTLTexture]) throws
    -> (instructions: MTLBuffer, headers: MTLBuffer, textures: [MTLTexture])
  {
    var instructions: [GraphInstruction] = []
    var headers = Array(repeating: GraphHeader(), count: SceneLimits.materials)
    var textures: [MTLTexture] = []
    // Identical encoded images share one decoded texture and graph binding across
    // slots, reusing textures from this library's published graphs or from the
    // published library a candidate replaces (`external`).
    var bindings: [[Data: Int]] = [[:], [:]]
    var reusable: [[Data: MTLTexture]] = [[:], [:]]
    for (graphs, published) in [(materialX, graphTextures), (external.materialX, external.graphTextures)] {
      bindings = [[:], [:]]
      for (_, old) in graphs.sorted(by: { $0.key < $1.key }) {
        for image in old.images where bindings[image.srgb ? 1 : 0][image.data] == nil {
          let index = bindings[0].count + bindings[1].count
          bindings[image.srgb ? 1 : 0][image.data] = index
          if index < published.count, reusable[image.srgb ? 1 : 0][image.data] == nil {
            reusable[image.srgb ? 1 : 0][image.data] = published[index]
          }
        }
      }
    }
    bindings = [[:], [:]]
    for slot in programs.keys.sorted() {
      guard (0..<SceneLimits.materials).contains(slot), let program = programs[slot] else {
        throw Self.error("Invalid graph material slot.")
      }
      try program.validate()
      var imageIndices: [Int] = []
      for image in program.images {
        if let index = bindings[image.srgb ? 1 : 0][image.data] {
          imageIndices.append(index)
          continue
        }
        guard textures.count < SceneLimits.graphImages else {
          throw Self.error("Scene exceeds 128 MaterialX images.")
        }
        bindings[image.srgb ? 1 : 0][image.data] = textures.count
        imageIndices.append(textures.count)
        if let texture = reusable[image.srgb ? 1 : 0][image.data] {
          textures.append(texture)
          continue
        }
        try validateEncodedImage(image.data, pending: candidateImages + textures)
        let texture = try decodeTexture(image.data, srgb: image.srgb)
        try validateDecodedTexture(texture, encodedBytes: image.data.count, pending: candidateImages + textures)
        textures.append(texture)
        try validateCandidateTextures(images: candidateImages, graph: textures)
      }
      var header = GraphHeader()
      for i in 0..<4 {
        header.roots0[i] = program.roots[i]
        header.roots1[i] = program.roots[i + 4]
        header.roots2[i] = program.roots[i + 8]
      }
      header.info = SIMD4(
        Int32(instructions.count), Int32(program.instructions.count), program.diffuseRoughness ?? -1,
        program.emission ?? -1)
      headers[slot] = header
      for var node in program.instructions {
        if node.code.x == 2 { node.value.x = Float(imageIndices[Int(node.value.x)]) }
        instructions.append(node)
      }
    }
    if instructions.isEmpty { instructions.append(GraphInstruction()) }
    guard
      let instructionBuffer = instructions.withUnsafeBytes({
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
      }),
      let headerBuffer = headers.withUnsafeBytes({
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
      })
    else { throw Self.error("Could not allocate MaterialX graph buffers.") }
    try validateCandidateTextures(images: candidateImages, graph: textures)
    return (instructionBuffer, headerBuffer, textures)
  }
}
