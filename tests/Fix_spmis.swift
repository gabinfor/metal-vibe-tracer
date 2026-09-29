// Stochastic pairwise MIS spatial reuse (REFERENCES.md SPMIS2026): layouts, mode plumbing and
// resolution; the defensive pairwise MIS partition of unity and the unbiasedness of its
// stochastic estimate (Eqs. 15-19) with the inverse-CDF neighbour draw of Eq. 17; reuse-cell
// construction and the cell search on synthetic G-buffers; memory and resource release;
// fallback equivalence; spatial-only mean radiance against MIS for ReSTIR DI + GI and unified
// ReSTIR PT; and the equal-sample error gain of unified ReSTIR PT on an imported mesh.
@MainActor func fixSPMISChecks() throws {
  let renderer = testRenderer
  let saved = (renderer.spatialNeighbors, renderer.indirectReuse, renderer.temporalReuse)
  renderer.temporalReuse = .reprojection

  // Plumbing: raw value 3 reaches the shaders; .automatic never resolves to it.
  require(SpatialNeighborSelection.stochasticPairwise.rawValue == 3
      && SpatialNeighborSelection.stochasticPairwise.resolved(importedSceneGraph: false) == .stochasticPairwise
      && SpatialNeighborSelection.stochasticPairwise.resolved(importedSceneGraph: true) == .stochasticPairwise
      && SpatialNeighborSelection.automatic.resolved(importedSceneGraph: true) != .stochasticPairwise
      && SpatialNeighborSelection.automatic.resolved(importedSceneGraph: false) != .stochasticPairwise,
    "stochastic pairwise MIS is an explicit mode (raw value 3); Automatic keeps the earlier selections")
  require(renderer.sceneKernels.spmis != nil, "the scene libraries contain the stochastic pairwise MIS kernels")

  let kernels = """
    kernel void spmis_layout(device uint *out [[buffer(0)]]) {
        out[0] = sizeof(SPMISPixel); out[1] = sizeof(SPMISSlot); out[2] = sizeof(SPMISChoice);
        out[3] = sizeof(SPMISShift); out[4] = SPMIS_PT_CANDIDATES; out[5] = SPMIS_TILE;
    }
    // One synthetic cell of `count` candidates: per candidate (c_i, target of y from domain i,
    // importance). The canonical target is 1 and cc = 2. Per trial: the stochastic canonical
    // weight (Eq. 18, one uniform pixel) and the stochastic sum of the non-canonical weights
    // (Eq. 16 with Ñ = SPMIS_CANDIDATES importance draws), both evaluated at the same y; and
    // the deterministic weights, whose sum must be 1 (Eq. 11).
    kernel void spmis_weights(const device float4 *candidates [[buffer(0)]], const device SPMISSlot *slots [[buffer(1)]],
                              constant uint &count [[buffer(2)]], device float4 *out [[buffer(3)]],
                              uint id [[thread_position_in_grid]]) {
        float M = float(count), scale = float(SPMIS_CANDIDATES) / M, cc = 2.0f, pc = 1.0f;
        float cS = 0.0f;
        for (uint i = 0; i < count; ++i) cS += candidates[i].x * scale;
        float mc = spmis_canonical_share(cS, cc), neighbours = 0.0f;
        for (uint i = 0; i < count; ++i) {
            mc += spmis_canonical_beta(candidates[i].x * scale, cS, cc, candidates[i].y, pc);
            neighbours += spmis_neighbor_weight(candidates[i].x * scale, cS, cc, candidates[i].y, pc);
        }
        SPMISPixel cell;
        cell.cell = 0u | (count << 25); cell.key = 0u; cell.confidence[0] = cS / scale; cell.confidence[1] = cS / scale;
        uint seed = pcg_hash(id * 9781u + 11u);
        uint z = spmis_uniform_pixel(slots, cell, rand_f(seed));
        float mcStochastic = spmis_canonical_share(cS, cc)
            + M * spmis_canonical_beta(candidates[z].x * scale, cS, cc, candidates[z].y, pc);
        float sum = 0.0f;
        for (uint k = 0; k < SPMIS_CANDIDATES; ++k) {
            uint pixel; float p;
            if (!spmis_draw(slots, cell, 0u, rand_f(seed), pixel, p)) continue;
            bool exact = abs(p - candidates[pixel].z / slots[count - 1].cdf[0]) <= 1e-5f;
            sum += spmis_neighbor_weight(candidates[pixel].x * scale, cS, cc, candidates[pixel].y, pc)
                / (float(SPMIS_CANDIDATES) * p) * (exact ? 1.0f : 1e6f);
        }
        out[id] = float4(mcStochastic, sum, mc, neighbours);
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  func run(_ name: String, threads: Int, _ bind: (MTLComputeCommandEncoder) -> Void) throws {
    let state = try gpu.makeComputePipelineState(function: library.makeFunction(name: name)!)
    let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(state)
    bind(encoder)
    encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: min(threads, state.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    require(command.status == .completed, "\(name) completes: \(String(describing: command.error))")
  }
  let layout = gpu.makeBuffer(length: 6 * 4, options: .storageModeShared)!
  try run("spmis_layout", threads: 1) { $0.setBuffer(layout, offset: 0, index: 0) }
  let sizes = (0..<6).map { Int(layout.contents().load(fromByteOffset: $0 * 4, as: UInt32.self)) }
  require(sizes[0] + sizes[1] + sizes[2] == 44 && sizes[3] * (sizes[4] + 1) == PathTracerRenderer.spmisShiftBytesPerPixel
      && sizes[4] == PathTracerRenderer.spmisPTCandidates && sizes[5] == PathTracerRenderer.spmisTile,
    "MSL SPMIS layouts, Ñ and tile size match the Swift allocations: \(sizes)")

  // Synthetic cell: 23 candidates with mixed confidences (one zero), targets and importances
  // (one zero: a pixel without a contributing sample, never drawn).
  var candidates = [SIMD4<Float>]()
  var state: UInt64 = 0x2545F4914F6CDD1D
  func uniform() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float(state >> 40) / Float(1 << 24) }
  for i in 0..<23 {
    let c: Float = i == 4 ? 0 : 1 + 19 * uniform()
    let target: Float = i == 9 ? 0 : 0.05 + 3 * uniform() * uniform()
    let importance: Float = i == 4 || i == 9 ? 0 : c * target * (0.2 + uniform())
    candidates.append(SIMD4(c, target, importance, 0))
  }
  var cdf: Float = 0
  var slotBytes = [UInt8]()
  for (i, c) in candidates.enumerated() {
    cdf += c.z
    withUnsafeBytes(of: UInt32(i)) { slotBytes += $0 }
    withUnsafeBytes(of: cdf) { slotBytes += $0 }
    withUnsafeBytes(of: cdf) { slotBytes += $0 }
  }
  let trials = 1 << 17
  let candidateBuffer = gpu.makeBuffer(bytes: candidates, length: candidates.count * 16, options: .storageModeShared)!
  let slotBuffer = gpu.makeBuffer(bytes: slotBytes, length: slotBytes.count, options: .storageModeShared)!
  let weights = gpu.makeBuffer(length: trials * 16, options: .storageModeShared)!
  var count = UInt32(candidates.count)
  try run("spmis_weights", threads: trials) {
    $0.setBuffer(candidateBuffer, offset: 0, index: 0); $0.setBuffer(slotBuffer, offset: 0, index: 1)
    $0.setBytes(&count, length: 4, index: 2); $0.setBuffer(weights, offset: 0, index: 3)
  }
  let w = (0..<trials).map { weights.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  func meanSE(_ v: [Double]) -> (Double, Double) {
    let m = v.reduce(0, +) / Double(v.count)
    return (m, (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1) / Double(v.count)).squareRoot())
  }
  let (mc, mcSE) = meanSE(w.map { Double($0.x) }), (mn, mnSE) = meanSE(w.map { Double($0.y) })
  let (total, totalSE) = meanSE(w.map { Double($0.x + $0.y) })
  let exactC = Double(w[0].z), exactN = Double(w[0].w)
  print("SPMIS weights: canonical \(mc) ± \(mcSE) (exact \(exactC)), neighbours \(mn) ± \(mnSE) (exact \(exactN)), sum \(total) ± \(totalSE)")
  require(abs(exactC + exactN - 1) < 1e-5, "defensive pairwise MIS weights with Ñ/M-scaled confidences sum to 1 (Eq. 11)")
  require(w.allSatisfy { $0.y < 1e5 }, "spmis_draw reports the exact selection probability I_i / sum I")
  require(abs(mc - exactC) < 5 * mcSE && abs(mn - exactN) < 5 * mnSE && abs(total - 1) < 5 * totalSE,
    "the stochastic canonical and non-canonical weights estimate the deterministic ones without bias (Eqs. 15, 18)")
  require(mnSE > 1e-4 && mcSE > 1e-5, "the stochastic weights vary (the check is not vacuous)")
  print("PASS: fix-spmis layouts, partition of unity and unbiased stochastic MIS weights")

  // Reuse cells on a synthetic 20 x 12 G-buffer (partial tiles at the right and bottom): diffuse
  // and glossy hits, misses, emitters, four normals and two material slots, with DI and GI
  // weights (weight sum, M, W). Checked against a CPU rebuild of Algorithm 1.
  let gw = 20, gh = 12
  let diffuseType: Float = 0, glossyType: Float = 1, emissiveType: Float = 3  // MSL MaterialType
  var positions = [SIMD4<Float>](), normals = [SIMD4<Float>](), di = [SIMD4<Float>](), gi = [SIMD4<Float>]()
  var surfaceWords = [UInt32](repeating: 0, count: gw * gh * 32)
  let normalChoices: [SIMD3<Float>] = [SIMD3(0, 0, 1), SIMD3(0.6, 0, 0.8), SIMD3(-0.6, 0, 0.8), SIMD3(0, 1, 0)]
  for i in 0..<(gw * gh) {
    let kind = Int(uniform() * 10)
    let miss = kind == 0, emitter = kind == 1
    let type: Float = emitter ? emissiveType : kind < 4 ? glossyType : diffuseType
    positions.append(SIMD4(0, 0, 0, miss ? -1 : 1 + uniform()))
    normals.append(SIMD4(normalChoices[Int(uniform() * 4) % 4], miss ? -1 : type))
    surfaceWords[i * 32 + 3] = UInt32(type) | (UInt32(uniform() < 0.3 ? 7 : 2) << 16)
    let W: Float = uniform() < 0.2 ? 0 : 0.5 + uniform()
    di.append(SIMD4(4 * uniform(), 1 + Float(Int(uniform() * 20)), W, 0))
    gi.append(SIMD4(2 * uniform(), 1 + Float(Int(uniform() * 20)), uniform() < 0.5 ? W : 0, 0))
  }
  func gtexture(_ format: MTLPixelFormat, _ values: [SIMD4<Float>]) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: gw, height: gh, mipmapped: false)
    d.usage = [.shaderRead]; d.storageMode = .shared
    let t = gpu.makeTexture(descriptor: d)!
    if format == .rgba16Float {
      let bits = values.flatMap { v in (0..<4).map { Float16(v[$0]).bitPattern } }
      t.replace(region: MTLRegionMake2D(0, 0, gw, gh), mipmapLevel: 0, withBytes: bits, bytesPerRow: gw * 8)
    } else {
      t.replace(region: MTLRegionMake2D(0, 0, gw, gh), mipmapLevel: 0, withBytes: values, bytesPerRow: gw * 16)
    }
    return t
  }
  let tPos = gtexture(.rgba32Float, positions), tNorm = gtexture(.rgba16Float, normals)
  let tDI = gtexture(.rgba32Float, di), tGI = gtexture(.rgba32Float, gi)
  let surfaceBuffer = gpu.makeBuffer(bytes: surfaceWords, length: surfaceWords.count * 4, options: .storageModeShared)!
  let tilesX = (gw + 7) / 8, tilesY = (gh + 7) / 8
  let cellBuffer = gpu.makeBuffer(length: gw * gh * 16, options: .storageModeShared)!
  let slotsBuffer = gpu.makeBuffer(length: tilesX * tilesY * 64 * 12, options: .storageModeShared)!
  let choiceBuffer = gpu.makeBuffer(length: gw * gh * 16, options: .storageModeShared)!
  let placeholderPT = gpu.makeBuffer(length: 64, options: .storageModeShared)!
  var cellUniforms = makeUniforms(scene: 1, mode: 0, width: gw, height: gh)
  cellUniforms.indirectReuse = IndirectReuse.restirGI.rawValue
  let production = renderer.sceneKernels.spmis!
  let command = renderer.commandQueue.makeCommandBuffer()!
  for (pipeline, tiled) in [(production.cells, true), (production.select, false)] {
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    for (index, texture) in [tPos, tNorm, tDI, tGI].enumerated() { encoder.setTexture(texture, index: index) }
    encoder.setBytes(&cellUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.setBuffer(surfaceBuffer, offset: 0, index: 3)
    encoder.setBuffer(placeholderPT, offset: 0, index: 5)
    encoder.setBuffer(cellBuffer, offset: 0, index: 9); encoder.setBuffer(slotsBuffer, offset: 0, index: 10)
    encoder.setBuffer(choiceBuffer, offset: 0, index: 11)
    if tiled {
      encoder.dispatchThreadgroups(MTLSize(width: tilesX, height: tilesY, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    } else {
      encoder.dispatchThreads(MTLSize(width: gw, height: gh, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }
    encoder.endEncoding()
  }
  command.commit(); command.waitUntilCompleted()
  require(command.status == .completed, "reuse-cell kernels complete")
  struct Cell { var cell: UInt32; var key: UInt32; var c0: Float; var c1: Float }
  let cells = (0..<(gw * gh)).map { cellBuffer.contents().load(fromByteOffset: $0 * 16, as: Cell.self) }
  func slot(_ s: Int) -> (pixel: Int, cdf0: Float, cdf1: Float) {
    let p = slotsBuffer.contents() + s * 12
    return (Int(p.load(as: UInt32.self)), p.load(fromByteOffset: 4, as: Float.self), p.load(fromByteOffset: 8, as: Float.self))
  }
  func key(_ i: Int) -> UInt32? {
    guard positions[i].w > 0, normals[i].w != emissiveType else { return nil }
    let n = SIMD3<Float>(Float(Float16(normals[i].x)), Float(Float16(normals[i].y)), Float(Float16(normals[i].z)))
    let q = (0..<3).map { UInt32(max(-2, min(1, Int((n[$0] * 2).rounded(.down)))) + 2) }
    return UInt32(normals[i].w) & 15 | q[0] << 4 | q[1] << 6 | q[2] << 8 | (surfaceWords[i * 32 + 3] >> 16) << 10
  }
  var cellsOK = true, slotsSeen = Set<Int>(), multiPixelCells = 0
  for i in 0..<(gw * gh) {
    let x = i % gw, y = i / gw, tile = (y / 8) * tilesX + x / 8
    guard let k = key(i) else { cellsOK = cellsOK && cells[i].cell == 0; continue }
    let members = (0..<(gw * gh)).filter { j in (j / gw / 8) * tilesX + (j % gw) / 8 == tile && key(j) == k }
    let start = Int(cells[i].cell & ((1 << 25) - 1)), n = Int(cells[i].cell >> 25)
    if members.count > 1 { multiPixelCells += 1 }
    let conf0 = members.reduce(Float(0)) { $0 + (normals[$1].w == diffuseType ? di[$1].y : 0) }
    let conf1 = members.reduce(Float(0)) { $0 + (normals[$1].w == diffuseType ? gi[$1].y : 0) }
    var prefix0: Float = 0, prefix1: Float = 0, listed = true
    for (r, j) in members.enumerated() {
      let s = slot(start + r)
      prefix0 += normals[j].w == diffuseType && di[j].z > 0 ? di[j].x : 0
      prefix1 += normals[j].w == diffuseType && gi[j].z > 0 ? gi[j].x : 0
      listed = listed && s.pixel == j && abs(s.cdf0 - prefix0) <= 1e-4 * max(1, prefix0) && abs(s.cdf1 - prefix1) <= 1e-4 * max(1, prefix1)
      slotsSeen.insert(start + r)
    }
    cellsOK = cellsOK && cells[i].key == k && n == members.count && start / 64 == tile && listed
      && abs(cells[i].c0 - conf0) <= 1e-4 * max(1, conf0) && abs(cells[i].c1 - conf1) <= 1e-4 * max(1, conf1)
  }
  require(cellsOK && multiPixelCells > 20, "each pixel's cell lists its tile's same-key pixels in order, with confidence sums and prefix sums of c p-hat W (Algorithm 1)")
  // The cell search: every choice is the pixel's own cell or a similar one (same type and slot,
  // normals within one quantization step), and some pixels do choose another cell.
  func similar(_ a: UInt32, _ b: UInt32) -> Bool {
    (a & ~0x3f0) == (b & ~0x3f0) && (0..<3).allSatisfy { c in abs(Int((a >> (4 + 2 * c)) & 3) - Int((b >> (4 + 2 * c)) & 3)) <= 1 }
  }
  var searchOK = true, moved = 0
  for i in 0..<(gw * gh) where key(i) != nil {
    let c0 = choiceBuffer.contents().load(fromByteOffset: i * 16, as: UInt32.self)
    let c1 = choiceBuffer.contents().load(fromByteOffset: i * 16 + 4, as: UInt32.self)
    for c in [c0, c1] {
      guard let owner = (0..<(gw * gh)).first(where: { cells[$0].cell == c }) else { searchOK = false; continue }
      searchOK = searchOK && similar(cells[i].key, cells[owner].key)
      if c != cells[i].cell { moved += 1 }
    }
  }
  require(searchOK && moved > 10, "the cell search chooses only the own or similar cells (\(moved) choices moved)")
  print("PASS: fix-spmis reuse cells and cell search on a synthetic G-buffer")

  // Plumbing, memory and release: renderFrame passes the mode; the cells (and, with ReSTIR PT,
  // the larger shift records) exist only in this mode, and the plan matches the resident frame.
  let mw = 256, mh = 192
  let tileSlots = ((mw + 7) / 8) * ((mh + 7) / 8) * 64
  for reuse in [IndirectReuse.restirGI, .restirPT, .restirPTUnified] {
    renderer.indirectReuse = reuse
    renderer.spatialNeighbors = .uniform
    let before = render(makeUniforms(scene: 1, mode: 0, width: 64, height: 48), samples: 3)
    require(renderer.spmisCells == nil && renderer.spmisSlots == nil && renderer.spmisChoices == nil,
      "\(reuse): other selections allocate no reuse cells")
    renderer.spatialNeighbors = .stochasticPairwise
    _ = render(makeUniforms(scene: 1, mode: 0, width: mw, height: mh), samples: 1)
    require(lastRenderUniforms?.spatialNeighbors == 3, "\(reuse): renderFrame writes spatialNeighbors = 3")
    let pt = reuse != .restirGI
    require(renderer.spmisCells?.length == mw * mh * 16 && renderer.spmisChoices?.length == mw * mh * 16
        && renderer.spmisSlots?.length == tileSlots * 12
        && (renderer.ptShifts?.length ?? 0) == (pt ? mw * mh * PathTracerRenderer.spmisShiftBytesPerPixel : 0),
      "\(reuse): stochastic pairwise MIS allocates its cells, choices, slots and shift records")
    let plan = PathTracerRenderer.FrameResourcePlan(width: mw, height: mh, usesReSTIR: true, usesMetalFX: false,
      indirectReuse: reuse, splatting: false, stochasticPairwise: true)
    let resident = Double(renderer.residentFrameBytes), planned = Double(plan.bytes!)
    print("\(reuse) with stochastic pairwise MIS: resident frame \(Int(resident)) B, plan \(Int(planned)) B")
    require(resident >= 0.95 * planned && resident <= 1.1 * planned, "\(reuse): the SPMIS resource plan matches the resident frame")
    require(renderer.renderMemoryError(width: mw, height: mh, spatialNeighbors: .uniform) == nil,
      "\(reuse): a spatial-mode switch at a small size fits the budget")
    // Fallback: switching back releases the cells and renders exactly as before.
    renderer.spatialNeighbors = .uniform
    let after = render(makeUniforms(scene: 1, mode: 0, width: 64, height: 48), samples: 3)
    require(renderer.spmisCells == nil && renderer.spmisChoices == nil && before == after,
      "\(reuse): the uniform selection releases the cells and renders identically after SPMIS frames")
  }
  require(PathTracerRenderer.FrameResourcePlan.spmisBytesPerPixel(.restirGI) == 44
      && PathTracerRenderer.FrameResourcePlan.spmisBytesPerPixel(.restirPTUnified) == 44 + 48
      && PathTracerRenderer.FrameResourcePlan.spmisBytesPerPixel(.restirPT) == 44 + 48,
    "stochastic pairwise MIS bytes per pixel per mode")
  print("PASS: fix-spmis plumbing, memory plan, release and fallback equivalence")

  // Spatial-only mean radiance against MIS: every frame starts without reservoir history, so
  // spatial reuse is the only reuse and its bias is not masked by the temporal pass. Frames are
  // averaged here. SPMIS (DI + GI with ReSTIR GI, unified ReSTIR PT) must agree with MIS; the
  // uniform selection's M / sum-M normalization, measured for contrast, is biased upward.
  func spatialOnly(_ view: Uniforms, frames: Int) -> [SIMD4<Float>] {
    var sum = [SIMD4<Float>](repeating: .zero, count: Int(view.width * view.height))
    applyTestView(view)
    renderer.denoiserEnabled = false
    var completed = 0, failure: String?
    let savedUpdate = renderer.onFrameUpdate, savedError = renderer.onError
    renderer.onFrameUpdate = { _ in completed += 1 }
    renderer.onError = { failure = $0 }
    let output = renderOutputs[SIMD2(Int(view.width), Int(view.height))] ?? {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(view.width), height: Int(view.height), mipmapped: false)
      d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
      return gpu.makeTexture(descriptor: d)!
    }()
    renderOutputs[SIMD2(Int(view.width), Int(view.height))] = output
    renderer.restartSampleSequence(at: 3000)
    for _ in 0..<frames {
      renderer.resetAccumulation()
      let target = completed + 1
      renderer.renderFrame(output: output)
      let deadline = Date().addingTimeInterval(60)
      while completed < target && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
      require(failure == nil && completed >= target, "spatial-only frame completes: \(failure ?? "timeout")")
      require(renderer.lastUniforms?.reservoirHistory == 1, "spatial-only frames have no temporal history")
      let frame = readTexture(renderer.accumTexture!)
      for i in sum.indices { sum[i] += frame[i] }
    }
    renderer.onFrameUpdate = savedUpdate; renderer.onError = savedError
    return sum.map { $0 / Float(frames) }
  }
  let bw = 160, bh = 120
  var cornell = makeUniforms(scene: 1, mode: 1, width: bw, height: bh)
  let cornellReference = render(cornell, samples: 1024)
  cornell.samplingMode = 0
  for (reuse, spatial) in [(IndirectReuse.restirGI, SpatialNeighborSelection.uniform), (.restirGI, .stochasticPairwise),
                           (.restirPTUnified, .stochasticPairwise)] {
    renderer.indirectReuse = reuse; renderer.spatialNeighbors = spatial
    let image = spatialOnly(cornell, frames: 256)
    let d = pairedDifference(image, cornellReference, width: bw, pixels: Array(0..<image.count), block: 8)
    print("Cornell spatial-only \(reuse) \(spatial) - MIS: \(d.mean / d.reference) ± \(d.se / d.reference) (relative)")
    if spatial == .uniform {
      require(d.mean > 10 * d.se && d.mean > 0.01 * d.reference, "the uniform M / sum-M spatial normalization is measurably biased")
    } else {
      require(abs(d.mean) < 4 * d.se + 0.001 * d.reference, "Cornell: spatial-only \(reuse) with SPMIS agrees with MIS")
    }
  }
  print("PASS: fix-spmis spatial-only mean radiance agrees with MIS (ReSTIR DI + GI and unified ReSTIR PT)")

  // Equal-sample error of unified ReSTIR PT on an imported mesh (a UV sphere on a floor),
  // SPMIS against the paired reuse, over three orbit views with their own MIS references.
  var obj = "v -3 -1 -3\nv 3 -1 -3\nv 3 -1 3\nv -3 -1 3\nf 1 4 3 2\n"
  let rings = 32, segments = 32
  for i in 0...rings { for j in 0..<segments {
    let theta = Float.pi * Float(i) / Float(rings), phi = 2 * Float.pi * Float(j) / Float(segments)
    obj += "v \(0.6 * sin(theta) * cos(phi)) \(-0.4 + 0.6 * cos(theta)) \(0.6 * sin(theta) * sin(phi))\n"
  }}
  for i in 0..<rings { for j in 0..<segments {
    let a = 5 + i * segments + j, b = 5 + i * segments + (j + 1) % segments
    obj += "f \(a) \(b) \(b + segments) \(a + segments)\n"
  }}
  let savedSettings = renderer.materials.settings
  renderer.materials.settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
  try renderer.materials.setMesh(try OBJMesh.load(obj))
  renderer.materials.hasSceneGraph = false
  renderer.indirectReuse = .restirPTUnified
  var meshView = makeUniforms(scene: 6, mode: 1, width: bw, height: bh)
  meshView.environment.w = Float(renderer.materials.nodeCount)
  let orbitTarget = SIMD3<Float>(meshView.cameraTarget.x, meshView.cameraTarget.y, meshView.cameraTarget.z)
  let orbitOffset = SIMD3<Float>(meshView.cameraPos.x, meshView.cameraPos.y, meshView.cameraPos.z) - orbitTarget
  func mse(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
    zip(a, b).reduce(0.0) { let d = $1.0 - $1.1; return $0 + Double(d.x * d.x + d.y * d.y + d.z * d.z) / 3 } / Double(a.count)
  }
  var ratios = [Double]()
  for trial in 0..<3 {
    let angle = Float(trial) * 0.5 - 0.5
    var view = meshView
    view.cameraPos = SIMD4(orbitTarget + SIMD3(orbitOffset.x * cos(angle) + orbitOffset.z * sin(angle), orbitOffset.y,
                                               -orbitOffset.x * sin(angle) + orbitOffset.z * cos(angle)), meshView.cameraPos.w)
    view.samplingMode = 1
    let reference = render(view, samples: 1024)
    view.samplingMode = 0
    renderer.spatialNeighbors = .uniform
    let paired = mse(render(view, samples: 16), reference)
    renderer.spatialNeighbors = .stochasticPairwise
    let stochastic = mse(render(view, samples: 16), reference)
    ratios.append(stochastic / paired)
    print("Imported mesh view \(trial), unified ReSTIR PT 16-frame MSE: paired \(paired), stochastic pairwise MIS \(stochastic)")
  }
  let meanRatio = ratios.reduce(0, +) / Double(ratios.count)
  require(ratios.allSatisfy { $0 < 0.95 } && meanRatio < 0.85,
    "stochastic pairwise MIS lowers unified ReSTIR PT's equal-sample MSE on the imported mesh by more than 15% (mean ratio \(meanRatio))")
  try renderer.materials.setMesh([])
  renderer.materials.settings = savedSettings
  print("PASS: fix-spmis equal-sample error gain of unified ReSTIR PT on an imported mesh")
  (renderer.spatialNeighbors, renderer.indirectReuse, renderer.temporalReuse) = saved
}
try fixSPMISChecks()
