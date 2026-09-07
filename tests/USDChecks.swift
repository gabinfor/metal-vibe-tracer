// Exercise the production SDK process, snapshot decoder, persistence and GPU emitters.
let usdFolder = URL(fileURLWithPath: "build/checks/usd", isDirectory: true)
let usdResult = try USDImporter.load(usdFolder.appendingPathComponent("scene.usdz"), into: ProjectDocument())
let usdGraph = usdResult.document.graph!
let usdTriangles = try usdGraph.renderTriangles()
require(usdGraph.assets.count == 1 && usdTriangles.count == 6, "USD shared instances reach Swift")
require(abs(usdTriangles.map { $0.a.x }.min()! - 0.99) < 0.001 && usdTriangles.contains { $0.a.x > 2.98 }, "USD composed centimeters become meters")
require(usdResult.document.scenes[6]!.materialX?.count == 2, "USD PreviewSurface compiles to GPU material")
var mirroredUSD = usdGraph
let mirroredIndex = mirroredUSD.nodes.firstIndex { $0.mesh != nil }!
mirroredUSD.nodes[mirroredIndex].matrix![0] *= -1
let mirroredTriangles = try mirroredUSD.renderTriangles()
let mt = mirroredTriangles[0]
let geometric = simd_cross(SIMD3(mt.b.x-mt.a.x,mt.b.y-mt.a.y,mt.b.z-mt.a.z), SIMD3(mt.c.x-mt.a.x,mt.c.y-mt.a.y,mt.c.z-mt.a.z))
require(simd_dot(geometric, SIMD3(mt.na.x,mt.na.y,mt.na.z)) > 0, "negative determinant preserves authored winding and normals")
let cancelledUSD = USDImportJob(); cancelledUSD.cancel()
do {
  _ = try USDImporter.load(usdFolder.appendingPathComponent("scene.usda"), into: ProjectDocument(), job: cancelledUSD)
  require(false, "cancelled import must stop")
} catch {}
let areaResult = try USDImporter.load(usdFolder.appendingPathComponent("area.usda"), into: ProjectDocument())
let usdBytes = try JSONEncoder().encode(areaResult.document)
let usdRoundtrip = try JSONDecoder().decode(ProjectDocument.self, from: usdBytes)
try controller.restore(usdRoundtrip)
require(testRenderer.materials.emissions.count == 1 && testRenderer.materials.meshTriangles.count == 4, "area emitter survives project roundtrip")
let usdKernel = """
kernel void usd_checks(constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],constant MaterialResources &images [[buffer(2)]],device float4 *out [[buffer(3)]]) {
 uint seed=47;uint count=0;float error=0,envError=0;float3 p=float3(0,.01f,0),n=float3(0,1,0);
 for(uint i=0;i<4096;++i) {
  LightSample ls=sample_direct_light(p,n,u,seed,images);
  if(ls.isDirectional>=2) {
   ++count;Material m={};m.slot=uint(images.triangles[ls.isDirectional-2].uvc.z);
   float pdf=eval_light_pdf(p,ls.position,m,u,images);
   error=max(error,abs(pdf-ls.pdf)/max(ls.pdf,1e-10f));
  } else envError=max(envError,abs(ls.pdf-eval_environment_pdf(ls.wi,n,u,images)));
 }
 out[0]=float4(count,error,envError,images.emitters[0]);
 HitRecord h;Ray r={p,n};bool hit=trace_scene(r,6,h,images,u);
 out[1]=float4(hit?h.mat.emission:float3(-1),hit?float(h.mat.type):-1);
 Ray back={float3(0,3,0),-n};trace_scene(back,6,h,images,u);out[2]=float4(h.mat.emission,0);
}
"""
let usdLibrary = try gpu.makeLibrary(source: metalSource + usdKernel, options: shaderCompileOptions())
let usdPipeline = try gpu.makeComputePipelineState(function: usdLibrary.makeFunction(name: "usd_checks")!)
var usdUniforms = makeUniforms(scene: 6, mode: 0, width: 64, height: 48)
usdUniforms.environment.w = Float(testRenderer.materials.nodeCount)
usdUniforms.environment.x = 0
usdUniforms.sunParams.w = 0
usdUniforms.lens.z = 1
usdUniforms.cameraPos = SIMD4(0,1,-4,45)
usdUniforms.cameraTarget = SIMD4(0,0,0,16)
usdUniforms.currentViewProj = makePerspective(fovyRadians: 45 * .pi / 180, aspect: 64.0/48, near: 0.05, far: 100) * makeLookAt(eye: SIMD3(0,1,-4),target: SIMD3(0,0,0),up: SIMD3(0,1,0))
usdUniforms.prevViewProj = usdUniforms.currentViewProj
let usdBuffer = gpu.makeBuffer(length: 3*16,options: .storageModeShared)!
let usdCommand = testRenderer.commandQueue.makeCommandBuffer()!
let usdEncoder = usdCommand.makeComputeCommandEncoder()!
usdEncoder.setComputePipelineState(usdPipeline)
testRenderer.materials.bind(usdEncoder)
usdEncoder.setBytes(&usdUniforms,length: MemoryLayout<Uniforms>.stride,index: 0)
usdEncoder.setBuffer(usdBuffer,offset: 0,index: 3)
usdEncoder.dispatchThreads(MTLSize(width: 1,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 1,height: 1,depth: 1))
usdEncoder.endEncoding();usdCommand.commit();usdCommand.waitUntilCompleted()
require(usdCommand.status == .completed, "USD emitter GPU command")
let usdGPU = (0..<3).map { usdBuffer.contents().load(fromByteOffset: $0*16,as: SIMD4<Float>.self) }
print("USD emitter GPU: \(usdGPU)")
require(usdGPU[0].x > 4000 && usdGPU[0].y < 0.0001 && usdGPU[0].z < 0.0001 && usdGPU[0].w == 2, "area-only proposal/PDF consistency")
require(usdGPU[1].x == 4 && usdGPU[1].y == 4 && usdGPU[1].z == 4 && usdGPU[2].x == 0, "authored one-sided rect light radiance")
// Disable the floor's OpenPBR override to exercise the ReSTIR path as well as MIS.
testRenderer.materials.settings[8].enabled = 0
for mode in UInt32(0)...3 {
 usdUniforms.samplingMode = mode
 let pixels = render(usdUniforms,samples: 48,denoise: mode == 0)
 require(pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "finite area-light rendering mode \(mode)")
 require(pixels.reduce(Float(0)) { $0+$1.x+$1.y+$1.z } > 1, "area light illuminates geometry mode \(mode)")
}
print("PASS: OpenUSD SDK process, Swift mapping, mirrored transforms, cancellation, emission persistence, GPU light PDFs and all integrators")
let referenceUSD = URL(fileURLWithPath: "build/reference-scenes/ShaderBall-triangulated.usda")
if FileManager.default.fileExists(atPath: referenceUSD.path) {
 let imported = try USDImporter.load(referenceUSD,into: ProjectDocument())
 print("ASWF reference: \(imported.report.joined(separator: "\n"))")
 try controller.restore(imported.document)
 try JSONEncoder().encode(imported.document).write(to: referenceUSD.deletingLastPathComponent().appendingPathComponent("StandardShaderBall-audit.vtrace"))
 try imported.report.joined(separator: "\n").write(to: referenceUSD.deletingLastPathComponent().appendingPathComponent("import-report-audit.txt"),atomically: true,encoding: .utf8)
 var view = makeUniforms(scene: 6,mode: 1,width: 192,height: 144)
 view.environment.w = Float(testRenderer.materials.nodeCount)
 view.environment.x = imported.document.options.environmentIntensity
 view.sunParams.w = imported.document.options.sunIntensity
 view.lens.z = 1
 let c = imported.document.camera
 let eye = c.target + SIMD3(c.distance*cos(c.pitch)*sin(c.yaw),c.distance*sin(c.pitch),-c.distance*cos(c.pitch)*cos(c.yaw))
 view.cameraPos = SIMD4(eye,c.fov)
 view.cameraTarget = SIMD4(c.target,16)
 view.currentViewProj = makePerspective(fovyRadians: c.fov * .pi / 180,aspect: 192.0/144,near: 0.001,far: 100) * makeLookAt(eye: eye,target: c.target,up: SIMD3(0,1,0))
 view.prevViewProj = view.currentViewProj
 let pixels = render(view,samples: 96,denoise: false)
 require(pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "ASWF reference render finite")
 require(pixels.reduce(Float(0)) { $0+$1.x+$1.y+$1.z } > 1, "ASWF reference receives authored lighting")
 savePreview([pixels],width: 192,height: 144,name: "openusd-audit-reference.png")
 print("PASS: ASWF Standard Shader Ball imported, rendered, and saved as a portable project")
}
controller.saveTimer?.invalidate()
