// Synthetic, locally authored fixtures exercise the actual importer and Metal evaluator.
require(
  MemoryLayout<GraphInstruction>.stride == 64 && MemoryLayout<GraphHeader>.stride == 64,
  "graph CPU/GPU layouts")
let mxFolder = URL(fileURLWithPath: "build/checks/materialx", isDirectory: true)
try FileManager.default.createDirectory(at: mxFolder, withIntermediateDirectories: true)
let multiOBJ = """
  v -1 0 0
  v 1 0 0
  v 1 2 0
  v -1 2 0
  vt 0 0
  vt 1 0
  vt 1 1
  vt 0 1
  o Panel
  g Face
  usemtl Red
  f 1/1 2/2 3/3
  usemtl Blue
  f 1/1 3/3 4/4
  o Back
  g Second
  usemtl Blue
  f 1/1 2/2 3/3
  """
var mxScene = SceneGraph()
let mxRoot = try mxScene.addOBJ(multiOBJ, name: "Panels.obj")
require(
  mxScene.assets.count == 2 && mxScene.materials.count == 2 && mxScene.nodes.count == 5,
  "OBJ hierarchy and material-name sharing")
let faceID = mxScene.nodes.first(where: { $0.name == "Face" })!.id
let backID = mxScene.nodes.first(where: { $0.name == "Second" })!.id
mxScene.nodes[mxScene.nodes.firstIndex(where: { $0.id == backID })!].transform.positionScale.z = 2
let mxInstance = try mxScene.instance(faceID)
require(mxScene.assets.count == 2 && mxScene.nodes.count == 6, "instances reuse mesh assets")
mxScene.nodes[mxScene.nodes.firstIndex(where: { $0.id == mxInstance })!].transform.positionScale.x =
  3
var mxTris = try mxScene.renderTriangles()
require(
  mxTris.count == 5 && Set(mxTris.map { $0.uvc.z }) == Set([Float(8), 9]),
  "per-face material slots survive flattening")
require(
  mxTris.contains(where: { $0.a.x == 2 && $0.uvc.w == 6 }),
  "instance transform and GPU pick identity")
var cyclic = mxScene
cyclic.nodes[0].parent = faceID
do {
  try cyclic.validate()
  require(false, "scene cycles rejected")
} catch {}
var invisible = mxScene
invisible.nodes[0].transform.rotationHidden.w = 1
let invisibleTris = try invisible.renderTriangles()
require(invisibleTris.isEmpty, "parent visibility inherited by instances")
var deleted = mxScene
deleted.remove(mxRoot)
require(deleted.nodes.isEmpty && deleted.assets.isEmpty, "subtree deletion cleans meshes")
func parseMX(_ body: String) throws -> MaterialXImport {
  try MaterialXImporter.read(
    Data(("<materialx version=\"1.39\">" + body + "</materialx>").utf8), baseURL: mxFolder,
    source: "Fixture.mtlx")
}
let mxBody = """
  <nodegraph name="Graph">
    <input name="tint" type="color3" value="0.8,0.2,0.1"/>
    <constant name="red" type="color3"><input name="value" type="color3" interfacename="tint"/></constant>
    <mix name="blend" type="color3">
      <input name="bg" type="color3" nodename="red"/>
      <input name="fg" type="color3" value="0.2,0.4,0.9"/>
      <input name="mix" type="float" value="0.25"/>
    </mix>
    <multiply name="mul" type="float"><input name="in1" type="float" value="0.8"/><input name="in2" type="float" value="0.5"/></multiply>
    <output name="color" type="color3" nodename="blend"/>
    <output name="rough" type="float" nodename="mul"/>
  </nodegraph>
  <open_pbr_surface name="Paint" type="surfaceshader">
    <input name="base_color" type="color3" nodegraph="Graph" output="color"/>
    <input name="specular_roughness" type="float" nodegraph="Graph" output="rough"/>
    <input name="coat_weight" type="float" value="0.3"/>
    <input name="coat_roughness" type="float" value="0.2"/>
  </open_pbr_surface>
  """
let mxImported = try parseMX(mxBody)
require(
  mxImported.materials.count == 1,
  "nodegraph, outputs and interface connections: \(mxImported.report)")
let mxProgram = mxImported.materials[0]
require(
  mxProgram.parameters.contains(where: { $0.name.contains("tint") }),
  "graph interface parameters exposed")
