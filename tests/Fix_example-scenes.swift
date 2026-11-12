// Example scenes (the scene browser, Sources/ExampleScenes.swift and SceneCatalog.swift), without the network or the archive's
// OBJ files: the catalog against scripts/showcase.json, which archives a scene still needs, archive verification
// and extraction from a locally made zip, and the showcase shot's camera, lighting and emission scaling applied to
// a synthetic emissive OBJ imported through ProjectDocument.appendOBJ, then opened through the studio controller.
@MainActor func fixExampleSceneChecks() throws {
  let manager = FileManager.default
  let folder = testOutputDirectory.appendingPathComponent("example-scenes", isDirectory: true)
  try? manager.removeItem(at: folder)
  try manager.createDirectory(at: folder, withIntermediateDirectories: true)

  // Catalog: every scene names a showcase shot of its own scene file, and pinned archive downloads.
  let shots = try ShowcaseShot.bundled()
  func shot(_ name: String) throws -> ShowcaseShot {
    guard let found = shots.first(where: { $0.name == name }) else { throw MaterialLibrary.error("no \(name) shot") }
    return found
  }
  let entries = SceneCatalog.entries
  require(Set(entries.map(\.id)).count == entries.count && entries.count == 31, "catalog ids are unique")
  require(entries.filter { $0.isDownload && $0.collection == .mcguire }.compactMap(\.shot) == ["sponza-noon", "san-miguel-golden",
    "bistro-exterior-golden", "bistro-interior", "bedroom", "breakfast-room", "buddha", "chinese-dragon",
    "fireplace-room", "living-room"], "download entries keep their shots")
  for entry in entries {
    if case .builtIn(let index) = entry.source {
      require(entry.shot == nil && StudioController.sceneNames.indices.contains(index) && index < 6
        && entry.title == StudioController.sceneNames[index], "\(entry.id) is a built-in scene")
    } else {
      require(shots.contains { $0.name == entry.shot }, "\(entry.id) has its showcase shot")
    }
    require(entry.id.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }, "\(entry.id) is a file-safe id")
  }
  require(SceneCatalog.entry("sponza")?.triangles == 262_266 && SceneCatalog.entry("nope") == nil, "lookup by id")
  let catalog = SceneCatalog.entries.filter { $0.collection == .mcguire }
  require(catalog.map(\.id) == ["sponza", "san-miguel", "bistro-exterior", "bistro-interior", "bedroom",
    "breakfast-room", "buddha", "chinese-dragon", "fireplace-room", "living-room"]
    && catalog.map(\.triangles) == [262_266, 9_963_375, 2_833_329, 1_020_903, 383_504, 269_764, 1_087_304, 871_198,
      142_983, 580_592]
    && catalog.map(\.materials) == [25, 287, 132, 66, 7, 14, nil, nil, 22, 42],
    "the download entries list Sponza, San Miguel, both Bistro shots and the six research models with their specs")
  for scene in catalog {
    guard let shot = shots.first(where: { $0.name == scene.shot }), case .download(let storage, let file, _) = scene.source,
      let credit = scene.credit, let licenseURL = scene.licenseURL, let terms = scene.terms, let attribution = scene.attribution
    else {
      require(false, "\(scene.id) is a download with a showcase shot, credit, license and terms")
      continue
    }
    require(scene.format == .obj && shot.obj?.hasSuffix("/\(storage)/\(file)") == true,
      "\(scene.id) frames the catalog's OBJ (\(shot.obj ?? "none") vs \(storage)/\(file))")
    require(shot.yaw != nil && shot.distance != nil && shot.target?.count == 3 && shot.exposure != nil
      && shot.sky != nil, "\(scene.id) sets the camera, sky and exposure")
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
    require(attribution.contains(credit) && attribution.contains(licenseURL.absoluteString)
      && attribution.hasSuffix(terms), "\(scene.title) attribution names the author, links the license and gives its terms")
  }
  require(entries.filter { !$0.isDownload }.allSatisfy { $0.attribution == nil && $0.archives.isEmpty && $0.credit == nil },
    "built-in and bundled scenes carry no credit and need no archive")
  let credits = SceneCatalog.credits
  require(credits.count == 19 && credits.contains { $0.hasPrefix("Amazon Lumberyard Bistro © 2017") }
    && credits.filter { $0.contains("creativecommons.org/licenses/by/") }.count == 10
    && credits.contains { $0.hasPrefix("Bedroom") && $0.contains("creativecommons.org/licenses/by-sa/4.0/") }
    && credits.filter { $0.contains("graphics.stanford.edu/data/3Dscanrep/") }.count == 2
    && credits.filter { $0.contains("creativecommons.org/publicdomain/zero/1.0/") }.count == 6
    && credits.contains { $0.hasPrefix("The White Room © Jay-Artist. CC BY 3.0") }
    && credits.contains { $0.hasPrefix("Glass of Water aXel. CC0 1.0") },
    "credits list each work once with its license: \(credits)")
  // The Stanford scans carry the repository's non-commercial and good-taste terms; the Bedroom's ShareAlike.
  require(catalog.filter { $0.terms == SceneCatalog.stanfordTerms }.map(\.shot) == ["buddha", "chinese-dragon"]
    && catalog[4].terms?.contains("CC BY-SA 4.0") == true, "per-scene terms: the Stanford scans' and the Bedroom's ShareAlike")
  require(catalog.allSatisfy { $0.attribution?.contains("Morgan McGuire's Computer Graphics Archive (casual-effects.com/data). ") == true
    && $0.attribution?.contains("Bitterli") == false }, "McGuire attributions name McGuire's archive")

  // Bitterli's ten validated scenes: Mitsuba scene files in archives of benedikt-bitterli.me, each extracting into
  // a folder of its archive's name, under a storage folder of its own.
  let bitterliIDs = ["veach-bidir", "veach-ajar", "glass-of-water", "bathroom", "water-caustic", "lamp", "kitchen",
    "white-room", "grey-white-room", "modern-hall"]
  let bitterliArchives = ["veach-bidir", "veach-ajar", "glass-of-water", "bathroom", "water-caustic", "lamp", "kitchen",
    "living-room-2", "living-room", "staircase2"]
  let publicDomain = ["veach-bidir", "veach-ajar", "glass-of-water", "bathroom", "water-caustic", "lamp"]
  let bitterli = entries.filter { $0.collection == .bitterli }
  require(bitterli.map(\.id) == bitterliIDs && entries.suffix(10).map(\.id) == bitterliIDs
    && bitterli.allSatisfy { $0.format == .mitsuba && $0.isDownload && $0.triangles == nil && $0.materials == nil },
    "the ten Bitterli scenes follow the McGuire ones as Mitsuba downloads")
  require(bitterli.map(\.title) == ["Veach, Bidir Room", "Veach, Ajar", "Glass of Water", "Contemporary Bathroom",
    "Water Caustic", "Little Lamp", "Country Kitchen", "The White Room", "The Grey & White Room", "Modern Hall"]
    && bitterli.map(\.credit) == ["Benedikt Bitterli", "Benedikt Bitterli", "aXel", "Mareck", "Benedikt Bitterli", "UP3D",
      "© Jay-Artist", "© Jay-Artist", "© Wig42", "© NewSee2l035"], "titles and credits")
  require(bitterli.map(\.tags) == [["caustics", "glass"], ["glass", "textures"], ["caustics", "glass"],
    ["glass", "textures"], ["caustics", "glass"], ["caustics", "glass"], ["glass", "textures"], ["glass", "textures"],
    ["glass", "textures"], ["glass", "textures"]], "Bitterli tags")
  let publicDomainTerms = "Public domain (CC0). Credit is appreciated but not required."
  var bitterliStorages = Set<String>()
  let mcguireStorages = Set(catalog.compactMap { scene -> String? in
    if case .download(let storage, _, _) = scene.source { return storage }
    return nil
  })
  for (scene, archiveName) in zip(bitterli, bitterliArchives) {
    guard let shot = shots.first(where: { $0.name == scene.shot }), case .download(let storage, let file, let archives) = scene.source,
      let archive = archives.first, let licenseURL = scene.licenseURL, let terms = scene.terms, let attribution = scene.attribution,
      let credit = scene.credit
    else {
      require(false, "\(scene.id) is a download with a showcase shot, credit, license and terms")
      continue
    }
    let sceneFile = scene.id == "water-caustic" ? "water-caustic/scene_v0.6.xml" : "\(archiveName)/scene_v3.xml"
    require(scene.shot == "bitterli-\(scene.id)" && shot.mitsuba?.hasSuffix("/\(file)") == true && file == sceneFile
      && shot.view == "Mitsuba: camera" && shot.obj == nil && shot.usd == nil && shot.scene == nil
      && shot.width == nil && shot.height == nil && shot.samples == nil && shot.depth == nil
      && shot.caustics == (scene.id == "water-caustic" ? 3 : nil), "\(scene.id) shot (\(shot.mitsuba ?? "none") vs \(file))")
    require(archives.count == 1 && archive.name == "\(archiveName).zip" && archive.folder.isEmpty
      && archive.url.scheme == "https" && archive.url.host == "benedikt-bitterli.me"
      && archive.url.path == "/resources/mitsuba/\(archive.name)", "\(scene.id) downloads \(archive.url)")
    require(archive.sha256.count == 64 && archive.sha256.allSatisfy { "0123456789abcdef".contains($0) }
      && archive.bytes > 0 && archive.unpackedBytes > archive.bytes, "\(scene.id) pins its archive")
    require(storage == "bitterli-\(archiveName)" && bitterliStorages.insert(storage).inserted
      && !mcguireStorages.contains(storage), "\(scene.id) has a storage folder of its own: \(storage)")
    if publicDomain.contains(scene.id) {
      require(scene.license == "CC0 1.0" && licenseURL.absoluteString == "https://creativecommons.org/publicdomain/zero/1.0/"
        && terms == publicDomainTerms, "\(scene.id) is CC0")
    } else {
      require(scene.license == "CC BY 3.0" && licenseURL.absoluteString == "https://creativecommons.org/licenses/by/3.0/"
        && terms == SceneCatalog.entry("sponza")?.terms, "\(scene.id) is CC BY 3.0 with the default terms")
    }
    require(attribution == "\(scene.title): \(credit), from Benedikt Bitterli's Rendering Resources "
      + "(benedikt-bitterli.me/resources). \(scene.license ?? "") (\(licenseURL.absoluteString)). \(terms)"
      && !attribution.contains("McGuire"), "\(scene.id) attribution names Bitterli's resources")
  }
  require(bitterli.filter { $0.credit?.hasPrefix("© ") == true }.count == 4 && publicDomain.count == 6,
    "four CC BY works and six CC0 works")
  let exterior = catalog[2], interior = catalog[3]
  let root = ExampleLibrary(root: folder)
  require(root.storage(exterior) == root.storage(interior)
    && Array(exterior.archives.dropFirst()) == Array(interior.archives.dropFirst())
    && exterior.archives.dropFirst().map(\.name) == ["BuildingTextures.zip", "OtherTextures.zip", "PropTextures.zip"],
    "the Bistro exterior and interior share one folder and its three texture archives")
  require(SceneEntry.Collection.allCases.map(\.title) == ["Built-in", "Spectral examples", "McGuire Computer Graphics Archive",
      "Bitterli's Rendering Resources"]
    && SceneEntry.Collection.mcguire.website?.absoluteString == "https://casual-effects.com/data/"
    && SceneEntry.Collection.bitterli.website?.absoluteString == "https://benedikt-bitterli.me/resources/"
    && SceneEntry.Collection.spectral.website == nil && interior.work == "Amazon Lumberyard Bistro",
    "collections name themselves and the archive's website")
  // Tags: the spectral scenes name their effect, textured downloads say so.
  require(SceneCatalog.entries.filter { $0.collection == .spectral }.map(\.tags) == [["spectral", "thin film"], ["spectral", "dispersion"],
    ["spectral", "fog"], ["spectral", "light spectra"], ["spectral", "many lights"]]
    && SceneCatalog.entry("cornell-fog")?.tags == ["fog"] && SceneCatalog.entry("cornell-glass-mirror")?.tags == ["glass"]
    && SceneCatalog.entry("sponza")?.tags == ["textures"] && SceneCatalog.entry("buddha")?.tags.isEmpty == true,
    "entries carry their feature tags")
  // Bundled spectral examples: a showcase shot each, whose stage is under Examples/Spectral and resolves.
  let spectral = SceneCatalog.entries.filter { $0.collection == .spectral }
  require(spectral.map(\.shot) == ["spectral-newton-series", "spectral-abbe-row", "spectral-tyndall-tank",
    "spectral-lamp-spectra", "spectral-lantern-arcade"],
    "spectral examples list Newton's colour series, the Abbe row, the Tyndall tank, the lamp spectra and the lantern arcade")
  for example in spectral {
    let stage = try shot(example.shot ?? "").usd
    guard case .bundled(let path) = example.source else {
      require(false, "\(example.id) is bundled")
      continue
    }
    require(example.format == .usd && stage == path && stage?.hasPrefix("Examples/Spectral/") == true
      && SceneCatalog.bundledURL(path) != nil, "\(example.id) opens a bundled stage (\(stage ?? "none"))")
  }
  require(SceneCatalog.megabytes(80_113_441) == "80 MB" && SceneCatalog.megabytes(1_438_403_029) == "1.4 GB",
    "download sizes read in MB and GB")

  // Installed archives: a marker holding the archive's digest; a stale marker does not count.
  let library = ExampleLibrary(root: folder.appendingPathComponent("library", isDirectory: true))
  let textures = interior.archives.dropFirst().reduce(Int64(0)) { $0 + $1.bytes }
  require(library.downloadBytes(catalog[0]) == 80_113_441 && library.missing(interior).count == 4
    && library.downloadBytes(interior) == 21_293_389 + textures, "a fresh library needs every archive")
  try manager.createDirectory(at: library.storage(interior), withIntermediateDirectories: true)
  for archive in interior.archives {
    try Data((archive.sha256 + "\n").utf8).write(to: library.marker(archive, storage: "bistro"))
  }
  require(library.missing(interior).isEmpty && library.downloadBytes(exterior) == 64_186_766
    && library.diskBytes(exterior) == 311_371_057, "after the interior, the exterior needs only Exterior.zip")
  try Data("0\n".utf8).write(to: library.marker(interior.archives[1], storage: "bistro"))
  require(library.missing(interior).map(\.name) == ["BuildingTextures.zip"], "a marker with another digest is stale")
  require(library.sceneFileURL(interior)?.path.hasSuffix("library/bistro/Interior/interior.obj") == true
    && library.sceneFileURL(spectral[0]) == nil && library.downloadBytes(spectral[0]) == 0
    && library.missing(SceneCatalog.entries[0]).isEmpty, "OBJ location; scenes that are not downloads need nothing")

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
  // The Bedroom scan is Z-up: its shot turns the imported top-level objects -90 degrees about X.
  var upright = plain
  try shot("bedroom").apply(to: &upright)
  let roots = upright.graph?.nodes.filter { $0.parent == nil } ?? []
  let turned = roots.first.map { upright.graph!.worldTransform($0.id).0 * SIMD4<Float>(0, 0, 1, 0) } ?? .zero
  require(!roots.isEmpty && roots.allSatisfy { abs($0.transform.rotationHidden.x + .pi / 2) < 1e-6 }
    && simd_length(SIMD3(turned.x, turned.y, turned.z) - SIMD3(0, 1, 0)) < 1e-5,
    "the bedroom shot stands a Z-up OBJ upright (+Z becomes +Y): \(turned)")
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

  // Controller: File > Credits and Licenses… stays, and an installed scene opens as a new untitled project with its
  // shot and credit, undoably. The lamp stands in for the Bistro interior.
  let fileMenu = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
  let previousLibrary = controller.exampleLibrary
  controller.exampleLibrary = ExampleLibrary(root: folder.appendingPathComponent("controller", isDirectory: true))
  defer { controller.exampleLibrary = previousLibrary }
  require(fileMenu?.items.contains { $0.action == #selector(StudioController.exampleCreditsAction) } == true
    && fileMenu?.items.contains { $0.action == #selector(StudioController.revealExampleScenesAction) } == true,
    "File lists Credits and Licenses… and Show Downloaded Scenes in Finder")
  let installed = controller.exampleLibrary
  // A download scene that is not installed opens nothing: the consent and download flow is the caller's.
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  let untouched = try encoder.encode(controller.project)
  require(!controller.isInstalled(interior) && controller.isInstalled(SceneCatalog.entries[0])
    && controller.isInstalled(spectral[0]), "built-in and bundled scenes are installed; a missing download is not")
  controller.openScene(interior)
  let afterwards = try encoder.encode(controller.project)
  require(!controller.isBusy && controller.exampleDownload == nil && afterwards == untouched,
    "opening a download scene that is not installed does nothing")
  try manager.createDirectory(at: installed.storage(interior), withIntermediateDirectories: true)
  let interiorFile = installed.sceneFileURL(interior)!
  try manager.createDirectory(at: interiorFile.deletingLastPathComponent(), withIntermediateDirectories: true)
  for name in ["lamp.mtl", "lamp.obj"] {
    try manager.copyItem(at: storage.appendingPathComponent("Lamp/" + name),
      to: interiorFile.deletingLastPathComponent().appendingPathComponent(name == "lamp.obj" ? "interior.obj" : name))
  }
  for archive in interior.archives {
    try Data((archive.sha256 + "\n").utf8).write(to: installed.marker(archive, storage: "bistro"))
  }
  waitUntil({ !controller.isBusy }, seconds: 60)
  // Without an event loop, undo registrations need an explicit group (as in Fix_persistence.swift).
  let history = controller.history, groupsByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer { history.groupsByEvent = groupsByEvent }
  func grouped(_ body: () -> Void) { history.beginUndoGrouping(); body(); history.endUndoGrouping() }
  let previousScene = testRenderer.sceneIndex, previousYaw = testRenderer.yaw
  grouped {
    require(controller.isInstalled(interior), "the scene is installed once its archives are present")
    // Opening asks before discarding edits; this document has none to lose.
    controller.associate(nil, edited: false, replaced: false)
    controller.openScene(interior)
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

  // Downloading from the scene browser, from local archives: a digest mismatch ends with the error in the details pane
  // and the Download button back, a cancel is reported, and a correct archive installs and opens the scene.
  let downloadLibrary = ExampleLibrary(root: folder.appendingPathComponent("browser-download", isDirectory: true))
  controller.exampleLibrary = downloadLibrary
  let payload = folder.appendingPathComponent("payload", isDirectory: true)
  try manager.createDirectory(at: payload, withIntermediateDirectories: true)
  try manager.copyItem(at: source.appendingPathComponent("lamp.obj"), to: payload.appendingPathComponent("interior.obj"))
  try manager.copyItem(at: source.appendingPathComponent("lamp.mtl"), to: payload.appendingPathComponent("lamp.mtl"))
  let payloadZip = folder.appendingPathComponent("Interior.zip")
  let payloadDitto = Process()
  payloadDitto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
  payloadDitto.arguments = ["-c", "-k", payload.path, payloadZip.path]
  try payloadDitto.run()
  payloadDitto.waitUntilExit()
  let payloadBytes = Int64((try payloadZip.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
  let payloadDigest = SHA256.hash(data: try Data(contentsOf: payloadZip)).map { String(format: "%02x", $0) }.joined()
  guard case .download(let interiorStorage, let interiorPath, _) = interior.source else { return require(false, "a download scene") }
  func localInterior(sha256: String) -> SceneEntry {
    var local = interior
    local.source = .download(storage: interiorStorage, file: interiorPath, archives: [ExampleArchive(
      name: "Interior.zip", url: payloadZip, folder: "Interior", bytes: payloadBytes, unpackedBytes: payloadBytes, sha256: sha256)])
    return local
  }
  let mismatched = localInterior(sha256: String(repeating: "0", count: 64)), correct = localInterior(sha256: payloadDigest)
  let scenes = controller.scenes, browser = scenes.browser
  controller.showStartScreen()
  controller.browseScenes()
  browser.filter = .all; browser.search = ""
  browser.selection = SceneCatalog.entry(interior.id)
  controller.beginSceneDownload(mismatched)
  require(controller.downloadingScene?.id == interior.id && browser.control("scene-download-cancel")?.isHidden == false
    && browser.control("scene-download")?.isHidden == true, "a download shows its progress in the details pane")
  waitUntil({ controller.downloadingScene == nil }, seconds: 60)
  let failure = (browser.control("scene-download-error") as? NSTextField)?.stringValue ?? ""
  require(controller.exampleDownload == nil && !controller.isInstalled(mismatched) && failure.contains("SHA-256")
    && browser.control("scene-download-error")?.isHidden == false && browser.control("scene-download")?.isHidden == false
    && browser.control("scene-download-cancel")?.isHidden == true && controller.startScreen != nil && scenes.isVisible,
    "a digest mismatch shows its error in the pane, restores Download and leaves the scene missing: \(failure)")
  // A download goes on while the Scenes window is hidden, and shows its progress for its card when it is shown again.
  controller.beginSceneDownload(mismatched)
  scenes.hide()
  browser.selection = SceneCatalog.entry("sponza")
  controller.browseScenes()
  let again = browser
  again.selection = SceneCatalog.entry(interior.id)
  require(controller.downloadingScene?.id == interior.id && controller.exampleDownload?.isCancelled == false && scenes.isVisible
    && again.control("scene-download-cancel")?.isHidden == false && again.control("scene-download")?.isHidden == true,
    "a download keeps running while the Scenes window is hidden and shows its progress when it is shown again")
  controller.cancelSceneDownload()
  waitUntil({ controller.downloadingScene == nil }, seconds: 60)
  require(controller.status.stringValue.contains("cancelled") && !controller.isInstalled(mismatched)
    && again.control("scene-download")?.isHidden == false, "Cancel ends the download and restores Download")
  // A failure on the second archive keeps the first installed; the scene is missing only the second.
  let partialLibrary = ExampleLibrary(root: folder.appendingPathComponent("browser-partial", isDirectory: true))
  controller.exampleLibrary = partialLibrary
  var partial = mismatched
  let first = ExampleArchive(name: "Interior.zip", url: payloadZip, folder: "Interior", bytes: payloadBytes,
    unpackedBytes: payloadBytes, sha256: payloadDigest)
  var second = first
  (second.name, second.folder, second.sha256) = ("Textures.zip", "Textures", String(repeating: "0", count: 64))
  partial.source = .download(storage: interiorStorage, file: interiorPath, archives: [first, second])
  again.reload()
  controller.beginSceneDownload(partial)
  waitUntil({ controller.downloadingScene == nil }, seconds: 60)
  let partialError = (again.control("scene-download-error") as? NSTextField)?.stringValue ?? ""
  require(partialLibrary.isInstalled(first, storage: interiorStorage) && !partialLibrary.isInstalled(second, storage: interiorStorage)
    && partialLibrary.missing(partial).map(\.name) == ["Textures.zip"] && partialLibrary.downloadBytes(partial) == second.bytes
    && partialError.contains("SHA-256") && again.control("scene-download")?.isHidden == false
    && (again.control("scene-download") as? NSButton)?.title == "Download \(SceneCatalog.megabytes(partialLibrary.downloadBytes(interior)))",
    "a failed second archive leaves the first installed, shows its error and restores Download: \(partialError)")
  controller.exampleLibrary = downloadLibrary
  controller.associate(nil, edited: false, replaced: false)
  grouped {
    controller.beginSceneDownload(correct)
    waitUntil({ controller.downloadingScene == nil }, seconds: 60)
    waitUntil({ !controller.isBusy }, seconds: 60)
  }
  require(controller.isInstalled(correct) && controller.startScreen == nil && testRenderer.sceneIndex == 6
    && controller.project.importReport?.first == interior.attribution && !scenes.isVisible,
    "a verified download with the Scenes window shown and no document loaded installs the scene, opens it with its credit and hides the window")
  history.undo()
  waitUntil({ !controller.isBusy }, seconds: 60)
  // A download that finishes over a document with unsaved changes asks nothing and replaces nothing: the Scenes window
  // stays with the scene selected and Open showing. A download that finishes while the window is hidden only reports
  // it, even over an unedited document. One that finishes over an unedited document with the window shown opens.
  let overLibrary = ExampleLibrary(root: folder.appendingPathComponent("browser-download-over", isDirectory: true))
  controller.exampleLibrary = overLibrary
  controller.associate(nil, edited: true, replaced: false)
  var discardPrompts = 0
  controller.unsavedChangesAnswer = { respond in discardPrompts += 1; respond(.alertThirdButtonReturn) }
  let editedScene = testRenderer.sceneIndex
  controller.browseScenes()
  let over = browser
  over.selection = SceneCatalog.entry("sponza")
  require(over.control("scene-show-in-finder")?.isHidden == true, "Show in Finder is hidden for a download that is missing")
  over.selection = correct
  controller.beginSceneDownload(correct)
  waitUntil({ controller.downloadingScene == nil }, seconds: 60)
  waitUntil({ !controller.isBusy }, seconds: 60)
  require(controller.isInstalled(correct) && discardPrompts == 0 && controller.documentEdited && scenes.isVisible
    && testRenderer.sceneIndex == editedScene && controller.project.importReport?.first != interior.attribution
    && over.selection?.id == interior.id && over.control("scene-open")?.isHidden == false
    && over.control("scene-download")?.isHidden == true
    && controller.status.stringValue == "\(interior.title) is downloaded; open it from the scene browser.",
    "a download finishing over an edited document does not prompt or replace it, selects the scene and shows Open: \(controller.status.stringValue)")
  require(over.control("scene-show-in-finder")?.isHidden == false, "Show in Finder is visible for an installed download")
  scenes.hide()
  let closedLibrary = ExampleLibrary(root: folder.appendingPathComponent("browser-download-closed", isDirectory: true))
  controller.exampleLibrary = closedLibrary
  controller.associate(nil, edited: false, replaced: false)
  controller.browseScenes()
  browser.selection = SceneCatalog.entry("sponza")
  controller.beginSceneDownload(correct)
  scenes.hide()
  waitUntil({ controller.downloadingScene == nil }, seconds: 60)
  waitUntil({ !controller.isBusy }, seconds: 60)
  require(controller.isInstalled(correct) && discardPrompts == 0 && !controller.documentEdited && !scenes.isVisible
    && testRenderer.sceneIndex == editedScene && controller.project.importReport?.first != interior.attribution
    && browser.selection?.id == interior.id && browser.control("scene-open")?.isHidden == false
    && controller.status.stringValue == "\(interior.title) is downloaded; open it from the scene browser.",
    "a download finishing while the Scenes window is hidden does not open the scene, selects it and reports it in the status line")
  let shownLibrary = ExampleLibrary(root: folder.appendingPathComponent("browser-download-shown", isDirectory: true))
  controller.exampleLibrary = shownLibrary
  controller.browseScenes()
  grouped {
    controller.beginSceneDownload(correct)
    waitUntil({ controller.downloadingScene == nil }, seconds: 60)
    waitUntil({ !controller.isBusy }, seconds: 60)
  }
  require(controller.isInstalled(correct) && discardPrompts == 0 && testRenderer.sceneIndex == 6
    && controller.project.importReport?.first == interior.attribution && !scenes.isVisible,
    "a download finishing over an unedited document with the Scenes window shown opens the scene and hides the window")
  history.undo()
  waitUntil({ !controller.isBusy }, seconds: 60)
  controller.unsavedChangesAnswer = nil
  controller.associate(nil, edited: false, replaced: false)
  controller.exampleLibrary = downloadLibrary
  // Bundled thumbnails: one 480 x 270 image per scene but the exempt Stanford scans, listed in scene-ids.txt.
  require(SceneCatalog.thumbnailExempt == Set(["buddha", "chinese-dragon"] + bitterliIDs),
    "the Stanford scans and the Bitterli scenes, until their thumbnails are rendered, are exempt from thumbnails")
  let thumbnailIDs = SceneCatalog.entries.map(\.id).filter { !SceneCatalog.thumbnailExempt.contains($0) }
  let listed = SceneCatalog.bundledURL("Examples/Thumbnails/scene-ids.txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
  require(listed?.split(separator: "\n").map(String.init) == thumbnailIDs && thumbnailIDs.count == 19,
    "scene-ids.txt lists the scenes with a thumbnail")
  for entry in SceneCatalog.entries {
    let url = SceneCatalog.bundledURL("Examples/Thumbnails/\(entry.id).jpg")
    let size = url.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
      .map { ($0.width, $0.height) }
    if SceneCatalog.thumbnailExempt.contains(entry.id) {
      require(size == nil && SceneBrowserView.thumbnail(entry) == nil, "\(entry.id) ships no thumbnail")
    } else {
      require(size?.0 == 480 && size?.1 == 270, "\(entry.id) has a 480 x 270 thumbnail (\(String(describing: size)))")
      require(SceneBrowserView.thumbnail(entry) != nil, "\(entry.id) shows its thumbnail")
    }
  }
  print("PASS: example scenes (catalog against showcase.json, archive markers, verification and extraction, shot settings and emission scaling, the File menu's credits, downloading from the scene browser)")
}
try fixExampleSceneChecks()
