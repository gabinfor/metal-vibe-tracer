import Cocoa
import simd

// REFERENCES.md: MITSUBA3, BITTERLI2016, OPENPBR, MATERIALX, SRGB1999. A shape's BSDF, area emitter and interior
// medium as one OpenPBR MaterialX document (the form GLTFImporter writes, with its Writer). The mapping is that of
// scripts/mitsuba_to_usd.py (material, principled_thin, colour_input, texture, plastic_texture, bump_normal_map,
// material_prim), whose report lines it keeps:
//   diffuse              base_color = reflectance (0.5), specular_weight 0
//   plastic/roughplastic base_color = diffuse_reflectance (0.5) x plasticRatio (int_ior 1.49, ext_ior 1.000277,
//                        alpha 0.1, beckmann), specular_ior = int_ior / ext_ior, specular_roughness = sqrt(alpha)
//                        (0 when smooth); a texture is multiplied by the ratio at rho 0.5, or for a nonlinear plastic
//                        baked per texel and channel from the ratio at 17 reflectances, linearly interpolated
//   conductor/rough...   base_metalness 1, base_color = F0 and specular_color = the 82-degree tint of
//                        MitsubaImporter.conductor (none, a perfect mirror, by default), specular_reflectance as
//                        specular_weight (its chroma kept in base_color; a texture multiplies base_color instead)
//   dielectric/rough...  transmission_weight 1, specular_ior = int_ior (1.5046) / ext_ior (1.000277),
//                        specular_transmittance as transmission_color, and zero as a black reflector
//   thindielectric       the same with geometry_thin_walled
//   principledthin       thin-walled; base_color, diff_trans as subsurface weight and anisotropy, spec_trans as
//                        transmission_weight and specular_weight, roughness, eta
//   twosided             its (first) inner BSDF; mask: geometry_opacity = opacity (a texture, or a constant's mean)
//   bumpmap              the inner BSDF with the height map as a tangent-space normal map, from the mesh's UV stretch
//   normalmap            the inner BSDF with its texture as the normal map
//   bitmap               an image node (sRGB unless raw), its texcoord scaled by the to_uv scale; checkerboard: a
//                        256 px 8-bit sRGB PNG of color0 (0.4) and color1 (0.2) in the import folder
//   no BSDF              grey diffuse 0.5, or black when the shape emits (Mitsuba's Shape default)
//   area emitter         emission_color x emission_luminance = the radiance
//   interior medium      homogeneous with albedo 0 (Mitsuba 0.6: sigma_s 0) behind a refracting BSDF:
//                        transmission_color exp(-sigma_t x scale) at transmission_depth 1
// Unsupported BSDFs, textures and properties, and every approximation, add a report line.
extension MitsubaImporter {
  // `name` labels the report lines and the baked images. `mesh` is the first mesh using the material: a bump map's
  // normal map depends on its UV stretch, as in the converter; without UVs the bump map is dropped and reported.
  static func material(bsdf: Node?, emission: SIMD3<Float>?, interior: Node?, name: String,
                       scene: inout Scene, folder: URL, mesh: Mesh? = nil) throws -> String {
    var builder = MaterialBuilder(name: name, folder: folder, scene: scene)
    defer { scene = builder.scene }
    var inputs: Inputs
    if let bsdf {
      inputs = try builder.inputs(bsdf)
    } else {
      // Without a BSDF Mitsuba gives a shape a diffuse 0.5, or 0 if it is an emitter (Shape::Shape).
      inputs = Inputs()
      inputs["base_color"] = .color(SIMD3(repeating: emission == nil ? 0.5 : 0))
      inputs["specular_weight"] = .value(0)
    }
    if let bump = inputs.bump {
      if let mesh, let uvs = mesh.uvs {
        inputs["geometry_normal"] = .normalMap(try builder.normalMap(bump, mesh: mesh, uvs: uvs))
      } else {
        builder.scene.note("\(name): bump map dropped (its mesh has no UVs)")
      }
    }
    if let emission {
      let scale = max(emission.max(), 1e-12)
      inputs["emission_color"] = .color(emission / scale)
      inputs["emission_luminance"] = .value(scale)
    }
    if let interior { builder.medium(interior, into: &inputs) }
    return inputs.document()
  }
}

