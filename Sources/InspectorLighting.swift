import Cocoa
import simd

// The Lighting inspector page: only the lighting the current scene reads. The shader evaluates the sky, the
// environment image and the sun in the Pavilion and imported scenes (sceneIndex 0 and 6), and scales the finite area
// and sphere lights of the Cornell, Veach, Glass & Mirror, Fog and Ring scenes (1–5) by the light intensity, size and
// colour. The atmosphere applies to every scene.
extension StudioController {
  // Emitter spectra (StudioOptions.lightSpectrum / sunSpectrum): nil is the RGB colour.
  static let illuminantTitles = [
    "RGB colour", "E (equal energy)", "D65 (daylight)", "A (incandescent, 2856 K)", "FL11 (narrow-band fluorescent)",
    "HP1 (high-pressure sodium)", "LED-B3 (white LED)",
  ]
  static let skyPresetTitles = ["Golden Hour", "High Noon", "Twilight / Studio"]
  // Sun azimuth and elevation (degrees) and intensity of each sky preset.
  static let skyPresetSuns: [SIMD3<Float>] = [SIMD3(133, 27, 850), SIMD3(131, 62, 1100), SIMD3(128, 19, 550)]
  var sceneUsesSky: Bool { renderer.sceneIndex == 0 || renderer.sceneIndex == 6 }
  var sceneHasFiniteLights: Bool { (1...5).contains(renderer.sceneIndex) }
  // Whether the project has an environment image (otherwise the procedural sky lights sky scenes).
  var hasEnvironmentImage: Bool { project.environmentData != nil }

