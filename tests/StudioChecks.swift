// Production model, GPU, export and AppKit integration checks.
require(MemoryLayout<ObjectSettings>.stride == 64,"object settings layout")
require(MemoryLayout<MeshTriangle>.stride == 128,"triangle layout")
require(MemoryLayout<MeshNode>.stride == 48,"BVH layout")
let studioDirectory=URL(fileURLWithPath:"build/checks/studio",isDirectory:true)
try FileManager.default.createDirectory(at:studioDirectory,withIntermediateDirectories:true)
let obj="""
v -1 0 0
v 1 0 0
v 1 2 0
v -1 2 0
vt 0 0
vt 1 0
vt 1 1
vt 0 1
vn 0 0 -1
f -4/1/1 -3/2/1 -2/3/1 -1/4/1
"""
let triangles=try OBJMesh.load(obj)
require(triangles.count==2,"OBJ negative indices and polygon triangulation")
do{_=try OBJMesh.load("v 0 0 0\nf 1 2 3");require(false,"reject out-of-range OBJ index")}catch{}
do{_=try OBJMesh.load("v nan 0 0");require(false,"reject invalid OBJ values")}catch{}
try testRenderer.materials.restore(SceneState())
var manyTriangles=triangles
for shift:Float in [4,8] { for var t in triangles {t.a.x+=shift;t.b.x+=shift;t.c.x+=shift;manyTriangles.append(t)} }
try testRenderer.materials.setMesh(manyTriangles)
require(testRenderer.materials.nodeCount>1,"BVH includes internal nodes")
var studioUniforms=makeUniforms(scene:6,mode:1,width:64,height:48)
studioUniforms.environment.w=Float(testRenderer.materials.nodeCount)
let studioKernels="""
kernel void studio_checks(constant Uniforms &u [[buffer(0)]],constant MaterialResources &images [[buffer(2)]],device float4 *out [[buffer(3)]]) {
    Ray r={float3(0,1,-2),float3(0,0,1)};HitRecord hit;
    bool found=trace_scene(r,6,hit,images,u);
    out[0]=float4(found ? hit.t:-1,found ? float(hit.mat.slot):-1,found?hit.uv:float2(-1));
    Ray lens={float3(0),normalize(float3(0.1f,0.2f,1))};
    uint seed=17;float3 focus=lens.direction*(u.lens.y/lens.direction.z);
    lens_ray(lens,float3(0,0,1),float3(1,0,0),float3(0,1,0),u,seed);
    float3 atFocus=lens.origin+lens.direction*((u.lens.y-lens.origin.z)/lens.direction.z);
    out[1]=float4(length(atFocus-focus),length(lens.origin),0,0);
    out[2]=float4(eval_environment(float3(1,0,0),u,images),1);
    float mismatch=0;
    for(int i=0;i<128;++i) {
        LightSample ls=sample_direct_light(float3(0,-0.9f,0),float3(0,1,0),u,seed,images);
        if(ls.pdf>0 && ls.isDirectional==0) {
            Material m={EMISSIVE,float3(0),ls.emission,0,1};
            mismatch=max(mismatch,abs(ls.pdf-eval_light_pdf(float3(0,-0.9f,0),ls.position,m,u))/ls.pdf);
        }
    }
    out[3]=float4(mismatch,0,0,0);
}
"""
let studioLibrary=try gpu.makeLibrary(source:metalSource+studioKernels,options:shaderCompileOptions())
let studioPipeline=try gpu.makeComputePipelineState(function:studioLibrary.makeFunction(name:"studio_checks")!)
func checkStudio(_ input:Uniforms)->[SIMD4<Float>] {
    var u=input
    let buffer=gpu.makeBuffer(length:64,options:.storageModeShared)!,command=testRenderer.commandQueue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(studioPipeline);testRenderer.materials.bind(encoder)
    encoder.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0);encoder.setBuffer(buffer,offset:0,index:3)
    encoder.dispatchThreads(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted()
    require(command.status == .completed,"studio GPU checks completed")
    return (0..<4).map {buffer.contents().load(fromByteOffset:$0*16,as:SIMD4<Float>.self)}
}
studioUniforms.lens=SIMD4(0.2,5,0,0)
var checksResult=checkStudio(studioUniforms)
require(abs(checksResult[0].x-2)<1e-5 && checksResult[0].y==7,"mesh BVH hit with imported material")
require(checksResult[1].x<1e-5 && checksResult[1].y>0 && checksResult[1].y<=0.2,"thin-lens rays meet the focus plane")
testRenderer.materials.objects[7].positionScale.z=1
checksResult=checkStudio(studioUniforms)
require(abs(checksResult[0].x-3)<1e-5,"mesh transform affects ray intersection")
testRenderer.materials.objects[7].rotationHidden.w=1
require(checkStudio(studioUniforms)[0].x<0,"hidden mesh does not intersect")
testRenderer.materials.objects[7]=ObjectSettings()
for scene in [UInt32(1),2,3,4,5] {
    for scale:Float in [0.4,1,2] {
        var u=makeUniforms(scene:scene,mode:1,width:1,height:1);u.light.w=scale
        require(checkStudio(u)[3].x<0.002,"light-size sampling and evaluation agree for scene \(scene), scale \(scale)")
    }
}
var meshView=makeUniforms(scene:6,mode:0,width:64,height:48)
meshView.environment.w=Float(testRenderer.materials.nodeCount)
meshView.cameraPos=SIMD4(0,1,-4,45);meshView.cameraTarget=SIMD4(0,1,0,16)
meshView.currentViewProj=makePerspective(fovyRadians:45 * .pi/180,aspect:64.0/48,near:0.05,far:100)*makeLookAt(eye:SIMD3(0,1,-4),target:SIMD3(0,1,0),up:SIMD3(0,1,0))
meshView.prevViewProj=meshView.currentViewProj
for mode in UInt32(0)...3 {
    meshView.samplingMode=mode
    _=render(meshView,samples:4,denoise:mode==0)
    require(lastPositions.filter { $0.w>0 && abs($0.z)<0.001 }.count>100,"imported mesh renders with strategy \(mode)")
}
print("PASS: OBJ validation, BVH, transforms/visibility, thin lens, scaled-light PDFs, mesh strategies")

