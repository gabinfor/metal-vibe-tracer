import Cocoa

// The Render inspector tab: Quality (preview resolution, path depth, limits), Method (sampling strategy, light
// transport, caustics, indirect clamp), Denoising (MetalFX, Open Image Denoise), Advanced (sampler, light sampling,
// the ReSTIR reuse modes, OIDN options, ring boost) and Reset Render Settings.
extension StudioController {
  static let strategyNames = [
    "ReSTIR Direct + Indirect", "Standard MIS", "Light Only (NEE)", "BSDF Only",
  ]
  static let strategyHelp =
    "ReSTIR Direct + Indirect reuses light and path samples across neighbouring pixels and frames; MetalFX denoises only this strategy. Standard MIS combines light and BSDF sampling, and renders scenes with participating media or caustic light tracing. Light Only (NEE) and BSDF Only use one technique each."
  // The Preview resolution popup's choices; a project value between them shows as an extra "Custom (NN%)" item.
  static let previewScaleChoices: [(scale: Float, title: String)] = [
    (0.25, "25%"), (1 / 3, "33%"), (0.5, "50%"), (2 / 3, "67%"), (0.75, "75%"), (1, "100%"),
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
    "Z++ draws low-discrepancy samples ordered along a shuffled Z curve, so neighbouring pixels complement each other and every pixel's samples over a still render are stratified: 2–87% less noise at the same sample count (least through glass) for 0.4–5% more frame time, and finer-grained noise in each frame. Independent draws uncorrelated per-pixel random numbers."
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
  static let indirectClampHelp =
    "Caps the luminance each sample's indirect light can add, which removes fireflies. It is biased: bright indirect effects such as caustics lose energy, the more so the lower the cap. Off keeps the unbiased render. Values of about 10–50 times a lit surface's brightness rarely change anything but the fireflies. With ReSTIR PT on imported scenes it caps the whole reused estimate, direct light included."
  static let metalFXHelp =
    "Denoises the interactive view with MetalFX while samples accumulate (ReSTIR Direct + Indirect only). Accumulated samples are kept when it is switched."
  static let oidnOptionHelp =
    "These options affect only Open Image Denoise output (Denoise Current Frame and denoised exports); raw accumulation is preserved."

  func renderPanel() {
    let r = renderer
    section("Quality")
    previewResolutionRow()
    number(
      "Path depth", Float(r.options.depth), 1...64, 16, integral: true, step: 1,
      help: "Path vertices per sample: 1 renders direct light only; more add indirect bounces at more cost per sample."
    ) { [weak self] in self?.renderer.options.depth = Int($0) }
    number(
      "Sample limit", Float(r.options.maxSamples), 0...16384, 0, reset: false, entry: 0...16_777_214, integral: true,
      step: 1, scale: .logarithmic, zeroText: "Unlimited",
      help: "Rendering stops after this many samples per pixel; Unlimited keeps accumulating."
    ) { [weak self] in self?.renderer.options.maxSamples = UInt32($0) }
    number(
      "Time limit, seconds", Float(r.options.timeLimit), 0...3600, 0, reset: false, entry: 0...86_400, step: 1,
      scale: .logarithmic, zeroText: "Unlimited",
      help: "Rendering stops after this many seconds; Unlimited keeps accumulating."
    ) { [weak self] in self?.renderer.options.timeLimit = Double($0) }

    section("Method")
    popupRow("Sampling strategy", Self.strategyNames, Int(r.samplingMode), help: Self.strategyHelp) { [weak self] i in
      guard let self, UInt32(i) != self.renderer.samplingMode else { return }
      self.checkpoint("Strategy")
      self.renderer.samplingMode = UInt32(i)
      self.changed()
      self.rebuild()
    }
    if r.samplingMode == 0 && r.activeSamplingMode != 0 {
      hint(r.hasMedia ? "Participating media render with Standard MIS." : "Caustic light tracing renders with Standard MIS.")
    }
    modeRow(
      "Light transport", Self.lightTransportChoices, current: r.lightTransport,
      automatic: r.resolvedLightTransport(.automatic), help: Self.lightTransportHelp
    ) { $0.lightTransport = $1 }
    if r.activeLightTransport == .spectral && !r.spectralShaders.compiling && r.spectralShaders.kernels == nil,
      let failure = r.spectralShaders.failure
    {
      hint(failure)
    } else if r.activeLightTransport == .spectral && r.spectralShaders.compiling {
      hint("Compiling the spectral shaders; the view renders in RGB until they are ready.")
    }
    // Caustic light tracing applies to imported scenes, whatever the strategy (it renders Standard MIS).
    modeRow(
      "Caustics", Self.causticChoices, current: r.caustics, automatic: CausticMode.automatic.resolved(),
      help: Self.causticHelp
    ) { $0.caustics = $1 }
    number(
      "Indirect clamp", r.options.indirectClamp ?? 0, 0...100, 0, entry: StudioOptions.indirectClampRange, step: 0.1,
      scale: .logarithmic, zeroText: "Off", help: Self.indirectClampHelp
    ) { [weak self] v in self?.renderer.options.indirectClamp = v > 0 ? v : nil }

    section("Denoising")
    toggle("MetalFX preview", r.denoiserEnabled, reset: false, help: Self.metalFXHelp, enabled: r.supportsMetalFX) {
      [weak self] on in
      self?.renderer.denoiserEnabled = on
      self?.rebuild()
    }
    if !r.supportsMetalFX {
      hint("MetalFX is not supported by this GPU.")
    } else if r.denoiserEnabled && r.activeSamplingMode != 0 {
      hint("MetalFX needs ReSTIR; the view shows raw samples.")
    }
    if r.denoiserEnabled {
      option(
        "Raw / MetalFX divider", \.compare, 0...1, 0, reset: false, step: 0.01, zeroText: "Off",
        help: "Shows raw accumulation left of the divider and the MetalFX result right of it; Off shows MetalFX only.")
    }
    popupRow(
      "OIDN quality", ["Fast", "Balanced", "High"], Int(r.oidnOptions.quality),
      help: "Open Image Denoise filter quality for Denoise Current Frame and denoised exports: High is slowest and best."
    ) { [weak self] i in self?.setOIDN("OIDN quality") { $0.quality = UInt32(i) } }
    popupRow(
      "OIDN guides", ["Colour only", "Albedo", "Albedo + normal"], Int(r.oidnOptions.guides),
      help: "The auxiliary images Open Image Denoise uses besides colour; more guides keep more texture and edge detail."
    ) { [weak self] i in self?.setOIDN("OIDN guides") { $0.guides = UInt32(i) } }
    let denoise = ActionButton("Denoise Current Frame") { [weak self] in self?.startOIDNPreview() }
    let denoiseHelp = "Freezes the view and denoises the accumulated samples with Open Image Denoise at the preview resolution."
    denoise.toolTip = denoiseHelp
    denoise.setAccessibilityHelp(denoiseHelp)
    let clear = ActionButton("Clear Denoised Preview") { [weak self] in self?.clearOIDNPreview() }
    clear.toolTip = "Returns to the live render."
    clear.setAccessibilityHelp(clear.toolTip)
    clear.isEnabled = r.offlineDenoisedPreview != nil
    buttonRow([denoise, clear])
    if r.offlineDenoisedPreview != nil { hint("The view shows the denoised frame until it is cleared.") }

    collapsible("Advanced", key: "render.advanced") {
      modeRow(
        "Sampler", Self.samplerChoices, current: r.sampler, automatic: r.resolvedSampler(.automatic),
        help: Self.samplerHelp
      ) { $0.sampler = $1 }
      // The light sampling applies to every strategy's imported emitters.
      modeRow(
        "Light sampling", Self.lightSamplingChoices, current: r.lightSampling,
        automatic: LightSampling.automatic.resolved(), help: Self.lightSamplingHelp
      ) { $0.lightSampling = $1 }
      if r.samplingMode == 0 {
        restirReuseRows()
      } else {
        hint("Reuse settings apply only to ReSTIR Direct + Indirect.")
      }
      let oidn = r.oidnOptions
      toggle(
        "Treat guides as noisy", oidn.treatGuidesAsNoisy, reset: false,
        help: "On, Open Image Denoise cleans the albedo and normal guides, which accumulate with the samples; off, it trusts them as noise-free. "
          + Self.oidnOptionHelp
      ) { [weak self] on in self?.applyOIDN { $0.treatGuidesAsNoisy = on } }
      toggle(
        "Robust HDR input scale", oidn.robustInputScale, reset: false,
        help: "Off, Open Image Denoise chooses its own HDR input scale; on, the scale is keyed on lit, non-emissive surfaces. "
          + Self.oidnOptionHelp
      ) { [weak self] on in self?.applyOIDN { $0.robustInputScale = on } }
      toggle(
        "Diffuse firefly suppression", oidn.suppressDiffuseFireflies, reset: false,
        help: "Keeps isolated very bright samples from spreading into false bright patches. " + Self.oidnOptionHelp
      ) { [weak self] on in self?.applyOIDN { $0.suppressDiffuseFireflies = on } }
      // The boost targets the Reflective Ring Study; it stays listed elsewhere while on, so it can be switched off.
      if r.sceneIndex == 5 || r.enableSMS != 0 {
        toggle(
          "Ring boost", r.enableSMS != 0,
          help: "An artistic, biased approximation of the ring caustic for the Reflective Ring Study's original ring position."
        ) { [weak self] on in self?.renderer.enableSMS = on ? 1 : 0 }
      }
    }

    if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: last) }
    let reset = button(
      "Reset Render Settings", style: .destructive,
      help: "Restores every setting on this tab to its default, as one undo step."
    ) { [weak self] in self?.resetRenderSettings() }
    reset.isEnabled = !renderSettingsAreDefault
    renderResetButton = reset
  }

  // The four ReSTIR reuse popups (ReSTIR Direct + Indirect only), after a note while their shaders compile.
  private func restirReuseRows() {
    let r = renderer
    let compiling = PathTracerRenderer.KernelGroup.allCases.filter { r.sceneShaders.compiling.contains($0) }
    if !compiling.isEmpty {
      hint("Compiling the \(compiling.map(\.title).joined(separator: ", ")) shaders; ReSTIR GI renders meanwhile.")
    }
    modeRow(
      "Indirect reuse", Self.indirectReuseChoices, current: r.indirectReuse,
      automatic: r.resolvedIndirectReuse(.automatic), help: Self.indirectReuseHelp
    ) { $0.indirectReuse = $1 }
    modeRow(
      "Spatial neighbours", Self.spatialNeighborChoices, current: r.spatialNeighbors,
      automatic: r.resolvedSpatialNeighbors(.automatic), help: Self.spatialNeighborHelp
    ) { $0.spatialNeighbors = $1 }
    modeRow(
      "Temporal reuse", Self.temporalReuseChoices, current: r.temporalReuse,
      automatic: r.resolvedTemporalReuse(.automatic, indirectReuse: r.indirectReuse), help: Self.temporalReuseHelp
    ) { $0.temporalReuse = $1 }
    modeRow(
      "Path shading", Self.controlVariateChoices, current: r.controlVariates,
      automatic: r.resolvedControlVariates(.automatic), help: Self.controlVariateHelp
    ) { $0.controlVariates = $1 }
  }

  // A popup row for one of the ReSTIRModes; the Automatic item names the mode it currently resolves to. A change goes
  // through setReSTIRModes (memory preflight, one undo step named `title`).
  private func modeRow<Mode: Equatable>(
    _ title: String, _ choices: [(mode: Mode, title: String)], current: Mode, automatic: Mode, help: String,
    _ set: @escaping (inout ReSTIRModes, Mode) -> Void
  ) {
    let resolved = choices.first { $0.mode == automatic }?.title ?? "\(automatic)"
    let titles = choices.map { $0.title == "Automatic" ? "Automatic (currently: \(resolved))" : $0.title }
    popupRow(title, titles, choices.firstIndex { $0.mode == current } ?? 0, help: help) { [weak self] i in
      let mode = choices[i].mode
      self?.setReSTIRModes(title) { set(&$0, mode) }
    }
  }

  // Preview resolution as a share of the viewport. A project value that is not one of the listed percentages shows as
  // a trailing "Custom (NN%)" item, which selects nothing new.
  private func previewResolutionRow() {
    let scale = renderer.options.previewScale
    func percent(_ s: Float) -> Int { Int((s * 100).rounded()) }
    var titles = Self.previewScaleChoices.map(\.title)
    var selected = Self.previewScaleChoices.firstIndex { percent($0.scale) == percent(scale) }
    if selected == nil {
      titles.append("Custom (\(percent(scale))%)")
      selected = titles.count - 1
    }
    popupRow(
      "Preview resolution", titles, selected!,
      help: "The viewport's render resolution as a share of its size: lower renders faster and blurrier. Exports use their own size."
    ) { [weak self] i in
      guard let self, i < Self.previewScaleChoices.count else { return }
      let choice = Self.previewScaleChoices[i].scale
      guard percent(choice) != percent(self.renderer.options.previewScale) else { return }
      self.checkpoint("Preview resolution")
      self.renderer.options.previewScale = choice
      self.changed()
      self.rebuild()
    }
  }

  // The render size a mode switch is preflighted at: the live accumulation, else the viewport.
  var previewRenderSize: (width: Int, height: Int)? {
    if let accum = renderer.accumTexture { return (accum.width, accum.height) }
    return viewportRenderSize(scale: renderer.options.previewScale)
  }
  // The viewport's render size at preview resolution `scale`.
  func viewportRenderSize(scale: Float) -> (width: Int, height: Int)? {
    let size = viewport.drawableSize
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

  // Whether every setting on the Render tab has its default (a new project's) value.
  var renderSettingsAreDefault: Bool {
    let r = renderer, o = r.options, d = StudioOptions()
    return r.samplingMode == 0 && ReSTIRModes(r) == ReSTIRModes.defaults && o.previewScale == d.previewScale
      && o.depth == d.depth && o.maxSamples == d.maxSamples && o.timeLimit == d.timeLimit
      && (o.indirectClamp ?? 0) == 0 && o.compare == d.compare && !r.denoiserEnabled && r.oidnOptions == OIDNOptions()
      && r.enableSMS == 0
  }
  // Restores the Render tab's defaults as one undo step. The ReSTIR modes pass the same GPU memory preflight as
  // setReSTIRModes, at the default preview resolution: when they do not fit (and the current ones do), nothing changes.
  func resetRenderSettings() {
    guard acceptsEdits, !renderSettingsAreDefault else { return }
    let modes = ReSTIRModes.defaults, defaults = StudioOptions()
    if modes != ReSTIRModes(renderer), let current = previewRenderSize {
      let size = renderer.options.previewScale == defaults.previewScale
        ? current : viewportRenderSize(scale: defaults.previewScale) ?? current
      if let message = renderer.renderMemoryError(
        width: size.width, height: size.height, indirectReuse: modes.indirectReuse, temporalReuse: modes.temporalReuse,
        spatialNeighbors: modes.spatialNeighbors),
        renderer.renderMemoryError(width: current.width, height: current.height) == nil
      {
        showError("Render settings were not reset. \(message)")
        rebuild()
        return
      }
    }
    checkpoint("Reset Render Settings")
    if renderer.offlineDenoisedPreview != nil {
      renderer.offlineDenoisedPreview = nil
      renderer.paused = oidnPreviewWasPaused
    }
    renderer.samplingMode = 0
    modes.apply(renderer)
    renderer.options.previewScale = defaults.previewScale
    renderer.options.depth = defaults.depth
    renderer.options.maxSamples = defaults.maxSamples
    renderer.options.timeLimit = defaults.timeLimit
    renderer.options.indirectClamp = nil
    renderer.options.compare = defaults.compare
    renderer.denoiserEnabled = false
    renderer.oidnOptions = OIDNOptions()
    renderer.enableSMS = 0
    renderer.presentationNeedsRefresh = true
    changed()
    rebuild()
  }

  // An OIDN option change as one undo step named `name`; choosing the current value records nothing.
  func setOIDN(_ name: String, _ update: (inout OIDNOptions) -> Void) {
    guard acceptsEdits else { return }
    var options = renderer.oidnOptions
    update(&options)
    guard options != renderer.oidnOptions else { return }
    checkpoint(name)
    applyOIDN { $0 = options }
    changed(reset: false)
  }
  // Applies an OIDN option change without recording undo (toggle rows record their own): a shown denoised preview is
  // cleared, since it no longer matches the options.
  func applyOIDN(_ update: (inout OIDNOptions) -> Void) {
    update(&renderer.oidnOptions)
    if renderer.offlineDenoisedPreview != nil {
      renderer.offlineDenoisedPreview = nil
      renderer.paused = oidnPreviewWasPaused
    }
    renderer.presentationNeedsRefresh = true
    rebuild()
  }
}
