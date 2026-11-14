import Cocoa

// The Render inspector page: sampling strategy, ReSTIR modes, denoising, display and render settings.
extension StudioController {
  static let strategyNames = [
    "ReSTIR Direct + Indirect", "Standard MIS", "Light Only (NEE)", "BSDF Only",
  ]
  // Render inspector choices for the ReSTIR reuse modes; index 0 is always .automatic.
  static let indirectReuseChoices: [(mode: IndirectReuse, title: String)] = [
    (.automatic, "Automatic"), (.restirGI, "ReSTIR GI"), (.restirPT, "ReSTIR PT"),
    (.restirPTUnified, "ReSTIR PT (unified)"),
  ]
  static let spatialNeighborChoices: [(mode: SpatialNeighborSelection, title: String)] = [
    (.automatic, "Automatic"), (.uniform, "Uniform"), (.compatibility, "Compatibility-guided"),
    (.stochasticPairwise, "Stochastic pairwise MIS"),
  ]
  static let temporalReuseChoices: [(mode: TemporalReuse, title: String)] = [
    (.automatic, "Automatic"), (.reprojection, "Reprojection"), (.splatting, "Reservoir splatting"),
  ]
  static let controlVariateChoices: [(mode: ControlVariates, title: String)] = [
    (.automatic, "Automatic"), (.restcv, "Control variates"), (.off, "Resampled"),
  ]
  static let indirectReuseHelp =
    "ReSTIR GI is fastest and reuses the first diffuse bounce; ReSTIR PT reuses whole paths (better glossy, mirror and deep light) at about 1.3–2.3× the GPU time and +114–210 B per pixel; unified also merges direct light."
  static let spatialNeighborHelp =
    "Compatibility-guided reuse prefers neighbours with a similar surface: lower noise on imported meshes for 3–26% more frame time. It applies to ReSTIR DI and GI, not unified ReSTIR PT. Stochastic pairwise MIS reuses DI, GI and PT samples without bias from 64-pixel cells: 6–33% lower noise per sample with ReSTIR PT for 13–55% more frame time and 44–92 B more per pixel."
  static let temporalReuseHelp =
    "Reservoir splatting lowers noise in newly revealed areas while the camera moves, for 5–26% more frame time and about 200 B more GPU memory per pixel. Still views render identically."
  static let controlVariateHelp =
    "ReSTIR PT only, with paired spatial reuse. Control variates (ReSTCV) shade each pixel from colour estimates accumulated over neighbouring pixels and frames: 5–47% less noise per frame while the camera moves (5–21% under MetalFX) and 1–14% less in still renders, for 0–3% more frame time. Single frames can hold a few dark pixels without the denoiser. Resampled shades from the reservoirs' samples."
  static let samplerChoices: [(mode: SamplerMode, title: String)] = [
    (.automatic, "Automatic"), (.zSampling, "Z++ (blue-noise LD)"), (.pcg, "Independent (PCG)"),
  ]
  static let samplerHelp =
    "Z++ draws low-discrepancy samples ordered along a shuffled Z curve, so neighbouring pixels complement each other and every pixel's samples over a still render are stratified: 2–87% less noise at the same sample count (least through glass) for 0.4–5% more frame time, and finer-grained noise in each frame. Independent draws per-pixel random numbers, as before."
  static let lightTransportChoices: [(mode: LightTransport, title: String)] = [
    (.automatic, "Automatic"), (.spectral, "Spectral"), (.rgb, "RGB"),
  ]
  // Figures from tests/PERFORMANCE.md (Spectral transport cost).
  static let lightTransportHelp =
    "Spectral traces four wavelengths per path: illuminant presets (sodium, fluorescent, LED, incandescent), dispersion and thin film render physically, and saturated colours interreflect without RGB's errors, for about a third more frame time and some colour noise per frame. Automatic uses Spectral. RGB is faster and renders RGB-lit scenes almost the same; it ignores presets, dispersion and thin film. The spectral shaders compile in the background the first time."
  static let lightSamplingChoices: [(mode: LightSampling, title: String)] = [
    (.automatic, "Automatic"), (.tree, "Light tree"), (.power, "Power"),
  ]
  static let causticChoices: [(mode: CausticMode, title: String)] = [
    (.automatic, "Automatic"), (.lightTracing, "Light tracing"), (.lightTracingGuided, "Light tracing, guided"),
    (.photons, "Light tracing + photons"), (.photonsGuided, "Light tracing + photons, guided"), (.off, "Off"),
  ]
  // Figures from tests/PERFORMANCE.md (Caustic light tracing, Emission guiding).
  static let causticHelp =
    "Light tracing renders the caustics you see directly, light focused through glass or off polished metal onto other surfaces, by tracing paths from the imported scene's emitters, sky and sun and connecting them to the camera. It is unbiased and resolves small lights faster than path tracing alone. Light tracing + photons also renders the caustics seen through glass, water or a mirror, caustic light that bounces on to other surfaces, and light focused into fog: the same light paths leave photons that camera paths gather at up to two surfaces or points in a medium after the first, slightly blurred at first and converging as samples accumulate. Guided learns, as samples accumulate, which directions from each light lead to caustics the camera sees, and sends half the light paths there: less noise per sample, but each sample takes longer, so it pays only where few light paths find the glass and the rest are costly. All render with Standard MIS. Automatic is Off."
  static let lightSamplingHelp =
    "How imported scenes choose an emitter for each light sample. Light tree picks emitters by how much light they can send to the point being shaded (a light BVH), so scenes with many lights spread over a large space need fewer samples. Power picks them in proportion to their power alone, wherever they are. Both are unbiased; procedural scenes, the sky and the environment are unaffected."
  func renderPanel() {
    heading("Sampling")
    popup(Self.strategyNames, Int(renderer.samplingMode), label: "Sampling strategy") { [weak self] i in
      guard let self else { return }
      self.checkpoint("Strategy")
      self.renderer.samplingMode = UInt32(i)
      self.changed()
      self.rebuild()
    }
    number("Indirect clamp (0 = off)", renderer.options.indirectClamp ?? 0, 0...100, 0, entry: StudioOptions.indirectClampRange) {
      [weak self] v in self?.renderer.options.indirectClamp = v > 0 ? v : nil
    }
    text(
      "Caps the luminance each sample's indirect light can add, which removes fireflies. It is biased: bright indirect effects such as caustics lose energy, the more so the lower the cap. 0 keeps the unbiased render. Values of about 10-50 times a lit surface's brightness rarely change anything but the fireflies. With ReSTIR PT on imported scenes it caps the whole reused estimate, direct light included.")
    if renderer.hasMedia && renderer.samplingMode == 0 {
      text("This scene has participating media, which render with Standard MIS; the ReSTIR settings below apply to scenes without media.")
    }
    restirModeControls()
    let metalFX = ActionButton("MetalFX denoiser (preview)") { [weak self] in
      guard let self, self.acceptsEdits else { return }
      self.checkpoint("MetalFX")
      self.renderer.denoiserEnabled.toggle()
      self.changed(reset: false)
      self.rebuild()
    }
    metalFX.setButtonType(.switch)
    metalFX.state = renderer.denoiserEnabled ? .on : .off
    add(metalFX)
    if renderer.activeSamplingMode != 0 {
      text("MetalFX is available with ReSTIR Direct + Indirect. This strategy displays raw accumulation.")
    }
    if !renderer.supportsMetalFX { text("MetalFX is not supported by this GPU.") }
    if renderer.offlineDenoisedPreview != nil {
      button("Clear OIDN Preview") { [weak self] in self?.clearOIDNPreview() }
      text("The viewport and preview capture show the OIDN result. Clearing it restores the previous render state.")
    } else {
      button("OIDN Preview Current Frame") { [weak self] in self?.startOIDNPreview() }
      text("Freezes and denoises the current accumulated samples at the preview render resolution.")
    }
    heading("Display")
    popup(Self.viewportNames, Int(renderer.viewportMode), label: "Viewport mode") { [weak self] i in
      guard let self else { return }
      self.checkpoint("Viewport mode")
      self.renderer.viewportMode = UInt32(i)
      self.changed(reset: false)
      self.rebuild()
    }
    option("Exposure, EV", \.exposure, -16...16, 0, reset: false)
    option("White balance, cool → warm", \.whiteBalance, -1...1, 0, reset: false)
    popup(
      ["Tone map: Filmic fit", "Tone map: Reinhard", "Tone map: Linear / clip"],
      renderer.options.toneMap, label: "Tone map"
    ) { [weak self] i in
      guard let self else { return }
      self.checkpoint("Tone map")
      self.renderer.options.toneMap = i
      self.changed(reset: false)
    }
    option("Raw / MetalFX divider (0 = off)", \.compare, 0...1, 0, reset: false)
    text(
      "The left side shows raw accumulation. Exposure and white balance affect the display and PNG export; EXR preserves linear radiance."
    )
    text("Inspection views bypass tone mapping and denoising, and do not reset the progressive render.")
    renderSettingsSections()
  }