// PNG/EXR preserve dimensions, orientation and HDR radiance.
let imageDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:2,height:2,mipmapped:false)
imageDescriptor.storageMode = .shared;imageDescriptor.usage=[.shaderRead,.shaderWrite]
let hdrTexture=gpu.makeTexture(descriptor:imageDescriptor)!
var fixturePixels:[SIMD4<Float>]=[SIMD4(4,0,0,1),SIMD4(0,2,0,1),SIMD4(0,0,3,1),SIMD4(1,1,1,1)]
hdrTexture.replace(region:MTLRegionMake2D(0,0,2,2),mipmapLevel:0,withBytes:&fixturePixels,bytesPerRow:32)
let exrURL=studioDirectory.appendingPathComponent("hdr-roundtrip.exr")
try RenderImage.write(texture:hdrTexture,url:exrURL,hdr:true)
let exrData=try Data(contentsOf:exrURL)
require(exrData.starts(with:[0x76,0x2f,0x31,0x01]),"export is an OpenEXR file")
try testRenderer.materials.setEnvironment(exrData)
let environmentPixels=readTexture(testRenderer.materials.environmentTexture)
print("EXR roundtrip pixels: \(environmentPixels)")
require(environmentPixels.contains(where:{$0.x>3.9 && $0.y<0.01}),"EXR preserves values above one")
let pngURL=studioDirectory.appendingPathComponent("orientation.png")
try RenderImage.write(texture:hdrTexture,url:pngURL,hdr:false)
let png=NSBitmapImageRep(data:try Data(contentsOf:pngURL))!
require(png.pixelsWide==2 && png.pixelsHigh==2,"PNG export dimensions")
let topLeft=png.colorAt(x:0,y:0)!.usingColorSpace(.sRGB)!
require(topLeft.redComponent>0.95 && topLeft.blueComponent<0.05,"PNG keeps top-left orientation")
// OIDN consumes linear HDR color with primary-surface albedo/normal guides.
let oidnDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:32,height:32,mipmapped:false)
oidnDescriptor.storageMode = .shared;oidnDescriptor.usage=[.shaderRead]
let oidnColor=gpu.makeTexture(descriptor:oidnDescriptor)!,oidnAlbedo=gpu.makeTexture(descriptor:oidnDescriptor)!,oidnNormal=gpu.makeTexture(descriptor:oidnDescriptor)!
var oidnColorPixels=[SIMD4<Float>](),oidnAlbedoPixels=[SIMD4<Float>](),oidnNormalPixels=[SIMD4<Float>]()
for i in 0..<(32*32) {
    let noise:Float = (i & 1)==0 ? 0.35 : -0.35
    oidnColorPixels.append(i == 16*32+16 ? SIMD4(200,160,80,1) : SIMD4(2+noise,1+noise*0.5,0.5+noise*0.25,1))
    oidnAlbedoPixels.append(SIMD4(0.8,0.5,0.2,1));oidnNormalPixels.append(SIMD4(0,1,0,0))
}
oidnColor.replace(region:MTLRegionMake2D(0,0,32,32),mipmapLevel:0,withBytes:&oidnColorPixels,bytesPerRow:32*16)
oidnAlbedo.replace(region:MTLRegionMake2D(0,0,32,32),mipmapLevel:0,withBytes:&oidnAlbedoPixels,bytesPerRow:32*16)
oidnNormal.replace(region:MTLRegionMake2D(0,0,32,32),mipmapLevel:0,withBytes:&oidnNormalPixels,bytesPerRow:32*16)
let oidnImage=try OIDNDenoiser.denoise(color:oidnColor,albedo:oidnAlbedo,normal:oidnNormal,commandQueue:testRenderer.commandQueue,progress:OIDNProgress())
require(oidnImage.width==32 && oidnImage.height==32 && oidnImage.pixels.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),"OIDN offline HDR filtering")
let oidnReference=SIMD3<Float>(2,1,0.5)
let oidnRawError=oidnColorPixels.reduce(Float(0)){$0+simd_length_squared(SIMD3($1.x,$1.y,$1.z)-oidnReference)}/Float(oidnColorPixels.count)
let oidnFilteredError=oidnImage.pixels.reduce(Float(0)){$0+simd_length_squared(SIMD3($1.x,$1.y,$1.z)-oidnReference)}/Float(oidnImage.pixels.count)
require(oidnFilteredError<oidnRawError,"OIDN reduces synthetic HDR noise")
require(oidnImage.pixels[16*32+16].x < 20,"OIDN preprocessing suppresses isolated diffuse fireflies")
var fastColorOnly=OIDNOptions();fastColorOnly.quality=0;fastColorOnly.guides=0
fastColorOnly.treatGuidesAsNoisy=false;fastColorOnly.robustInputScale=false;fastColorOnly.suppressDiffuseFireflies=false
let oidnUnguided=try OIDNDenoiser.denoise(color:oidnColor,albedo:oidnAlbedo,normal:oidnNormal,commandQueue:testRenderer.commandQueue,progress:OIDNProgress(),options:fastColorOnly)
require(oidnUnguided.pixels.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),"configured OIDN color-only fast path")
print("PASS: OIDN runtime, HDR input and auxiliary guides")
// A uniform HDR environment is directly visible and lights secondary paths.
fixturePixels=Array(repeating:SIMD4(2,1,0.5,1),count:4)
hdrTexture.replace(region:MTLRegionMake2D(0,0,2,2),mipmapLevel:0,withBytes:&fixturePixels,bytesPerRow:32)
try RenderImage.write(texture:hdrTexture,url:exrURL,hdr:true)
try testRenderer.materials.setEnvironment(Data(contentsOf:exrURL))
studioUniforms.environment=SIMD4(3,0,1,Float(testRenderer.materials.nodeCount))
let env=checkStudio(studioUniforms)[2]
require(abs(env.x-6)<0.02 && abs(env.y-3)<0.02,"linear HDR environment brightness")
print("PASS: PNG orientation and dimensions, HDR EXR export and environment loading")

