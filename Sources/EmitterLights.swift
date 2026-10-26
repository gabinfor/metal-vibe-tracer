import Foundation
import simd

// Per-emitter spectra and spot shaping (docs/VOLUME_DESIGN.md §2-3). REFERENCES.md: PLANCK, CIEDATA, OPENUSD
// (UsdLux ShapingAPI). An imported light's material slot carries an EmitterLight; the slot's emission (linear
// RGB radiance) is its tint times intensity, as before.
struct EmitterLight: Codable, Equatable, Sendable {
  enum Spectrum: Codable, Equatable, Sendable {
    // The scene's light preset (StudioOptions.lightSpectrum), as for every emitter before per-light spectra.
    case inherit
    // An Illuminant preset (raw value).
    case preset(UInt32)
    // Planck's law at this temperature in kelvin.
    case blackbody(kelvin: Float)
    // A Gaussian band: centre and full width at half maximum in nanometres.
    case narrowband(center: Float, fwhm: Float)
  }
  var spectrum: Spectrum = .inherit
  // UsdLux ShapingAPI: the cone's angle off the light's axis in degrees (nil: no cone), its softness and the focus
  // exponent. The axis is the emitting face's normal (rectangle and disk lights).
  var coneAngle: Float?
  var coneSoftness: Float = 0
  var focus: Float = 0

  static let temperatureRange: ClosedRange<Float> = 500...40000
  static let wavelengthRange: ClosedRange<Float> = 360...830
  static let fwhmRange: ClosedRange<Float> = 0.5...200

  var isDefault: Bool { self == EmitterLight() }
  var isValid: Bool {
    switch spectrum {
    case .inherit: break
    case .preset(let k): guard Illuminant(rawValue: k) != nil else { return false }
    case .blackbody(let t): guard Self.temperatureRange.contains(t) else { return false }
    case .narrowband(let c, let w): guard Self.wavelengthRange.contains(c), Self.fwhmRange.contains(w) else { return false }
    }
    if let a = coneAngle, !(a.isFinite && a >= 0 && a <= 180) { return false }
    return coneSoftness.isFinite && coneSoftness >= 0 && focus.isFinite && focus >= 0
  }

  // Relative spectral power at `nm` before normalisation (presets have no analytic form and return nil).
  func shape(_ nm: Double) -> Double? {
    switch spectrum {
    case .inherit, .preset: return nil
    case .blackbody(let t): return EmitterLight.planck(nm, kelvin: Double(t))
    case .narrowband(let c, let w):
      let sigma = Double(w) / 2.354820045, x = (nm - Double(c)) / sigma
      return exp(-0.5 * x * x)
    }
  }
  // PLANCK: spectral radiance B(lambda, T) up to the constant c1, with lambda in micrometres and the exact SI
  // second radiation constant c2 = hc/k = 14387.76877 um K. MSL emitter_shape_value evaluates the same form.
  static func planck(_ nm: Double, kelvin t: Double) -> Double {
    let um = nm / 1000
    return 1 / (pow(um, 5) * (exp(14387.76877 / (um * t)) - 1))
  }

  // The GPU record, MaterialLibrary.slotParameters 3-5 (MSL slot_emitter, emitter_shaping):
  // [3] kind (0 inherit, 1 preset, 2 blackbody, 3 narrow band), parameter a, parameter b, 1 / luminance;
  // [4] linear sRGB of the normalised spectrum (RGB transport's colour; white for inherit and presets);
  // [5] cone angle and smooth start in radians, focus, 1 when shaped.
  func slotParameters(observer: CIEObserver?) -> [SIMD4<Float>] {
    var record = SIMD4<Float>(0, 0, 0, 1), rgb = SIMD4<Float>(1, 1, 1, 0)
    switch spectrum {
    case .inherit: break
    case .preset(let k): record = SIMD4(1, Float(k), 0, 1)
    case .blackbody(let t): record = SIMD4(2, t, 0, 1)
    case .narrowband(let c, let w): record = SIMD4(3, c, w, 1)
    }
    if let observer, let colour = observer.normalised({ self.shape($0) }) {
      record.w = Float(colour.scale)
      rgb = SIMD4(SIMD3<Float>(colour.rgb), 0)
    }
    var shaping = SIMD4<Float>(0, 0, 0, 0)
    if let a = coneAngle, a < 90 || focus > 0 {
      let cut = min(a, 90) * .pi / 180
      // ShapingAPI: theta_smoothStart = lerp(softness, theta_cutoff, 0); softness is clamped to [0, 1].
      shaping = SIMD4(cut, cut * (1 - min(1, coneSoftness)), focus, 1)
    } else if focus > 0 {
      shaping = SIMD4(.pi / 2, .pi / 2, focus, 1)
    }
    return [record, rgb, shaping]
  }
  // The fraction of a one-sided emitter's power inside its cone, sin^2 of the angle (the middle of the soft
  // edge), which scales its light-selection weight (MaterialLibrary emitter list) so that a narrow beam is
  // not chosen in proportion to its radiance. Both MIS strategies read the same weights.
  var selectionScale: Double {
    guard let a = coneAngle, a < 90 else { return 1 }
    let angle = Double(a) * (1 - 0.5 * Double(min(1, coneSoftness))) * .pi / 180
    return max(1e-6, pow(sin(angle), 2))
  }
  static let noSlotParameters: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1), SIMD4(1, 1, 1, 0), SIMD4(0, 0, 0, 0)]
}