  // The sampler, light transport, light sampling and caustics popups (every strategy) and the four ReSTIR reuse
  // popups, which apply only to ReSTIR Direct + Indirect and are disabled (with a note) for the other strategies.
  func restirModeControls() {
    let r = renderer, restir = r.samplingMode == 0
    func choice<Mode: Equatable>(
      _ title: String, _ choices: [(mode: Mode, title: String)], current: Mode, automatic: String,
      help: String, enabled: Bool = restir, _ set: @escaping (inout ReSTIRModes, Mode) -> Void
    ) {
      let label = NSTextField(labelWithString: title)
      label.font = .systemFont(ofSize: 12)
      label.textColor = enabled ? .labelColor : .disabledControlTextColor
      add(label)
      let titles = choices.map { $0.title == "Automatic" ? "Automatic (currently: \(automatic))" : $0.title }
      let popup = ActionPopup(titles, selected: choices.firstIndex { $0.mode == current } ?? 0, label: title) {
        [weak self] i in
        guard let self, self.acceptsEdits else { return }
        let mode = choices[i].mode
        self.setReSTIRModes(title) { set(&$0, mode) }
      }
      popup.toolTip = help
      popup.setAccessibilityHelp(help)
      popup.isEnabled = enabled
      add(popup)
    }
    func name<Mode: Equatable>(_ mode: Mode, _ choices: [(mode: Mode, title: String)]) -> String {
      choices.first { $0.mode == mode }?.title ?? "\(mode)"
    }
    // The sampler applies to every strategy.
    choice(
      "Sampler", Self.samplerChoices, current: r.sampler,
      automatic: name(r.resolvedSampler(.automatic), Self.samplerChoices),
      help: Self.samplerHelp, enabled: true
    ) { $0.sampler = $1 }
    // The light transport applies to every strategy.
    choice(
      "Light transport", Self.lightTransportChoices, current: r.lightTransport,
      automatic: name(r.resolvedLightTransport(.automatic), Self.lightTransportChoices),
      help: Self.lightTransportHelp, enabled: true
    ) { $0.lightTransport = $1 }
    // The light sampling applies to every strategy's imported emitters.
    choice(
      "Light sampling", Self.lightSamplingChoices, current: r.lightSampling,
      automatic: name(LightSampling.automatic.resolved(), Self.lightSamplingChoices),
      help: Self.lightSamplingHelp, enabled: true
    ) { $0.lightSampling = $1 }
    // Caustic light tracing applies to imported scenes, whatever the strategy (it renders Standard MIS).
    choice(
      "Caustics", Self.causticChoices, current: r.caustics,
      automatic: name(CausticMode.automatic.resolved(), Self.causticChoices),
      help: Self.causticHelp, enabled: true
    ) { $0.caustics = $1 }
    if r.activeLightTransport == .spectral && !r.spectralShaders.compiling && r.spectralShaders.kernels == nil,
      let failure = r.spectralShaders.failure
    {
      text(failure)
    } else if r.activeLightTransport == .spectral && r.spectralShaders.compiling {
      text("Compiling the spectral shaders; the view renders in RGB until they are ready.")
    }
    let compiling = PathTracerRenderer.KernelGroup.allCases.filter { r.sceneShaders.compiling.contains($0) }
    if !compiling.isEmpty {
      text("Compiling the \(compiling.map(\.title).joined(separator: ", ")) shaders; until they are ready the view renders with ReSTIR GI, reprojection and automatic neighbours.")
    }
    choice(
      "Indirect reuse", Self.indirectReuseChoices, current: r.indirectReuse,
      automatic: name(r.resolvedIndirectReuse(.automatic), Self.indirectReuseChoices),
      help: Self.indirectReuseHelp
    ) { $0.indirectReuse = $1 }
    choice(
      "Spatial neighbours", Self.spatialNeighborChoices, current: r.spatialNeighbors,
      automatic: name(r.resolvedSpatialNeighbors(.automatic), Self.spatialNeighborChoices),
      help: Self.spatialNeighborHelp
    ) { $0.spatialNeighbors = $1 }
    choice(
      "Temporal reuse", Self.temporalReuseChoices, current: r.temporalReuse,
      automatic: name(r.resolvedTemporalReuse(.automatic, indirectReuse: r.indirectReuse), Self.temporalReuseChoices),
      help: Self.temporalReuseHelp
    ) { $0.temporalReuse = $1 }
    choice(
      "Path shading", Self.controlVariateChoices, current: r.controlVariates,
      automatic: name(r.resolvedControlVariates(.automatic), Self.controlVariateChoices),
      help: Self.controlVariateHelp
    ) { $0.controlVariates = $1 }
    if !restir {
      text("Indirect reuse, spatial neighbours, temporal reuse and path shading apply only to ReSTIR Direct + Indirect.")
    }
  }
  // The render size a mode switch is preflighted at: the live accumulation, else the viewport.
  var previewRenderSize: (width: Int, height: Int)? {
    if let accum = renderer.accumTexture { return (accum.width, accum.height) }
    let size = viewport.drawableSize, scale = renderer.options.previewScale
    guard size.width >= 1, size.height >= 1 else { return nil }
    return (max(1, Int(Float(size.width) * scale)), max(1, Int(Float(size.height) * scale)))
  }
  // Applies a ReSTIR mode change as one undo step, after the GPU memory preflight. A switch
  // the budget cannot hold (when the current modes fit) is refused: the error is shown, the
  // popup reverts and rendering continues with the current modes.
  func setReSTIRModes(_ name: String, _ update: (inout ReSTIRModes) -> Void) {
    guard acceptsEdits else { return }
    var modes = ReSTIRModes(renderer)
    update(&modes)
    guard modes != ReSTIRModes(renderer) else { return }
    if let size = previewRenderSize,
      let message = renderer.renderMemoryError(
        width: size.width, height: size.height, indirectReuse: modes.indirectReuse, temporalReuse: modes.temporalReuse,
        spatialNeighbors: modes.spatialNeighbors),
      renderer.renderMemoryError(width: size.width, height: size.height) == nil
    {
      showError("\(name) was not changed. \(message)")
      rebuild()
      return
    }
    checkpoint(name)
    modes.apply(renderer)
    changed()
    rebuild()
  }