var document=ProjectDocument();document.scene=6;document.scenes[6]=testRenderer.materials.state();document.triangles=triangles;document.environmentData=testRenderer.materials.environmentData;document.options.exposure=2;document.oidn=fastColorOnly;document.viewportMode=2
let archive=try JSONEncoder().encode(document)
let decoded=try JSONDecoder().decode(ProjectDocument.self,from:archive);try decoded.validate()
require(decoded.triangles.count==2 && decoded.environmentData==document.environmentData && decoded.options.exposure==2 && decoded.oidn==fastColorOnly && decoded.viewportMode==2,"project roundtrip embeds geometry, environment and settings")
var invalid=decoded;invalid.scenes[6]!.surfaces=[]
do{try invalid.validate();require(false,"reject malformed project before applying")}catch{}
print("PASS: portable project roundtrip and invalid project rejection")

let mapBytes = try Data(contentsOf: pngURL)
var mappedState = SceneState()
mappedState.maps[4] = mapBytes
mappedState.names[4] = "audit.png"
mappedState.surfaces[1].mapMask = 1
try testRenderer.materials.restore(mappedState)
weak var releasedMap = testRenderer.materials.images[4] as AnyObject
try testRenderer.materials.restore(SceneState())
require(testRenderer.materials.payloads[4] == nil && testRenderer.materials.settings[1].mapMask == 0
    && testRenderer.materials.images[4].width == 1,
  "empty-state restore replaces absent maps with shared defaults")
