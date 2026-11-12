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
//                        specular_weight (its chroma kept in base_color; a grey texture is connected to
//                        specular_weight, a coloured one multiplies base_color instead)
//   dielectric/rough...  transmission_weight 1, specular_ior = int_ior (1.5046) / ext_ior (1.000277) (below 1: its
//                        inverse, with the shape's facing reversed by MitsubaImporter.load), specular_transmittance
//                        as transmission_color, and zero as a black reflector
//   thindielectric       the same with geometry_thin_walled
//   principledthin       thin-walled; base_color, diff_trans as subsurface weight and anisotropy, spec_trans as
//                        transmission_weight and specular_weight, roughness, eta
//   twosided             its (first) inner BSDF; mask: geometry_opacity = opacity (a texture, or a constant's mean)
//   bumpmap              the inner BSDF with the height map as a tangent-space normal map, from the mesh's UV stretch
//   normalmap            the inner BSDF with its texture as the normal map
//   bitmap               an image node (sRGB unless raw) sampled at Mitsuba's (s_u u, s_v v) for the to_uv scale (the
//                        converter's sampling differed for a non-integer s_v), normal maps too; checkerboard: a
//                        256 px 8-bit sRGB PNG of color0 (0.4) and color1 (0.2) in the import folder
//   no BSDF              grey diffuse 0.5, or black when the shape emits (Mitsuba's Shape default)
//   area emitter         emission_color x emission_luminance = the radiance
//   interior medium      homogeneous with albedo 0 (Mitsuba 0.6: sigma_s 0) behind a refracting BSDF:
//                        transmission_color exp(-sigma_t x scale) at transmission_depth 1
// Unsupported BSDFs, textures and properties, and every approximation, add a report line, as do values that are not
// finite (the default used) or negative where that is meaningless (0 used). Baked images are at most bakeTexels.
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
    if var radiance = emission {
      if (0..<3).contains(where: { !radiance[$0].isFinite }) {
        builder.scene.note("\(name): radiance is not a finite number; 0 used for those channels")
        radiance = SIMD3((0..<3).map { radiance[$0].isFinite ? radiance[$0] : 0 })
      }
      if radiance.min() < 0 {
        builder.scene.note("\(name): radiance is negative; 0 used for those channels")
        radiance = simd_max(radiance, .zero)
      }
      let scale = max(radiance.max(), 1e-12)
      // The compiler accepts constants below 1e8, which the renderer's emission clamp also is.
      if scale >= 1e8 { builder.scene.note("\(name): radiance above 1e8 is clamped to it") }
      inputs["emission_color"] = .color(radiance / scale)
      inputs["emission_luminance"] = .value(min(scale, 99_999_992))
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
    // Texture coordinates for a to_uv scale (nil for none). MaterialX's t is (u, 1 - v) and the image is sampled at
    // (t'x, 1 - t'y), so t' = s t + (0, 1 - s_v) samples the image at Mitsuba's (s_u u, s_v v), whatever s_v.
    func coordinates(_ scale: SIMD2<Float>) -> String? {
      guard scale != SIMD2(1, 1) else { return nil }
      let uv = w.op("texcoord", "vector2", [])
      let scaled = w.op("multiply", "vector2", [("in1", .node(uv, "vector2"))], extra: [("in2", "vector2", "\(scale.x), \(scale.y)")])
      guard scale.y != 1 else { return scaled }
      return w.op("add", "vector2", [("in1", .node(scaled, "vector2"))], extra: [("in2", "vector2", "0.0, \(1 - scale.y)")])
    }
    var values: [(String, GLTFImporter.Writer.Value)] = []
    for (name, input) in list {
      switch input {
      case .value(let v): values.append((name, .float(v)))
      case .color(let c): values.append((name, .color(c)))
      case .boolean(let b): values.append((name, .boolean(b)))
      case .texture(let t, let tint):
        // MaterialX leaves float images raw, so specular_weight is the red channel of the colour-managed image, as
        // Mitsuba decodes a bitmap unless raw.
        let weight = name == "specular_weight"
        let type = name == "geometry_opacity" ? "float" : "color3"
        let node = w.image(t.file.path, type: type, colorspace: t.srgb ? "srgb_texture" : "raw", uv: coordinates(t.scale),
                           u: "periodic", v: "periodic")
        if weight {
          values.append((name, .node(w.op("extract", "float", [("in", .node(node, type)), ("index", .integer(0))]), "float")))
        } else if let tint {
          values.append((name, .node(w.op("multiply", type, [("in1", .node(node, type)), ("in2", .color(tint))]), type)))
        } else {
          values.append((name, .node(node, type)))
        }
      case .normalMap(let t):
        let node = w.image(t.file.path, type: "vector3", colorspace: "raw", uv: coordinates(t.scale), u: "periodic", v: "periodic")
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
      let sides = node.children.filter { $0.tag == "bsdf" }
      if sides.count > 1, sides[0].id == nil || sides[1].id != sides[0].id {
        scene.note("\(name): twosided back-side BSDF unsupported; the front BSDF used on both sides")
      }
      return try inputs(inner())
    case "bumpmap", "normalmap":
      m = try inputs(inner())
      let map = node.children.first { $0.tag == "texture" }
      guard let t = try map.flatMap({ try texture($0, property: $0.name ?? "map") }) else {
        scene.note("\(name): \(kind) texture unsupported; dropped")
        return m
      }
      if kind == "normalmap" {
        // Mitsuba's normal map is tangent-space (dp/du, dp/dv, n), as the app's normalmap node.
        m["geometry_normal"] = .normalMap(t)
      } else {
        m.bump = Inputs.Bump(texture: t, scale: scalar(node, "scale", 1))
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
      // A non-finite alpha gives the neutral ratio (plasticRatio) and the default roughness.
      if node.child("alpha")?.tag != "texture", let a = node.float("alpha"), !a.isFinite {
        scene.note("\(name): alpha \(a) is not finite; the neutral plastic ratio 1 and alpha 0.1 used")
        alpha = a
      } else {
        alpha = nonNegative(scalar(node, "alpha", 0.1), "alpha")
      }
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
    m["specular_roughness"] = .value(alpha.map { ($0.isFinite ? $0 : 0.1).squareRoot() } ?? 0)
    return m
  }

  mutating func conductor(_ node: MitsubaImporter.Node, rough: Bool) throws -> Inputs {
    var (f0, tint) = try MitsubaImporter.conductor(node)
    if !(0..<3).allSatisfy({ f0[$0].isFinite && tint[$0].isFinite }) {
      scene.note("\(name): conductor eta or k is not a finite number; the default conductor (a mirror) used")
      (f0, tint) = (SIMD3(repeating: 1), SIMD3(repeating: 1))
    }
    var m = Inputs()
    m["base_metalness"] = .value(1)
    m["specular_roughness"] = .value(rough ? roughness(node) : 0)
    if rough { _ = try distribution(node) }
    // OpenPBR's metal Fresnel is Schlick from F0 with its 82-degree value tinted by specular_color.
    if tint.min() < 0.999 { m["specular_color"] = .color(tint) }
    // specular_reflectance scales Mitsuba's whole Fresnel, grazing angles included; OpenPBR's specular_weight scales
    // the metal lobe the same way. A colour keeps its chroma in base_color; a grey texture is a connected
    // specular_weight, while a coloured one can only scale base_color (F0).
    switch try colour(node, "specular_reflectance", default: SIMD3(repeating: 1)) {
    case .texture(let t, _):
      if try Self.isGrey(t, owner: name) {
        m["base_color"] = .color(f0)
        m["specular_weight"] = .texture(t, tint: nil)
      } else {
        m["base_color"] = .texture(t, tint: f0)
        scene.note("\(name): coloured specular_reflectance texture scales F0 only")
      }
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
      // Below 1, the same interface from its other side (MitsubaImporter.invertedDielectric).
      m["specular_ior"] = .value(eta < 1 ? 1 / eta : eta)
      if eta < 1 {
        scene.note("\(name): int_ior / ext_ior \(eta) is below 1; rendered as \(1 / eta)"
          + (kind == "thindielectric" ? "" : " with the shape's facing reversed"))
      }
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
    m["specular_roughness"] = .value(nonNegative(scalar(node, "roughness", 0.5), "roughness"))
    var eta = scalar(node, "eta", 1.5)
    if eta <= 0 {
      scene.note("\(name): eta \(eta) is not positive; 1.5 used")
      eta = 1.5
    }
    m["specular_ior"] = .value(eta)
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

  // A constant float property; a texture or a non-finite value is reported and replaced by the default.
  mutating func scalar(_ node: MitsubaImporter.Node, _ property: String, _ fallback: Float) -> Float {
    if node.child(property)?.tag == "texture" {
      scene.note("\(name): \(property) texture unsupported; \(fallback) used")
      return fallback
    }
    guard let value = node.float(property) else { return fallback }
    guard value.isFinite else {
      scene.note("\(name): \(property) is not a finite number; \(fallback) used")
      return fallback
    }
    return value
  }

  // A value that cannot be negative; a negative one is reported and 0 used.
  mutating func nonNegative(_ value: Float, _ property: String) -> Float {
    guard value < 0 else { return value }
    scene.note("\(name): \(property) \(value) is negative; 0 used")
    return 0
  }

  // sqrt(alpha), alpha 0.1 when absent.
  mutating func roughness(_ node: MitsubaImporter.Node) -> Float {
    nonNegative(scalar(node, "alpha", 0.1), "alpha").squareRoot()
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

  // A colour property: a texture, or a constant (constant(_:_:default:)).
  mutating func colour(_ node: MitsubaImporter.Node, _ property: String, default fallback: SIMD3<Float>) throws -> Inputs.Input {
    if let p = node.child(property), p.tag == "texture" {
      if let t = try texture(p, property: property) { return .texture(t, tint: nil) }
      return .color(fallback)
    }
    return .color(constant(node, property, default: fallback))
  }

  // A constant colour: the default when absent; an unreadable or non-finite one is reported and the default used,
  // negative components are reported and 0 used.
  mutating func constant(_ node: MitsubaImporter.Node, _ property: String, default fallback: SIMD3<Float>) -> SIMD3<Float> {
    guard let p = node.child(property) else { return fallback }
    guard let c = node.rgb(property) else {
      scene.note("\(name): \(p.tag) colour on \(node.type ?? "a BSDF") is not read; default used")
      return fallback
    }
    guard (0..<3).allSatisfy({ c[$0].isFinite }) else {
      scene.note("\(name): \(property) is not a finite number; default used")
      return fallback
    }
    guard c.min() < 0 else { return c }
    scene.note("\(name): \(property) is negative; 0 used for those channels")
    return simd_max(c, .zero)
  }

  // MARK: Textures

  // The texture properties each type's mapping reads; others are reported.
  static let textureProperties: [String: Set<String>] = [
    "bitmap": ["filename", "raw", "to_uv", "wrap_mode", "filter_type"], "checkerboard": ["color0", "color1", "to_uv"],
  ]

  // A bitmap (sRGB unless raw) or a baked checkerboard, with the scale of its to_uv; nil, reported, for other textures.
  // `property` is the BSDF property it feeds, for the report.
  mutating func texture(_ node: MitsubaImporter.Node, property: String) throws -> Inputs.Texture? {
    let kind = node.type ?? "(no type)"
    guard let known = Self.textureProperties[kind] else {
      scene.note("\(name): texture \(kind) unsupported; constant used")
      return nil
    }
    for child in node.children {
      guard let other = child.name, !known.contains(other) else { continue }
      scene.note("\(name): \(property) texture \(kind) \(other) unsupported; ignored")
    }
    let toUV = node.transform("to_uv")
    var scale = SIMD2(toUV[0][0], toUV[1][1])
    if !(scale.x.isFinite && scale.y.isFinite) {
      scene.note("\(name): \(property) texture to_uv is not a finite number; scale 1 used")
      scale = SIMD2(1, 1)
    } else if toUV[1][0] != 0 || toUV[0][1] != 0 || toUV[3][0] != 0 || toUV[3][1] != 0 {
      scene.note("\(name): \(property) texture to_uv offset or rotation unsupported; only its scale (\(scale.x), \(scale.y)) used")
    }
    switch kind {
    case "bitmap":
      guard let file = node.url("filename") else { throw MitsubaImporter.error("material '\(name)': a bitmap texture has no filename") }
      guard FileManager.default.fileExists(atPath: file.path) else {
        throw MitsubaImporter.error("material '\(name)': texture file \(file.lastPathComponent) is missing")
      }
      if let mode = node.string("wrap_mode"), mode != "repeat" {
        scene.note("\(name): \(property) texture wrap_mode \(mode) unsupported; repeat used")
      }
      if node.string("filter_type") == "nearest" {
        scene.note("\(name): \(property) texture filter_type nearest unsupported; bilinear used")
      }
      return Inputs.Texture(file: file, srgb: node.bool("raw") != true, scale: scale)
    default:
      // A 256 px checkerboard of 128 px squares, color0 at the top left.
      func colour(_ key: String, _ fallback: Float) -> SIMD3<Float> {
        guard node.child(key)?.tag != "texture" else {
          scene.note("\(name): checkerboard \(key) texture unsupported; \(fallback) used")
          return SIMD3(repeating: fallback)
        }
        return constant(node, key, default: SIMD3(repeating: fallback))
      }
      let c0 = colour("color0", 0.4), c1 = colour("color1", 0.2)
      let n = 256
      let even = (0..<3).map { Self.encoded(c0[$0]) }, odd = (0..<3).map { Self.encoded(c1[$0]) }
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
    }
  }

  // A nonlinear plastic's diffuse texture with rho' = rho r(rho) per texel and channel, r interpolated between
  // its values at 17 reflectances (an 8-bit sRGB PNG).
  mutating func plasticTexture(_ t: Inputs.Texture, factor: (Float) -> Float) throws -> Inputs.Texture {
    let image = try Self.image(t.file, owner: name)
    let ratios = (0...16).map { factor(max(Float($0) / 16, 1e-3)) }
    var pixels = [UInt8](repeating: 0, count: 3 * image.width * image.height)
    try pixels.withUnsafeMutableBufferPointer { out in
      try ratios.withUnsafeBufferPointer { r in
        func baked(_ x: Float) -> UInt8 {
          let s = min(max(x, 0), 1) * 16, i = min(Int(s), 15)
          return Self.encoded(x * (r[i] + (r[i + 1] - r[i]) * (s - Float(i))))
        }
        try Self.forEachTexel(image, srgb: t.srgb, owner: name) { i, red, green, blue in
          out[3 * i] = baked(red); out[3 * i + 1] = baked(green); out[3 * i + 2] = baked(blue)
        }
      }
    }
    let file = folder.appendingPathComponent(Self.fileName(
      [name, t.file.deletingPathExtension().lastPathComponent], Self.digest("\(t.file.path) \(ratios)"), "plastic"))
    try Self.writePNG(pixels, width: image.width, height: image.height, to: file, owner: name)
    scene.note("\(name): nonlinear plastic texture baked with its internal-scattering factor")
    return Inputs.Texture(file: file, srgb: true, scale: t.scale)
  }

  // Mitsuba's bumpmap as a tangent-space normal map: it displaces by d = scale x h (h the texel's luminance after
  // sRGB decoding unless raw) and shades with n' ~ n - (d_u / |dp/du|) T_u - (d_v / |dp/dv|) T_v (bumpmap.cpp).
  // |dp/du| and |dp/dv| are the area-weighted UV stretch of the mesh; the map holds (-d_u / |dp/du|,
  // +d_v / |dp/dv|, 1), since the app's bitangent follows v down the image and its normal map's green points up.
  // It is sampled with the height map's to_uv scale, which the derivatives include.
  mutating func normalMap(_ bump: Inputs.Bump, mesh: MitsubaImporter.Mesh, uvs: [SIMD2<Float>]) throws -> Inputs.Texture {
    let image = try Self.image(bump.texture.file, owner: name)
    let w = image.width, h = image.height
    var height = [Float](repeating: 0, count: w * h)
    try height.withUnsafeMutableBufferPointer { out in
      try Self.forEachTexel(image, srgb: bump.texture.srgb, owner: name) { i, red, green, blue in
        out[i] = 0.2126 * red + 0.7152 * green + 0.0722 * blue
      }
    }
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
        let o = 3 * (y * w + x)
        pixels[o] = UInt8(min(max(n.x * 0.5 + 0.5, 0), 1) * 255 + 0.5)
        pixels[o + 1] = UInt8(min(max(n.y * 0.5 + 0.5, 0), 1) * 255 + 0.5)
        pixels[o + 2] = UInt8(min(max(n.z * 0.5 + 0.5, 0), 1) * 255 + 0.5)
      }
    }
    let file = folder.appendingPathComponent(Self.fileName(
      [name], Self.digest("\(bump.texture.file.path) \(bump.scale) \(su) \(sv) \(lu) \(lv)"), "bump-normal"))
    try Self.writePNG(pixels, width: w, height: h, to: file, owner: name)
    scene.note("\(name): bump map converted to a normal map (UV stretch \(String(format: "%.3g", lu)) x \(String(format: "%.3g", lv)))")
    return Inputs.Texture(file: file, srgb: false, scale: bump.texture.scale)
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
      let scale = scalar(node, "scale", 1)
      extinction = extinction.map { $0 * scale }
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

  // Images baked from a texture are at most 64 megapixels (8192 x 8192): a bake holds the decoded image and an
  // 8-bit output (about 700 MB for 16-bit RGBA sources at the limit).
  static let bakeTexels = 1 << 26

  // A texture to bake, checked against bakeTexels.
  static func image(_ url: URL, owner: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width > 0, image.height > 0
    else { throw MitsubaImporter.error("material '\(owner)': cannot decode \(url.lastPathComponent)") }
    guard image.width * image.height <= bakeTexels else {
      throw MitsubaImporter.error("material '\(owner)': texture \(url.lastPathComponent) is too large to bake (\(image.width) × \(image.height))")
    }
    return image
  }

  // Whether every texel of the texture has equal red, green and blue.
  static func isGrey(_ t: Inputs.Texture, owner: String) throws -> Bool {
    var grey = true
    try forEachTexel(try image(t.file, owner: owner), srgb: t.srgb, owner: owner) { _, red, green, blue in
      if red != green || green != blue { grey = false }
    }
    return grey
  }

  // Calls `body` with each texel's index (rows from the top) and linear RGB: integer formats are normalized and sRGB
  // decoded when `srgb`, float formats are read as stored; grey images repeat their channel and alpha is ignored, as
  // the converter read them through Mitsuba's Bitmap. 8- and 16-bit RGB and grey images are read as stored (no
  // colour management); others are drawn into a float context in their own colour space (sRGB when not RGB or grey)
  // and un-premultiplied.
  static func forEachTexel(_ image: CGImage, srgb: Bool, owner: String, _ body: (Int, Float, Float, Float) -> Void) throws {
    let w = image.width, h = image.height
    if let layout = StoredLayout(image), let data = image.dataProvider?.data {
      let maximum = layout.bits == 8 ? 255 : 65535
      let table = (0...maximum).map { v -> Float in
        let x = Float(v) / Float(maximum)
        return srgb ? (x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)) : x
      }
      let rowBytes = image.bytesPerRow, pixelBytes = image.bitsPerPixel / 8, colourCount = layout.colours
      guard CFDataGetLength(data) >= (h - 1) * rowBytes + w * pixelBytes else {
        throw MitsubaImporter.error("material '\(owner)': cannot read a texture's pixels")
      }
      let bytes = CFDataGetBytePtr(data)!
      table.withUnsafeBufferPointer { table in
        for y in 0..<h {
          for x in 0..<w {
            let pixel = bytes + y * rowBytes + x * pixelBytes
            func component(_ k: Int) -> Int {
              let m = layout.memoryIndex[k]
              if layout.bits == 8 { return Int(pixel[m]) }
              let hi = Int(pixel[2 * m]), lo = Int(pixel[2 * m + 1])
              return layout.littleEndian ? lo << 8 | hi : hi << 8 | lo
            }
            var c = SIMD3<Float>(repeating: table[component(0)])
            if colourCount == 3 { c = SIMD3(table[component(0)], table[component(1)], table[component(2)]) }
            if layout.premultiplied {
              // Stored values times alpha: undo it before decoding.
              let a = Float(component(colourCount)) / Float(maximum)
              func value(_ k: Int) -> Float {
                let x = Float(component(k)) / Float(maximum), u = a > 0 ? min(1, x / a) : x
                return srgb ? (u <= 0.04045 ? u / 12.92 : powf((u + 0.055) / 1.055, 2.4)) : u
              }
              c = colourCount == 3 ? SIMD3(value(0), value(1), value(2)) : SIMD3(repeating: value(0))
            }
            body(y * w + x, c.x, c.y, c.z)
          }
        }
      }
      return
    }
    // Other formats (float, palette, other colour spaces): drawn as premultiplied float RGBA.
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    var stored = [Float](repeating: 0, count: 4 * w * h)
    let drawn = stored.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: 16 * w, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { throw MitsubaImporter.error("material '\(owner)': cannot read a texture's pixels") }
    let decode = srgb && !image.bitmapInfo.contains(.floatComponents)
    func linear(_ v: Float) -> Float { decode ? (v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)) : v }
    for i in 0..<(w * h) {
      let a = stored[4 * i + 3], scale: Float = a > 0 ? 1 / a : 1
      body(i, linear(stored[4 * i] * scale), linear(stored[4 * i + 1] * scale), linear(stored[4 * i + 2] * scale))
    }
  }

  // Where an 8- or 16-bit RGB or grey image keeps its components: memoryIndex[k] is the slot of colour k (then alpha).
  struct StoredLayout {
    let bits: Int, colours: Int, premultiplied: Bool, littleEndian: Bool
    let memoryIndex: [Int]

    init?(_ image: CGImage) {
      let model = image.colorSpace?.model
      guard !image.bitmapInfo.contains(.floatComponents), image.bitsPerComponent == 8 || image.bitsPerComponent == 16,
        model == .rgb || model == .monochrome
      else { return nil }
      bits = image.bitsPerComponent
      colours = model == .rgb ? 3 : 1
      let info = image.alphaInfo
      let slots = colours + (info == .none ? 0 : 1)
      guard image.bitsPerPixel == slots * bits else { return nil }
      premultiplied = info == .premultipliedFirst || info == .premultipliedLast
      let alphaFirst = info == .first || info == .premultipliedFirst || info == .noneSkipFirst
      // Logical order: colours then alpha, or alpha first.
      var logical = Array(0..<slots)
      if alphaFirst { logical = Array(1..<slots) + [0] }
      let order = image.bitmapInfo.intersection(.byteOrderMask)
      var reversed = false, little = false
      switch (bits, order) {
      case (_, []), (_, .byteOrder32Big), (16, .byteOrder16Big), (8, .byteOrder16Big): break
      case (8, .byteOrder32Little) where slots == 4, (8, .byteOrder16Little) where slots == 2: reversed = true
      case (16, .byteOrder16Little): little = true
      default: return nil
      }
      littleEndian = little
      memoryIndex = logical.map { reversed ? slots - 1 - $0 : $0 }
    }
  }

  // A linear value as 8-bit sRGB (clamped to 0-1), rounded as the converter did.
  static func encoded(_ value: Float) -> UInt8 {
    let x = min(max(value, 0), 1)
    return UInt8((x <= 0.0031308 ? 12.92 * x : 1.055 * powf(x, 1 / 2.4) - 0.055) * 255 + 0.5)
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

  // A baked image's file name: the readable parts (letters, digits and underscores kept, the rest underscores),
  // shortened to keep the name well within 255 bytes, then the digest that makes it unique, then the kind.
  static func fileName(_ parts: [String], _ digest: String, _ kind: String) -> String {
    let readable = parts.map { String($0.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" }) }
    return "\(String(readable.joined(separator: "-").prefix(120)))-\(digest)-\(kind).png"
  }

  // FNV-1a (64-bit) of the inputs a baked image is made from, so images with different contents get different names.
  static func digest(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
    return String(hash, radix: 16)
  }
}
