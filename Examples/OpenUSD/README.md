# OpenUSD import and reference scenes

Use **Objects → Open USD scene…** in Metal Vibe Tracer. The official OpenUSD 26.08 SDK composes the stage; the existing Swift/Metal renderer renders the imported snapshot. USDA, USDC, USD and USDZ are supported. OpenUSD supplies scene interchange, not a replacement rendering engine.

## A complete reference we can use now

The [ASWF Standard Shader Ball](https://github.com/usd-wg/assets/tree/3b75c2dad6a494897557dcca0098257bcf42a8c6/full_assets/StandardShaderBall) includes geometry, textures, an enclosing environment, camera, and area lights. Its documentation includes **Houdini Karma** renders. It was rebuilt from scratch with inspiration from Thomas Anagnostou's Simball, originally developed with Maxwell Render. Geometry/textures are by Chris Rydalch; specification/validation by André Mazzone. The ASWF asset is **CC-BY-4.0**; preserve attribution and its LICENCE when sharing source, adapted scenes, or derived renders.

From the project directory:

```sh
/usr/bin/python3 scripts/fetch_reference_scene.py
./build.sh
open build/MetalVibeTracer.app
```

Open `build/reference-scenes/ShaderBall-triangulated.usda` with the USD button. This separate override chooses the supplied triangulated geometry and PreviewSurface plastic variant at frame 3; upstream files are unchanged. The downloaded asset is pinned to commit `3b75c2dad6a494897557dcca0098257bcf42a8c6`, checked against Git object hashes, and recorded in `DOWNLOAD.json`. Original docs and license stay beside the files. The import has 17 mesh assets, 24 nodes, 11 materials, 63,882 triangles and five rectangular lights. Every material compiles, with no displayColor fallback. The `neutral` material's OpenPBR emission is connected to an image that has no file in the default `internal_emitter = "off"` variant, so it evaluates to zero; select `internal_emitter = "bulb"` or `"bulb_and_ribbon"` in your own override to drive that emission from the supplied emitter maps (those variants also add a sphere light).

Run `MTL_DEBUG_LAYER=1 python3 tests/verify.py --usd-only` to import through the production helper, check the import counts, validate GPU lighting, render with the authored camera, and save:

- `build/checks/latest/usd/StandardShaderBall-audit.vtrace`: portable project with embedded image data.
- `build/checks/latest/usd/import-report-audit.txt`: retained warnings and fallbacks.
- `build/checks/latest/openusd-audit-reference.png`: local 192×144 renderer preview.

Each run writes to its own directory, `build/checks/runs/verify-<time>-<pid>/`. `build/checks/latest` points to the newest run, and older runs beyond the last three are removed.

Without the download the check is skipped with a message. Add `--require-reference` to make a missing scene fail instead. Earlier runs wrote `StandardShaderBall.vtrace`, `import-report.txt` and their `-audit` variants into `build/reference-scenes/`, and `openusd-reference.png` or `openusd-audit-reference.png` directly into `build/checks/`. Those files are stale. The repository copy `docs/images/openusd-reference.png` is a September 8 render, and its CC-BY-4.0 attribution is in `docs/images/README.md`.

This establishes a usable scene for visual inspection. It is **not yet a matched Karma benchmark**: three internal objects use subdivision control cages; PreviewSurface maps approximately to OpenPBR; ACEScg/OCIO transforms are absent. The unused external MaterialX variants also generate warnings because this SDK wheel lacks the MaterialX Sdf plugin. Selecting a supported PreviewSurface variant keeps the main surface usable. Keep these differences visible when comparing renders.

## Larger scene for a later benchmark

[Amazon Lumberyard Bistro from NVIDIA ORCA](https://developer.nvidia.com/orca/amazon-lumberyard-bistro) is the stronger architectural benchmark candidate. It originated in Lumberyard; ORCA provides FBX plus Falcor camera/light files and a CC-BY-4.0 license. Its interior has 1,046,609 triangles and exterior 2,832,120, exceeding our current 500,000 limit. It has not been downloaded or imported. A future step is FBX-to-USD conversion and a larger-scene acceleration/memory budget, followed by material/light validation against Falcor.

## Current coverage

| Component | Behavior |
| --- | --- |
| Composition | Official SDK resolves layers, references, payloads, default variant selections and packages; snapshot at stage start time. Python bridge also accepts `--frame`. |
| Meshes | Planar concave polygon triangulation, holes, authored orientation, indexed UV0/normals, inherited and subset material bindings. Degenerate faces are dropped and non-simple polygons fan-triangulated (both counted in the report); meshes without points, topology or renderable faces are skipped; subtrees under a zero or singular scale are hidden. |
| Scene | Parent transforms, visibility, shared mesh assets, stage units/Y- or Z-up; full affine matrices including nonuniform scale and mirroring. |
| Materials | PreviewSurface metallic workflow and a bounded set of direct MaterialX UsdShade nodes. Local compiler limits remain in README. OpenPBR `emission_color`/`emission_luminance` (constant or connected) and PreviewSurface `emissiveColor` (radiance at unit luminance) make surfaces emit; such surfaces are also light-sampled. A scene lit only by emissive materials still receives the neutral inspection sky, because that fallback looks only for UsdLux lights; lower **Environment brightness** in the Environment settings. Unsupported materials report a displayColor fallback that keeps each prim's own displayColor. `ND_image` colour spaces come from USD metadata (`Usd.ColorSpaceAPI`): sRGB (`srgb_texture`, `srgb_rec709_scene`, `sRGB`), linear (`lin_rec709`, `lin_rec709_scene`) and raw (`raw`, `data`, `identity`); other spaces fall back with a report line. A primvar reader `varname` connected to the material interface is resolved. |
| Lights | Rectangles become one-sided emitters. Disks become equal-area octagons and spheres equal-area 80-face outward polyhedra, both reported. Normalized lights divide by the area actually built, so power is preserved; radiance above 1e8 is scaled down and reported. One lat-long dome, textured or constant-color, is imported. One distant light becomes an independent sun with its authored angle (clamped to 0.1–90°): its irradiance at normal incidence follows UsdLux, intensity × 2^exposure × π·sin²(angle/2) when unnormalized, so default unnormalized suns are dim. Radiance is editable in Materials. Other light types, non-lat-long domes, MeshLightAPI and VolumeLightAPI are reported as omitted. |
| Camera | Perspective camera poses/FOV become saved orbit views; first valid camera is active. The orbit pivot is the first surface on the view ray; the optical focus distance is kept only when authored. |
| Persistence | Embedded `.vtrace` snapshot, import report, undo and cancellation; original USD files are unchanged. |

No USD export, live layer/variant editing, animation playback, skinning, point instancers, subdivision evaluation, volumes, arbitrary shader execution, OCIO, full lens models, light shaping/linking/filtering, or external MaterialX Sdf composition. Meshes render two-sided. Dome orientation/tint and distant-light tint are not applied. The report exposes skipped/approximated features. Limits: 256 nodes, 56 imported materials, 500,000 triangles across instances, and existing MaterialX image/instruction limits. Imports are built in a helper process run by `/usr/bin/python3` (CPython 3.9); other interpreters are refused with a message. Cancellation, failure or quitting preserves the active project and stops the helper. Opening a USD scene starts an untitled document without the previous project's file association or saved views.
