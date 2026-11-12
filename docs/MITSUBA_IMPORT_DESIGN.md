# Mitsuba scene import and Bitterli's scenes as downloads

Status: **2026-11-10. Proposed; nothing implemented.** Design approved in conversation on 2026-11-10. Depends on the scene browser ([SCENE_BROWSER_DESIGN.md](SCENE_BROWSER_DESIGN.md)) for the download entries (§6); §3–5 do not depend on it.

## 1. Problem

Bitterli's rendering resources (`BITTERLI2016`) are Mitsuba XML scenes. The app cannot read them. Ten have been converted by `scripts/mitsuba_to_usd.py`, a development tool that needs Mitsuba's Python package, and compared with Mitsuba by `scripts/compare_scene.py`. A user of the app can open none of them, and the download examples offer only OBJ versions of two of the rooms.

## 2. Goal and decisions

Decisions (user, 2026-11-10):

- The app **imports any Mitsuba scene file** natively, in Swift, with no helper process and no new dependency.
- The first version offers **the ten validated scenes** as downloads: Veach Bidir Room, Veach Ajar, Glass of Water, Country Kitchen, Contemporary Bathroom, The White Room, The Grey & White Room, Modern Hall, Water Caustic, Little Lamp.
- Archives download from Bitterli's site after consent; nothing is redistributed.

Done means: each of the ten scenes opens from the browser with its own camera, lights and path depth, and agrees with Mitsuba as closely as the Python converter's output does (§7).

Out of scope, reported on import: scattering media, `point`, `spot` and `directional` emitters, hair and other curve shapes, the other 25 scenes on Bitterli's page.

## 3. Importer structure

`Sources/MitsubaImporter.swift` follows `GLTFImporter`: `MitsubaImporter.load(_:into:progress:)` builds a `USDImportSnapshot` with mesh sidecars and one OpenPBR MaterialX document per material, and `USDImporter.document` turns it into the project (`format: "Mitsuba"`). The BSDF mapping is `MitsubaImporter.material` in `Sources/MitsubaMaterials.swift`, which writes the documents with `GLTFImporter.Writer` and bakes checkerboards, nonlinear plastic textures and bump normal maps into the import folder; a bump map's normal map takes its UV stretch from the first mesh using the material.

- **Detection:** an `.xml` file whose root element is `<scene>`. **Open Scene File…** accepts it.
- **XML layer:** `<default>` values and `$name` substitution; `<ref>` ids, which are global, including BSDFs nested in another BSDF; `<include>`; `<transform>` with `matrix`, `translate`, `rotate`, `scale` and `lookat`.
- **Mitsuba 0.6:** a scene whose `version` is below 2 goes through a rename pass to Mitsuba 3 names (`toWorld`, `intIOR`, `extIOR`, `maxDepth`, `sampleCount`, `faceNormals`, and the other camelCase properties the supported plugins use), and BSDFs' `<srgb>` colours are linearized. Water Caustic ships only in this form.
- **Camera:** the first `perspective` sensor becomes the saved view "Mitsuba: camera" and the active camera, with the vertical field of view derived from `fov`, `fov_axis` and the film size. Mitsuba's camera looks along +z with x to the left.
- **Depth and size:** the integrator's `max_depth` sets the project's path depth and the film's size the render size. A `sppm` or other unknown integrator contributes only its depth.
- **Report:** every unsupported plugin or property is listed once in the import report with what was used instead.

## 4. What is read

| Mitsuba | Becomes |
| --- | --- |
| `obj`, `ply`, `serialized` shapes | One mesh per shape, in world space (`MitsubaImporter.mesh`); `face_normals` gives flat normals, and a file without normals gets smooth ones, as in Mitsuba |
| `rectangle`, `disk`, `cube`, `sphere` | Tessellated meshes (a 64 × 32 sphere, a 64-segment disk); a mirroring transform reverses the winding so the front side stays the analytic normal's, which is the emitting side |
| `diffuse` | `base_color`, `specular_weight` 0 |
| `plastic`, `roughplastic` | `base_color` = reflectance × internal-scattering ratio (§5), `specular_ior`, `specular_roughness` = √alpha |
| `conductor`, `roughconductor` | `base_metalness` 1, `base_color` = F0, `specular_color` = 82° edge tint, `specular_reflectance` as `specular_weight` |
| `dielectric`, `roughdielectric` | `transmission_weight` 1, `specular_ior`, `transmission_color`; zero transmittance is a black reflector |
| `thindielectric`, `principledthin` | `geometry_thin_walled`, as the converter's header documents |
| `twosided`, `mask`, `bumpmap`, `normalmap` | The inner BSDF; `geometry_opacity`; a normal map |
| `bitmap`, `checkerboard` | Image nodes (sRGB unless `raw`) with `to_uv` scale; a checkerboard is baked to PNG; a missing file is an error |
| `area` emitter on a shape | Emission on the shape's material; a shape with an emitter and no BSDF has a black surface |
| `envmap`, `constant` scene emitters | The environment, with its rotation about the vertical axis |
| `homogeneous` interior medium with zero albedo (0.6: `sigma_s` 0) behind a refracting BSDF | `transmission_color` exp(−`sigma_t` × `scale`) at `transmission_depth` 1; other media are reported and ignored |

The mappings are those of `scripts/mitsuba_to_usd.py` as validated in `REFERENCES.md` (`MITSUBA3`, `BITTERLI2016`), with two additions: the `sphere` (Little Lamp's emitter) and the absorbing interior medium (Modern Hall's glass). `ply` and `serialized` are not used by the ten scenes and are included because other Mitsuba scenes commonly use them.

