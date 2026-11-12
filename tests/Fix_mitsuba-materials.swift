// Mitsuba materials (MitsubaImporter.material) beyond Fix_mitsuba.swift's mapping rows: the baked images' texels
// against the converter's formulas (bump normal maps, nonlinear plastics), principledthin, textured masks and
// plastics, conductor chroma, normal maps, transmission colours, IOR ratios below 1,
// values that are not finite or negative, texture properties the mapping does not read, to_uv sampling (Mitsuba's
// rows for any v scale) and the bake size limit.
@MainActor func fixMitsubaMaterialChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("mitsuba-materials", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  let bakes = folder.appendingPathComponent("bakes", isDirectory: true)
  try FileManager.default.createDirectory(at: bakes, withIntermediateDirectories: true)
  var count = 0
  func bsdf(_ xml: String) throws -> MitsubaImporter.Node {
    count += 1
    let url = folder.appendingPathComponent("bsdf\(count).xml")
    try #"<scene version="3.0.0">\#(xml)</scene>"#.write(to: url, atomically: true, encoding: .utf8)
    return try MitsubaImporter.Scene(url: url).root.children[0]
  }
  let sceneURL = folder.appendingPathComponent("scene.xml")
  try #"<scene version="3.0.0"/>"#.write(to: sceneURL, atomically: true, encoding: .utf8)
  var scene = try MitsubaImporter.Scene(url: sceneURL)
  func document(_ xml: String?, emission: SIMD3<Float>? = nil, name: String = "m", mesh: MitsubaImporter.Mesh? = nil) throws -> String {
    let node = try xml.map { try bsdf($0) }
    return try MitsubaImporter.material(bsdf: node, emission: emission, interior: nil, name: name, scene: &scene, folder: bakes, mesh: mesh)
  }
  func compiled(_ text: String) throws -> MaterialXProgram {
    let result = try MaterialXImporter.read(Data(text.utf8), baseURL: bakes, source: "mitsuba")
    guard let program = result.materials.first else { throw MaterialLibrary.error("the document does not compile: \(result.report)") }
    return program
  }
  func program(_ xml: String?, emission: SIMD3<Float>? = nil, name: String = "m") throws -> MaterialXProgram {
    try compiled(document(xml, emission: emission, name: name))
  }
  func input(_ p: MaterialXProgram, _ name: String) -> SIMD3<Float>? {
    p.parameters.first { $0.name.hasSuffix("/" + name) }.flatMap { $0.defaultValue }.map { SIMD3($0.x, $0.y, $0.z) }
  }
  func near(_ a: SIMD3<Float>?, _ b: SIMD3<Float>, _ tolerance: Float = 1e-5) -> Bool { a.map { simd_length($0 - b) < tolerance } ?? false }
  func reported(_ line: String) -> Bool { scene.report.contains(line) }
  func reported(prefix: String) -> Bool { scene.report.contains { $0.hasPrefix(prefix) } }
  func requireThrows(_ fragment: String, _ body: () throws -> Void) {
    do { try body() } catch {
      require(error.localizedDescription.contains(fragment), "error mentions '\(fragment)' (got \(error.localizedDescription))")
      return
    }
    require(false, "expected an error mentioning '\(fragment)'")
  }
  // An 8-bit PNG in `folder`: RGB, or RGBA with straight (not premultiplied) alpha.
  func png(_ name: String, width: Int = 4, height: Int = 4, alpha: UInt8? = nil, _ texel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws {
    let samples = alpha == nil ? 3 : 4
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: samples,
      hasAlpha: alpha != nil, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: alpha == nil ? [] : .alphaNonpremultiplied,
      bytesPerRow: samples * width, bitsPerPixel: 8 * samples)!
    for y in 0..<height {
      for x in 0..<width {
        let c = texel(x, y), o = samples * (y * width + x)
        rep.bitmapData![o] = c.0; rep.bitmapData![o + 1] = c.1; rep.bitmapData![o + 2] = c.2
        if let alpha { rep.bitmapData![o + 3] = alpha }
      }
    }
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
  }
  // The 8-bit RGB of a baked PNG's texel.
  func texel(_ url: URL, _ x: Int, _ y: Int) -> SIMD3<Int>? {
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data), let pixels = rep.bitmapData else { return nil }
    // Decoded PNGs may hold an alpha sample first.
    let o = y * rep.bytesPerRow + x * rep.bitsPerPixel / 8 + (rep.hasAlpha && rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0)
    return SIMD3(Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2]))
  }
  func baked(_ suffix: String, _ prefix: String) throws -> URL? {
    try FileManager.default.contentsOfDirectory(atPath: bakes.path).first { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
      .map { bakes.appendingPathComponent($0) }
  }
  func srgb(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4) }
  func encode(_ x: Float) -> Int { let x = min(max(x, 0), 1); return Int((x <= 0.0031308 ? 12.92 * x : 1.055 * powf(x, 1 / 2.4) - 0.055) * 255 + 0.5) }
  let quad = MitsubaImporter.Mesh(positions: [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)], normals: nil,
    uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], triangles: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)])

  // Bump map: heights h = (40 x + 20 y) / 255 (raw) on a 4 x 4 image over a 2 x 2 quad (UV stretch 2). The converter's
  // bump_normal_map at texel (1, 1): d_u = (h(2, 1) - h(0, 1)) / 2 x 4, d_v = (h(1, 2) - h(1, 0)) / 2 x 4, and the map
  // holds normalize(-d_u / 2, +d_v / 2, 1) as 8-bit (n / 2 + 1 / 2).
  try png("ramp.png") { x, y in let v = UInt8(40 * x + 20 * y); return (v, v, v) }
  _ = try compiled(document("""
    <bsdf type="bumpmap"><texture type="bitmap" name="map"><string name="filename" value="ramp.png"/><boolean name="raw" value="true"/></texture>
      <bsdf type="diffuse"/></bsdf>
    """, name: "ramp", mesh: quad))
  let du: Float = (80.0 / 255) / 2 * 4, dv: Float = (40.0 / 255) / 2 * 4
  let n = simd_normalize(SIMD3(-du / 2, dv / 2, 1))
  let expectedNormal = SIMD3((0..<3).map { Int((n[$0] * 0.5 + 0.5) * 255 + 0.5) })
  let normal = try baked("-bump-normal.png", "ramp").flatMap { texel($0, 1, 1) }
  require(normal.map { simd_reduce_max(simd_abs($0 &- expectedNormal)) <= 1 } == true && (normal?.x ?? 255) < 128 && (normal?.y ?? 0) > 128,
    "bump map: a texel's normal leans against the height's u slope and with its v slope, as bump_normal_map computes (\(String(describing: normal)), expected \(expectedNormal))")

  // Nonlinear plastic: a uniform texel rho bakes to rho x plasticRatio(rho) in 8-bit sRGB; RGBA alpha is ignored.
  try png("grey.png") { _, _ in (128, 128, 128) }
  try png("grey-alpha.png", alpha: 100) { _, _ in (128, 128, 128) }
  let rho = srgb(128.0 / 255)
  let expectedPlastic = encode(rho * MitsubaImporter.plasticRatio(eta: 1.5, alpha: nil, ggx: false, nonlinear: true, rho: rho))
  for (file, label) in [("grey.png", "opaque"), ("grey-alpha.png", "translucent")] {
    _ = try compiled(document("""
      <bsdf type="plastic"><float name="int_ior" value="1.5"/><float name="ext_ior" value="1"/><boolean name="nonlinear" value="true"/>
        <texture type="bitmap" name="diffuse_reflectance"><string name="filename" value="\(file)"/></texture></bsdf>
      """, name: label))
    let value = try baked("-plastic.png", label).flatMap { texel($0, 2, 1) }
    require(value.map { abs($0.x - expectedPlastic) <= 1 && $0.x == $0.y && $0.y == $0.z } == true,
      "nonlinear plastic bake (\(label)): rho x plasticRatio(rho) within one 8-bit level (\(String(describing: value)), expected \(expectedPlastic))")
  }
  let longName = String(repeating: "Material name ", count: 30)
  _ = try compiled(document("""
    <bsdf type="plastic"><boolean name="nonlinear" value="true"/>
      <texture type="bitmap" name="diffuse_reflectance"><string name="filename" value="grey.png"/></texture></bsdf>
    """, name: longName))
  let bakedNames = try FileManager.default.contentsOfDirectory(atPath: bakes.path)
  require(bakedNames.allSatisfy { $0.utf8.count < 200 }, "a long material name still gives a short baked file name")

  // principledthin against the converter's principled_thin.
  let thin = try program("""
    <bsdf type="principledthin"><rgb name="base_color" value="0.8, 0.5, 0.3"/><float name="diff_trans" value="1.6"/>
      <float name="spec_trans" value="0.5"/><float name="roughness" value="0.4"/><float name="eta" value="1.33"/>
      <float name="anisotropic" value="0.2"/><float name="spec_tint" value="0.1"/><float name="sheen" value="0.3"/><float name="flatness" value="0.4"/></bsdf>
    """, name: "leaf")
  require(thin.thinWalled == true && near(input(thin, "base_color"), SIMD3(0.8, 0.5, 0.3)) && near(input(thin, "subsurface_weight"), SIMD3(repeating: 1))
    && abs((thin.subsurfaceAnisotropy ?? 0) - 0.6) < 1e-5 && near(input(thin, "transmission_weight"), SIMD3(repeating: 0.5))
    && near(input(thin, "specular_weight"), SIMD3(repeating: 0.5)) && near(input(thin, "specular_roughness"), SIMD3(repeating: 0.4))
    && near(input(thin, "specular_ior"), SIMD3(repeating: 1.33)) && thin.transmissionColor.map { simd_length($0 - SIMD3(0.8, 0.5, 0.3)) < 1e-5 } == true,
    "principledthin: thin-walled, diff_trans 1.6 as subsurface weight 1 and anisotropy 0.6, spec_trans as both weights, base colour tint")
  require(["anisotropic", "spec_tint", "sheen", "flatness"].allSatisfy { reported("leaf: principledthin \($0) unsupported; dropped") },
    "principledthin: the four dropped properties are reported")

  // Textured mask and linear plastic, conductor chroma, normal map, transmission colours, Beckmann, zero radiance.
  let mask = try program("""
    <bsdf type="mask"><texture type="bitmap" name="opacity"><string name="filename" value="grey.png"/></texture><bsdf type="diffuse"/></bsdf>
    """)
  require(mask.opacity != nil && mask.images.count == 1 && input(mask, "geometry_opacity") == nil, "mask: a texture becomes connected geometry_opacity")
  let linear = try program(#"<bsdf type="plastic"><texture type="bitmap" name="diffuse_reflectance"><string name="filename" value="grey.png"/></texture></bsdf>"#)
  let tint = MitsubaImporter.plasticRatio(eta: 1.49 / 1.000277, alpha: nil, ggx: false, nonlinear: false, rho: 0.5)
  require(linear.images.count == 1 && linear.parameters.contains { $0.name.hasSuffix("/in2") && $0.defaultValue.map { abs($0.x - tint) < 1e-5 && $0.x == $0.z } == true },
    "a textured linear plastic: the texture times plasticRatio at rho 0.5")
  let chroma = try program(#"<bsdf type="conductor"><string name="material" value="Cu"/><rgb name="specular_reflectance" value="0.5, 0.25, 0.125"/></bsdf>"#)
  let cu = MitsubaTables.conductors["Cu"]!.f0
  require(near(input(chroma, "specular_weight"), SIMD3(repeating: 0.5)) && near(input(chroma, "base_color"), cu * SIMD3(1, 0.5, 0.25)),
    "conductor: a coloured specular_reflectance splits into specular_weight (its maximum) and base_color chroma")
  try png("normal.png") { _, _ in (128, 128, 255) }
  let mapped = try document("""
    <bsdf type="normalmap"><texture type="bitmap" name="normalmap"><string name="filename" value="normal.png"/><boolean name="raw" value="true"/></texture>
      <bsdf type="diffuse"/></bsdf>
    """)
  let mappedProgram = try compiled(mapped)
  require(mapped.contains("<normalmap ") && mappedProgram.roots[8] >= 0, "normalmap: geometry_normal from the texture")
  let pane = try program(#"<bsdf type="thindielectric"><rgb name="specular_transmittance" value="0.9, 0.6, 0.3"/></bsdf>"#)
  let bright = try program(#"<bsdf type="dielectric"><rgb name="specular_transmittance" value="1.5, 0.5, 0.5"/></bsdf>"#)
  require(pane.transmissionColor == SIMD3(0.9, 0.6, 0.3) && bright.transmissionColor == SIMD3(1, 0.5, 0.5),
    "thin transmission_color, and transmission_color clamped at 1")
  // An IOR ratio below 1: specular_ior 1 / eta (the app's IOR is at least 1.01; MitsubaImporter.load reverses the shape).
  let bubble = try program(#"<bsdf type="dielectric"><float name="int_ior" value="0.763"/><float name="ext_ior" value="1"/></bsdf>"#, name: "bubble")
  require(near(input(bubble, "specular_ior"), SIMD3(repeating: 1 / 0.763)) && reported(prefix: "bubble: int_ior / ext_ior 0.763 is below 1"),
    "a dielectric with int_ior / ext_ior 0.763: specular_ior 1 / 0.763, reported (\(String(describing: input(bubble, "specular_ior"))))")
  _ = try program(#"<bsdf type="roughconductor"/>"#)
  require(reported("Beckmann microfacet distributions are rendered as GGX at the same alpha"), "a Beckmann distribution is reported")
  let dark = try program(nil, emission: .zero)
  require(dark.emission != nil && near(input(dark, "emission_color"), .zero), "an emitter with radiance 0 compiles and emits nothing")

  // Values that are not finite or negative.
  let nanColour = try program(#"<bsdf type="diffuse"><rgb name="reflectance" value="nan, 0.5, 0.5"/></bsdf>"#, name: "nan")
  require(near(input(nanColour, "base_color"), SIMD3(repeating: 0.5)) && reported("nan: reflectance is not a finite number; default used"),
    "a NaN colour: reported, default used")
  let negative = try program(nil, emission: SIMD3(-5, 2, 4), name: "neg")
  require(near(input(negative, "emission_color").map { $0 * (input(negative, "emission_luminance")?.x ?? 0) }, SIMD3(0, 2, 4))
    && reported(prefix: "neg: radiance is negative"), "a negative radiance channel: reported, 0 used")
  let nanScale = try document(#"""
    <bsdf type="diffuse"><texture type="bitmap" name="reflectance"><string name="filename" value="grey.png"/>
      <transform name="to_uv"><scale x="nan" y="2"/></transform></texture></bsdf>
    """#, name: "uvnan")
  require(!nanScale.contains("texcoord") && reported("uvnan: reflectance texture to_uv is not a finite number; scale 1 used"), "a NaN to_uv: reported, scale 1")

  // Texture properties the mapping does not read.
  _ = try program("""
    <bsdf type="diffuse"><texture type="bitmap" name="reflectance"><string name="filename" value="grey.png"/>
      <string name="wrap_mode" value="clamp"/><string name="filter_type" value="nearest"/><string name="format" value="variant"/>
      <transform name="to_uv"><scale x="2" y="2"/><translate x="0.5"/></transform></texture></bsdf>
    """, name: "wrap")
  require(reported("wrap: reflectance texture wrap_mode clamp unsupported; repeat used")
    && reported("wrap: reflectance texture filter_type nearest unsupported; bilinear used")
    && reported("wrap: reflectance texture bitmap format unsupported; ignored")
    && reported("wrap: reflectance texture to_uv offset or rotation unsupported; only its scale (2.0, 2.0) used"),
    "wrap_mode, filter_type, other properties and a to_uv offset are reported (\(scene.report.filter { $0.hasPrefix("wrap") }))")
  _ = try program("""
    <bsdf type="diffuse"><texture type="checkerboard" name="reflectance"><texture type="bitmap" name="color0"><string name="filename" value="grey.png"/></texture></texture></bsdf>
    """, name: "chequer")
  require(reported("chequer: checkerboard color0 texture unsupported; 0.4 used"), "a textured checkerboard colour is reported")
  _ = try program(#"<bsdf type="twosided"><bsdf type="diffuse"/><bsdf type="conductor"/></bsdf>"#, name: "sides")
  require(reported("sides: twosided back-side BSDF unsupported; the front BSDF used on both sides"), "a twosided with two BSDFs is reported")

  // to_uv sampling: t' = s t + (0, 1 - s_v), so a v scale of 1.5 samples Mitsuba's image row frac(1.5 v); normal maps too.
  let scaled = try document("""
    <bsdf type="normalmap"><texture type="bitmap" name="normalmap"><string name="filename" value="normal.png"/>
      <transform name="to_uv"><scale x="2" y="1.5"/></transform></texture>
      <bsdf type="diffuse"><texture type="bitmap" name="reflectance"><string name="filename" value="grey.png"/>
        <transform name="to_uv"><scale x="2" y="1.5"/></transform></texture></bsdf></bsdf>
    """)
  let scaledProgram = try compiled(scaled)
  require(scaled.contains(#"type="vector2" value="2.0, 1.5""#) && scaled.contains(#"type="vector2" value="0.0, -0.5""#)
    && scaled.components(separatedBy: #"name="texcoord" type="vector2""#).count == 3 && scaledProgram.images.count == 2,
    "a to_uv scale applies to colour and normal-map images, with the v offset 1 - s_v")

  // Bake size limit.
  let huge = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8193, pixelsHigh: 8192, bitsPerSample: 8, samplesPerPixel: 1,
    hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: 8193, bitsPerPixel: 8)!
  try huge.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("huge.png"))
  requireThrows("material 'huge': texture huge.png is too large to bake (8193 × 8192)") {
    _ = try document("""
      <bsdf type="plastic"><boolean name="nonlinear" value="true"/>
        <texture type="bitmap" name="diffuse_reflectance"><string name="filename" value="huge.png"/></texture></bsdf>
      """, name: "huge")
  }
  print("PASS: Mitsuba materials: baked texels, principledthin, value guards, texture reports, to_uv sampling, bake limit")
}
try fixMitsubaMaterialChecks()
