# Renderer performance check — September 4, 2026

Apple M4, 640×480, ReSTIR. Paired original/optimized pipelines used the same
host code, shader resources, camera fixtures, and sample indices. Both MetalFX
instances were warmed first. Two rounds reverse variant order; each measurement
uses 12 frames and excludes the first four from timing. Table entries are medians
of 16 GPU command-buffer times per case, including rendering and presentation,
excluding CPU readback. The reported final thermal state was fair (1).

| Scene fixture | MetalFX | Before (ms) | After (ms) | Speedup |
| --- | --- | ---: | ---: | ---: |
| Default Pavilion | Off | 68.11 | 14.57 | 4.67× |
| Default Pavilion | On | 92.00 | 23.72 | 3.88× |
| Pavilion with coated OpenPBR floor | Off | 70.28 | 27.72 | 2.54× |
| Pavilion with coated OpenPBR floor | On | 107.12 | 65.51 | 1.64× |
| Cornell box | Off | 73.43 | 10.17 | 7.22× |
| Cornell box | On | 78.91 | 14.07 | 5.61× |

These measurements describe these fixtures and this run, not guaranteed window
FPS. Standalone measurements varied under GPU load; the paired results above
are the comparison used. No resolution, path-depth, texture, or denoiser-quality
setting was reduced. Noise patterns change because eligible paths use a simpler
diffuse sampler and non-diffuse paths no longer consume unused reservoir draws.

Changes: Lambert fast path for legacy diffuse; shared layered BSDF/PDF
preparation; skip reservoir work on ineligible surfaces; skip unused texture
footprint calculations; Metal relaxed arithmetic, retaining NaN/Inf handling.

Validation: complete GPU regression suite with Metal API validation, plus
adapter checks comparing the diffuse fast path with full upstream OpenPBR and
the combined evaluator with separate BSDF/PDF evaluation. Energy, grazing
cylinder, texture, material, and MetalFX checks passed.

Reproduce with `python3 tests/benchmark.py /path/to/before/main.swift` after
building, using a baseline with the same host layout and shader resources.
Raw report for this run: `build/checks/performance.txt`.

Source SHA-256:

- Before: 3d19ffbd7c3956d3397b83c7a218c0bcecece60aebe9711e42a8425990e9f117
- After: 25329ef3b2dcb03babafd051acb526acc27feb8ce38a2d7863c63c17b8ff0be4
