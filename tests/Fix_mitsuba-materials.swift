// Mitsuba materials (MitsubaImporter.material) beyond Fix_mitsuba.swift's mapping rows: the baked images' texels
// against their formulas (bump normal maps, nonlinear plastics), principledthin, textured masks and
// plastics, conductor chroma and textured specular_reflectance (sRGB, raw, near-grey, and unreadable or too large to
// check), normal maps, transmission colours, IOR ratios below 1 (dielectric, roughdielectric, thindielectric), values
// that are not finite or negative, texture properties the mapping does not read, to_uv sampling (Mitsuba's rows for
// any v scale), the bake size limit, hostile values in baked images, BSDF wrapper depth, anisotropic roughness, coating
// IOR ratios below 1, and a 0.6 file shaped like Bitterli's archives.
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
  func document(_ xml: String?, emission: SIMD3<Float>? = nil, name: String = "m", interior: MitsubaImporter.Node? = nil,
                mesh: MitsubaImporter.Mesh? = nil) throws -> String {
    let node = try xml.map { try bsdf($0) }
    return try MitsubaImporter.material(bsdf: node, emission: emission, interior: interior, name: name, scene: &scene, folder: bakes, mesh: mesh)
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

  // Bump map: heights h = (40 x + 20 y) / 255 (raw) on a 4 x 4 image over a 2 x 2 quad (UV stretch 2). The bumpmap
  // formula at texel (1, 1): d_u = (h(2, 1) - h(0, 1)) / 2 x 4, d_v = (h(1, 2) - h(1, 0)) / 2 x 4, and the map
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
    "bump map: a texel's normal leans against the height's u slope and with its v slope, as MitsubaImporter.normalMap computes it (\(String(describing: normal)), expected \(expectedNormal))")

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

  // principledthin against its mapping (REFERENCES.md MITSUBA3, principledthin).
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
  // Mitsuba decodes a bitmap opacity as sRGB unless raw (probed in 3.9.1: a grey 128 PNG gives opacity 0.2159, raw 0.5020).
  let maskText = try document("""
    <bsdf type="mask"><texture type="bitmap" name="opacity"><string name="filename" value="grey.png"/></texture><bsdf type="diffuse"/></bsdf>
    """, name: "veil")
  let rawMaskText = try document("""
    <bsdf type="mask"><texture type="bitmap" name="opacity"><string name="filename" value="grey.png"/><boolean name="raw" value="true"/></texture><bsdf type="diffuse"/></bsdf>
    """, name: "rawveil")
  require(maskText.contains(#"colorspace="srgb_texture""#) && maskText.contains("<extract ") && !rawMaskText.contains("<extract ")
    && !rawMaskText.contains("srgb_texture"), "a mask's bitmap opacity is the red channel of the sRGB image unless raw")
  let linear = try program(#"<bsdf type="plastic"><texture type="bitmap" name="diffuse_reflectance"><string name="filename" value="grey.png"/></texture></bsdf>"#)
  let tint = MitsubaImporter.plasticRatio(eta: 1.49 / 1.000277, alpha: nil, ggx: false, nonlinear: false, rho: 0.5)
  require(linear.images.count == 1 && linear.parameters.contains { $0.name.hasSuffix("/in2") && $0.defaultValue.map { abs($0.x - tint) < 1e-5 && $0.x == $0.z } == true },
    "a textured linear plastic: the texture times plasticRatio at rho 0.5")
  let chroma = try program(#"<bsdf type="conductor"><string name="material" value="Cu"/><rgb name="specular_reflectance" value="0.5, 0.25, 0.125"/></bsdf>"#)
  let cu = MitsubaTables.conductors["Cu"]!.f0
  require(near(input(chroma, "specular_weight"), SIMD3(repeating: 0.5)) && near(input(chroma, "base_color"), cu * SIMD3(1, 0.5, 0.25)),
    "conductor: a coloured specular_reflectance splits into specular_weight (its maximum) and base_color chroma")
  // A textured specular_reflectance scales Mitsuba's whole Fresnel: a grey one (Veach Ajar's checkerboard floor) is a
  // connected specular_weight over the conductor's F0; a coloured one can only scale F0 and is reported.
  // MaterialX leaves float images raw, so the weight is the red channel of the colour-managed (sRGB) image.
  let checkerText = try document("""
    <bsdf type="roughconductor"><string name="material" value="Cu"/><texture type="checkerboard" name="specular_reflectance">
      <rgb name="color0" value="0.8"/><rgb name="color1" value="0.2"/></texture></bsdf>
    """, name: "checker")
  let checker = try compiled(checkerText)
  // The colour space of the colour image that specular_weight's extract reads, and the extract's index.
  func weightSource(_ text: String) -> (colorspace: String, index: String)? {
    func capture(_ pattern: String) -> String? {
      guard let match = try? Regex(pattern).firstMatch(in: text), match.output.count > 1, let value = match.output[1].substring else { return nil }
      return String(value)
    }
    guard let extract = capture(#"<input name="specular_weight" type="float" nodename="(\w+)"/>"#),
      let image = capture(#"<extract name="\#(extract)" type="float">\s*<input name="in" type="color3" nodename="(\w+)"/>"#),
      let index = capture(#"<extract name="\#(extract)" type="float">\s*<input name="in" [^>]*/>\s*<input name="index" type="integer" value="(\d+)"/>"#),
      let space = capture(#"<image name="\#(image)" type="color3">\s*<input name="file" type="filename" value="[^"]*" colorspace="(\w+)"/>"#)
    else { return nil }
    return (space, index)
  }
  let checkerSource = weightSource(checkerText)
  require(input(checker, "specular_weight") == nil && checker.images.count == 1 && near(input(checker, "base_color"), cu)
    && checkerSource?.colorspace == "srgb_texture" && checkerSource?.index == "0",
    "a grey specular_reflectance texture: specular_weight from the sRGB image's red channel, base_color F0 (\(String(describing: checkerSource)), \(String(describing: input(checker, "base_color"))))")
  // A raw grey texture: the same red channel of an image read without sRGB decoding.
  let rawWeightText = try document("""
    <bsdf type="conductor"><texture type="bitmap" name="specular_reflectance"><string name="filename" value="grey.png"/>
      <boolean name="raw" value="true"/></texture></bsdf>
    """, name: "rawweight")
  let rawSource = weightSource(rawWeightText)
  require(rawSource?.colorspace == "raw" && rawSource?.index == "0" && !rawWeightText.contains("srgb_texture"),
    "a raw grey specular_reflectance texture: specular_weight from the raw image's red channel (\(String(describing: rawSource)))")
  // Near-grey (channels a level apart, as a JPEG's chroma subsampling leaves them) counts as grey.
  try png("near-grey.png") { x, y in let v = UInt8(100 + 20 * x); return (v, (x + y) % 2 == 0 ? v + 1 : v, (x + y) % 2 == 0 ? v : v - 1) }
  let nearGrey = try document("""
    <bsdf type="conductor"><texture type="bitmap" name="specular_reflectance"><string name="filename" value="near-grey.png"/></texture></bsdf>
    """, name: "neargrey")
  require(weightSource(nearGrey)?.colorspace == "srgb_texture" && !reported(prefix: "neargrey:"),
    "a near-grey specular_reflectance texture (channels within 2 of 255) takes the grey path")
  try png("red.png") { _, _ in (200, 50, 50) }
  let tinted = try program("""
    <bsdf type="conductor"><string name="material" value="Cu"/><texture type="bitmap" name="specular_reflectance">
      <string name="filename" value="red.png"/></texture></bsdf>
    """, name: "tinted")
  require(input(tinted, "base_color") == nil && tinted.images.count == 1
    && reported("tinted: coloured specular_reflectance texture scales F0 only"),
    "a coloured specular_reflectance texture multiplies base_color and is reported")
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
  let roughBubble = try program(#"<bsdf type="roughdielectric"><float name="int_ior" value="0.763"/><float name="ext_ior" value="1"/></bsdf>"#, name: "froth")
  let thinBubble = try program(#"<bsdf type="thindielectric"><float name="int_ior" value="0.763"/><float name="ext_ior" value="1"/></bsdf>"#, name: "film0")
  require(near(input(roughBubble, "specular_ior"), SIMD3(repeating: 1 / 0.763)) && near(input(thinBubble, "specular_ior"), SIMD3(repeating: 1 / 0.763))
    && reported("film0: thindielectric with an IOR ratio below 1 is rendered with the inverse ratio; its total internal reflection is lost"),
    "a roughdielectric and a thindielectric below 1: specular_ior 1 / eta, the thin one reported as an approximation")
  // A named conductor material with k alone: Mitsuba rejects the unused property; the importer reports it.
  _ = try program(#"<bsdf type="conductor"><string name="material" value="Au"/><rgb name="k" value="1"/></bsdf>"#, name: "gold")
  require(reported("gold: k ignored with a named conductor material"), "a named conductor material with k is reported")
  _ = try program(#"<bsdf type="conductor"><string name="material" value="Au"/></bsdf>"#, name: "plainGold")
  require(!reported(prefix: "plainGold:"), "a named conductor material alone is not reported")
  // A thin dielectric with an interior medium is thin-walled, not unrefracting.
  let slab = #"<medium type="homogeneous" name="interior"><rgb name="albedo" value="0"/><rgb name="sigma_t" value="0.5"/></medium>"#
  _ = try compiled(document(#"<bsdf type="thindielectric"/>"#, name: "film", interior: try bsdf(slab)))
  require(reported("film: interior medium ignored (its BSDF is thin-walled)"), "a thin dielectric's interior medium is reported as thin-walled")
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
  // A conductor's specular_reflectance texture that cannot be checked for grey (above the bake limit, or not an
  // image) takes the coloured path with a report line naming the reason; the import succeeds.
  try Data("not an image".utf8).write(to: folder.appendingPathComponent("unreadable.png"))
  for (file, label, reason) in [("huge.png", "hugemetal", "too large to bake (8193 × 8192)"), ("unreadable.png", "badmetal", "cannot decode unreadable.png")] {
    let text = try document("""
      <bsdf type="conductor"><texture type="bitmap" name="specular_reflectance"><string name="filename" value="\(file)"/></texture></bsdf>
      """, name: label)
    require(weightSource(text) == nil && text.contains(#"name="base_color" type="color3" nodename"#)
      && scene.report.contains { $0.hasPrefix("\(label): specular_reflectance texture \(file) not checked for grey") && $0.contains(reason) }
      && reported("\(label): coloured specular_reflectance texture scales F0 only"),
      "\(file) as a conductor's specular_reflectance: the coloured path, reported with the reason (\(scene.report.filter { $0.hasPrefix(label) }))")
  }

  // Hostile values in baked images: a huge bump scale and NaN texels give finite texels (a flat normal, a 0 albedo)
  // instead of trapping on the 8-bit conversion.
  // Scale 3e38: slopes near Float's largest still give the bump's direction, normalize(-d_u, d_v, 0) at (1, 1).
  _ = try compiled(document("""
    <bsdf type="bumpmap"><texture type="bitmap" name="map"><string name="filename" value="ramp.png"/><boolean name="raw" value="true"/></texture>
      <float name="scale" value="3e38"/><bsdf type="diffuse"/></bsdf>
    """, name: "steep", mesh: quad))
  let tangent = simd_normalize(SIMD3(-du, dv, 0))
  let expectedSteep = SIMD3((0..<3).map { Int((tangent[$0] * 0.5 + 0.5) * 255 + 0.5) })
  let steep = try baked("-bump-normal.png", "steep").flatMap { texel($0, 1, 1) }
  require(steep.map { simd_reduce_max(simd_abs($0 &- expectedSteep)) <= 1 } == true,
    "bump scale 3e38: the normal lies along the slope (\(String(describing: steep)), expected \(expectedSteep))")
  // With a to_uv scale of 100 as well the slope overflows to infinity: the flat (0, 0, 1).
  _ = try compiled(document("""
    <bsdf type="bumpmap"><texture type="bitmap" name="map"><string name="filename" value="ramp.png"/><boolean name="raw" value="true"/>
      <transform name="to_uv"><scale value="100"/></transform></texture>
      <float name="scale" value="3e38"/><bsdf type="diffuse"/></bsdf>
    """, name: "cliff", mesh: quad))
  let cliff = try baked("-bump-normal.png", "cliff").flatMap { texel($0, 1, 1) }
  require(cliff == SIMD3(128, 128, 255), "an overflowing bump slope is the flat (0, 0, 1) (\(String(describing: cliff)))")
  // A 32-bit float TIFF with a NaN texel at (0, 0) and 0.5 elsewhere.
  let floats = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 32, samplesPerPixel: 3, hasAlpha: false,
    isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .floatingPointSamples, bytesPerRow: 48, bitsPerPixel: 96)!
  floats.bitmapData!.withMemoryRebound(to: Float.self, capacity: 48) { texels in
    for i in 0..<48 { texels[i] = i < 3 ? .nan : 0.5 }
  }
  try floats.tiffRepresentation!.write(to: folder.appendingPathComponent("nan.tif"))
  _ = try compiled(document("""
    <bsdf type="plastic"><boolean name="nonlinear" value="true"/>
      <texture type="bitmap" name="diffuse_reflectance"><string name="filename" value="nan.tif"/><boolean name="raw" value="true"/></texture></bsdf>
    """, name: "nanplastic"))
  let nanPlastic = try baked("-plastic.png", "nanplastic").flatMap { texel($0, 0, 0) }
  require(nanPlastic.map { $0.x < 255 } == true, "a NaN texel in a nonlinear plastic's float texture bakes to a finite texel (\(String(describing: nanPlastic)))")
  _ = try compiled(document("""
    <bsdf type="bumpmap"><texture type="bitmap" name="map"><string name="filename" value="nan.tif"/><boolean name="raw" value="true"/></texture>
      <bsdf type="diffuse"/></bsdf>
    """, name: "nanbump", mesh: quad))
  let nanBump = try baked("-bump-normal.png", "nanbump")
  require(nanBump != nil, "a NaN texel in a bump map's float texture bakes a normal map")
  // BSDF wrappers 20 deep: an error, not a recursion per level.
  let wrapped = String(repeating: #"<bsdf type="twosided">"#, count: 20) + #"<bsdf type="diffuse"/>"# + String(repeating: "</bsdf>", count: 20)
  requireThrows("BSDF wrappers nested more than \(MitsubaImporter.maxWrapperDepth) deep") { _ = try document(wrapped, name: "onion") }

  // Anisotropic roughness as its geometric mean; an IOR ratio below 1 on an opaque coating is 1.01.
  let brushed = try program(#"<bsdf type="roughconductor"><float name="alpha_u" value="0.04"/><float name="alpha_v" value="0.16"/><string name="distribution" value="ggx"/></bsdf>"#, name: "brushed")
  require(near(input(brushed, "specular_roughness"), SIMD3<Float>(repeating: Float(0.08).squareRoot()))
    && reported(prefix: "brushed: anisotropic alpha_u 0.04 and alpha_v 0.16 rendered isotropic at alpha 0.08")
    && !reported(prefix: "brushed: roughconductor alpha_"), "alpha_u and alpha_v: sqrt(alpha_u alpha_v), reported (\(scene.report.filter { $0.hasPrefix("brushed") }))")
  let frosted = try program(#"<bsdf type="roughdielectric"><float name="alpha_u" value="0.09"/><string name="distribution" value="ggx"/></bsdf>"#, name: "frosted")
  require(near(input(frosted, "specular_roughness"), SIMD3(repeating: (0.09 * 0.1 as Float).squareRoot().squareRoot())),
    "a missing alpha_v is Mitsuba's 0.1")
  for (xml, label, kind) in [(#"<bsdf type="plastic"><float name="int_ior" value="1"/><float name="ext_ior" value="1.5"/></bsdf>"#, "under", "plastic"),
                             (#"<bsdf type="principledthin"><float name="eta" value="0.8"/></bsdf>"#, "underthin", "principledthin")] {
    let p = try program(xml, name: label)
    require(near(input(p, "specular_ior"), SIMD3(repeating: 1.01)) && reported(prefix: "\(label): \(kind) IOR ratio 0.") ,
      "\(kind) with an IOR ratio below 1: specular_ior 1.01, reported (\(scene.report.filter { $0.hasPrefix(label) }))")
  }

  // A 0.6 file shaped like Bitterli's archives: conductor extEta (1, dropped; 2, dividing eta and k), bitmap filterType,
  // checkerboard uoffset, and a medium's sigmaS and sigmaA. No "unsupported" line.
  try png("tile.png") { x, y in ((x + y) % 2 == 0 ? 200 : 50, 90, 90) }
  let legacyURL = folder.appendingPathComponent("archive06.xml")
  try """
    <scene version="0.6.0">
      <bsdf type="roughconductor" id="steel"><float name="alpha" value="0.1"/><string name="distribution" value="ggx"/>
        <float name="extEta" value="1"/><rgb name="specularReflectance" value="0.5, 0.5, 0.5"/>
        <rgb name="eta" value="1.6, 0.9, 0.5"/><rgb name="k" value="9.2, 6.3, 4.8"/></bsdf>
      <bsdf type="conductor" id="immersed"><float name="extEta" value="2"/><rgb name="eta" value="1.6, 0.9, 0.5"/><rgb name="k" value="9.2, 6.3, 4.8"/></bsdf>
      <bsdf type="conductor" id="named"><float name="extEta" value="1.33"/><string name="material" value="Au"/></bsdf>
      <bsdf type="diffuse" id="tiles"><texture type="bitmap" name="reflectance"><string name="filename" value="tile.png"/>
        <string name="filterType" value="trilinear"/></texture></bsdf>
      <bsdf type="roughconductor" id="floor"><float name="extEta" value="1"/><string name="distribution" value="ggx"/>
        <texture type="checkerboard" name="specularReflectance"><float name="uoffset" value="0"/><float name="voffset" value="0"/>
          <float name="uscale" value="20"/><float name="vscale" value="80"/></texture></bsdf>
      <bsdf type="dielectric" id="glass"/>
      <medium type="homogeneous" id="tint"><rgb name="sigmaS" value="0"/><rgb name="sigmaA" value="0.5"/></medium>
    </scene>
    """.write(to: legacyURL, atomically: true, encoding: .utf8)
  let legacy = try MitsubaImporter.Scene(url: legacyURL).root.children
  func legacyNode(_ id: String) -> MitsubaImporter.Node { legacy.first { $0.id == id }! }
  let before = scene.report.count
  for id in ["steel", "immersed", "tiles", "floor"] {
    _ = try compiled(MitsubaImporter.material(bsdf: legacyNode(id), emission: nil, interior: nil, name: "old-\(id)", scene: &scene, folder: bakes))
  }
  let absorbing = try compiled(MitsubaImporter.material(bsdf: legacyNode("glass"), emission: nil, interior: legacyNode("tint"), name: "old-glass",
                                                     scene: &scene, folder: bakes))
  let legacyLines = scene.report[before...].filter { $0.contains("unsupported") }
  require(legacyLines.isEmpty && absorbing.transmissionColor.map { simd_length($0 - SIMD3(repeating: exp(-0.5))) < 1e-5 } == true,
    "a 0.6 file shaped like the archives: no unsupported lines, and its medium read (\(legacyLines))")
  let relative = try document(#"<bsdf type="conductor"><rgb name="eta" value="0.8, 0.45, 0.25"/><rgb name="k" value="4.6, 3.15, 2.4"/></bsdf>"#, name: "old-immersed")
  let immersed = try MitsubaImporter.material(bsdf: legacyNode("immersed"), emission: nil, interior: nil, name: "old-immersed", scene: &scene, folder: bakes)
  require(immersed == relative, "a 0.6 conductor's eta and k are divided by its extEta")
  _ = try MitsubaImporter.material(bsdf: legacyNode("named"), emission: nil, interior: nil, name: "old-named", scene: &scene, folder: bakes)
  require(reported("old-named: conductor extEta unsupported; ignored"), "extEta with a named conductor is reported")
  print("PASS: Mitsuba materials: baked texels, principledthin, value guards, texture reports, to_uv sampling, bake limit, hostile values, anisotropy, 0.6 archives")
}
try fixMitsubaMaterialChecks()
