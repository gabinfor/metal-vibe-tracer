// Example scenes (File > Open Example Scene, Sources/ExampleScenes.swift), without the network or the archive's
// OBJ files: the catalog against scripts/showcase.json, which archives a scene still needs, archive verification
// and extraction from a locally made zip, and the showcase shot's camera, lighting and emission scaling applied to
// a synthetic emissive OBJ imported through ProjectDocument.appendOBJ, then opened through the studio controller.
@MainActor func fixExampleSceneChecks() throws {
  let manager = FileManager.default
  let folder = testOutputDirectory.appendingPathComponent("example-scenes", isDirectory: true)
  try? manager.removeItem(at: folder)
  try manager.createDirectory(at: folder, withIntermediateDirectories: true)

  // Catalog: every scene names a showcase shot of its own OBJ, and pinned McGuire archive downloads.
  let shots = try ShowcaseShot.bundled()
  func shot(_ name: String) throws -> ShowcaseShot {
    guard let found = shots.first(where: { $0.name == name }) else { throw MaterialLibrary.error("no \(name) shot") }
    return found
  }
  let catalog = ExampleScenes.catalog
  require(catalog.map(\.shot) == ["sponza-noon", "san-miguel-golden", "bistro-exterior-golden", "bistro-interior"],
    "example catalog lists Sponza, San Miguel and both Bistro shots: \(catalog.map(\.shot))")
  for scene in catalog {
    guard let shot = shots.first(where: { $0.name == scene.shot }) else {
      require(false, "showcase.json has the \(scene.shot) shot")
      continue
    }
    require(shot.obj?.hasSuffix("/\(scene.storage)/\(scene.obj)") == true,
      "\(scene.shot) frames the catalog's OBJ (\(shot.obj ?? "none") vs \(scene.storage)/\(scene.obj))")
    require(shot.yaw != nil && shot.distance != nil && shot.target?.count == 3 && shot.exposure != nil
      && shot.sky != nil, "\(scene.shot) sets the camera, sky and exposure")
    require(!scene.archives.isEmpty && Set(scene.archives.map(\.name)).count == scene.archives.count,
      "\(scene.title) has distinct archives")
    for archive in scene.archives {
      require(archive.url.scheme == "https" && archive.url.host == "casual-effects.com"
        && archive.url.path.hasPrefix("/g3d/data10/"), "\(archive.name) downloads from McGuire's archive: \(archive.url)")
      require(archive.sha256.count == 64 && archive.sha256.allSatisfy { "0123456789abcdef".contains($0) },
        "\(archive.name) pins a SHA-256 digest")
      require(archive.bytes > 0 && archive.unpackedBytes >= archive.bytes, "\(archive.name) sizes")
      require(!archive.folder.contains("..") && !archive.folder.hasPrefix("/"), "\(archive.name) extracts inside its scene")
    }
    require(scene.attribution.contains(scene.credit) && scene.attribution.contains(scene.licenseURL.absoluteString),
      "\(scene.title) attribution names the author and links the license")
  }
  require(ExampleScenes.credits.count == 3 && ExampleScenes.credits.contains { $0.hasPrefix("Amazon Lumberyard Bistro © 2017") }
    && ExampleScenes.credits.allSatisfy { $0.contains("creativecommons.org/licenses/by/") },
    "credits list each work once with its license: \(ExampleScenes.credits)")
  let exterior = catalog[2], interior = catalog[3]
  require(exterior.storage == interior.storage
    && Array(exterior.archives.dropFirst()) == Array(interior.archives.dropFirst())
    && exterior.archives.dropFirst().map(\.name) == ["BuildingTextures.zip", "OtherTextures.zip", "PropTextures.zip"],
    "the Bistro exterior and interior share one folder and its three texture archives")
  require(ExampleScenes.megabytes(80_113_441) == "80 MB" && ExampleScenes.megabytes(1_438_403_029) == "1.4 GB",
    "download sizes read in MB and GB")

  // Installed archives: a marker holding the archive's digest; a stale marker does not count.
  let library = ExampleLibrary(root: folder.appendingPathComponent("library", isDirectory: true))
  let textures = ExampleScenes.bistroTextures.reduce(Int64(0)) { $0 + $1.bytes }
  require(library.downloadBytes(catalog[0]) == 80_113_441 && library.missing(interior).count == 4
    && library.downloadBytes(interior) == 21_293_389 + textures, "a fresh library needs every archive")
  try manager.createDirectory(at: library.storage(interior), withIntermediateDirectories: true)
  for archive in interior.archives {
    try Data((archive.sha256 + "\n").utf8).write(to: library.marker(archive, storage: interior.storage))
  }
  require(library.missing(interior).isEmpty && library.downloadBytes(exterior) == 64_186_766
    && library.diskBytes(exterior) == 311_371_057, "after the interior, the exterior needs only Exterior.zip")
  try Data("0\n".utf8).write(to: library.marker(interior.archives[1], storage: interior.storage))
  require(library.missing(interior).map(\.name) == ["BuildingTextures.zip"], "a marker with another digest is stale")
  require(library.objURL(interior).path.hasSuffix("library/bistro/Interior/interior.obj"), "OBJ location")

  // A local archive in the same layout as Interior.zip: an emissive lamp and a plain floor.
  let source = folder.appendingPathComponent("source", isDirectory: true)
  try manager.createDirectory(at: source, withIntermediateDirectories: true)
  try Data("""
    mtllib lamp.mtl
    v 0 0 0
    v 1 0 0
    v 0 1 0
    v 0 0 1
    usemtl Lamp
    f 1 2 3
    usemtl Floor
    f 1 2 4

    """.utf8).write(to: source.appendingPathComponent("lamp.obj"))
  try Data("newmtl Lamp\nKd 0.5 0.5 0.5\nKe 2 1.5 1\nnewmtl Floor\nKd 0.8 0.8 0.8\n".utf8)
    .write(to: source.appendingPathComponent("lamp.mtl"))
  let zip = folder.appendingPathComponent("Lamp.zip")
  let ditto = Process()
  ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
  ditto.arguments = ["-c", "-k", source.path, zip.path]
  try ditto.run()
  ditto.waitUntilExit()
  require(ditto.terminationStatus == 0, "ditto made the test archive")
  let bytes = Int64((try zip.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
  let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
  let archive = ExampleArchive(name: "Lamp.zip", url: URL(string: "https://casual-effects.com/g3d/data10/test")!,
    folder: "Lamp", bytes: bytes, unpackedBytes: bytes, sha256: digest)
  let storage = library.root.appendingPathComponent("lamp", isDirectory: true)
  try manager.createDirectory(at: storage, withIntermediateDirectories: true)
  for (wrong, expected) in [((bytes + 1, digest), "expected"), ((bytes, String(repeating: "0", count: 64)), "SHA-256")] {
    var bad = archive
    (bad.bytes, bad.sha256) = wrong
    var message = ""
    do { try ExampleSceneDownload.installDownloaded(zip, archive: bad, storage: storage, library: library) } catch {
      message = error.localizedDescription
    }
    require(message.contains(expected) && !library.isInstalled(bad, storage: "lamp")
      && !manager.fileExists(atPath: storage.appendingPathComponent("Lamp").path),
      "a mismatched archive is rejected before extraction: \(message)")
  }
  // A leftover file from an interrupted extraction is replaced.
  try manager.createDirectory(at: storage.appendingPathComponent("Lamp"), withIntermediateDirectories: true)
  try Data("stale".utf8).write(to: storage.appendingPathComponent("Lamp/lamp.obj"))
  try ExampleSceneDownload.installDownloaded(zip, archive: archive, storage: storage, library: library)
  let obj = storage.appendingPathComponent("Lamp/lamp.obj")
  let staging = try manager.contentsOfDirectory(atPath: storage.path).filter { $0.hasSuffix(".extracting") }
  require(library.isInstalled(archive, storage: "lamp") && manager.fileExists(atPath: storage.appendingPathComponent("Lamp/lamp.mtl").path)
    && (try? Data(contentsOf: obj)) == (try? Data(contentsOf: source.appendingPathComponent("lamp.obj")))
    && staging.isEmpty,
    "a verified archive extracts into its folder, records its marker and leaves no staging folder")

  // Showcase shots on the imported lamp: the interior's lamps brighten 60x under CIE A, the daylight exterior's go off.
  func imported() throws -> ProjectDocument {
    var p = ProjectDocument()
    var skipped = 0, report: [String] = []
    _ = try p.appendOBJ(try Data(contentsOf: obj), name: "lamp.obj", folder: obj.deletingLastPathComponent(),
      skipped: &skipped, report: &report)
    return p
  }
  func emitters(_ p: ProjectDocument) -> [MaterialXProgram] {
    (p.scenes[6]?.materialX ?? [:]).values.filter { $0.emission != nil }
  }
  let plain = try imported()
  require(emitters(plain).count == 1, "the lamp's Ke becomes one MaterialX emission")
  let evening = try shot("bistro-interior")
  var p = plain
  evening.apply(to: &p)
  require(p.camera.yaw == -1.967 && p.camera.pitch == 0.0564 && p.camera.distance == 1064.002 && p.camera.fov == 60
    && p.camera.target == SIMD3<Float>(1200, 130, -250), "the interior shot sets the camera: \(p.camera)")
  require(p.sky == 2 && p.options.exposure == 1.6 && p.options.lightSpectrum == 2 && p.options.outputWidth == 1600
    && p.options.outputHeight == 900 && p.options.exportSamples == 128 && p.scene == 6,
    "the interior shot sets the sky, exposure, lamp spectrum and export size")
  let lamp = emitters(p)
  let before = emitters(plain)[0]
  if lamp.count == 1, let root = lamp[0].emission {
    let scale = lamp[0].instructions[Int(root)]
    require(scale.code.x == 3 && scale.code.y == before.emission! && Int(scale.code.z) == before.instructions.count
      && lamp[0].instructions[Int(scale.code.z)].value == SIMD4(repeating: 60) && lamp[0].instructions.count == before.instructions.count + 2,
      "emissionScale 60 multiplies the lamp's emission register by a constant 60")
    try lamp[0].validate()
  } else {
    require(false, "the scaled lamp keeps its emission")
  }
  let noon = try shot("bistro-exterior-golden")
  var day = plain
  noon.apply(to: &day)
  require(emitters(day).isEmpty && day.sky == 0 && day.options.sunAzimuth == 133 && day.options.sunElevation == 20
    && day.options.exposure == 2.6, "the daylight exterior shot switches emission off and sets the sun")
  let sponza = try shot("sponza-noon")
  var still = plain
  sponza.apply(to: &still)
  require(emitters(still).count == 1 && emitters(still)[0].instructions.count == before.instructions.count,
    "a shot without emissionScale leaves emission unchanged")
  // A program without room for the two scaling instructions keeps its emission; constant Ke scales too.
  var full = plain
  let slot = full.scenes[6]!.materialX!.first { $0.value.emission != nil }!.key
  while full.scenes[6]!.materialX![slot]!.instructions.count < 63 {
    full.scenes[6]!.materialX![slot]!.instructions.append(GraphInstruction())
  }
  full.scenes[6]!.emissions = [slot: SIMD3(1, 2, 3)]
  require(full.scaleImportedEmission(by: 4) == 1 && full.scenes[6]!.materialX![slot]!.instructions.count == 63
    && full.scenes[6]!.emissions![slot] == SIMD3(4, 8, 12), "a full program is reported and constant emission scales")
  var empty = ProjectDocument()
  require(empty.scaleImportedEmission(by: 0) == 0 && empty.scenes[6] == nil, "no imported scene, nothing to scale")

  // Controller: File > Open Example Scene lists the catalog with download sizes, and an installed scene opens
  // as a new untitled project with its shot and credit, undoably. The lamp stands in for the Bistro interior.
  let examples = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items
    .first { $0.title == "Open Example Scene" }?.submenu
  let entries = examples?.items.filter { $0.action == #selector(StudioController.exampleSceneAction(_:)) } ?? []
  let previousLibrary = controller.exampleLibrary
  controller.exampleLibrary = ExampleLibrary(root: folder.appendingPathComponent("controller", isDirectory: true))
  defer { controller.exampleLibrary = previousLibrary }
  for item in entries { _ = controller.validateMenuItem(item) }
  require(entries.map(\.tag) == [0, 1, 2, 3] && entries.first?.title == "Crytek Sponza — 80 MB download…"
    && entries.last?.title == "Amazon Lumberyard Bistro (interior) — 1.4 GB download…"
    && examples?.items.contains { $0.action == #selector(StudioController.exampleCreditsAction) } == true,
    "File > Open Example Scene lists the scenes with their download sizes: \(entries.map(\.title))")
  let installed = controller.exampleLibrary
  try manager.createDirectory(at: installed.storage(interior), withIntermediateDirectories: true)
  try manager.createDirectory(at: installed.objURL(interior).deletingLastPathComponent(), withIntermediateDirectories: true)
  for name in ["lamp.mtl", "lamp.obj"] {
    try manager.copyItem(at: storage.appendingPathComponent("Lamp/" + name),
      to: installed.objURL(interior).deletingLastPathComponent().appendingPathComponent(name == "lamp.obj" ? "interior.obj" : name))
  }
  for archive in interior.archives {
    try Data((archive.sha256 + "\n").utf8).write(to: installed.marker(archive, storage: interior.storage))
  }
  _ = controller.validateMenuItem(entries[3])
  require(entries[3].title == interior.title, "an installed scene's menu entry shows no download")
  waitUntil({ !controller.isBusy }, seconds: 60)
  // Without an event loop, undo registrations need an explicit group (as in Fix_persistence.swift).
  let history = controller.history, groupsByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer { history.groupsByEvent = groupsByEvent }
  func grouped(_ body: () -> Void) { history.beginUndoGrouping(); body(); history.endUndoGrouping() }
  let previousScene = testRenderer.sceneIndex, previousYaw = testRenderer.yaw
  grouped {
    controller.confirmExampleDownload(interior)
    waitUntil({ !controller.isBusy }, seconds: 60)
  }
  require(testRenderer.sceneIndex == 6 && testRenderer.yaw == -1.967 && testRenderer.distance == 1064.002
    && testRenderer.options.lightSpectrum == 2 && testRenderer.options.exposure == 1.6 && testRenderer.skyMode == 2
    && controller.project.graph?.assets.count == 1 && emitters(controller.snapshot()).count == 1
    && emitters(controller.snapshot())[0].instructions.count == before.instructions.count + 2,
    "an installed example scene opens with its showcase shot, without downloading")
  require(controller.projectURL == nil && controller.documentEdited && controller.project.importReport?.first == interior.attribution
    && controller.history.canUndo, "the example opens as an edited untitled project that carries its credit")
  history.undo()
  waitUntil({ !controller.isBusy }, seconds: 60)
  require(testRenderer.sceneIndex == previousScene && testRenderer.yaw == previousYaw,
    "undo returns to the previous document")
  print("PASS: example scenes (catalog against showcase.json, archive markers, verification and extraction, shot settings and emission scaling, File > Open Example Scene)")
}
try fixExampleSceneChecks()
