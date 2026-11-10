import Cocoa
import simd

// REFERENCES.md: MTL2026, MCGUIRE2012, GGX2007, ENDERTON2010, MATERIALX, OPENPBR. OBJ `mtllib` materials, translated into one
// OpenPBR MaterialX document and compiled by MaterialXImporter like any other graph:
//   Kd x map_Kd               base_color (map sRGB)
//   Ks x map_Ks, Ni           specular_weight = max(Ks) / F0(Ni), clamped to 0-1; specular_ior = Ni
//   Ns                        specular_roughness = sqrt(alpha), alpha = sqrt(2 / (Ns + 2)) (GGX2007)
//   d (or 1 - Tr) x map_d     geometry_opacity; without map_d, an alpha channel in map_Kd
//   Ke x map_Ke               emission_color at emission_luminance 1 (radiance)
//   map_bump / bump           height converted to a tangent-space normal map (heightNormalMap, -bm / 128), or
//                             used directly when the image is a normal map (isNormalMap)
//   norm                      tangent-space normal map
//   illum 4, 6, 7, 9          glass: transmission_weight 1, transmission_color = 1 - Tf (McGuire's
//                             reading, which his archive's files follow: Tf 1 transmits nothing and is
//                             opaque, read as a reflection model below), smooth (the model's reflection and refraction are ray
//                             traced, not Ns highlights); Ni <= 1 or unset ("light does not bend") is
//                             geometry_thin_walled
//   d (or 1 - Tr) < 1         without map_d or a map_Kd alpha channel: glass as above (exporters write
//                             glass as constant dissolve; masks stay coverage) when untextured or named
//                             glass; other textured dissolve is coverage d
//   illum 3, 5, 8             ray-traced reflection: a Ks beyond the dielectric's reach (Ks > F0(Ni)) is
//                             base_metalness = max(Ks), so a mirror (Ks 0.95) reflects as one; likewise
//                             illum 4, 6, 7 when 1 - Tf makes them opaque ("Reflection: Ray trace on")
//   Kd 0 0 0 with map_Kd      the map alone (exporters' texture-driven colour), not black
//   illum 0, 1                no specular lobe; illum 2 the default; others are reported
// Map options -s and -o (UV scale and offset), -clamp, -bm, -mm (base + gain x texel, on colour and
// scalar maps) and -imfchan are applied; others are reported and ignored.
struct MTLMap {
  var file: String
  var scale = SIMD2<Float>(1, 1)
  var offset = SIMD2<Float>(0, 0)
  var clamp = false
  var bumpMultiplier: Float = 1
  // -mm base gain: the texel value v becomes base + gain x v.
  var range = SIMD2<Float>(0, 1)
  var channel: String?
}
struct MTLMaterial {
  var name: String
  var kd = SIMD3<Float>(repeating: 0.8)
  var ks = SIMD3<Float>(repeating: 0)
  var ke = SIMD3<Float>(repeating: 0)
  var ns: Float = 0
  var ni: Float?
  var d: Float?
  var illum = 2
  var tf: SIMD3<Float>?
  var maps: [String: MTLMap] = [:]
  // Transparency models: "Glass on" (4, 9) and "Refraction on" (6, 7).
  // A transparency model's transmitted fraction, 1 - Tf (white without Tf; MTL2026, MCGUIRE2012).
  var transmitted: SIMD3<Float> { 1 - simd_clamp(tf ?? .zero, .zero, SIMD3(repeating: 1)) }
  var transparencyModel: Bool { [4, 6, 7, 9].contains(illum) }
  var transmits: Bool { transparencyModel && transmitted.max() > 0 }
}
enum OBJMaterials {
  // Parses MTL text; `report` names ignored statements and options once each.
  static func read(_ text: String, report: inout [String]) throws -> [MTLMaterial] {
    var result: [MTLMaterial] = []
    var ignored = Set<String>()
    var lineNumber = 0
    func note(_ s: String) { if ignored.insert(s).inserted { report.append(s) } }
    for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      lineNumber += 1
      let fields = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .split(whereSeparator: \.isWhitespace).map(String.init)
      guard let keyword = fields.first?.lowercased() else { continue }
      if keyword == "newmtl" {
        result.append(MTLMaterial(name: fields.dropFirst().joined(separator: " ")))
        continue
      }
      guard !result.isEmpty else { continue }
      func numbers() throws -> [Float] {
        let values = fields.dropFirst().compactMap { Float($0) }
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite }) else {
          throw MaterialLibrary.error("Invalid MTL value on line \(lineNumber).")
        }
        return values
      }
      func color() throws -> SIMD3<Float> {
        if fields.count > 1, ["spectral", "xyz"].contains(fields[1]) {
          note("MTL spectral and xyz colours are not supported; using white.")
          return SIMD3(repeating: 1)
        }
        let v = try numbers()
        return SIMD3(v[0], v.count > 2 ? v[1] : v[0], v.count > 2 ? v[2] : v[0])
      }
      let m = result.count - 1
      // A malformed statement is reported and skipped; the rest of the library still imports.
      do {
        switch keyword {
      case "kd": result[m].kd = try color()
      case "ks": result[m].ks = try color()
      case "ke": result[m].ke = try color()
      case "ns": result[m].ns = try numbers()[0]
      case "ni": result[m].ni = try numbers()[0]
      case "d":
        // "d -halo" is not supported; the factor is used.
        result[m].d = fields.dropFirst().compactMap { Float($0) }.first ?? 1
      case "tr": if result[m].d == nil { result[m].d = 1 - (try numbers()[0]) }
      case "illum": result[m].illum = Int(min(max(try numbers()[0], -1), 99))
      case "tf": result[m].tf = try color()
      case "ka", "map_ka", "sharpness": break  // ambient: no OpenPBR input
      case "map_kd", "map_ks", "map_ke", "map_d", "map_bump", "bump", "norm":
        let key = keyword == "bump" ? "map_bump" : keyword
        result[m].maps[key] = try map(Array(fields.dropFirst()), line: lineNumber, note: note)
      default: note("MTL statement '\(fields[0])' is not supported and was ignored.")
      }
      } catch {
        report.append("\(result[m].name): \(error.localizedDescription.dropLast()); the statement was ignored.")
      }
    }
    return result
  }
  static func map(_ tokens: [String], line: Int, note: (String) -> Void) throws -> MTLMap {
    var map = MTLMap(file: "")
    var i = 0
    func values(_ maximum: Int) -> [Float] {
      var v: [Float] = []
      while v.count < maximum, i < tokens.count, let x = Float(tokens[i]) { v.append(x); i += 1 }
      return v
    }
    let arity = ["-blendu": 1, "-blendv": 1, "-boost": 1, "-cc": 1, "-texres": 1, "-type": 1]
    while i < tokens.count, tokens[i].hasPrefix("-"), tokens[i].count > 1, Float(tokens[i]) == nil {
      let option = tokens[i].lowercased()
      i += 1
      switch option {
      case "-s", "-o":
        let v = values(3)
        guard !v.isEmpty else { throw MaterialLibrary.error("MTL \(option) needs values on line \(line).") }
        let uv = SIMD2(v[0], v.count > 1 ? v[1] : (option == "-s" ? 1 : 0))
        if option == "-s" { map.scale = uv } else { map.offset = uv }
      case "-t": _ = values(3); note("MTL map option -t (turbulence) is not supported and was ignored.")
      case "-bm": map.bumpMultiplier = values(1).first ?? 1
      case "-mm":
        let v = values(2)
        map.range = SIMD2(v.first ?? 0, v.count > 1 ? v[1] : 1)
      case "-clamp": map.clamp = i < tokens.count && tokens[i].lowercased() == "on"; i += 1
      case "-imfchan": map.channel = i < tokens.count ? tokens[i].lowercased() : nil; i += 1
      default:
        if let n = arity[option] { i += n } else { throw MaterialLibrary.error("Unknown MTL map option \(option) on line \(line).") }
        note("MTL map option \(option) is not supported and was ignored.")
      }
    }
    guard i < tokens.count else { throw MaterialLibrary.error("MTL map without a file on line \(line).") }
    map.file = tokens[i...].joined(separator: " ").replacingOccurrences(of: "\\", with: "/")
    return map
  }

  // Compiles the materials named `names` from the `mtllib` files (resolved against `folder`).
  // Returns programs by material name and the base colours (for slots whose program fails).
  static func programs(libraries: [String], folder: URL, names: Set<String>, report: inout [String],
                       progress: OperationProgress? = nil) throws
    -> (programs: [String: MaterialXProgram], colors: [String: SIMD3<Float>])
  {
    var materials: [String: MTLMaterial] = [:]
    for library in libraries {
      // An mtllib argument may list several files; a single name may also contain spaces.
      let whole = folder.appendingPathComponent(library.replacingOccurrences(of: "\\", with: "/"))
      let files = FileManager.default.fileExists(atPath: whole.path)
        ? [whole] : library.split(separator: " ").map { folder.appendingPathComponent(String($0).replacingOccurrences(of: "\\", with: "/")) }
      for file in files {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_000_000,
          let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
          report.append("Material library \(file.lastPathComponent) could not be read (UTF-8 or Latin-1 text up to 16 MB).")
          continue
        }
        for m in try read(text, report: &report) where materials[m.name] == nil { materials[m.name] = m }
      }
    }
    let used = materials.values.filter { names.contains($0.name) }.sorted { $0.name < $1.name }
    for name in names.sorted() where materials[name] == nil && name != "Default" {
      report.append("Material \(name) is not defined in the material libraries.")
    }
    guard !used.isEmpty else { return ([:], [:]) }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-mtl-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    var document = MaterialXWriter()
    var shaders: [String: String] = [:]
    for (index, m) in used.enumerated() {
      progress?.update("Translating MTL materials", completed: index, of: used.count)
      shaders["m\(index)"] = m.name
      document.material(m, prefix: "m\(index)", folder: folder, scratch: scratch, report: &report)
    }
    progress?.begin("Reading material textures")
    let imported = try MaterialXImporter.read(Data(document.text.utf8), baseURL: folder, source: "MTL")
    var programs: [String: MaterialXProgram] = [:]
    for var program in imported.materials {
      guard let name = shaders[program.name] else { continue }
      program.name = name
      programs[name] = program
    }
    // Textures outside the OBJ's folder (often "../textures") and generated normal maps are embedded
    // as expected, so their notes are dropped; node paths (m12_kd) are reported by material name.
    for line in imported.report where !line.contains(": imported ") && !line.contains("is outside the document folder") {
      let id = line.prefix { $0 != ":" && $0 != "_" }
      report.append(shaders[String(id)].map { $0 + line.dropFirst(id.count).drop { $0 != ":" } } ?? line)
    }
    return (programs, Dictionary(uniqueKeysWithValues: used.map { ($0.name, $0.kd) }))
  }

  // Tangent-space normal map from a height map (MTL bump): n = normalize(-k dh/du, -k dh/dv, 1),
  // with central differences (wrapping unless clamped), h in 0-1 per texel scaled to UV units by
  // the image size (stored values, without colour management), and k = bm / 128 (see below),
  // since MTL defines no world scale for bump heights. Rows run top to bottom, so +v is up.
  static func heightNormalMap(_ url: URL, multiplier: Float, clamp: Bool, to output: URL) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0,
      image.width <= 16384, image.height <= 16384
    else { throw MaterialLibrary.error("Could not read bump map \(url.lastPathComponent).") }
    let w = image.width, h = image.height
    var height = [Float](repeating: 0, count: w * h)
    try height.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: 4 * w,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { throw MaterialLibrary.error("Could not convert bump map \(url.lastPathComponent).") }
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func at(_ x: Int, _ y: Int) -> Float {
      let x = clamp ? min(max(x, 0), w - 1) : (x + w) % w, y = clamp ? min(max(y, 0), h - 1) : (y + h) % h
      return height[y * w + x]
    }
    // Heights are in UV units scaled by -bm / 128 (MTL gives bumps no world scale). The constant puts
    // the Crytek Sponza height maps' median slope (0.06-0.13) at that of the archive's authored normal
    // maps (Bistro ddna and San Miguel N_ maps: median 0.09, quartiles 0.05-0.19); REFERENCES.md MTL2026.
    let k = multiplier / 128
    var pixels = [UInt8](repeating: 255, count: 4 * w * h)
    for y in 0..<h {
      for x in 0..<w {
        let du = (at(x + 1, y) - at(x - 1, y)) / 2 * Float(w), dv = (at(x, y - 1) - at(x, y + 1)) / 2 * Float(h)
        let n = simd_normalize(SIMD3(-k * du, -k * dv, 1))
        let o = 4 * (y * w + x)
        for c in 0..<3 { pixels[o + c] = UInt8((min(max(n[c] * 0.5 + 0.5, 0), 1) * 255).rounded()) }
      }
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4 * w, bitsPerPixel: 32)!
    pixels.withUnsafeBytes { rep.bitmapData!.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: pixels.count) }
    guard let png = rep.representation(using: .png, properties: [:]) else {
      throw MaterialLibrary.error("Could not encode the normal map for \(url.lastPathComponent).")
    }
    try png.write(to: output)
  }
  // Whether a bump-map image is a tangent-space normal map instead of heights (exporters such as
  // Bistro's write CryEngine "ddna" normal maps as map_bump): coloured texels whose blue channel is
  // at least 0.5 almost everywhere (a tangent-space normal has z >= 0), where a height map is grey.
  static func isNormalMap(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return false }
    let w = min(image.width, 64), h = min(image.height, 64)
    var rgba = [UInt8](repeating: 0, count: 4 * w * h)
    let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return false }
    var chroma: Float = 0, outward = 0
    for i in 0..<(w * h) {
      let c = SIMD3<Float>(Float(rgba[4 * i]), Float(rgba[4 * i + 1]), Float(rgba[4 * i + 2])) / 255
      chroma += c.max() - c.min()
      if c.z >= 0.48 { outward += 1 }
    }
    return chroma / Float(w * h) > 0.1 && Float(outward) > 0.95 * Float(w * h)
  }
  // Whether an image has an alpha channel with any texel below 1.
  static func hasCoverage(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    else { return false }
    let w = image.width, h = image.height
    var rgba = [UInt8](repeating: 255, count: 4 * w * h)
    let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.clear(CGRect(x: 0, y: 0, width: w, height: h))
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    return drawn && stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] < 255 }
  }
}

