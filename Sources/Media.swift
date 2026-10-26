import Foundation
import simd

// A homogeneous medium filling the scene (docs/VOLUME_DESIGN.md §4; REFERENCES.md BUCHOLTZ1995, HG1941):
// extinction density per metre (at 550 nm with the Rayleigh law), single-scattering albedo, Henyey-Greenstein
// anisotropy, and whether scattering follows the Rayleigh lambda^-4 law. Uniforms.mediumScatter / pathOptions.
struct SceneMedium: Codable, Equatable, Sendable {
  var density: Float = 0.05
  var albedo = SIMD3<Float>(repeating: 0.9)
  var anisotropy: Float = 0
  var rayleigh = false
  static let densityRange: ClosedRange<Float> = 0...100
  var isValid: Bool {
    Self.densityRange.contains(density) && (0..<3).allSatisfy { albedo[$0].isFinite && (0...1).contains(albedo[$0]) }
      && (-0.99...0.99).contains(anisotropy)
  }
}

extension PathTracerRenderer {
  // Whether the frame has participating media: the scene medium, or an imported slot's interior medium.
  var hasMedia: Bool {
    (medium?.density ?? 0) > 0 || (sceneIndex == 6 && materials.materialX.values.contains { $0.medium != nil })
  }
  // The strategy the frame runs: media render with Standard MIS (MSL volume_path), never ReSTIR.
  var activeSamplingMode: UInt32 { hasMedia && samplingMode == 0 ? 1 : samplingMode }
  // Uniforms.mediumScatter (albedo, density) and pathOptions (anisotropy, Rayleigh, media present, indirect clamp).
  var mediumUniforms: (scatter: SIMD4<Float>, options: SIMD4<Float>) {
    let m = medium ?? SceneMedium(density: 0)
    let present: Float = hasMedia ? 1 : 0
    return (SIMD4(m.albedo, m.density), SIMD4(m.anisotropy, m.rayleigh ? 1 : 0, present, max(0, options.indirectClamp ?? 0)))
  }
}