// OpenPBR inputs in the order they were set; `bump` carries a bump map until the mesh is known.
private struct Inputs {
  enum Input {
    case value(Float), color(SIMD3<Float>), boolean(Bool)
    case texture(Texture, tint: SIMD3<Float>?)
    case normalMap(Texture)
  }
  struct Texture {
    var file: URL
    var srgb: Bool
    var scale: SIMD2<Float>
  }
  struct Bump {
    var texture: Texture
    var scale: Float
  }
  private(set) var list: [(name: String, value: Input)] = []
  var bump: Bump?

  subscript(name: String) -> Input? {
    get { list.first { $0.name == name }?.value }
    set {
      let index = list.firstIndex { $0.name == name }
      switch (index, newValue) {
      case (let i?, let v?): list[i].value = v
      case (let i?, nil): list.remove(at: i)
      case (nil, let v?): list.append((name, v))
      case (nil, nil): break
      }
    }
  }
  func value(_ name: String) -> Float? {
    if case .value(let v)? = self[name] { return v }
    return nil
  }

  func document() -> String {
    var w = GLTFImporter.Writer(prefix: "mitsuba")
    // A texcoord scaled by the to_uv scale, as the converter wrote it (nil for no scale).
    func coordinates(_ scale: SIMD2<Float>) -> String? {
      guard scale != SIMD2(1, 1) else { return nil }
      let uv = w.op("texcoord", "vector2", [])
      return w.op("multiply", "vector2", [("in1", .node(uv, "vector2"))], extra: [("in2", "vector2", "\(scale.x), \(scale.y)")])
    }
    var values: [(String, GLTFImporter.Writer.Value)] = []
    for (name, input) in list {
      switch input {
      case .value(let v): values.append((name, .float(v)))
      case .color(let c): values.append((name, .color(c)))
      case .boolean(let b): values.append((name, .boolean(b)))
      case .texture(let t, let tint):
        let type = name == "geometry_opacity" ? "float" : "color3"
        let node = w.image(t.file.path, type: type, colorspace: t.srgb ? "srgb_texture" : "raw", uv: coordinates(t.scale),
                           u: "periodic", v: "periodic")
        if let tint {
          values.append((name, .node(w.op("multiply", type, [("in1", .node(node, type)), ("in2", .color(tint))]), type)))
        } else {
          values.append((name, .node(node, type)))
        }
      case .normalMap(let t):
        let node = w.image(t.file.path, type: "vector3", colorspace: "raw", uv: nil, u: "periodic", v: "periodic")
        values.append((name, .node(w.op("normalmap", "vector3", [("in", .node(node, "vector3"))]), "vector3")))
      }
    }
    return w.document(values)
  }
}

private struct MaterialBuilder {
  let name: String
  let folder: URL
  var scene: MitsubaImporter.Scene

  // The properties each BSDF's mapping reads; any other property is reported as unsupported.
  static let properties: [String: Set<String>] = [
    "diffuse": ["reflectance"],
    "plastic": ["diffuse_reflectance", "int_ior", "ext_ior", "nonlinear"],
    "roughplastic": ["diffuse_reflectance", "int_ior", "ext_ior", "nonlinear", "alpha", "distribution", "sample_visible"],
    "conductor": ["material", "eta", "k", "specular_reflectance"],
    "roughconductor": ["material", "eta", "k", "specular_reflectance", "alpha", "distribution", "sample_visible"],
    "dielectric": ["int_ior", "ext_ior", "specular_reflectance", "specular_transmittance"],
    "roughdielectric": ["int_ior", "ext_ior", "specular_reflectance", "specular_transmittance", "alpha", "distribution", "sample_visible"],
    "thindielectric": ["int_ior", "ext_ior", "specular_reflectance", "specular_transmittance"],
    "principledthin": ["base_color", "diff_trans", "spec_trans", "roughness", "eta", "anisotropic", "spec_tint", "sheen",
                       "sheen_tint", "flatness"],
    "twosided": [], "mask": ["opacity"], "bumpmap": ["scale"], "normalmap": [],
  ]

