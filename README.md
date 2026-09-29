# Metal Vibe Tracer

An experimental path tracer for macOS, built with Swift, AppKit, and Metal. Explore lighting and materials in real time, import scenes, and export denoised renders.

## Features

- **Path tracing:** ReSTIR with Standard MIS, light-only, and BSDF-only comparison modes. Imported scenes use ReSTIR PT, which reuses whole paths, including glossy, mirror and glass paths, with the improvements of ReSTIR PT Enhanced (Lin et al., SIGGRAPH 2022 and I3D 2026; `RESTIRPT2022`, `RESTIRPTE2026` in [REFERENCES.md](REFERENCES.md)). The procedural scenes use ReSTIR direct lighting with first-bounce diffuse ReSTIR GI, which is faster there; its spatial reuse can pick neighbours by compatibility-guided selection (Junkins et al., HPG 2026; `COMPATRESTIR2026`).
- **Materials:** OpenPBR surfaces, image textures, normal maps, and a supported subset of MaterialX graphs.
- **Scenes:** six procedural test scenes, OBJ import, and OpenUSD scene import with hierarchy, instances, materials, lights, and cameras. Imported meshes are traced as instances through a two-level acceleration structure: Metal hardware ray tracing where a launch-time check finds it watertight (Apple M4 does), otherwise an exact software 4-wide SAH hierarchy. Up to 1,000,000 stored and 64,000,000 rendered triangles.
- **Lighting:** procedural skies, HDRI environments, editable area lights, and a thin-lens camera.
- **Denoising:** MetalFX interactive preview and Open Image Denoise for in-app snapshots and offline exports.
- **Viewport:** beauty, albedo, world normals, depth, and material/roughness views.
- **Projects:** portable `.vtrace` files with embedded assets stored once each, saved camera views, undo/redo, and autosave recovery.
- **Export:** sRGB PNG and linear HDR OpenEXR (32-bit float RGB) at independent resolutions and sample counts.

## Requirements

- macOS 26 or later
- A Metal-capable GPU; tested on Apple M4
- Xcode 27 command-line tools (Swift 6.4). The app, the GPU test suite and the benchmark compile in the Swift 6 language mode (`-swift-version 6`), so a Swift 6 toolchain is required.
- Internet access for the first build

MetalFX preview requires a supported GPU. OpenUSD import uses the command-line tools’ `/usr/bin/python3` (CPython 3.9); the import helper refuses other Python versions with a message.

## Getting started

```sh
git clone https://github.com/gabinfor/metal-vibe-tracer.git
cd metal-vibe-tracer
./build.sh
open build/MetalVibeTracer.app
```

The first build downloads pinned OpenUSD 26.8 and Open Image Denoise 2.5.0 runtimes. Later builds reuse the cache after checking it. The OIDN cache records every file's SHA-256 and the target architecture, so a cache made by an older build is prepared once more. A cached OpenUSD wheel that fails its checksum is moved to `build/usd-wheel/rejected/` and downloaded again. OpenPBR shader sources are vendored, and Metal shaders compile at runtime; the separate Metal command-line toolchain is not required.

`build.sh` compiles first and then assembles a staging bundle. `scripts/check_bundle.py` runs the bundled helpers from `/` with a minimal environment, and the staged bundle replaces `build/MetalVibeTracer.app` only if that check passes. The app loads its shaders, USD helper and OIDN runtime from its bundle only, never from the launch directory.

If the checkout is inside iCloud Drive (for example `~/Documents`), the build marks `build/` with `com.apple.fileprovider.ignore#P` so that the roughly 1 GB tree stays local. Older builds may have left conflict copies such as `build/OpenUSD 2` or duplicate `.app` bundles. They are unused and can be deleted by hand. A checkout outside iCloud-synced folders avoids the issue.

## Usage

Choose a scene in the inspector, then adjust its camera, lighting, materials, and objects. Use **Render** to change the sampling strategy, the ReSTIR reuse modes (indirect reuse, spatial neighbours, temporal reuse) or the viewport mode. **Settings…** is available in the top toolbar and the macOS application menu.

| Action | Control |
| --- | --- |
| Orbit / pan / zoom | Drag / Shift-drag / scroll |
| Select a surface | Click in the viewport |
| Open / save / save as | ⌘O / ⌘S / ⇧⌘S |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Pause or resume / restart | ⌘P / ⌘R |
| Export controls | ⌘E |
| Settings | ⌘, |
| Show or hide inspector | ⌘I |
| Frame selection / all imported objects | ⌘F / ⇧⌘F |
| Close window / minimize / hide | ⌘W / ⌘M / ⌘H |