for body in [
  "<noise3d name=\"noise\" type=\"color3\"/><open_pbr_surface name=\"bad\" type=\"surfaceshader\"><input name=\"base_color\" type=\"color3\" nodename=\"noise\"/></open_pbr_surface>",
  "<constant name=\"loop\" type=\"color3\"><input name=\"value\" type=\"color3\" nodename=\"loop\"/></constant><open_pbr_surface name=\"bad\" type=\"surfaceshader\"><input name=\"base_color\" type=\"color3\" nodename=\"loop\"/></open_pbr_surface>",
  "<open_pbr_surface name=\"bad\" type=\"surfaceshader\"><input name=\"subsurface_weight\" type=\"float\" value=\"1\"/></open_pbr_surface>",
  "<image name=\"missing\" type=\"color3\"><input name=\"file\" type=\"filename\" value=\"missing.png\"/></image><open_pbr_surface name=\"bad\" type=\"surfaceshader\"><input name=\"base_color\" type=\"color3\" nodename=\"missing\"/></open_pbr_surface>",
] {
  let bad = try parseMX(body)
  require(
    bad.materials.isEmpty && bad.report.joined().contains("NOT imported"),
    "unsupported and invalid graphs reported")
}
var badProgram = mxProgram
badProgram.roots[0] = -1
do {
  try badProgram.validate()
  require(false, "invalid output register rejected")
} catch {}
badProgram = mxProgram
badProgram.instructions[0].code.z = 200
do {
  try badProgram.validate()
  require(false, "invalid unused register rejected")
} catch {}
let mxBitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
let mxPixels: [UInt8] = [128, 64, 32, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
for i in mxPixels.indices { mxBitmap.bitmapData![i] = mxPixels[i] }
try mxBitmap.representation(using: .png, properties: [:])!.write(
  to: mxFolder.appendingPathComponent("color.png"))
let textureBody = """
  <image name="img" type="color3" colorspace="srgb_texture"><input name="file" type="filename" value="color.png"/></image>
  <extract name="green" type="float"><input name="in" type="color3" nodename="img"/><input name="index" type="integer" value="1"/></extract>
  <normalmap name="normal" type="vector3"><input name="in" type="vector3" value="0.5,0.5,1"/></normalmap>
  <open_pbr_surface name="Image" type="surfaceshader">
   <input name="base_color" type="color3" nodename="img"/>
   <input name="specular_roughness" type="float" nodename="green"/>
   <input name="geometry_normal" type="vector3" nodename="normal"/>
  </open_pbr_surface>
  """
let textureImport = try parseMX(textureBody)
require(textureImport.materials.count == 1, "image graph compiles: \(textureImport.report)")
let textureProgram = textureImport.materials[0]
try testRenderer.materials.restore(SceneState())
try testRenderer.materials.prepareMaterialX([8: mxProgram, 9: textureProgram])
try testRenderer.materials.setMesh(mxTris)
testRenderer.materials.hasSceneGraph = true
let mxKernel = """
  kernel void materialx_checks(constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],constant MaterialResources &images [[buffer(2)]],device float4 *out [[buffer(3)]]) {
   Ray r={float3(0.5f,0.5f,-2),float3(0,0,1)};HitRecord h;
   bool found=trace_scene(r,6,h,images,u);
   out[0]=float4(found?float(h.mat.slot):-1,found?float(h.objectID):-1,h.t,0);
   resolve_material(h,r,u,settings,images,0);
   out[1]=float4(h.mat.albedo,h.mat.roughness);out[2]=float4(h.mat.coat,h.mat.coatRoughness,h.mat.specularWeight,h.mat.baseWeight);
   // The same resolution path is used for reflected/refracted surface hits.
   Ray secondary={float3(-0.5f,1.5f,-2),float3(0,0,1)};
   trace_scene(secondary,6,h,images,u);out[3]=float4(float(h.mat.slot),float(h.objectID),h.t,0);
   h.uv=float2(0.25f,0.25f);resolve_material(h,secondary,u,settings,images,0);
   out[4]=float4(h.mat.albedo,h.mat.roughness);out[5]=float4(h.normal,0);
  }
  """
let mxLibrary = try gpu.makeLibrary(source: metalSource + mxKernel, options: shaderCompileOptions())
let mxPipeline = try gpu.makeComputePipelineState(
  function: mxLibrary.makeFunction(name: "materialx_checks")!)
func evaluateMX() -> [SIMD4<Float>] {
  var u = makeUniforms(scene: 6, mode: 0, width: 1, height: 1)
  u.environment.w = Float(testRenderer.materials.nodeCount)
  u.lens.z = 1
  let buffer = gpu.makeBuffer(length: 6 * 16, options: .storageModeShared)!
  let command = testRenderer.commandQueue.makeCommandBuffer()!
  let encoder = command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(mxPipeline)
  testRenderer.materials.bind(encoder)
  encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
  encoder.setBuffer(buffer, offset: 0, index: 3)
  encoder.dispatchThreads(
    MTLSize(width: 1, height: 1, depth: 1),
    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding()
  command.commit()
  command.waitUntilCompleted()
  require(command.status == .completed, "MaterialX GPU evaluation")
  return (0..<6).map { buffer.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
}
let mxResult = evaluateMX()
print("MaterialX GPU: \(mxResult)")
require(
  mxResult[0].x == 8 && mxResult[0].y == 66 && abs(mxResult[0].z - 2) < 1e-5,
  "scene graph face material and pick ID")
require(
  simd_length(mxResult[1] - SIMD4(0.65, 0.25, 0.3, 0.4)) < 0.002,
  "Metal graph arithmetic and OpenPBR input mapping")
require(simd_length(mxResult[2] - SIMD4(0.3, 0.2, 1, 1)) < 0.002, "coat roughness and weights")
require(mxResult[3].x == 9 && mxResult[3].y == 66, "two materials on one mesh")
require(
  abs(mxResult[4].x - 0.21586) < 0.004 && abs(mxResult[4].y - 0.05127) < 0.004
    && abs(mxResult[4].z - 0.01444) < 0.004, "sRGB image conversion and UV orientation")
require(
  abs(mxResult[4].w - mxResult[4].y) < 0.002 && mxResult[5].z < -0.99,
  "channel extraction and normal map")
var mxDoc = ProjectDocument()
mxDoc.scene = 6
mxDoc.graph = mxScene
mxDoc.scenes[6] = testRenderer.materials.state()
let mxData = try JSONEncoder().encode(mxDoc)
let mxRoundtrip = try JSONDecoder().decode(ProjectDocument.self, from: mxData)
try mxRoundtrip.validate()
require(
  mxRoundtrip.graph!.nodes[2].id == faceID
    && mxRoundtrip.scenes[6]!.materialX![9]!.images[0].data == textureProgram.images[0].data,
  "project embeds graph identities and MaterialX image bytes")
try mxData.write(to: mxFolder.appendingPathComponent("Panels.vtrace"))
try ("<materialx version=\"1.39\">" + mxBody + "</materialx>").write(
  to: mxFolder.appendingPathComponent("Paint.mtlx"), atomically: true, encoding: .utf8)
try multiOBJ.write(
  to: mxFolder.appendingPathComponent("Panels.obj"), atomically: true, encoding: .utf8)
try controller.restore(mxRoundtrip)
controller.selectedNode = faceID
controller.selectedSubset = 0
for page in [3, 4] {
  controller.page = page
  controller.rebuild()
  controller.view.layoutSubtreeIfNeeded()
  require(
    controller.stack.arrangedSubviews.count > 8, "scene and graph material inspector populated")
}
controller.history.removeAllActions()
controller.history.beginUndoGrouping()
controller.editGraph("Move parent") { g in g.nodes[0].transform.positionScale.x = 0.5 }
controller.history.endUndoGrouping()
controller.history.undo()
require(
  controller.project.graph!.nodes[0].transform.positionScale.x == 0,
  "graph edit undo restores hierarchy")
controller.page = 3
controller.rebuild()
let parameterControl = controller.stack.arrangedSubviews.compactMap { $0 as? NumberControl }.first!
controller.history.beginUndoGrouping()
parameterControl.set(0.6)
controller.history.endUndoGrouping()
let editedProgram = controller.renderer.materials.materialX[8]!
require(
  abs(editedProgram.instructions[editedProgram.parameters[0].instruction].value.x - 0.6) < 1e-5,
  "inspector parameter changes executable graph")
controller.saveTimer?.invalidate()
var mxView = makeUniforms(scene: 6, mode: 0, width: 64, height: 48)
mxView.environment.w = Float(testRenderer.materials.nodeCount)
mxView.lens.z = 1
mxView.cameraPos = SIMD4(0, 1, -4, 45)
mxView.cameraTarget = SIMD4(0, 1, 0, 16)
mxView.currentViewProj =
  makePerspective(fovyRadians: 45 * .pi / 180, aspect: 64.0 / 48, near: 0.05, far: 100)
  * makeLookAt(eye: SIMD3(0, 1, -4), target: SIMD3(0, 1, 0), up: SIMD3(0, 1, 0))
mxView.prevViewProj = mxView.currentViewProj
for mode in UInt32(0)...3 {
  mxView.samplingMode = mode
  let pixels = render(mxView, samples: 4, denoise: mode == 0)
  require(
    pixels.allSatisfy { p in (0..<3).allSatisfy { c in p[c].isFinite } },
    "graph material finite render strategy \(mode)")
}
print(
  "PASS: hierarchy, shared instances, face bindings, graph compiler/rejections, GPU expressions/images, project roundtrip, inspector edits and all rendering strategies"
)

// Graph changes must remain visible through the existing mirror/glass paths.
try testRenderer.materials.restore(SceneState())
testRenderer.materials.hasSceneGraph = false
let reflectedView = makeUniforms(scene: 3, mode: 0, width: 96, height: 72)
let reflectedBefore = render(reflectedView, samples: 24, denoise: true)
let primaryTypes = lastNormals.map { Int($0.w) }
try testRenderer.materials.prepareMaterialX([0: textureProgram])
let reflectedAfter = render(reflectedView, samples: 24, denoise: true)
for type in [1, 2] {
  let mask = primaryTypes.indices.filter { primaryTypes[$0] == type }
  let difference =
    mask.reduce(Float(0)) { $0 + simd_length(reflectedBefore[$1] - reflectedAfter[$1]) }
    / Float(max(1, mask.count))
  require(
    mask.count > 10 && difference > 0.005,
    "MaterialX reaches \(type==1 ? "reflected":"refracted") surfaces")
}
let reflectedGuides = readTexture(testRenderer.metalFX!.diffuse)
require(
  reflectedGuides.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite },
  "finite MaterialX reflected/transmitted MetalFX guides")
savePreview(
  [reflectedBefore, reflectedAfter, lastDisplay], width: 96, height: 72,
  name: "materialx-secondary.png")
print("PASS: MaterialX visible through mirror/glass paths and MetalFX guides")
controller.saveTimer?.invalidate()

// Old documents omit the new optional fields and retain eight material slots.
var legacyState = SceneState()
legacyState.surfaces = Array(legacyState.surfaces.prefix(8))
legacyState.objects = Array(legacyState.objects.prefix(8))
legacyState.maps = Array(legacyState.maps.prefix(32))
legacyState.names = Array(legacyState.names.prefix(32))
legacyState.surfaces[7].enabled = 1
legacyState.surfaces[7].color = SIMD4(0.2, 0.7, 0.4, 1)
legacyState.objects[7].positionScale = SIMD4(4, 2, 1, 2)
var legacyDocument = ProjectDocument()
legacyDocument.version = 1
legacyDocument.scene = 6
legacyDocument.triangles = try OBJMesh.load(multiOBJ)
legacyDocument.scenes[6] = legacyState
let legacyBytes = try JSONEncoder().encode(legacyDocument)
var migratedDocument = try JSONDecoder().decode(ProjectDocument.self, from: legacyBytes)
try migratedDocument.validate()
_ = try migratedDocument.appendOBJ(multiOBJ, name: "Added.obj")
try migratedDocument.validate()
require(
  migratedDocument.version == 2 && migratedDocument.triangles.isEmpty
    && migratedDocument.graph!.assets.count == 3,
  "legacy single mesh migrates and append retains it")
require(
  migratedDocument.graph!.nodes[0].transform.positionScale == SIMD4(4, 2, 1, 2)
    && migratedDocument.scenes[6]!.surfaces[8].color == SIMD4(0.2, 0.7, 0.4, 1),
  "legacy transform and material survive migration")
let beforeInvalid = try JSONEncoder().encode(migratedDocument.graph)
do {
  _ = try migratedDocument.appendOBJ("v invalid", name: "Bad.obj")
  require(false, "invalid appended OBJ fails")
} catch {}
let afterInvalid = try JSONEncoder().encode(migratedDocument.graph)
let beforeGraph = try JSONDecoder().decode(SceneGraph.self, from: beforeInvalid)
let afterGraph = try JSONDecoder().decode(SceneGraph.self, from: afterInvalid)
require(beforeGraph.nodes.map(\.id) == afterGraph.nodes.map(\.id), "failed import preserves graph")
try controller.restore(migratedDocument)
controller.selectedNode = migratedDocument.graph!.nodes[0].id
controller.page = 4
controller.rebuild()
controller.view.layoutSubtreeIfNeeded()
if let bitmap = controller.sidebar.bitmapImageRepForCachingDisplay(in: controller.sidebar.bounds) {
  controller.sidebar.cacheDisplay(in: controller.sidebar.bounds, to: bitmap)
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: mxFolder.appendingPathComponent("hierarchy-inspector.png"))
}
controller.saveTimer?.invalidate()
print("PASS: legacy project migration, material/transform retention and failed append preservation")
if let parameter = mxProgram.parameters.first {
  require(parameter.defaultValue != nil, "MaterialX parameter retains imported reset default")
  let roundtrip = try JSONDecoder().decode(MaterialXProgram.self, from: JSONEncoder().encode(mxProgram))
  require(roundtrip.parameters.first?.defaultValue == parameter.defaultValue,
    "MaterialX parameter default persists")
}