  // MARK: BSDFs

  mutating func inputs(_ node: MitsubaImporter.Node) throws -> Inputs {
    let kind = node.type ?? "(no type)"
    if let known = Self.properties[kind] {
      for child in node.children where child.tag != "bsdf" {
        guard let property = child.name, !known.contains(property) else { continue }
        // The texture of a bumpmap or normalmap is its input, whatever its name.
        if (kind == "bumpmap" || kind == "normalmap") && child.tag == "texture" { continue }
        scene.note("\(name): \(kind) \(property) unsupported; ignored")
      }
    }
    func inner() throws -> MitsubaImporter.Node {
      guard let bsdf = node.children.first(where: { $0.tag == "bsdf" }) else {
        throw MitsubaImporter.error("material '\(name)': \(kind) has no inner BSDF")
      }
      return bsdf
    }
    var m = Inputs()
    switch kind {
    case "twosided":
      return try inputs(inner())
    case "bumpmap", "normalmap":
      m = try inputs(inner())
      let map = node.children.first { $0.tag == "texture" }
      guard let t = try map.flatMap({ try texture($0) }) else {
        scene.note("\(name): \(kind) texture unsupported; dropped")
        return m
      }
      if kind == "normalmap" {
        // Mitsuba's normal map is tangent-space (dp/du, dp/dv, n), as the app's normalmap node.
        m["geometry_normal"] = .normalMap(t)
      } else {
        m.bump = Inputs.Bump(texture: t, scale: node.float("scale") ?? 1)
      }
    case "mask":
      // OpenPBR geometry_opacity: coverage, stochastic in both renderers.
      m = try inputs(inner())
      switch try colour(node, "opacity", default: SIMD3(repeating: 1)) {
      case .texture(let t, _): m["geometry_opacity"] = .texture(t, tint: nil)
      case .color(let c) where c.sum() / 3 < 1: m["geometry_opacity"] = .value(c.sum() / 3)
      default: break
      }
    case "diffuse":
      m["base_color"] = try colour(node, "reflectance", default: SIMD3(repeating: 0.5))
      m["specular_weight"] = .value(0)
    case "plastic", "roughplastic":
      m = try plastic(node, rough: kind == "roughplastic")
    case "conductor", "roughconductor":
      m = try conductor(node, rough: kind == "roughconductor")
    case "dielectric", "roughdielectric", "thindielectric":
      m = try dielectric(node, kind: kind)
    case "principledthin":
      m = try principledThin(node)
    default:
      scene.note("\(name): BSDF \(kind) unsupported; grey diffuse used")
      m["base_color"] = .color(SIMD3(repeating: 0.5))
      m["specular_weight"] = .value(0)
    }
    return m
  }

