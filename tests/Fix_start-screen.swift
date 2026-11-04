// Launch start state (AppDelegate, StartScreenView): background shader compilation with on-demand
// kernel groups, the empty start screen, the kept and restorable last-session autosave, and the
// activity strip of project operations.
@MainActor func fixStartScreenChecks() throws {
  let folder = studioDirectory.absoluteURL.appendingPathComponent("fix-start-screen", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let savedAutosaveURL = controller.autosaveURL
  controller.autosaveURL = folder.appendingPathComponent("Autosave.vtrace")
  defer { controller.autosaveURL = savedAutosaveURL }
  func idle() { waitUntil({ !controller.isBusy }, seconds: 120) }

  // The launch path: core pipelines compile off the main thread with counted progress; the optional
  // groups compile in the background when a mode needs them, which falls back until then.
  let progress = OperationProgress("Preparing GPU shaders")
  let source = metalSource, mathMode = shaderCompileOptions().mathMode
  final class Outcome: @unchecked Sendable {
    let lock = NSLock()
    var result: Result<PathTracerRenderer.CompiledShaders, Error>?
    var onMain = true
    var done: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
  }
  let outcome = Outcome()
  DispatchQueue.global(qos: .userInitiated).async {
    let result = Result {
      try PathTracerRenderer.compileShaders(device: gpu, source: source, mathMode: mathMode, groups: [], progress: progress)
    }
    outcome.lock.lock(); outcome.result = result; outcome.onMain = Thread.isMainThread; outcome.lock.unlock()
  }
  waitUntil({ outcome.done }, seconds: 600)
  let compiled = outcome.result, compiledOnMain = outcome.onMain
  let launched = try PathTracerRenderer(device: gpu, shaders: compiled!.get())
  require(!compiledOnMain && progress.snapshot.fraction == 1 && progress.snapshot.detail == "9 of 9",
    "launch compiles the nine core pipelines off the main thread with counted progress")
  require(launched.sceneKernels.pt == nil && launched.meshKernels.splat == nil && launched.meshKernels.spmis == nil,
    "the optional kernel groups are not compiled at launch")
  launched.sceneIndex = 6
  launched.indirectReuse = .restirPT
  require(launched.activeIndirectReuse == .restirGI, "ReSTIR PT falls back to GI until its kernels are compiled")
  launched.requestKernels()
  require(launched.sceneShaders.compiling == [.pt] && launched.sceneShaders.progress != nil,
    "a mode that needs ReSTIR PT starts compiling only that group in the background")
  waitUntil({ launched.sceneShaders.compiling.isEmpty }, seconds: 600)
  require(launched.meshKernels.pt != nil && launched.proceduralKernels.pt != nil && launched.activeIndirectReuse == .restirPT
    && launched.sceneShaders.progress == nil && launched.meshKernels.splat == nil,
    "the compiled ReSTIR PT group is installed for both libraries")
  let export = try PathTracerRenderer(device: gpu, sharing: launched)
  require(export.sceneShaders === launched.sceneShaders && export.meshKernels.pt != nil,
    "renderers created with sharing: share the background-compiled groups")
  print("PASS: fix-start-screen background core compile, on-demand kernel groups and their fallbacks")

  // A last session on disk.
  try controller.restore(ProjectDocument())
  testRenderer.options.exposure = 1.75
  try controller.flushAutosave(to: controller.autosaveURL)
  let lastSession = try Data(contentsOf: controller.autosaveURL)
  try? FileManager.default.removeItem(at: controller.previousAutosaveURL)

  // The start screen: nothing renders, only open and import commands apply, quitting keeps the autosave.
  controller.showStartScreen()
  controller.view.layoutSubtreeIfNeeded()
  guard let start = controller.startScreen else { return require(false, "the start screen is shown") }
  require(controller.viewport.isPaused && controller.viewport.isHidden && start.frame.width > 300,
    "the start screen covers the paused viewport")
  if let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
    controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: studioDirectory.appendingPathComponent("start-screen.png"))
  }
  require(start.button("start-restore")?.superview?.isHidden == false && start.button("start-open")?.isEnabled == true
    && start.button("start-scene-1")?.title == StudioController.sceneNames[1],
    "the start screen offers open, import, built-in scenes and restoring the autosaved session")
  // Example scenes: every bundled example, and every download example with its remaining download size.
  let downloads = ExampleScenes.catalog.indices.map { start.button("start-download-\($0)")?.title ?? "" }
  require(SpectralExamples.catalog.indices.allSatisfy { start.button("start-example-\($0)")?.title == SpectralExamples.catalog[$0].title }
    && zip(downloads, ExampleScenes.catalog).allSatisfy { title, scene in
      title == StartScreenView.downloadTitle(scene, controller.exampleLibrary) && title.hasPrefix(scene.shortTitle) }
    && StartScreenView.describe(.example(4)) == "Opening Lantern Arcade",
    "the start screen offers the bundled and downloadable example scenes (\(downloads))")
  func valid(_ selector: Selector) -> Bool {
    controller.validateMenuItem(NSMenuItem(title: "", action: selector, keyEquivalent: ""))
  }
  require(valid(#selector(StudioController.openAction)) && valid(#selector(StudioController.importOBJAction))
    && !valid(#selector(StudioController.saveAction)) && !valid(#selector(StudioController.exportAction))
    && !valid(#selector(StudioController.undoAction)), "the start screen enables only open and import commands")
  testRenderer.options.exposure = 3
  controller.changed(reset: false)
  controller.saveTimer?.invalidate()
  try controller.flushAutosave()
  require((try? Data(contentsOf: controller.autosaveURL)) == lastSession,
    "quitting from the start screen keeps the last session's autosave")

  // Restore Last Session loads the autosave and keeps the file.
  controller.performStartAction(.restoreSession)
  require(controller.projectOperationInProgress && !controller.activityStrip.isHidden,
    "restoring runs off the main thread with the activity strip shown")
  idle()
  require(controller.startScreen == nil && testRenderer.options.exposure == 1.75 && !controller.viewport.isPaused
    && controller.activityStrip.isHidden, "restoring the last session dismisses the start screen")
  controller.autosaveQueue.sync {}
  require(FileManager.default.fileExists(atPath: controller.autosaveURL.path)
    && !FileManager.default.fileExists(atPath: controller.previousAutosaveURL.path),
    "a restored session keeps its autosave in place")

  // Another start action keeps the last session as the recovery copy before autosaving anew.
  controller.showStartScreen()
  controller.performStartAction(.builtInScene(1))
  idle()
  controller.autosaveQueue.sync {}
  require(controller.startScreen == nil && testRenderer.sceneIndex == 1 && controller.projectURL == nil
    && !controller.documentEdited, "a built-in scene opens as a new untitled project")
  require(!testRenderer.denoiserEnabled, "MetalFX is off in a new project")
  // The labelled scene selector lists the built-in scenes, the bundled examples and the downloads in groups.
  func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { views(type, in: $0) }
  }
  controller.page = 0
  controller.rebuild()
  let picker = views(ActionPopup.self, in: controller.stack).first { $0.accessibilityLabel() == "Scene" }
  let headers = picker?.menu?.items.filter(\.isSectionHeader).map(\.title) ?? []
  let captions = views(NSTextField.self, in: controller.stack).map(\.stringValue)
  require(picker?.selectedTag() == 1 && headers == ["Built-in scenes", "Example scenes", "Download examples"]
    && picker?.menu?.items.filter { $0.tag >= StudioController.exampleTag && !$0.isSectionHeader }.count
      == SpectralExamples.catalog.count + ExampleScenes.catalog.count
    && captions.prefix(2).contains("Scene"), "the inspector's Scene selector is labelled and groups built-in, example and download scenes")
  if let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
    controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: studioDirectory.appendingPathComponent("inspector-scene.png"))
  }
  require((try? Data(contentsOf: controller.previousAutosaveURL)) == lastSession,
    "starting another document keeps the last session as Autosave-previous.vtrace")

  // Saving reports its phase in the activity strip until it finishes.
  var saved = false
  controller.beginSaveProject(folder.appendingPathComponent("strip.vtrace")) { saved = $0 }
  require(!controller.activityStrip.isHidden && controller.activityLabel.stringValue.contains("strip.vtrace"),
    "a save shows its phase in the activity strip")
  idle()
  require(saved && controller.activityStrip.isHidden && controller.activity == nil, "the activity strip clears when the save ends")

  controller.viewport.isPaused = true
  controller.saveTimer?.invalidate()
  try controller.restore(ProjectDocument())
  controller.associate(nil, edited: false, replaced: true)
  controller.saveTimer?.invalidate()
  controller.history.removeAllActions()
  print("PASS: fix-start-screen empty start state, kept and restored autosave, activity strip")
}
try fixStartScreenChecks()
