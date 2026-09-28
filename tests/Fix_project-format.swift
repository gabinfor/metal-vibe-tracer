// Project format 3 (R-45, R-74): one content-addressed asset table, inline in .vtrace files
// and stored as AutosaveAssets sidecars by autosaves. Locally generated fixtures only.
@MainActor func fixProjectFormatChecks() throws {
  let manager = FileManager.default
  let folder = studioDirectory.absoluteURL.appendingPathComponent("fix-project-format", isDirectory: true)
  try? manager.removeItem(at: folder)
  try manager.createDirectory(at: folder, withIntermediateDirectories: true)
  let history = controller.history
  let savedAutosaveURL = controller.autosaveURL
  controller.autosaveURL = folder.appendingPathComponent("controller/Autosave.vtrace")
  defer { controller.autosaveURL = savedAutosaveURL }
  func idle() { waitUntil({ !controller.isBusy }, seconds: 60) }
  // Explicit undo groups, as in Fix_persistence: the suite has no event loop grouping.
  func grouped(_ body: () throws -> Void) rethrows {
    history.beginUndoGrouping()
    defer { history.endUndoGrouping() }
    try body()
  }
  let wasGroupingByEvent = history.groupsByEvent
  history.groupsByEvent = false
  defer { history.groupsByEvent = wasGroupingByEvent }
  func reset() throws {
    controller.saveTimer?.invalidate()
    try controller.restore(ProjectDocument())
    controller.associate(nil, edited: false, replaced: true)
    controller.saveTimer?.invalidate()
    history.removeAllActions()
  }
  func rejects(_ what: String, _ body: () throws -> Void) {
    do {
      try body()
      require(false, "\(what) is rejected")
    } catch {}
  }
  func rejects(_ what: String, json object: Any) {
    rejects(what) {
      let data = try JSONSerialization.data(withJSONObject: object)
      _ = try ProjectDocument.decodeProject(data, near: nil)
    }
  }
  func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
  func address(_ data: Data?) -> UInt { data.map { $0.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) } } ?? 0 }
  func occurrences(_ text: String, _ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }
  // JSONEncoder writes "/" as "\/".
  func escaped(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "/", with: "\\/") }
  func noise(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Data((0..<count).map { _ in
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return UInt8(truncatingIfNeeded: state >> 56)
    })
  }
  func noisePNG(_ side: Int, seed: UInt64) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 3,
      hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 3, bitsPerPixel: 24)!
    let bytes = noise(side * side * 3, seed: seed)
    bytes.copyBytes(to: rep.bitmapData!, count: bytes.count)
    return rep.representation(using: .png, properties: [:])!
  }
  func gridOBJ(_ n: Int) -> String {
    var lines = ["o Grid"]
    for y in 0...n { for x in 0...n { lines.append("v \(Float(x) / Float(n)) \(Float(y) / Float(n)) 0") } }
    for y in 0..<n {
      for x in 0..<n {
        let a = y * (n + 1) + x + 1
        lines.append("f \(a) \(a + 1) \(a + n + 2) \(a + n + 1)")
      }
    }
    return lines.joined(separator: "\n")
  }
  func equivalent(_ a: ProjectDocument, _ b: ProjectDocument) -> Bool {
    guard a.environmentData == b.environmentData, a.environmentName == b.environmentName,
      a.meshName == b.meshName, a.scene == b.scene, a.camera.yaw == b.camera.yaw,
      sameBytes(a.triangles, b.triangles), Set(a.scenes.keys) == Set(b.scenes.keys)
    else { return false }
    if let x = a.graph {
      guard let y = b.graph, x.sameGeometry(as: y), x.sameBindings(as: y) else { return false }
    } else if b.graph != nil {
      return false
    }
    return a.scenes.allSatisfy { key, state in b.scenes[key].map { state.sameResources(as: $0) } ?? false }
  }
  func sidecars(_ autosave: URL) -> [String: UInt64] {
    let store = ProjectAssets.sidecarFolder(near: autosave)
    var result: [String: UInt64] = [:]
    for name in (try? manager.contentsOfDirectory(atPath: store.path)) ?? [] {
      let attributes = try? manager.attributesOfItem(atPath: store.appendingPathComponent(name).path)
      result[name] = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
    return result
  }

  // Fixture: three MaterialX shaders sharing one image, two maps, an environment and a
  // 20,000-triangle scene-graph mesh.
  let sharedPNG = noisePNG(256, seed: 1), mapA = noisePNG(384, seed: 2), mapB = noisePNG(384, seed: 3)
  try sharedPNG.write(to: folder.appendingPathComponent("shared.png"))
  let library = try MaterialXImporter.read(
    Data(
      """
      <materialx version="1.39"><texcoord name="texcoord" type="vector2"/>
      <image name="shared" type="color3" colorspace="srgb_texture"><input name="file" type="filename" value="shared.png"/><input name="texcoord" type="vector2" nodename="texcoord"/></image>
      <open_pbr_surface name="A" type="surfaceshader"><input name="base_color" type="color3" nodename="shared"/></open_pbr_surface>
      <open_pbr_surface name="B" type="surfaceshader"><input name="base_color" type="color3" nodename="shared"/><input name="specular_roughness" type="float" value="0.7"/></open_pbr_surface>
      <open_pbr_surface name="C" type="surfaceshader"><input name="base_color" type="color3" nodename="shared"/><input name="specular_roughness" type="float" value="0.2"/></open_pbr_surface>
      </materialx>
      """.utf8), baseURL: folder, source: "Shared.mtlx")
  require(
    library.materials.count == 3 && library.materials.allSatisfy({ $0.images.count == 1 && $0.images[0].data == sharedPNG }),
    "fixture shaders share one image: \(library.report)")
  let environment = try Data(contentsOf: exrURL)
  var document = ProjectDocument()
  _ = try document.appendOBJ(gridOBJ(100), name: "Grid.obj")
  var state = document.scenes[6] ?? SceneState()
  state.materialX = [8: library.materials[0], 9: library.materials[1], 10: library.materials[2]]
  state.maps[16] = mapA
  state.names[16] = "a.png"
  state.maps[20] = mapB
  state.names[20] = "b.png"
  document.scenes[6] = state
  document.environmentData = environment
  document.environmentName = "hdr-roundtrip.exr"
  try document.validate()
  require(document.graph?.assets.first?.triangles.count == 20_000, "fixture mesh has 20,000 triangles")

  // Old-format fixtures: JSONEncoder over the unchanged document types is the version 1/2
  // writer, byte for byte.
  let v2 = try JSONEncoder().encode(document)
  let v2Text = String(decoding: v2, as: UTF8.self)
  require(document.version == 2 && !v2Text.contains("sha256:") && !v2Text.contains("assetTable"),
    "fixture uses the version 2 layout")
  let fromV2 = try ProjectDocument.decodeProject(v2, near: nil)
  try fromV2.validate()
  require(equivalent(document, fromV2) && fromV2.version == 2, "version 2 project opens unchanged")
  let v2Images = (8...10).map { fromV2.scenes[6]?.materialX?[$0]?.images[0].data }
  require(Set(v2Images.map(address)).count == 1, "identical version 2 payloads share one buffer after opening")
  var legacy = ProjectDocument()
  legacy.version = 1
  legacy.scene = 6
  legacy.triangles = try OBJMesh.load(gridOBJ(20))
  legacy.meshName = "Grid.obj"
  var legacyState = SceneState()
  legacyState.surfaces = Array(legacyState.surfaces.prefix(8))
  legacyState.objects = Array(legacyState.objects.prefix(8))
  legacyState.maps = Array(legacyState.maps.prefix(32))
  legacyState.names = Array(legacyState.names.prefix(32))
  legacyState.maps[28] = mapA
  legacyState.names[28] = "a.png"
  legacy.scenes[6] = legacyState
  let fromV1 = try ProjectDocument.decodeProject(JSONEncoder().encode(legacy), near: nil)
  try fromV1.validate()
  require(equivalent(legacy, fromV1) && fromV1.version == 1, "version 1 flat-mesh project opens unchanged")
  let v1Resaved = try fromV1.encodeForSaving()
  let fromV1Resaved = try ProjectDocument.decodeProject(v1Resaved, near: nil)
  require(equivalent(legacy, fromV1Resaved) && fromV1Resaved.version == 3
    && object(v1Resaved)["triangleData"] is String, "version 1 project resaves as format 3 with a binary flat mesh")
  print("PASS: fix-project-format version 1 and 2 projects open and resave (R-45, R-74)")

  // R-74: the shared image is stored once per project; the file stays self-contained.
  let v3 = try fromV2.encodeForSaving()
  let v3Text = String(decoding: v3, as: UTF8.self)
  let fromV3 = try ProjectDocument.decodeProject(v3, near: nil)
  try fromV3.validate()
  let table = object(v3)["assetTable"] as? [String: [String: Any]] ?? [:]
  let sharedKey = ProjectAssets.reference(for: sharedPNG)
  require(fromV3.version == 3 && equivalent(document, fromV3), "format 3 project round-trips")
  require(
    occurrences(v2Text, escaped(sharedPNG)) == 3 && occurrences(v3Text, escaped(sharedPNG)) == 1
      && occurrences(v3Text, sharedKey) == 4 && table[sharedKey]?["data"] is String,
    "a MaterialX image shared by three programs is stored once")
  require(table.count == 5 && table.values.allSatisfy({ $0["data"] is String }),
    "images, environment and mesh are inline table entries (\(table.count))")
  let v3Images = (8...10).map { fromV3.scenes[6]?.materialX?[$0]?.images[0].data }
  require(Set(v3Images.map(address)).count == 1, "references to one payload decode to one shared buffer")
  print("fix-project-format .vtrace bytes: version 2 \(v2.count), format 3 \(v3.count)")
  // Shared payloads count once against the embedded-asset limit.
  var sharedHeavy = ProjectDocument()
  var heavyState = SceneState()
  let big = Data(count: 100 * 1024 * 1024)
  for i in 0..<6 { heavyState.maps[i] = big }
  sharedHeavy.scenes[0] = heavyState
  try sharedHeavy.validate()
  require(sharedHeavy.embeddedAssetBytes == big.count, "a payload shared by six maps counts once")
  print("PASS: fix-project-format shared MaterialX image stored once per self-contained project (R-74)")

  // R-45: autosave revisions write the JSON plus only payloads that are not stored yet.
  let autosave = folder.appendingPathComponent("autosave/Autosave.vtrace")
  let expected = try document.encodeForAutosave()
  let first = try document.writeAutosave(to: autosave, grace: 0)
  require(first.assetsWritten == expected.payloads.count && first.assetsWritten == 5 && first.assetsReused == 0
    && sidecars(autosave).count == 5, "first autosave stores each distinct payload once as a sidecar")
  let firstFiles = sidecars(autosave)
  var edited = document
  edited.camera.yaw += 0.25
  let second = try edited.writeAutosave(to: autosave, grace: 0)
  require(second.assetsWritten == 0 && second.assetBytesWritten == 0 && second.assetsReused == 5
    && sidecars(autosave) == firstFiles, "a camera-only revision rewrites no sidecar")
  let mapC = noisePNG(128, seed: 4)
  edited.scenes[6]?.maps[24] = mapC
  let third = try edited.writeAutosave(to: autosave, grace: 0)
  require(third.assetsWritten == 1 && third.assetBytesWritten == mapC.count && third.assetsRemoved == 0,
    "a new map writes exactly one sidecar")
  // A sidecar damaged in place is detected and rewritten instead of being referenced.
  let mapCFile = ProjectAssets.sidecarFolder(near: autosave).appendingPathComponent(
    ProjectAssets.digest(ProjectAssets.reference(for: mapC)))
  var damagedMap = mapC
  damagedMap[damagedMap.count / 2] ^= 0xFF
  let handle = try FileHandle(forWritingTo: mapCFile)
  try handle.write(contentsOf: damagedMap)
  try handle.close()
  try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30)], ofItemAtPath: mapCFile.path)
  let repaired = try edited.writeAutosave(to: autosave, grace: 0)
  require(repaired.assetsWritten == 1 && repaired.assetBytesWritten == mapC.count && (try? Data(contentsOf: mapCFile)) == mapC,
    "a damaged sidecar is rewritten")
  let autosaveJSON = try Data(contentsOf: autosave)
  let restored = try ProjectDocument.decodeProject(autosaveJSON, near: autosave)
  require(equivalent(edited, restored), "sidecar autosave restores the document")
  require(!String(decoding: autosaveJSON, as: UTF8.self).contains(escaped(mapA)), "autosave JSON holds no payload bytes")
  do {
    _ = try ProjectDocument.decodeProject(autosaveJSON, near: nil)
    require(false, "sidecar autosave without its folder is rejected")
  } catch {
    require(error.localizedDescription.contains(ProjectAssets.sidecarFolderName), "missing-folder message names it")
  }
  print(
    "fix-project-format autosave bytes per revision: version 2 layout \(v2.count) every revision; "
      + "format 3 first \(first.bytesWritten), camera-only \(second.bytesWritten), new map \(third.bytesWritten)")
  require(second.bytesWritten * 20 < v2.count, "a camera-only autosave writes under 5% of the version 2 bytes")
  print("PASS: fix-project-format autosave sidecars written once per content (R-45)")

  // Garbage collection keeps every payload a recovery copy references.
  let recovery = folder.appendingPathComponent("recovery", isDirectory: true)
  let current = recovery.appendingPathComponent("Autosave.vtrace")
  let previous = recovery.appendingPathComponent("Autosave-previous.vtrace")
  func only(_ map: Data) -> ProjectDocument {
    var d = ProjectDocument()
    var s = SceneState()
    s.maps[4] = map
    d.scenes[0] = s
    return d
  }
  let (x, y, z, w) = (noise(4096, seed: 10), noise(4096, seed: 11), noise(4096, seed: 12), noise(4096, seed: 13))
  func stored(_ data: Data) -> Bool {
    manager.fileExists(
      atPath: ProjectAssets.sidecarFolder(near: current).appendingPathComponent(
        ProjectAssets.digest(ProjectAssets.reference(for: data))).path)
  }
  _ = try only(x).writeAutosave(to: current, grace: 0)
  let replaced = try only(z).writeAutosave(to: current, grace: 0)
  require(replaced.assetsRemoved == 1 && !stored(x) && stored(z), "an unreferenced sidecar is collected")
  let unrestorable = try StudioController.preserveUnrestorableAutosave(current)
  _ = try only(y).writeAutosave(to: previous, grace: 0)
  // A damaged file that still names a digest keeps that sidecar (the scan does not parse).
  let v = noise(4096, seed: 14)
  _ = try only(v).writeAutosave(to: recovery.appendingPathComponent("scratch.vtrace"), grace: 0)
  let damaged = recovery.appendingPathComponent("Autosave-unrestorable-damaged.vtrace")
  try Data("{\"broken\": \"\(ProjectAssets.reference(for: v))".utf8).write(to: damaged)
  try manager.removeItem(at: recovery.appendingPathComponent("scratch.vtrace"))
  let store = ProjectAssets.sidecarFolder(near: current)
  let orphan = store.appendingPathComponent(String(repeating: "ab", count: 32))
  let fresh = store.appendingPathComponent(String(repeating: "cd", count: 32))
  let foreign = store.appendingPathComponent("notes.txt")
  for file in [orphan, fresh, foreign] { try Data("x".utf8).write(to: file) }
  // Every sidecar except `fresh` is older than the grace period below.
  for name in try manager.contentsOfDirectory(atPath: store.path) where name != fresh.lastPathComponent {
    try manager.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: store.appendingPathComponent(name).path)
  }
  let collected = try only(w).writeAutosave(to: current, grace: 60)
  require(
    collected.assetsRemoved == 1 && !manager.fileExists(atPath: orphan.path) && manager.fileExists(atPath: fresh.path)
      && manager.fileExists(atPath: foreign.path) && stored(w) && stored(y) && stored(z) && stored(v),
    "collection keeps recovery, unrestorable, damaged-file and recent sidecars and ignores foreign files")
  let keptPrevious = try ProjectDocument.decodeProject(Data(contentsOf: previous), near: previous)
  let keptUnrestorable = try ProjectDocument.decodeProject(Data(contentsOf: unrestorable), near: unrestorable)
  require(keptPrevious.scenes[0]?.maps[4] == y && keptUnrestorable.scenes[0]?.maps[4] == z,
    "Autosave-previous and Autosave-unrestorable copies still open after collection")
  // A damaged or missing sidecar fails the restore instead of loading wrong bytes.
  let zFile = store.appendingPathComponent(ProjectAssets.digest(ProjectAssets.reference(for: z)))
  var corrupt = z
  corrupt[0] ^= 1
  try corrupt.write(to: zFile)
  rejects("a sidecar whose bytes do not match its digest") {
    _ = try ProjectDocument.decodeProject(Data(contentsOf: unrestorable), near: unrestorable)
  }
  try manager.removeItem(at: zFile)
  rejects("a missing sidecar") {
    _ = try ProjectDocument.decodeProject(Data(contentsOf: unrestorable), near: unrestorable)
  }
  print("PASS: fix-project-format sidecar collection keeps recovery copies (R-45)")

  // Validation bounds the table and every reference before any payload or GPU resource.
  var small = ProjectDocument()
  _ = try small.appendOBJ(gridOBJ(2), name: "Small.obj")
  var smallState = small.scenes[6] ?? SceneState()
  let smallMap = noise(1000, seed: 20)
  smallState.maps[16] = smallMap
  small.scenes[6] = smallState
  let valid = object(try small.encodeForSaving())
  let mapKey = ProjectAssets.reference(for: smallMap)
  require((try? ProjectDocument.decodeProject(JSONSerialization.data(withJSONObject: valid), near: nil)) != nil,
    "re-serialized format 3 fixture opens")
  func mutated(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
    var copy = valid
    change(&copy)
    return copy
  }
  func setMap(_ value: Any) -> [String: Any] {
    mutated { root in
      var scenes = root["scenes"] as? [String: Any] ?? [:]
      var scene = scenes["6"] as? [String: Any] ?? [:]
      var maps = scene["maps"] as? [Any] ?? []
      maps[16] = value
      scene["maps"] = maps
      scenes["6"] = scene
      root["scenes"] = scenes
    }
  }
  func setEntry(_ key: String, _ entry: [String: Any]?, rename: String? = nil) -> [String: Any] {
    mutated { root in
      var table = root["assetTable"] as? [String: Any] ?? [:]
      table[key] = nil
      table[rename ?? key] = entry
      root["assetTable"] = table
    }
  }
  let entry = (valid["assetTable"] as? [String: [String: Any]])?[mapKey] ?? [:]
  let size = entry["size"] as? Int ?? 0
  rejects("a dangling map reference", json: setMap(ProjectAssets.referencePrefix + String(repeating: "0", count: 64)))
  rejects("inline base64 in a format 3 data position", json: setMap(smallMap.base64EncodedString()))
  let badKey = ProjectAssets.referencePrefix + String(repeating: "z", count: 64)
  rejects("a malformed asset key", json: setEntry(mapKey, entry, rename: badKey))
  rejects("an upper-case digest", json: setEntry(mapKey, entry, rename: mapKey.uppercased()))
  var oversized = entry
  oversized["size"] = ProjectAssets.maximumEntryBytes + 1
  rejects("an oversized entry", json: setEntry(mapKey, oversized))
  var short = entry
  short["size"] = size - 1
  rejects("an entry whose data does not match its size", json: setEntry(mapKey, short))
  var tampered = entry
  var flipped = smallMap
  flipped[0] ^= 1
  tampered["data"] = flipped.base64EncodedString()
  rejects("an entry whose bytes do not match its digest", json: setEntry(mapKey, tampered))
  rejects("a table without the referenced entry", json: setEntry(mapKey, nil))
  let meshReference = (valid["meshData"] as? [String: String])?.values.first ?? ""
  rejects("a mesh reference to an unknown asset", json: mutated { $0["meshData"] = [UUID().uuidString: meshReference] })
  let ragged = noise(100, seed: 21)
  rejects("a mesh payload that is not whole triangles", json: mutated { root in
    var table = root["assetTable"] as? [String: Any] ?? [:]
    let key = ProjectAssets.reference(for: ragged)
    table[key] = ["size": ragged.count, "data": ragged.base64EncodedString()]
    root["assetTable"] = table
    root["meshData"] = (root["meshData"] as? [String: String] ?? [:]).mapValues { _ in key }
  })
  rejects("a version 2 file with an asset table", json: mutated { $0["version"] = 2 })
  rejects("a format 3 file without an asset table", json: mutated { $0["assetTable"] = nil })
  rejects("a newer format", json: mutated { $0["version"] = 4 })
  var v2Object = object(try JSONEncoder().encode(small))
  v2Object["scenes"] = (setMap(mapKey)["scenes"])
  rejects("a reference in a version 2 file", json: v2Object)
  let limitEntries = (0..<3).reduce(into: [String: ProjectAssets.Entry]()) { table, i in
    table[ProjectAssets.reference(for: Data([UInt8(i)]))] = ProjectAssets.Entry(size: ProjectAssets.maximumEntryBytes)
  }
  do {
    _ = try ProjectAssets.load(limitEntries, sidecars: nil)
    require(false, "a table above the aggregate limit is rejected")
  } catch {
    require(error.localizedDescription.contains("exceed"), "the aggregate bound is checked before any payload is read")
  }
  var crowded: [String: ProjectAssets.Entry] = [:]
  crowded.reserveCapacity(ProjectAssets.maximumEntries + 1)
  for i in 0...ProjectAssets.maximumEntries { crowded[String(i)] = ProjectAssets.Entry(size: 0) }
  rejects("a table with too many entries") { _ = try ProjectAssets.load(crowded, sidecars: nil) }
  // Through the controller: a rejected file allocates nothing and keeps the document.
  try reset()
  let dangling = folder.appendingPathComponent("dangling.vtrace")
  try JSONSerialization.data(withJSONObject: setMap(ProjectAssets.referencePrefix + String(repeating: "1", count: 64)))
    .write(to: dangling)
  let live = testRenderer.materials
  grouped {
    controller.beginOpenProject(dangling)
    idle()
  }
  require(testRenderer.materials === live && controller.projectURL == nil
    && controller.errorMessage?.contains("reference") == true,
    "opening a file with a dangling reference fails before resources are prepared")
  print("PASS: fix-project-format table, digest and reference validation")

  // Studio paths: open version 2, save and reopen format 3, autosave and restore, presets.
  let v2URL = folder.appendingPathComponent("legacy-v2.vtrace"), v3URL = folder.appendingPathComponent("saved-v3.vtrace")
  try v2.write(to: v2URL)
  grouped {
    controller.beginOpenProject(v2URL)
    idle()
  }
  require(controller.projectURL == v2URL && testRenderer.materials.payloads[16] == mapA
    && testRenderer.materials.materialX[9]?.images[0].data == sharedPNG, "Studio opens a version 2 project")
  var saved: Bool?
  controller.beginSaveProject(v3URL) { saved = $0 }
  idle()
  let savedObject = object(try Data(contentsOf: v3URL))
  require(saved == true && savedObject["assetTable"] != nil && savedObject["version"] as? Int == 3, "Studio saves format 3")
  try reset()
  grouped {
    controller.beginOpenProject(v3URL)
    idle()
  }
  require(controller.projectURL == v3URL && testRenderer.materials.payloads[20] == mapB
    && testRenderer.materials.materialX[10]?.images[0].data == sharedPNG
    && controller.project.graph?.assets.first?.triangles.count == 20_000, "Studio reopens its format 3 save")
  testRenderer.yaw += 0.2
  controller.changed(reset: false)
  try controller.flushAutosave()
  let before = sidecars(controller.autosaveURL)
  testRenderer.yaw += 0.2
  controller.changed(reset: false)
  try controller.flushAutosave()
  require(before.count == 5 && sidecars(controller.autosaveURL) == before, "Studio autosave revisions reuse their sidecars")
  let yaw = testRenderer.yaw
  try reset()
  controller.restoreAutosave()
  idle()
  require(testRenderer.yaw == yaw && testRenderer.materials.payloads[16] == mapA
    && controller.projectURL == v3URL && controller.documentEdited, "Studio restores a sidecar autosave")
  var preset = ProjectDocument()
  var presetState = SceneState()
  presetState.materialX = [1: library.materials[1]]
  presetState.maps[4] = mapC
  preset.scenes[0] = presetState
  let presetURL = folder.appendingPathComponent("Shared.vmat")
  try preset.encodedProject().json.write(to: presetURL)
  grouped {
    controller.beginLoadMaterial(from: presetURL, slot: 12)
    idle()
  }
  require(testRenderer.materials.materialX[12]?.images[0].data == sharedPNG && testRenderer.materials.payloads[48] == mapC,
    "format 3 material preset loads")
  try reset()
  print("PASS: fix-project-format Studio open, save, autosave, restore and presets")
}
try fixProjectFormatChecks()