  mutating func plastic(_ node: MitsubaImporter.Node, rough: Bool) throws -> Inputs {
    // OpenPBR's coated base has diffuse albedo rho' (1 - E_spec(mu)); Mitsuba's plastic scatters inside its coating.
    // rho' = rho r, with r = MitsubaImporter.plasticRatio (REFERENCES.md MITSUBA3).
    let eta = try MitsubaImporter.ior(node, "int_ior", default: 1.49) / MitsubaImporter.ior(node, "ext_ior", default: 1.000277)
    let nonlinear = node.bool("nonlinear") ?? false
    var alpha: Float?
    var ggx = false
    if rough {
      let a = scalar(node, "alpha", 0.1)
      if !a.isFinite { scene.note("\(name): alpha \(a) is not finite; the neutral plastic ratio 1 and alpha 0.1 used") }
      alpha = a
      ggx = try distribution(node)
    }
    let validIOR = eta.isFinite && eta > 0
    if !validIOR { scene.note("\(name): int_ior / ext_ior \(eta) is not a finite positive IOR; the neutral plastic ratio 1 and specular_ior 1.5 used") }
    func factor(_ rho: Float) -> Float { MitsubaImporter.plasticRatio(eta: eta, alpha: alpha, ggx: ggx, nonlinear: nonlinear, rho: rho) }
    var m = Inputs()
    switch try colour(node, "diffuse_reflectance", default: SIMD3(repeating: 0.5)) {
    case .texture(let t, _) where nonlinear:
      // The factor depends on rho: the texture is baked per texel and channel.
      m["base_color"] = .texture(try plasticTexture(t, factor: factor), tint: nil)
    case .texture(let t, _):
      m["base_color"] = .texture(t, tint: SIMD3(repeating: factor(0.5)))  // constant for a linear plastic
    case .color(let c):
      m["base_color"] = .color(SIMD3((0..<3).map { min(1, c[$0] * factor(c[$0])) }))
    default:
      break
    }
    if validIOR { m["specular_ior"] = .value(eta) }
    m["specular_roughness"] = .value(alpha.map { max($0.isFinite ? $0 : 0.1, 0).squareRoot() } ?? 0)
    return m
  }

  mutating func conductor(_ node: MitsubaImporter.Node, rough: Bool) throws -> Inputs {
    let (f0, tint) = try MitsubaImporter.conductor(node)
    var m = Inputs()
    m["base_metalness"] = .value(1)
    m["specular_roughness"] = .value(rough ? roughness(node) : 0)
    if rough { _ = try distribution(node) }
    // OpenPBR's metal Fresnel is Schlick from F0 with its 82-degree value tinted by specular_color.
    if tint.min() < 0.999 { m["specular_color"] = .color(tint) }
    // specular_reflectance scales Mitsuba's whole Fresnel, grazing angles included; OpenPBR's specular_weight scales
    // the metal lobe the same way. A colour keeps its chroma in base_color; a texture can only scale base_color (F0).
    switch try colour(node, "specular_reflectance", default: SIMD3(repeating: 1)) {
    case .texture(let t, _):
      m["base_color"] = .texture(t, tint: f0)
    case .color(let s):
      let weight = min(1, s.max())
      m["base_color"] = .color(f0 * (weight > 0 ? s / weight : SIMD3(repeating: 1)))
      if weight < 1 { m["specular_weight"] = .value(weight) }
    default:
      break
    }
    return m
  }

  mutating func dielectric(_ node: MitsubaImporter.Node, kind: String) throws -> Inputs {
    let eta = try MitsubaImporter.ior(node, "int_ior", default: 1.5046) / MitsubaImporter.ior(node, "ext_ior", default: 1.000277)
    var m = Inputs()
    if eta.isFinite && eta > 0 {
      m["specular_ior"] = .value(eta)
    } else {
      scene.note("\(name): int_ior / ext_ior \(eta) is not a finite positive IOR; specular_ior 1.5 used")
    }
    m["specular_roughness"] = .value(kind == "roughdielectric" ? roughness(node) : 0)
    if kind == "roughdielectric" { _ = try distribution(node) }
    let reflectance = try colour(node, "specular_reflectance", default: SIMD3(repeating: 1))
    if case .color(let c) = reflectance, c == SIMD3(repeating: 1) {} else {
      scene.note("\(name): \(kind) specular_reflectance unsupported; dropped")
    }
    let transmittance = try colour(node, "specular_transmittance", default: SIMD3(repeating: 1))
    if kind == "thindielectric" {
      // Both reflect 2R / (1 + R) of a pane's two interfaces and pass the rest straight through.
      m["transmission_weight"] = .value(1)
      m["base_color"] = .color(SIMD3(repeating: 1))
      m["geometry_thin_walled"] = .boolean(true)
    }
    var t = SIMD3<Float>(repeating: 1)
    switch transmittance {
    case .texture: scene.note("\(name): \(kind) specular_transmittance texture unsupported; white used")
    case .color(let c): t = c
    default: break
    }
    if kind != "thindielectric" {
      // specular_transmittance filters the refracted lobe; zero leaves a black reflector (a TV screen).
      if t.max() <= 0 {
        m["base_color"] = .color(.zero)
        return m
      }
      m["transmission_weight"] = .value(1)
      m["base_color"] = .color(SIMD3(repeating: 1))
    }
    if t.min() < 1 { m["transmission_color"] = .color(simd_min(t, SIMD3(repeating: 1))) }
    return m
  }

