// OBJ materials (docs/SCENE_STORAGE_DESIGN.md, phase 4 group B): the streaming OBJ reader's mtllib
// statements and line endings, MTL parsing and its OpenPBR MaterialX translation, the bump-to-normal
// conversion's orientation, and alpha-channel coverage, through ProjectDocument.appendOBJ.
@MainActor func fixOBJMaterialChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("obj-materials", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder.appendingPathComponent("tex"), withIntermediateDirectories: true)
  // w x h RGBA image from a texel function (x right, y down).
  func png(_ name: String, _ w: Int, _ h: Int, alpha: Bool = true, _ texel: (Int, Int) -> SIMD4<UInt8>) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
      samplesPerPixel: alpha ? 4 : 3, hasAlpha: alpha, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: (alpha ? 4 : 3) * w, bitsPerPixel: alpha ? 32 : 24)!
    for y in 0..<h { for x in 0..<w {
      let t = texel(x, y), o = (alpha ? 4 : 3) * (y * w + x)
      for c in 0..<(alpha ? 4 : 3) { rep.bitmapData![o + c] = t[c] }
    } }
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
  }
  try png("tex/leaf.png", 4, 4) { x, _ in SIMD4(40, 160, 40, x < 2 ? 0 : 255) }
  try png("tex/stone.png", 4, 4, alpha: false) { _, _ in SIMD4(128, 128, 128, 255) }
  try png("tex/ramp.png", 16, 16, alpha: false) { x, _ in SIMD4(repeating: UInt8(x * 16)) }

  // Streaming reader: mtllib arguments, CR-only and VT/FF line ends, tabs, signed indices.
  var skipped = 0, libraries: [String] = []
  let parsed = try OBJMesh.parts(Data("mtllib  scene.mtl\rv 0 0 0\u{0B}v +1 0 0\u{0C}v 0 1 0\r\n\tusemtl\tLeaf\nf -3 -2 -1\n".utf8),
    skipped: &skipped, libraries: &libraries)
  require(libraries == ["scene.mtl"] && parsed.count == 1 && parsed[0].subsets == ["Leaf"] && parsed[0].geometry.count == 1,
    "OBJ reader keeps mtllib and accepts CR, VT and FF line ends (\(libraries), \(parsed.map(\.subsets)))")
  let lineError: String
  do { _ = try OBJMesh.parts(Data("v 0 0 0\rv 1 0 0\rv 0 1 0\rf 1 2 1e3\r".utf8), skipped: &skipped, libraries: &libraries); lineError = "" }
  catch { lineError = error.localizedDescription }
  require(lineError.contains("Invalid OBJ index") && lineError.contains("line 4"), "CR-only OBJ error names its line: \(lineError)")

  // MTL parsing: options, backslash paths, Tr, ignored statements.
  var report: [String] = []
  let mtl = """
    # materials
    newmtl Leaf
    \tKd 1 1 1
    \tKs 0.02 0.02 0.02
    \tNs 10
    \tNi 1.5
    \tmap_Kd -s 2 3 -o 0.5 0 tex\\leaf.png
    newmtl Stone
    \tKd 0.5 0.4 0.3
    \tTr 0.25
    \tillum 1
    \tmap_bump -bm 2 -clamp on tex/ramp.png
    \tmap_Kd -t 1 1 1 tex/stone.png
    \tPm 0.5
    newmtl Lamp
    \tKe 2 2 1
    \tillum 5
    newmtl Pane
    \tKd 1 1 1
    \tKs 0.5 0.5 0.5
    \tNs 100
    \tNi 1.0
    \tTf 0.2 0.3 0.4
    \tillum 7
    newmtl Bottle
    \tNi 1.5
    \tillum 4
    """
  let materials = try OBJMaterials.read(mtl, report: &report)
  require(materials.map(\.name) == ["Leaf", "Stone", "Lamp", "Pane", "Bottle"], "MTL materials: \(materials.map(\.name))")
  require(materials[3].tf == SIMD3(0.2, 0.3, 0.4) && materials[3].transmits && materials[4].transmits && !materials[2].transmits,
    "MTL Tf and transparency models")
  let leafMap = materials[0].maps["map_kd"]
  require(leafMap?.file == "tex/leaf.png" && leafMap?.scale == SIMD2(2, 3) && leafMap?.offset == SIMD2(0.5, 0),
    "MTL map options and backslash path: \(String(describing: leafMap))")
  require(materials[1].d == 0.75 && materials[1].maps["map_bump"]?.bumpMultiplier == 2 && materials[1].maps["map_bump"]?.clamp == true,
    "MTL Tr and bump options")
  require(report.contains { $0.contains("'Pm'") } && report.contains { $0.contains("-t") }, "MTL reports ignored input: \(report)")

  // Translation: GGX roughness from Ns, specular weight from Ks and Ni, constant coverage, emission.
  var writer = MaterialXWriter()
  for (i, m) in materials.enumerated() { writer.material(m, prefix: "m\(i)", folder: folder, scratch: folder, report: &report) }
  let text = writer.text
  let roughness = (2 / Float(12)).squareRoot().squareRoot()
  require(text.contains("name=\"specular_roughness\" type=\"float\" value=\"\(roughness)\"")
    && text.contains("value=\"2.0, 3.0\"") && text.contains("name=\"geometry_opacity\" type=\"float\" nodename=\"m0_alpha\"")
    && text.contains("name=\"emission_color\" type=\"color3\" value=\"2.0, 2.0, 1.0\""),
    "MTL to MaterialX translation:\n\(text)")
  require(report.contains { $0.contains("illum 5") } && !report.contains { $0.contains("illum 7") || $0.contains("illum 4") }
    && report.contains { $0.contains("alpha channel of tex/leaf.png") },
    "MTL reports illum and alpha coverage: \(report)")
  // Glass (illum 4/6/7/9): smooth transmission filtered by Tf; Ni 1 ("light does not bend") is thin-walled.
  let shaders = text.components(separatedBy: "<open_pbr_surface ")
  let pane = shaders.first { $0.hasPrefix("name=\"m3\"") } ?? "", bottle = shaders.first { $0.hasPrefix("name=\"m4\"") } ?? ""
  require(pane.contains("name=\"transmission_weight\" type=\"float\" value=\"1.0\"")
    && pane.contains("name=\"transmission_color\" type=\"color3\" value=\"0.2, 0.3, 0.4\"")
    && pane.contains("name=\"geometry_thin_walled\" type=\"boolean\" value=\"true\"")
    && pane.contains("name=\"specular_roughness\" type=\"float\" value=\"0.0\"")
    && bottle.contains("name=\"transmission_weight\" type=\"float\" value=\"1.0\"")
    && !bottle.contains("geometry_thin_walled") && !bottle.contains("transmission_color"),
    "MTL glass translation:\n\(pane)\n\(bottle)")
  // Bump ramp rising with u (x) and constant in v: the normal tilts toward -u, not along v.
  let normalURL = folder.appendingPathComponent("ramp-normal.png")
  try OBJMaterials.heightNormalMap(folder.appendingPathComponent("tex/ramp.png"), multiplier: 64, clamp: true, to: normalURL)
  let normal = NSBitmapImageRep(data: try Data(contentsOf: normalURL))!
  let o = 8 * normal.bytesPerRow + 8 * normal.bitsPerPixel / 8
  let centre = SIMD3<Double>((0..<3).map { Double(normal.bitmapData![o + $0]) / 255 })
  let expected = simd_normalize(SIMD3<Double>(-64.0 / 128 * 16 / 255 * 16, 0, 1)) * 0.5 + 0.5
  require(simd_length(centre - expected) < 0.01, "bump ramp tilts the normal toward -u (\(centre); expected \(expected))")
  require(OBJMaterials.isNormalMap(normalURL) && !OBJMaterials.isNormalMap(folder.appendingPathComponent("tex/ramp.png")),
    "a bump-slot normal map is told apart from a height map")
  require(OBJMaterials.hasCoverage(folder.appendingPathComponent("tex/leaf.png"))
    && !OBJMaterials.hasCoverage(folder.appendingPathComponent("tex/stone.png")), "alpha coverage detection")

  // Palette PNGs (Bistro's small colour maps), which MTKTextureLoader rejects, decode through Core Graphics.
  let palette = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 1, colorTable: [0, 0, 0, 200, 100, 50])!
  let indices: [UInt8] = [0, 1, 1, 0]
  let paletteImage = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 2, space: palette,
    bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: Data(indices) as CFData)!, decode: nil,
    shouldInterpolate: false, intent: .defaultIntent)!
  let paletteData = NSMutableData()
  let destination = CGImageDestinationCreateWithData(paletteData, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, paletteImage, nil)
  require(CGImageDestinationFinalize(destination), "palette PNG written")
  require((try? MTKTextureLoader(device: gpu).newTexture(data: paletteData as Data, options: nil)) == nil,
    "the palette PNG exercises the Core Graphics fallback")
  let decoded = try testRenderer.materials.decodeTexture(paletteData as Data, srgb: true)
  require(decoded.width == 2 && decoded.height == 2, "palette PNG decodes as a texture")

  // Through the document: each usemtl subset gets its compiled program and base colour.
  try mtl.write(to: folder.appendingPathComponent("scene.mtl"), atomically: true, encoding: .utf8)
  let obj = """
    mtllib scene.mtl
    v 0 0 0
    v 1 0 0
    v 0 1 0
    vt 0 0
    vt 1 0
    vt 0 1
    usemtl Leaf
    f 1/1 2/2 3/3
    usemtl Stone
    f 1/1 3/3 2/2
    usemtl Missing
    f 2/2 3/3 1/1
    usemtl Pane
    f 1/1 2/2 3/3
    usemtl Bottle
    f 1/1 2/2 3/3
    """
  var document = ProjectDocument()
  report = []
  _ = try document.appendOBJ(Data(obj.utf8), name: "scene.obj", folder: folder, skipped: &skipped, report: &report)
  let graph = document.graph!, state = document.scenes[6]!
  func slot(_ name: String) -> Int { graph.materials.first { $0.name == name }!.slot }
  let leaf = state.materialX?[slot("Leaf")], stone = state.materialX?[slot("Stone")]
  // Stone's constant dissolve (Tr 0.25) without a mask is glass, not coverage; Leaf's alpha mask stays coverage.
  require(leaf?.opacity != nil && leaf?.images.count == 1 && stone?.opacity == nil && stone?.thinWalled == true
    && stone?.images.count == 2 && report.contains { $0.contains("Stone: constant dissolve d 0.75 rendered as glass") }
    && state.materialX?[slot("Missing")] == nil && state.surfaces[slot("Stone")].color == SIMD4(0.5, 0.4, 0.3, 1),
    "OBJ import compiles MTL programs: leaf \(String(describing: leaf?.images.count)), stone \(String(describing: stone?.images.count))")
  let paneProgram = state.materialX?[slot("Pane")], bottleProgram = state.materialX?[slot("Bottle")]
  require(paneProgram?.transmissionColor == SIMD3(0.2, 0.3, 0.4) && paneProgram?.thinWalled == true
    && bottleProgram != nil && bottleProgram?.transmissionColor == nil && bottleProgram?.thinWalled == nil,
    "OBJ glass compiles to per-slot transmission colour and thin walls")
  require(report.contains { $0.contains("Missing is not defined") } && document.importReport?.first == "scene.obj:"
    && !report.contains { $0.contains("vibe-mtl-") }, "OBJ import report: \(report)")
  print("PASS: OBJ mtllib materials, MTL to OpenPBR MaterialX, bump-to-normal orientation and alpha coverage")

  // Over the texture budget, the largest graph image is halved until the scene fits; small images
  // stay exact, the embedded bytes are untouched, and an unchanged scene reuses its textures.
  try png("big.png", 1024, 512, alpha: false) { x, y in SIMD4(UInt8(x % 256), UInt8(y % 256), 64, 255) }
  try png("small.png", 64, 64, alpha: false) { _, _ in SIMD4(200, 100, 50, 255) }
  let pair = try MaterialXImporter.read(Data("""
    <materialx version="1.39">
     <image name="big" type="color3"><input name="file" type="filename" value="big.png"/></image>
     <image name="small" type="color3"><input name="file" type="filename" value="small.png"/></image>
     <open_pbr_surface name="Big" type="surfaceshader"><input name="base_color" type="color3" nodename="big"/></open_pbr_surface>
     <open_pbr_surface name="Small" type="surfaceshader"><input name="base_color" type="color3" nodename="small"/></open_pbr_surface>
    </materialx>
    """.utf8), baseURL: folder, source: "pair.mtlx")
  var budgetState = SceneState()
  budgetState.materialX = [8: pair.materials[0], 9: pair.materials[1]]
  let limited = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
  let estimate = { (w: Int, h: Int) in MaterialLibrary.estimatedTextureBytes(pixels: UInt64(w * h), depth: 8).partialValue }
  // Room for the big image at 512 x 256 but not at full size.
  limited.textureBudgetOverride = limited.uniqueTextureBytes(limited.residentTextures) + estimate(512, 256) + estimate(64, 64) + 4096
  try limited.restore(budgetState)
  let sizes = limited.graphTextures.map { SIMD2($0.width, $0.height) }
  require(limited.graphTextureSide == 512 && sizes.contains(SIMD2(512, 256)) && sizes.contains(SIMD2(64, 64))
    && limited.materialX[8]?.images[0].data == pair.materials[0].images[0].data,
    "the big image is halved to fit the budget, the small one is exact, embedded bytes unchanged (\(sizes), side \(String(describing: limited.graphTextureSide)))")
  let first = limited.graphTextures.map { ObjectIdentifier($0 as AnyObject) }
  try limited.restore(budgetState)
  require(limited.graphTextures.map { ObjectIdentifier($0 as AnyObject) } == first, "an unchanged budgeted scene reuses its textures")
  let roomy = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
  try roomy.restore(budgetState)
  require(roomy.graphTextureSide == nil && roomy.graphTextures.contains { $0.width == 1024 }, "within the budget images keep full size")
  print("PASS: graph images downscale, largest first, to fit the GPU texture budget")
}
try fixOBJMaterialChecks()
