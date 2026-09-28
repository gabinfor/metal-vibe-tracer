# Renderer performance — September 28, 2026

Measured with `python3 tests/benchmark.py --rounds 3 --frames 12 --report tests/PERFORMANCE-raw.txt`
(run through the suite's GPU slot lock, no other GPU suite running). The unedited report,
including every per-run mean radiance, is committed as
[`PERFORMANCE-raw.txt`](PERFORMANCE-raw.txt).

## Environment

| | |
| --- | --- |
| Source | `84db5e3` (`main`): the remediation packages plus the 2026-09-28 follow-up fixes, no uncommitted source changes |
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
| Default Pavilion (scene 0) | ReSTIR | 26.11 | 31.60 |
| Pavilion with coated OpenPBR floor | ReSTIR | 33.26 | 38.76 |
| Cornell box (scene 1) | ReSTIR | 11.81 | 16.08 |
| Imported mesh (scene 6, 8,130 triangles) | ReSTIR | 13.80 | 17.22 |
| Default Pavilion (scene 0) | MIS | 22.09 | — |

MetalFX adds about 3.4–5.5 ms per frame at this size. The slowest single frame in this run
took 41.3 ms (coated floor, MetalFX on; see the raw report's max values). The medians are
insensitive to such outliers. These figures describe these fixtures on this machine; they
are not window frame rates.

The scenes without imported meshes are 5–14% faster than in the September 27 run at `0eb96bb`
(for example Pavilion 30.28 → 26.11 ms). The paired comparison below finds no difference
between the shaders before and after the follow-up for those scenes, so the difference
comes from other changes between the two revisions or from run-to-run conditions, not from
the watertight test. Compare figures within one run rather than across runs.

## Watertight intersection cost (imported meshes)

Commit `9f80023` replaced the Möller–Trumbore-style mesh test with the watertight algorithm
of Woop, Benthin and Wald (`REFERENCES.md` `WOOP2013`). The new test transforms each vertex
into the ray's sheared frame, evaluates three edge functions without FMA contraction, and
traverses boxes enlarged by a per-ray rounding bound. A paired run with the shaders of
`a0586f2`, the commit before the change, isolates the cost:
`--baseline <a0586f2 main.swift> --rounds 3 --frames 12`, same session, interleaved rounds.
That run's report is not committed.

| Imported mesh (8,130 triangles) | Before (`a0586f2`) | After (`84db5e3`) | Change |
| --- | ---: | ---: | ---: |
| MetalFX off | 12.09 | 13.30 | +1.21 ms (+10%) |
| MetalFX on | 15.82 | 17.37 | +1.55 ms (+10%) |

Only scene 6 traces mesh triangles, and the cost grows with the number of mesh triangles
tested per ray. For the other fixtures, whose code paths differ only in the MetalFX guide
kernel, the paired run measured −0.8 to +0.1 ms between baseline and current. The one
exception is the coated floor with MetalFX off: 33.19 ms vs 35.14 ms, with a current maximum
of 37.73 ms. The main run above measured 33.26 ms for it, so this is run-to-run noise. The imported-mesh
fixture's mean raw radiance changed from 0.6370 to 0.6186 (−2.9%) with the new test; both
variants are deterministic across rounds, and the difference is within the benchmark's
default 5% output tolerance.

## Before/after comparisons

`--baseline previous/main.swift` compiles a previous version's embedded shaders against the
current host code and interleaves both. It is accepted only if the baseline's MSL
`Uniforms` size and every field offset (304 bytes), the material argument-buffer length
and the kernel bindings match what the host binds, and each scenario's mean raw radiance
agrees within `--output-tolerance` (default 5%); otherwise no timings are printed.

The audit base `7a54652` is rejected by that check: its `Uniforms` has a `padding` field
where the host writes `reservoirHistoryReset` and no `reservoirHistory`, so a paired base-versus-remediation
comparison with the current host code is not meaningful, and none is reported here.
