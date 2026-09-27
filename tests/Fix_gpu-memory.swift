// Regression checks for the GPU resource allocation and budgeting fixes
// (R-04, R-17..R-21, R-37, R-58..R-62, R-100, R-101, R-125, R-128).
@MainActor func fixGPUMemoryChecks() throws {
  let renderer = testRenderer
  let folder = testOutputDirectory.appendingPathComponent("fix-gpu-memory", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  func png(_ width: Int, _ height: Int, _ rgba: [UInt8]) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: width * 4, bitsPerPixel: 32)!
    for i in 0..<(width * height) { for c in 0..<4 { rep.bitmapData![i * 4 + c] = rgba[c] } }
    return rep.representation(using: .png, properties: [:])!
  }
  // 16-bit maps decode to about the RGBA16 predecode estimate, so budgets can sit
  // between one and two decoded images.
  func png16(_ width: Int, _ height: Int, _ value: UInt16) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 16,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: width * 8, bitsPerPixel: 64)!
    rep.bitmapData!.withMemoryRebound(to: UInt16.self, capacity: width * height * 4) { p in
      for i in 0..<(width * height * 4) { p[i] = i % 4 == 3 ? 65535 : value }
    }
    return rep.representation(using: .png, properties: [:])!
  }
  func sharedTexture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
    return gpu.makeTexture(descriptor: d)!
  }

  // R-128: every host/shader struct agrees on size and field offsets, and the
  // SurfaceSettings array fits the 4 KB setBytes payload.
  func offsets<T>(_ type: T.Type, _ paths: [PartialKeyPath<T>]) -> [Int] {
    [MemoryLayout<T>.stride] + paths.map { MemoryLayout<T>.offset(of: $0)! }
  }
  let layouts: [(String, [String], [Int])] = [
    ("Uniforms", ["cameraPos", "cameraTarget", "cameraUp", "sunParams", "currentViewProj", "prevViewProj",
      "frameIndex", "sceneIndex", "samplingMode", "enableSMS", "skyMode", "enableFog", "viewportMode",
      "width", "height", "jitter", "sampleIndex", "reservoirHistoryReset", "reservoirHistory", "environment", "lens", "light"],
     offsets(Uniforms.self, [\Uniforms.cameraPos, \Uniforms.cameraTarget, \Uniforms.cameraUp, \Uniforms.sunParams,
      \Uniforms.currentViewProj, \Uniforms.prevViewProj, \Uniforms.frameIndex, \Uniforms.sceneIndex,
      \Uniforms.samplingMode, \Uniforms.enableSMS, \Uniforms.skyMode, \Uniforms.enableFog, \Uniforms.viewportMode,
      \Uniforms.width, \Uniforms.height, \Uniforms.jitter, \Uniforms.sampleIndex, \Uniforms.reservoirHistoryReset,
      \Uniforms.reservoirHistory,
      \Uniforms.environment, \Uniforms.lens, \Uniforms.light])),
    ("SurfaceSettings", ["color", "surface", "detail", "enabled", "mapMask", "normalStrength", "padding"],
     offsets(SurfaceSettings.self, [\SurfaceSettings.color, \SurfaceSettings.surface, \SurfaceSettings.detail,
      \SurfaceSettings.enabled, \SurfaceSettings.mapMask, \SurfaceSettings.normalStrength, \SurfaceSettings.padding])),
    ("ObjectSettings", ["positionScale", "rotationHidden", "uvTransform", "channels"],
     offsets(ObjectSettings.self, [\ObjectSettings.positionScale, \ObjectSettings.rotationHidden,
      \ObjectSettings.uvTransform, \ObjectSettings.channels])),
    ("MeshTriangle", ["a", "b", "c", "na", "nb", "nc", "uvab", "uvc"],
     offsets(MeshTriangle.self, [\MeshTriangle.a, \MeshTriangle.b, \MeshTriangle.c, \MeshTriangle.na,
      \MeshTriangle.nb, \MeshTriangle.nc, \MeshTriangle.uvab, \MeshTriangle.uvc])),
    ("MeshNode", ["lo", "hi", "links"], offsets(MeshNode.self, [\MeshNode.lo, \MeshNode.hi, \MeshNode.links])),
    ("GraphInstruction", ["code", "value", "extra", "auxiliary"],
     offsets(GraphInstruction.self, [\GraphInstruction.code, \GraphInstruction.value, \GraphInstruction.extra,
      \GraphInstruction.auxiliary])),
    ("GraphHeader", ["roots0", "roots1", "roots2", "info"],
     offsets(GraphHeader.self, [\GraphHeader.roots0, \GraphHeader.roots1, \GraphHeader.roots2, \GraphHeader.info])),
  ]
  var layoutBody = "", layoutCount = 0
  for (type, fields, _) in layouts {
    layoutBody += "{ \(type) v; out[\(layoutCount)] = sizeof(\(type));"
    layoutCount += 1
    for field in fields {
      layoutBody += " out[\(layoutCount)] = uint((thread char *)&v.\(field) - (thread char *)&v);"
      layoutCount += 1
    }
    layoutBody += " }\n"
  }
  let fixKernels = """
    kernel void fix_gpu_memory_layout(device uint *out [[buffer(0)]]) {
    \(layoutBody)}
    kernel void fix_gpu_memory_sample(constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, filter::nearest);
        out[0] = images.maps[4].sample(s, float2(0.5f), level(0));
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + fixKernels, options: shaderCompileOptions())
  let layoutPipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "fix_gpu_memory_layout")!)
  let samplePipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "fix_gpu_memory_sample")!)
  let layoutBuffer = gpu.makeBuffer(length: layoutCount * 4, options: .storageModeShared)!
  do {
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(layoutPipeline); encoder.setBuffer(layoutBuffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "layout probe completes")
  }
  var index = 0
  for (type, fields, expected) in layouts {
    for (label, swiftValue) in zip(["size"] + fields, expected) {
      let gpuValue = Int(layoutBuffer.contents().load(fromByteOffset: index * 4, as: UInt32.self))
      require(gpuValue == swiftValue, "\(type).\(label): MSL \(gpuValue), Swift \(swiftValue)")
      index += 1
    }
  }
  require(MemoryLayout<SurfaceSettings>.stride * SceneLimits.materials <= 4096
      && renderer.materials.settings.count == SceneLimits.materials, "SurfaceSettings fit setBytes")
  print("PASS: shared struct sizes and offsets match between Swift and Metal")

  // R-21: with full-size sentinel reservoirs bound, the temporal kernel writes no
  // reservoir output in MIS or inspection mode, including sky pixels.
  do {
    let w = 16, h = 12
    var u = makeUniforms(scene: 0, mode: 1, width: w, height: h)
    u.cameraPos = SIMD4<Float>(0, 0.4, 0, 40); u.cameraTarget = SIMD4<Float>(0, 20, 0.5, 16)
    u.cameraUp = SIMD4<Float>(0, 0, 1, 0)
    let gbuffer = [sharedTexture(.rgba32Float, w, h), sharedTexture(.rgba16Float, w, h), sharedTexture(.rgba16Float, w, h)]
    let formats: [MTLPixelFormat] = [.rgba32Float, .rgba32Float, .rgba32Float, .rgba32Float, .rgba32Float, .rgba32Float,
      .rgba32Float, .rgba16Float, .rgba32Float, .rgba32Float, .rgba32Float, .rgba16Float, .rgba32Float, .rgba32Float]
    let reservoirs = formats.map { sharedTexture($0, w, h) }
    for t in reservoirs {
      if t.pixelFormat == .rgba16Float {
        let bytes = [UInt16](repeating: Float16(7).bitPattern, count: w * h * 4)
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 8)
      } else {
        let bytes = [Float](repeating: 7, count: w * h * 4)
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 16)
      }
    }
    let history = [sharedTexture(.rgba32Float, w, h), sharedTexture(.rgba16Float, w, h)]
    for (sampling, viewport) in [(UInt32(1), UInt32(0)), (UInt32(3), UInt32(0)), (UInt32(0), UInt32(2))] {
      u.samplingMode = sampling; u.viewportMode = viewport
      let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
      encoder.setComputePipelineState(renderer.restirTemporalPipeline)
      let bound = gbuffer + Array(reservoirs[0..<6]) + history + Array(reservoirs[6...])
      for (i, t) in bound.enumerated() { encoder.setTexture(t, index: i) }
      renderer.materials.bind(encoder)
      encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
      // The temporal pass also writes the integrator's primary-surface cache.
      encoder.setBuffer(renderer.primarySurfaceBuffer(width: w, height: h)!, offset: 0, index: 3)
      encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
      encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
      require(command.status == .completed, "placeholder-mode temporal pass completes")
      require(readTexture(gbuffer[0]).contains { $0.w < 0 }, "placeholder check includes sky misses")
      for t in reservoirs {
        require(readTexture(t).allSatisfy { $0 == SIMD4<Float>(repeating: 7) },
          "strategy \(sampling), view \(viewport) leaves reservoirs untouched")
      }
    }
  }
  print("PASS: non-ReSTIR and inspection passes never write reservoir outputs")

  // R-04, R-18, R-17: production renderFrame beauty -> inspection -> beauty keeps
  // the accumulation and sample count, swaps only reservoirs, gates temporal
  // reuse once, frees MetalFX while unused and budgets its scaler internals.
  try renderer.materials.setEnvironment(nil); try renderer.materials.setMesh([])
  try renderer.materials.restore(SceneState())
  renderer.paused = false
  renderer.options = StudioOptions(); renderer.options.previewScale = 0.5
  renderer.sceneIndex = 1; renderer.viewportMode = 0; renderer.samplingMode = 0
  renderer.denoiserEnabled = renderer.supportsMetalFX
  let output = sharedTexture(.bgra8Unorm, 96, 64)
  var completed = 0
  renderer.onFrameUpdate = { _ in completed += 1 }
  func frame() {
    let target = completed + 1
    renderer.renderFrame(output: output)
    let deadline = Date().addingTimeInterval(20)
    while completed < target && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    require(completed >= target, "renderFrame completes")
  }
  for _ in 0..<3 { frame() }
  let beautyAccum = renderer.accumTexture
  let beautyCount = renderer.frameIndex
  let beautyBytes = renderer.residentFrameBytes
  require(renderer.resPosDirA?.width == 48 && beautyCount == 3, "beauty frames use full-size reservoirs")
  if renderer.supportsMetalFX {
    let fx = renderer.metalFX!
    let scaler = renderer.metalFXScalerBytesPerPixel
    require(scaler >= 64, "MetalFX scaler internals are measured, not assumed covered by headroom")
    let fxTextures = [fx.color, fx.depth, fx.motion, fx.diffuse, fx.specular, fx.normal, fx.roughness,
      fx.hitDistance, fx.denoiseMask, fx.output, fx.exposure].reduce(UInt64(0)) { $0 + UInt64($1.allocatedSize) }
    require(beautyBytes >= fxTextures + 48 * 32 * scaler, "resident bytes include the scaler internals")
    // A real scaler at a larger size must fit the plan's per-pixel MetalFX term.
    let before = gpu.currentAllocatedSize
    let probe = try MetalFXDenoiser(device: gpu, width: 640, height: 480)
    let measured = UInt64(max(0, gpu.currentAllocatedSize - before))
    withExtendedLifetime(probe) {}
    let with = PathTracerRenderer.FrameResourcePlan(width: 640, height: 480, usesReSTIR: true, usesMetalFX: true,
      metalFXScalerBytesPerPixel: scaler).bytes!
    let without = PathTracerRenderer.FrameResourcePlan(width: 640, height: 480, usesReSTIR: true, usesMetalFX: false).bytes!
    require(with - without >= measured, "MetalFX plan \(with - without) B covers measured \(measured) B")
  }
  renderer.viewportMode = 2
  frame(); frame()
  require(renderer.accumTexture === beautyAccum, "entering inspection keeps the accumulation texture")
  require(renderer.resPosDirA?.width == 1 && renderer.giWeightsB?.width == 1, "inspection frees the reservoirs")
  require(renderer.metalFX == nil, "unused MetalFX denoiser is released")
  require(renderer.residentFrameBytes < beautyBytes, "inspection frees reservoir and MetalFX memory")
  renderer.viewportMode = 0
  require(renderer.frameIndex == beautyCount, "leaving inspection resumes the beauty sample count")
  frame()
  require(renderer.accumTexture === beautyAccum && renderer.frameIndex == beautyCount + 1,
    "returning to beauty continues the accumulation")
  require(renderer.resPosDirA?.width == 48 && renderer.lastUniforms?.reservoirHistoryReset == 1,
    "new reservoirs skip temporal reuse on their first frame")
  frame()
  require(renderer.lastUniforms?.reservoirHistoryReset == 0 && renderer.frameIndex == beautyCount + 2,
    "temporal reuse resumes on the following frame")
  renderer.samplingMode = 1
  frame()
  require(renderer.accumTexture === beautyAccum && renderer.resPosDirA?.width == 1 && renderer.metalFX == nil,
    "switching strategy swaps reservoirs only and releases MetalFX")
  renderer.samplingMode = 0
  print("PASS: inspection/strategy changes reallocate only reservoirs, MetalFX released and fully budgeted")

  // R-125: bind() declares every argument-buffer resource, and resources swapped
  // after encoding stay alive for that command buffer.
  let red = png(8, 8, [255, 0, 0, 255])
  var mapped = SceneState(); mapped.maps[4] = red; mapped.names[4] = "red.png"; mapped.surfaces[1].mapMask = 1
  mapped.emissions = [8: SIMD3<Float>(1, 1, 1)]
  try renderer.materials.restore(mapped)
  let m = renderer.materials
  let bound = Set(m.boundResources.map { ObjectIdentifier($0) })
  let expected: [MTLResource] = m.residentTextures + [m.triangleBuffer, m.nodeBuffer, m.objectBuffer,
    m.graphInstructionBuffer, m.graphHeaderBuffer, m.emissionBuffer, m.emitterBuffer, ]
  require(expected.allSatisfy { bound.contains(ObjectIdentifier($0)) }, "useResources covers every bound slot")
  weak let swapped = m.images[4] as AnyObject
  let sampleOut = gpu.makeBuffer(length: 16, options: .storageModeShared)!
  try autoreleasepool {
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(samplePipeline); require(m.bind(encoder), "bind succeeds")
    encoder.setBuffer(sampleOut, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    encoder.endEncoding()
    try m.restore(SceneState())
    require(swapped != nil, "encoded command buffer retains a swapped map")
    command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "in-flight swap completes: \(String(describing: command.error))")
  }
  let sampled = sampleOut.contents().load(as: SIMD4<Float>.self)
  require(sampled.x > 0.9 && sampled.y < 0.1, "encoded frame reads the map it was encoded with")

  // R-100: rebuilding for an object edit reuses the unchanged emitter buffer.
  try m.restore(mapped)
  let emitters = m.emitterBuffer
  m.objects[1].positionScale.x += 0.5
  do {
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    require(m.bind(encoder), "object edit rebuild succeeds"); encoder.endEncoding()
  }
  require(m.emitterBuffer === emitters, "unchanged emitter list keeps its buffer")

  // R-60: a failed restore keeps a pending object edit pending.
  m.objects[1].positionScale.y = 3
  require(m.bindingsDirty, "object edit pending")
  m.bindingAllocationFailureCountdown = 0
  var other = mapped; other.emissions = [:]
  do { try m.restore(other); require(false, "injected restore failure") } catch {}
  require(m.bindingsDirty, "failed restore keeps pending bindings dirty")
  do {
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    require(m.bind(encoder), "pending edit uploads"); encoder.endEncoding()
  }
  require(m.objectBuffer.contents().load(fromByteOffset: MemoryLayout<ObjectSettings>.stride + 4, as: Float.self) == 3,
    "GPU object settings receive the edit after a failed restore")
  print("PASS: argument-buffer resources declared and retained, emitter reuse, rollback keeps pending edits")

  // R-101: BVH-ordered triangles are read through the shared buffer, not copied.
  var quad = try OBJMesh.load("v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4")
  quad += quad.map { var t = $0; t.a.x += 3; t.b.x += 3; t.c.x += 3; return t }
  try m.setMesh(quad)
  require(m.orderedTriangles.count == quad.count
      && UnsafeRawPointer(m.orderedTriangles.baseAddress!) == UnsafeRawPointer(m.triangleBuffer.contents()),
    "ordered triangles alias the GPU triangle buffer")
  try m.setMesh([])
  print("PASS: single host triangle copy")

  // R-19: maps and MaterialX images are budgeted together in restore().
  try m.restore(SceneState())
  let base = m.uniqueTextureBytes(m.residentTextures)
  let mapData = png16(128, 128, 40_000), graphData = png16(128, 128, 20_000)
  try graphData.write(to: folder.appendingPathComponent("graph.png"))
  let graphImport = try MaterialXImporter.read(Data("""
    <materialx version="1.39"><image name="img" type="color3" colorspace="srgb_texture"><input name="file" type="filename" value="graph.png"/></image>
    <open_pbr_surface name="Graph" type="surfaceshader"><input name="base_color" type="color3" nodename="img"/></open_pbr_surface></materialx>
    """.utf8), baseURL: folder, source: "Fix.mtlx")
  require(graphImport.materials.count == 1, "fixture graph compiles: \(graphImport.report)")
  var mapOnly = SceneState(); mapOnly.maps[4] = mapData; mapOnly.surfaces[1].mapMask = 1
  var graphOnly = SceneState(); graphOnly.materialX = [2: graphImport.materials[0]]
  var both = mapOnly; both.materialX = graphOnly.materialX
  try m.restore(mapOnly); let mapBytes = m.uniqueTextureBytes(m.residentTextures) - base
  try m.restore(graphOnly); let graphBytes = m.uniqueTextureBytes(m.residentTextures) - base
  try m.restore(SceneState())
  print("16-bit map \(mapBytes) B, graph image \(graphBytes) B, estimate \(128 * 128 * 11) B")
  m.textureBudgetOverride = base + max(mapBytes, graphBytes, 128 * 128 * 11) + min(mapBytes, graphBytes) / 2
  try m.restore(mapOnly); try m.restore(SceneState())
  try m.restore(graphOnly); try m.restore(SceneState())
  do { try m.restore(both); require(false, "combined maps and MaterialX images exceed the budget") } catch {}
  require(m.payloads[4] == nil && m.graphTextures.isEmpty && m.materialX.isEmpty,
    "rejected combined restore leaves the published state intact")

  // R-59: float predecode estimate and batch-cumulative pre-checks.
  let floatImage = CIImage(color: CIColor(red: 1, green: 0.5, blue: 0.25)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
  let floatURL = folder.appendingPathComponent("float.tiff")
  try CIContext().writeTIFFRepresentation(of: floatImage, to: floatURL, format: .RGBAf,
    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, options: [:])
  let floatData = try Data(contentsOf: floatURL)
  m.textureBudgetOverride = base + 128 * 128 * 16
  do { try m.validateEncodedImage(floatData); require(false, "32-bit float image uses the RGBA32F estimate") } catch {}
  m.textureBudgetOverride = base + max(mapBytes, 128 * 128 * 11) + mapBytes / 2
  try m.validateEncodedImage(mapData)
  let pending = try m.texture(data: mapData, channel: 0)
  do {
    try m.validateEncodedImage(mapData, pending: [pending])
    require(false, "pre-check counts images decoded earlier in the batch")
  } catch {}
  m.textureBudgetOverride = nil
  print("PASS: combined map/graph budgets, float estimates and cumulative pre-checks")

  // R-58, R-62: environment CDFs are budgeted before allocation, and clearing the
  // environment never aliases a material map.
  let environmentImage = CIImage(color: CIColor(red: 2, green: 1, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 256))
  let environmentURL = folder.appendingPathComponent("environment.exr")
  try CIContext().writeOpenEXRRepresentation(of: environmentImage, to: environmentURL, options: [:])
  let environmentData = try Data(contentsOf: environmentURL)
  m.textureBudgetOverride = base + 512 * 256 * 16 + 512 * 256 * 2
  do { try m.setEnvironment(environmentData); require(false, "environment CDFs count toward the budget") } catch {}
  require(m.environmentData == nil, "rejected environment is not published")
  m.textureBudgetOverride = nil
  try m.setEnvironment(environmentData)
  require(m.environmentColumns.width == 512 && m.uniqueTextureBytes(m.residentTextures) >= base + 512 * 256 * 20,
    "resident textures include the environment CDFs")
  var slotZero = SceneState(); slotZero.maps[0] = mapData; slotZero.surfaces[0].mapMask = 1
  try m.restore(slotZero)
  weak let slotZeroMap = m.images[0] as AnyObject
  try m.setEnvironment(nil)
  try m.clear(slot: 0, channel: 0)
  autoreleasepool {}
  require(slotZeroMap == nil && m.environmentTexture.width == 1,
    "cleared slot-0 map is released; environment uses its own placeholder")
  print("PASS: environment sampling budgets and placeholder")

  // R-20: a replacement library shares identical textures with the published
  // one and budgets its own new textures on top of the live set.
  try m.restore(mapOnly)
  try m.setEnvironment(environmentData)
  let candidate = try MaterialLibrary(device: gpu, function: renderer.materialFunction)
  candidate.external = m.residentSnapshot()
  try candidate.restore(mapOnly)
  try candidate.setEnvironment(environmentData)
  require(candidate.images[4] === m.images[4] && candidate.environmentTexture === m.environmentTexture,
    "replacement shares identical decoded textures")
  let liveBytes = m.uniqueTextureBytes(m.residentTextures)
  candidate.textureBudgetOverride = liveBytes + mapBytes / 2
  var otherMap = SceneState(); otherMap.maps[4] = png16(128, 128, 1_000); otherMap.surfaces[1].mapMask = 1
  do { try candidate.restore(otherMap); require(false, "replacement budget counts the published library") } catch {}
  let published = m.images[4]
  try controller.restore(controller.snapshot())
  require(renderer.materials !== m && renderer.materials.images[4] === published
      && renderer.materials.external.textures.isEmpty,
    "controller restore shares textures and drops its reference to the old library")
  print("PASS: whole-library replacement shares and budgets against the live library")

  // R-37: saving refuses what open would reject, with an actionable message.
  var oversized = ProjectDocument()
  oversized.environmentData = Data(count: 200 * 1024 * 1024)
  var heavy = SceneState()
  for i in 0..<3 { heavy.maps[i] = Data(count: 128 * 1024 * 1024) }
  oversized.scenes[0] = heavy
  do { _ = try oversized.encodeForSaving(); require(false, "save rejects embedded assets above the open limit") } catch {
    require(error.localizedDescription.contains("512 MiB"), "embedded-limit message is actionable")
  }
  do { try controller.requireEmbeddedCapacity(ProjectDocument.embeddedAssetLimit + 1); require(false, "asset loads keep the aggregate limit") } catch {}
  var broken = ProjectDocument(); broken.scenes[0] = SceneState(); broken.scenes[0]!.surfaces = []
  do { _ = try broken.encodeForSaving(); require(false, "save rejects documents validate() rejects") } catch {}
  let saved = try controller.snapshot().encodeForSaving()
  try JSONDecoder().decode(ProjectDocument.self, from: saved).validate()
  let v = SIMD4<Float>(-3.4028235e+38, -1.1754944e-38, -0.12345679, -9.8765434e-12)
  let worst = MeshTriangle(a: v, b: v, c: v, na: v, nb: v, nc: v, uvab: v, uvc: v)
  let perTriangle = try JSONEncoder().encode(Array(repeating: worst, count: 1000)).count / 1000
  require(perTriangle <= 600, "triangle JSON bound holds (\(perTriangle) B)")
  require(ProjectDocument.maximumFileBytes >= ProjectDocument.embeddedAssetLimit / 3 * 4 + 2 * SceneLimits.triangles * perTriangle,
    "open limit covers base64 assets and both triangle stores")
  print("PASS: save and autosave only write projects the open path accepts")
}
try fixGPUMemoryChecks()
