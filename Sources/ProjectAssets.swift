import CryptoKit
import Darwin
import Foundation
import Synchronization

// Project format 3 (R-45, R-74). Every embedded payload (texture maps, MaterialX images,
// the environment image and mesh triangles) is stored once in a content-addressed asset
// table keyed by "sha256:<64 lowercase hex digits>" (SHA-256, FIPS 180-4, via CryptoKit).
// The document names a payload by that key wherever versions 1 and 2 embedded base64, so
// bytes shared by several MaterialX programs, maps or scenes are written once. A .vtrace
// file (and a material preset) keeps every payload inline as base64 and stays a single
// self-contained file. Autosaves and recovery copies list only sizes and keep each payload
// as a binary sidecar file in AutosaveAssets/ beside them, named by its digest and written
// once, so a new autosave revision writes the small JSON plus any payloads not yet stored.
//
// JSON layout added by format 3 (all other keys are unchanged from version 2):
//   "assetTable":   {"sha256:<hex>": {"size": <bytes>, "data": "<base64>"}}  ("data" absent: sidecar)
//   "meshData":     {"<MeshAsset.id>": "sha256:<hex>"}  scene-graph mesh triangles
//   "triangleData": "sha256:<hex>"                      legacy flat mesh triangles
// Mesh payloads are the MeshTriangle array's bytes: 32 little-endian Float32 values per
// triangle in field order a, b, c, na, nb, nc, uvab, uvc. The corresponding "triangles"
// arrays in the document are empty.
enum ProjectAssets {
  static let formatVersion = 3
  static let sidecarFolderName = "AutosaveAssets"
  static let referencePrefix = "sha256:"
  static let triangleBytes = MemoryLayout<MeshTriangle>.stride
  // Bounds checked before any payload is decoded, read or uploaded. An entry holds at most
  // the environment (256 MiB); images count against ProjectDocument.embeddedAssetLimit and
  // meshes against the stored (graph) and legacy flat triangle limits.
  static let maximumEntryBytes = 256 * 1024 * 1024
  static let maximumMeshBytes = 2 * SceneLimits.triangles * triangleBytes
  static let maximumTableBytes = ProjectDocument.embeddedAssetLimit + maximumMeshBytes
  // Seven scenes of maps and MaterialX images, the environment, the flat mesh and at most
  // one entry per stored triangle for mesh assets.
  static let maximumEntries =
    7 * SceneLimits.materials * (4 + SceneLimits.graphImages) + 2 + SceneLimits.triangles
  // Unreferenced sidecars younger than this are kept, so payloads another writer stored
  // but has not referenced yet survive a collection.
  static let sidecarGracePeriod: TimeInterval = 600

  enum WireKey: String, CodingKey { case version, assetTable, meshData, triangleData }
  struct Entry: Codable {
    var size: Int
    var data: String?
  }