autoreleasepool { }
require(releasedMap == nil, "empty-state restore releases the obsolete map")
let baseTextureBytes = testRenderer.materials.uniqueTextureBytes(
  testRenderer.materials.images + testRenderer.materials.graphTextures + [testRenderer.materials.environmentTexture])
try testRenderer.materials.restore(mappedState)
let oneMapBytes = testRenderer.materials.uniqueTextureBytes(
  testRenderer.materials.images + testRenderer.materials.graphTextures + [testRenderer.materials.environmentTexture])
try testRenderer.materials.restore(SceneState())
var twoMapState = mappedState
twoMapState.maps[8] = mapBytes
twoMapState.names[8] = "audit-2.png"
twoMapState.surfaces[2].mapMask = 1
testRenderer.materials.textureBudgetOverride = baseTextureBytes + (oneMapBytes - baseTextureBytes)
do {
  try testRenderer.materials.restore(twoMapState)
  require(false, "aggregate texture budget rejects a multi-image candidate")
} catch {}
require(testRenderer.materials.payloads[4] == nil && testRenderer.materials.images[4].width == 1,
  "failed aggregate texture preparation preserves the published state")
testRenderer.materials.textureBudgetOverride = nil
print("PASS: restored map release and aggregate candidate texture budgeting")

let stableState = testRenderer.materials.state()
let stableArgument = testRenderer.materials.argumentBuffer
var failedState = stableState
failedState.emissions = [8: SIMD3<Float>(12, 8, 4)]
testRenderer.materials.bindingAllocationFailureCountdown = 3
do {
    try testRenderer.materials.restore(failedState)
    require(false, "injected late binding allocation fails")
} catch {}
require(testRenderer.materials.argumentBuffer === stableArgument
    && testRenderer.materials.emissions == stableState.emissions,
  "late binding failure rolls back CPU and GPU resource snapshots")
testRenderer.materials.objects[1].positionScale.x += 1
testRenderer.materials.bindingAllocationFailureCountdown = 0
let failedEncoder = testRenderer.commandQueue.makeCommandBuffer()!.makeComputeCommandEncoder()!
require(!testRenderer.materials.bind(failedEncoder), "binding failure propagates to the caller")
failedEncoder.endEncoding()
try testRenderer.materials.rebuildArguments(testRenderer.materials.images)

