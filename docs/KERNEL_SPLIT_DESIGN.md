# Kernel split: profile and design

Status: profiling done (2026-11-20); no split is implemented yet.

The next release aims to cut both noise per sample and frame time. This document records where the frame's GPU time goes on the Apple M4 and which restructuring the measurements support. The idea comes from `ZHENG2024COROUTINES` (GPU coroutines) and `LUISARENDER2022`, listed in `REFERENCES.md` as related work.

## Tool

`scripts/measure_passes.py` (a development tool, not part of the suite) renders still and orbiting frames at one sample per frame and prints the mean GPU time of every compute pass that `PathTracerRenderer.encodeSample` encodes. In `-D VIBE_TESTING` builds, `PathTracerRenderer.passTimer` (`PassTimer`) creates those encoders with Metal counter sampling at the encoder boundaries and sums the timestamps per encoder label.

- **Cases:** small fixtures by default, 480 × 270: the Cornell box and Pavilion (ReSTIR GI); a generated UV sphere with a glossy OBJ material on a matte floor (8,192 triangles); the 25 instanced bumpy patches of `tests/benchmark.py`; and the ASWF Shader Ball project when `build/reference-scenes` holds it. The three imported fixtures render with unified ReSTIR PT. `--large` adds Sponza and Bitterli's Kitchen and Living Room.
- **Turnaround:** all cases run in one process. The binary is cached in `build/measure-passes` by the hash of its Swift source, and it reads the MSL of `main.swift`'s `metalSource` literal from a file at run time, so an edit to the shaders alone is measured in about 13 s instead of about 60 s (a whole-program Swift compile).
- **Overrides:** `--depth`, `--rgb` and `--reuse` set the project's path depth, light transport and indirect reuse.
- **Spills:** with `--spills`, each case runs under `xctrace record --template 'Metal System Trace'` and the script lists the register spill sizes that the trace reports per encoder.

`MTLComputePipelineState.maxTotalThreadsPerThreadgroup` is 1,024 for every scene kernel on the M4, so it does not indicate register pressure there; the trace's spill events do.

## Measurements

Apple M4 (10-core GPU), macOS 27, 960 × 540, preview scale 1, spectral transport, path depth 16 unless stated, still camera (accumulating). GPU milliseconds per frame:

| Scene | Reuse | Frame | Largest passes |
| --- | --- | --- | --- |
| Pavilion (scene 0) | ReSTIR GI | 79.9 | Pass 2 (shading) 88%, Pass 1 12% |
| Cornell (scene 1) | ReSTIR GI | 26.2 | Pass 2 86%, Pass 1 14% |
| Sponza (OBJ) | unified ReSTIR PT | 313.8 | initial paths 92.7%, Pass 2 4.3% |
| Living Room (Mitsuba) | unified ReSTIR PT | 453.2 | initial paths 73.6%, paired shifts 22.1% |
| Kitchen (Mitsuba) | unified ReSTIR PT | 655.3 | initial paths 71.6%, paired shifts 25.2% |

While orbiting, ReSTIR PT's temporal reuse adds 13–17% (Kitchen 135 ms, Living Room 29 ms).

Register spills reported by the trace (Sponza): `restir_pt_initial_kernel` 16,064 B, `shading_kernel` 11,136 B, `restir_pt_temporal_kernel` 5,712 B, `restir_pt_shift_kernel` 5,184 B, `restir_temporal_kernel` 4,608 B. Pavilion's command buffers spill up to 6,992 B.

The fixtures at 480 × 270 show the same split (ms per frame, still camera):

| Fixture | Frame | Initial paths | Paired shifts |
| --- | --- | --- | --- |
| Cornell (ReSTIR GI) | 6.9 | — (Pass 2 5.7) | — |
| Pavilion (ReSTIR GI) | 21.6 | — (Pass 2 19.0) | — |
| UV sphere | 24.8 | 12.5 | 8.3 |
| Instanced patches | 17.7 | 9.0 | 4.4 |
| Shader Ball | 135.8 | 95.4 | 32.6 |

Ablations of `restir_pt_initial_kernel` on Sponza (ms per frame):

| Variant | Initial paths |
| --- | --- |
| Depth 16, spectral (default) | 290.7 |
| Depth 4 | 190.2 |
| Depth 2 | about 90 |
| RGB transport | 220.2 |
| Every material forced to Lambert in `pt_prepare` (temporary edit) | 105.4 |

Experiments on the fixtures (temporary shader edits, initial paths in ms per frame):

| Experiment | UV sphere | Shader Ball |
| --- | --- | --- |
| Baseline | 12.5 | 95.4 |
| Every material forced to Lambert in `pt_prepare` | 4.6 | 28.1 |
| `pt_connectable` reads a two-field lobe instead of the previous vertex's `Material` | 12.2 | 100.6 (noise) |
| `pt_prepare`, `pt_eval` and `pt_sample` marked `noinline` | 66.8 | 477.5 |

## Reading

- The imported scenes, not the procedural ones, are slow, and `restir_pt_initial_kernel` (`pt_generate`) dominates them, followed by `restir_pt_shift_kernel`. On Sponza the initial paths cost about 560 ns per pixel, far above what the hardware ray rate implies for the rays they trace (`docs/SCENE_STORAGE_DESIGN.md`: about 377 Mrays/s on incoherent closest-hit rays).
- The layered OpenPBR BSDF is the largest cost: forcing Lambert removes 62–71% of the initial paths on the fixtures and 64% on Sponza (an upper bound, since Lambert also changes the paths).
- Carrying less state does not help: the compiler already drops the `Material` fields that later steps never read, so a smaller record changed nothing.
- Calls are expensive on this GPU: real (non-inlined) calls into the BSDF made the kernel five times slower, consistent with the cost of the spills.
- Much of the cost is per path, not per bounce: depth 2 still costs 90 ms on Sponza.

## Options

1. **Cheaper BSDF work** (most direct): compile only the lobes a scene uses (the OpenPBR feature toggles and the Lambert fast path in progress on `perf/shading-throughput`), and avoid the second `OpenPBR_PreparedBsdf` that spectral transport prepares per vertex (RGB transport measured 24% faster on Sponza).
2. **Wavefront split of the path tree** (the coroutine paper's split points): a per-bounce host loop of a trace-and-resolve kernel and a vertex kernel (NEE, RIS candidate, BSDF sample), with the path state in a per-pixel buffer and a compacted queue of live paths. Traversal then runs without the BSDF's registers, and paths can be sorted by material before the vertex kernel. The BSDF arithmetic itself stays, so the gain is bounded by the occupancy and divergence the split removes; the reservoir and reconnection state must round-trip exactly (`tests/Fix_restir-pt.swift`, `tests/Fix_restcv.swift`).

`paired shifts` (`restir_pt_shift_kernel`, up to 34%) replays paths through the same BSDF code, so option 1 also applies there.
