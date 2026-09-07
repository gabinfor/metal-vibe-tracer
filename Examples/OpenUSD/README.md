# OpenUSD import and reference scenes

Use **Objects → Open USD scene…** in Vibe Tracer. The official OpenUSD 26.08 SDK composes the stage; the existing Swift/Metal renderer renders the imported snapshot. USDA, USDC, USD and USDZ are supported. OpenUSD supplies scene interchange, not a replacement rendering engine.

## A complete reference we can use now

The [ASWF Standard Shader Ball](https://github.com/usd-wg/assets/tree/3b75c2dad6a494897557dcca0098257bcf42a8c6/full_assets/StandardShaderBall) includes geometry, textures, an enclosing environment, camera, and area lights. Its documentation includes **Houdini Karma** renders. It was rebuilt from scratch with inspiration from Thomas Anagnostou's Simball, originally developed with Maxwell Render. Geometry/textures are by Chris Rydalch; specification/validation by André Mazzone. The ASWF asset is **CC-BY-4.0**; preserve attribution and its LICENCE when sharing source, adapted scenes, or derived renders.

From the project directory:

```sh
/usr/bin/python3 scripts/fetch_reference_scene.py
./build.sh
open build/VibeTracer.app
```

Open `build/reference-scenes/ShaderBall-triangulated.usda` with the USD button. This separate override chooses the supplied triangulated geometry and PreviewSurface plastic variant at frame 3; upstream files are unchanged. The downloaded asset is pinned to commit `3b75c2dad6a494897557dcca0098257bcf42a8c6`, checked against Git object hashes, and recorded in `DOWNLOAD.json`. Original docs and license stay beside the files. The import has 17 mesh assets, 24 nodes, 11 materials, 63,882 triangles and five rectangular lights.

Run `MTL_DEBUG_LAYER=1 python3 tests/verify.py --usd-only` to import through the production helper, validate GPU lighting, render with the authored camera, and save:

- `build/reference-scenes/StandardShaderBall.vtrace`: portable project with embedded image data.
- `build/reference-scenes/import-report.txt`: retained warnings and fallbacks.
- `build/checks/openusd-reference.png`: local renderer preview.

This establishes a usable scene for visual inspection. It is **not yet a matched Karma benchmark**: three internal objects use subdivision control cages; unsupported neutral-material parameters cause reported fallbacks; PreviewSurface maps approximately to OpenPBR; ACEScg/OCIO transforms are absent; millimeter details can be affected by fixed ray offsets. The unused external MaterialX variants also generate warnings because this SDK wheel lacks the MaterialX Sdf plugin. Selecting a supported PreviewSurface variant keeps the main surface usable. Keep these differences visible when comparing renders.

## Larger scene for a later benchmark

[Amazon Lumberyard Bistro from NVIDIA ORCA](https://developer.nvidia.com/orca/amazon-lumberyard-bistro) is the stronger architectural benchmark candidate. It originated in Lumberyard; ORCA provides FBX plus Falcor camera/light files and a CC-BY-4.0 license. Its interior has 1,046,609 triangles and exterior 2,832,120, exceeding our current 500,000 limit. It has not been downloaded or imported. A future step is FBX-to-USD conversion and a larger-scene acceleration/memory budget, followed by material/light validation against Falcor.

## Current coverage

| Component | Behavior |
| --- | --- |
| Composition | Official SDK resolves layers, references, payloads, default variant selections and packages; snapshot at stage start time. Python bridge also accepts `--frame`. |
| Meshes | Planar concave polygon triangulation, holes, authored orientation, indexed UV0/normals, inherited and subset material bindings. |
| Scene | Parent transforms, visibility, shared mesh assets, stage units/Y- or Z-up; full affine matrices including nonuniform scale and mirroring. |
| Materials | PreviewSurface metallic workflow and a bounded set of direct MaterialX UsdShade nodes. Local compiler limits remain in README. Unsupported materials report a displayColor fallback. |
| Lights | Rectangle → one-sided triangle emitter; one textured dome; one distant sun. Radiance editable in Materials. Other light types report omission. |
| Camera | Perspective camera poses/FOV become saved orbit views; first valid camera is active. |
| Persistence | Embedded `.vtrace` snapshot, import report, undo and cancellation; original USD files are unchanged. |

No USD export, live layer/variant editing, animation playback, skinning, point instancers, subdivision evaluation, volumes, arbitrary shader execution, OCIO, full lens models, light shaping/linking/filtering, or external MaterialX Sdf composition. Meshes render two-sided. Dome orientation/tint and distant-light angle/tint are approximated. The report exposes skipped/approximated features. Limits: 256 nodes, 56 imported materials, 500,000 triangles across instances, and existing MaterialX image/instruction limits. Imports are built in a helper process; cancellation or failure preserves the active project.