  // Mitsuba principledthin as a thin-walled OpenPBR surface (see scripts/mitsuba_to_usd.py).
  mutating func principledThin(_ node: MitsubaImporter.Node) throws -> Inputs {
    let base = try colour(node, "base_color", default: SIMD3(repeating: 0.5))
    let d = min(2, max(0, scalar(node, "diff_trans", 0)))
    let s = min(1, max(0, scalar(node, "spec_trans", 0)))
    var m = Inputs()
    m["geometry_thin_walled"] = .boolean(true)
    m["base_color"] = base
    m["specular_roughness"] = .value(scalar(node, "roughness", 0.5))
    m["specular_ior"] = .value(scalar(node, "eta", 1.5))
    m["specular_weight"] = .value(s)
    if d > 0 {
      m["subsurface_weight"] = .value(min(d, 1))
      m["subsurface_color"] = base
      if d > 1 { m["subsurface_scatter_anisotropy"] = .value(d - 1) }
    }
    if s > 0 {
      m["transmission_weight"] = .value(s)
      switch base {
      case .texture: scene.note("\(name): principledthin textured base_color does not tint its specular transmission")
      case .color(let c) where c.min() < 1: m["transmission_color"] = .color(simd_min(c, SIMD3(repeating: 1)))
      default: break
      }
    }
    for property in ["anisotropic", "spec_tint", "sheen", "flatness"] where scalar(node, property, 0) != 0 {
      scene.note("\(name): principledthin \(property) unsupported; dropped")
    }
    return m
  }

  // MARK: Properties

  // A constant float property; a texture is reported and replaced by the default.
  mutating func scalar(_ node: MitsubaImporter.Node, _ property: String, _ fallback: Float) -> Float {
    if node.child(property)?.tag == "texture" {
      scene.note("\(name): \(property) texture unsupported; \(fallback) used")
      return fallback
    }
    return node.float(property) ?? fallback
  }

  // sqrt(alpha), alpha 0.1 when absent; a non-finite alpha is reported and 0.1 used.
  mutating func roughness(_ node: MitsubaImporter.Node) -> Float {
    let alpha = scalar(node, "alpha", 0.1)
    guard alpha.isFinite else {
      scene.note("\(name): alpha \(alpha) is not finite; 0.1 used")
      return Float(0.1).squareRoot()
    }
    return max(alpha, 0).squareRoot()
  }

  // Whether the microfacet distribution is GGX. OpenPBR's is, so Beckmann (Mitsuba's default) is reported.
  mutating func distribution(_ node: MitsubaImporter.Node) throws -> Bool {
    switch node.string("distribution") ?? "beckmann" {
    case "ggx": return true
    case "beckmann":
      scene.note("Beckmann microfacet distributions are rendered as GGX at the same alpha")
      return false
    case let other: throw MitsubaImporter.error("material '\(name)': unknown distribution '\(other)'")
    }
  }

