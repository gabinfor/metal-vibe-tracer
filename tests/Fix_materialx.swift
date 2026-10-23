// Regression checks for MaterialX import/compilation and material image decoding
// (R-23..R-28, R-73, R-74, R-129, R-130). Locally authored synthetic fixtures only.
@MainActor func fixMaterialXChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("fix-materialx", isDirectory: true)
  let docs = folder.appendingPathComponent("docs", isDirectory: true)
  try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
  // Uniform 2×2 PNGs; 16-bit samples use v*257 so their byte order is irrelevant.
  func png(_ name: String, samples: Int, bits: Int, _ values: [Int]) throws -> Data {
    let alpha = samples == 2 || samples == 4
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: bits,
      samplesPerPixel: samples, hasAlpha: alpha, isPlanar: false,
      colorSpaceName: samples <= 2 ? .deviceWhite : .deviceRGB,
      bitmapFormat: alpha ? .alphaNonpremultiplied : [], bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<2 {
      for x in 0..<2 {
        for c in 0..<samples {
          let offset = y * rep.bytesPerRow + x * rep.bitsPerPixel / 8 + c * bits / 8
          rep.bitmapData![offset] = UInt8(values[c])
          if bits == 16 { rep.bitmapData![offset + 1] = UInt8(values[c]) }
        }
      }
    }
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: folder.appendingPathComponent(name))
    return data
  }
  let gray8 = try png("gray8.png", samples: 1, bits: 8, [153])
  _ = try png("grayAlpha8.png", samples: 2, bits: 8, [153, 200])
  let rgba16 = try png("rgba16.png", samples: 4, bits: 16, [153, 153, 153, 255])
  let gray16 = try png("gray16.png", samples: 1, bits: 16, [153])
  _ = try png("grayAlpha16.png", samples: 2, bits: 16, [153, 200])
  let srgb: Float = 0.31855  // sRGB EOTF of 0.6 (153/255)
  let alpha: Float = 200.0 / 255.0
  func close(_ a: Float, _ b: Float, _ tolerance: Float = 0.004) -> Bool { abs(a - b) < tolerance }
  func mx(_ body: String, root: String = "", base: URL? = nil) throws -> MaterialXImport {
    try MaterialXImporter.read(
      Data(("<materialx version=\"1.39\"\(root)>" + body + "</materialx>").utf8),
      baseURL: base ?? folder, source: "Fix.mtlx")
  }
  func extract(_ name: String, _ source: String, _ type: String, _ index: Int) -> String {
    "<extract name=\"\(name)\" type=\"float\"><input name=\"in\" type=\"\(type)\" nodename=\"\(source)\"/><input name=\"index\" type=\"integer\" value=\"\(index)\"/></extract>"
  }
  func image(_ name: String, _ type: String, _ file: String, _ colorspace: String?) -> String {
    "<image name=\"\(name)\" type=\"\(type)\"\(colorspace.map { " colorspace=\"\($0)\"" } ?? "")><input name=\"file\" type=\"filename\" value=\"\(file)\"/></image>"
  }

  // R-25: rotate2d follows mx_rotate_vector2, (x, y) -> (ca*x + sa*y, -sa*x + ca*y).
  let rotate = try mx(
    """
    <rotate2d name="rot" type="vector2"><input name="in" type="vector2" value="0.3,0.1"/><input name="amount" type="float" value="90"/></rotate2d>
    <add name="shift" type="vector2"><input name="in1" type="vector2" nodename="rot"/><input name="in2" type="vector2" value="0.5,0.5"/></add>
    \(extract("rx", "shift", "vector2", 0))\(extract("ry", "shift", "vector2", 1))
    <open_pbr_surface name="Rotate" type="surfaceshader"><input name="base_metalness" type="float" nodename="rx"/><input name="coat_weight" type="float" nodename="ry"/></open_pbr_surface>
    """)
  require(rotate.materials.count == 1, "rotate2d graph compiles: \(rotate.report)")

  // R-27: nodes named after the input they drive are not the input itself.
  let collide = try mx(
    """
    <constant name="base_color" type="color3"><input name="value" type="color3" value="0.1,0.2,0.3"/></constant>
    <nodegraph name="specular_roughness"><constant name="r" type="float"><input name="value" type="float" value="0.45"/></constant><output name="out" type="float" nodename="r"/></nodegraph>
    <texcoord name="texcoord" type="vector2"/>
    <image name="gray" type="color3" colorspace="srgb_texture"><input name="file" type="filename" value="gray8.png"/><input name="texcoord" type="vector2" nodename="texcoord"/></image>
    <open_pbr_surface name="Collide" type="surfaceshader"><input name="base_color" type="color3" nodename="base_color"/><input name="specular_roughness" type="float" nodegraph="specular_roughness"/></open_pbr_surface>
    <open_pbr_surface name="Gray" type="surfaceshader"><input name="base_color" type="color3" nodename="gray"/></open_pbr_surface>
    <open_pbr_surface name="GrayAgain" type="surfaceshader"><input name="base_color" type="color3" nodename="gray"/><input name="specular_roughness" type="float" value="0.7"/></open_pbr_surface>
    """)
  require(
    collide.materials.map(\.name) == ["Collide", "Gray", "GrayAgain"],
    "node/nodegraph names matching input names resolve: \(collide.report)")

  // R-23/R-24: grayscale, gray+alpha and 16-bit images decode as RGBA with sRGB applied.
  let wide = try mx(
    image("ga8", "color4", "grayAlpha8.png", "srgb_texture")
      + extract("ga8a", "ga8", "color4", 3) + extract("ga8g", "ga8", "color4", 1)
      + extract("ga8b", "ga8", "color4", 2)
      + "<open_pbr_surface name=\"GrayAlpha\" type=\"surfaceshader\"><input name=\"base_metalness\" type=\"float\" nodename=\"ga8a\"/><input name=\"coat_weight\" type=\"float\" nodename=\"ga8g\"/><input name=\"specular_roughness\" type=\"float\" nodename=\"ga8b\"/></open_pbr_surface>"
      + image("c16", "color3", "rgba16.png", "srgb_texture")
      + image("g16", "color3", "gray16.png", "srgb_texture") + extract("g16g", "g16", "color3", 1)
      + image("ga16", "color4", "grayAlpha16.png", "srgb_texture")
      + extract("ga16a", "ga16", "color4", 3)
      + image("r16", "float", "gray16.png", nil)
      + "<open_pbr_surface name=\"Wide\" type=\"surfaceshader\"><input name=\"base_color\" type=\"color3\" nodename=\"c16\"/><input name=\"coat_weight\" type=\"float\" nodename=\"g16g\"/><input name=\"base_metalness\" type=\"float\" nodename=\"ga16a\"/><input name=\"specular_roughness\" type=\"float\" nodename=\"r16\"/></open_pbr_surface>"
  )
  require(wide.materials.count == 2, "grayscale and 16-bit image graphs compile: \(wide.report)")

  // R-26: inherited sRGB applies only to color images; explicit tags on others are reported.
  let raw = try mx(
    image("rough", "float", "gray8.png", nil) + image("vec", "vector3", "gray8.png", "srgb_texture")
      + extract("vx", "vec", "vector3", 0)
      + "<open_pbr_surface name=\"Raw\" type=\"surfaceshader\"><input name=\"specular_roughness\" type=\"float\" nodename=\"rough\"/><input name=\"base_metalness\" type=\"float\" nodename=\"vx\"/></open_pbr_surface>",
    root: " colorspace=\"srgb_texture\"")
  require(raw.materials.count == 1, "document-colorspace float/vector images compile: \(raw.report)")
  require(
    raw.materials[0].images.allSatisfy { !$0.srgb }
      && raw.report.contains { $0.contains("ignored on vector3 image") },
    "sRGB colorspace ignored and reported on non-color images: \(raw.report)")
  let unsupportedFloat = try mx(
    image("aces", "float", "gray8.png", nil)
      + "<open_pbr_surface name=\"AcesFloat\" type=\"surfaceshader\"><input name=\"specular_roughness\" type=\"float\" nodename=\"aces\"/></open_pbr_surface>",
    root: " colorspace=\"acescg\"")
  require(unsupportedFloat.materials.count == 1, "inherited OCIO tag does not reject a float image")

  // R-28: default subsurface inputs, valueless geometry frames and explicit tangent space import.
  let full = try mx(
    """
    <normalmap name="nm" type="vector3"><input name="in" type="vector3" value="0.5,0.5,1"/><input name="space" type="string" value="tangent"/><input name="normal" type="vector3"/></normalmap>
    <open_pbr_surface name="Full" type="surfaceshader">
     <input name="subsurface_weight" type="float" value="0"/><input name="subsurface_color" type="color3" value="0.8,0.8,0.8"/>
     <input name="subsurface_radius" type="float" value="1"/><input name="subsurface_radius_scale" type="color3" value="1,0.5,0.25"/>
     <input name="subsurface_scatter_anisotropy" type="float" value="0"/><input name="geometry_normal" type="vector3" nodename="nm"/>
     <input name="geometry_tangent" type="vector3"/><input name="geometry_coat_normal" type="vector3"/><input name="geometry_coat_tangent" type="vector3" defaultgeomprop="Tworld"/>
    </open_pbr_surface>
    """)
  require(full.materials.count == 1, "OpenPBR default subsurface/geometry inputs import: \(full.report)")
  for (body, message) in [
    ("<normalmap name=\"nm\" type=\"vector3\"><input name=\"in\" type=\"vector3\" value=\"0.5,0.5,1\"/><input name=\"space\" type=\"string\" value=\"object\"/></normalmap><open_pbr_surface name=\"bad\" type=\"surfaceshader\"><input name=\"geometry_normal\" type=\"vector3\" nodename=\"nm\"/></open_pbr_surface>", "Object-space"),
    ("<open_pbr_surface name=\"bad\" type=\"surfaceshader\"><input name=\"subsurface_color\" type=\"color3\" value=\"0.5,0.5,0.5\"/></open_pbr_surface>", "Non-default subsurface_color"),
    ("<open_pbr_surface name=\"bad\" type=\"surfaceshader\"><input name=\"geometry_tangent\" type=\"vector3\" value=\"1,0,0\"/></open_pbr_surface>", "geometry_tangent must keep"),
    ("<open_pbr_surface name=\"bad\" type=\"surfaceshader\"><input name=\"geometry_coat_normal\" type=\"vector3\" defaultgeomprop=\"Tworld\"/></open_pbr_surface>", "geometry_coat_normal must keep"),
  ] {
    let rejected = try mx(body)
    require(
      rejected.materials.isEmpty && rejected.report.joined().contains(message),
      "specific OpenPBR/normalmap rejection '\(message)': \(rejected.report)")
  }

  // R-73: out-of-folder images are reported; oversized and non-regular files are not read.
  let outside = try mx(
    image("up", "color3", "../gray8.png", "srgb_texture")
      + "<open_pbr_surface name=\"Up\" type=\"surfaceshader\"><input name=\"base_color\" type=\"color3\" nodename=\"up\"/></open_pbr_surface>",
    base: docs)
  require(
    outside.materials.count == 1
      && outside.report.contains { $0.contains("outside the document folder") },
    "out-of-folder image listed in the report: \(outside.report)")
  require(
    !collide.report.contains { $0.contains("outside the document folder") },
    "in-folder images are not flagged")
  let huge = folder.appendingPathComponent("huge.png")
  FileManager.default.createFile(atPath: huge.path, contents: nil)
  let hugeHandle = try FileHandle(forWritingTo: huge)
  try hugeHandle.truncate(atOffset: 129 * 1024 * 1024)
  try hugeHandle.close()
  try? FileManager.default.createDirectory(
    at: folder.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
  for (file, message) in [("huge.png", "128 MiB"), ("folder.png", "not a regular file")] {
    let rejected = try mx(
      image("i", "color3", file, nil)
        + "<open_pbr_surface name=\"bad\" type=\"surfaceshader\"><input name=\"base_color\" type=\"color3\" nodename=\"i\"/></open_pbr_surface>")
    require(
      rejected.materials.isEmpty && rejected.report.joined().contains(message),
      "image file checked before reading (\(message)): \(rejected.report)")
  }
  try FileManager.default.removeItem(at: huge)
  let bigDocument = folder.appendingPathComponent("big.mtlx")
  FileManager.default.createFile(atPath: bigDocument.path, contents: nil)
  let bigHandle = try FileHandle(forWritingTo: bigDocument)
  try bigHandle.truncate(atOffset: 17_000_000)
  try bigHandle.close()
  do {
    _ = try MaterialXImporter.load(bigDocument)
    require(false, "oversized MaterialX document rejected")
  } catch { require(error.localizedDescription.contains("16 MB"), "document size message") }
  try FileManager.default.removeItem(at: bigDocument)
  let documentURL = docs.appendingPathComponent("Rotate.mtlx")
  try (
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<materialx version=\"1.39\">"
      + image("up", "color3", "../gray8.png", "srgb_texture")
      + "<open_pbr_surface name=\"FromFile\" type=\"surfaceshader\"><input name=\"base_color\" type=\"color3\" nodename=\"up\"/></open_pbr_surface></materialx>"
  ).write(to: documentURL, atomically: true, encoding: .utf8)
  let fromFile = try MaterialXImporter.load(documentURL)
  require(fromFile.materials.count == 1, "UTF-8 declared file loads: \(fromFile.report)")

  // R-129: non-UTF-8 declared encodings are rejected before libxml2 decodes them.
  do {
    _ = try MaterialXImporter.read(
      Data("<?xml version=\"1.0\" encoding=\"UTF-7\"?><materialx version=\"1.39\"/>".utf8),
      baseURL: folder, source: "Fix.mtlx")
    require(false, "UTF-7 declared MaterialX rejected")
  } catch { require(error.localizedDescription.contains("declared encoding"), "encoding message: \(error)") }

  // R-130: XML syntax errors carry their location.
  do {
    _ = try MaterialXImporter.read(
      Data("<materialx version=\"1.39\">\n<open_pbr_surface name=\"a\" type=\"surfaceshader\">\n</materialx>".utf8),
      baseURL: folder, source: "Fix.mtlx")
    require(false, "malformed MaterialX rejected")
  } catch {
    require(error.localizedDescription.contains("line 3"), "XML error line number: \(error.localizedDescription)")
  }

  // R-25: USD Transform2d stays counter-clockwise; direct ND_rotate2d follows MaterialX.
  let usda = folder.appendingPathComponent("transform2d.usda")
  try """
    #usda 1.0
    (
        metersPerUnit = 1
        upAxis = "Y"
    )
    def Mesh "Quad" (
        prepend apiSchemas = ["MaterialBindingAPI"]
    )
    {
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
        uniform token subdivisionScheme = "none"
        rel material:binding = </Rotated>
    }
    def Material "Rotated"
    {
        token outputs:mtlx:surface.connect = </Rotated/Surface.outputs:out>
        def Shader "Surface"
        {
            uniform token info:id = "ND_open_pbr_surface_surfaceshader"
            float inputs:base_metalness.connect = </Rotated/X.outputs:out>
            float inputs:coat_weight.connect = </Rotated/Y.outputs:out>
            float inputs:specular_roughness.connect = </Rotated/R.outputs:out>
            token outputs:out
        }
        def Shader "T"
        {
            uniform token info:id = "UsdTransform2d"
            float2 inputs:in = (0.3, 0.1)
            float inputs:rotation = 90
            float2 inputs:translation = (0.5, 0.5)
            float2 outputs:result
        }
        def Shader "X"
        {
            uniform token info:id = "ND_extract_vector2"
            float2 inputs:in.connect = </Rotated/T.outputs:result>
            int inputs:index = 0
            float outputs:out
        }
        def Shader "Y"
        {
            uniform token info:id = "ND_extract_vector2"
            float2 inputs:in.connect = </Rotated/T.outputs:result>
            int inputs:index = 1
            float outputs:out
        }
        def Shader "Rot"
        {
            uniform token info:id = "ND_rotate2d_vector2"
            float2 inputs:in = (0.3, 0.1)
            float inputs:amount = 90
            float2 outputs:out
        }
        def Shader "Shift"
        {
            uniform token info:id = "ND_add_vector2"
            float2 inputs:in1.connect = </Rotated/Rot.outputs:out>
            float2 inputs:in2 = (0.5, 0.5)
            float2 outputs:out
        }
        def Shader "R"
        {
            uniform token info:id = "ND_extract_vector2"
            float2 inputs:in.connect = </Rotated/Shift.outputs:out>
            int inputs:index = 0
            float outputs:out
        }
    }
    """.write(to: usda, atomically: true, encoding: .utf8)
  let usdImport = try USDImporter.load(usda, into: ProjectDocument())
  guard let usdProgram = usdImport.document.scenes[6]?.materialX?.values.first else {
    require(false, "USD Transform2d material compiles: \(usdImport.report)")
    return
  }

  // GPU evaluation through the production resolve_materialx and material-map sampling.
  let kernel = """
    kernel void fix_materialx_eval(constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]], constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(3)]], constant uint &slot [[buffer(4)]]) {
     HitRecord h={};h.t=1;h.normal=float3(0,0,-1);h.front_face=true;h.mat.slot=slot;h.uv=float2(0.25f);
     h.tangent=float3(1,0,0);h.bitangent=float3(0,1,0);h.uvDensity=float2(0);h.geometricNormal=h.normal;
     Ray r={float3(0,0,-1),float3(0,0,1)};
     resolve_materialx(h,r,images,TextureFootprint{});
     out[0]=float4(h.mat.albedo,h.mat.roughness);out[1]=float4(h.mat.metalness,h.mat.coat,0,0);
     for(uint c=0;c<4;++c) out[2+c]=sample_material_map(images,slot,c,float2(0.25f),TextureFootprint{});
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernel, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(
    function: library.makeFunction(name: "fix_materialx_eval")!)
  func evaluate(_ slot: Int) -> [SIMD4<Float>] {
    var u = makeUniforms(scene: 6, mode: 0, width: 1, height: 1)
    var index = UInt32(slot)
    let buffer = gpu.makeBuffer(length: 6 * 16, options: .storageModeShared)!
    let command = testRenderer.commandQueue.makeCommandBuffer()!
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    testRenderer.materials.bind(encoder)
    encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setBuffer(buffer, offset: 0, index: 3)
    encoder.setBytes(&index, length: 4, index: 4)
    encoder.dispatchThreads(
      MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    require(command.status == .completed, "fix-materialx GPU evaluation")
    return (0..<6).map { buffer.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  }

  // Inspector maps through both decode entry points (project restore and file load).
  var state = SceneState()
  state.maps[31 * 4 + 0] = rgba16
  state.maps[31 * 4 + 1] = gray16
  state.maps[31 * 4 + 3] = gray8
  try testRenderer.materials.restore(state)
  try testRenderer.materials.load(url: folder.appendingPathComponent("gray8.png"), slot: 30, channel: 0)
  try testRenderer.materials.load(url: folder.appendingPathComponent("grayAlpha8.png"), slot: 30, channel: 1)
  let programs: [Int: MaterialXProgram] = [
    8: rotate.materials[0], 9: collide.materials[0], 10: collide.materials[1],
    11: collide.materials[2], 12: wide.materials[0], 13: wide.materials[1], 14: raw.materials[0],
    15: usdProgram,
  ]
  try testRenderer.materials.prepareMaterialX(programs)
  let uniqueImages = Set(programs.values.flatMap { $0.images.map { "\($0.srgb)" + $0.data.base64EncodedString() } })
  require(
    testRenderer.materials.graphTextures.count == uniqueImages.count
      && collide.materials[1].images[0].data == collide.materials[2].images[0].data,
    "shared MaterialX images decode and bind once (R-74)")

  let rotated = evaluate(8)
  print("fix-materialx rotate2d: \(rotated[1])")
  require(close(rotated[1].x, 0.6, 1e-4) && close(rotated[1].y, 0.2, 1e-4), "MaterialX rotate2d(90) direction")
  let collided = evaluate(9)
  require(
    simd_length(SIMD3(collided[0].x, collided[0].y, collided[0].z) - SIMD3(0.1, 0.2, 0.3)) < 1e-4
      && close(collided[0].w, 0.45, 1e-4), "name-collision graph values")
  for slot in [10, 11] {
    let gray = evaluate(slot)[0]
    require(
      close(gray.x, srgb) && close(gray.y, srgb) && close(gray.z, srgb),
      "grayscale color3 image broadcasts after sRGB decoding: \(gray)")
  }
  let grayAlpha = evaluate(12)
  print("fix-materialx gray+alpha: \(grayAlpha[0]) \(grayAlpha[1])")
  require(
    close(grayAlpha[1].x, alpha) && close(grayAlpha[1].y, srgb) && close(grayAlpha[0].w, srgb),
    "gray+alpha color4 image reads (g, g, g, a)")
  let deep = evaluate(13)
  print("fix-materialx 16-bit: \(deep[0]) \(deep[1])")
  require(
    close(deep[0].x, srgb) && close(deep[0].y, srgb) && close(deep[0].z, srgb),
    "16-bit sRGB color image is linearized")
  require(close(deep[1].y, srgb) && close(deep[1].x, alpha), "16-bit gray and gray+alpha sRGB images")
  require(close(deep[0].w, 0.6), "16-bit raw float image stays linear")
  let rawValues = evaluate(14)
  require(
    close(rawValues[0].w, 0.6) && close(rawValues[1].x, 0.6),
    "document sRGB does not decode float/vector images: \(rawValues[0]) \(rawValues[1])")
  let usdValues = evaluate(15)
  print("fix-materialx USD Transform2d/rotate2d: \(usdValues[0]) \(usdValues[1])")
  require(
    close(usdValues[1].x, 0.4, 1e-4) && close(usdValues[1].y, 0.8, 1e-4),
    "USD Transform2d rotates counter-clockwise")
  require(close(usdValues[0].w, 0.6, 1e-4), "USD ND_rotate2d follows MaterialX")
  let loaded = evaluate(30)
  print("fix-materialx maps: \(loaded[2]) \(loaded[3])")
  require(
    close(loaded[2].x, srgb) && close(loaded[2].y, srgb) && close(loaded[2].z, srgb)
      && close(loaded[2].w, 1), "grayscale albedo map broadcasts")
  require(
    close(loaded[3].x, 0.6) && close(loaded[3].y, 0.6) && close(loaded[3].z, 0.6)
      && close(loaded[3].w, alpha), "gray+alpha map reads (g, g, g, a)")
  let restored = evaluate(31)
  print("fix-materialx restored maps: \(restored[2]) \(restored[3]) \(restored[5])")
  require(
    close(restored[2].x, srgb) && close(restored[2].y, srgb) && close(restored[2].z, srgb),
    "16-bit sRGB albedo map is linearized")
  require(close(restored[3].x, 0.6) && close(restored[3].z, 0.6), "16-bit gray linear map broadcasts")
  require(close(restored[5].x, 0.6) && close(restored[5].y, 0.6), "grayscale normal map broadcasts")

  // Content-based reuse keeps decoded textures when programs move between slots.
  let previous = testRenderer.materials.graphTextures
  try testRenderer.materials.prepareMaterialX([20: collide.materials[2], 21: wide.materials[1]])
  require(
    testRenderer.materials.graphTextures.allSatisfy { t in previous.contains { $0 === t } },
    "unchanged MaterialX images are reused across slots")
  try testRenderer.materials.restore(SceneState())
  print("PASS: MaterialX rotate2d/USD Transform2d, name resolution, OpenPBR defaults, image decoding, colorspaces, file checks, image sharing and XML diagnostics")
}
try fixMaterialXChecks()

// OpenPBR specular_color: a constant colour compiles to MaterialXProgram.specularColor (connected ones
// are rejected), reaches the GPU per slot (slot_specular_color), and tints a metal's 82-degree Fresnel:
// at grazing incidence the tinted metal reflects less, at normal incidence alike.
@MainActor func fixSpecularColorChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("specular-color", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let tinted = try MaterialXImporter.read(Data("""
    <materialx version="1.39"><open_pbr_surface name="Tint" type="surfaceshader">
      <input name="base_metalness" type="float" value="1"/><input name="specular_color" type="color3" value="0.4, 0.5, 0.6"/>
    </open_pbr_surface></materialx>
    """.utf8), baseURL: folder, source: "Tint.mtlx")
  require(tinted.materials.first?.specularColor == SIMD3(0.4, 0.5, 0.6), "constant specular_color compiles (\(tinted.report))")
  let connected = try MaterialXImporter.read(Data("""
    <materialx version="1.39"><constant name="c" type="color3"><input name="value" type="color3" value="0.5, 0.5, 0.5"/></constant>
    <open_pbr_surface name="Linked" type="surfaceshader"><input name="specular_color" type="color3" nodename="c"/></open_pbr_surface></materialx>
    """.utf8), baseURL: folder, source: "Linked.mtlx")
  require(connected.materials.isEmpty && connected.report.contains { $0.contains("specular_color must be a constant") },
    "connected specular_color is rejected: \(connected.report)")
  var state = SceneState()
  state.materialX = [8: tinted.materials[0]]
  let l = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
  try l.restore(state)
  let kernel = """
    kernel void tint_probe(constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(3)]], uint id [[thread_position_in_grid]]) {
        if (id != 0) return;
        out[0] = float4(slot_specular_color(8u, images), slot_specular_color(9u, images).x);
        Material m = {}; m.type = OPENPBR; m.usesMaterialX = 1u; m.albedo = float3(0.9f); m.roughness = 0.3f; m.metalness = 1.0f;
        m.ior = 1.5f; m.specularWeight = 1.0f; m.baseWeight = 1.0f; m.slot = 8u;
        float3 n = float3(0, 0, 1);
        for (uint k = 0; k < 2; ++k) {
            float3 wo = k == 0 ? normalize(float3(0.98f, 0, 0.2f)) : float3(0, 0, 1), wi = float3(-wo.x, -wo.y, wo.z);
            m.specularColor = float3(1.0f);
            float3 white = openpbr_get_sum_of_diffuse_specular(openpbr_eval(prepare_openpbr(m, n, wo), wi));
            m.specularColor = float3(0.4f, 0.5f, 0.6f);
            float3 tint = openpbr_get_sum_of_diffuse_specular(openpbr_eval(prepare_openpbr(m, n, wo), wi));
            out[1 + k] = float4(tint / max(white, float3(1e-9f)), 0);
        }
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernel, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "tint_probe")!)
  let out = gpu.makeBuffer(length: 48, options: .storageModeShared)!
  let command = testRenderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(pipeline)
  require(l.bind(encoder), "tint probe binds material resources")
  encoder.setBuffer(out, offset: 0, index: 3)
  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
  let v = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3)
  require(v[0] == SIMD4(0.4, 0.5, 0.6, 1), "the slot's specular_color reaches the GPU, other slots are white (\(v[0]))")
  require(v[1].x < 0.95 && v[1].x < v[1].y && v[1].y < v[1].z && abs(v[2].x - 1) < 0.02 && abs(v[2].z - 1) < 0.02,
    "the edge tint lowers grazing metal reflection per channel and leaves normal incidence (grazing \(v[1]), normal \(v[2]))")
  print("PASS: OpenPBR specular_color compiles, reaches the GPU per slot and tints the metal edge")
}
try fixSpecularColorChecks()