## 5. Values the converter takes from Mitsuba

| Value | In Swift |
| --- | --- |
| Named IORs (`bk7`, `water`) | `MitsubaTables.ior` (`Sources/MitsubaTables.swift`): the 23 names of Mitsuba 3.9.1's `ior.h` table, read through Mitsuba by `scripts/generate_mitsuba_tables.py` (run by hand under the Mitsuba development environment; its outputs are checked in), looked up in any case by `MitsubaImporter.ior` (`REFERENCES.md`, `MITSUBA3`) |
| Named conductors (`Cu`, `Au`) | `MitsubaTables.conductors`: F0 and edge tint of the 71 presets and `none`, written by the same script; `MitsubaImporter.conductor` follows Mitsuba's default, `none` (a perfect mirror), when a conductor gives no material, `eta` or `k` (the converter used Cu) |
| Explicit conductor `eta`, `k` | The unpolarized conductor Fresnel formula (`fresnel_conductor`) at normal incidence and at μ = 1/7, `eta` 0 and `k` 1 when absent, as in Mitsuba |
| Plastic internal-scattering ratio | `MitsubaImporter.plasticRatio`, computed with the formulas and quadrature of Mitsuba's `plastic` and `roughplastic` (rough integrals cached per IOR, alpha and distribution); `tests/fixtures/mitsuba/plastic-ratios.json`, 126 ratios generated from Mitsuba at a grid of IOR, alpha, distribution, `nonlinear` and reflectance, checks it within 0.1%; the ratios are computed to convergence, since the converter's 32 × 32 sampling overestimates them by up to 0.79% |
| Nonlinear plastic textures | Baked per texel and channel into the import folder, from the ratio at 17 reflectances |
| Mesh loading | Readers in `MitsubaImporter` for the three formats (the app's OBJ reader splits by material and group, which Mitsuba's `obj` does not); welding and computed normals follow Mitsuba's plugins and agree with it on the Bitterli scenes' OBJ files (`REFERENCES.md`, `MITSUBA3`) |

## 6. Download entries

Ten `SceneEntry` values in a `.bitterli` collection (`format: .mitsuba`), each with one archive from `https://benedikt-bitterli.me/resources/mitsuba/<name>.zip`. Sizes and SHA-256 digests are pinned from the archives in `build/scenes/downloads`, after each is re-checked against the server's `Content-Length`.

| Scene | Archive | Author | License |
| --- | --- | --- | --- |
| Veach, Bidir Room | `veach-bidir.zip` | Benedikt Bitterli | CC0 1.0 |
| Veach, Ajar | `veach-ajar.zip` | Benedikt Bitterli | CC0 1.0 |
| Glass of Water | `glass-of-water.zip` | aXel | CC0 1.0 |
| Contemporary Bathroom | `bathroom.zip` | Mareck | CC0 1.0 |
| Water Caustic | `water-caustic.zip` | Benedikt Bitterli | CC0 1.0 |
| Little Lamp | `lamp.zip` | UP3D | CC0 1.0 |
| Country Kitchen | `kitchen.zip` | Jay-Artist | CC BY 3.0 |
| The White Room | `living-room-2.zip` | Jay-Artist | CC BY 3.0 |
| The Grey & White Room | `living-room.zip` | Wig42 | CC BY 3.0 |
| Modern Hall | `staircase2.zip` | NewSee2l035 | CC BY 3.0 |

- Each entry names the scene file inside the archive: `scene_v3.xml`, or the 0.6 file for Water Caustic.
- Each has a shot in `scripts/showcase.json` with a new `"mitsuba"` source key, `"view": "Mitsuba: camera"`, and a caustics mode where the 2026-11-09 comparison needs one (Water Caustic: light tracing + photons).
- CC0 entries state that credit is appreciated and not required; CC BY 3.0 entries use the existing credit terms.
- Thumbnails follow the browser's rules.
- The McGuire Fireplace Room and Living Room entries stay.

## 7. Validation

- `scripts/compare_scene.py` renders each XML through the native import (a `"mitsuba"` shot through `scripts/render_showcase.py`) against Mitsuba's render of the same file, at the settings recorded under `BITTERLI2016`.
- Acceptance: each scene's mean radiance ratio matches the recorded ratio to within noise. Modern Hall and Little Lamp may move because of the medium and the sphere; a change is explained and recorded.
- Once the ten match, `scripts/mitsuba_to_usd.py` is removed and `scripts/mitsuba_probes.py` uses the native import.

## 8. Tests

`tests/Fix_mitsuba.swift`, without the network or Mitsuba: defaults, references and includes; the 0.6 renames; each transform operation; each BSDF mapping; the IOR and conductor tables and the plastic ratio against the fixture; winding of mirrored rectangles and disks; `obj`, `ply` and `serialized` readers on small fixtures; a synthetic scene end to end (camera, depth, emitter, environment, report). The catalog test covers the ten entries.

## 9. Documentation

Same change: `README.md` (formats, examples, validation wording), `docs/USER_GUIDE.md` (Mitsuba import, its limits, the Bitterli scenes), `CHANGELOG.md`, `REFERENCES.md` (`MITSUBA3` and `BITTERLI2016` used-in symbols, the generated tables, the archives' sizes and download dates, the removed converter), `docs/SCENE_STORAGE_DESIGN.md` (phase 4), `tests/PERFORMANCE.md` where it names the converter. A minor version bump.
