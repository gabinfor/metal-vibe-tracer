# Mitsuba Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app opens Mitsuba XML scenes natively, and Bitterli's ten validated scenes are download entries in the scene browser.

**Architecture:** `MitsubaImporter` parses the XML in Swift and builds the `USDImportSnapshot` and `MeshAsset` list that `GLTFImporter` builds, handing them to `USDImporter.document`. The material mapping is a port of `scripts/mitsuba_to_usd.py`, whose header comment and `REFERENCES.md` (`MITSUBA3`, `BITTERLI2016`) are the reference for every formula. Values the converter reads from Mitsuba at run time become a checked-in table and a Swift quadrature.

**Tech Stack:** Swift 6 (Foundation `XMLDocument`, `Compression` for zlib, CoreGraphics for PNG), the GPU test harness (`tests/verify.py`), Python 3 with the Mitsuba 3.9.1 development environment (`build/mitsuba-venv`) for the table generator and comparisons only.

**Spec:** `docs/MITSUBA_IMPORT_DESIGN.md`

**Status:** implemented on `feature/mitsuba-import` (2026-11-12); the code and `docs/MITSUBA_IMPORT_DESIGN.md` describe what was built. The plan is kept as written; where it says something the code does not do:

- Detection: there is no `isMitsuba`; every `.xml` goes to `MitsubaImporter.load`, which fails with "is not a Mitsuba scene" when the root element is not `<scene>`. `mesh` takes the shape's index (`mesh(_:index:scene:)`), and `material` is in `Sources/MitsubaMaterials.swift`.
- The mapping is not the converter's unchanged: the default conductor is Mitsuba 3.9.1's `none` (a perfect mirror), not `Cu`; the plastic ratio is computed to convergence and checked against the fixture within 0.1%, not 1%; v is flipped as Mitsuba's `flip_tex_coords` says (by default for `obj` only), while serialized and analytic shapes keep Mitsuba's coordinates; `serialized` reads versions 3 and 4. The design's §4 lists the other deliberate differences.
- Task 6's acceptance (within ±0.01 of the 2026-10-21 ratios) was replaced by the user's rule of 2026-11-12: every difference measured and explained (design §2, §7).
- Added beyond the plan: limits on hostile scene files, dielectrics with an IOR ratio below 1, the conversion of area emitters inside glass, and the area-averaged mip filter (`METALTEXTURES`) that Modern Hall's validation led to.
- Task 8: `CHANGELOG.md` keeps the entries under Unreleased; the version is set at release.

## Global Constraints

- Starts after the scene browser plan (`docs/superpowers/plans/2026-11-10-scene-browser.md`) is merged; Task 7 needs `SceneEntry`, Tasks 1–6 do not.
- `AGENTS.md` applies to every task: `REFERENCES.md` and the affected docs change in the same change as the code; keep citation keys; no unused code; no drive-by refactors.
- No new runtime dependency and no helper process. Mitsuba's Python package is used only by scripts under `scripts/`.
- Tests need neither the network nor Mitsuba. Run them with `python3 tests/verify.py --only Fix_mitsuba.swift`; the full suite runs once, in Task 9.
- Mapping formulas are ported from `scripts/mitsuba_to_usd.py` unchanged; where this plan gives a value, it is the converter's.
- Path depth: app depth = `max_depth − 1`, clamped to 1…64; `max_depth` −1 or absent gives 64 (as `scripts/compare_scene.py`).
- Texture coordinates: Mitsuba's v origin is the top left; flip v as the converter does (`1 − v`).
- Archives download only from `https://benedikt-bitterli.me/resources/mitsuba/`; nothing is redistributed.
- Comparison renders are undenoised. Report long renders as samples done / target and elapsed time.

## Review Focus

1. An `.xml` file that is not a Mitsuba scene (a MaterialX-like or arbitrary XML): the import fails with "not a Mitsuba scene", not a crash or an empty project. (Task 1)
2. A mesh file the scene names is missing or unreadable: the import fails naming the file and the shape id. (Task 2)
3. A `<ref>` to an undefined id, or an undefined `$variable`: the import fails naming it, rather than using a default silently. (Task 1)
4. A scene with no sensor: it opens with the app's default camera and a report line. (Task 5)
5. A scene with only unsupported emitters (a `point` light): it opens, dark, with a report line saying which emitters were skipped. (Task 5)

---

### Task 1: XML layer