// Integrate production rendering (including preview scale and display-only changes).
try testRenderer.materials.setEnvironment(nil);try testRenderer.materials.setMesh([]);try testRenderer.materials.restore(SceneState())
testRenderer.sceneIndex=1;testRenderer.samplingMode=0;testRenderer.denoiserEnabled=true
testRenderer.options=StudioOptions();testRenderer.options.previewScale=0.5
let outputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:96,height:64,mipmapped:false)
outputDescriptor.storageMode = .shared;outputDescriptor.usage=[.shaderRead,.shaderWrite]
let studioOutput=gpu.makeTexture(descriptor:outputDescriptor)!
var frameDone=false
testRenderer.onFrameUpdate={_ in frameDone=true}
func waitUntil(_ condition:()->Bool,seconds:Double=30) {
    let deadline=Date().addingTimeInterval(seconds)
    while !condition() && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
    require(condition(),"async operation completes")
}
testRenderer.samplingMode=1
testRenderer.denoiserEnabled=false
var allocationDone=false
testRenderer.onFrameUpdate={_ in allocationDone=true}
testRenderer.renderFrame(output:studioOutput);waitUntil({allocationDone})
let nonReSTIRBytes=testRenderer.residentFrameBytes
require(testRenderer.resPosDirA?.width==1 && testRenderer.giPosPdfA?.width==1,
  "non-ReSTIR mode uses placeholder reservoirs")
testRenderer.samplingMode=0
testRenderer.denoiserEnabled=true
frameDone=false
testRenderer.onFrameUpdate={_ in frameDone=true}
testRenderer.renderFrame(output:studioOutput);waitUntil({frameDone})
require(testRenderer.accumTexture?.width==48 && testRenderer.metalFX?.output.width==48,"preview scale preserves native-resolution MetalFX")
require(testRenderer.resPosDirA?.width==48 && testRenderer.giPosPdfA?.width==48
    && testRenderer.residentFrameBytes > nonReSTIRBytes,
  "ReSTIR transition allocates full-size reservoirs")
let beforeCount=testRenderer.frameIndex
for enabled in [false,true] {
    testRenderer.denoiserEnabled=enabled
    let refresh=testRenderer.commandQueue.makeCommandBuffer()!
    require(testRenderer.presentCurrentFrame(refresh,output:studioOutput),"frozen display refresh encodes")
    refresh.commit();refresh.waitUntilCompleted()
    require(refresh.status == .completed && testRenderer.lastPresentationUsedMetalFX==enabled && testRenderer.frameIndex==beforeCount,"MetalFX toggle refreshes frozen image without tracing")
}
testRenderer.options.maxSamples=1
require(testRenderer.reachedLimit,"sample target stops rendering")
let displayCommand=testRenderer.commandQueue.makeCommandBuffer()!
testRenderer.options.exposure=2;testRenderer.options.compare=0.5
require(testRenderer.encodeDisplay(displayCommand,display:testRenderer.lastDisplay!,raw:testRenderer.accumTexture!,output:studioOutput),"display encoder")
displayCommand.commit();displayCommand.waitUntilCompleted()
require(displayCommand.status == .completed && testRenderer.frameIndex==beforeCount,"display adjustment preserves accumulation")
let debugDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:testRenderer.accumTexture!.width,height:testRenderer.accumTexture!.height,mipmapped:false)
debugDescriptor.storageMode = .shared;debugDescriptor.usage=[.shaderRead,.shaderWrite]
let debugOutput=gpu.makeTexture(descriptor:debugDescriptor)!
var debugSignatures=[Float]()
for mode in UInt32(1)...4 {
    testRenderer.viewportMode=mode
    let command=testRenderer.commandQueue.makeCommandBuffer()!
    require(testRenderer.presentCurrentFrame(command,output:debugOutput),"viewport inspection mode encodes")
    command.commit();command.waitUntilCompleted();require(command.status == .completed,"viewport inspection command")
    let pixels=readTexture(debugOutput)
    require(pixels.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),"finite viewport inspection")
    debugSignatures.append(pixels.reduce(0){$0+$1.x+$1.y+$1.z}/Float(pixels.count))
}
testRenderer.viewportMode=0
require(Set(debugSignatures.map{Int(($0*1000).rounded())}).count>=3 && testRenderer.frameIndex==beforeCount,"viewport inspection modes are distinct and preserve accumulation")
testRenderer.options.timeLimit=2;testRenderer.options.maxSamples=0;testRenderer.renderElapsed=2
require(testRenderer.reachedLimit,"time target stops rendering")
print("PASS: production render scale, MetalFX, sample/time limits, display-only accumulation preservation")