  // Render limits, Open Image Denoise and Experimental, at the end of the Render page.
  func renderSettingsSections() {
    heading("Render limits")
    number(
      "Sample limit (0 = unlimited)", Float(renderer.options.maxSamples), 0...16384, 0, reset: false, integral: true
    ) { [weak self] in self?.renderer.options.maxSamples = UInt32($0) }
    number(
      "Time limit, seconds (0 = unlimited)", Float(renderer.options.timeLimit), 0...3600, 0,
      reset: false
    ) { [weak self] in self?.renderer.options.timeLimit = Double($0) }
    option("Preview resolution scale", \.previewScale, 0.1...1, 0.5)
    number("Path depth (1 = direct light only)", Float(renderer.options.depth), 1...64, 16, integral: true) {
      [weak self] in self?.renderer.options.depth = Int($0)
    }

    heading("Open Image Denoise")
    popup(["Quality: Fast", "Quality: Balanced", "Quality: High"], Int(renderer.oidnOptions.quality)) {
      [weak self] i in self?.setOIDN("OIDN quality") { $0.quality = UInt32(i) }
    }
    popup(["Guides: Color only", "Guides: Albedo", "Guides: Albedo + normal"], Int(renderer.oidnOptions.guides)) {
      [weak self] i in self?.setOIDN("OIDN guides") { $0.guides = UInt32(i) }
    }
    button("Treat guides as noisy: \(renderer.oidnOptions.treatGuidesAsNoisy ? "On" : "Off")") { [weak self] in
      self?.setOIDN("OIDN guide noise") { $0.treatGuidesAsNoisy.toggle() }
    }
    button("Robust HDR input scale: \(renderer.oidnOptions.robustInputScale ? "On" : "Off")") { [weak self] in
      self?.setOIDN("OIDN HDR scale") { $0.robustInputScale.toggle() }
    }
    button("Diffuse firefly suppression: \(renderer.oidnOptions.suppressDiffuseFireflies ? "On" : "Off")") { [weak self] in
      self?.setOIDN("OIDN firefly suppression") { $0.suppressDiffuseFireflies.toggle() }
    }
    text("By default OIDN chooses its own HDR input scale; the robust scale instead keys exposure on lit, non-emissive surfaces. The diffuse firefly filter prevents isolated HDR samples from expanding into false bright patches. Both affect only OIDN output; raw accumulation is preserved.")

    heading("Experimental")
    popup(["Ring boost: Off", "Ring boost: On"], Int(renderer.enableSMS)) { [weak self] i in
      guard let self else { return }
      self.checkpoint("Ring boost")
      self.renderer.enableSMS = UInt32(i)
      self.changed()
    }
    text("Ring boost is an artistic approximation for the original ring position.")
  }

  func setOIDN(_ name: String, _ update: (inout OIDNOptions) -> Void) {
    guard acceptsEdits else { return }
    checkpoint(name)
    update(&renderer.oidnOptions)
    if renderer.offlineDenoisedPreview != nil {
      renderer.offlineDenoisedPreview = nil
      renderer.paused = oidnPreviewWasPaused
    }
    renderer.presentationNeedsRefresh = true
    changed(reset: false)
    rebuild()
  }
}