**Files:**
- Create: `Sources/MitsubaImporter.swift`, `tests/Fix_mitsuba.swift`
- Modify: `tests/verify.py` (add `('Fix_mitsuba.swift', {'full', 'studio'})` after `Fix_gltf.swift`)

**Interfaces:**
- Produces:

```swift
enum MitsubaImporter {
  static func isMitsuba(_ url: URL) -> Bool      // .xml whose root element is <scene>
  static func error(_ message: String) -> Error  // MaterialLibrary.error("Mitsuba: " + message)
  struct Node {                                   // one resolved XML element
    let tag: String                               // "bsdf", "shape", "float", "ref", ...
    let type: String?                             // the plugin type, $variables substituted
    let name: String?
    let id: String?
    let attributes: [String: String]              // values after $ substitution and the 0.6 rename
    let children: [Node]
    func child(_ name: String) -> Node?           // by name attribute; a <ref> is resolved to its target
    func float(_ name: String) -> Float?
    func string(_ name: String) -> String?
    func bool(_ name: String) -> Bool?
    func rgb(_ name: String) -> SIMD3<Float>?     // <rgb>, <spectrum> or <float> (grey); "a, b, c" or "a b c"
    func transform(_ name: String) -> simd_float4x4   // identity when absent
  }
  struct Scene {
    let root: Node
    let folder: URL
    let version: Int                              // major version; < 2 means the 0.6 rename ran
    var report: [String]
    init(url: URL) throws
    mutating func note(_ line: String)            // each distinct line once
  }
}
```

- Transform operations compose in document order, each applied after the previous (`matrix` row-major 16 or 9 values, `translate`, `rotate` with `angle` and an axis, `scale` uniform or per axis, `lookat` with `origin`, `target`, `up`).
- 0.6 rename table (exact): `toWorld→to_world`, `toUV→to_uv`, `intIOR→int_ior`, `extIOR→ext_ior`, `maxDepth→max_depth`, `sampleCount→sample_count`, `faceNormals→face_normals`, `fovAxis→fov_axis`, `diffuseReflectance→diffuse_reflectance`, `specularReflectance→specular_reflectance`, `specularTransmittance→specular_transmittance`, `sigmaT→sigma_t`, `sigmaA→sigma_a`, `sigmaS→sigma_s`, `focusDistance→focus_distance`, `uscale`/`vscale` on a texture → a `to_uv` scale, `<lookAt>→<lookat>`, `<transform name="toWorld">` likewise. In a 0.6 file, plugin `diffuse`'s `<srgb>` values are read as sRGB and linearized.
- `<include filename>` splices the included file's children; a cycle is an error.

- [ ] **Step 1: Write `tests/Fix_mitsuba.swift`** with `@MainActor func fixMitsubaChecks() throws` and `try fixMitsubaChecks()` at the end, writing fixtures under `testOutputDirectory/mitsuba`. Assertions for this task:

```swift
// defaults.xml: <default name="d" value="7"/>, <integrator type="path"><integer name="max_depth" value="$d"/></integrator>,
// a nested bumpmap containing <bsdf type="diffuse" id="inner">, a shape with <ref id="inner"/>,
// <transform name="to_world"><scale value="2"/><translate x="1" y="0" z="0"/></transform>
let scene = try MitsubaImporter.Scene(url: defaultsURL)
require(scene.version == 3 && scene.root.children.first { $0.tag == "integrator" }?.float("max_depth") == 7, "defaults substitute")
require(shape.child("bsdf")?.id == "inner", "a ref resolves to a BSDF nested in another")
require(shape.transform("to_world") * SIMD4(1, 0, 0, 1) == SIMD4(3, 0, 0, 1), "scale then translate")
let old = try MitsubaImporter.Scene(url: v06URL)     // version="0.6.0", toWorld, intIOR, maxDepth, <lookAt>
require(old.version == 0 && oldShape.child("to_world") != nil && oldBSDF.float("int_ior") == 1.33
  && oldIntegrator.float("max_depth") == 9, "0.6 names are renamed")
require(MitsubaImporter.isMitsuba(defaultsURL) && !MitsubaImporter.isMitsuba(otherXMLURL), "detection by root element")
requireThrows("not a Mitsuba scene") { try MitsubaImporter.Scene(url: otherXMLURL) }
requireThrows("undefined reference 'missing'") { try MitsubaImporter.Scene(url: badRefURL) }
requireThrows("undefined variable '$nope'") { try MitsubaImporter.Scene(url: badVariableURL) }
```