// CIE 1931 2-degree colour-matching functions at 1 nm, 360-830 nm (REFERENCES.md CIEDATA): the vendored CSV,
// bundled by build.sh. The host uses them for per-light spectra's luminance normalisation and RGB colour.
struct CIEObserver: Sendable {
  let cmf: [SIMD3<Double>]   // x, y, z at 360 + i nm
  // MSL VIBE_XYZ_TO_LINEAR_SRGB (SpectralTables.metal), rows of the matrix.
  static let xyzToLinearSRGB = simd_double3x3(rows: [
    SIMD3(3.24044625, -1.53713476, -0.498530193),
    SIMD3(-0.969266606, 1.87601196, 0.0415560422),
    SIMD3(0.0556435036, -0.20402618, 1.05722657),
  ])
  static let shared: CIEObserver? = {
    guard let url = runtimeResourceURL(bundled: Bundle.main.resourceURL?.appendingPathComponent("CIE_xyz_1931_2deg.csv"),
                                       repositoryPath: "Vendor/Spectral/CIE/CIE_xyz_1931_2deg.csv"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    return CIEObserver(csv: text)
  }()
  init?(csv: String) {
    var rows: [SIMD3<Double>] = []
    for (i, line) in csv.split(whereSeparator: \.isNewline).enumerated() {
      let fields = line.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
      guard fields.count == 4, fields[0] == Double(360 + i) else { return nil }
      rows.append(SIMD3(fields[1], fields[2], fields[3]))
    }
    guard rows.count == 471 else { return nil }
    cmf = rows
  }
  // A spectrum's normalisation to luminance Y = sum S ybar = 1 (as the presets) and its linear sRGB at that
  // luminance; nil for spectra without an analytic shape or with no luminance.
  func normalised(_ shape: (Double) -> Double?) -> (scale: Double, rgb: SIMD3<Double>)? {
    var xyz = SIMD3<Double>(0, 0, 0)
    for (i, c) in cmf.enumerated() {
      guard let s = shape(Double(360 + i)) else { return nil }
      xyz += s * c
    }
    guard xyz.y > 0, xyz.y.isFinite else { return nil }
    return (1 / xyz.y, Self.xyzToLinearSRGB * (xyz / xyz.y))
  }
}

// The Materials page's controls for an imported light's spectrum and spot cone (StudioController.materialPanel).
extension StudioController {
  static let emitterSpectrumTitles = ["Scene light spectrum"] + illuminantTitles.dropFirst() + ["Blackbody", "Narrow band (laser)"]
  func emitterLightControls(_ slot: Int) {
    let light = renderer.materials.emitterLights[slot] ?? EmitterLight()
    func update(rebuilds: Bool = false, _ change: (inout EmitterLight) -> Void) {
      var edited = renderer.materials.emitterLights[slot] ?? EmitterLight()
      change(&edited)
      renderer.materials.emitterLights[slot] = edited.isDefault ? nil : edited
      if rebuilds { rebuild() }
    }
    let presets = Self.illuminantTitles.count - 1
    let selected: Int
    switch light.spectrum {
    case .inherit: selected = 0
    case .preset(let k): selected = 1 + Int(k)
    case .blackbody: selected = 1 + presets
    case .narrowband: selected = 2 + presets
    }
    heading("Light spectrum")
    popup(Self.emitterSpectrumTitles, selected, label: "Spectrum") { [weak self] i in
      guard let self else { return }
      self.checkpoint("Light spectrum")
      update(rebuilds: true) { e in
        e.spectrum = i == 0 ? .inherit : i <= presets ? .preset(UInt32(i - 1))
          : i == 1 + presets ? .blackbody(kelvin: 2700) : .narrowband(center: 532, fwhm: 2)
      }
      self.changed()
    }
    switch light.spectrum {
    case .blackbody(let t):
      number("Temperature (K)", t, 1000...12000, 2700, entry: EmitterLight.temperatureRange) { v in
        update { $0.spectrum = .blackbody(kelvin: v) }
      }
    case .narrowband(let c, let w):
      number("Centre (nm)", c, 380...780, 532, entry: EmitterLight.wavelengthRange) { v in
        update { $0.spectrum = .narrowband(center: v, fwhm: w) }
      }
      number("Width, FWHM (nm)", w, 1...50, 2, entry: EmitterLight.fwhmRange) { v in
        update { $0.spectrum = .narrowband(center: c, fwhm: v) }
      }
    default: break
    }
    heading("Spot cone")
    number("Cone angle (°)", light.coneAngle ?? 90, 0.5...90, 90) { v in
      update { $0.coneAngle = v >= 90 ? nil : v }
    }
    number("Cone softness", light.coneSoftness, 0...1, 0) { v in update { $0.coneSoftness = v } }
    number("Focus", light.focus, 0...50, 0) { v in update { $0.focus = v } }
    text(
      "Spectral transport renders the spectrum; RGB transport uses its colour (presets stay white). A blackbody or narrow band is normalised to the same luminance, so the radiance above keeps its brightness. The cone (UsdLux ShapingAPI) is measured from the light's facing direction; a few degrees make a beam.")
  }
}