// AppKit layout/actions, without displaying a native window or touching user autosave.
let application=NSApplication.shared
application.setActivationPolicy(.prohibited)
let testWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:680),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
let controller=StudioController(renderer:testRenderer,window:testWindow)
testWindow.contentView=controller.view
controller.viewport.isPaused=true
for page in 0..<7 {
    controller.page=page;controller.rebuild();controller.view.layoutSubtreeIfNeeded()
    require(controller.stack.arrangedSubviews.count>3,"inspector page \(page) contains controls")
    require(controller.sidebar.frame.width>300 && controller.viewport.frame.width>300,"inspector layout leaves room for viewport")
}
frameDone=false
testRenderer.onFrameUpdate={_ in frameDone=true}
testRenderer.renderFrame(output:studioOutput);waitUntil({frameDone})
controller.startOIDNPreview()
waitUntil({controller.previewDenoiseJob==nil},seconds:45)
require(testRenderer.offlineDenoisedPreview != nil && testRenderer.paused,"controller displays a frozen OIDN viewport preview")
let oidnPreviewCommand=testRenderer.commandQueue.makeCommandBuffer()!
require(testRenderer.presentCurrentFrame(oidnPreviewCommand,output:studioOutput),"OIDN viewport presentation encodes")
oidnPreviewCommand.commit();oidnPreviewCommand.waitUntilCompleted()
require(oidnPreviewCommand.status == .completed && !testRenderer.lastPresentationUsedMetalFX,"OIDN viewport preview bypasses MetalFX")
controller.clearOIDNPreview()
require(testRenderer.offlineDenoisedPreview == nil && !testRenderer.paused,"clearing OIDN preview restores live rendering")
controller.page=3;controller.rebuild();controller.view.layoutSubtreeIfNeeded()
if let rep=controller.sidebar.bitmapImageRepForCachingDisplay(in:controller.sidebar.bounds) {
    controller.sidebar.cacheDisplay(in:controller.sidebar.bounds,to:rep)
    try rep.representation(using:.png,properties:[:])!.write(to:studioDirectory.appendingPathComponent("inspector.png"))
}
controller.history.groupsByEvent=false
controller.history.beginUndoGrouping();controller.checkpoint("Exposure");testRenderer.options.exposure=3;controller.history.endUndoGrouping()
controller.history.undo();require(testRenderer.options.exposure==2,"GUI undo restores project state")
controller.history.redo();require(testRenderer.options.exposure==3,"GUI redo restores project state")
controller.saveTimer?.invalidate()
// Same-scene assignments are common during restore/test setup and must not reset the camera.
testRenderer.yaw = 1.1; testRenderer.pitch = -0.4; testRenderer.distance = 0.002
let sameScene = testRenderer.sceneIndex
testRenderer.sceneIndex = sameScene
require(abs(testRenderer.yaw - 1.1) < 1e-6 && abs(testRenderer.distance - 0.002) < 1e-7,
  "same-scene assignment preserves camera")
let tinyClip = testRenderer.cameraClipPlanes()
require(tinyClip.near < 0.001 && tinyClip.far >= 100, "camera clip planes support tiny scenes")
require(testRenderer.renderMemoryError(width: 8192, height: 8192) != nil,
  "oversized render is rejected by GPU memory preflight")
let autosaveTestURL = studioDirectory.appendingPathComponent("final-autosave.vtrace")
try controller.flushAutosave(to: autosaveTestURL)
let autosaved = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: autosaveTestURL))
require(autosaved.camera.distance == testRenderer.distance, "shutdown autosave flush persists final snapshot")
testRenderer.distance = 4.6; testRenderer.pitch = 0.2
// Export through the actual controller, then decode its independently sized file.
controller.renderer.options.outputWidth=48;controller.renderer.options.outputHeight=32;controller.renderer.options.exportSamples=2
let exportURL=studioDirectory.appendingPathComponent("controller-export.png")
controller.startExport(url:exportURL,hdr:false)
waitUntil({controller.exportRenderer==nil},seconds:45)
let exported=NSBitmapImageRep(data:try Data(contentsOf:exportURL))!
require(exported.pixelsWide==48 && exported.pixelsHigh==32,"controller export uses requested output dimensions")
controller.saveTimer?.invalidate();controller.viewport.delegate=nil
print("PASS: six AppKit inspector pages, OIDN viewport preview, undo/redo, independent export flow")
