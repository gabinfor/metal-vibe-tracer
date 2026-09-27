// Verification-gap checks (R-105, R-107, R-116, R-117, R-118): motion/jitter/depth
// conventions, the MetalFX-unavailable fallback, multi-frame inspection renders, edit
// invalidation, project I/O guards, quit, preflight alongside live frames and mip filtering.
func fixTestsChecks() throws {
  let r = testRenderer
  let folder = testOutputDirectory.appendingPathComponent("fix-tests", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let history = controller.history
  let wasGroupingByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer { history.groupsByEvent = wasGroupingByEvent }
  func grouped(_ body: () throws -> Void) rethrows {
    history.beginUndoGrouping()
    defer { history.endUndoGrouping() }
    try body()
  }
  func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
    return gpu.makeTexture(descriptor: d)!
  }
  // One production frame (renderFrame), waiting for its completion handler.
  func frame(_ output: MTLTexture, _ renderer: PathTracerRenderer = testRenderer) {
    var done = false, failure: String?
    let savedUpdate = renderer.onFrameUpdate, savedError = renderer.onError
    renderer.onFrameUpdate = { _ in done = true }
    renderer.onError = { failure = $0 }
    defer { renderer.onFrameUpdate = savedUpdate; renderer.onError = savedError }
    renderer.renderFrame(output: output)
    waitUntil({ done || failure != nil })
    require(failure == nil, "renderFrame: \(failure ?? "")")
  }
  func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
  func reset() throws {
    controller.saveTimer?.invalidate()
    try controller.restore(ProjectDocument())
    controller.associate(nil, edited: false, replaced: true)
    controller.saveTimer?.invalidate()
    history.removeAllActions()
    r.options.previewScale = 1
    r.paused = false
  }
  try reset()

  // R-105: motion vectors are previous-minus-current pixel positions of the G-buffer
  // point without jitter; primary rays sample pixel centre + jitter (y down), which
  // is the offset MetalFX receives; MetalFX's depth and matrices match the frame's
  // view projection (the renderer's clip planes).
  if r.supportsMetalFX {
    let w = 96, h = 64
    let output = texture(.rgba16Float, w, h)
    r.sceneIndex = 0; r.samplingMode = 0; r.viewportMode = 0; r.denoiserEnabled = true
    frame(output); frame(output)
    let before = r.lastUniforms!
    let eye = SIMD3<Float>(before.cameraPos.x, before.cameraPos.y, before.cameraPos.z)
    let right = simd_normalize(simd_cross(simd_normalize(r.target - eye), SIMD3<Float>(0, 1, 0)))
    // A pure camera translation to the right: static points move left on screen.
    r.target += right * 0.02
    frame(output)
    let u = r.lastUniforms!, fx = r.metalFX!
    require(u.prevViewProj == before.currentViewProj && u.currentViewProj != before.currentViewProj,
      "the moving frame carries the previous view projection")
    let positions = readTexture(r.historyPosDepth!), motion = readTexture(fx.motion), depth = readTexture(fx.depth)
    let viewToClip = fx.scaler.viewToClipMatrix, worldToView = fx.scaler.worldToViewMatrix
    var matrixError: Float = 0
    for c in 0..<4 { for row in 0..<4 {
      let a = (viewToClip * worldToView)[c][row], b = u.currentViewProj[c][row]
      matrixError = max(matrixError, abs(a - b) / max(1, abs(b)))
    }}
    require(matrixError < 1e-4, "MetalFX view and projection matrices match the frame (\(matrixError))")
    let clip = r.cameraClipPlanes()
    require(abs(viewToClip[2][2] - clip.near / (clip.far - clip.near)) < 1e-6 * max(1, viewToClip[2][2]) && fx.scaler.isDepthReversed,
      "MetalFX projection uses the renderer's reversed-Z clip planes")
    func pixel(_ m: simd_float4x4, _ p: SIMD4<Float>) -> SIMD2<Float> {
      let c = m * SIMD4<Float>(p.x, p.y, p.z, 1)
      return SIMD2((c.x / c.w * 0.5 + 0.5) * Float(w), (0.5 - c.y / c.w * 0.5) * Float(h))
    }
    var hits = 0, rightward = 0
    var jitterError: Float = 0, motionError: Float = 0, depthError: Float = 0
    var measuredJitter = SIMD2<Float>(repeating: 0)
    for y in 0..<h { for x in 0..<w {
      let i = y * w + x, p = positions[i]
      guard p.w > 0 else { continue }
      hits += 1
      let current = pixel(u.currentViewProj, p), previous = pixel(u.prevViewProj, p)
      let offset = current - SIMD2(Float(x) + 0.5, Float(y) + 0.5)
      measuredJitter += offset
      jitterError = max(jitterError, simd_length(offset - u.jitter))
      let expected = previous - current, actual = SIMD2(motion[i].x, motion[i].y)
      motionError = max(motionError, simd_length(actual - expected) / max(1, simd_length(expected)))
      if actual.x > 0 { rightward += 1 }
      let view = viewToClip * worldToView * SIMD4<Float>(p.x, p.y, p.z, 1)
      depthError = max(depthError, abs(depth[i].x - view.z / view.w) / max(1e-6, view.z / view.w))
    }}
    measuredJitter /= Float(max(1, hits))
    print("fix-tests motion/jitter/depth: \(hits) hits, jitter \(u.jitter) measured \(measuredJitter) (max error \(jitterError) px), motion error \(motionError), depth error \(depthError), rightward \(rightward)")
    require(hits > w * h / 2, "motion check sees geometry")
    require(jitterError < 0.01 && simd_length(u.jitter) > 0.1, "primary rays sample pixel centre plus the frame jitter (y down)")
    require(abs(fx.scaler.jitterOffsetX - measuredJitter.x) < 0.01 && abs(fx.scaler.jitterOffsetY - measuredJitter.y) < 0.01,
      "MetalFX receives the measured sample offset with the same sign")
    require(motionError < 0.01, "motion vectors are previous minus current pixel position")
    require(rightward > hits * 99 / 100, "a camera moving right yields positive horizontal motion")
    require(depthError < 1e-3, "MetalFX depth is the reversed-Z depth of its own view and projection")

    // A static camera: the converged MetalFX image stays registered with the raw
    // accumulation (sub-pixel shift from a one-step Lucas-Kanade fit).
    r.resetAccumulation()
    for _ in 0..<24 { frame(output) }
    let raw = displayPixels(readTexture(r.accumTexture!)), shown = displayPixels(readTexture(fx.output))
    func luma(_ p: SIMD4<Float>) -> Float { (p.x + p.y + p.z) / 3 }
    var a = simd_float2x2(), b = SIMD2<Float>(repeating: 0)
    for y in 1..<(h - 1) { for x in 1..<(w - 1) {
      let i = y * w + x
      let g = SIMD2((luma(raw[i + 1]) - luma(raw[i - 1])) / 2, (luma(raw[i + w]) - luma(raw[i - w])) / 2)
      a = a + simd_float2x2(rows: [g * g.x, g * g.y]); b += g * (luma(shown[i]) - luma(raw[i]))
    }}
    let shift = a.determinant > 1e-9 ? a.inverse * b : SIMD2<Float>(repeating: .nan)
    print("fix-tests static MetalFX shift versus raw: \(shift) px")
    require(simd_length(shift) < 0.1, "static MetalFX output is not shifted against the raw render")
    print("PASS: fix-tests motion-vector sign/scale, jitter sign, MetalFX matrices/depth and static registration (R-105)")
  } else {
    print("SKIP: fix-tests MetalFX motion/jitter/depth checks (MetalFX unsupported on \(gpu.name))")
  }

  // R-117: a device without MetalFX presents the raw accumulation, never fails a
  // frame, and neither allocates nor budgets MetalFX resources.
  do {
    PathTracerRenderer.simulateUnsupportedMetalFX = true
    let fallback = try PathTracerRenderer(device: gpu, sharing: r)
    PathTracerRenderer.simulateUnsupportedMetalFX = false
    require(!fallback.supportsMetalFX && !fallback.denoiserEnabled && fallback.metalFXScalerBytesPerPixel == 0,
      "unsupported devices start with the denoiser off and no MetalFX budget")
    fallback.options.previewScale = 1; fallback.sceneIndex = 1; fallback.samplingMode = 0
    fallback.denoiserEnabled = true  // e.g. a project saved on a MetalFX-capable Mac
    let output = texture(.rgba32Float, 64, 48)
    for _ in 0..<3 {
      frame(output, fallback)
      require(!fallback.lastPresentationUsedMetalFX && fallback.metalFX == nil && fallback.lastDisplay === fallback.accumTexture,
        "MetalFX-unavailable frames present the raw accumulation")
    }
    let reference = texture(.rgba32Float, 64, 48)
    let command = fallback.commandQueue.makeCommandBuffer()!
    require(fallback.encodeDisplay(command, display: fallback.accumTexture!, raw: fallback.accumTexture!, output: reference),
      "fallback display reference encodes")
    command.commit(); command.waitUntilCompleted()
    require(readTexture(output) == readTexture(reference), "fallback shows exactly the tone-mapped raw render")
    let refresh = fallback.commandQueue.makeCommandBuffer()!
    require(fallback.presentCurrentFrame(refresh, output: output), "fallback paused refresh encodes")
    refresh.commit(); refresh.waitUntilCompleted()
    require(!fallback.lastPresentationUsedMetalFX && mean(readTexture(fallback.accumTexture!)) > 0.01,
      "fallback refresh shows the raw render")
    require(fallback.renderMemoryError(width: 64, height: 48) == nil && fallback.metalFX == nil,
      "fallback frames fit the preflight without MetalFX resources")
    print("PASS: fix-tests MetalFX-unavailable fallback presents and budgets the raw render (R-117)")
  }

  // R-118: multi-frame production renders in every inspection view, for ReSTIR and a
  // non-ReSTIR strategy, then resize down/up and return to beauty.
  for scene in [UInt32(0), 1] {
    for mode in [UInt32(0), 1] {
      var signatures = [Int]()
      for view in UInt32(1)...4 {
        var u = makeUniforms(scene: scene, mode: mode, width: 49, height: 33)
        u.viewportMode = view
        _ = render(u, samples: 3, denoise: mode == 0)
        let shown = readTexture(renderOutputs[SIMD2(49, 33)]!)
        require(shown.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "finite inspection view \(view)")
        require(r.resPosDirA?.width == 1 && r.giWeightsB?.width == 1 && r.metalFX == nil,
          "inspection view \(view) uses placeholder reservoirs and no MetalFX")
        signatures.append(Int((shown.reduce(0) { $0 + $1.x + $1.y + $1.z } / Float(shown.count) * 1000).rounded()))
      }
      require(Set(signatures).count >= 3, "inspection views differ (scene \(scene), strategy \(mode))")
    }
  }
  for (width, height) in [(64, 48), (32, 24), (96, 72)] {
    let beauty = render(makeUniforms(scene: 1, mode: 0, width: width, height: height), samples: 3, denoise: true)
    require(r.accumTexture?.width == width && r.resPosDirA?.width == width && mean(beauty) > 0.01,
      "beauty frames after inspection reallocate reservoirs at \(width)x\(height)")
    if r.supportsMetalFX { require(r.metalFX?.output.width == width, "MetalFX follows the resize to \(width)x\(height)") }
  }
  print("PASS: fix-tests multi-frame renderFrame inspection views, strategies and resize (R-118)")

  // R-107 (F4): a render that fits alone but not beside a concurrent export is
  // rejected up front and keeps the live frame resources.
  do {
    try reset()
    let output = texture(.rgba16Float, 64, 48)
    frame(output)
    let accum = r.accumTexture, count = r.frameIndex
    let budget = max(UInt64(512 * 1024 * 1024), gpu.recommendedMaxWorkingSetSize * 7 / 10)
    require(r.renderMemoryError(width: 128, height: 96) == nil, "the larger render fits alone")
    var errors = [String]()
    let savedError = r.onError
    r.onError = { errors.append($0) }
    r.concurrentRenderBytes = budget
    r.renderFrame(output: texture(.rgba16Float, 128, 96))
    r.concurrentRenderBytes = 0
    r.onError = savedError
    require(errors.count == 1 && errors[0].contains("GPU memory") && r.accumTexture === accum && r.frameIndex == count,
      "a render rejected by the shared budget reports it and keeps the live frame")
    frame(output)
    require(r.accumTexture === accum && r.frameIndex == count + 1, "the live preview continues after the rejection")
  }
  print("PASS: fix-tests preflight rejection beside a concurrent render (R-107, F4)")

  // R-107 (F5): a scene-graph document through the controller. Picking, and each
  // editGraph kind's effect on BVH builds, accumulation, MetalFX history and emitters.
  do {
    var graph = SceneGraph()
    _ = try graph.addOBJ("v -1 0 0\nv 1 0 0\nv 1 2 0\nv -1 2 0\nusemtl Paint\nf 1 2 3 4\n", name: "quad.obj")
    let glow = try graph.addMaterial("Glow")
    var document = ProjectDocument()
    document.scene = 6; document.graph = graph; document.options.previewScale = 1
    document.camera.yaw = 0; document.camera.pitch = 0; document.camera.distance = 4; document.camera.fov = 45
    document.camera.target = SIMD3<Float>(0, 1, 0)
    var state = SceneState(); state.emissions = [glow.slot: SIMD3<Float>(6, 6, 6)]
    document.scenes[6] = state
    try controller.restore(document)
    history.removeAllActions()
    let m = r.materials
    func emitters() -> UInt32 { r.materials.emitterBuffer.contents().load(as: UInt32.self) }
    let meshIndex = controller.project.graph!.nodes.firstIndex { $0.mesh != nil }!
    let meshNode = controller.project.graph!.nodes[meshIndex].id
    require(r.materials.hasSceneGraph && emitters() == 0, "graph document loads without emitters")
    let output = texture(.rgba16Float, 64, 48)
    r.denoiserEnabled = r.supportsMetalFX
    frame(output); frame(output)
    var picked: Int? = -1
    r.pick(SIMD2<Float>(0.5, 0.5)) { picked = $0 }
    waitUntil({ picked != -1 })
    require(picked == 64 + meshIndex, "pick_kernel returns the graph node under the cursor (\(String(describing: picked)))")
    controller.selectedNode = nil
    controller.pick(SIMD2<Float>(0.5, 0.5))
    waitUntil({ controller.selectedNode != nil })
    require(controller.selectedNode == meshNode && controller.page == 3, "clicking selects the picked object")
    let builds = m.meshBuildCount
    // Metadata: no flattening or BVH build, and the accumulation continues.
    let count = r.frameIndex, generation = r.interactionGeneration
    grouped { controller.editGraph("Rename object", kind: .metadata) { g in g.nodes[meshIndex].name = "Renamed" } }
    require(controller.project.graph!.nodes[meshIndex].name == "Renamed" && r.materials.meshBuildCount == builds
      && r.frameIndex == count && r.interactionGeneration == generation, "metadata edits keep geometry and accumulation")
    // Bindings: triangle slots and the emitter list change without a BVH build; the
    // accumulation and MetalFX history restart.
    if r.supportsMetalFX { require(!r.metalFXHistoryNeedsReset, "MetalFX history is live before the edit") }
    grouped { controller.editGraph("Assign material", kind: .bindings) { g in g.nodes[meshIndex].bindings[0] = glow.id } }
    require(r.materials.meshBuildCount == builds && emitters() == 2 && r.frameIndex == 0 && r.metalFXHistoryNeedsReset
      && r.reservoirHistory == 0, "binding edits rebind emitters without a BVH build and restart accumulation")
    frame(output)
    require(r.frameIndex == 1, "rendering resumes after a binding edit")
    history.undo()
    waitUntil({ !controller.isBusy })
    require(emitters() == 0 && controller.project.graph!.nodes[meshIndex].bindings[0] != glow.id && r.frameIndex == 0,
      "undoing the binding edit restores the bindings and the emitter list")
    // Geometry: a transform flattens and rebuilds the BVH once.
    frame(output)
    let undoneBuilds = r.materials.meshBuildCount
    grouped { controller.editGraph("Move object") { g in g.nodes[meshIndex].transform.positionScale.x = 0.25 } }
    require(r.materials.meshBuildCount == undoneBuilds + 1 && r.frameIndex == 0, "geometry edits rebuild the BVH and restart")
    // Inspector: a material parameter restarts accumulation and MetalFX history.
    frame(output); frame(output)
    if r.supportsMetalFX { require(!r.metalFXHistoryNeedsReset, "MetalFX history is live before the inspector edit") }
    controller.selectedNode = meshNode; controller.selectedSubset = 0
    controller.page = 3; controller.rebuild()
    let control = controller.stack.arrangedSubviews.compactMap { $0 as? NumberControl }.first!
    grouped { control.set(control.minimum + (control.maximum - control.minimum) * 0.37) }
    require(r.frameIndex == 0 && r.metalFXHistoryNeedsReset && r.reservoirHistory == 0 && controller.documentEdited,
      "inspector edits restart accumulation, ReSTIR and MetalFX history")
    controller.saveTimer?.invalidate()
  }
  print("PASS: fix-tests picking, editGraph metadata/bindings/geometry and inspector invalidation (R-107, F5)")

  // R-107 (F5 persistence): generation, busy, revision and identity guards.
  do {
    try reset()
    func idle() { waitUntil({ !controller.isBusy }, seconds: 60) }
    func decode(_ url: URL) throws -> ProjectDocument { try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url)) }
    let fileA = folder.appendingPathComponent("guard-A.vtrace"), fileB = folder.appendingPathComponent("guard-B.vtrace")
    let fileC = folder.appendingPathComponent("guard-C.vtrace")
    for url in [fileA, fileB, fileC] { try? FileManager.default.removeItem(at: url) }
    var opened = ProjectDocument(); opened.options.exposure = 0.5
    try JSONEncoder().encode(opened).write(to: fileB)
    var saveDuringOpen: Bool?
    grouped {
      controller.beginOpenProject(fileB)
      controller.beginSaveProject(fileA) { saveDuringOpen = $0 }
      require(saveDuringOpen == false, "Save during Open is rejected")
      idle()
    }
    require(controller.projectURL == fileB && !FileManager.default.fileExists(atPath: fileA.path),
      "Open completes and the rejected Save writes nothing")
    controller.beginSaveProject(fileA)
    controller.newProject()
    idle()
    require(controller.projectURL == fileA && testRenderer.options.exposure == 0.5 && !controller.documentEdited,
      "New during Save does nothing and the save associates its file")
    controller.beginSaveProject(fileA)
    testRenderer.options.exposure = 1.25
    controller.changed(reset: false)
    idle()
    let savedBeforeEdit = try decode(fileA)
    require(controller.projectURL == fileA && controller.documentEdited && savedBeforeEdit.options.exposure == 0.5,
      "an edit during Save keeps the newer revision unsaved")
    controller.beginSaveProject(fileC)
    controller.associate(nil, edited: true, replaced: true)
    idle()
    require(controller.projectURL == nil && controller.documentEdited && FileManager.default.fileExists(atPath: fileC.path),
      "a save never associates its file with a document that replaced it meanwhile")
    controller.saveTimer?.invalidate()
  }
  print("PASS: fix-tests Save during Open, New during Save, edit during Save and identity guards (R-107, F5)")

  // R-116: black/white 1-pixel checker; box-filtered mips average in linear light,
  // so sRGB and linear maps both read 0.5 at LOD 1 (gamma-incorrect filtering: 0.214).
  do {
    try reset()
    let checker = try materialFixture("bw-checker") { x, y in (x + y) % 2 == 0 ? [255, 255, 255, 255] : [0, 0, 0, 255] }
    try r.materials.load(url: checker, slot: 1, channel: 0)
    try r.materials.load(url: checker, slot: 1, channel: 1)
    let library = try gpu.makeLibrary(source: metalSource + """
      kernel void fix_tests_mips(constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(0)]]) {
          // 64 texels wide at density 1: footprint 2/64 is LOD 1, footprint 1 the 1x1 level.
          out[0] = sample_material_map(images, 1, 0, float2(0.3f, 0.3f), float2(1), 2.0f / 64.0f);
          out[1] = sample_material_map(images, 1, 1, float2(0.3f, 0.3f), float2(1), 2.0f / 64.0f);
          out[2] = sample_material_map(images, 1, 0, float2(0.3f, 0.3f), float2(1), 1.0f);
          out[3] = sample_material_map(images, 1, 1, float2(0.3f, 0.3f), float2(1), 1.0f);
      }
      """, options: shaderCompileOptions())
    let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "fix_tests_mips")!)
    let buffer = gpu.makeBuffer(length: 4 * 16, options: .storageModeShared)!
    let command = r.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    r.materials.bind(encoder)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "mip sampling kernel completes")
    let mips = (0..<4).map { buffer.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
    print("fix-tests checker mips (sRGB LOD1, linear LOD1, sRGB top, linear top): \(mips.map { $0.x })")
    for (i, name) in ["sRGB LOD 1", "linear LOD 1", "sRGB 1x1", "linear 1x1"].enumerated() {
      require(abs(mips[i].x - 0.5) < 0.02 && abs(mips[i].y - 0.5) < 0.02, "\(name) mip of a black/white checker is 0.5 linear")
    }
    for channel in 0..<2 { try r.materials.clear(slot: 1, channel: channel) }
  }
  print("PASS: fix-tests linear-light mip filtering of sRGB and linear maps (R-116)")

  // R-116: MaterialX subtract (in1 - in2) and clamp evaluated on the GPU from a
  // texcoord-driven value, so neither can be folded on the CPU. Swapped operands
  // would give (0.1, 0.1, 0.1) and roughness 0.5.
  do {
    try reset()
    let graph = try MaterialXImporter.read(Data("""
      <materialx version="1.39">
      <texcoord name="uv" type="vector2"/>
      <extract name="u" type="float"><input name="in" type="vector2" nodename="uv"/><input name="index" type="integer" value="0"/></extract>
      <subtract name="tint" type="color3"><input name="in1" type="color3" value="0.9,0.5,0.2"/><input name="in2" type="float" nodename="u"/></subtract>
      <clamp name="bounded" type="color3"><input name="in" type="color3" nodename="tint"/><input name="low" type="float" value="0.1"/><input name="high" type="float" value="0.4"/></clamp>
      <subtract name="offset" type="float"><input name="in1" type="float" nodename="u"/><input name="in2" type="float" value="0.75"/></subtract>
      <clamp name="rough" type="float"><input name="in" type="float" nodename="offset"/><input name="low" type="float" value="0.05"/><input name="high" type="float" value="1"/></clamp>
      <open_pbr_surface name="Ops" type="surfaceshader"><input name="base_color" type="color3" nodename="bounded"/><input name="specular_roughness" type="float" nodename="rough"/></open_pbr_surface>
      </materialx>
      """.utf8), baseURL: folder, source: "Ops.mtlx")
    require(graph.materials.count == 1, "subtract/clamp MaterialX graph compiles: \(graph.report)")
    try r.materials.prepareMaterialX([8: graph.materials[0]])
    let library = try gpu.makeLibrary(source: metalSource + """
      kernel void fix_tests_materialx(constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(0)]]) {
          HitRecord h = {}; h.t = 1; h.normal = float3(0, 0, -1); h.front_face = true; h.mat.slot = 8; h.uv = float2(0.25f);
          h.tangent = float3(1, 0, 0); h.bitangent = float3(0, 1, 0); h.uvDensity = float2(0); h.geometricNormal = h.normal;
          Ray ray = { float3(0, 0, -1), float3(0, 0, 1) };
          resolve_materialx(h, ray, images, 0.0f);
          out[0] = float4(h.mat.albedo, h.mat.roughness);
      }
      """, options: shaderCompileOptions())
    let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "fix_tests_materialx")!)
    let buffer = gpu.makeBuffer(length: 16, options: .storageModeShared)!
    let command = r.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    r.materials.bind(encoder)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "MaterialX operator kernel completes")
    let value = buffer.contents().load(as: SIMD4<Float>.self)
    print("fix-tests MaterialX subtract/clamp: \(value)")
    require(simd_length(value - SIMD4<Float>(0.4, 0.25, 0.1, 0.05)) < 1e-4, "MaterialX subtract order and clamp bounds")
    try reset()
  }
  print("PASS: fix-tests MaterialX subtract and clamp on the GPU (R-116)")

  // R-107 (F5): quitting with no pending project I/O flushes the final autosave.
  do {
    try reset()
    testRenderer.options.exposure = 0.75
    controller.changed(reset: false)
    let appDelegate = AppDelegate()
    appDelegate.studio = controller
    try? FileManager.default.removeItem(at: controller.autosaveURL)
    require(appDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
      "quit without pending I/O terminates immediately")
    let flushed = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: controller.autosaveURL))
    require(flushed.options.exposure == 0.75, "applicationShouldTerminate flushes the final autosave")
    controller.terminationRequested = false
    try reset()
  }
  print("PASS: fix-tests applicationShouldTerminate autosave flush (R-107, F5)")
}
try fixTestsChecks()