// OpenPBR transmission_color and geometry_thin_walled (MTL glass, REFERENCES.md MTL2026): constants
// compile to MaterialXProgram.transmissionColor / thinWalled (connected colours are rejected), reach
// the GPU per slot (slot_transmission), and a thin-walled pane transmits without bending from either
// face, where solid glass refracts; the transmitted colour follows transmission_color.
@MainActor func fixThinWalledGlassChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("thin-walled", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let glass = try MaterialXImporter.read(Data("""
    <materialx version="1.39"><open_pbr_surface name="Pane" type="surfaceshader">
      <input name="transmission_weight" type="float" value="1"/><input name="transmission_color" type="color3" value="0.2, 0.4, 0.8"/>
      <input name="geometry_thin_walled" type="boolean" value="true"/><input name="specular_roughness" type="float" value="0"/>
    </open_pbr_surface></materialx>
    """.utf8), baseURL: folder, source: "Pane.mtlx")
  require(glass.materials.first?.transmissionColor == SIMD3(0.2, 0.4, 0.8) && glass.materials.first?.thinWalled == true,
    "constant transmission_color and geometry_thin_walled compile (\(glass.report))")
  let connected = try MaterialXImporter.read(Data("""
    <materialx version="1.39"><constant name="c" type="color3"><input name="value" type="color3" value="0.5, 0.5, 0.5"/></constant>
    <open_pbr_surface name="Linked" type="surfaceshader"><input name="transmission_color" type="color3" nodename="c"/></open_pbr_surface></materialx>
    """.utf8), baseURL: folder, source: "Linked.mtlx")
  require(connected.materials.isEmpty && connected.report.contains { $0.contains("transmission_color must be a constant") },
    "connected transmission_color is rejected: \(connected.report)")
  var state = SceneState()
  state.materialX = [8: glass.materials[0]]
  let l = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
  try l.restore(state)
  let kernel = """
    kernel void glass_probe(constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(3)]], uint id [[thread_position_in_grid]]) {
        if (id != 0) return;
        out[0] = slot_transmission(8u, images);
        out[1] = slot_transmission(9u, images);
        Material m = {}; m.type = OPENPBR; m.usesMaterialX = 1u; m.albedo = float3(0.8f); m.roughness = 0.03f;
        m.ior = 1.5f; m.specularWeight = 1.0f; m.baseWeight = 1.0f; m.transmission = 1.0f; m.slot = 8u;
        m.specularColor = float3(1.0f);
        float3 n = float3(0, 0, 1), wo = normalize(float3(sin(0.7f), 0, cos(0.7f)));
        // 0: thin-walled, front face; 1: thin-walled, back face; 2: solid, front face.
        for (uint c = 0; c < 3; ++c) {
            m.transmissionTint = c < 2 ? slot_transmission(8u, images) : float4(slot_transmission(8u, images).rgb, 0.0f);
            m.inside = c == 1;
            OpenPBR_PreparedBsdf p = prepare_openpbr(m, n, wo);
            float3 direction = float3(0), weight = float3(0);
            uint seed = 12345u;
            for (uint i = 0; i < 4096u; ++i) {
                float3 r = float3(rand_f(seed), rand_f(seed), rand_f(seed)), wi; OpenPBR_DiffuseSpecular f; float pdf; uint lobe;
                openpbr_sample(p, r, wi, f, pdf, lobe);
                if (pdf > 0.0f && dot(wi, n) < 0.0f) { direction += wi; weight += openpbr_get_sum_of_diffuse_specular(f); }
            }
            out[2 + c] = float4(normalize(direction), dot(normalize(direction), -wo));
            out[5 + c] = float4(weight / 4096.0f, 0);
        }
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernel, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "glass_probe")!)
  let out = gpu.makeBuffer(length: 8 * 16, options: .storageModeShared)!
  let command = testRenderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(pipeline)
  require(l.bind(encoder), "glass probe binds material resources")
  encoder.setBuffer(out, offset: 0, index: 3)
  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
  let v = (0..<8).map { out.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  print("Thin-walled glass checks: \(v)")
  require(v[0] == SIMD4(0.2, 0.4, 0.8, 1) && v[1] == SIMD4(1, 1, 1, 0),
    "the slot's transmission_color and thin wall reach the GPU, other slots are clear and solid (\(v[0]), \(v[1]))")
  require(v[2].w > 0.999 && v[3].w > 0.999, "a thin-walled pane transmits without bending from either face (\(v[2]), \(v[3]))")
  require(v[4].w < 0.99, "solid glass refracts (\(v[4]))")
  let tint = SIMD3(v[5].x, v[5].y, v[5].z)
  require(tint.x > 0.01 && tint.x < tint.y && tint.y < tint.z && tint.z < 1,
    "transmitted light follows transmission_color (\(tint))")
  print("PASS: OpenPBR transmission_color and geometry_thin_walled compile, reach the GPU per slot, and thin walls transmit unbent")
}
try fixThinWalledGlassChecks()
