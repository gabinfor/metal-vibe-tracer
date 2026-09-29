# ReSTIR spatial neighbour selection — September 29, 2026

Compatibility-guided selection (`REFERENCES.md` `COMPATRESTIR2026`, now the default)
versus the earlier uniform selection (`PathTracerRenderer.spatialNeighbors = .uniform`),
on an Apple M4 (10-core GPU, 16 GB), macOS 27.0 (26A428), Swift 6.4. Source: `d5a449f` plus
this change (uncommitted at measurement; the committed shaders are identical).

## Equivalence and cost against `main`

`python3 tests/benchmark.py --baseline <main.swift of d5a449f> --rounds 2 --frames 12` with
`VIBE_ACCELERATION=flat`, which puts both renderers on the flat BVH (the script forces it
for the baseline). The raw report is [`PERFORMANCE-neighbors-raw.txt`](PERFORMANCE-neighbors-raw.txt).
With `VIBE_SPATIAL_NEIGHBORS=uniform` and `--output-tolerance 0`, all six scenarios gave
mean raw radiance identical to the baseline's, and timings matched within noise
(for example, Pavilion 26.29 vs 26.33 ms). Default (compatibility) mode, median GPU ms per frame, 640×480:

| Scene fixture | MetalFX | Baseline `d5a449f` | Current | Change |
| --- | --- | ---: | ---: | ---: |
| Default Pavilion | off | 26.29 | 27.83 | +5.9% |
| Default Pavilion | on | 30.89 | 32.81 | +6.2% |
| Pavilion with coated OpenPBR floor | off | 32.80 | 34.19 | +4.2% |
| Pavilion with coated OpenPBR floor | on | 38.30 | 39.38 | +2.8% |
| Cornell box | off | 11.85 | 13.51 | +14.0% |
| Cornell box | on | 15.16 | 17.12 | +12.9% |
| Default Pavilion, MIS (no ReSTIR) | off | 22.28 | 22.45 | +0.8% |
| Imported mesh (8,130 triangles), flat BVH | off | 14.94 | 16.43 | +10.0% |
| Imported mesh (8,130 triangles), flat BVH | on | 18.34 | 20.03 | +9.2% |
| Instanced scene graph, flat BVH | off | 44.56 | 48.00 | +7.7% |
| Instanced scene graph, flat BVH | on | 47.94 | 52.49 | +9.5% |

With the default hardware traversal, paired interleaved runs (16 pairs of 10 frames,
median of the per-pair ratios, MetalFX off) measured, at 640×480 and 320×240: Pavilion
+6.0% / +7.3%, Pavilion close-up — / +6.9%, coated floor +3.4% / +4.4%, Cornell +13.2% / +14.5%,
Cornell glass & mirror +10.6% / +10.8%, imported UV sphere +20.1% / +33.6%, instanced
patches +25.7% / +23.8%. Most of the extra time is spatial reuse that the uniform
selection's rejections used to skip; the selection taps and the 1/Z support test add the rest.

## Error at equal sample count and equal time

The scratch driver used for these figures is not part of the suite. It renders through the
production `render()` path at 320×240 and path depth 16. Each figure is the mean over 4
independent seed sequences of the accumulated image's MSE (linear RGB, all pixels) against
a 1,024-frame MIS reference. Equal-time figures scale by the 640×480 cost ratio above,
assuming MSE ∝ 1/frames (the 16- to 64-frame ratios measured 3.7–4.7).

| Scene | Uniform, 64 frames | Compatibility, 64 frames | Equal sample | Equal time |
| --- | ---: | ---: | ---: | ---: |
| Pavilion (default view) | 0.2879 | 0.2883 | +0.1% | +6% |
| Pavilion close-up (copper sphere, floor) | 0.8680 | 0.8708 | +0.3% | +7% |
| Pavilion, coated OpenPBR floor | 0.3457 | 0.3424 | −1.0% | +2% |
| Cornell box | 1.855e-4 | 1.726e-4 | −7.0% | +5% |
| Cornell glass & mirror | 5.283e-3 | 5.329e-3 | +0.9% | +12% |
| Imported UV sphere on a floor | 1.967e-3 | 1.178e-3 | −40% | −28% |
| Instanced bumpy patches (25 × 19,968 triangles) | 6.822e-3 | 2.673e-3 | −61% | −51% |

