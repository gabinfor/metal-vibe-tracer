import Foundation

// REFERENCES.md: MCGUIRE2017, STANFORD3DSCAN, BITTERLI2016 (the Fireplace and Living Room cameras); the spectral
// scenes: OPENPBR (thin film, dispersion), SCHOTTGLASS, DIAMANTI2014, OPENUSD (implicit prims, ShapingAPI),
// BUCHOLTZ1995, PLANCK, CIEDATA (docs/VOLUME_DESIGN.md: media, light spectra, spot cones).
// The one list of scenes the application offers (docs/SCENE_BROWSER_DESIGN.md): the built-in scenes, the OpenUSD
// stages bundled in Examples/Spectral, and the scenes of Morgan McGuire's Computer Graphics Archive, which are
// downloaded on request and opened with the camera and lighting of the scripts/showcase.json shot of their `shot`.

struct SceneEntry: Sendable {
  enum Collection: String, Sendable, CaseIterable { case builtIn, spectral, mcguire }
  enum Source: Sendable {
    // An index into StudioController.sceneNames.
    case builtIn(Int)
    // A repository path, the same under Contents/Resources.
    case bundled(String)
    // A folder under ExampleLibrary.root, the scene's file in it and the archives that provide it.
    case download(storage: String, file: String, archives: [ExampleArchive])
  }
  enum Format: String, Sendable { case procedural, usd, obj }
  var id: String
  var title: String
  var summary: String
  var collection: Collection
  var source: Source
  var format: Format
  var triangles: Int?
  var materials: Int?
  var tags: [String] = []
  var credit: String?
  var license: String?
  var licenseURL: URL?
  // What the license asks of renders, after the license in the details pane and the import report.
  var terms: String?
  // The scripts/showcase.json shot giving the camera, sky, sun, exposure and emission of the README image.
  var shot: String?

  var archives: [ExampleArchive] {
    if case .download(_, _, let archives) = source { return archives }
    return []
  }
  var isDownload: Bool {
    if case .download = source { return true }
    return false
  }
  // The credited work: Bistro's exterior and interior are one scene.
  var work: String { title.components(separatedBy: " (")[0] }
  var attribution: String? {
    guard let credit, let license, let licenseURL, let terms else { return nil }
    return "\(title): \(credit), from Morgan McGuire's Computer Graphics Archive (casual-effects.com/data). "
      + "\(license) (\(licenseURL.absoluteString)). \(terms)"
  }
}

extension SceneEntry.Collection {
  var title: String {
    switch self {
    case .builtIn: return "Built-in"
    case .spectral: return "Spectral examples"
    case .mcguire: return "McGuire Computer Graphics Archive"
    }
  }
  var website: URL? { self == .mcguire ? URL(string: "https://casual-effects.com/data/") : nil }
}

enum SceneCatalog {
  private static let base = "https://casual-effects.com/g3d/data10/"
  private static func archive(_ name: String, _ path: String, folder: String, _ bytes: Int64, unpacked: Int64,
                              _ sha256: String) -> ExampleArchive {
    ExampleArchive(name: name, url: URL(string: base + path)!, folder: folder, bytes: bytes, unpackedBytes: unpacked,
                   sha256: sha256)
  }
  // Sizes and digests of the archives downloaded on 2026-10-20 (REFERENCES.md MCGUIRE2017).
  private static let bistroTextures = [
    archive("BuildingTextures.zip", "research/model/bistro/BuildingTextures", folder: "BuildingTextures", 507_671_451,
            unpacked: 508_329_182, "16538a37f34cadec5665d97e5b77ef3581d67ab674b33b9caeef1d277cbde6bf"),
    archive("OtherTextures.zip", "research/model/bistro/OtherTextures", folder: "OtherTextures", 431_016_313,
            unpacked: 431_592_637, "0806fee3eeb0e14cd501582edbd2d5caf33c5416a62a871e0f126391096f5c58"),
    archive("PropTextures.zip", "research/model/bistro/PropTextures", folder: "PropTextures", 415_421_476,
            unpacked: 416_385_050, "a179e4ee6367d2b518c4978d7e2e690c59503861634d67d0da8bacfa7196571a"),
  ]
  private static let cc30 = URL(string: "https://creativecommons.org/licenses/by/3.0/")!
  private static let cc40 = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
  private static let ccBySA40 = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
  private static let stanford = URL(string: "https://graphics.stanford.edu/data/3Dscanrep/")!
  private static let bistroCredit = "© 2017 Amazon Lumberyard"
  static let stanfordTerms = "For research and non-commercial use; images must credit the Stanford Computer Graphics "
    + "Laboratory. The model has religious and cultural significance: keep renderings in good taste."
  private static let adaptedTerms = "Images rendered from it are adapted works and must credit it."
  // A single-archive research model extracted into a folder of its own name (sizes and digests of 2026-11-04).
  private static func research(_ model: String, _ bytes: Int64, unpacked: Int64, _ sha256: String) -> [ExampleArchive] {
    [archive("\(model).zip", "research/model/\(model)/\(model).zip", folder: "", bytes, unpacked: unpacked, sha256)]
  }

