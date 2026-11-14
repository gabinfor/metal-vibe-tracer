import Cocoa

// The Export tab: the output size, samples and source, the file format and the export commands. Project commands are
// in the File menu.
extension StudioController {
  // Size presets after Custom; Match Viewport follows them.
  static let exportSizePresets: [(width: Int, height: Int)] = [
    (1280, 720), (1920, 1080), (2560, 1440), (3840, 2160), (1080, 1080),
  ]
  static let exportSizeTitles = ["Custom"] + exportSizePresets.map { "\($0.width) × \($0.height)" } + ["Match Viewport"]
  // The Size popup's item for an output size: its preset, else Custom (0).
  static func exportSizeIndex(width: Int, height: Int) -> Int {
    exportSizePresets.firstIndex { $0.width == width && $0.height == height }.map { $0 + 1 } ?? 0
  }
  // The viewport's size in pixels, within the output limits.
  var viewportPixelSize: (width: Int, height: Int) {
    let size = viewport.convertToBacking(viewport.bounds).size
    func clamp(_ v: CGFloat) -> Int { min(8192, max(16, Int(v.rounded()))) }
    return (clamp(size.width), clamp(size.height))
  }
  // Export preferences (UserDefaults, not the project): the format and Show in Finder when done.
  static let exportFormatKey = "ExportFormat", exportRevealKey = "ExportShowInFinder"
  static let exportFormats = ["PNG", "OpenEXR"]
  var exportsOpenEXR: Bool {
    get { preferences.integer(forKey: Self.exportFormatKey) == 1 }
    set { preferences.set(newValue ? 1 : 0, forKey: Self.exportFormatKey) }
  }
  var revealsExportInFinder: Bool {
    get { preferences.bool(forKey: Self.exportRevealKey) }
    set { preferences.set(newValue, forKey: Self.exportRevealKey) }
  }
  func setOutputSize(width: Int, height: Int) {
    guard acceptsEdits else { return }
    checkpoint("Output size")
    renderer.options.outputWidth = width
    renderer.options.outputHeight = height
    changed(reset: false)
  }

  func filePanel() {
    let o = renderer.options
    section("Size")
    popupRow(
      "Preset", Self.exportSizeTitles, Self.exportSizeIndex(width: o.outputWidth, height: o.outputHeight),
      help: "Match Viewport takes the viewport's size in pixels."
    ) { [weak self] i in
      guard let self else { return }
      if i == Self.exportSizeTitles.count - 1 {
        let size = self.viewportPixelSize
        self.setOutputSize(width: size.width, height: size.height)
      } else if i > 0 {
        let preset = Self.exportSizePresets[i - 1]
        self.setOutputSize(width: preset.width, height: preset.height)
      }
      self.rebuild()
    }
    // The output size commits once on release (live: false): one undo step and autosave per drag.
    number("Width", Float(o.outputWidth), 16...8192, 1920, reset: false, integral: true, live: false) {
      [weak self] in self?.renderer.options.outputWidth = Int($0)
    }
    number("Height", Float(o.outputHeight), 16...8192, 1080, reset: false, integral: true, live: false) {
      [weak self] in self?.renderer.options.outputHeight = Int($0)
    }
    section("Quality")
    number(
      "Samples", Float(o.exportSamples), 1...16384, 128, reset: false, integral: true, scale: .logarithmic,
      help: "Samples per pixel the export renders before it is written."
    ) { [weak self] in self?.renderer.options.exportSamples = UInt32($0) }
    let source = popupRow(
      "Source", ["OIDN denoised", "Raw", "MetalFX display"], exportDenoise ? 0 : (exportRaw ? 1 : 2),
      help:
        "OIDN denoised filters the converged linear render with albedo and normal guides (Render tab › Denoising settings). Raw writes the accumulation as rendered. MetalFX display writes what the MetalFX preview shows."
    ) { [weak self] i in
      self?.exportDenoise = i == 0
      self?.exportRaw = i == 1
    }
    source.setAccessibilityLabel("Export source")
    section("Output")
    popupRow(
      "Format", Self.exportFormats, exportsOpenEXR ? 1 : 0,
      help: "PNG applies the exposure, white balance and tone map. OpenEXR stores linear 32-bit radiance."
    ) { [weak self] i in
      self?.exportsOpenEXR = i == 1
      self?.rebuild()
    }
    toggle("Show in Finder when done", revealsExportInFinder, records: false) { [weak self] on in
      self?.revealsExportInFinder = on
    }
    button("Render and Export…", style: .primary, help: "Renders the scene at the output size and saves it.") {
      [weak self] in
      guard let self else { return }
      self.beginExport(hdr: self.exportsOpenEXR)
    }
    button("Save Preview as PNG…", help: "Saves the viewport as shown, at the preview's resolution.") {
      [weak self] in self?.capturePreview()
    }
    hint(exportsOpenEXR ? "OpenEXR stores linear radiance." : "PNG applies exposure and the tone map.")
  }
}