  // A colour property: a texture, or a constant (the default when absent or unreadable, which is reported).
  mutating func colour(_ node: MitsubaImporter.Node, _ property: String, default fallback: SIMD3<Float>) throws -> Inputs.Input {
    guard let p = node.child(property) else { return .color(fallback) }
    if p.tag == "texture" {
      if let t = try texture(p) { return .texture(t, tint: nil) }
      return .color(fallback)
    }
    guard let c = node.rgb(property) else {
      scene.note("\(name): \(p.tag) colour on \(node.type ?? "a BSDF") is not read; default used")
      return .color(fallback)
    }
    return .color(c)
  }

  // MARK: Textures

  // A bitmap (sRGB unless raw) or a baked checkerboard, with its to_uv scale; nil, reported, for other textures.
  mutating func texture(_ node: MitsubaImporter.Node) throws -> Inputs.Texture? {
    let toUV = node.transform("to_uv")
    let scale = SIMD2(toUV[0][0], toUV[1][1])
    switch node.type {
    case "bitmap":
      guard let file = node.url("filename") else { throw MitsubaImporter.error("material '\(name)': a bitmap texture has no filename") }
      guard FileManager.default.fileExists(atPath: file.path) else {
        throw MitsubaImporter.error("material '\(name)': texture file \(file.lastPathComponent) is missing")
      }
      return Inputs.Texture(file: file, srgb: node.bool("raw") != true, scale: scale)
    case "checkerboard":
      let c0 = node.rgb("color0") ?? SIMD3(repeating: 0.4), c1 = node.rgb("color1") ?? SIMD3(repeating: 0.2)
      let n = 256
      let even = Self.encoded(c0), odd = Self.encoded(c1)
      var pixels = [UInt8](repeating: 0, count: 3 * n * n)
      for y in 0..<n {
        for x in 0..<n {
          let c = (y / (n / 2) + x / (n / 2)) % 2 == 1 ? odd : even
          for k in 0..<3 { pixels[3 * (y * n + x) + k] = c[k] }
        }
      }
      let file = folder.appendingPathComponent("checker-\(Self.digest("\(c0) \(c1)")).png")
      try Self.writePNG(pixels, width: n, height: n, to: file, owner: name)
      scene.note("\(name): checkerboard baked to \(file.lastPathComponent) (\(n) px, 8-bit sRGB)")
      return Inputs.Texture(file: file, srgb: true, scale: scale)
    default:
      scene.note("\(name): texture \(node.type ?? "(no type)") unsupported; constant used")
      return nil
    }
  }

  // A nonlinear plastic's diffuse texture with rho' = rho r(rho) per texel and channel, r interpolated between
  // its values at 17 reflectances (an 8-bit sRGB PNG).
  mutating func plasticTexture(_ t: Inputs.Texture, factor: (Float) -> Float) throws -> Inputs.Texture {
    let image = try Self.texels(t.file, srgb: t.srgb, owner: name)
    let ratios = (0...16).map { factor(max(Float($0) / 16, 1e-3)) }
    func interpolated(_ x: Float) -> Float {
      let s = min(max(x, 0), 1) * 16, i = min(Int(s), 15)
      return ratios[i] + (ratios[i + 1] - ratios[i]) * (s - Float(i))
    }
    let pixels = image.values.flatMap { c in Self.encoded(SIMD3((0..<3).map { c[$0] * interpolated(c[$0]) })) }
    let file = folder.appendingPathComponent(
      "\(Self.identifier(name))-\(t.file.deletingPathExtension().lastPathComponent)-\(Self.digest("\(t.file.path) \(ratios)"))-plastic.png")
    try Self.writePNG(pixels, width: image.width, height: image.height, to: file, owner: name)
    scene.note("\(name): nonlinear plastic texture baked with its internal-scattering factor")
    return Inputs.Texture(file: file, srgb: true, scale: t.scale)
  }

