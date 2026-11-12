// glTF 2.0 import (GLTFImporter): GLB and external-buffer files, node hierarchy and cameras, primitive modes,
// the material extensions' OpenPBR translation (anisotropy conversion and rotation, iridescence, volume,
// alpha mask, texture transform), MaterialX's rotated geometry_tangent, and on the GPU the anisotropic
// highlight's long axis following anisotropyRotation.
@MainActor func fixGLTFChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("gltf", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

  // A binary buffer of float32 / uint16 runs, with accessors and buffer views appended to `json`.
  struct Builder {
    var bin = Data()
    var views: [[String: Any]] = []
    var accessors: [[String: Any]] = []
    mutating func add(_ floats: [Float], type: String) -> Int {
      while bin.count % 4 != 0 { bin.append(0) }
      views.append(["buffer": 0, "byteOffset": bin.count, "byteLength": 4 * floats.count])
      floats.withUnsafeBytes { bin.append(contentsOf: $0) }
      let n = ["VEC2": 2, "VEC3": 3][type] ?? 1
      var a: [String: Any] = ["bufferView": views.count - 1, "componentType": 5126, "count": floats.count / n, "type": type]
      if type == "VEC3" {
        a["min"] = (0..<3).map { c in stride(from: c, to: floats.count, by: 3).map { floats[$0] }.min()! }
        a["max"] = (0..<3).map { c in stride(from: c, to: floats.count, by: 3).map { floats[$0] }.max()! }
      }
      accessors.append(a)
      return accessors.count - 1
    }
    mutating func indices(_ values: [UInt16]) -> Int {
      while bin.count % 4 != 0 { bin.append(0) }
      views.append(["buffer": 0, "byteOffset": bin.count, "byteLength": 2 * values.count])
      values.withUnsafeBytes { bin.append(contentsOf: $0) }
      accessors.append(["bufferView": views.count - 1, "componentType": 5123, "count": values.count, "type": "SCALAR"])
      return accessors.count - 1
    }
    // A quad in the z = 0 plane facing +Z, UV (0, 0) at its top left: dP/du = +X, dP/dv = -Y.
    mutating func quad(size: Float) -> [String: Any] {
      let s = size / 2
      let p = add([-s, s, 0, s, s, 0, s, -s, 0, -s, -s, 0], type: "VEC3")
      let n = add([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1], type: "VEC3")
      let t = add([0, 0, 1, 0, 1, 1, 0, 1], type: "VEC2")
      return ["attributes": ["POSITION": p, "NORMAL": n, "TEXCOORD_0": t], "indices": indices([0, 3, 2, 0, 2, 1])]
    }
    func json(_ body: [String: Any], uri: String? = nil) -> [String: Any] {
      var j = body
      j["asset"] = ["version": "2.0"]
      j["bufferViews"] = views
      j["accessors"] = accessors
      j["buffers"] = [uri.map { ["byteLength": bin.count, "uri": $0] } ?? ["byteLength": bin.count]]
      return j
    }
    func glb(_ body: [String: Any]) throws -> Data {
      var text = try JSONSerialization.data(withJSONObject: json(body))
      while text.count % 4 != 0 { text.append(0x20) }
      var payload = bin
      while payload.count % 4 != 0 { payload.append(0) }
      var out = Data("glTF".utf8)
      func u32(_ v: Int) { var x = UInt32(v).littleEndian; out.append(Data(bytes: &x, count: 4)) }
      u32(2); u32(12 + 8 + text.count + 8 + payload.count)
      u32(text.count); u32(0x4E4F_534A); out.append(text)
      u32(payload.count); u32(0x004E_4942); out.append(payload)
      return out
    }
  }

  // --- GLB: hierarchy, primitives, cameras, material extensions -------------------------------------
  var b = Builder()
  var quad = b.quad(size: 2)
  quad["material"] = 0
  // A strip of two triangles without normals or indices (face normals), bound to material 1.
  let strip = b.add([0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0], type: "VEC3")
  let half = Float.pi / 4
  let body: [String: Any] = [
    "scene": 0, "scenes": [["nodes": [0, 2]]],
    "nodes": [
      ["name": "Parent", "translation": [1, 2, 3], "rotation": [0, sin(half), 0, cos(half)], "children": [1]],
      ["name": "Child", "mesh": 0, "scale": [2, 2, 2]],
      ["name": "Eye", "camera": 0, "translation": [0, 1, 5]],
    ],
    "meshes": [["name": "Parts", "primitives": [quad, ["attributes": ["POSITION": strip], "mode": 5, "material": 1]]]],
    "cameras": [["type": "perspective", "perspective": ["yfov": 0.6, "znear": 0.01]]],
    "materials": [
      ["name": "Titanium", "pbrMetallicRoughness": ["baseColorFactor": [0.5, 0.5, 0.5, 1], "metallicFactor": 1, "roughnessFactor": 0.4],
       "extensions": ["KHR_materials_anisotropy": ["anisotropyStrength": 0.5, "anisotropyRotation": Double.pi / 2],
                      "KHR_materials_iridescence": ["iridescenceFactor": 1, "iridescenceIor": 1.13, "iridescenceThicknessMaximum": 300]]],
      ["name": "Glass", "pbrMetallicRoughness": ["metallicFactor": 0, "roughnessFactor": 0],
       "extensions": ["KHR_materials_transmission": ["transmissionFactor": 1], "KHR_materials_ior": ["ior": 1.45],
                      "KHR_materials_volume": ["thicknessFactor": 1, "attenuationDistance": 2, "attenuationColor": [0.5, 0.8, 0.9]]]],
    ],
    "extensionsUsed": ["KHR_materials_anisotropy", "KHR_materials_iridescence", "KHR_materials_transmission",
                       "KHR_materials_ior", "KHR_materials_volume", "EXT_unknown_thing"],
  ]
  let glbURL = folder.appendingPathComponent("parts.glb")
  try b.glb(body).write(to: glbURL)
  let imported = try GLTFImporter.load(glbURL, into: ProjectDocument())
  let p = imported.document
  guard let graph = p.graph, let asset = graph.assets.first else { require(false, "glTF: the GLB imports a mesh"); return }
  require(graph.assets.count == 1 && asset.subsets == ["Titanium", "Glass"] && asset.geometry.count == 4,
    "glTF: one asset per mesh with a subset per primitive, strips triangulated (\(asset.subsets), \(asset.geometry.count) triangles)")
  let stripFaces = asset.geometry.faces.filter { $0.w == 1 }
  require(stripFaces.count == 2 && stripFaces.allSatisfy { f in
      [f.x, f.y, f.z].allSatisfy { simd_distance(SIMD3(asset.geometry.vertices[Int($0)][3], asset.geometry.vertices[Int($0)][4],
        asset.geometry.vertices[Int($0)][5]), SIMD3(0, 0, 1)) < 1e-6 } },
    "glTF: primitives without normals get face normals")
  if let child = graph.nodes.first(where: { $0.name == "Child" }) {
    let (world, _) = graph.worldTransform(child.id)
    let x = world * SIMD4<Float>(1, 0, 0, 1)
    // Parent: +90 degrees about Y (x -> -z) after the child's scale 2, then translation (1, 2, 3).
    require(simd_distance(SIMD3(x.x, x.y, x.z), SIMD3(1, 2, 1)) < 1e-5, "glTF: node TRS composes parent x child (\(x))")
  } else { require(false, "glTF: the child node is imported") }
  require(abs((p.views["glTF: Eye"]?.fov ?? 0) - 0.6 * 180 / .pi) < 1e-3 && p.camera.fov == p.views["glTF: Eye"]?.fov,
    "glTF: a perspective camera becomes the opening view with its vertical FOV (\(p.views.keys.sorted()))")
  require(imported.report.contains { $0.contains("EXT_unknown_thing") }, "glTF: unsupported extensions are reported")
  let programs = p.scenes[6]?.materialX ?? [:]
  let slot = { (name: String) in graph.materials.first { $0.name == name }.flatMap { programs[$0.slot] } }
  if let titanium = slot("Titanium") {
    require(abs((titanium.anisotropyRotation ?? 0) - .pi / 2) < 1e-5,
      "glTF: anisotropyRotation becomes the rotated geometry_tangent (\(String(describing: titanium.anisotropyRotation)))")
    require(titanium.spectral.map { abs($0.y - 1) < 1e-6 && abs($0.z - 0.3) < 1e-6 && abs($0.w - 1.13) < 1e-6 } == true,
      "glTF: iridescence becomes a 0.3 um thin film of IOR 1.13 (\(String(describing: titanium.spectral)))")
  } else { require(false, "glTF: the anisotropic material compiles (\(imported.report))") }
  if let glass = slot("Glass") {
    require(glass.medium == SIMD4(0, 0, 0, 2) && glass.transmissionColor == SIMD3(0.5, 0.8, 0.9) && glass.thinWalled == nil,
      "glTF: volume attenuation becomes transmission_color at transmission_depth (\(String(describing: glass.medium)))")
  } else { require(false, "glTF: the glass material compiles (\(imported.report))") }
  // glTF's alpha_t = mix(alpha, 1, s^2) and alpha_b = alpha through OpenPBR's anisotropic alpha.
  for (r, s) in [(Float(0.4), Float(0.5)), (0.05, 0.15), (0.9, 1), (0.3, 0)] {
    let (roughness, a) = GLTFImporter.Reader.anisotropic(roughness: r, strength: s)
    let alpha = roughness * roughness, ax = alpha * (2 / (1 + (1 - a) * (1 - a))).squareRoot(), ay = (1 - a) * ax
    let alphaT = r * r + s * s * (1 - r * r)
    require(abs(ax - alphaT) < 1e-5 && abs(ay - r * r) < 1e-5, "glTF anisotropy maps to OpenPBR (r \(r), s \(s): \(ax), \(ay))")
  }
  print("PASS: glTF GLB: hierarchy, strips and face normals, cameras, anisotropy, iridescence, volume")

  // --- .gltf with an external buffer and textures: mask, texture transform, baked anisotropic roughness ---
  var t = Builder()
  var textured = t.quad(size: 1)
  textured["material"] = 0
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
  for i in 0..<16 { rep.bitmapData![4 * i] = 255; rep.bitmapData![4 * i + 1] = UInt8(i * 16); rep.bitmapData![4 * i + 2] = 0; rep.bitmapData![4 * i + 3] = i < 8 ? 0 : 255 }
  try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("maps file.png"))
  let transform: [String: Any] = ["KHR_texture_transform": ["offset": [0.5, 0], "scale": [2, 2], "rotation": 0.3]]
  let texturedBody: [String: Any] = [
    "nodes": [["mesh": 0]], "meshes": [["primitives": [textured]]],
    "images": [["uri": "maps%20file.png"]], "samplers": [["wrapS": 33071, "wrapT": 33648]],
    "textures": [["source": 0, "sampler": 0]],
    "materials": [["name": "Leaf", "alphaMode": "MASK", "alphaCutoff": 0.4,
      "pbrMetallicRoughness": ["baseColorTexture": ["index": 0, "extensions": transform],
                               "metallicRoughnessTexture": ["index": 0]],
      "extensions": ["KHR_materials_anisotropy": ["anisotropyStrength": 0.3]]]],
  ]
  try t.bin.write(to: folder.appendingPathComponent("leaf.bin"))
  let gltfURL = folder.appendingPathComponent("leaf.gltf")
  try JSONSerialization.data(withJSONObject: t.json(texturedBody, uri: "leaf.bin")).write(to: gltfURL)
  let leaf = try GLTFImporter.load(gltfURL, into: ProjectDocument())
  let leafProgram = leaf.document.scenes[6]?.materialX?.values.first
  require(leafProgram?.opacity != nil && (leafProgram?.images.count ?? 0) >= 3 && leafProgram?.anisotropyRotation == nil,
    "glTF: a masked, transformed, anisotropic textured material compiles with coverage and baked maps (\(leaf.report))")
  require(leaf.report.contains { $0.contains("mirrored-repeat") }, "glTF: mirrored-repeat wrapping is reported")
  var required = texturedBody
  required["extensionsRequired"] = ["KHR_draco_mesh_compression"]
  try JSONSerialization.data(withJSONObject: t.json(required, uri: "leaf.bin")).write(to: gltfURL)
  var refusal = ""
  do { _ = try GLTFImporter.load(gltfURL, into: ProjectDocument()) } catch { refusal = error.localizedDescription }
  require(refusal.contains("KHR_draco_mesh_compression"), "glTF: a required unsupported extension is refused (\(refusal))")
  print("PASS: glTF external buffer: alpha mask, texture transform, wrap modes, baked anisotropic roughness, required extensions")

  // --- MaterialX: geometry_tangent accepts only the tangent rotated about the normal by a constant ---
  func tangentDocument(_ graph: String) -> Data {
    Data("""
      <?xml version="1.0"?>
      <materialx version="1.39">
        <tangent name="t" type="vector3"><input name="space" type="string" value="world"/></tangent>
        <normal name="n" type="vector3"><input name="space" type="string" value="world"/></normal>
        \(graph)
        <open_pbr_surface name="S" type="surfaceshader">
          <input name="specular_roughness_anisotropy" type="float" value="0.5"/>
          <input name="geometry_tangent" type="vector3" nodename="out"/>
        </open_pbr_surface>
      </materialx>
      """.utf8)
  }
  let rotated = try MaterialXImporter.read(tangentDocument("""
    <rotate3d name="out" type="vector3"><input name="in" type="vector3" nodename="t"/>
      <input name="amount" type="float" value="-30"/><input name="axis" type="vector3" nodename="n"/></rotate3d>
    """), baseURL: folder, source: "tangent")
  require(abs((rotated.materials.first?.anisotropyRotation ?? 0) - .pi / 6) < 1e-6,
    "MaterialX: rotate3d of the tangent about the normal by -30 degrees turns anisotropy 30 degrees toward the bitangent")
  let wrongAxis = try MaterialXImporter.read(tangentDocument("""
    <rotate3d name="out" type="vector3"><input name="in" type="vector3" nodename="t"/>
      <input name="amount" type="float" value="45"/><input name="axis" type="vector3" value="0, 1, 0"/></rotate3d>
    """), baseURL: folder, source: "tangent")
  require(wrongAxis.materials.isEmpty && wrongAxis.report.contains { $0.contains("geometry_tangent") },
    "MaterialX: a tangent rotated about a constant axis is rejected (\(wrongAxis.report))")

  // --- GPU: the anisotropic highlight of a rough metal quad is longest along the rotated tangent ---
  func anisotropicQuad(_ rotation: Double) throws -> ProjectDocument {
    var q = Builder()
    var plate = q.quad(size: 3)
    plate["material"] = 0
    var lamp = q.quad(size: 0.15)
    lamp["material"] = 1
    let url = folder.appendingPathComponent("highlight-\(rotation).glb")
    try q.glb([
      "nodes": [["mesh": 0], ["mesh": 1, "translation": [0, 0, 3], "rotation": [1, 0, 0, 0]]],
      "meshes": [["primitives": [plate]], ["primitives": [lamp]]],
      "materials": [
        ["pbrMetallicRoughness": ["baseColorFactor": [0.9, 0.9, 0.9, 1], "metallicFactor": 1, "roughnessFactor": 0.2],
         "extensions": ["KHR_materials_anisotropy": ["anisotropyStrength": 0.7, "anisotropyRotation": rotation]]],
        ["pbrMetallicRoughness": ["baseColorFactor": [0, 0, 0, 1]], "emissiveFactor": [1, 1, 1],
         "extensions": ["KHR_materials_emissive_strength": ["emissiveStrength": 200]]],
      ],
    ]).write(to: url)
    return try GLTFImporter.load(url, into: ProjectDocument()).document
  }
  let w = 64, h = 64
  var spreads: [SIMD2<Float>] = []
  for rotation in [0, Double.pi / 2] {
    try controller.restore(try anisotropicQuad(rotation))
    var v = makeUniforms(scene: 6, mode: 1, width: w, height: h)
    let eye = SIMD3<Float>(0, 0, 2.2)
    v.cameraPos = SIMD4(eye, 60); v.cameraTarget = SIMD4(0, 0, 0, 8)
    v.currentViewProj = makePerspective(fovyRadians: 60 * .pi / 180, aspect: 1, near: 0.05, far: 100)
      * makeLookAt(eye: eye, target: .zero, up: SIMD3(0, 1, 0))
    v.prevViewProj = v.currentViewProj
    v.environment = .zero
    v.sunParams.w = 0
    v.lens.z = 1
    let pixels = render(v, samples: 64)
    // Luminance-weighted spread of the highlight about the image centre, in x and y.
    var total: Float = 0, spread = SIMD2<Float>(repeating: 0)
    for (i, c) in pixels.enumerated() {
      let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
      let d = SIMD2(Float(i % w) - Float(w) / 2 + 0.5, Float(i / w) - Float(h) / 2 + 0.5)
      total += l; spread += l * d * d
    }
    spreads.append((spread / max(total, 1e-6)).squareRoot())
  }
  print("glTF anisotropic highlight spread (x, y): rotation 0 \(spreads[0]), rotation 90 degrees \(spreads[1])")
  require(spreads[0].x > 1.3 * spreads[0].y && spreads[1].y > 1.3 * spreads[1].x,
    "glTF: the anisotropic highlight stretches along the tangent, and along the bitangent when rotated 90 degrees (\(spreads))")
  print("PASS: glTF anisotropy rotation on the GPU; MaterialX rotated geometry_tangent")

  // --- GPU: absorbing glass is coloured by its volume only, not again at its surfaces ---
  // A glass slab 1 m thick (attenuation 0.5 at 1 m) in front of a white emitter passes half the light of a
  // clear slab; tinting at both interfaces as well would pass an eighth.
  func slab(_ attenuation: Float) throws -> ProjectDocument {
    var q = Builder()
    var front = q.quad(size: 3), back = q.quad(size: 3), lamp = q.quad(size: 6)
    front["material"] = 0; back["material"] = 0; lamp["material"] = 1
    let url = folder.appendingPathComponent("slab-\(attenuation).glb")
    try q.glb([
      "nodes": [["mesh": 0, "translation": [0, 0, 0.5]], ["mesh": 1, "translation": [0, 0, -0.5], "rotation": [0, 1, 0, 0]],
                ["mesh": 2, "translation": [0, 0, -2]]],
      "meshes": [["primitives": [front]], ["primitives": [back]], ["primitives": [lamp]]],
      "materials": [
        ["pbrMetallicRoughness": ["metallicFactor": 0, "roughnessFactor": 0],
         "extensions": ["KHR_materials_transmission": ["transmissionFactor": 1],
                        "KHR_materials_volume": ["thicknessFactor": 1, "attenuationDistance": 1,
                                                 "attenuationColor": [attenuation, attenuation, attenuation]]]],
        ["pbrMetallicRoughness": ["baseColorFactor": [0, 0, 0, 1]], "emissiveFactor": [1, 1, 1]],
      ],
    ]).write(to: url)
    return try GLTFImporter.load(url, into: ProjectDocument()).document
  }
  var through: [Float] = []
  for attenuation in [Float(1), 0.5] {
    try controller.restore(try slab(attenuation))
    var v = makeUniforms(scene: 6, mode: 1, width: 32, height: 32)
    let eye = SIMD3<Float>(0, 0, 3)
    v.cameraPos = SIMD4(eye, 20); v.cameraTarget = SIMD4(0, 0, 0, 8)
    v.currentViewProj = makePerspective(fovyRadians: 20 * .pi / 180, aspect: 1, near: 0.05, far: 100)
      * makeLookAt(eye: eye, target: .zero, up: SIMD3(0, 1, 0))
    v.prevViewProj = v.currentViewProj
    v.environment = .zero
    v.sunParams.w = 0
    v.lens.z = 1
    let pixels = render(v, samples: 64)
    let centre = pixels.indices.filter { abs($0 % 32 - 16) < 8 && abs($0 / 32 - 16) < 8 }
    through.append(centre.reduce(0) { $0 + 0.2126 * pixels[$1].x + 0.7152 * pixels[$1].y + 0.0722 * pixels[$1].z } / Float(centre.count))
  }
  print("glTF absorbing glass slab: clear \(through[0]), attenuation 0.5 per metre \(through[1]), ratio \(through[1] / through[0]) (expected 0.5)")
  require(through[0] > 0.5 && abs(through[1] / through[0] - 0.5) < 0.03,
    "glTF: glass with volume attenuation is coloured by Beer-Lambert only, not tinted again at its surfaces (\(through))")
  print("PASS: glTF absorbing glass: Beer-Lambert without surface tint")
}
try fixGLTFChecks()