// Writes MTL materials as one MaterialX 1.39 document of top-level nodes and open_pbr_surface shaders.
struct MaterialXWriter {
  private var body = ""
  // Normal maps generated from bump maps, by source path, multiplier and clamping.
  private var normalMaps: [String: URL] = [:]
  var text: String { "<?xml version=\"1.0\"?>\n<materialx version=\"1.39\">\n" + body + "</materialx>\n" }
  private static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  private static func value(_ v: [Float]) -> String { v.map { String($0) }.joined(separator: ", ") }
  enum Input { case value([Float]), node(String), literal(String) }
  private mutating func node(_ name: String, _ category: String, _ type: String, _ inputs: [(String, String, Input)],
                             attributes: String = "") {
    body += "  <\(category) name=\"\(name)\" type=\"\(type)\"\(attributes)>\n"
    for (input, t, v) in inputs {
      switch v {
      case .value(let x): body += "    <input name=\"\(input)\" type=\"\(t)\" value=\"\(Self.value(x))\"/>\n"
      case .node(let n): body += "    <input name=\"\(input)\" type=\"\(t)\" nodename=\"\(n)\"/>\n"
      case .literal(let x): body += "    <input name=\"\(input)\" type=\"\(t)\" value=\"\(x)\"/>\n"
      }
    }
    body += "  </\(category)>\n"
  }
  private mutating func file(_ name: String, type: String, path: String, colorspace: String?, map: MTLMap, uv: String?) {
    var inputs = "    <input name=\"file\" type=\"filename\" value=\"\(Self.escape(path))\""
    inputs += colorspace.map { " colorspace=\"\($0)\"" } ?? ""
    inputs += "/>\n"
    if let uv { inputs += "    <input name=\"texcoord\" type=\"vector2\" nodename=\"\(uv)\"/>\n" }
    if map.clamp {
      inputs += "    <input name=\"uaddressmode\" type=\"string\" value=\"clamp\"/>\n"
      inputs += "    <input name=\"vaddressmode\" type=\"string\" value=\"clamp\"/>\n"
    }
    // -mm base gain on colour and scalar maps: the image node is `name`_raw and `name` is base + gain x texel.
    let components = ["float": 1, "color3": 3][type]
    guard map.range != SIMD2(0, 1), let components else {
      body += "  <image name=\"\(name)\" type=\"\(type)\">\n\(inputs)  </image>\n"
      return
    }
    body += "  <image name=\"\(name)_raw\" type=\"\(type)\">\n\(inputs)  </image>\n"
    node(name + "_gain", "multiply", type, [("in1", type, .node(name + "_raw")),
      ("in2", type, .value(Array(repeating: map.range.y, count: components)))])
    node(name, "add", type, [("in1", type, .node(name + "_gain")),
      ("in2", type, .value(Array(repeating: map.range.x, count: components)))])
  }
  // UV scale and offset of a map (nil for the default coordinates).
  private mutating func coordinates(_ name: String, _ map: MTLMap) -> String? {
    guard map.scale != SIMD2(1, 1) || map.offset != .zero else { return nil }
    node(name + "_uv", "texcoord", "vector2", [])
    node(name + "_scaled", "multiply", "vector2", [("in1", "vector2", .node(name + "_uv")), ("in2", "vector2", .value([map.scale.x, map.scale.y]))])
    node(name + "_st", "add", "vector2", [("in1", "vector2", .node(name + "_scaled")), ("in2", "vector2", .value([map.offset.x, map.offset.y]))])
    return name + "_st"
  }
  mutating func material(_ m: MTLMaterial, prefix: String, folder: URL, scratch: URL, report: inout [String]) {
    var inputs: [(String, String, Input)] = []
    func url(_ map: MTLMap) -> URL? {
      let u = URL(fileURLWithPath: map.file, relativeTo: folder).standardizedFileURL
      if FileManager.default.fileExists(atPath: u.path) { return u }
      // Once per texture: map_Kd is resolved for its colour, its coverage and its opacity.
      let line = "\(m.name): texture \(map.file) not found; ignored."
      if !report.contains(line) { report.append(line) }
      return nil
    }
    // A scalar from a map's channel: alpha when asked (-imfchan m) or as the default for map_d on an
    // image with alpha, otherwise the luminance image (red for colour images, the compiler's float read).
    func scalar(_ key: String, _ map: MTLMap, _ path: URL, alphaDefault: Bool, sharesColor: Bool) -> String {
      let n = prefix + "_" + key
      let uv = coordinates(n, map)
      let alpha = map.channel == "m" || (map.channel == nil && alphaDefault)
      if alpha {
        file(n + "_rgba", type: "color4", path: path.path, colorspace: sharesColor ? "srgb_texture" : "raw", map: map, uv: uv)
        node(n, "extract", "float", [("in", "color4", .node(n + "_rgba")), ("index", "integer", .value([3]))])
      } else if let c = map.channel, let index = ["r": 0, "g": 1, "b": 2][c] {
        file(n + "_rgb", type: "color3", path: path.path, colorspace: "raw", map: map, uv: uv)
        node(n, "extract", "float", [("in", "color3", .node(n + "_rgb")), ("index", "integer", .value([Float(index)]))])
      } else {
        file(n, type: "float", path: path.path, colorspace: nil, map: map, uv: uv)
      }
      return n
    }
    // Base colour.
    if let map = m.maps["map_kd"], let path = url(map) {
      let n = prefix + "_kd"
      file(n, type: "color3", path: path.path, colorspace: "srgb_texture", map: map, uv: coordinates(n, map))
      // Kd 0 0 0 beside map_Kd is how exporters write a texture-driven colour (the McGuire archive's
      // tables, paintings and leaves); the specification's product would be black, so the map stands alone.
      if m.kd != SIMD3(repeating: 1), m.kd != .zero {
        node(n + "_tint", "multiply", "color3", [("in1", "color3", .node(n)), ("in2", "color3", .value([m.kd.x, m.kd.y, m.kd.z]))])
        inputs.append(("base_color", "color3", .node(n + "_tint")))
      } else {
        inputs.append(("base_color", "color3", .node(n)))
      }
    } else {
      inputs.append(("base_color", "color3", .value([min(1, max(0, m.kd.x)), min(1, max(0, m.kd.y)), min(1, max(0, m.kd.z))])))
    }
    // Glass: a transparency model, or constant dissolve without a coverage mask (how exporters write
    // glass). A textured dissolve material is glass only when its name says so (the Bistro's dirty
    // panes); other textured ones, such as the Living Room's paper lampshade, are partial coverage.
    let d = min(1, max(0, m.d ?? 1))
    let masked = m.maps["map_d"] != nil || (m.maps["map_kd"].flatMap(url).map(OBJMaterials.hasCoverage) ?? false)
    let dissolveGlass = d < 1 && !masked && (m.maps["map_kd"] == nil || m.name.lowercased().contains("glass"))
    let glass = m.transmits || dissolveGlass
    if glass && !m.transmits {
      report.append("\(m.name): constant dissolve d \(d) rendered as glass (transmission).")
    } else if d < 1 && !masked && !glass {
      report.append("\(m.name): textured constant dissolve d \(d) rendered as coverage.")
    }
    // Specular: Phong exponent to GGX roughness, Ks against the dielectric F0 of Ni.
    let ior = (m.ni ?? 0) > 1 ? min(2.5, max(1.01, m.ni!)) : 1.5
    let f0 = ((ior - 1) / (ior + 1)) * ((ior - 1) / (ior + 1))
    let alpha = (2 / (max(0, m.ns) + 2)).squareRoot()
    inputs.append(("specular_roughness", "float", .value([glass ? 0 : alpha.squareRoot()])))
    inputs.append(("specular_ior", "float", .value([ior])))
    if glass {
      // Glass: the model's reflection and refraction are ray traced (ideal), filtered by 1 - Tf. Ni 1
      // means light does not bend, which is OpenPBR's thin-walled transmission; Fresnel keeps the
      // dielectric IOR above (1.5 when Ni is 1 or unset).
      // Dissolve glass with Tf 1 (or none) transmits white: its dissolve, not Tf, says it is glass.
      let t = m.transmitted.max() > 0 ? m.transmitted : SIMD3(repeating: 1)
      inputs.append(("transmission_weight", "float", .value([1])))
      if t != SIMD3(repeating: 1) { inputs.append(("transmission_color", "color3", .value([t.x, t.y, t.z]))) }
      if (m.ni ?? 1) <= 1 { inputs.append(("geometry_thin_walled", "boolean", .literal("true"))) }
    } else if !m.transparencyModel, ![0, 1, 2, 3, 5, 8].contains(m.illum) {
      report.append("\(m.name): illum \(m.illum) rendered as illum 2 (diffuse and specular).")
    }
    let weight = m.illum < 2 ? 0 : (m.ks.max() / f0)
    // Reflection models whose Ks a dielectric cannot reach: the excess is metal reflection. The opaque
    // transparency models (4, 6, 7 with Tf 1) keep their ray-traced reflection.
    if [3, 4, 5, 6, 7, 8].contains(m.illum), !glass, m.ks.max() > f0 {
      let metal = min(1, m.ks.max())
      inputs.append(("base_metalness", "float", .value([metal])))
      // Without map_Kd the metal takes Ks's tint at full strength, so it reflects Ks rather than Kd x Ks.
      if m.maps["map_kd"] == nil, let i = inputs.firstIndex(where: { $0.0 == "base_color" }) {
        let tint = simd_clamp(m.kd, .zero, SIMD3(repeating: 1)) * (1 - metal) + m.ks / m.ks.max() * metal
        inputs[i] = ("base_color", "color3", .value([tint.x, tint.y, tint.z]))
      }
      report.append("\(m.name): illum \(m.illum) reflection Ks \(m.ks.max()) rendered as metalness \(metal).")
    }
    if m.illum >= 2, let map = m.maps["map_ks"], let path = url(map) {
      let n = scalar("ks", map, path, alphaDefault: false, sharesColor: false)
      node(n + "_weight", "multiply", "float", [("in1", "float", .node(n)), ("in2", "float", .value([weight]))])
      node(n + "_clamped", "clamp", "float", [("in", "float", .node(n + "_weight"))])
      inputs.append(("specular_weight", "float", .node(n + "_clamped")))
    } else {
      inputs.append(("specular_weight", "float", .value([min(1, weight)])))
    }
    // Coverage (a glass material's constant dissolve is its transparency, above).
    var opacity: String?
    if let map = m.maps["map_d"], let path = url(map) {
      opacity = scalar("d", map, path, alphaDefault: OBJMaterials.hasCoverage(path), sharesColor: false)
    } else if let map = m.maps["map_kd"], let path = url(map), OBJMaterials.hasCoverage(path) {
      var alphaMap = map
      alphaMap.channel = "m"
      opacity = scalar("alpha", alphaMap, path, alphaDefault: true, sharesColor: true)
      report.append("\(m.name): the alpha channel of \(map.file) is used as opacity.")
    }
    if let o = opacity {
      if d < 1 {
        node(o + "_d", "multiply", "float", [("in1", "float", .node(o)), ("in2", "float", .value([d]))])
        inputs.append(("geometry_opacity", "float", .node(o + "_d")))
      } else {
        inputs.append(("geometry_opacity", "float", .node(o)))
      }
    } else if d < 1 && !glass {
      inputs.append(("geometry_opacity", "float", .value([d])))
    }
    // Emission.
    if m.ke != .zero || m.maps["map_ke"] != nil {
      if let map = m.maps["map_ke"], let path = url(map) {
        let n = prefix + "_ke"
        file(n, type: "color3", path: path.path, colorspace: "srgb_texture", map: map, uv: coordinates(n, map))
        let ke = m.ke == .zero ? SIMD3<Float>(repeating: 1) : m.ke
        node(n + "_tint", "multiply", "color3", [("in1", "color3", .node(n)), ("in2", "color3", .value([ke.x, ke.y, ke.z]))])
        inputs.append(("emission_color", "color3", .node(n + "_tint")))
      } else {
        inputs.append(("emission_color", "color3", .value([m.ke.x, m.ke.y, m.ke.z])))
      }
      inputs.append(("emission_luminance", "float", .value([1])))
    }
    // Normal: a normal map as given, or a bump height map converted to one.
    if let map = m.maps["norm"], let path = url(map) {
      let n = prefix + "_norm"
      file(n, type: "vector3", path: path.path, colorspace: nil, map: map, uv: coordinates(n, map))
      node(n + "_map", "normalmap", "vector3", [("in", "vector3", .node(n))])
      inputs.append(("geometry_normal", "vector3", .node(n + "_map")))
    } else if let map = m.maps["map_bump"], let path = url(map), OBJMaterials.isNormalMap(path) {
      report.append("\(m.name): bump map \(map.file) is a tangent-space normal map and is used as one.")
      let n = prefix + "_norm"
      file(n, type: "vector3", path: path.path, colorspace: nil, map: map, uv: coordinates(n, map))
      node(n + "_map", "normalmap", "vector3", [("in", "vector3", .node(n))])
      inputs.append(("geometry_normal", "vector3", .node(n + "_map")))
    } else if let map = m.maps["map_bump"], let path = url(map) {
      if let c = map.channel, c != "l" {
        report.append("\(m.name): bump channel -imfchan \(c) read as luminance.")
      }
      let key = "\(path.path)|\(map.bumpMultiplier)|\(map.clamp)"
      let output = normalMaps[key] ?? scratch.appendingPathComponent("\(normalMaps.count)_\(path.deletingPathExtension().lastPathComponent)_normal.png")
      do {
        if normalMaps[key] == nil {
          try OBJMaterials.heightNormalMap(path, multiplier: map.bumpMultiplier, clamp: map.clamp, to: output)
          normalMaps[key] = output
        }
        let n = prefix + "_bump"
        file(n, type: "vector3", path: output.path, colorspace: nil, map: map, uv: coordinates(n, map))
        node(n + "_map", "normalmap", "vector3", [("in", "vector3", .node(n))])
        inputs.append(("geometry_normal", "vector3", .node(n + "_map")))
      } catch {
        report.append("\(m.name): \(error.localizedDescription)")
      }
    }
    node(prefix, "open_pbr_surface", "surfaceshader", inputs)
  }
}