`requireThrows(_ fragment: String, _ body: () throws -> Void)` is a local helper that requires an error whose description contains the fragment.

- [ ] **Step 2: Run** `python3 tests/verify.py --only Fix_mitsuba.swift`. Expected: compile failure, `MitsubaImporter` not found.
- [ ] **Step 3: Implement** `Node`, `Scene` and the helpers with Foundation's `XMLDocument`. Head the file with the citation comment (`REFERENCES.md: MITSUBA3, BITTERLI2016, OPENPBR, MATERIALX`) and a mapping table in the style of `GLTFImporter.swift`'s header, filled in as later tasks land.
- [ ] **Step 4: Run.** Expected: `PASS` lines, exit 0.
- [ ] **Step 5: Commit** `"Mitsuba import: XML resolution and 0.6 names"`.

### Task 2: Shapes

**Files:**
- Modify: `Sources/MitsubaImporter.swift`, `tests/Fix_mitsuba.swift`
- Create: `tests/fixtures/mitsuba/tri.ply`, `tri-binary.ply`, `tri.serialized` (a few hundred bytes each, written once by Mitsuba 3.9.1 from one triangle with normals and UVs; note the generating command in `tests/fixtures/mitsuba/README.md`)

**Interfaces:**
- Produces:

```swift
extension MitsubaImporter {
  struct Mesh {                                   // world space
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]?                  // nil: the renderer uses face normals
    var uvs: [SIMD2<Float>]?                      // v already flipped
    var triangles: [SIMD3<UInt32>]
  }
  static func mesh(_ shape: Node, scene: inout Scene) throws -> Mesh?   // nil and a report line when unsupported
}
```