The **Window** menu provides Minimize, Zoom and Bring All to Front. ⌘E and **Settings…** reveal the inspector if it is hidden.

Use **OIDN Preview Current Frame** to denoise the current accumulation inside the app. For a final image, open **Export**, choose a resolution and sample count, and select OIDN, raw, or MetalFX output. PNG includes display adjustments and is sRGB-encoded. OpenEXR stores linear HDR radiance as 32-bit float RGB without an alpha channel, so values above 65504 are kept. MetalFX output, in the preview or in an export, is a display estimate, not radiometric data. The suite measured MetalFX/raw region-mean ratios of 1.03 on diffuse Cornell surfaces, 0.87 on diffuse Pavilion surfaces, 0.69 on reflective regions and 0.77 on the grazing gold cylinder. For linear radiance, export the raw or OIDN source as OpenEXR.

Projects embed imported assets and can be reopened without the original files. Since project format 3, each distinct image, environment or mesh is stored once per file, and autosaves write only assets that changed, as separate sidecar files. Older projects open and are saved as format 3; builds from before this change cannot open format-3 projects. Open, New and Open USD Scene ask Save / Don't Save / Cancel when the document has unsaved changes; a replaced unsaved document is also kept as `Autosave-previous.vtrace`. The app restores its latest autosave on startup, together with its project file association and edited state. An autosave that cannot be restored is moved aside as `Autosave-unrestorable-<date>.vtrace` and never overwritten. Quit waits for pending saves.

See the [user guide](docs/USER_GUIDE.md) for material controls, project behavior, import coverage, and export details.

## Example assets

- [MaterialX examples](Examples/MaterialX/README.md)
- [OpenUSD examples and reference scenes](Examples/OpenUSD/README.md)
- [Poly Haven HDRI test selection](Examples/HDRI/README.md)

To download the optional 4K HDRI selection locally:

```sh
python3 scripts/fetch_test_hdris.py
```

## Development

The renderer and embedded Metal kernels live in `main.swift`. App controls, project handling, importers, and export code are in `Sources/`.

```sh
./build.sh
python3 tests/verify.py
```

The verification suite runs the production shaders on Metal and checks rendering, materials, denoising, imports, project persistence, and UI construction. GPU checks go through the production `PathTracerRenderer.renderFrame` path. GPU access is required. Native file dialogs and mouse interactions require manual checks.

`python3 tests/verify.py [--studio-only | --usd-only] [--require-reference]` runs the full suite, the Studio subset, or the OpenUSD subset. `--require-reference` makes a missing ASWF Shader Ball download fail instead of being skipped with a message. Unknown flags are rejected.

`tests/harness.py` assembles the test program from `main.swift`, `Sources/*.swift` and an explicit, ordered list of test files. Every cut uses a marker that must occur exactly once, so a moved marker fails the build instead of dropping code. The harness compiles with `-swift-version 6 -D VIBE_TESTING` and passes the repository root through `VIBE_TRACER_REPOSITORY`. Only such test builds may load resources from the repository; release builds use the bundle. The suite also runs `tests/USDChecks.py`, `tests/Fix_build.py` and `tests/Fix_tests.py`. `build/verify.lock` allows one suite run per checkout at a time; a second run waits.

Each run writes diagnostic images and fixtures to its own `build/checks/runs/verify-<time>-<pid>/` directory, and `build/checks/latest` points to the newest run. The last three runs are kept. On GPUs without MetalFX's temporal denoised scaler, the MetalFX checks print `SKIP` and the suite exercises the raw fallback path instead.

For Metal API validation:

```sh
MTL_DEBUG_LAYER=1 python3 tests/verify.py
```

The September 26, 2026 audit remediation and its validation are recorded in
[docs/AUDIT_REMEDIATION_2026-09-26.md](docs/AUDIT_REMEDIATION_2026-09-26.md).
The application is currently distributed as an unsigned local build; signing,
notarization, and clean-machine installation remain release packaging work.

