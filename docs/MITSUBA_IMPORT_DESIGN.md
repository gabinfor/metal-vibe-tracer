# Mitsuba scene import and Bitterli's scenes as downloads

Status: **2026-11-12: implemented and accepted.** The importer (§3–§5) opens Mitsuba scenes through **Open Scene File…**; the ten download entries (§6) open through it, with thumbnails and specs; the validation against Mitsuba 3.9.1 (§7) is done: all ten scenes are accepted under the user's acceptance rule of 2026-11-12 (§2), eight directly and two (Modern Hall, Veach Bidir) as differences explained by renderer changes since 2026-10-21. The development converter it replaces, `scripts/mitsuba_to_usd.py`, was removed on 2026-11-12 (§7). Design approved in conversation on 2026-11-10. Depends on the scene browser ([SCENE_BROWSER_DESIGN.md](SCENE_BROWSER_DESIGN.md)) for the download entries (§6); §3–5 do not depend on it.

## 1. Problem

Bitterli's rendering resources (`BITTERLI2016`) are Mitsuba XML scenes. Before this work the app could not read them: ten had been converted by `scripts/mitsuba_to_usd.py`, a development tool that needs Mitsuba's Python package, and compared with Mitsuba by `scripts/compare_scene.py`, but a user of the app could open none of them, and the download examples offered only OBJ versions of two of the rooms.

## 2. Goal and decisions

Decisions (user, 2026-11-10):

- The app **imports any Mitsuba scene file** natively, in Swift, with no helper process and no new dependency.
- The first version offers **the ten validated scenes** as downloads: Veach Bidir Room, Veach Ajar, Glass of Water, Country Kitchen, Contemporary Bathroom, The White Room, The Grey & White Room, Modern Hall, Water Caustic, Little Lamp.
- Archives download from Bitterli's site after consent; nothing is redistributed.

Done meant, in the original design: each of the ten scenes opens from the browser with its own camera, lights and path depth, and each scene's mean radiance ratio to Mitsuba matches the ratio recorded for the converter's output on 2026-10-21 to within noise.

Acceptance rule (user decision, 2026-11-12, replacing that criterion): every remaining difference from Mitsuba is measured and explained. The ratios recorded on 2026-10-21 are kept as history; the ratios of 2026-11-12 and their measured causes (§7, `REFERENCES.md` `BITTERLI2016`) are the record, and the importer is accepted on that basis. The ten scenes therefore open with their own camera, lights and path depth and are compared with Mitsuba 3.9.1, with every difference traced to a documented cause. The scenes are not claimed to match their recorded 2026-10-21 ratios where they do not.

Out of scope, reported on import: scattering media, `point`, `spot` and `directional` emitters, hair and other curve shapes, the other 25 scenes on Bitterli's page.

## 3. Importer structure

`Sources/MitsubaImporter.swift` follows `GLTFImporter`: `MitsubaImporter.load(_:into:progress:)` builds a `USDImportSnapshot` with mesh sidecars and one OpenPBR MaterialX document per material, and `USDImporter.document` turns it into the project (`format: "Mitsuba"`). The BSDF mapping is `MitsubaImporter.material` in `Sources/MitsubaMaterials.swift`, which writes the documents with `GLTFImporter.Writer` and bakes checkerboards, nonlinear plastic textures and bump normal maps into the import folder; a bump map's normal map takes its UV stretch from the first mesh using the material.