On the "hard" 10% of diffuse pixels (the fewest uniform-box neighbours passing the binary
test, as in the paper's Section 7), 64-frame MSE fell by 63% (sphere), 43% (patches) and 10%
(Cornell). It rose by 30% on the coated-floor Pavilion. The ASWF Standard Shader Ball has no
diffuse primary hits, so no ReSTIR spatial reuse runs there and both modes are identical.
After 4 frames at 640×480, the MetalFX display error (tone-mapped, against a 1,024-frame MIS
reference) was 6.39e-4 → 3.51e-4 on Cornell and 7.18e-4 → 7.68e-4 on Pavilion (uniform →
compatibility); after 16 frames it was 3.93e-4 → 3.85e-4 and 8.59e-4 → 8.66e-4. Mean-radiance bias against MIS for both modes is listed under `COMPATRESTIR2026` in
`REFERENCES.md`: compatibility mode is closer to MIS in six of seven scenes.

# Renderer performance — September 28, 2026 (acceleration structure)

Measured with `python3 tests/benchmark.py --baseline <main.swift of 192724f> --rounds 3 --frames 12
--report tests/PERFORMANCE-raw.txt` (run through the suite's GPU slot lock, no other GPU suite
running). The unedited report, including every per-run mean radiance, is committed as
[`PERFORMANCE-raw.txt`](PERFORMANCE-raw.txt). "Baseline" is the shaders of `192724f` (the flat
median BVH) compiled against the current host code, which gives the baseline renderer the flat
mesh layout (`MeshAcceleration.flat`); "current" is this change with its default traversal.

## Environment

| | |
| --- | --- |
| Source | `192724f` (`main`) plus the acceleration-structure change (uncommitted at measurement; the committed source is identical) |
| Device | Apple M4 (10-core GPU), 16 GB unified memory |
| System | macOS 27.0 (26A428), Apple Swift 6.4 (`-O`, arm64) |
| Default traversal | hardware (`MaterialLibrary.hardwareWatertight`: 0 leaks on this device) |
| Thermal state | fair (1) at the end of the run |

## Method

- Every frame goes through the production `PathTracerRenderer.renderFrame` path (the
  `render()` helper in `tests/GPUChecks.swift`): pass 1 G-buffer/ReSTIR temporal, pass 2
  shading, MetalFX when enabled, and display tone mapping.
- 640×480, preview scale 1, path depth 16, default sun/sky, default camera preset of each
  scene. Strategy ReSTIR DI+GI unless marked MIS.
- Each run starts from a reset accumulation and the same jitter/seed sequence, renders 12
  frames and times frames 5–12 (GPU command-buffer start to end, no CPU readback). Three
  rounds, interleaved with the baseline, so each median is over 24 frames.
- The imported-mesh fixture is scene 6 with a generated 8,130-triangle UV sphere on a floor
  quad (a graph-less mesh). The instanced fixture, new with this change, is a scene graph of 25
  rotated, scaled instances of one bumpy 19,968-triangle patch (499,200 rendered triangles, the
  most the flat BVH of `192724f` could render).

## Results (median GPU ms per frame; min–max in the raw report)

| Scene fixture | Strategy | MetalFX | Baseline (flat BVH) | Current | Change |
| --- | --- | --- | ---: | ---: | ---: |
| Default Pavilion (scene 0) | ReSTIR | off | 33.58 | 31.06 | −7.5% |
| Default Pavilion (scene 0) | ReSTIR | on | 38.88 | 36.55 | −6.0% |
| Pavilion with coated OpenPBR floor | ReSTIR | off | 42.79 | 40.76 | −4.7% |
| Pavilion with coated OpenPBR floor | ReSTIR | on | 48.23 | 46.14 | −4.3% |
| Cornell box (scene 1) | ReSTIR | off | 13.51 | 12.98 | −3.9% |
| Cornell box (scene 1) | ReSTIR | on | 18.24 | 17.81 | −2.4% |
| Default Pavilion (scene 0) | MIS | off | 27.12 | 25.33 | −6.6% |
| Imported mesh (scene 6, 8,130 triangles) | ReSTIR | off | 14.71 | 8.20 | −44% |
| Imported mesh (scene 6, 8,130 triangles) | ReSTIR | on | 19.13 | 12.45 | −35% |
| Instanced scene graph (25 × 19,968 triangles) | ReSTIR | off | 49.94 | 15.71 | −69% |
| Instanced scene graph (25 × 19,968 triangles) | ReSTIR | on | 58.74 | 20.01 | −66% |

Every scenario's mean raw radiance agrees with the baseline within the 5% tolerance. Scenes
0–5 run kernels compiled without the mesh code (`VIBE_MESHES=0`, see below), which is why they
are slightly faster than the baseline, whose kernels still carried the flat BVH. Figures
describe these fixtures on this machine; compare figures within one run.

With the software traversal forced (`VIBE_ACCELERATION=twoLevel`, same session, three rounds;
report not committed), the two scene-6 fixtures measured 13.96 vs 14.74 ms (imported mesh) and
46.21 vs 50.92 ms (instanced), MetalFX off: the two-level SAH hierarchy alone is 5–9% faster on
these fixtures, and hardware traversal accounts for the rest.

## Acceleration structure selection

The gate compared three candidates (prototype kernels using the renderer's exact
`intersect_mesh_triangle`, `mesh_box_ray` and `mesh_node_hit` code; 1,600,000 rays per run;
`primary` = camera rays, `diffuse` = random directions from the primary hits). GPU ms:

| Scene (triangles) | Rays | Median BVH (before) | Binned SAH, binary | Binned SAH, 4-wide (adopted) | Metal boxes + software test | Metal triangles |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Curved patch (999,698) | primary | 10.45 | 5.89 | 5.92 | 4.39 | 1.46 |
| Curved patch (999,698) | diffuse | 22.22 | 17.23 | 13.83 | 19.17 | 1.89 |
| Triangle soup (500,000) | primary | 28.63 | 31.77 | 24.28 | 185.90 | 2.25 |
| Triangle soup (500,000) | diffuse | 44.69 | 46.72 | 33.46 | 202.96 | 2.67 |
| Floor + 400 thin pillars (339,200) | primary | 45.50 | 6.57 | 7.21 | 13.65 | 1.25 |
| Floor + 400 thin pillars (339,200) | diffuse | 62.67 | 17.51 | 12.32 | 20.80 | 1.64 |

Leaf size 2 was fastest (leaf size 4: patch 6.55/15.36, soup 25.61/37.93, pillars 7.58/13.69;
leaf size 8 slower still); 32 bins instead of 16 changed nothing. A quantized 80-byte 4-wide node
(`REFERENCES.md` `CWBVH2017`) was 7–12% slower than the 128-byte float node. The
4-wide binned-SAH build of the 1,000,000-triangle patch takes 104 ms on the CPU (the median
build 485 ms). "Metal boxes + software test" (one bounding box per SAH leaf, the watertight test
in an `intersection_query`) is exact but not reliably faster than software.

Metal's triangle intersector was 4–13× faster than the adopted software hierarchy but is gated on watertightness (`METALRT`): rays
aimed at shared edges of a curved patch leaked through packed float3 vertices (20 of 14,598 at
16×16 cells, 71 of 242,694 at 64×64, 309 of 3,919,878 at 256×256; similar for welded indexed
vertices, 1 km offsets and 1 mm scale), and never through the unwelded `MeshTriangle` layout the
renderer now uses (all of those fixtures, compacted or not, `preferFastIntersection` or not,
identity or rotated/scaled instances). With that layout the hardware traversal passed every other
gate check as well (`tests/Fix_accel.swift`, and the whole suite with
`VIBE_ACCELERATION=hardware`), so it is the default where the run-time probe finds no leak.

## Large instanced scene (`tests/Fix_accel.swift`)

40 instances of a 199,712-triangle patch (7,988,480 rendered triangles, 16× the former
500,000-triangle cap), 320×240, MIS, 12 frames (median of frames 5–12), same run:

| | Software two-level | Hardware | Flat BVH |
| --- | ---: | ---: | ---: |
| Mesh GPU memory | 30.4 MiB | 48.5 MiB | refused (975 MiB of flattened triangles alone) |
| Build | 43 ms | 73 ms | — |
| Median frame | 8.04 ms | 3.28 ms | — |

Five instances (998,560 rendered, within the flat BVH's limit): flat 551 ms build, 2.85 ms per
frame, 145.9 MiB; software two-level 36 ms, 2.26 ms, 30.4 MiB; identical mean radiance. Transform,
visibility and binding edits rebuild no asset hierarchy (checked by counters in
`tests/Fix_accel.swift`).

## Kernels without mesh code (scenes 0–5)

With the two-level and hardware traversal inlined into every kernel, scenes 0–5 (which never
trace a mesh) were 13–17% slower than the baseline in paired runs (Pavilion 35.92 vs 31.56 ms).
Compiling the same source a second time with the macro `VIBE_MESHES=0` removes the dead mesh
code; those kernels (`PathTracerRenderer.proceduralKernels`) measured at or below the baseline
(table above). The second library costs about 0.7 s of shader compilation plus about 7.8 s of
pipeline creation on the first launch after a shader change; the Metal shader cache serves later
launches.

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