`python3 tests/benchmark.py [--baseline /path/to/previous/main.swift] [--report FILE] [--frames 12] [--rounds 2] [--output-tolerance 0.05]` times the production `renderFrame` path on fixed scenes. A baseline's shaders are compared only when their Uniforms layout, argument-buffer length and kernel bindings match the current host code, and each scenario's mean raw radiance agrees within `--output-tolerance`. Otherwise no timings are printed. Current measurements, from September 28, 2026 at `84db5e3`, are in [tests/PERFORMANCE.md](tests/PERFORMANCE.md), with the unedited report in [tests/PERFORMANCE-raw.txt](tests/PERFORMANCE-raw.txt). The September 29 reservoir-splatting figures (moving-camera error in disoccluded pixels, time, memory and bias against reprojection) head that file, with their raw measurements in [tests/PERFORMANCE-splatting-raw.txt](tests/PERFORMANCE-splatting-raw.txt); the September 29 ReSTIR PT figures (error, bias, time and memory against ReSTIR GI) follow, with their reports in [tests/PERFORMANCE-restir-pt-raw.txt](tests/PERFORMANCE-restir-pt-raw.txt); the September 29 spatial neighbour selection figures follow, with their report in [tests/PERFORMANCE-neighbors-raw.txt](tests/PERFORMANCE-neighbors-raw.txt). Earlier speedup figures, which predate ReSTIR GI and could not be reproduced, have been withdrawn.

See [REFERENCES.md](REFERENCES.md) for algorithm sources, dependency versions, and implementation adaptations.

## Known limitations

- On the procedural scenes, ReSTIR GI reuses only the first diffuse indirect vertex; deeper and glossy transport use ordinary path tracing, and its practical reuse is biased by up to +0.25% of mean radiance. ReSTIR PT reuses every path and agreed with MIS within ±0.1%, but its shifts cost 1.3–2.3× the frame time: on the procedural scenes it lowers error by 0–20% at equal sample count but raises it by 22–105% at equal time, so the default (`IndirectReuse.automatic`) uses it only for imported scenes, where it wins at equal time (8–25% lower error). While the camera moves it lowers per-frame error by 37–75% in most scenes, at 1.7–3.6× the frame time. The **Indirect reuse** popup on the Render page overrides the default per project. Test builds (`-D VIBE_TESTING`) change the default everywhere with `VIBE_INDIRECT_REUSE=gi|pt|unified`. Use Standard MIS with fog and ring boost disabled for reference comparisons: at equal time it beats both ReSTIR modes for converged images on most scenes.
- ReSTIR PT reuses temporally only while the view changes; its duplication-map decorrelation (biased) is off, and replay stream compaction, light tiles and dual motion vectors are not implemented.
- Temporal reuse reprojects each pixel into the previous frame. Multi-layer reservoir splatting (Hong et al., SIGGRAPH 2026, on reservoir splatting by Liu et al., SIGGRAPH 2025; `HONG2026`, `LIU2025`) is implemented as an alternative for ReSTIR DI, GI and PT: while the camera moves it keeps reservoirs of recently hidden surfaces in a deep layer, so that disoccluded pixels regain their history. With unified ReSTIR PT it lowered the per-frame error of newly disoccluded pixels by up to 9–39% per scene (little with ReSTIR GI), but whole-image and MetalFX errors changed by only a few percent at 5–26% more frame time, so it is off by default (`TemporalReuse.automatic`). Its domains are point sampled rather than area reservoirs, it uses one deep layer, and it is disabled with a thin lens. Select it with the **Temporal reuse** popup on the Render page (stored in the project); test builds make it the default with `VIBE_TEMPORAL_REUSE=splatting`.
- Compatibility-guided neighbour selection costs 3–26% more frame time than the earlier uniform selection. On imported meshes it lowers ReSTIR GI's error substantially (40–61% at equal sample count in the measured fixtures). On the procedural scenes it is within about ±1%, or 7% lower on Cornell, which is 2–12% worse at equal time, so its default (`SpatialNeighborSelection.automatic`) uses it only for imported scene graphs, which now default to ReSTIR PT and its own paired neighbours. The **Spatial neighbours** popup on the Render page chooses either selection per project; test builds make uniform the default with `VIBE_SPATIAL_NEIGHBORS=uniform`.
- HDRI sampling uses a luminance-weighted lat-long distribution; very small or high-contrast features can still require additional samples.
- OpenUSD import is a scene snapshot, with partial material and light support. Animation, subdivision evaluation, volumes, curves, and USD export are unsupported.
- MaterialX support is a bounded importer, with no node editor or graph export. OCIO/ACES color management, UDIMs, displacement, and several advanced material features are unsupported.
- MetalFX can soften detail. OIDN works on the accumulated image; raw output remains available for comparison.
- Fog and the optional ring-caustic boost are approximate preview effects.

## Acknowledgments

Built with Apple Metal and MetalFX, Adobe OpenPBR, OpenUSD, and Intel Open Image Denoise. Optional HDRI test assets are from Poly Haven under CC0.

Third-party licenses and attribution are retained with the vendored dependencies and bundled resources. Full citations and implementation notes are in [REFERENCES.md](REFERENCES.md).