  func lightingPanel() {
    if sceneUsesSky {
      environmentSection()
      // With an environment image only an imported distant light is a sun; the procedural sun is part of the sky.
      if !hasEnvironmentImage || renderer.options.sunAngle != nil { sunSection() }
    }
    if sceneHasFiniteLights {
      section("Lights")
      option(
        "Intensity", \.lightIntensity, 0...100, 1, step: 0.01, scale: .logarithmic,
        help: "Multiplies the emission of the scene's lights. The Veach scene's four lights share these settings.")
      option("Size", \.lightSize, 0.05...4, 1, step: 0.01, help: "Multiplies the size of the scene's lights.")
      colorRow("Light color", renderer.options.lightColor, help: "Tints the scene's lights (linear RGB).") {
        [weak self] in self?.renderer.options.lightColor = $0
      }
      spectrumRow("Light spectrum", \.lightSpectrum)
    } else if renderer.sceneIndex == 6 {
      section("Lights")
      spectrumRow("Light spectrum", \.lightSpectrum)
      hint("Select a light to edit it on the Materials tab.")
    }
    atmosphereSection()
  }
  private func environmentSection() {
    section("Environment")
    if hasEnvironmentImage {
      hint("Image: " + project.environmentName)
    } else {
      popupRow(
        "Sky preset", Self.skyPresetTitles, Int(renderer.skyMode),
        help: "The procedural sky and its sun. Choosing a preset also sets the sun's position and intensity."
      ) { [weak self] i in
        guard let self else { return }
        self.checkpoint("Sky preset")
        self.renderer.skyMode = UInt32(i)
        let sun = Self.skyPresetSuns[i]
        self.renderer.options.sunAzimuth = sun.x
        self.renderer.options.sunElevation = sun.y
        self.renderer.options.sunIntensity = sun.z
        self.renderer.options.sunAngle = nil
        self.changed()
        self.rebuild()
      }
    }
    button(
      "Load Environment Image…",
      help: "An equirectangular image (HDR, EXR, PNG, JPEG or TIFF) that replaces the procedural sky."
    ) { [weak self] in self?.loadEnvironment() }
    if hasEnvironmentImage {
      button("Remove Image", style: .destructive, help: "Returns to the procedural sky.") { [weak self] in
        self?.removeEnvironmentImage()
      }
    }
    option(
      "Brightness", \.environmentIntensity, 0...100, 1, step: 0.01, scale: .logarithmic,
      help: "Multiplies the sky or environment image.")
    if hasEnvironmentImage {
      option(
        "Rotation, °", \.environmentRotation, -180...180, 0, step: 1,
        help: "Turns the environment image about the vertical axis.")
    }
  }
  private func sunSection() {
    section("Sun")
    let preset = Self.skyPresetSuns[min(Int(renderer.skyMode), Self.skyPresetSuns.count - 1)]
    option("Azimuth, °", \.sunAzimuth, -180...180, preset.x, entry: -360...360, step: 1,
      help: "The sun's compass direction.")
    option("Elevation, °", \.sunElevation, -89...89, preset.y, entry: -90...90, step: 1,
      help: "The sun's height above the horizon.")
    option(
      "Intensity", \.sunIntensity, 0...10000, preset.z,
      help: renderer.options.sunAngle == nil
        ? "The procedural sun's brightness." : "The imported sun's irradiance at normal incidence.")
    spectrumRow("Sun spectrum", \.sunSpectrum)
    if let angle = renderer.options.sunAngle {
      let note = String(format: "Imported distant light: %.2f° sun.", angle)
      hint(note)
      if let last = stack.arrangedSubviews.last {
        last.toolTip = note + " Its intensity is irradiance, independent of the environment brightness. "
          + "Choosing a sky preset restores the procedural sun."
      }
    }
  }
  // An emitter spectrum popup: the RGB colour or an illuminant preset (spectral light transport only).
  private func spectrumRow(_ title: String, _ path: WritableKeyPath<StudioOptions, UInt32?>) {
    let current = renderer.options[keyPath: path].map { Int($0) + 1 } ?? 0
    let covers = path == \.sunSpectrum
      ? "the sun's" : "the area and sphere lights' and imported emitters' (the light colour tints it like a filter)"
    popupRow(
      title, Self.illuminantTitles, min(current, Self.illuminantTitles.count - 1),
      help: "Spectral light transport only: a preset replaces \(covers) daylight-like RGB spectrum. The sky and "
        + "environment images stay RGB."
    ) { [weak self] i in
      guard let self else { return }
      self.checkpoint(title)
      self.renderer.options[keyPath: path] = i == 0 ? nil : UInt32(i - 1)
      self.changed()
      self.rebuild()
    }
  }
  private func atmosphereSection() {
    section("Atmosphere")
    let atmosphere = renderer.medium != nil ? 2 : Int(renderer.enableFog)
    popupRow(
      "Atmosphere", ["Clear", "Fog preview", "Participating medium"], atmosphere,
      help: "Fog preview is a fast single-scatter camera fog. A participating medium is a physically based haze "
        + "in the scene's bounding box."
    ) { [weak self] i in
      guard let self else { return }
      self.checkpoint("Atmosphere")
      self.renderer.enableFog = i == 1 ? 1 : 0
      self.renderer.medium = i == 2 ? (self.renderer.medium ?? SceneMedium()) : nil
      self.changed()
      self.rebuild()
    }
    if let medium = renderer.medium { mediumControls(medium) }
  }
  // The scene medium (SceneMedium; docs/VOLUME_DESIGN.md §4), in the Atmosphere section.
  func mediumControls(_ medium: SceneMedium) {
    func update(_ change: (inout SceneMedium) -> Void) {
      var edited = renderer.medium ?? SceneMedium()
      change(&edited)
      renderer.medium = edited
    }
    number(
      "Density, 1/m", medium.density, 0...5, 0.05, entry: SceneMedium.densityRange, step: 0.001, scale: .logarithmic,
      help: "Extinction per metre (at 550 nm with the Rayleigh law)."
    ) { v in update { $0.density = v } }
    colorRow(
      "Scattering albedo", medium.albedo,
      help: "The fraction of extinguished light that scatters rather than being absorbed, per channel."
    ) { v in update { $0.albedo = simd_clamp(v, SIMD3(repeating: 0), SIMD3(repeating: 1)) } }
    number(
      "Anisotropy", medium.anisotropy, -0.99...0.99, 0, step: 0.01,
      help: "Henyey-Greenstein g: positive scatters forward, negative backward, 0 evenly."
    ) { v in update { $0.anisotropy = v } }
    popupRow(
      "Scattering law", ["Grey", "Rayleigh (λ⁻⁴)"], medium.rayleigh ? 1 : 0,
      help: "Rayleigh scattering is bluer at short wavelengths, so beams turn orange as they cross the medium."
    ) { [weak self] i in
      guard let self else { return }
      self.checkpoint("Scattering law")
      update { $0.rayleigh = i == 1 }
      self.changed()
    }
    hint("Scenes with a medium render with Standard MIS instead of ReSTIR.")
  }
  func removeEnvironmentImage() {
    guard !isBusy else { return }
    let record = undoRecord("Clear environment")
    do {
      try renderer.materials.setEnvironment(nil)
      project.environmentData = nil
      project.environmentName = "Procedural sky"
      commit(record)
      changed()
      rebuild()
    } catch { showError(error.localizedDescription) }
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
