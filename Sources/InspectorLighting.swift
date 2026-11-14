import Cocoa
import simd

// The Lighting inspector page: environment, sun, scene lights, light spectra and the atmosphere.
extension StudioController {
  // Emitter spectra (StudioOptions.lightSpectrum / sunSpectrum): nil is the RGB colour.
  static let illuminantTitles = [
    "RGB colour", "E (equal energy)", "D65 (daylight)", "A (incandescent, 2856 K)", "FL11 (narrow-band fluorescent)",
    "HP1 (high-pressure sodium)", "LED-B3 (white LED)",
  ]
  func lightingPanel() {
    heading("Environment")
    popup(["Golden Hour", "High Noon", "Twilight / Studio"], Int(renderer.skyMode), label: "Sky preset") {
      [weak self] i in
      guard let self else { return }
      self.checkpoint("Sky preset")
      self.renderer.skyMode = UInt32(i)
      let p: [SIMD3<Float>] = [SIMD3(133, 27, 850), SIMD3(131, 62, 1100), SIMD3(128, 19, 550)]
      self.renderer.options.sunAzimuth = p[i].x
      self.renderer.options.sunElevation = p[i].y
      self.renderer.options.sunIntensity = p[i].z
      self.renderer.options.sunAngle = nil
      self.changed()
      self.rebuild()
    }
    text(project.environmentName)
    button("Load HDRI / environment image…") { [weak self] in self?.loadEnvironment() }
    button("Use procedural sky") { [weak self] in
      guard let self, !self.isBusy else { return }
      let record = self.undoRecord("Clear environment")
      do {
        try self.renderer.materials.setEnvironment(nil)
        self.project.environmentData = nil
        self.project.environmentName = "Procedural sky"
        self.commit(record)
        self.changed()
        self.rebuild()
      } catch { self.showError(error.localizedDescription) }
    }
    option("Environment brightness", \.environmentIntensity, 0...100, 1)
    option("Environment rotation, degrees", \.environmentRotation, -180...180, 0)
    option("Sun azimuth, degrees", \.sunAzimuth, -180...180, 133)
    option("Sun elevation, degrees", \.sunElevation, -89...89, 27)
    option("Sun intensity", \.sunIntensity, 0...10000, 850)
    text(
      "Sky/HDRI lighting is used in the Pavilion and Imported Mesh Studio. Sun controls apply to the procedural sky."
    )
    if let angle = renderer.options.sunAngle {
      text(String(format: "Imported distant light: %.2f° sun, intensity is irradiance, independent of the environment. A sky preset restores the procedural sun.", angle))
    }
    heading("Scene lights")
    option("Light intensity", \.lightIntensity, 0...100, 1)
    option("Light size multiplier", \.lightSize, 0.05...4, 1)
    // Light color is linear, like material tint; the well shows sRGB.
    func encode(_ c: Float) -> CGFloat {
      CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }
    func decode(_ c: CGFloat) -> Float {
      let x = Float(c)
      return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    let c = renderer.options.lightColor
    text("Light color")
    add(
      ActionColor(
        NSColor(srgbRed: encode(c.x), green: encode(c.y), blue: encode(c.z), alpha: 1),
        label: "Light color"
      ) { [weak self] c in
        guard let self, self.acceptsEdits, let c = c.usingColorSpace(.sRGB) else { return }
        // A colour-panel drag sends many changes; one undo step covers the burst.
        self.checkpoint("Light color", coalesce: true)
        self.renderer.options.lightColor = SIMD3(
          decode(c.redComponent), decode(c.greenComponent), decode(c.blueComponent))
        self.changed()
      })
    text(
      "Applies to the finite lights in Cornell, Veach, and Ring scenes. Veach lights share these controls."
    )
    heading("Light spectra")
    func spectrum(_ title: String, _ path: WritableKeyPath<StudioOptions, UInt32?>) {
      let current = renderer.options[keyPath: path].map { Int($0) + 1 } ?? 0
      popup(Self.illuminantTitles, min(current, Self.illuminantTitles.count - 1), label: title) { [weak self] i in
        guard let self else { return }
        self.checkpoint(title)
        self.renderer.options[keyPath: path] = i == 0 ? nil : UInt32(i - 1)
        self.changed()
        self.rebuild()
      }
    }
    text("Light spectrum")
    spectrum("Light spectrum", \.lightSpectrum)
    text("Sun spectrum")
    spectrum("Sun spectrum", \.sunSpectrum)
    text(
      "Spectral light transport only: a preset replaces the RGB colour's daylight-like spectrum, and the light colour tints it like a filter. Light spectrum covers area and sphere lights and imported emitters; the sky and environment images stay RGB."
    )
    let atmosphere = renderer.medium != nil ? 2 : Int(renderer.enableFog)
    popup(["Atmosphere: Clear", "Atmosphere: Fog preview", "Atmosphere: Participating medium"], atmosphere, label: "Atmosphere") {
      [weak self] i in
      guard let self else { return }
      self.checkpoint("Atmosphere")
      self.renderer.enableFog = i == 1 ? 1 : 0
      self.renderer.medium = i == 2 ? (self.renderer.medium ?? SceneMedium()) : nil
      self.changed()
      self.rebuild()
    }
    if let medium = renderer.medium { mediumControls(medium) }
  }
  // The scene medium (SceneMedium; docs/VOLUME_DESIGN.md §4), on the Lighting page.
  func mediumControls(_ medium: SceneMedium) {
    func update(_ change: (inout SceneMedium) -> Void) {
      var edited = renderer.medium ?? SceneMedium()
      change(&edited)
      renderer.medium = edited
    }
    number("Density (per metre)", medium.density, 0...5, 0.05, entry: SceneMedium.densityRange) { v in update { $0.density = v } }
    for (i, channel) in ["R", "G", "B"].enumerated() {
      number("Scattering albedo \(channel)", medium.albedo[i], 0...1, 0.9) { v in update { $0.albedo[i] = v } }
    }
    number("Anisotropy (g)", medium.anisotropy, -0.99...0.99, 0) { v in update { $0.anisotropy = v } }
    popup(["Grey scattering", "Rayleigh scattering (λ⁻⁴)"], medium.rayleigh ? 1 : 0, label: "Scattering law") { [weak self] i in
      guard let self else { return }
      self.checkpoint("Scattering law")
      update { $0.rayleigh = i == 1 }
      self.changed()
    }
    text(
      "Homogeneous haze in the scene's bounding box: density is the extinction per metre (at 550 nm with the Rayleigh law), albedo the scattered fraction, and anisotropy the Henyey-Greenstein g (positive scatters forward). Scenes with media render with Standard MIS instead of ReSTIR. Rayleigh scattering is bluer at short wavelengths, so beams turn orange as they cross it.")
  }
  func loadEnvironment() {
    chooseOpen(
      "Load equirectangular environment", extensions: ["hdr", "exr", "png", "jpg", "tif", "tiff"]
    ) { [weak self] url in self?.beginLoadEnvironment(from: url) }
  }
  // HDRI conversion and importance CDFs are built on projectIOQueue.
  func beginLoadEnvironment(from url: URL) {
    guard !isBusy else { return }
    let record = undoRecord("Environment image")
    let document = snapshot()
    beginDocumentChange("Loading \(url.lastPathComponent)…", build: { [weak self] _ -> (ProjectDocument, Void) in
      guard let self else { throw MaterialLibrary.error("Environment load cancelled.") }
      var document = document  // The build runs on projectIOQueue with its own copy.
      document.environmentData = try self.readBounded(url, maximum: 256 * 1024 * 1024)
      document.environmentName = url.lastPathComponent
      try self.requireEmbeddedCapacity(document.embeddedAssetBytes)
      return (document, ())
    }) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.commit(record)
        self.changed()
      case .failure(let error): self.showError(error.localizedDescription)
      }
    }
  }
}
