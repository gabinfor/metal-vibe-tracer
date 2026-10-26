// The optional indirect clamp (StudioOptions.indirectClamp, MSL path_add / indirect_clamped): off renders exactly
// as before, direct lighting is never clamped, a cap far above every sample changes only the order of additions,
// and a low cap lowers the mean and the brightest pixels (fireflies) of indirect light, in the path loop and in
// volume_path.
@MainActor func fixClampChecks() throws {
  let r = testRenderer
  let saved = (r.options.indirectClamp, r.lightTransport, r.medium)
  defer { (r.options.indirectClamp, r.lightTransport, r.medium) = saved }
  // The test view keeps the renderer's clamp (applyTestView).
  func image(_ view: Uniforms, clamp: Float?, samples: Int = 64) -> [SIMD4<Float>] {
    r.options.indirectClamp = clamp
    return render(view, samples: samples)
  }
  func mean(_ p: [SIMD4<Float>]) -> Double { p.reduce(0.0) { $0 + Double($1.x + $1.y + $1.z) } / Double(3 * p.count) }
  func peak(_ p: [SIMD4<Float>]) -> Float { p.map { max($0.x, $0.y, $0.z) }.max() ?? 0 }
  for transport in [LightTransport.rgb, .spectral] {
    r.lightTransport = transport
    let label = transport == .rgb ? "RGB" : "spectral"
    // Cornell glass and mirror, Standard MIS: caustics and glossy interreflections give fireflies.
    let view = makeUniforms(scene: 3, mode: 1, width: 64, height: 64)
    let off = image(view, clamp: nil), zero = image(view, clamp: 0)
    require(off == zero, "\(label): a clamp of 0 is off and renders bit-identically")
    var direct = view; direct.cameraTarget.w = 1
    require(image(direct, clamp: nil) == image(direct, clamp: 0.01), "\(label): direct lighting (depth 1) is never clamped")
    let huge = image(view, clamp: 1e5)
    let worst = zip(off, huge).map { abs($0.0.x - $0.1.x) + abs($0.0.y - $0.1.y) + abs($0.0.z - $0.1.z) }.max() ?? 0
    require(worst < 1e-4 * max(1, peak(off)), "\(label): a cap above every sample changes only rounding (\(worst))")
    let low = image(view, clamp: 0.2)
    // The visible light (radiance 24) is direct and stays; elsewhere the brightest pixels are indirect fireflies.
    func lum(_ v: SIMD4<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
    let lit = off.indices.filter { lum(off[$0]) < 10 }
    let peakOff = lit.map { lum(off[$0]) }.max() ?? 0, peakLow = lit.map { lum(low[$0]) }.max() ?? 0
    let brighter = off.indices.map { lum(low[$0]) - lum(off[$0]) }.max() ?? 0
    print("\(label) indirect clamp, Cornell glass: mean \(mean(off)) -> \(mean(low)), brightest non-light pixel \(peakOff) -> \(peakLow)")
    require(mean(low) < mean(off) && mean(low) > 0.5 * mean(off) && peakLow < peakOff && brighter < 1e-4,
      "\(label): a low cap lowers the indirect mean and the brightest indirect pixels, and brightens none (\(brighter))")
  }
  // volume_path: haze in the Cornell box (scene medium) renders identically with the clamp off, and a low cap
  // lowers its multiply scattered light without brightening any pixel.
  r.lightTransport = .spectral
  r.medium = SceneMedium(density: 1.5, albedo: SIMD3(repeating: 0.95), anisotropy: 0.3, rayleigh: false)
  let hazy = makeUniforms(scene: 3, mode: 1, width: 48, height: 48)
  let hazeOff = image(hazy, clamp: nil), hazeZero = image(hazy, clamp: 0), hazeLow = image(hazy, clamp: 0.05)
  require(hazeOff == hazeZero, "volume_path: a clamp of 0 renders bit-identically")
  let hazeBrighter = zip(hazeLow, hazeOff).map { (0.2126 * ($0.0.x - $0.1.x) + 0.7152 * ($0.0.y - $0.1.y) + 0.0722 * ($0.0.z - $0.1.z)) }.max() ?? 0
  print("volume_path indirect clamp: mean \(mean(hazeOff)) -> \(mean(hazeLow))")
  require(mean(hazeLow) < mean(hazeOff) && hazeBrighter < 1e-4, "volume_path: a low cap lowers multiply scattered light and brightens no pixel")
  print("PASS: indirect clamp off, direct-only, cap above all samples and low cap (RGB, spectral and volume_path)")
}
try fixClampChecks()