  // Mitsuba's bumpmap as a tangent-space normal map: it displaces by d = scale x h (h the texel's luminance after
  // sRGB decoding unless raw) and shades with n' ~ n - (d_u / |dp/du|) T_u - (d_v / |dp/dv|) T_v (bumpmap.cpp).
  // |dp/du| and |dp/dv| are the area-weighted UV stretch of the mesh; the map holds (-d_u / |dp/du|,
  // +d_v / |dp/dv|, 1), since the app's bitangent follows v down the image and its normal map's green points up.
  mutating func normalMap(_ bump: Inputs.Bump, mesh: MitsubaImporter.Mesh, uvs: [SIMD2<Float>]) throws -> Inputs.Texture {
    let image = try Self.texels(bump.texture.file, srgb: bump.texture.srgb, owner: name)
    let w = image.width, h = image.height
    let height = image.values.map { simd_dot($0, SIMD3(0.2126, 0.7152, 0.0722)) }
    var lu = 0.0, lv = 0.0, area = 0.0
    for t in mesh.triangles {
      let p0 = mesh.positions[Int(t.x)], e1 = mesh.positions[Int(t.y)] - p0, e2 = mesh.positions[Int(t.z)] - p0
      let d1 = uvs[Int(t.y)] - uvs[Int(t.x)], d2 = uvs[Int(t.z)] - uvs[Int(t.x)]
      let det = d1.x * d2.y - d2.x * d1.y
      guard abs(det) > 1e-12 else { continue }
      let dpdu = (e1 * d2.y - e2 * d1.y) / det, dpdv = (e2 * d1.x - e1 * d2.x) / det
      let a = Double(simd_length(simd_cross(e1, e2)))
      lu += Double(simd_length(dpdu)) * a
      lv += Double(simd_length(dpdv)) * a
      area += a
    }
    lu /= max(area, 1e-12)
    lv /= max(area, 1e-12)
    // Central differences per unit of Mitsuba (u, v), wrapping like the default repeat filter.
    let su = bump.texture.scale.x, sv = bump.texture.scale.y
    let ku = bump.scale / Float(max(lu, 1e-12)), kv = bump.scale / Float(max(lv, 1e-12))
    var pixels = [UInt8](repeating: 0, count: 3 * w * h)
    for y in 0..<h {
      for x in 0..<w {
        let du = (height[y * w + (x + 1) % w] - height[y * w + (x + w - 1) % w]) / 2 * Float(w) * su
        let dv = (height[(y + 1) % h * w + x] - height[(y + h - 1) % h * w + x]) / 2 * Float(h) * sv
        let n = simd_normalize(SIMD3(-ku * du, kv * dv, 1))
        for k in 0..<3 { pixels[3 * (y * w + x) + k] = UInt8(min(max(n[k] * 0.5 + 0.5, 0), 1) * 255 + 0.5) }
      }
    }
    let file = folder.appendingPathComponent(
      "\(Self.identifier(name))-\(Self.digest("\(bump.texture.file.path) \(bump.scale) \(su) \(sv) \(lu) \(lv)"))-bump-normal.png")
    try Self.writePNG(pixels, width: w, height: h, to: file, owner: name)
    scene.note("\(name): bump map converted to a normal map (UV stretch \(String(format: "%.3g", lu)) x \(String(format: "%.3g", lv)))")
    return Inputs.Texture(file: file, srgb: false, scale: SIMD2(1, 1))
  }

  // MARK: Interior medium