  static func invalid(_ detail: String) -> Error {
    MaterialLibrary.error("Invalid or unsupported project data: \(detail)")
  }
  static func reference(for data: Data) -> String {
    let hex = Array("0123456789abcdef".utf8)
    var text = Array(referencePrefix.utf8)
    for byte in SHA256.hash(data: data) {
      text.append(hex[Int(byte >> 4)])
      text.append(hex[Int(byte & 15)])
    }
    return String(decoding: text, as: UTF8.self)
  }
  static func isDigest<S: Collection>(_ bytes: S) -> Bool where S.Element == UInt8 {
    bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func isReference(_ key: String) -> Bool {
    key.hasPrefix(referencePrefix) && isDigest(key.utf8.dropFirst(referencePrefix.utf8.count))
  }
  static func digest(_ reference: String) -> String { String(reference.dropFirst(referencePrefix.count)) }
  static func sidecarFolder(near url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(sidecarFolderName, isDirectory: true)
  }

  static func triangleData(_ triangles: [MeshTriangle]) -> Data { triangles.withUnsafeBytes { Data($0) } }
  static func triangles(_ data: Data) throws -> [MeshTriangle] {
    guard data.count % triangleBytes == 0, data.count / triangleBytes <= SceneLimits.triangles else {
      throw invalid("a mesh payload has an invalid size.")
    }
    let zero = SIMD4<Float>(repeating: 0)
    var result = [MeshTriangle](
      repeating: MeshTriangle(a: zero, b: zero, c: zero, na: zero, nb: zero, nc: zero, uvab: zero, uvc: zero),
      count: data.count / triangleBytes)
    result.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
    return result
  }

  // Same bytes; views of one buffer compare without reading it.
  static func identical(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    let shared = a.withUnsafeBytes { x in b.withUnsafeBytes { y in x.baseAddress == y.baseAddress } }
    return shared || a == b
  }
  static func distinct(_ payloads: [Data]) -> [Data] {
    var bySize: [Int: [Data]] = [:]
    var result: [Data] = []
    for data in payloads where !(bySize[data.count]?.contains(where: { identical($0, data) }) ?? false) {
      bySize[data.count, default: []].append(data)
      result.append(data)
    }
    return result
  }

  // Encoding: each payload is hashed once per encode, also when several positions share it.
  final class Collector: Sendable {
    private struct State {
      var payloads: [String: Data] = [:]
      // Keyed by buffer address and size; the retained Data keeps the address unique.
      var identities: [SIMD2<UInt>: (key: String, data: Data)] = [:]
    }
    private let state = Mutex(State())
    var payloads: [String: Data] { state.withLock { $0.payloads } }
    func intern(_ data: Data) -> String {
      // Data of at most 14 bytes is stored inline; its address is a temporary.
      let address = data.count > 64 ? data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) } : 0
      let identity = SIMD2(address, UInt(data.count))
      if address != 0, let known = state.withLock({ $0.identities[identity] }) { return known.key }
      let key = ProjectAssets.reference(for: data)
      state.withLock { state in
        if state.payloads[key] == nil { state.payloads[key] = data }
        if address != 0 { state.identities[identity] = (key, data) }
      }
      return key
    }
  }
  // Decoding: the loaded table of a format-3 file; nil for versions 1 and 2.
  final class Resolver: Sendable {
    let sidecars: URL?
    let table = Mutex<[String: Data]?>(nil)
    init(sidecars: URL?) { self.sidecars = sidecars }
    func data(_ decoder: Decoder) throws -> Data {
      let text = try decoder.singleValueContainer().decode(String.self)
      guard let table = table.withLock({ $0 }) else {
        // Versions 1 and 2 embed base64 (which never contains ':').
        guard let data = Data(base64Encoded: text) else { throw ProjectAssets.invalid("malformed embedded data.") }
        return data
      }
      guard let data = table[text] else {
        throw ProjectAssets.invalid("a reference names no entry of the asset table.")
      }
      return data
    }
  }
  static let resolverKey = CodingUserInfoKey(rawValue: "VibeTracer.ProjectAssets.Resolver")

  // Validates the whole table (count, keys, sizes, total) before reading any payload, then
  // loads each one and checks its size and digest.
  static func load(_ entries: [String: Entry], sidecars: URL?) throws -> [String: Data] {
    guard entries.count <= maximumEntries else { throw invalid("too many assets.") }
    var total = 0
    for (key, entry) in entries {
      guard isReference(key), (0...maximumEntryBytes).contains(entry.size) else {
        throw invalid("an asset key or size is out of range.")
      }
      if let text = entry.data, text.utf8.count != (entry.size + 2) / 3 * 4 {
        throw invalid("an embedded asset's length does not match its size.")
      }
      total += entry.size
    }
    guard total <= maximumTableBytes else { throw invalid("the embedded assets exceed the project limit.") }
    var table: [String: Data] = [:]
    table.reserveCapacity(entries.count)
    for (key, entry) in entries {
      let data: Data
      if let text = entry.data {
        guard let decoded = Data(base64Encoded: text) else { throw invalid("malformed embedded data.") }
        data = decoded
      } else {
        guard let sidecars else {
          throw MaterialLibrary.error(
            "This project stores its images and meshes in a separate \(sidecarFolderName) folder, which is not available here.")
        }
        data = try readSidecar(sidecars.appendingPathComponent(digest(key)), size: entry.size)
      }
      guard data.count == entry.size, reference(for: data) == key else {
        throw MaterialLibrary.error("An embedded image or mesh is damaged (its checksum does not match).")
      }
      table[key] = data
    }
    return table
  }
  static func readSidecar(_ url: URL, size: Int) throws -> Data {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, values?.fileSize == size else {
      throw MaterialLibrary.error(
        "An image or mesh of this autosave is missing from \(sidecarFolderName) (\(url.lastPathComponent)).")
    }
    let data = try Data(contentsOf: url)
    guard data.count == size else { throw MaterialLibrary.error("\(url.lastPathComponent) changed while it was read.") }
    return data
  }

  // Sidecar files this process wrote or verified, by path: file number and modification
  // date, so a file changed in place or replaced is verified again.
  private struct SidecarToken: Equatable {
    var file: UInt64
    var modified: Date
  }
  private static let verifiedSidecars = Mutex<[String: SidecarToken]>([:])
  private static func sidecarToken(_ file: URL, size: Int) -> SidecarToken? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? NSNumber)?.intValue == size,
      let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    return SidecarToken(file: number, modified: modified)
  }
  static func noteSidecar(_ file: URL, size: Int) {
    guard let token = sidecarToken(file, size: size) else { return }
    verifiedSidecars.withLock { $0[file.path] = token }
  }
  // True when `file` already holds the payload: its bytes are hashed once per process (and
  // again after any change), so a damaged sidecar is rewritten instead of referenced. A
  // fresh date protects a reused sidecar from another writer's collection until the new
  // JSON references it.
  static func reuseSidecar(_ file: URL, digest: String, size: Int) -> Bool {
    guard let token = sidecarToken(file, size: size) else { return false }
    if verifiedSidecars.withLock({ $0[file.path] }) != token {
      guard let data = try? Data(contentsOf: file), data.count == size,
        reference(for: data) == referencePrefix + digest
      else { return false }
    }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    noteSidecar(file, size: size)
    return true
  }

  struct EncodedFile: Encodable {
    var document: ProjectDocument
    var meshData: [String: String]
    var triangleData: String?
    var collector: Collector
    var inline: Bool
    func encode(to encoder: Encoder) throws {
      try document.encode(to: encoder)
      var container = encoder.container(keyedBy: WireKey.self)
      if !meshData.isEmpty { try container.encode(meshData, forKey: .meshData) }
      try container.encodeIfPresent(triangleData, forKey: .triangleData)
      // Written last: the document's payloads were interned while it was encoded.
      let table = collector.payloads.mapValues { Entry(size: $0.count, data: inline ? $0.base64EncodedString() : nil) }
      try container.encode(table, forKey: .assetTable)
    }
  }
  struct DecodedFile: Decodable {
    var document: ProjectDocument
    init(from decoder: Decoder) throws {
      guard let key = ProjectAssets.resolverKey, let resolver = decoder.userInfo[key] as? Resolver else {
        throw ProjectAssets.invalid("no asset resolver.")
      }
      let container = try decoder.container(keyedBy: WireKey.self)
      let version = try container.decode(Int.self, forKey: .version)
      let tabled = version >= 3
      guard (1...formatVersion).contains(version), container.contains(.assetTable) == tabled,
        tabled || !(container.contains(.meshData) || container.contains(.triangleData))
      else { throw MaterialLibrary.error("Invalid or unsupported project data.") }
      var table: [String: Data] = [:]
      if tabled {
        table = try load(container.decode([String: Entry].self, forKey: .assetTable), sidecars: resolver.sidecars)
        resolver.table.withLock { $0 = table }
      }
      var document = try ProjectDocument(from: decoder)
      guard tabled else {
        document.shareIdenticalPayloads()
        self.document = document
        return
      }
      if let reference = try container.decodeIfPresent(String.self, forKey: .triangleData) {
        guard document.triangles.isEmpty, let data = table[reference] else {
          throw invalid("the flat mesh reference is dangling.")
        }
        document.triangles = try triangles(data)
      }
      let meshes = try container.decodeIfPresent([String: String].self, forKey: .meshData) ?? [:]
      if !meshes.isEmpty {
        guard var graph = document.graph, meshes.count <= graph.assets.count else {
          throw invalid("mesh references name no scene-graph asset.")
        }
        var indices: [UUID: Int] = [:]
        for (i, asset) in graph.assets.enumerated() where indices[asset.id] == nil { indices[asset.id] = i }
        var stored = 0
        for (id, reference) in meshes {
          guard let uuid = UUID(uuidString: id), let i = indices[uuid], graph.assets[i].triangles.isEmpty,
            let data = table[reference]
          else { throw invalid("a mesh reference is dangling.") }
          stored += data.count / triangleBytes
          guard stored <= SceneLimits.triangles else { throw invalid("stored meshes exceed the triangle limit.") }
          graph.assets[i].triangles = try triangles(data)
        }
        document.graph = graph
      }
      self.document = document
    }
  }

  // Garbage collection of AutosaveAssets/ next to recovery files in `folder`. A sidecar is
  // kept while any .vtrace/.json file in the folder mentions its digest (Autosave,
  // Autosave-previous, Autosave-unrestorable-* and flushed copies alike), while it is in
  // `keeping`, or while it is younger than `grace`. If any file cannot be scanned, nothing
  // is deleted. Returns the number of sidecars removed.
  static func collectSidecars(in folder: URL, keeping: Set<String>, grace: TimeInterval) -> Int {
    let manager = FileManager.default
    let store = folder.appendingPathComponent(sidecarFolderName, isDirectory: true)
    guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
      let sidecars = try? manager.contentsOfDirectory(
        at: store, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
    else { return 0 }
    var referenced = Set(keeping.map(digest))
    for file in files where ["vtrace", "json"].contains(file.pathExtension.lowercased()) {
      guard let digests = referencedDigests(in: file) else { return 0 }
      referenced.formUnion(digests)
    }
    let cutoff = Date().addingTimeInterval(-grace)
    var removed = 0
    for sidecar in sidecars {
      let name = sidecar.lastPathComponent
      guard isDigest(name.utf8), !referenced.contains(name),
        let values = try? sidecar.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
        values.isRegularFile == true, let modified = values.contentModificationDate, modified <= cutoff
      else { continue }
      if (try? manager.removeItem(at: sidecar)) != nil { removed += 1 }
    }
    return removed
  }
  private struct Stamp: Equatable {
    var size: Int
    var modified: Date
    var file: UInt64
  }
  // Scans keyed by path; a rewritten or replaced file has a new stamp and is scanned again.
  private static let scans = Mutex<[String: (stamp: Stamp, digests: Set<String>)]>([:])
  // Every "sha256:<hex>" in the file, found without parsing it, so damaged or older files
  // are handled conservatively. nil when the file cannot be read.
  static func referencedDigests(in file: URL) -> Set<String>? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let size = (attributes[.size] as? NSNumber)?.intValue,
      let modified = attributes[.modificationDate] as? Date,
      let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    else { return nil }
    let stamp = Stamp(size: size, modified: modified, file: number)
    if let known = scans.withLock({ $0[file.path] }), known.stamp == stamp { return known.digests }
    guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
    let digests = referencedDigests(in: data)
    scans.withLock { scans in
      if scans.count > 256 { scans.removeAll() }
      scans[file.path] = (stamp, digests)
    }
    return digests
  }
  static func referencedDigests(in data: Data) -> Set<String> {
    var found = Set<String>()
    let prefix = Array(referencePrefix.utf8)
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var offset = 0
      while offset < raw.count, let hit = memmem(base + offset, raw.count - offset, prefix, prefix.count) {
        let start = base.distance(to: UnsafeRawPointer(hit)) + prefix.count
        if start + 64 <= raw.count {
          let candidate = UnsafeRawBufferPointer(start: base + start, count: 64)
          if isDigest(candidate) { found.insert(String(decoding: candidate, as: UTF8.self)) }
        }
        offset = start
      }
    }
    return found
  }
}

