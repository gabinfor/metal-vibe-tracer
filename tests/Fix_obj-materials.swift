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
    \tillum 7
    """
  let materials = try OBJMaterials.read(mtl, report: &report)
  require(materials.map(\.name) == ["Leaf", "Stone", "Lamp"], "MTL materials: \(materials.map(\.name))")
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
  require(report.contains { $0.contains("illum 7") } && report.contains { $0.contains("alpha channel of tex/leaf.png") },
    "MTL reports illum and alpha coverage: \(report)")
  // Bump ramp rising with u (x) and constant in v: the normal tilts toward -u, not along v.
  let normalURL = folder.appendingPathComponent("ramp-normal.png")
  try OBJMaterials.heightNormalMap(folder.appendingPathComponent("tex/ramp.png"), multiplier: 64, clamp: true, to: normalURL)
  let normal = NSBitmapImageRep(data: try Data(contentsOf: normalURL))!
  let o = 8 * normal.bytesPerRow + 8 * normal.bitsPerPixel / 8
  let centre = SIMD3<Double>((0..<3).map { Double(normal.bitmapData![o + $0]) / 255 })
  let expected = simd_normalize(SIMD3<Double>(-64.0 / 512 * 16 / 255 * 16, 0, 1)) * 0.5 + 0.5
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
    """
  var document = ProjectDocument()
  report = []
  _ = try document.appendOBJ(Data(obj.utf8), name: "scene.obj", folder: folder, skipped: &skipped, report: &report)
  let graph = document.graph!, state = document.scenes[6]!
  func slot(_ name: String) -> Int { graph.materials.first { $0.name == name }!.slot }
  let leaf = state.materialX?[slot("Leaf")], stone = state.materialX?[slot("Stone")]
  require(leaf?.opacity != nil && leaf?.images.count == 1 && stone?.opacity != nil && stone?.images.count == 2
    && state.materialX?[slot("Missing")] == nil && state.surfaces[slot("Stone")].color == SIMD4(0.5, 0.4, 0.3, 1),
    "OBJ import compiles MTL programs: leaf \(String(describing: leaf?.images.count)), stone \(String(describing: stone?.images.count))")
  require(report.contains { $0.contains("Missing is not defined") } && document.importReport?.first == "scene.obj:"
    && !report.contains { $0.contains("vibe-mtl-") }, "OBJ import report: \(report)")
  print("PASS: OBJ mtllib materials, MTL to OpenPBR MaterialX, bump-to-normal orientation and alpha coverage")
}
try fixOBJMaterialChecks()