  private static func builtIn(_ index: Int, _ id: String, _ summary: String, tags: [String] = []) -> SceneEntry {
    SceneEntry(id: id, title: StudioController.sceneNames[index], summary: summary, collection: .builtIn,
               source: .builtIn(index), format: .procedural, tags: tags)
  }
  private static func spectral(_ id: String, _ title: String, _ summary: String, stage: String, tag: String) -> SceneEntry {
    SceneEntry(id: id, title: title, summary: summary, collection: .spectral,
               source: .bundled("Examples/Spectral/\(stage).usda"), format: .usd, tags: ["spectral", tag],
               shot: "spectral-\(id)")
  }
  private static func mcguire(_ id: String, _ title: String, _ summary: String, shot: String, storage: String,
                              file: String, archives: [ExampleArchive], triangles: Int, materials: Int?,
                              tags: [String] = [], credit: String, license: String, licenseURL: URL,
                              terms: String = adaptedTerms) -> SceneEntry {
    SceneEntry(id: id, title: title, summary: summary, collection: .mcguire,
               source: .download(storage: storage, file: file, archives: archives), format: .obj,
               triangles: triangles, materials: materials, tags: tags, credit: credit, license: license,
               licenseURL: licenseURL, terms: terms, shot: shot)
  }

  static let entries: [SceneEntry] = [
    builtIn(0, "pavilion", "An architectural pavilion with glass, wood and water"),
    builtIn(1, "cornell-box", "The Cornell box with a diffuse box and sphere"),
    builtIn(2, "veach-mis", "Veach's multiple importance sampling test: four plates and four lights"),
    builtIn(3, "cornell-glass-mirror", "A Cornell box with a glass sphere and a mirror sphere", tags: ["glass"]),
    builtIn(4, "cornell-fog", "A Cornell box filled with fog", tags: ["fog"]),
    builtIn(5, "reflective-ring", "A reflective ring study"),
    spectral("newton-series", "Newton's Colour Series",
             "Thin-film interference: soap films and anodized titanium", stage: "NewtonSeries", tag: "thin film"),
    spectral("abbe-row", "Abbe Row",
             "Dispersion: one slit seen through four optical glasses", stage: "AbbeRow", tag: "dispersion"),
    spectral("tyndall-tank", "Tyndall Tank",
             "Rayleigh scattering: a white beam turns blue to the side and orange through a medium",
             stage: "TyndallTank", tag: "fog"),
    spectral("lamp-spectra", "Lamp Spectra",
             "The same colours under blackbody, daylight, fluorescent, sodium and LED spots in haze",
             stage: "LampSpectra", tag: "light spectra"),
    spectral("lantern-arcade", "Lantern Arcade",
             "Many lights: 416 lamps from 2000 K to 6500 K over polished stone, where the light tree shines",
             stage: "LanternArcade", tag: "many lights"),
    mcguire("sponza", "Crytek Sponza", "262 k triangles, at noon", shot: "sponza-noon", storage: "sponza",
            file: "sponza.obj",
            archives: [archive("sponza.zip", "common/model/crytek_sponza/sponza.zip", folder: "", 80_113_441,
                               unpacked: 95_882_276, "da005cbee0be2df2abc8513f3ceb61bcb6f69aac112babcd9c00169a27c2770c")],
            triangles: 262_266, materials: 25, tags: ["textures"], credit: "© 2010 Frank Meinl, Crytek",
            license: "CC BY 3.0", licenseURL: cc30),
    mcguire("san-miguel", "San Miguel 2.0", "10 M triangles, at golden hour", shot: "san-miguel-golden",
            storage: "San_Miguel", file: "san-miguel.obj",
            archives: [archive("San_Miguel.zip", "research/model/San_Miguel/San_Miguel.zip", folder: "", 535_519_642,
                               unpacked: 1_910_092_684,
                               "85874077735808150e679b3c71d70a37a270cb8833f4911325aa1099da3f7d4a")],
            triangles: 9_963_375, materials: 287, tags: ["textures"], credit: "© Guillermo M. Leal Llaguno",
            license: "CC BY 3.0", licenseURL: cc30),
    mcguire("bistro-exterior", "Amazon Lumberyard Bistro (exterior)", "2.8 M triangles, in daylight",
            shot: "bistro-exterior-golden", storage: "bistro", file: "Exterior/exterior.obj",
            archives: [archive("Exterior.zip", "research/model/bistro/Exterior.zip", folder: "Exterior", 64_186_766,
                               unpacked: 311_371_057,
                               "f612ba0d8a65811afe0d48a023d31e5b43ac40b78e9b12d15e2b7dc8923c29d4")] + bistroTextures,
            triangles: 2_833_329, materials: 132, tags: ["textures"], credit: bistroCredit, license: "CC BY 4.0",
            licenseURL: cc40),
    mcguire("bistro-interior", "Amazon Lumberyard Bistro (interior)", "1.0 M triangles, in the evening",
            shot: "bistro-interior", storage: "bistro", file: "Interior/interior.obj",
            archives: [archive("Interior.zip", "research/model/bistro/Interior.zip", folder: "Interior", 21_293_389,
                               unpacked: 108_416_959,
                               "3faa41f8d6860d1267268348d44d2b74c64a8bfb55dd4b03c562a70ab83b1062")] + bistroTextures,
            triangles: 1_020_903, materials: 66, tags: ["textures"], credit: bistroCredit, license: "CC BY 4.0",
            licenseURL: cc40),
    mcguire("bedroom", "Bedroom", "383 k triangles, a photogrammetry scan", shot: "bedroom", storage: "bedroom",
            file: "iscv2.obj",
            archives: research("bedroom", 34_180_493, unpacked: 64_565_388,
                               "90834c4336ec1b6f8331175b5600e5f7ce2b863ea7b345ef1b9545f209c4ef94"),
            triangles: 383_504, materials: 7, tags: ["textures"], credit: "© 2017 fhernand", license: "CC BY-SA 4.0",
            licenseURL: ccBySA40,
            terms: "Images rendered from it are adapted works: credit it and share them under CC BY-SA 4.0."),
    mcguire("breakfast-room", "Breakfast Room", "270 k triangles, sunlight through blinds", shot: "breakfast-room",
            storage: "breakfast_room", file: "breakfast_room.obj",
            archives: research("breakfast_room", 6_446_862, unpacked: 23_472_999,
                               "e56ff9b4c89b680cfd5c4c00390533ae28fff7a122d6fc8c92c273a9066c0ca8"),
            triangles: 269_764, materials: 14, tags: ["textures"], credit: "© Wig42", license: "CC BY 3.0",
            licenseURL: cc30),
    mcguire("buddha", "Happy Buddha", "1.1 M triangles, a Stanford scan", shot: "buddha", storage: "buddha",
            file: "buddha.obj",
            archives: research("buddha", 22_519_689, unpacked: 93_037_212,
                               "c14c098ce8d8caaf05696c54396197bf16a22837ef1275cca04d42fd6ab9a6a8"),
            triangles: 1_087_304, materials: nil, credit: "© 1996 Stanford University",
            license: "Stanford 3D Scanning Repository terms", licenseURL: stanford, terms: stanfordTerms),
    mcguire("chinese-dragon", "Chinese Dragon", "871 k triangles, a Stanford scan", shot: "chinese-dragon",
            storage: "dragon", file: "dragon.obj",
            archives: research("dragon", 17_847_685, unpacked: 74_094_075,
                               "111124359a31e4d6b2eeb5398e5bc96a5d9e2d2a130afb10bb4cfbc011bdb797"),
            triangles: 871_198, materials: nil, credit: "© 1996 Stanford University",
            license: "Stanford 3D Scanning Repository terms", licenseURL: stanford, terms: stanfordTerms),
    mcguire("fireplace-room", "Fireplace Room", "143 k triangles, Bitterli's camera", shot: "fireplace-room",
            storage: "fireplace_room", file: "fireplace_room.obj",
            archives: research("fireplace_room", 9_107_724, unpacked: 32_691_058,
                               "9d7be47b9f2065e13a57c1831072d1599bb10ac4740582d6fc0f94efd80ff724"),
            triangles: 142_983, materials: 22, tags: ["textures"], credit: "© Wig42", license: "CC BY 3.0",
            licenseURL: cc30),
    mcguire("living-room", "Living Room", "581 k triangles, Bitterli's camera", shot: "living-room",
            storage: "living_room", file: "living_room.obj",
            archives: research("living_room", 14_547_906, unpacked: 60_888_828,
                               "f14daf4f566871e18c262a450db9ae0285b7124e93e05b3a8bfbcbf674a21aeb"),
            triangles: 580_592, materials: 42, tags: ["textures"], credit: "© 2012 Jay-Artist", license: "CC BY 3.0",
            licenseURL: cc30),
  ]

  static func entry(_ id: String) -> SceneEntry? { entries.first { $0.id == id } }
  // The entries of one collection, in catalog order.
  static func entries(_ collection: SceneEntry.Collection) -> [SceneEntry] { entries.filter { $0.collection == collection } }
  // One line per credited work, for the credits sheet.
  static var credits: [String] {
    var seen = Set<String>()
    return entries.filter { $0.credit != nil && seen.insert($0.work).inserted }.compactMap {
      guard let credit = $0.credit, let license = $0.license, let url = $0.licenseURL else { return nil }
      return "\($0.work) \(credit). \(license), \(url.absoluteString)."
    }
  }
  static func megabytes(_ bytes: Int64) -> String {
    bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(Int((Double(bytes) / 1e6).rounded())) MB"
  }
  static func bundledURL(_ path: String) -> URL? {
    runtimeResourceURL(bundled: Bundle.main.resourceURL?.appendingPathComponent(path), repositoryPath: path)
  }
}
