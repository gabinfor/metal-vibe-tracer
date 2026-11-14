import Cocoa

// The Export inspector page: project commands, output size, samples and source.
extension StudioController {
  func filePanel() {
    heading("Project")
    text(projectURL?.lastPathComponent ?? "Untitled project")
    button("New project") { [weak self] in
      self?.confirmDiscardingChanges { self?.newProject() }
    }
    button("Open project…") { [weak self] in self?.openProject() }
    button("Save project") { [weak self] in self?.saveProject() }
    button("Save project as…") { [weak self] in self?.saveProject(asNew: true) }
    text(
      "Projects embed textures, the environment image, and imported geometry. Changes are also autosaved locally; the main menu offers to restore them at the next launch."
    )
    heading("Export")
    number("Output width", Float(renderer.options.outputWidth), 16...8192, 1920, reset: false, integral: true) {
      [weak self] in self?.renderer.options.outputWidth = Int($0)
    }
    number("Output height", Float(renderer.options.outputHeight), 16...8192, 1080, reset: false, integral: true) {
      [weak self] in self?.renderer.options.outputHeight = Int($0)
    }
    number("Export samples", Float(renderer.options.exportSamples), 1...16384, 128, reset: false, integral: true) {
      [weak self] in self?.renderer.options.exportSamples = UInt32($0)
    }
    let exportSource = exportDenoise ? 0 : (exportRaw ? 1 : 2)
    popup([
      "Export source: OIDN offline (configured)",
      "Export source: raw accumulation",
      "Export source: MetalFX display",
    ], exportSource, label: "Export source") { [weak self] i in
      self?.exportDenoise = i == 0
      self?.exportRaw = i == 1
    }
    button("Render and export PNG…") { [weak self] in self?.beginExport(hdr: false) }
    button("Render and export HDR OpenEXR…") { [weak self] in self?.beginExport(hdr: true) }
    button("Capture current preview PNG…") { [weak self] in self?.capturePreview() }
    text(
      "OIDN filters the converged linear render with albedo and normal guides. EXR stores linear floating-point radiance. PNG uses the current exposure, white balance and tone map."
    )
  }
}