// Bytes written by one autosave revision (the measurement the R-45 checks report).
struct AutosaveWriteReport {
  var jsonBytes = 0
  var assetBytesWritten = 0
  var assetsWritten = 0
  var assetsReused = 0
  var assetsRemoved = 0
  var bytesWritten: Int { jsonBytes + assetBytesWritten }
}

extension ProjectDocument {
  // Format-3 bytes without the save limits (material presets). `inline` embeds every
  // payload; otherwise the table lists sizes and the payloads are returned for sidecars.
  func encodedProject(inline: Bool = true) throws -> (json: Data, payloads: [String: Data]) {
    let collector = ProjectAssets.Collector()
    var copy = self
    copy.version = ProjectAssets.formatVersion
    var triangleData: String?
    if !copy.triangles.isEmpty {
      triangleData = collector.intern(ProjectAssets.triangleData(copy.triangles))
      copy.triangles = []
    }
    var meshData: [String: String] = [:]
    if var graph = copy.graph {
      for i in graph.assets.indices where !graph.assets[i].triangles.isEmpty {
        meshData[graph.assets[i].id.uuidString] = collector.intern(ProjectAssets.triangleData(graph.assets[i].triangles))
        graph.assets[i].triangles = []
      }
      copy.graph = graph
    }
    let encoder = JSONEncoder()
    encoder.dataEncodingStrategy = .custom { data, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(collector.intern(data))
    }
    let json = try encoder.encode(
      ProjectAssets.EncodedFile(
        document: copy, meshData: meshData, triangleData: triangleData, collector: collector, inline: inline))
    return (json, collector.payloads)
  }
  // Decodes project format 1, 2 or 3. `url` locates a format-3 autosave's AutosaveAssets
  // sidecars; nil accepts only inline payloads. Table bounds, digests and references are
  // checked here, before validate() and before any GPU resource is prepared.
  static func decodeProject(_ data: Data, near url: URL?) throws -> ProjectDocument {
    guard let key = ProjectAssets.resolverKey else { throw ProjectAssets.invalid("no asset resolver.") }
    let decoder = JSONDecoder()
    decoder.userInfo[key] = ProjectAssets.Resolver(sidecars: url.map(ProjectAssets.sidecarFolder(near:)))
    decoder.dataDecodingStrategy = .custom { decoder in
      guard let resolver = decoder.userInfo[key] as? ProjectAssets.Resolver else {
        throw ProjectAssets.invalid("no asset resolver.")
      }
      return try resolver.data(decoder)
    }
    return try decoder.decode(ProjectAssets.DecodedFile.self, from: data).document
  }
  // Writes an autosave or recovery copy: payloads missing from AutosaveAssets/ first (each
  // atomically), then the JSON atomically, then unreferenced sidecars are collected. A
  // crash at any point leaves the previous JSON and every sidecar it references intact.
  func writeAutosave(to url: URL, grace: TimeInterval = ProjectAssets.sidecarGracePeriod) throws
    -> AutosaveWriteReport
  {
    let (json, payloads) = try encodeForAutosave()
    let manager = FileManager.default
    let store = ProjectAssets.sidecarFolder(near: url)
    try manager.createDirectory(at: store, withIntermediateDirectories: true)
    var report = AutosaveWriteReport()
    for (key, data) in payloads {
      let digest = ProjectAssets.digest(key)
      let file = store.appendingPathComponent(digest)
      // Content-addressed: a stored payload is never rewritten.
      if ProjectAssets.reuseSidecar(file, digest: digest, size: data.count) {
        report.assetsReused += 1
      } else {
        try data.write(to: file, options: .atomic)
        ProjectAssets.noteSidecar(file, size: data.count)
        report.assetsWritten += 1
        report.assetBytesWritten += data.count
      }
    }
    try json.write(to: url, options: .atomic)
    report.jsonBytes = json.count
    report.assetsRemoved = ProjectAssets.collectSidecars(
      in: url.deletingLastPathComponent(), keeping: Set(payloads.keys), grace: grace)
    return report
  }
  // The environment and every scene's maps and MaterialX images, shared ones repeated.
  var imagePayloads: [Data] {
    var result: [Data] = environmentData.map { [$0] } ?? []
    for state in scenes.values {
      result += state.maps.compactMap { $0 }
      for program in (state.materialX ?? [:]).values { result += program.images.map(\.data) }
    }
    return result
  }
  // Identical payloads decoded separately (versions 1 and 2) share one buffer, so undo
  // snapshots and the next save hold each once.
  mutating func shareIdenticalPayloads() {
    var canonical: [Int: [Data]] = [:]
    func share(_ data: inout Data) {
      if let same = canonical[data.count]?.first(where: { ProjectAssets.identical($0, data) }) {
        data = same
      } else {
        canonical[data.count, default: []].append(data)
      }
    }
    if var data = environmentData {
      share(&data)
      environmentData = data
    }
    for key in Array(scenes.keys) {
      guard var state = scenes[key] else { continue }
      for i in state.maps.indices {
        guard var data = state.maps[i] else { continue }
        share(&data)
        state.maps[i] = data
      }
      if var programs = state.materialX {
        for slot in Array(programs.keys) {
          guard var program = programs[slot] else { continue }
          for i in program.images.indices { share(&program.images[i].data) }
          programs[slot] = program
        }
        state.materialX = programs
      }
      scenes[key] = state
    }
  }
}