- `obj`: `v`, `vt`, `vn` and `f` (triangles and fan-triangulated polygons, negative indices); everything else in the file is ignored, and the file is one mesh. `ply`: ASCII and binary little-endian, `vertex` (`x y z`, optional `nx ny nz`, `u v` or `s t`) and `face` lists. `serialized`: format `0x041C`, version 4, zlib stream, the `shape_index` property selecting the sub-mesh through the offset table at the end of the file; single and double precision flags.
- Normals: `face_normals` true gives nil; a file without normals gets area-and-angle-weighted smooth normals (Mitsuba's default); otherwise the file's normals, transformed by the inverse transpose.
- `rectangle`: (−1,−1,0)…(1,1,0), normal +z, UV 0…1. `disk`: radius 1, 64 segments. `cube`: −1…1, 12 triangles, flat normals. `sphere`: `center` and `radius` (defaults 0 and 1) then `to_world`, a 64 × 32 UV sphere with smooth normals.
- A `to_world` with a negative determinant reverses triangle winding on `rectangle` and `disk`; their normals are the normal-transformed +z.

- [ ] **Step 1: Tests:**

```swift
let quad = try MitsubaImporter.mesh(rectangleNode, scene: &scene)!      // to_world: scale x by -1
require(quad.triangles.count == 2 && faceNormal(quad, 0).z > 0.99, "a mirrored rectangle still faces +z")
let ball = try MitsubaImporter.mesh(sphereNode, scene: &scene)!         // radius 2 at (1, 0, 0)
require(ball.positions.allSatisfy { abs(simd_length($0 - SIMD3(1, 0, 0)) - 2) < 1e-4 }, "sphere centre and radius")
for file in ["tri.obj", "tri.ply", "tri-binary.ply", "tri.serialized"] {
  let m = try MitsubaImporter.mesh(node(file), scene: &scene)!
  require(m.triangles.count == 1 && m.positions.count == 3 && m.uvs?.count == 3, "\(file) reads one triangle")
  require(abs(m.uvs![1].y - (1 - 0.25)) < 1e-6, "\(file): v is flipped")
}
let flat = try MitsubaImporter.mesh(node("cube-no-normals.obj", faceNormals: true), scene: &scene)!
let smooth = try MitsubaImporter.mesh(node("cube-no-normals.obj"), scene: &scene)!
require(flat.normals == nil && smooth.normals?.count == smooth.positions.count, "face_normals and smooth normals")
requireThrows("missing.obj") { _ = try MitsubaImporter.mesh(node("missing.obj"), scene: &scene) }
require(try MitsubaImporter.mesh(hairNode, scene: &scene) == nil && scene.report.contains { $0.contains("shape hair") }, "unsupported shapes are reported")
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"Mitsuba import: mesh files and analytic shapes"`.

### Task 3: Values taken from Mitsuba

**Files:**
- Create: `scripts/generate_mitsuba_tables.py`, `Sources/MitsubaTables.swift` (generated, checked in), `tests/fixtures/mitsuba/plastic-ratios.json`
- Modify: `Sources/MitsubaImporter.swift`, `tests/Fix_mitsuba.swift`, `REFERENCES.md` (`MITSUBA3`)

**Interfaces:**
- `build/mitsuba-venv/bin/python -I scripts/generate_mitsuba_tables.py` writes both outputs, with Mitsuba's version in a header comment, and fails if the version is not 3.9.1.
- Produces:

```swift
enum MitsubaTables {
  static let ior: [String: Float]                              // every name Mitsuba's dielectric accepts
  static let conductors: [String: (f0: SIMD3<Float>, tint: SIMD3<Float>)]   // every named conductor, incl. "none"
}
extension MitsubaImporter {
  static func ior(_ node: Node, _ name: String, default: Float) throws -> Float    // a number or a table name
  static func conductor(_ node: Node) throws -> (f0: SIMD3<Float>, tint: SIMD3<Float>)
  static func plasticRatio(eta: Float, alpha: Float?, ggx: Bool, nonlinear: Bool, rho: Float) -> Float  // alpha nil: smooth
}
```

- `conductor`: a `material` name reads the table (default `Cu`); explicit `eta` and `k` use the unpolarized conductor Fresnel at μ = 1 for F0 and at μ = 1/7 for the tint, `tint = clamp(F(1/7) / (F0 + (1 − F0)(1 − 1/7)^5), 0, 1)`, as `conductor_colors`.
- `plasticRatio` reproduces `plastic_ratio`: Mitsuba's diffuse albedo over ρ(1 − specular albedo), averaged over incidence cosines 0.3, 0.5, 0.7, 0.9. Read Mitsuba 3.9.1's `plastic.cpp`, `roughplastic.cpp` and `microfacet.h` (`eval_transmittance`, `eval_diffuse_reflectance`, `fresnel_diffuse_reflectance`) and port their quadrature; cite the files and tag in `REFERENCES.md`.
- `plastic-ratios.json`: Mitsuba's ratios at eta ∈ {1.3, 1.49, 1.9}, alpha ∈ {smooth, 0.01, 0.1, 0.3}, distribution ∈ {beckmann, ggx}, nonlinear ∈ {false, true}, ρ ∈ {0.05, 0.5, 0.95}.

- [ ] **Step 1: Write the generator and run it.** Expected: both files written; the table has at least `Cu`, `Au`, `Ag`, `Al`, `none`, and `ior["bk7"]` ≈ 1.5046, `ior["water"]` ≈ 1.3330.
- [ ] **Step 2: Tests:**

```swift
require(abs(try MitsubaImporter.ior(nodeWith("int_ior", "bk7"), "int_ior", default: 1) - 1.5046) < 1e-4, "named IOR")
requireThrows("unknown IOR 'unobtainium'") { _ = try MitsubaImporter.ior(nodeWith("int_ior", "unobtainium"), "int_ior", default: 1) }
let gold = try MitsubaImporter.conductor(nodeWith("material", "Au"))
require(gold.f0.x > gold.f0.z && simd_reduce_max(gold.tint) <= 1, "gold is warm and its tint is a reflectance")
let explicit = try MitsubaImporter.conductor(etaKNode(eta: [0.2, 0.9, 1.1], k: [3.9, 2.4, 2.2]))
require(simd_length(explicit.f0 - expectedF0) < 1e-4, "explicit eta, k through the Fresnel formula")   // expectedF0 computed in the test from ((η−1)²+k²)/((η+1)²+k²)
for row in try plasticFixture() {
  let r = MitsubaImporter.plasticRatio(eta: row.eta, alpha: row.alpha, ggx: row.ggx, nonlinear: row.nonlinear, rho: row.rho)
  require(abs(r / row.ratio - 1) < 0.01, "plastic ratio within 1% of Mitsuba at \(row)")
}
```

- [ ] **Step 3: Run.** Expected: FAIL.
- [ ] **Step 4: Implement** the lookups, the Fresnel formula and the quadrature.
- [ ] **Step 5: Run.** Expected: PASS. If a rough-plastic row misses 1%, re-read Mitsuba's source for the term that differs; do not loosen the tolerance.
- [ ] **Step 6: Commit** `"Mitsuba import: IOR and conductor tables, plastic ratio"`.

### Task 4: Materials and textures

**Files:**
- Modify: `Sources/MitsubaImporter.swift` (or create `Sources/MitsubaMaterials.swift` if the importer file passes about 900 lines), `tests/Fix_mitsuba.swift`

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces:

```swift
extension MitsubaImporter {
  // One OpenPBR MaterialX document (the form GLTFImporter writes) for a shape's BSDF, emitter and interior medium.
  // bsdf nil: black when emission is set (Mitsuba's default for an emitter), else grey 0.5 diffuse.
  static func material(bsdf: Node?, emission: SIMD3<Float>?, interior: Node?, name: String,
                       scene: inout Scene, folder: URL) throws -> String
}
```

- BSDF mapping: exactly `material()`, `principled_thin()`, `colour_input()` and `texture()` in `scripts/mitsuba_to_usd.py` (spec §4 lists the rows). Defaults to copy: `diffuse` reflectance 0.5; plastic `int_ior` 1.49, `ext_ior` 1.000277, alpha 0.1, distribution `beckmann`; dielectric `int_ior` 1.5046; roughness = √alpha.
- Textured linear plastic: texture × tint `plasticRatio(ρ = 0.5)`. Textured nonlinear plastic: a PNG baked per texel and channel into `folder`, from the ratio at 17 reflectances, linearly interpolated.
- `checkerboard`: a 256 px, 8-bit sRGB PNG in `folder` from `color0` (default 0.4) and `color1` (default 0.2).
- `bumpmap`: converted to a tangent-space normal map as `bump_normal_map` does. `normalmap`: used directly.
- Interior medium: `homogeneous` with albedo 0 (or `sigma_s` 0) on a transmissive BSDF sets `transmission_depth` 1 and `transmission_color` = exp(−σ_t) per channel; any other medium is reported and ignored.
- Each approximation and unsupported input adds the report line the converter's `report.append` writes.

- [ ] **Step 1: Tests.** One fixture BSDF per row, asserting on the MaterialX document's OpenPBR inputs (read them the way `tests/Fix_gltf.swift` reads its imported materials; check that file first and reuse its approach):
  - `diffuse` 0.2, 0.4, 0.6 → `base_color` equal, `specular_weight` 0.
  - `roughconductor` Cu alpha 0.25 with `specular_reflectance` 0.5 → `base_metalness` 1, `specular_roughness` 0.5, `specular_weight` 0.5, `base_color` = table F0.
  - `dielectric` water → `transmission_weight` 1, `specular_ior` ≈ 1.3330 / 1.000277; with `specular_transmittance` 0 → `base_color` 0 and no transmission.
  - `thindielectric` → `geometry_thin_walled` true.
  - `plastic` ρ 0.5, nonlinear → `base_color` = 0.5 × `plasticRatio(...)`.
  - `mask` opacity 0.61 over `diffuse` → `geometry_opacity` 0.61. `twosided` → its inner BSDF's inputs.
  - `checkerboard` reflectance → an image input whose file exists and is 256 × 256.
  - Emitter radiance 5 and no BSDF → emission 5 and `base_color` 0.
  - Interior `sigma_t` (0.5, 0.2, 0.4), albedo 0 → `transmission_depth` 1, `transmission_color` ≈ (0.6065, 0.8187, 0.6703).
  - BSDF `hair` → grey 0.5 and a report line containing "BSDF hair unsupported".
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"Mitsuba import: BSDFs, textures, emitters and interior media"`.

### Task 5: Scene assembly and Open Scene File…

**Files:**
- Modify: `Sources/MitsubaImporter.swift`, `Sources/USDImporter.swift` (`beginImportUSD` dispatch, as it dispatches glTF), `Sources/SceneBrowser.swift` (`SceneFile.extensions` gains `"xml"`), `scripts/render_showcase.py` (driver: `shot.mitsuba`), `Sources/ExampleScenes.swift` (`ShowcaseShot.mitsuba: String?`), `tests/Fix_mitsuba.swift`

**Interfaces:**
- Produces:

```swift
extension MitsubaImporter {
  static func load(_ url: URL, into source: ProjectDocument, progress: OperationProgress? = nil) throws -> USDImportResult
}
```

- One asset and one node per shape, named by the shape's id (or `<type><index>`); materials shared by `<ref>` id and emission.
- Camera: the first `perspective` sensor → the view `"Mitsuba: camera"`, made the active camera; vertical FOV from `fov` and `fov_axis` (default `x`; `smaller` and `larger` resolved against the film size) and film `width` / `height` (defaults 768 × 576); `to_world` right-multiplied by diag(−1, 1, −1, 1). No sensor: the default camera and a report line.
- Film size sets the project's render size; `max_depth` the path depth by the Global Constraints rule.
- Scene emitters: the first `envmap` (file, `scale`, rotation about +Y from `to_world`) or `constant` becomes the environment; others are reported as skipped.
- `"mitsuba"` joins `usd`, `gltf` and `obj` as a `ShowcaseShot` scene source, and its comment and the "everything but the scene source" comment are updated.

- [ ] **Step 1: Tests.** A synthetic scene (a `rectangle` floor, an OBJ triangle with a `<ref>` plastic, an emissive `sphere`, an `envmap` rotated 90° about y, a sensor with `fov` 90 on axis x and a 1280 × 720 film, `max_depth` 7, a `point` emitter):
  - `load` returns a document with 3 assets, the view `"Mitsuba: camera"` with vertical FOV ≈ 58.72°, render size 1280 × 720, path depth 6, an environment with rotation 90°.
  - The report contains a line about the skipped `point` emitter and none about the supported plugins.
  - A copy without the sensor loads with a "no sensor" report line.
  - On the GPU (as `Fix_gltf.swift`'s render checks): rendering the scene at 64 spp gives a mean radiance above zero on the floor under the sphere and zero for a copy with the sphere's emitter removed and no environment.
  - `controller.beginOpenSceneFile(sceneURL)` loads it as an untitled document.
- [ ] **Step 2: Run** `--only Fix_mitsuba.swift Fix_start-screen.swift`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"Mitsuba import: scenes open through Open Scene File"`.

### Task 6: Validation against Mitsuba; retire the converter

**Files:**
- Modify: `scripts/compare_scene.py`, `scripts/mitsuba_probes.py`, `REFERENCES.md` (`BITTERLI2016`, `MITSUBA3`), `tests/PERFORMANCE.md`, `docs/SCENE_STORAGE_DESIGN.md`
- Delete: `scripts/mitsuba_to_usd.py` (last step)

**Interfaces:**
- `compare_scene.py` writes a shot with `"mitsuba": <scene.xml>` in place of converting to USD; the import report comes from the driver's output in place of `conversion.json`. Its other options are unchanged.

- [ ] **Step 1: Switch `compare_scene.py` to the native import** and run it on Veach Bidir Room at the recorded settings (scale 0.5, app 1,024 spp, Mitsuba 4,096, Standard MIS). Expected: mean ratio 0.99 ± 0.01 per channel.
- [ ] **Step 2: Run the other nine scenes** (in `build/scenes/`; Water Caustic from its 0.6 file). Recorded targets, mean ratio app / Mitsuba: Veach Ajar 1.05; Glass of Water 1.02; Country Kitchen 0.97; Contemporary Bathroom 1.00; The White Room 1.01; The Grey & White Room 1.00 (plants region within 1%); Modern Hall 1.05 before its glass medium; Water Caustic and Little Lamp have no recorded ratio, so record theirs. Acceptance: within ±0.01 of the target, except Modern Hall and Little Lamp, whose change from the medium and the sphere is measured and explained.
- [ ] **Step 3: Bisect any scene outside tolerance** with `mitsuba_probes.py`'s flattened variants (repointed at the native import) before changing any mapping; fix the importer, not the tolerance.
- [ ] **Step 4: Record the results** in `REFERENCES.md` under `BITTERLI2016` (dated, with settings) and update `tests/PERFORMANCE.md` and `docs/SCENE_STORAGE_DESIGN.md` where they name the converter.
- [ ] **Step 5: Delete `scripts/mitsuba_to_usd.py`**; grep `scripts/`, `tests/`, `docs/`, `README.md`, `REFERENCES.md` for its name and fix each mention (history in `CHANGELOG.md` stays).
- [ ] **Step 6: Commit** `"Mitsuba import validated on ten Bitterli scenes; converter removed"`.

### Task 7: Bitterli download entries

**Files:**
- Modify: `Sources/SceneCatalog.swift`, `scripts/showcase.json`, `Sources/SceneBrowser.swift` (credits wording per collection), `Sources/ExampleScenes.swift` (`openScene` dispatch for `.mitsuba`), `tests/Fix_example-scenes.swift`, `Examples/Thumbnails/`

**Interfaces:**
- Consumes: `SceneEntry` and `openScene` from the browser plan; `MitsubaImporter.load`.
- Adds `SceneEntry.Collection.bitterli` (title "Bitterli's Rendering Resources", website `https://benedikt-bitterli.me/resources/`) and `SceneEntry.Format.mitsuba`.
- Ten entries, ids and archives: `veach-bidir` (`veach-bidir.zip`), `veach-ajar`, `glass-of-water`, `bathroom`, `water-caustic`, `lamp`, `kitchen`, `white-room` (`living-room-2.zip`), `grey-white-room` (`living-room.zip`), `modern-hall` (`staircase2.zip`). Titles, authors and licenses: spec §6. Scene file inside each archive: `<archive name>/scene_v3.xml`; Water Caustic: `water-caustic/scene_v0.6.xml`.
- CC0 terms text: `"Public domain (CC0). Credit is appreciated but not required."` CC BY 3.0 entries use the default terms.
- Shots named `bitterli-<id>` with `"mitsuba"`, `"view": "Mitsuba: camera"`; `water-caustic` adds `"caustics": 3`.

- [ ] **Step 1: Pin each archive.** For each zip in `build/scenes/downloads`: compare its size with the server's `Content-Length` (`curl -sIL`), compute `shasum -a 256` and the unpacked size, and confirm the scene file path inside it. A size mismatch stops the task: ask the user before downloading anything again.
- [ ] **Step 2: Tests** in `Fix_example-scenes.swift`: 31 entries; the ten ids above are in `.bitterli` with `format == .mitsuba`; every archive URL has host `benedikt-bitterli.me` and path prefix `/resources/mitsuba/`; each has its shot with a `mitsuba` path ending in the entry's scene file; the six CC0 entries carry the CC0 terms; credits list ten more works. A locally made zip holding the Task 5 synthetic scene installs and opens through `controller.openScene`.
- [ ] **Step 3: Run.** Expected: FAIL.
- [ ] **Step 4: Implement** the entries, shots and the `.mitsuba` open path.
- [ ] **Step 5: Render the ten thumbnails** (`python3 scripts/render_showcase.py --thumbnails --only <ids>`), and add their credits to `Examples/Thumbnails/README.md`.
- [ ] **Step 6: Run** `--only Fix_example-scenes.swift Fix_start-screen.swift`, then `./build.sh`. Expected: PASS and a clean bundle check.
- [ ] **Step 7: Commit** `"Bitterli's ten validated scenes as download examples"`.

### Task 8: Documentation

**Files:**
- Modify: `README.md`, `docs/USER_GUIDE.md`, `CHANGELOG.md`, `REFERENCES.md`, `docs/MITSUBA_IMPORT_DESIGN.md` (status line), `docs/SCENE_BROWSER_DESIGN.md` (collections and formats), `THIRD_PARTY_NOTICES.md` if it lists example sources

- [ ] **Step 1: Update.** `README.md`: supported formats, the example list, and the validation wording now that the scenes open in the app. `docs/USER_GUIDE.md`: a Mitsuba import section (what is read, what is reported, 0.6 files) and the Bitterli scenes. `CHANGELOG.md`: the importer and the ten downloads, under a minor version. `REFERENCES.md`: `MITSUBA3` and `BITTERLI2016` "Used in" symbols, the generated tables and fixture with Mitsuba's version, the archives' sizes and download dates, the "Last reviewed" line.
- [ ] **Step 2: Check every claim against the code:** labels, limits, defaults, file names and scene counts.
- [ ] **Step 3: Commit** `"Mitsuba import: documentation"`.

### Task 9: Full verification

- [ ] **Step 1: Run** `python3 tests/verify.py`. Expected: exit 0 with every file's PASS lines.
- [ ] **Step 2: In the built app,** download and open Veach Bidir Room and Water Caustic from the browser, and open one scene with **Open Scene File…**. Expected: each opens at Bitterli's camera with its lights; Water Caustic shows the caustic web once photons accumulate.
- [ ] **Step 3: Report** the suite result and what was checked by hand; fix and re-run on any failure.