  // A homogeneous medium that only absorbs (albedo 0; in Mitsuba 0.6, sigma_s 0 with sigma_a), behind a BSDF that
  // refracts into it, as OpenPBR's transmission_color exp(-sigma_t) at transmission_depth 1; anything else is
  // reported and ignored.
  mutating func medium(_ node: MitsubaImporter.Node, into m: inout Inputs) {
    let kind = node.type ?? "(no type)"
    var extinction: SIMD3<Float>?
    if kind == "homogeneous" {
      if node.child("sigma_s") != nil || node.child("sigma_a") != nil {
        if let s = node.rgb("sigma_s"), s == .zero, let a = node.rgb("sigma_a") { extinction = a }
      } else if node.rgb("albedo") == .zero {
        extinction = node.child("sigma_t") == nil ? SIMD3(repeating: 1) : node.rgb("sigma_t")
      }
      extinction = extinction.map { $0 * (node.float("scale") ?? 1) }
    }
    guard let sigma = extinction, (0..<3).allSatisfy({ sigma[$0].isFinite && sigma[$0] >= 0 }) else {
      scene.note("\(name): interior medium \(kind) unsupported (only an absorbing homogeneous medium is read); ignored")
      return
    }
    guard (m.value("transmission_weight") ?? 0) > 0, m["geometry_thin_walled"] == nil else {
      scene.note("\(name): interior medium ignored (its BSDF does not refract)")
      return
    }
    if m["transmission_color"] != nil { scene.note("\(name): specular_transmittance replaced by the interior medium's absorption") }
    m["transmission_color"] = .color(SIMD3((0..<3).map { exp(-sigma[$0]) }))
    m["transmission_depth"] = .value(1)
  }

  // MARK: Images

  // A texture's linear RGB texels, rows from the top: integer formats are normalized and sRGB decoded when `srgb`,
  // float formats are read as stored; grey images repeat their channel and alpha is dropped, as the converter read
  // them through Mitsuba's Bitmap.
  static func texels(_ url: URL, srgb: Bool, owner: String) throws -> (width: Int, height: Int, values: [SIMD3<Float>]) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width > 0, image.height > 0, image.width <= 16384, image.height <= 16384
    else { throw MitsubaImporter.error("material '\(owner)': cannot decode \(url.lastPathComponent)") }
    let w = image.width, h = image.height
    let gray = image.colorSpace?.model == .monochrome
    let own = image.colorSpace.flatMap { [.monochrome, .rgb].contains($0.model) ? $0 : nil }
    let space = own ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let channels = gray ? 1 : 4
    var stored = [Float](repeating: 0, count: channels * w * h)
    let drawn = stored.withUnsafeMutableBytes { bytes -> Bool in
      let alpha = gray ? CGImageAlphaInfo.none : CGImageAlphaInfo.noneSkipLast
      guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: 4 * channels * w,
        space: space, bitmapInfo: alpha.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { throw MitsubaImporter.error("material '\(owner)': cannot read \(url.lastPathComponent)") }
    let decode = srgb && !image.bitmapInfo.contains(.floatComponents)
    func linear(_ v: Float) -> Float { decode ? (v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)) : v }
    let values = (0..<(w * h)).map { i in
      gray ? SIMD3(repeating: linear(stored[i])) : SIMD3(linear(stored[4 * i]), linear(stored[4 * i + 1]), linear(stored[4 * i + 2]))
    }
    return (w, h, values)
  }

  // A linear colour as 8-bit sRGB (clamped to 0-1), rounded as the converter did.
  static func encoded(_ c: SIMD3<Float>) -> [UInt8] {
    (0..<3).map { k in
      let x = min(max(c[k], 0), 1)
      return UInt8((x <= 0.0031308 ? 12.92 * x : 1.055 * powf(x, 1 / 2.4) - 0.055) * 255 + 0.5)
    }
  }

  static func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL, owner: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
      hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 3 * width, bitsPerPixel: 24)!
    pixels.withUnsafeBytes { rep.bitmapData!.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: pixels.count) }
    guard let png = rep.representation(using: .png, properties: [:]) else {
      throw MitsubaImporter.error("material '\(owner)': cannot write \(url.lastPathComponent)")
    }
    try png.write(to: url)
  }

  // A file-name fragment: characters other than letters, digits and underscores become underscores.
  static func identifier(_ text: String) -> String {
    String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
  }

  // FNV-1a (64-bit) of the inputs a baked image is made from, so images with different contents get different names.
  static func digest(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
    return String(hash, radix: 16)
  }
}
