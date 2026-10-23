# Changelog

Metal Vibe Tracer is in early development: releases are validated builds, not stable APIs or file formats. Every method below is cited, with its adaptations, in [REFERENCES.md](REFERENCES.md); measurements are in [tests/PERFORMANCE.md](tests/PERFORMANCE.md) and [docs/SCENE_STORAGE_DESIGN.md](docs/SCENE_STORAGE_DESIGN.md).

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