- **Detection:** an `.xml` file is opened by the Mitsuba importer. **Open Scene File…** offers `.xml` (`MitsubaImporter.fileExtensions` in `SceneFile.extensions`) and `StudioController.beginImportUSD` reads every `.xml` with `MitsubaImporter.load`, which fails with "is not a Mitsuba scene" when the root element is not `<scene>`; the document is kept.
- **Assembly:** one mesh asset and one node per shape (world space, identity node transform), named by the shape's id, else `<type><index>`; meshes are read in parallel. One material per BSDF id, area-emitter radiance and interior medium, shared by the shapes that have the same three. Zero-area triangles are dropped and counted in the report.
- **XML layer:** `<default>` values and `$name` substitution; `<ref>` ids, which are global, including BSDFs nested in another BSDF; `<include>`; `<transform>` with `matrix`, `translate`, `rotate`, `scale` and `lookat`.
- **Mitsuba 0.6:** a scene whose `version` is below 2 goes through a rename pass to Mitsuba 3 names (`toWorld`, `intIOR`, `extIOR`, `maxDepth`, `sampleCount`, `faceNormals`, and the other camelCase properties the supported plugins use), and BSDFs' `<srgb>` colours are linearized. Water Caustic ships only in this form.
- **Camera:** the first `perspective` or `thinlens` sensor becomes the saved view "Mitsuba: camera" and the active camera. Mitsuba's camera looks along +z with x to the left, so `to_world` × diag(−1, 1, −1, 1) is the camera (eye: the origin, direction: `to_world`'s z, up: its y). The vertical field of view comes from `fov` and `fov_axis` (`x` by default; `smaller` and `larger` resolved against the film's aspect, `diagonal` over its diagonal) or, without `fov`, from `focal_length` (`50mm` by default, over 35 mm film's 43.27 mm diagonal), and the film's `width` and `height` (768 × 576 by default). A `thinlens`'s `aperture_radius` (up to 0.5) and `focus_distance` (10,000, Mitsuba's far clip, by default) are the lens. A scene without a supported sensor keeps the default camera, with a report line.
- **Depth and size:** the film's size (clamped to 16–8,192) sets `StudioOptions.outputWidth` and `outputHeight`, and the integrator's `max_depth` sets `StudioOptions.depth` to `max_depth` − 1, clamped to 1–64; −1 or no `max_depth` gives 64 (the rule of `scripts/compare_scene.py`). A wrapper integrator gives its inner one's depth; a `sppm` or other integrator than `path`, `volpath` and `volpathmis` contributes only its depth, with a report line.
- **Lighting:** an `envmap` is the environment (its file, `scale` as the intensity, and its turn about +y minus 90° as `environmentRotation`, the convention of a USD dome (`scripts/usd_bridge.py`), `REFERENCES.md` `OPENUSD`); a `to_world` that is not a turn about +y is reported. A `constant` emitter is a uniform 8 × 4 Radiance HDR image of its radiance. A scene without a supported emitter stays unlit (`USDImporter.document` with `inspectionSky` false), as Mitsuba renders it without them.
- **Report:** every unsupported plugin or property is listed once in the import report with what was used instead: other emitters, other and additional sensors, media outside a shape's interior and exterior media, `shapegroup` and `instance`, a shape's `to_uv`, unknown elements.

## 4. What is read

| Mitsuba | Becomes |
| --- | --- |
| `obj`, `ply`, `serialized` shapes | One mesh per shape, in world space (`MitsubaImporter.mesh`); `face_normals` gives flat normals, and a file without normals gets smooth ones, as in Mitsuba |
| `rectangle`, `disk`, `cube`, `sphere` | Tessellated meshes (a 64 × 32 sphere, a 64-segment disk with planar uv, where Mitsuba's is polar); a mirroring transform reverses the winding so the front side stays the analytic normal's, which is the emitting side |
| `flip_normals`, shape `to_uv` | `flip_normals` reverses any shape's winding and negates its normals, so an emitter emits from the other side (with a dielectric whose ratio is below 1, the two reversals cancel); a shape's `to_uv` is reported and ignored |
| `diffuse` | `base_color`, `specular_weight` 0 |
| `plastic`, `roughplastic` | `base_color` = reflectance × internal-scattering ratio (§5), `specular_ior`, `specular_roughness` = √alpha |
| `conductor`, `roughconductor` | `base_metalness` 1, `base_color` = F0, `specular_color` = 82° edge tint, `specular_reflectance` as `specular_weight`; a grey textured `specular_reflectance` (every texel's channels within 2 of 255 levels, so a grey JPEG's chroma noise still counts) is a connected `specular_weight`, the red channel of the sRGB-decoded image (MaterialX leaves float images raw), while a coloured one scales F0 only and is reported, as is one that cannot be checked (not decodable, or above 64 megapixels), which takes the coloured path with a report line naming the reason; a named `material` given with `k` alone reports that `k` is ignored |
| `dielectric`, `roughdielectric` | `transmission_weight` 1, `specular_ior`, `transmission_color`; zero transmittance is a black reflector; an `int_ior` / `ext_ior` below 1 (Glass of Water's bubbles in ice), inside `twosided`, `mask`, `bumpmap` or `normalmap` wrappers or not, is imported as its inverse with the shape's facing reversed and a report line, since the app's IOR is at least 1.01 and each surface uses only its own relative IOR (`MitsubaImporter.leafBSDF`, `reversesFacing`); an interior medium on such a shape would then be on its outside, where the app cannot attach one, and is dropped with a report line; a shape with an area emitter is not reversed, since the app's emission is one-sided, and its glass is rendered index-matched (`specular_ior` 1) with a report line |
| `thindielectric`, `principledthin` | `geometry_thin_walled` (a `thindielectric` with a ratio below 1 keeps its facing and takes the inverse ratio, an approximation that is reported: Mitsuba 3.9.1's pane at 0.763 reflects totally from about 50°, at 1/0.763 it reflects 0.06 at 50° and 0.34 at 75°) |
| `twosided`, `mask`, `bumpmap`, `normalmap` | The inner BSDF; `geometry_opacity` (a bitmap opacity is the red channel of the sRGB-decoded image unless `raw`, as Mitsuba 3.9.1 reads it); a normal map |
| `bitmap`, `checkerboard` | Image nodes (sRGB unless `raw`), sampled as Mitsuba does at the `to_uv` scale (normal maps included); `to_uv` offsets and rotations are reported and ignored; a checkerboard is baked to PNG; a missing file is an error, and so is a source above 64 megapixels that would be baked (`MitsubaMaterials.bakeTexels`) |
| `area` emitter on a shape | Emission on the shape's material; a shape with an emitter and no BSDF has a black surface |
| `envmap`, `constant` scene emitters | The environment, with its rotation about the vertical axis; other scene emitters are reported |
| `perspective`, `thinlens` sensor; film; integrator | The view "Mitsuba: camera", the output size and the path depth (§3) |
| `homogeneous` interior medium with zero albedo (0.6: `sigma_s` 0) behind a refracting BSDF | `transmission_color` exp(−`sigma_t` × `scale`) at `transmission_depth` 1; other media are reported and ignored |

The importer defines the mapping; `REFERENCES.md` (`MITSUBA3`, `BITTERLI2016`) documents it and how it was validated. It began as a port of `scripts/mitsuba_to_usd.py`, a development converter to USD that it replaced (removed on 2026-11-12), and differs from the converter deliberately in these ways: the `sphere` shape (Little Lamp's emitter) and the absorbing interior medium (Modern Hall's glass); the converged plastic ratio and Mitsuba's default conductor `none` (§5); the horizontal field of view from every `fov_axis`; `flip_normals`; a texture's `to_uv` scale sampled at Mitsuba's rows, normal maps included; report lines for inputs the converter dropped silently (properties the mapping does not read, a Beckmann distribution, non-finite or negative values, a dielectric's `specular_reflectance`); the three fixes found by the validation (a dielectric with an IOR ratio below 1, a grey textured conductor `specular_reflectance` and its colour management); and Mitsuba's own mesh readers. `ply` and `serialized` are not used by the ten scenes and are included because other Mitsuba scenes commonly use them.

## 5. Values taken from Mitsuba

| Value | In Swift |
| --- | --- |
| Named IORs (`bk7`, `water`) | `MitsubaTables.ior` (`Sources/MitsubaTables.swift`): the 23 names of Mitsuba 3.9.1's `ior.h` table, read through Mitsuba by `scripts/generate_mitsuba_tables.py` (run by hand under the Mitsuba development environment; its outputs are checked in), looked up in any case by `MitsubaImporter.ior` (`REFERENCES.md`, `MITSUBA3`) |
| Named conductors (`Cu`, `Au`) | `MitsubaTables.conductors`: F0 and edge tint of the 71 presets and `none`, written by the same script; `MitsubaImporter.conductor` follows Mitsuba's default, `none` (a perfect mirror), when a conductor gives no material, `eta` or `k` |
| Explicit conductor `eta`, `k` | The unpolarized conductor Fresnel formula (`fresnel_conductor`) at normal incidence and at μ = 1/7, `eta` 0 and `k` 1 when absent, as in Mitsuba |
| Plastic internal-scattering ratio | `MitsubaImporter.plasticRatio`, computed with the formulas and quadrature of Mitsuba's `plastic` and `roughplastic` (rough integrals cached per IOR, alpha and distribution); `tests/fixtures/mitsuba/plastic-ratios.json`, 126 ratios generated from Mitsuba at a grid of IOR, alpha, distribution, `nonlinear` and reflectance, checks it within 0.1%; the ratios are computed to convergence (a 32 × 32 sampling of Mitsuba overestimates them by up to 0.79%) |
| Nonlinear plastic textures | Baked per texel and channel into the import folder, from the ratio at 17 reflectances |
| Mesh loading | Readers in `MitsubaImporter` for the three formats (the app's OBJ reader splits by material and group, which Mitsuba's `obj` does not); welding and computed normals follow Mitsuba's plugins and agree with it on the Bitterli scenes' OBJ files (`REFERENCES.md`, `MITSUBA3`) |

## 6. Download entries

Ten `SceneEntry` values in a `.bitterli` collection (`format: .mitsuba`), each with one archive from `https://benedikt-bitterli.me/resources/mitsuba/<name>.zip`. Sizes and SHA-256 digests are pinned in `SceneCatalog` from the archives in `build/scenes/downloads`, after each was re-checked against the server's `Content-Length` (2026-11-12).

| Scene (`id`) | Archive | Author | License |
| --- | --- | --- | --- |
| Veach, Bidir Room (`veach-bidir`) | `veach-bidir.zip` | Benedikt Bitterli | CC0 1.0 |
| Veach, Ajar (`veach-ajar`) | `veach-ajar.zip` | Benedikt Bitterli | CC0 1.0 |
| Glass of Water (`glass-of-water`) | `glass-of-water.zip` | aXel | CC0 1.0 |
| Contemporary Bathroom (`bathroom`) | `bathroom.zip` | Mareck | CC0 1.0 |
| Water Caustic (`water-caustic`) | `water-caustic.zip` | Benedikt Bitterli | CC0 1.0 |
| Little Lamp (`lamp`) | `lamp.zip` | UP3D | CC0 1.0 |
| Country Kitchen (`kitchen`) | `kitchen.zip` | Jay-Artist | CC BY 3.0 |
| The White Room (`white-room`) | `living-room-2.zip` | Jay-Artist | CC BY 3.0 |
| The Grey & White Room (`grey-white-room`) | `living-room.zip` | Wig42 | CC BY 3.0 |
| Modern Hall (`modern-hall`) | `staircase2.zip` | NewSee2l035 | CC BY 3.0 |

- Each archive extracts into a folder of its own name, so the entry's storage folder is `bitterli-<archive name>` (the McGuire `living_room` storage stays separate from Bitterli's `living-room`) and its scene file is `<archive name>/scene_v3.xml`; Water Caustic's archive holds only `water-caustic/scene_v0.6.xml`.
- Each has a shot in `scripts/showcase.json` with a new `"mitsuba"` source key, `"view": "Mitsuba: camera"`, and a caustics mode where the 2026-11-09 comparison needs one (Water Caustic: light tracing + photons).
- CC0 entries state that credit is appreciated and not required; CC BY 3.0 entries use the existing credit terms.
- Opening (`StudioController.beginMitsubaImport`, from `openScene`): after the unsaved-changes prompt it loads the installed scene file through `beginImportUSD(from:opened:adjust:)`, the path **Open Scene File…** and the bundled spectral examples use, as a new untitled document. `adjust` applies the shot (`ShowcaseShot.apply`: the saved view **Mitsuba: camera** and, for Water Caustic, caustics; the shots carry no size, depth or sample count, so the scene's own film size and path depth stand) and puts the entry's attribution first in the import report. Like the spectral examples it shows a status line ("Opened *title* *credit*, *license*. Credits: File > Credits and Licenses….") instead of the report sheet, which **Import report…** on the Objects page still shows.
- Thumbnails follow the browser's rules: `render_showcase.py --thumbnails` renders each shot at 960 × 540 (replacing the scene's film size; a square film keeps its vertical field of view, so the 16:9 frame shows more to the sides), at most 256 spp, not denoised. The ten are listed in `Examples/Thumbnails/README.md`.
- The catalog's `triangles` and `materials` are what the importer reports for each scene.
- **Credits and Licenses…** names both archives (McGuire's imported unchanged, Bitterli's opened through this importer) and has a website button for each.
- The McGuire Fireplace Room and Living Room entries stay.

## 7. Validation

- `scripts/compare_scene.py SCENE.xml [--reference V3.xml]` renders the file through the native import (a `"mitsuba"` shot through `scripts/render_showcase.py`, with the film size times `--scale` and the importer's path depth, checked against the reference's `max_depth`) and compares it with Mitsuba 3.9.1's `volpath` render of the same file, or of `--reference` when Mitsuba cannot load it (Water Caustic's 0.6 file, against the hand-written `scene_v3.xml`). A cached reference is reused only when its recorded settings match.
- `--metal-ms` renders a second reference whose GGX `roughconductor`s carry OpenPBR's metal multiple-scattering lobe (`scripts/compare_mitsuba.py`'s `openpbr_metal_ms`), which separates the rough-metal energy compensation from other differences; its cache is kept apart from the plain reference's. A cached reference records the scene file's SHA-256 and the Mitsuba version, and a `max_depth` of −1 is noted in the result, since the app stops at 64.
- `scripts/mitsuba_probes.py` writes flattened variants and variants with a textured property made constant (with links to the scene's files and the `.xml` files it includes) and probe plates for the same comparison.
- Results of 2026-11-12, at the settings recorded under `BITTERLI2016`, are in REFERENCES.md: mean radiance ratios between about 0.97 and 1.06 across the ten scenes. The comparison found three importer defects, fixed (IOR ratios below 1, a grey textured conductor `specular_reflectance` and its colour management), and measured every remaining difference: the rough-metal energy compensation, an emitter inside a dielectric (Little Lamp), Mitsuba's ray offset through Country Kitchen's double-layer blind, the black-reflector dielectrics of 2026-11-05 (The White Room), the medium and the converged plastic ratio. Modern Hall (−1.2% since the 2026-10-21 renderer, localized to commit `125b557`) and Veach Bidir (+0.3 to +0.8%) differ from their 2026-10-21 ratios because the renderer changed since; the native import equalled the converter's output on the same build. Under the acceptance rule of §2 (the user's decision of 2026-11-12) all ten are accepted; the recorded 2026-10-21 ratios stay as history. The converter, `scripts/mitsuba_to_usd.py`, was then removed (2026-11-12); results dated before then were produced with it.

## 8. Tests

`tests/Fix_mitsuba.swift`, without the network or Mitsuba: defaults, references and includes; the 0.6 renames; each transform operation; each BSDF mapping; the IOR and conductor tables and the plastic ratio against the fixture; winding of mirrored rectangles and disks; `obj`, `ply` and `serialized` readers on small fixtures; a synthetic scene end to end (camera, depth, emitter, environment, report). The catalog test covers the ten entries.

## 9. Documentation

Same change: `README.md` (formats, examples, validation wording), `docs/USER_GUIDE.md` (Mitsuba import, its limits, the Bitterli scenes), `CHANGELOG.md`, `REFERENCES.md` (`MITSUBA3` and `BITTERLI2016` used-in symbols, the generated tables, the archives' sizes and download dates, the converter's removal), `docs/SCENE_STORAGE_DESIGN.md` (phase 4), `tests/PERFORMANCE.md` where it names the converter. A minor version bump.
