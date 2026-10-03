// Z++ sampler block artifacts (REFERENCES.md ZPP2026, "Adaptations": key layout). Before the fix, a
// pixel's key was its shuffled Morton index XOR the frame, so over 4^k frames every pixel of an
// aligned 2^k x 2^k block drew exactly the same samples in every dimension, and a still
// accumulation showed tinted square tiles. Checks: per-pixel estimates of neighbouring pixels are
// uncorrelated over 4, 16 and 64 frames in 1D, 2D and 3D constituents, and across dimensions; the
// 2 x 2 per-frame stratification holds in every frame; and a rendered still accumulation of the
// Pavilion (ReSTIR GI, the default transport) carries no more error energy at 2-8 pixel scales or
// correlation between adjacent pixels than independent PCG streams.
@MainActor func fixZSamplerBlockChecks() throws {
  let renderer = testRenderer
  let saved = (renderer.sampler, renderer.zTemporal, renderer.indirectReuse, renderer.spatialNeighbors,
               renderer.temporalReuse, renderer.controlVariates)
  defer {
    (renderer.sampler, renderer.zTemporal, renderer.indirectReuse, renderer.spatialNeighbors,
     renderer.temporalReuse, renderer.controlVariates) = saved
  }
  let kernels = """
    // One frame of a still accumulation: per-pixel running means of step functions of a 1D, a 2D
    // and a 3D constituent and of a second 1D dimension (buffer 1), and the frame's raw 1D and 2D
    // draws (buffer 2).
    kernel void zb_accumulate(constant Uniforms &u [[buffer(0)]], device float4 *means [[buffer(1)]],
                              device float4 *draws [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.width || gid.y >= u.height) return;
        Sampler s = pixel_sampler(gid, u);
        sampler_event(s, 1u, Z_BSDF);
        float a = rand_f(s); float2 b = rand_f2(s); float3 c = rand_f3(s); float d = rand_f(s);
        float4 v = float4(a < 0.3f ? 1.0f : 0.0f, b.x + b.y < 0.8f ? 1.0f : 0.0f,
                          c.x * c.y > 0.5f * c.z ? 1.0f : 0.0f, d < 0.3f ? 1.0f : 0.0f);
        uint i = gid.y * u.width + gid.x;
        means[i] = (u.frameIndex == 1u ? 0.0f : means[i]) + (v - (u.frameIndex == 1u ? 0.0f : means[i])) / float(u.frameIndex);
        draws[i] = float4(a, b, 0.0f);
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernels, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "zb_accumulate")!)
  let side = 128
  let means = gpu.makeBuffer(length: side * side * 16, options: .storageModeShared)!
  let draws = gpu.makeBuffer(length: side * side * 16, options: .storageModeShared)!
  func load(_ b: MTLBuffer) -> [SIMD4<Float>] { (0..<(side * side)).map { b.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) } }
  func fixed(_ v: Float) -> UInt32 { UInt32(v * 16_777_216) << 8 }

  // Sampler level: correlation of per-pixel estimates at pixel offsets, over 8 accumulations.
  var stratified = true
  for frames in [4, 16, 64] {
    var sums = [String: SIMD3<Double>]()
    for trial in 0..<8 {
      var u = makeUniforms(scene: 1, mode: 1, width: side, height: side)
      u.indirectReuse = 64 | (ZTemporal.reshuffled.rawValue << 7)
      let start = UInt32(trial) * 100_003 + 17
      for j in 0..<frames {
        u.sampleIndex = start + UInt32(j); u.frameIndex = UInt32(j) + 1
        let command = renderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setBuffer(means, offset: 0, index: 1); encoder.setBuffer(draws, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: side, height: side, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        require(command.status == .completed, "zb_accumulate completes")
        // Every frame (not only the first) stratifies each aligned 2 x 2 block: one 1D draw per
        // quarter and a (0, 2, 2)-net of the 2D draws.
        if frames == 16 && trial == 0 {
          let v = load(draws)
          for by in stride(from: 0, to: side, by: 2) { for bx in stride(from: 0, to: side, by: 2) {
            var quarters = Set<UInt32>(), cells = [Set<UInt32>(), Set<UInt32>(), Set<UInt32>()]
            for y in by..<(by + 2) { for x in bx..<(bx + 2) {
              let p = v[y * side + x], qx = fixed(p.y), qy = fixed(p.z)
              quarters.insert(fixed(p.x) >> 30)
              cells[0].insert(qx >> 30); cells[1].insert(((qx >> 31) << 1) | (qy >> 31)); cells[2].insert(qy >> 30)
            }}
            stratified = stratified && quarters.count == 4 && cells.allSatisfy { $0.count == 4 }
          }}
        }
      }
      let v = load(means)
      for component in 0..<4 {
        let m = v.map { Double($0[component]) }.reduce(0, +) / Double(v.count)
        let other = 3 - component
        let om = v.map { Double($0[other]) }.reduce(0, +) / Double(v.count)
        for (label, dx, dy, c2) in [("(1,0)", 1, 0, component), ("(0,1)", 0, 1, component), ("(1,1)", 1, 1, component),
                                    ("(2,0)", 2, 0, component), ("(4,0)", 4, 0, component), ("(0,2)", 0, 2, component),
                                    ("dimension (0,0)", 0, 0, other), ("dimension (1,0)", 1, 0, other)] {
          let mean2 = c2 == component ? m : om
          var s = SIMD3<Double>(0, 0, 0)
          for y in 0..<(side - dy) { for x in 0..<(side - dx) {
            let a = Double(v[y * side + x][component]) - m, b = Double(v[(y + dy) * side + x + dx][c2]) - mean2
            s += SIMD3(a * b, a * a, b * b)
          }}
          sums["\(component) \(label)", default: .zero] += s
        }
      }
    }
    var worst = (0.0, ""), worstCross = (0.0, "")
    for (key, s) in sums {
      let r = s.x / (s.y * s.z).squareRoot()
      if key.contains("dimension") { if abs(r) > abs(worstCross.0) { worstCross = (r, key) } }
      else if r > worst.0 { worst = (r, key) }
    }
    print("Z sampler, \(frames) frames: largest neighbour correlation of per-pixel estimates \(worst.0) (\(worst.1)), across dimensions \(worstCross.0) (\(worstCross.1))")
    // Before the fix, siblings shared their sample sets: 0.44-0.47 at (1, 0) after 4 frames, 0.86-0.88 after 64.
    require(worst.0 < 0.2, "Z sampler, \(frames) frames: neighbouring pixels accumulate different samples (no block correlation)")
    require(abs(worstCross.0) < 0.05, "Z sampler, \(frames) frames: dimensions of a pixel and of its neighbour are decorrelated")
  }
  require(stratified, "Z sampler: every frame of an accumulation stratifies aligned 2 x 2 pixel blocks (1D quarters, 2D (0, 2, 2)-nets)")
  print("PASS: fix-zsampler-blocks neighbouring pixels draw decorrelated samples over an accumulation")

  // Render level: the difference of two independent still accumulations (the reference and ReSTIR
  // GI's bias cancel) at the user's view, Pavilion with default settings, 16 frames.
  let w = 192, h = 144
  let view = makeUniforms(scene: 0, mode: 0, width: w, height: h)
  renderer.indirectReuse = .restirGI; renderer.spatialNeighbors = .automatic; renderer.temporalReuse = .reprojection
  renderer.controlVariates = .automatic; renderer.zTemporal = .reshuffled
  let output = renderOutputs[SIMD2(w, h)] ?? {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
    return gpu.makeTexture(descriptor: d)!
  }()
  renderOutputs[SIMD2(w, h)] = output
  func accumulate(at start: UInt32, frames: Int) -> [SIMD4<Float>] {
    var drained = false
    DispatchQueue.main.async { drained = true }
    while !drained { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    applyTestView(view); renderer.denoiserEnabled = false
    renderer.resetAccumulation(); renderer.restartSampleSequence(at: start)
    let savedUpdate = renderer.onFrameUpdate
    var completed = 0
    renderer.onFrameUpdate = { _ in completed += 1 }
    for frame in 1...frames {
      renderer.renderFrame(output: output)
      let deadline = Date().addingTimeInterval(60)
      while completed < frame && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
      require(completed >= frame, "block-check accumulation completes frame \(frame)")
    }
    renderer.onFrameUpdate = savedUpdate
    return readTexture(renderer.accumTexture!)
  }
  // Tone-mapped luma and red-green chroma of a - b.
  func difference(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> [[Double]] {
    var luma = [Double](), chroma = [Double]()
    for i in a.indices {
      let p = simd_max(a[i], .zero), q = simd_max(b[i], .zero), d = p / (p + 1) - q / (q + 1)
      luma.append(Double(0.2126 * d.x + 0.7152 * d.y + 0.0722 * d.z)); chroma.append(Double(d.x - d.y))
    }
    return [luma, chroma]
  }
  // b^2 E[(b x b block mean)^2] / E[e^2] over aligned blocks: 1 for white noise, up to b^2 for block-correlated error.
  func blockExcess(_ e: [Double], _ b: Int) -> Double {
    let total = e.map { $0 * $0 }.reduce(0, +) / Double(e.count)
    var s = 0.0, n = 0
    for by in stride(from: 0, to: h - b + 1, by: b) { for bx in stride(from: 0, to: w - b + 1, by: b) {
      var m = 0.0
      for y in by..<(by + b) { for x in bx..<(bx + b) { m += e[y * w + x] } }
      m /= Double(b * b); s += m * m; n += 1
    }}
    return Double(b * b) * s / Double(n) / total
  }
  func adjacentCorrelation(_ e: [Double]) -> Double {
    var s = 0.0, t = 0.0
    for y in 0..<(h - 1) { for x in 0..<(w - 1) { let v = e[y * w + x]; s += v * (e[y * w + x + 1] + e[(y + 1) * w + x]) / 2; t += v * v } }
    return s / t
  }
  var stats = [SamplerMode: [Double]]()
  for mode in [SamplerMode.pcg, .zSampling] {
    renderer.sampler = mode
    var sum = [Double](repeating: 0, count: 8)
    for pair in 0..<3 {
      let channels = difference(accumulate(at: UInt32(pair) * 20_011 + 101, frames: 16), accumulate(at: UInt32(pair) * 20_011 + 7_919, frames: 16))
      for (c, e) in channels.enumerated() {
        sum[4 * c] += blockExcess(e, 2) / 3; sum[4 * c + 1] += blockExcess(e, 4) / 3
        sum[4 * c + 2] += blockExcess(e, 8) / 3; sum[4 * c + 3] += adjacentCorrelation(e) / 3
      }
    }
    stats[mode] = sum
  }
  let p = stats[.pcg]!, z = stats[.zSampling]!
  print("Pavilion ReSTIR GI, 16 frames, PCG / Z: luma block excess 2/4/8 px \(p[0...2]) / \(z[0...2]), adjacent correlation \(p[3]) / \(z[3]); chroma \(p[4...6]) / \(z[4...6]), \(p[7]) / \(z[7])")
  for c in 0..<2 {
    for k in 0..<3 { require(z[4 * c + k] < 1.15 * p[4 * c + k], "Z sampler: no excess \(c == 0 ? "luma" : "chroma") error energy at \(2 << k)-pixel block scale against PCG") }
    require(z[4 * c + 3] < p[4 * c + 3] + 0.05, "Z sampler: \(c == 0 ? "luma" : "chroma") errors of adjacent pixels are no more correlated than with PCG")
  }
  print("PASS: fix-zsampler-blocks still accumulations show no block-correlated error")
}
try fixZSamplerBlockChecks()
