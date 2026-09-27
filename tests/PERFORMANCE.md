# Renderer performance — September 27, 2026

Measured with `python3 tests/benchmark.py --rounds 3 --frames 12 --report tests/PERFORMANCE-raw.txt`
(run through the suite's GPU slot lock, no other GPU suite running). The unedited report,
including every per-run mean radiance, is committed as
[`PERFORMANCE-raw.txt`](PERFORMANCE-raw.txt).

## Environment

| | |
| --- | --- |
| Source | `0eb96bb` — audit base `7a54652` plus the remediation packages (`fix-integration` branch), no uncommitted source changes |
| Device | Apple M4, 16 GB unified memory |
| System | macOS 27.0 (26A428), Apple Swift 6.4 (`-O`, arm64) |
| Thermal state | nominal (0) at the end of the run |

## Method

- Every frame goes through the production `PathTracerRenderer.renderFrame` path (the
  `render()` helper in `tests/GPUChecks.swift`): pass 1 G-buffer/ReSTIR temporal, pass 2
  shading, MetalFX when enabled, and display tone mapping.
- 640×480, preview scale 1, path depth 16, default sun/sky, default camera preset of each
  scene. Strategy ReSTIR DI+GI unless marked MIS.
- Each run starts from a reset accumulation and the same jitter/seed sequence, renders 12
  frames and times frames 5–12 (GPU command-buffer start to end, no CPU readback). Three
  rounds, so each median is over 24 frames. All renderers and the MetalFX scaler are warmed
  before timing.
- The imported-mesh fixture is scene 6 with a generated 8,130-triangle UV sphere on a floor
  quad, exercising the mesh BVH path.

## Results (median GPU ms per frame; min–max in the raw report)

| Scene fixture | Strategy | MetalFX off | MetalFX on |
| --- | --- | ---: | ---: |
| Default Pavilion (scene 0) | ReSTIR | 30.28 | 37.00 |
| Pavilion with coated OpenPBR floor | ReSTIR | 38.44 | 44.58 |
| Cornell box (scene 1) | ReSTIR | 12.48 | 17.29 |
| Imported mesh (scene 6, 8,130 triangles) | ReSTIR | 12.62 | 17.99 |
| Default Pavilion (scene 0) | MIS | 25.14 | — |

MetalFX adds about 5–7 ms per frame at this size. Individual MetalFX frames occasionally
took up to 32–54 ms (see the raw report's max values); the medians are insensitive to such outliers.
These figures describe these fixtures on this machine; they are not window frame rates
and are not comparable with the September 4 table this file used to contain, which predated
ReSTIR GI, the primary-surface cache and the remediation changes.

## Before/after comparisons

`--baseline previous/main.swift` compiles a previous version's embedded shaders against the
current host code and interleaves both. It is accepted only if the baseline's MSL
`Uniforms` size and every field offset (304 bytes), the material argument-buffer length
and the kernel bindings match what the host binds, and each scenario's mean raw radiance
agrees within `--output-tolerance` (default 5%); otherwise no timings are printed.

The audit base `7a54652` is rejected by that check: its `Uniforms` has a `padding` field
where the host writes `reservoirHistoryReset` and no `reservoirHistory`, so a paired base-versus-remediation
comparison with the current host code is not meaningful, and none is reported here.
