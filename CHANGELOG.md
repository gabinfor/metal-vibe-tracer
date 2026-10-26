# Changelog

Metal Vibe Tracer is in early development: releases are validated builds, not stable APIs or file formats. Every method below is cited, with its adaptations, in [REFERENCES.md](REFERENCES.md); measurements are in [tests/PERFORMANCE.md](tests/PERFORMANCE.md) and [docs/SCENE_STORAGE_DESIGN.md](docs/SCENE_STORAGE_DESIGN.md).

## 0.3.0 — 2026-10-26

Light as a spectrum, in scenes made to show it: participating media (haze, milky and Rayleigh-scattering volumes), per-light spectra (blackbody, CIE presets, laser lines), spot and beam lights, and four spectral example scenes included with the app, rendered for the README without a denoiser. An optional indirect clamp removes fireflies at the cost of bias. Existing scenes render as before. Projects saved by 0.3.0 can hold media, light spectra and the clamp, which 0.2.x ignores. Validated on an Apple M4 (16 GB, 10-core GPU) with macOS 27: the GPU verification suite passes (198 checks).

### Rendering

- **Participating media** (docs/VOLUME_DESIGN.md): homogeneous scene haze (Lighting › Atmosphere › *Participating medium*, or `vibe:medium` attributes on a USD stage's default prim) and object interiors from OpenPBR `transmission_depth`, `transmission_scatter` and `transmission_scatter_anisotropy`, with index-matched boundaries (`specular_weight` 0), Henyey–Greenstein phase functions (`HG1941`) and an optional Rayleigh λ⁻⁴ law (`BUCHOLTZ1995`). Distances are sampled once for all wavelengths with a throughput-weighted mixture over them (`ADOBEOPENPBR`, `PBRT2023`). Scenes with media render with Standard MIS.
- **Per-light spectra**: each imported light can have a CIE preset, a blackbody temperature (`PLANCK`; UsdLux `colorTemperature`) or a narrow band such as a laser line, normalised to equal luminance and included in wavelength sampling; editable on the Materials page.
- **Spot and beam lights**: UsdLux `ShapingAPI` cones, softness and focus on rectangle and disk lights (`OPENUSD`), editable on the Materials page; shaped lights are selected in proportion to their cone's power.
- `Uniforms` grows from 304 to 336 bytes; per-slot material parameters from 3 to 8 float4.
- **Indirect clamp** (Render page; `StudioOptions.indirectClamp`, `"indirectClamp"` per showcase shot): an optional, biased per-sample cap on the luminance of indirect light (two or more scattering events; with unified ReSTIR PT its whole estimate), which removes fireflies. Off by default; when off, renders are bit-identical to before (`tests/Fix_clamp.swift`). `Uniforms.mediumOptions` is renamed `pathOptions`, whose w holds the cap.

### Scenes and import

- **Spectral example scenes**, included with the app: **Tyndall Tank** (Rayleigh scattering of a beam) and **Lamp Spectra** (five lamp spectra in haze), and **Newton's Colour Series** (thin-film interference: soap films 100–800 nm, anodized titanium 30–150 nm; `DIAMANTI2014`) and **Abbe Row** (a slit seen through 60° prisms of SCHOTT N-SF11, F2, N-BK7 and N-FK51A at minimum deviation; `SCHOTTGLASS`). They are OpenUSD stages in `Examples/Spectral`, listed first in File › Open Example Scene and on the File page, and open without a download or an import report.
- **OpenUSD implicit prims:** `Sphere`, `Cube` and `Cylinder` prims are tessellated from their schema attributes (smooth normals, outward winding) instead of being skipped (`OPENUSD`).
- `scripts/render_showcase.py` exports the raw accumulation unless a shot sets `"denoise": true`, and prints samples over the target and elapsed time every 30 s.

## 0.2.1 — 2026-10-23

The app now opens instantly and shows progress for everything it loads, and the README's production scenes open from inside the app. Validated on an Apple M4 (16 GB, 10-core GPU) with macOS 27: the GPU verification suite passes (192 checks).

### Launch and progress

- **Instant launch:** the window opens at once on an empty start screen (open project, import OBJ/USD, built-in scenes, Restore Last Session) instead of compiling every GPU pipeline on the main thread and restoring the autosave. The core pipelines compile concurrently in the background with a progress bar; ReSTIR PT, reservoir splatting and stochastic pairwise MIS compile on demand (`METALSHADERCOMPILE`). First launch of a new build: window 293 s → 0.97 s, renderer ready after 37 s; cached: 0.21 s → 0.19 s to the window (`tests/PERFORMANCE.md`, "Launch time").
- **Progress everywhere:** a progress bar with the current step (and Cancel where supported) for shader compilation, project open/save/restore, OBJ/MTL import with texture decoding and downscaling and MaterialX preparation, USD import, mesh hierarchy and acceleration-structure builds, exports and OIDN. USD imports no longer block the window with a sheet.
- Exports reuse the preview's hierarchies and acceleration structures instead of rebuilding them on the main thread.

### Scenes and import

- **Example scenes:** File › Open Example Scene (and the File page) opens Crytek Sponza, San Miguel 2.0 and the Amazon Lumberyard Bistro (exterior, interior) from Morgan McGuire's Computer Graphics Archive (`MCGUIRE2017`) with the README images' camera and lighting. Nothing is bundled: after a consent sheet that gives the size, destination and license, each archive is downloaded once, checked against a pinned size and SHA-256 digest, extracted into Application Support and imported through the OBJ/MTL path. Credits and licenses are shown in the app and carried in the project's import report.
- The showcase shot settings, including `emissionScale`, moved from `scripts/render_showcase.py` into app code (`ShowcaseShot`, `ProjectDocument.scaleImportedEmission`); the app bundles `scripts/showcase.json`.

## 0.2.0 — 2026-10-23

121 commits since 0.1.0. Validated on an Apple M4 (16 GB, 10-core GPU) with macOS 27: the GPU verification suite passes (189 checks).

### Rendering

- **ReSTIR PT** with the ReSTIR PT Enhanced improvements (`RESTIRPT2022`, `RESTIRPTE2026`): whole-path reuse, including glossy, mirror and glass paths; the default for imported scenes.
- **Spatial and temporal reuse options:** compatibility-guided neighbour selection (`COMPATRESTIR2026`), stochastic pairwise MIS (`SPMIS2026`), multi-layer reservoir splatting (`HONG2026`, `LIU2025`) and spatio-temporal control variates for ReSTIR PT shading (`RESTCV2026`), each selectable on the Render page.
- **Spectral light transport**, now the default: four wavelengths per path, bounded-MESE reflectance spectra from sRGB, CIE illuminant presets for lights and the sun, dispersion and thin-film interference (`PETERS2019`, `FOURIERSRGB2019`, `PETERSBLOG2025`, `HERO2014`).
- **Z++ sampler** (`ZPP2026`), opt-in for every strategy.
- **Two-level acceleration** with instancing: Metal hardware ray tracing where a launch-time check finds it watertight, an exact software 4-wide BVH otherwise; batched builds and instance-structure refits.
- **Anisotropic ray-cone texture filtering** (`RAYCONES2021`) with pbrt-v4's sample-count footprint scale at primary hits (`PBRT2023`).
- **Watertight ray/triangle intersection**, error-bounded ray offsets, and corrected HDRI, sun, sphere and emitter light sampling.

### Materials

- **OpenPBR alpha cutouts** from `geometry_opacity` (stochastic coverage), with an opaque-instance fast path in hardware traversal.
- **Glass:** OpenPBR `transmission_color` and `geometry_thin_walled`; MTL glass (`illum` 4/6/7/9, or constant dissolve) as smooth, thin-walled or solid transmission.
- **MaterialX:** graph-driven emission, constant `specular_color`, images downscaled to fit the GPU texture budget, and fixes to rotate2d, image decoding and colour spaces.
- **Open Image Denoise guides** taken behind smooth glass, so glass no longer blurs what shows through it.

### Scenes and import

- **Large scenes:** indexed geometry (64 B per triangle with software traversal, 150 B with hardware, down from 160 and 246), 1,024 material slots, 4,096 graph images, 65,535 scene nodes; memory budgets and triangle limits scale with the Mac's GPU. San Miguel (10 M triangles, 287 materials) imports from OBJ in about 12 s.
- **OBJ/MTL import:** a streaming OBJ reader; MTL materials translated to OpenPBR MaterialX, including glass, coverage, emission and bump-to-normal conversion at a strength calibrated on authored normal maps.
- **OpenUSD:** binary mesh sidecars instead of JSON, PreviewSurface emission, UsdLux power and sun fixes, robust import.
- **Projects:** format 4 (indexed meshes, content-addressed assets, autosave sidecars); embedded images up to 1 GiB. Formats 1–3 open and are saved as format 4; 0.1.0 cannot open format-4 projects.

### Performance and scaling

- Samples per frame are sized from measured GPU time, the viewport follows the display's refresh rate, and exports keep two command buffers in flight, so faster GPUs are not held to one sample per frame.
- Cutout scenes keep opaque instances on the hardware fast path (Sponza 15–23% faster, Bistro about 10%).

### Validation

- **Mitsuba 3** comparisons (`MITSUBA3`, `BITTERLI2016`): the built-in Cornell box agrees within 0.02% of mean radiance and Veach MIS within 0.11%; five of seven Bitterli scenes agree within 2.5%, and the remaining gaps are documented model differences.
- The verification suite runs in the Swift 6 language mode through the production `renderFrame` path, with statistical tolerances and MetalFX energy, fallback and motion checks.

### Documentation

- README with production-scene renders (Sponza, San Miguel, Bistro), validation side-by-sides and before/after comparisons; CONTRIBUTING.md; the MIT license scoped to the project's own code, with third-party notices.

### Known limitations

- ReSTIR PT costs 1.3–2.3× the frame time, so procedural scenes default to first-bounce ReSTIR GI.
- Spectral MIS for rough dispersive glass and lane splitting are experimental and off by default.
- Glass makes paths continue into building interiors: a 960×540, 64-spp Bistro exterior export took 179 s with glass against 67 s with the former opaque panes. The cost of the new texture filtering against the old has not been measured in the same harness yet.
- Large texture sets are downscaled to fit the GPU budget; block compression is not implemented.
- OpenUSD import is a snapshot (no animation, subdivision, volumes or curves); MaterialX support is a bounded importer.
- The app is an unsigned, non-notarized build.

## 0.1.0 — 2026-09-21

First development release: a Metal path tracer with ReSTIR DI and GI, OpenPBR materials through Adobe's implementation, a bounded MaterialX importer, OpenUSD import, MetalFX preview, Open Image Denoise exports and portable projects. Validated on an Apple M4 with macOS 26.
