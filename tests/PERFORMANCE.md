# Spectral light transport — October 3, 2026

Spectral transport (`REFERENCES.md` `PETERSBLOG2025`, `PETERS2019`, `FOURIERSRGB2019`, `HERO2014`, `CIEDATA`; `LightTransport.spectral`, **Light transport → Spectral**; [docs/SPECTRAL_DESIGN.md](../docs/SPECTRAL_DESIGN.md)) against RGB transport. Setup: Apple M4 (10-core GPU, 16 GB), macOS 27.0, source `6ed36c2` plus this change (uncommitted at measurement; the shaders measured equal the committed ones up to the near-grey shortcut of `spectral_lagrange`, which changed the grey-world means by less than 0.01%). Scratch drivers render through the production `renderFrame` path, path depth 16, the default Z++ sampler. The unedited figures are in [`PERFORMANCE-spectral-raw.txt`](PERFORMANCE-spectral-raw.txt).

## Frame time

Median GPU frame time at 640×480 (frames 5–12):

| Scene, strategy | RGB | Spectral | Change |
| --- | ---: | ---: | ---: |
| Cornell, ReSTIR GI | 12.56 ms | 17.96 ms | +43% |
| Cornell glass & mirror, ReSTIR GI | 13.41 ms | 18.95 ms | +41% |
| Pavilion, MIS | 23.27 ms | 31.21 ms | +34% |
| Pavilion, ReSTIR GI | 27.68 ms | 41.49 ms | +50% |
| Pavilion, coated floor, ReSTIR GI | 35.06 ms | 53.20 ms | +52% |
| Imported UV sphere, unified ReSTIR PT | 13.70 ms | 23.47 ms | +71% |

A second run (the equal-time table below) measured +6% to +48% for the same scenes, and `tests/Fix_spectral.swift` +13% to +44% at 320×240: the overhead is large everywhere, against Peters' 2–36% (≤ 0.3 ms) on an RTX 5070 Ti. Disabling parts in turn attributed it roughly to colour conversions at every vertex (≈ 30 points: the grid's eight loads and the bounded MESE per base colour, specular colour and emitter) and register pressure from float4 throughput and the second OpenPBR preparation (≈ 10 points). Caching the conversions per vertex or per kernel made frames 5–30% slower (more registers in the path loops) and was reverted; the host solves the area light's multipliers once per frame instead.

## Error at equal sample count and equal time

Linear MSE of 64 accumulated frames at 160×120 (default strategy: ReSTIR, the scene's default indirect reuse) against a 2,048-frame MIS reference of the same transport, mean of 3 independent sequences; equal-time ratio = spectral MSE × time / (RGB MSE × time):

| Scene | MSE RGB | MSE spectral | Equal samples | Frame time | Equal time |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cornell | 2.461e-4 | 2.675e-4 | ×1.09 | +6% | ×1.15 |
| Cornell glass & mirror | 4.975e-3 | 5.358e-3 | ×1.08 | +32% | ×1.42 |
| Pavilion | 0.2289 | 0.2529 | ×1.10 | +48% | ×1.64 |
| Pavilion, coated floor | 0.3299 | 0.3346 | ×1.01 | +43% | ×1.45 |
| Imported UV sphere | 5.298e-4 | 6.550e-4 | ×1.24 | +38% | ×1.71 |

Four stratified, importance-sampled wavelengths add 1–24% colour noise per sample; with the frame time, spectral transport needs 1.15–1.71 times RGB's time for the same error in these RGB-defined scenes.

## Converged RGB against spectral

The two transports' 2,048-frame MIS references differ by what RGB gets wrong in interreflections of coloured surfaces (relative mean, RGB / spectral − 1, R, G, B): Cornell +1.2%, +0.3%, +1.0%; Cornell glass & mirror +1.8%, +0.2%, +0.7%; Pavilion +3.0%, −0.4%, +1.5% (coated floor the same); imported UV sphere (grey) −0.1%, +0.1%, 0.0%. In a grey world (grey OpenPBR room, white light) the transports agree within 0.3% of the mean, 2–4 tile-clustered standard errors (`tests/Fix_spectral.swift`), and six test colours rendered on a wall round-trip within 0.05 8-bit steps beyond three standard errors. The light and sun presets render their 1 nm reference colours within 1.3 standard errors per channel.

Spectral ReSTIR keeps RGB ReSTIR's bias against MIS of the same transport (relative, R, G, B, coloured Cornell box, ± standard error ≈ 0.15%): ReSTIR GI +1.43, +1.78, +1.18% (RGB +1.38, +1.71, +1.28%); ReSTIR PT +0.51, +0.10, +0.12% (RGB +0.60, +0.07, +0.24%); unified ReSTIR PT +0.71, +0.03, +0.27% (RGB +0.70, +0.05, +0.37%); with ReSTCV +0.57, +0.12, +0.05% (RGB +0.67, +0.08, +0.18%); with stochastic pairwise MIS +0.76, −0.05, +0.19% (RGB +0.73, −0.03, +0.30%); ReSTIR GI with stochastic pairwise MIS +0.41, +0.68, +0.41% (RGB +0.39, +0.59, +0.46%). Paths shifted back into their own pixel reproduce F in 99.6–100% of cases, as in RGB.

## Colour conversion

Round trip of every 8-bit sRGB code (16,777,216) through the renderer's float32 conversion with relaxed math (`tests/Fix_spectral.swift`): max 0.459 8-bit steps, mean 0.012; 22 codes above 0.4, none above 0.5. Without the refinement the coarse grid's trilinear interpolation reached 0.787 steps at the gamut boundary (also in double precision); the 5,189 cells (of 614,125) worse than 0.35 steps are solved exactly at load in 369 ms. Monochromatic 500 nm light reproduces its CMF colour within 2e-5.

## Memory and build

Spectral transport allocates 18.6 MB per device (the 86³ float4 moment grid, 10.2 MB, plus room for 8,192 refined 4×4×4 blocks, 8.4 MB) and a 15 KB sampling buffer per renderer, all on first use; `renderMemoryError` counts them. No reservoir grows. The app bundles `FourierSRGB86.bin` (7.6 MB) and `SpectralTables.metal` (154 KB); the 256³ table (101 MB) is no longer generated by `build.sh` or bundled. The first build solves the grid in about 100 s (10 processes) instead of about 470 s for the grid and the 256³ table. The two spectral libraries compile concurrently in 2.9 s cold (in the background in the application).

## Equivalence against `main`

With **Light transport → RGB** (and Automatic in RGB scenes) every procedural `tests/benchmark.py` scenario renders mean radiance identical to `6ed36c2` at zero tolerance (Pavilion default, MIS, coated floor and orbiting, Cornell; MetalFX on and off). The scene-6 scenarios differ by up to 0.09% because the benchmark forces the baseline onto the flat BVH, as in the Z++ section above. RGB frame times are within −2% to +0% of `6ed36c2` on the procedural scenarios (for example Pavilion 28.04 → 27.81 ms, Cornell 12.60 → 12.53 ms); the scene-6 baseline times use the flat BVH and are not comparable.

## Default

`LightTransport.automatic` resolves to spectral only where the scene needs wavelengths: a light or sun preset other than D65, or dispersion or thin film on a material. Everywhere else it traces RGB, because spectral transport costs 6–71% more frame time and 1.15–1.71 times the time to equal error, for differences that are RGB's interreflection error (up to 3% in one channel in the Pavilion) rather than visible effects. `VIBE_LIGHT_TRANSPORT=rgb|spectral` selects the transport in `-D VIBE_TESTING` builds.

# Z++ sampler — October 2, 2026

The Z++ sampler (`REFERENCES.md` `ZPP2026`; `SamplerMode.zSampling`, **Sampler → Z++**) against the earlier per-pixel PCG streams (`SamplerMode.pcg`). Setup: Apple M4 (10-core GPU, 16 GB), macOS 27.0, source `1124b00` plus this change (uncommitted at measurement; the shaders measured equal the committed ones except that the static and timing runs used the PerPixel temporal model, which renders still views statistically identically to the default ReShuffle-like model; and, before the last change, every accumulation shared one Owen scramble, which leaves error magnitudes unchanged; the bias runs below use the final shaders). Scratch drivers render through the production `renderFrame` path at 320×240 (errors) and 640×480 (times), path depth 16; other GPU work shared the machine. The unedited figures are in [`PERFORMANCE-zsampling-raw.txt`](PERFORMANCE-zsampling-raw.txt).

## Static accumulation (equal sample count)

Change of linear MSE against an 8,192-frame MIS (PCG) reference at 16 / 64 / 256 accumulated frames, mean of 3 seed sequences (Shader Ball 2), and frame time at 640×480 (median of 3 interleaved rounds):

| Scene | MIS | ReSTIR GI | Unified ReSTIR PT | Frame time MIS / GI / PT |
| --- | ---: | ---: | ---: | ---: |
| Pavilion | −38% / +2% / −13% | −30% / +5% / −12% | −2% / 0% / −12% | +3.2% / +3.6% / +3.1% |
| Pavilion close-up | −38% / −24% / −40% | −37% / −24% / −39% | −11% / −6% / −26% | +3.2% / +2.9% / +2.0% |
| Pavilion, coated floor | −21% / −16% / −8% | −20% / −15% / −9% | +6% / +8% / −7% | +2.1% / +3.0% / +2.9% |
| Cornell box | −23% / −31% / −44% | −9% / −11% / −16% | −8% / −9% / −12% | +2.6% / +1.2% / +2.9% |
| Cornell glass & mirror | −9% / −4% / −1% | −4% / −4% / 0% | +8% / −1% / −3% | +3.8% / +3.6% / +4.9% |
| Imported UV sphere | −79% / −86% / −87% | −28% / −27% / −26% | −35% / −36% / −28% | +3.4% / +2.1% / +2.7% |
| Instanced bumpy patches | −62% / −70% / −71% | −10% / −8% / −9% | −29% / −30% / −28% | +2.6% / +1.1% / +0.4% |
| ASWF Shader Ball | −35% / −43% / −48% | (ran as MIS) | −15% / −15% / −6% | +4.2% / — / +4.8% |

The Pavilion views' linear MSE is dominated by caustic fireflies through the chrome sphere (seed-to-seed spread up to ±15%); their tone-mapped MSE at 256 frames fell by 3–10%. Gains are largest where the first vertices decide the pixel (sky and sun light on matte imported surfaces, area-lit Cornell walls) and under MIS, whose per-pixel samples stay intact; ReSTIR resampling mixes neighbours' samples, which keeps part of the gain. Cornell glass & mirror, dominated by long specular chains, is the break-even case: within ±3% at equal time. Everywhere else the gain exceeds the 0.4–4.9% time cost. The Shader Ball fixture restores its document's strategy, so its ReSTIR GI rows repeat MIS and are omitted.

## Moving camera (per-frame and MetalFX error)

Orbit and back-and-forth paths of "Multi-layer reservoir splatting" below, frames 24 and 40, 2 seed sequences, 384-frame MIS references. The raw frame's whole-image tone-mapped error is unchanged (−4% to +1%) with every temporal model: one sample per pixel cannot be stratified. Its error at the 4 × 4-pixel scale, which MetalFX and the eye average, fell by 12–36% with MIS, 2–10% with ReSTIR GI and up to 7% with unified ReSTIR PT (the screen-space dithering of Z sampling). MetalFX display error, change against PCG (orbit / back-and-forth):

| Scene | ReSTIR GI, PerPixel / TZ / ReShuffle | Unified PT, PerPixel / TZ / ReShuffle |
| --- | ---: | ---: |
| Cornell | +1.2 / +0.8 / −0.4%, +2.5 / +1.6 / 0.0% | +1.0 / +1.0 / −0.6%, +1.5 / +0.5 / +0.8% |
| Pavilion | −2.7 / −2.5 / −4.9%, −4.2 / −4.5 / −5.1% | −1.2 / −1.8 / −1.9%, +1.5 / −1.1 / −6.1% |
| Instanced patches | −2.4 / −2.1 / −3.5%, −0.4 / −1.1 / −0.3% | +1.8 / 0.0 / −2.3%, +0.8 / −1.1 / −3.4% |
| Imported UV sphere | −8.9 / −9.5 / −11.5%, +0.2 / −0.8 / −4.5% | +2.9 / +1.3 / −4.4%, +1.8 / −2.1 / −6.7% |

PerPixel and TZ hand a pixel's neighbours' samples to it in the next frames (Z++ Sec. 4.1), which MetalFX's reprojection partly re-averages; the ReShuffle-like model gives each moving frame a fresh block and was best or tied in every case, so it is the default `ZTemporal`. Still views accumulate aligned nets in all models. STZ, checked only in an earlier Cornell orbit run (an earlier shader revision with a quadrant shuffle per dimension), was within 1% of TZ.

## Mean radiance (bias)

Relative mean-radiance difference against the 8,192-frame MIS (PCG) reference, mean ± standard error over 6 independent 256-frame accumulations at 320×240 (PCG / Z++ with the default ReShuffle-like model; each Z++ accumulation is its own scramble, so the standard error is taken across accumulations rather than tiles):

| Scene | MIS | ReSTIR GI | Unified ReSTIR PT |
| --- | ---: | ---: | ---: |
| Cornell | −0.002 ± 0.005% / −0.030 ± 0.029% | +0.383 ± 0.004% / +0.345 ± 0.030% | −0.002 ± 0.004% / +0.034 ± 0.027% |
| Cornell glass & mirror | −0.036 ± 0.040% / −0.30 ± 0.27% | +0.221 ± 0.035% / −0.11 ± 0.27% | 0.000 ± 0.038% / +0.03 ± 0.25% |
| Imported UV sphere | +0.004 ± 0.007% / +0.029 ± 0.007% | +0.129 ± 0.006% / +0.126 ± 0.011% | 0.000 ± 0.004% / +0.037 ± 0.033% |
| Instanced patches | −0.011 ± 0.006% / +0.003 ± 0.005% | −0.052 ± 0.014% / −0.058 ± 0.014% | −0.003 ± 0.004% / +0.028 ± 0.027% |
| Pavilion | −0.030 ± 0.024% / −0.04 ± 0.11% | +0.320 ± 0.054% / +0.27 ± 0.11% | −0.047 ± 0.026% / −0.11 ± 0.09% |

ReSTIR GI keeps its own bias (`RESTIRGI2021`) under either sampler. The Z++ means agree with MIS within 1–2 standard errors except the UV sphere under MIS (+0.029 ± 0.007%, 4 SE from six accumulations; 0.03% of mean radiance). The standard error of one accumulation's image mean is larger with Z++ than with PCG, because all pixels of an accumulation share one Owen randomization: its integration error is correlated across pixels, while its per-pixel error is lower. A first run that fixed one scramble for every accumulation showed apparent offsets of up to −0.11% (patches, unified PT) with tile-clustered errors that did not account for that correlation; scrambles now also depend on the key's top bits (one of 256 per accumulation), which is what makes accumulations independent.

## Memory and equivalence

No GPU memory is added: the sampler state lives in registers, and ReSTIR PT keeps its 64-byte reservoirs, whose seed now holds the 32-bit Z key. With **Sampler → Independent (PCG)** every procedural `tests/benchmark.py` scenario renders mean radiance identical to `1124b00` at zero tolerance (all strategies, MetalFX on and off). The scene-6 scenarios differ from the baseline by up to 0.7% because the benchmark forces the baseline onto the flat BVH: `1124b00` benchmarked against itself shows exactly the same differences. The PCG mode costs 1–3% over `1124b00` on the Pavilion scenarios (Cornell −3%), from the runtime sampler branch.

## Default

`SamplerMode.automatic` resolves to Z++ for every strategy and scene: it lowered static equal-sample MSE in 22 of 23 measured scene/strategy pairs (Cornell glass & mirror with ReSTIR GI: +0.3%) at 256 frames, for 0.4–4.9% more frame time, and kept moving-camera errors within about +1% (MetalFX −12% to +1%). `VIBE_SAMPLER=pcg|z` and `VIBE_Z_TEMPORAL=perpixel|tz|stz|reshuffle` select the variants in `-D VIBE_TESTING` builds.

# Spatio-temporal control variates (ReSTCV) — September 29, 2026

ReSTCV shading of ReSTIR PT (`REFERENCES.md` `RESTCV2026`; `ControlVariates.restcv`, **Path shading → Control variates**) compared with the resampled shading it replaces ("Resampled", the vector-valued resampling weights of `RESTIRPTE2026` Sec. 6.3). Both use paired spatial reuse and reprojection unless noted. Parameters: centre weight 1.6, equal weights for the partners' estimators, α = min(ρ_i / ρ_j, 2), temporal confidence cap 20.

Setup: Apple M4 (10-core GPU, 16 GB), macOS 27.0 (26A428), Swift 6.4, source `428d383` plus this change (uncommitted at measurement; the committed shaders differ only by comments and, for the splatting runs, the deep-domain estimates, measured separately below). The scratch drivers of the earlier sections render through the production `renderFrame` path at 320×240 and path depth 16; they are not part of the suite. Other GPU work shared the machine, so frame times are medians of three interleaved rounds, and a repeat run is given where the two differed. Errors of single frames are display-referred: negative values, which a ReSTCV frame can hold, are clamped to zero before tone mapping, as the display does. The unedited results are in [`PERFORMANCE-restcv-raw.txt`](PERFORMANCE-restcv-raw.txt).

## Moving camera (per-frame error, the paper's target)

The orbit and back-and-forth paths of "Multi-layer reservoir splatting" below: tone-mapped MSE of the raw single frame and of the MetalFX output at frames 32 and 48, against 512-frame MIS references (384 for the Shader Ball), for all pixels and for pixels hidden in the previous frame ("new"), averaged over 3 seed sequences (2 for the Shader Ball). Each value is the change with ReSTCV.

| Scene, path | Reuse | All | New | MetalFX all | MetalFX recent | Frame time |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Cornell, orbit / back-and-forth | unified PT | −25% / −25% | −6% / −11% | −8% / −7% | −1% / −3% | −2% / +1% |
| UV sphere, orbit / back-and-forth | unified PT | −47% / −46% | −8% / −8% | −18% / −21% | −1% / −7% | −3% / −5% |
| Instanced patches, orbit / back-and-forth | unified PT | −11% / −10% | −3% / −3% | −6% / −5% | −3% / −2% | 0% / −1% |
| Pavilion, orbit / back-and-forth | unified PT | −8% / −9% | −2% / −2% | −5% / −6% | −9% / −9% | 0% / +1% |
| Shader Ball, orbit | unified PT | −5% | +1% | −8% | −2% | 0% |
| Cornell, orbit / back-and-forth | ReSTIR PT | −16% / −16% | −1% / −2% | −5% / −3% | −4% / +2% | +1% / +1% |
| UV sphere, orbit / back-and-forth | ReSTIR PT | −0.2% / −0.1% | 0% / 0% | −1% / −0.4% | 0% / +1% | +2% / 0% |
| Instanced patches, orbit / back-and-forth | ReSTIR PT | −0.5% / −0.5% | 0% / 0% | −1% / −1% | −1% / −1% | +2% / +1% |
| Pavilion, orbit / back-and-forth | ReSTIR PT | −2% / −3% | +1% / 0% | −4% / −6% | −4% / −9% | +1% / +1% |

The whole-image error falls most where one resampled path decides a pixel's colour: coloured walls (Cornell) and the imported fixtures lit by the sky and the sun. ReSTIR PT (non-unified) lights diffuse primaries with ReSTIR DI, which ReSTCV does not change, so its gain is small except on Cornell. Newly disoccluded pixels gain little with reprojection: they have no history and borrow their partners' estimates. 0.05–2.1% of the pixels of a single frame have a negative channel (UV sphere 0.05%, Cornell 0.4–0.6%, patches 0.7–0.8%, Pavilion 1.2–1.3%, Shader Ball 2.1%); they show black without the denoiser and are counted in the display-referred figures above.

With reservoir splatting (`HONG2026`; back-and-forth path), ReSTCV changed the error by −47% / −10% / −9% (all pixels) and −44% / −4% / −5% (new pixels) on the UV sphere, the patches and Pavilion, and the MetalFX error by −19% / −6% / −6%. Newly disoccluded pixels then had 64%, 8% and 26% less error than with reprojection and ReSTCV, since deep domains carry their estimates. Before deep domains carried them, `tests/Fix_splatting.swift` measured no disocclusion gain for splatting under ReSTCV (ratios 0.99–1.02 against 0.85–0.91).

## Static accumulation (64 frames, 4 seed sequences, against a 1,024-frame MIS reference)

MSE (linear RGB, all pixels), change with ReSTCV, tone-mapped (x/(1+x)) change, and frame time at 640×480. Equal time assumes MSE ∝ 1/frames and uses the repeat run's times where one exists.

Unified ReSTIR PT:

| Scene | Resampled MSE | ReSTCV | Tone-mapped | Resampled ms | ReSTCV ms | Equal time |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Pavilion | 0.2611 | −1.3% | −2.7% | 54.4 (repeat 54.6) | 55.4 (55.3) | 0% |
| Pavilion close-up | 0.3628 | −1.2% | −1.9% | 66.9 | 66.8 | −1% |
| Pavilion, coated OpenPBR floor | 0.3249 | −1.4% | −2.8% | 68.4 | 69.2 | 0% |
| Cornell box | 1.636e-4 | −12% | −19% | 18.0 (19.1) | 19.2 (19.3) | **−11%** |
| Cornell glass & mirror | 4.169e-3 | −3% | −2% | 25.6 | 26.2 | −1% |
| Imported UV sphere | 9.207e-4 | −14% | −17% | 12.9 (12.9) | 13.1 (13.3) | **−12%** |
| Instanced bumpy patches | 2.028e-3 | −8% | −10% | 21.8 (21.7) | 22.2 (21.8) | **−7%** |
| ASWF Standard Shader Ball | 1.786e-3 | −5% | −6% | 128.6 | 129.8 | **−4%** |

ReSTIR PT: −1.2% (Pavilion), −1.1% (close-up), −1.3% (coated floor), −5% (Cornell), −3% (glass), −0.7% (UV sphere), −0.2% (patches) and −3% (Shader Ball) at equal sample count, for 0.4–3.8% more frame time: −4% (Cornell) to +3% (UV sphere) at equal time.

Static views accumulate without temporal reuse (`restir_pt_temporal`), so these frames use spatial control variates only. With temporal reuse on every frame (`ptTemporalWhileAccumulating`, the papers' real-time setting), ReSTCV lowered the 64-frame MSE by 35% (Cornell, 2.91e-4 → 1.90e-4), 47% (UV sphere, 1.42e-3 → 7.53e-4) and 16% (patches, 9.62e-3 → 8.09e-3). Only the UV sphere accumulates better that way than with the static policy (7.53e-4 against 7.88e-4; Cornell 1.90e-4 against 1.44e-4, patches 8.09e-3 against 1.87e-3), because temporal reuse correlates successive frames, so the policy is unchanged.

## Parameters

Moving camera, orbit, 2 seed sequences, 384-frame references, unified ReSTIR PT, all pixels (raw / MetalFX):

- **Spatial compositing:** the paper's confidence weights (q_j = M_j, with the centre at 1.6 M_c) against equal weights (3 seed sequences, 512-frame references): new pixels +22% (Pavilion 2.74e-2 against 2.23e-2) and +15% (patches), where the partners' long histories outweigh a disoccluded pixel's own estimate; the patches' MetalFX error was +2.5% against resampled shading rather than −6%. Equal weights are used, as in the authors' code.
- **Centre weight:** 1 instead of 1.6 raised the error by 8% (Cornell), 10% (UV sphere), 12% (Pavilion) and 12% (Shader Ball), and the MetalFX error by 0.6–1.6%.
- **α:** fixing α = 1 changed the error by −0.2% to +0.4% and the MetalFX error by −0.7% to +0.1%; paired pixels of the measured fixtures share materials. The paper's reflectance ratio is kept.
- **Clamping:** clamping each frame before accumulation biased mean radiance by up to +0.09% (patches with temporal reuse on every frame: +0.077 ± 0.022% against −0.010 ± 0.022%). The accumulation is therefore left unclamped.

## Mean radiance (bias)

512 accumulated frames at 320×240 against the 1,024-frame MIS reference, relative ± tile-clustered SE, resampled / ReSTCV. "Every frame" keeps temporal reuse on while accumulating, so the temporal control variates run on every frame.

| Mode | Cornell | Cornell glass | UV sphere | Patches | Pavilion |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unified PT | +0.005 / +0.004 ± 0.010% | +0.078 / +0.079 ± 0.072% | +0.012 / +0.012 ± 0.008% | −0.002 / −0.001 ± 0.010% | −0.074 / −0.073 ± 0.061% |
| Unified PT, every frame | −0.011 / −0.021 ± 0.017% | −0.002 / +0.045 ± 0.097% | −0.033 / −0.020 ± 0.012% | −0.001 / −0.010 ± 0.022% | |
| ReSTIR PT | +0.007 / +0.006 ± 0.010% | +0.074 / +0.077 ± 0.072% | −0.023 / −0.023 ± 0.010% | −0.063 / −0.062 ± 0.017% | |
| ReSTIR PT, every frame | −0.001 / +0.025 ± 0.013% | −0.008 / +0.020 ± 0.092% | −0.025 / −0.033 ± 0.011% | −0.075 / −0.071 ± 0.018% | |

Every difference between the two shadings is within twice the listed standard error. ReSTIR PT's patches bias comes from its ReSTIR DI pass (`RESTIR2020`).

## Memory

The estimate takes 16 B per pixel (`PTControl`), allocated with the ReSTIR PT resources: unified ReSTIR PT 338 B instead of 322 B per pixel (+5%), ReSTIR PT 434 B instead of 418 B, 31.6 MiB at 1920×1080. With splatting, the two deep-domain pools add 16 B per slot each: 182 B instead of 174 B per pixel (unified), 206 B instead of 198 B (ReSTIR PT).

## Equivalence and cost against `main`

`VIBE_CONTROL_VARIATES=off VIBE_ACCELERATION=flat python3 tests/benchmark.py --baseline <main.swift of 428d383> --rounds 1 --frames 8 --output-tolerance 0` rendered all ten scenarios with mean raw radiance identical to the baseline. With the defaults (ReSTCV on the imported scenes) and `--rounds 3 --frames 12`, the procedural (ReSTIR GI) scenarios were within ±1% of the baseline; the imported mesh took +0.3% (MetalFX off) and +5.5% (on), the orbiting mesh +3.3% and +1.2%, and the instanced scene graph +1.0% and +2.1%.

## Default

`ControlVariates.automatic` resolves to ReSTCV wherever it applies (ReSTIR PT and unified ReSTIR PT with paired reuse), which covers the imported scenes by default. While the camera moves, which is when the preview shows single low-sample frames, it lowered every measured whole-image error and the MetalFX display error by 5–21%, at unchanged frame time. In still accumulations it wins or ties at equal time (−12% to 0% with unified ReSTIR PT). **Resampled** remains selectable: for comparisons, and because raw single frames without the denoiser can show a few black pixels.

# Stochastic pairwise MIS — September 29, 2026

Stochastic pairwise MIS spatial reuse (`REFERENCES.md` `SPMIS2026`; `SpatialNeighborSelection.stochasticPairwise`) compared with the existing spatial reuse. With ReSTIR GI the baseline is the procedural default (uniform taps, "u"), plus compatibility-guided selection ("c") on imported meshes. With unified ReSTIR PT (the imported-scene default) the baseline is paired reuse ("p"). Parameters: 8 × 8 tiles, Ñ = 3, Ñc = 1, 12 search taps from max(1, height/120) pixels with 25% growth. The radius, Ñ for ReSTIR PT and the kernel split were chosen by the sweeps under "Parameters".

Setup: Apple M4 (10-core GPU, 16 GB), macOS 27.0 (26A428), Swift 6.4, source `cc88e24` plus this change (uncommitted at measurement; the committed shaders differ only by comments and the GI geometric-normal support test). The scratch drivers render through the production `renderFrame` path at 320×240 and path depth 16, and are not part of the suite. Other GPU work shared the machine, so the frame times are medians of three interleaved rounds. The unedited results are in [`PERFORMANCE-spmis-raw.txt`](PERFORMANCE-spmis-raw.txt).

## Static accumulation (64 frames, 4 seed sequences, against a 1,024-frame MIS reference)

MSE (linear RGB, all pixels), change with SPMIS, tone-mapped (x/(1+x)) change, and the frame-time change at 640×480. Equal time assumes MSE ∝ 1/frames.

Unified ReSTIR PT:

| Scene | Paired MSE | SPMIS | Tone-mapped | Paired ms | SPMIS ms | Equal time |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Pavilion | 0.2611 | −6% | −11% | 48.0 | 70.6 | +38% |
| Pavilion close-up | 0.3628 | −5% | −10% | 59.7 | 92.5 | +46% |
| Pavilion, coated OpenPBR floor | 0.3249 | −7% | −12% | 62.3 | 91.4 | +37% |
| Cornell box | 1.636e-4 | −17% | −35% | 16.9 | 22.6 | +10% |
| Cornell glass & mirror | 4.169e-3 | −13% | −15% | 23.5 | 33.9 | +26% |
| Imported UV sphere | 9.207e-4 | −33% | −35% | 12.0 | 16.1 | **−11%** |
| Instanced bumpy patches | 2.028e-3 | −28% | −31% | 20.7 | 27.4 | **−4%** |
| ASWF Standard Shader Ball | 1.786e-3 | −23% | −22% | 116.9 | 132.1 | **−13%** |

ReSTIR GI (DI and GI spatial reuse):

| Scene | Uniform MSE | SPMIS | Tone-mapped | Uniform ms | SPMIS ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pavilion | 0.2875 | +2% | +7% | 25.7 | 28.0 |
| Pavilion close-up | 0.4130 | −2% | +2% | 28.0 | 29.7 |
| Coated floor | 0.3620 | +3% | +7% | 32.5 | 34.1 |
| Cornell box | 1.781e-4 | +1% | 0% | 11.9 | 13.6 |
| Cornell glass & mirror | 5.238e-3 | 0% | +1% | 12.5 | 14.0 |
| Imported UV sphere | 1.966e-3 | +4% (compatibility −37%) | −4% | 7.8 | 9.5 (compatibility 9.2) |
| Instanced patches | 6.806e-3 | −41% (compatibility −62%) | −37% | 14.6 | 17.2 (compatibility 18.2) |

ReSTIR GI's reservoirs already carry up to 20 frames of temporal history, and its uniform normalization is biased toward lower variance. Unbiased stochastic weights therefore gain nothing there. The Shader Ball has no diffuse primary hits, so ReSTIR GI does no spatial reuse on it.

## Moving camera (per-frame error)

These use the orbit and back-and-forth paths of "Multi-layer reservoir splatting" below: tone-mapped MSE of the raw single frame and of the MetalFX output at frames 32 and 48, against 512-frame MIS references (384 for the Shader Ball), for all pixels and for pixels hidden in the previous frame ("new"). Each value is the change with SPMIS.

| Scene, path | Reuse | All | New | MetalFX all | MetalFX recent | Frame time |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Pavilion, orbit | unified PT | −13% | −20% | +0.1% | +8% | +33% |
| Cornell, orbit | unified PT | −10% | −15% | −1.3% | −0.3% | +19% |
| UV sphere, orbit | unified PT | −20% | −38% | +15% | +16% | +19% |
| UV sphere, back-and-forth | unified PT | −20% | −49% | +4% | +12% | +19% |
| Instanced patches, orbit | unified PT | −10% | −11% | +23% | +12% | +23% |
| Instanced patches, back-and-forth | unified PT | −10% | −10% | +21% | +14% | +21% |
| Shader Ball, orbit | unified PT | −10% | −25% | +1.3% | +4% | +9% |
| Pavilion, orbit | ReSTIR GI | −1.4% | −9% | −1.1% | −2% | +6% |
| Cornell, orbit | ReSTIR GI | −7% | −5% | +0.3% | +0.3% | +6% |
| UV sphere, orbit / back-and-forth | ReSTIR GI | −9% / −8% | −10% / −19% | −2% / −5% | −4% / −14% | ≈ +10% |
| Instanced patches, orbit / back-and-forth | ReSTIR GI | −7% / −6% | −5% / −2% | −2% / −3% | +3% / +2% | +7% / +12% |

The raw per-frame error falls, most in disocclusions: the paper's case. Within each reuse cell, however, many pixels pick the same few contributing samples, and the MetalFX denoiser keeps that structure. Its output therefore gets no better, and 4–23% worse on the mesh scenes with ReSTIR PT.

## Mean radiance (bias)

Spatial-only runs clear reservoir history every frame, so spatial reuse is the only reuse. They average 256–512 frames, and each difference is relative to MIS ± tile-clustered SE.

| Mode | Cornell | Cornell glass | UV sphere | Patches | Pavilion |
| --- | ---: | ---: | ---: | ---: | ---: |
| ReSTIR GI, uniform | +6.12 ± 0.17% | +3.33 ± 0.13% | +1.05 ± 0.06% | | |
| ReSTIR GI, compatibility | −0.205 ± 0.012% | | +0.009 ± 0.008% | | |
| ReSTIR GI, SPMIS | +0.026 ± 0.010% | +0.03 ± 0.07% | +0.015 ± 0.010% | −0.000 ± 0.015% | −0.05 ± 0.07% |
| Unified PT, paired | −0.007 ± 0.009% | +0.006 ± 0.074% | +0.012 ± 0.009% | +0.021 ± 0.012% | −0.09 ± 0.08% |
| Unified PT, SPMIS | −0.006 ± 0.009% | +0.017 ± 0.072% | +0.012 ± 0.008% | +0.023 ± 0.012% | −0.06 ± 0.08% |

Before the support tests (x2 visible from, and above the geometric normal of, the neighbour whose domain the canonical weight counts), SPMIS GI measured −0.078 ± 0.010% on Cornell.

In full accumulation (temporal reuse included), ReSTIR GI with SPMIS measured +0.27 ± 0.02% on Cornell, +0.11 ± 0.01% on the UV sphere, +0.26 ± 0.08% on glass and +0.16 ± 0.02% on the patches. Uniform mode measured +0.25%, +0.09% and +0.23% on the first three. The remaining bias comes from the temporal merge, and compatibility mode's darkening happens to offset it (Cornell +0.07%). Unified ReSTIR PT with SPMIS agrees with MIS within noise: Cornell +0.006 ± 0.010%, UV sphere +0.011 ± 0.008%, patches +0.005 ± 0.012%, glass +0.12 ± 0.08%.

## Parameters

Unified ReSTIR PT, 64-frame MSE at 320×240:

- **Search radius** (first tap), sweeping 16 → 8 → 4 → 2 → 1 pixels: Cornell 1.54, 1.46, 1.40, 1.36, 1.33e-4; UV sphere 7.04, 6.69, 6.36, 6.13, 5.97e-4; Pavilion 0.255, 0.252, 0.250, 0.246, 0.242.
- **Own cell only:** lowest raw error, but MetalFX error while orbiting rose from 1.57e-4 (paired) to 2.86e-4 on the UV sphere and by 18% on Pavilion. At 1 pixel the rise was 22% and 3%; at 2 pixels, 15% and 0%. 2 pixels (height/120) is used.
- **Ñ for ReSTIR PT** (1 + Ñ shifts per pixel against paired reuse's three): Ñ = 1 is worse than paired everywhere. Ñ = 2 cost +18–43% for −3% to −15% MSE, and did not win at equal time. Ñ = 3 is used.
- **Kernel structure:** one shift per thread in a separate pass took 22.6 / 16.1 ms (Cornell / UV sphere) against 26.3 / 23.0 ms for four shifts per thread in the resampling kernel. Moving the cell search out of `shading_kernel` saved 0.7–0.9 ms per frame with ReSTIR GI.
- **Why SPMIS costs more than its shift count suggests:** it draws neighbours that hold contributing paths, so almost every shift is a full shift. Paired reuse skips pixels without a path and incompatible pairs, and on Pavilion the drawn paths are often long caustic chains.

## Memory

The reuse cells take 44 B per pixel: a 16 B `SPMISPixel` and a 16 B `SPMISChoice` per pixel and a 12 B `SPMISSlot` per tile slot. With ReSTIR PT, `ptShifts` also grows from 48 to 96 B (four 24 B records), for 92 B per pixel in all. At 1920×1080 that is 87 MiB (ReSTIR GI) or 182 MiB (ReSTIR PT), allocated only in this mode.

## Equivalence and cost against `main`

`VIBE_ACCELERATION=flat python3 tests/benchmark.py --baseline <main.swift of cc88e24> --rounds 1 --frames 8 --output-tolerance 0` rendered all six scenarios with mean raw radiance identical to the baseline in the default modes, with timings within ±2% (Pavilion 25.71 vs 25.73 ms, Cornell 11.9 vs 12.0 ms). With `VIBE_SPATIAL_NEIGHBORS=stochastic`, the procedural ReSTIR GI scenarios took +16% (Cornell), +8% (Pavilion) and +4% (coated floor).

## Default

`SpatialNeighborSelection.automatic` is unchanged: uniform for the procedural scenes, compatibility-guided for imported scene graphs, and paired reuse for ReSTIR PT. SPMIS never wins with ReSTIR GI. With ReSTIR PT it wins at equal time only in static accumulations of the imported fixtures (4–13%). The interactive MetalFX preview, which those scenes show while the camera moves, gets no better. The mode is therefore listed on the Render page for final renders and for raw per-frame noise in disocclusions.

# Multi-layer reservoir splatting — September 29, 2026

Temporal reuse by multi-layer reservoir splatting (`REFERENCES.md` `HONG2026`, `LIU2025`;
`TemporalReuse.splatting`) against the existing reprojection (`TemporalReuse.reprojection`, the
default), on an Apple M4 (10-core GPU, 16 GB), macOS 27.0 (26A428), Swift 6.4. Source: `bd7134b`
plus this change (uncommitted at measurement; the committed shaders are identical apart from
comments). One deep layer, hole-filling radius 1, pool of one domain per four pixels.

Splatting runs only on frames where the view changed, so every figure below comes from a moving
camera. The scratch driver (not part of the suite) renders through the production `renderFrame`
path at 320×240, path depth 16, along four 48-frame camera paths from the default view: **orbit**
(yaw +0.015 rad per frame), **pan** (the target slides sideways by 0.6% of the orbit distance per
frame), **dolly** (distance ×0.985 per frame) and **back-and-forth** (the orbit reversing every 16
frames, so that recently hidden surfaces reappear). At frames 32 and 48 it compares the raw
single frame and the MetalFX output with a 512-frame MIS reference of that view (384 for the
Shader Ball), tone-mapped x/(1+x) (MetalFX: the display curve), averaged over 3 seed sequences (2
for the Shader Ball). **New** pixels are those whose primary hit was behind a nearer surface in the
previous frame (a depth test against that frame's G-buffer); **recent** ones were hidden in any of
the last 8 frames. Pixels entering the frame at the image border are not counted as disoccluded.

## Per-frame error with unified ReSTIR PT (the imported-scene default)

Reprojection's error, and the change with splatting:

| Scene | Path | New px | New | Splat | Recent | Splat | All | Splat | MetalFX all | Deep domains |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Pavilion | orbit | 236–453 | 2.28e-2 | −15% | 1.47e-2 | −7% | 8.89e-3 | −0.9% | −0.2% | 13,391 |
| Pavilion | pan | 151–200 | 3.09e-2 | 0% | 2.03e-2 | 0% | 9.81e-3 | +0.2% | −1.0% | 2,829 |
| Pavilion | dolly | 292–445 | 3.03e-2 | −3% | 2.17e-2 | +2% | 1.41e-2 | −0.2% | +1.9% | 3,543 |
| Pavilion | back-and-forth | 349–414 | 2.55e-2 | −25% | 1.64e-2 | −9% | 1.01e-2 | −1.1% | −0.3% | 6,093 |
| Cornell box | orbit | 62–119 | 7.99e-3 | 0% | 6.52e-3 | −2% | 1.16e-3 | 0.0% | 0.0% | 3,539 |
| Cornell box | pan | 127–305 | 6.42e-3 | +3% | 4.40e-3 | +3% | 1.01e-3 | −0.2% | −1.0% | 2,053 |
| Cornell box | dolly | 255–433 | 6.92e-3 | +4% | 2.65e-3 | −2% | 8.03e-4 | +3.4% | −1.6% | 2,765 |
| Cornell box | back-and-forth | 115–151 | 6.62e-3 | −5% | 5.86e-3 | −3% | 1.13e-3 | +1.1% | +1.5% | 2,022 |
| Imported UV sphere | orbit | 152–179 | 1.09e-2 | −16% | 6.01e-3 | −7% | 2.53e-3 | −0.1% | −2.4% | 6,317 |
| Imported UV sphere | pan | 105–117 | 1.29e-2 | −10% | 6.41e-3 | −2% | 2.56e-3 | −0.4% | −0.3% | 3,672 |
| Imported UV sphere | dolly | 6–9 | (1.14e-2) | (−6%) | (1.41e-2) | (+48%) | 1.87e-3 | +1.2% | −3.8% | 11,010 |
| Imported UV sphere | back-and-forth | 180–222 | 1.06e-2 | −39% | 5.80e-3 | −20% | 2.54e-3 | −0.3% | −4.7% | 3,045 |
| Instanced patches | orbit | 702–1,076 | 2.58e-2 | −9% | 1.68e-2 | −4% | 6.99e-3 | −0.6% | +1.3% | 5,123 |
| Instanced patches | pan | 677–1,984 | 3.33e-2 | −4% | 2.08e-2 | −1% | 8.00e-3 | +0.1% | +1.7% | 4,031 |
| Instanced patches | dolly | 749–1,727 | 3.08e-2 | −3% | 2.06e-2 | −1% | 8.07e-3 | −1.0% | +1.2% | 2,279 |
| Instanced patches | back-and-forth | 1,210–1,224 | 2.65e-2 | −7% | 1.67e-2 | −4% | 7.51e-3 | −0.7% | +1.9% | 5,000 |
| ASWF Shader Ball | orbit | 309–332 | 1.17e-2 | −12% | 5.17e-3 | −8% | 4.15e-3 | +0.6% | +1.3% | 6,394 |
| ASWF Shader Ball | back-and-forth | 266–415 | 1.06e-2 | −17% | 5.27e-3 | −7% | 4.79e-3 | +0.8% | −1.3% | 5,294 |

"Deep domains" is the largest pool of the sequence (capacity 19,200; no overflow). The UV-sphere
dolly disoccludes fewer than 10 pixels, so its masked figures are noise. MetalFX display error of
recently disoccluded pixels changed by −14% to +8% (no consistent sign): MetalFX's own history
dominates the displayed image.

ReSTIR PT (with ReSTIR DI) on Pavilion: new-pixel error −10% (orbit), −9% (pan), −7% (dolly), −27%
(back-and-forth); whole image within ±0.7%.

ReSTIR GI (the procedural default): new-pixel error −5 to −3% on Pavilion, −13% to +2% on the UV
sphere, within ±2% on the patches and −3% to +6% on Cornell; whole image within ±1% except −3.1%
on the UV-sphere orbit. Its temporal reuse carries little of the per-frame error: dropping temporal
reuse entirely (history cleared every frame) raised whole-image error by only 7% on Pavilion and
31% on Cornell (unified ReSTIR PT: 73% and 83%), which bounds what any temporal reuse can recover.

Why the gain is modest: splatting finds temporal history for most disoccluded pixels (on the
Pavilion back-and-forth, about 85% of them took a deep-domain splat in a diagnostic run, with a
mean DI confidence of 21 against 4 without history), but deep domains get no spatial reuse, and this renderer's paired spatial reuse
(three neighbours) already lifts history-less pixels; on monotonic paths many revealed surfaces
were never visible before (the paper's stated limitation).

## Frame time and memory

Median GPU time of moving frames (orbit, frames 9–32 of three interleaved rounds), 640×480:

| Scene | GI | GI splat | Change | Unified | Unified splat | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Pavilion | 25.99 | 28.64 | +10% | 68.29 | 73.71 | +8% |
| Cornell box | 12.20 | 14.19 | +16% | 22.38 | 24.13 | +8% |
| Imported UV sphere | 9.14 | 11.49 | +26% | 15.88 | 17.66 | +11% |
| Instanced patches | 22.60 | 25.29 | +12% | 31.63 | 35.64 | +13% |
| ASWF Shader Ball | — | — | — | 152.32 | 159.87 | +5% |

(The UV-sphere unified pair is from a repeat run; the first gave 19.68 / 27.66 ms under an
interfering load.) Ablations on the UV sphere and Cornell put 35–60% of the overhead in
the per-pixel passes (activation, reservoir splats, the DI/GI merge) and the rest in proportion
to the deep domains (their layers, canonical samples and temporal shifts). A second deep layer
doubled the pool on the instanced patches (+30% instead of +13%) without lowering the error. Static
frames (every accumulated frame after the first) run no splat pass.

Splat resources (`FrameResourcePlan.splatBytesPerPixel`, allocated only with
`TemporalReuse.splatting`): ReSTIR GI and ReSTIR PT 198 B per pixel, unified ReSTIR PT 174 B: 58 /
51 MiB at 640×480 and 392 / 344 MiB at 1920×1080.

`tests/benchmark.py --rounds 2 --frames 12` (default hardware traversal, 640×480; the two new
"orbiting" scenarios move the camera every frame and use each scene's default indirect reuse, ReSTIR
GI for Pavilion and unified ReSTIR PT for the mesh), default against `VIBE_TEMPORAL_REUSE=splatting`,
median GPU ms (reports in [`PERFORMANCE-splatting-raw.txt`](PERFORMANCE-splatting-raw.txt)):

| Scenario | MetalFX | Reprojection | Splatting | Change |
| --- | --- | ---: | ---: | ---: |
| Default Pavilion, orbiting | off | 25.51 | 27.89 | +9% |
| Default Pavilion, orbiting | on | 29.94 | 32.02 | +7% |
| Imported mesh, orbiting | off | 15.66 | 16.66 | +6% |
| Imported mesh, orbiting | on | 19.17 | 20.23 | +6% |

The static scenarios run no splat pass (only an 8-byte counter clear per frame) and matched within
±1%, except the static imported mesh (+4% and +7%, from a noisy splatting run whose frames ranged
up to 19 ms).

## Mean radiance (bias)

Mean radiance of moving frames against MIS stays as with reprojection: over the scenes above,
the mean of the measured single frames differed from the references by the same amounts in both
modes (ReSTIR GI +0.1% to +1.4% on Pavilion and Cornell in either mode, unified ReSTIR PT
within ±0.9%). The suite's alternating-view check (`tests/Fix_splatting.swift`, 192 frames per
view at 128×96) gives unified ReSTIR PT −0.7 ± 0.5% / +0.1 ± 0.4% with splatting against −0.7 /
+0.0% with reprojection, and ReSTIR GI −0.5 ± 0.6% / +0.9 ± 0.4% against +0.0 / +1.3%.

## Default

At equal time the whole image favours reprojection in every mode: its error is within ±3% either
way while splatting costs 5–26% more frame time. Splatting's gain is local to disoccluded pixels
(up to −39% with ReSTIR PT) and does not carry through MetalFX. `TemporalReuse.automatic`
therefore resolves to reprojection; `PathTracerRenderer.temporalReuse = .splatting` (or
`VIBE_TEMPORAL_REUSE=splatting` in test builds) trades that time for less noise behind moving
occluders with ReSTIR PT.

## Equivalence against `main`

`VIBE_ACCELERATION=flat python3 tests/benchmark.py --baseline <main.swift of bd7134b> --rounds 1
--frames 8 --output-tolerance 0` (reprojection, the default): all six static scenarios rendered
mean raw radiance identical to `bd7134b`'s shaders, with timings within ±1.2%.

# ReSTIR PT — September 29, 2026

ReSTIR PT (`REFERENCES.md` `RESTIRPT2022`, `RESTIRPTE2026`; `IndirectReuse`) against the
earlier bounded first-bounce ReSTIR GI (`IndirectReuse.restirGI`, `RESTIRGI2021`), on an Apple M4
(10-core GPU, 16 GB), macOS 27.0 (26A428), Swift 6.4. Source: `ba3fd91` plus this change
(uncommitted at measurement; the committed shaders are identical). "PT" is ReSTIR PT for paths
of three or more vertices, with ReSTIR DI or MIS for direct light; "unified" is ReSTIR PT for
every path (`restirPTUnified`, no DI pass). Both reuse temporally only while the view changes,
unless noted ("T": temporal reuse on every frame, as in the papers' real-time renderers).

The scratch driver used for the error figures is not part of the suite. It renders through the
production `renderFrame` path at 320×240 and path depth 16. Each error is the mean over 4
independent seed sequences (`restartSampleSequence(at:)`) of the accumulated image's MSE (linear
RGB, all pixels) against a 1,024-frame MIS reference; "tone-mapped" applies x/(1+x) per channel
first, which limits the weight of caustic fireflies (in Pavilion, 1% of the pixels hold 90% of the
linear error). Frame times are medians of 30 frames over three interleaved rounds at 640×480,
static camera (static accumulation: PT and unified skip temporal reuse there). The GPU was shared
with other work at times, so times vary by up to ±10% between sessions; ratios within one table
come from interleaved runs.

## Equal-sample and equal-time error (64 accumulated frames)

| Scene | GI MSE | PT | Unified | Unified T | GI ms | PT ms | Unified ms | Unified, equal time |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Pavilion | 0.2875 | −8% | −9% | +94% | 27.9 | 57.3 | 57.5 | +87% |
| Pavilion close-up | 0.4130 | −9% | −12% | +99% | 30.9 | 69.0 | 72.0 | +105% |
| Pavilion, coated OpenPBR floor | 0.3620 | −10% | −10% | +58% | 40.1 | 76.5 | 73.5 | +64% |
| Cornell box | 1.781e-4 | −15% | −8% | +63% | 14.9 | 20.6 | 19.7 | +22% |
| Cornell glass & mirror | 5.238e-3 | −21% | −20% | +65% | 14.7 | 29.7 | 29.0 | +57% |
| Ring studio (scene 5) | 1.511e-3 | 0% | 0% | +180% | 12.9 | 24.6 | 22.2 | +72% |
| Veach plates (scene 2) | 2.008e-2 | 0% | 0% | +2% | 6.3 | 12.8 | 12.5 | +99% |
| Imported UV sphere on a floor | 1.966e-3 | −4% | **−53%** | −28% | 8.9 | 13.9 | 16.2 | **−14%** |
| ASWF Standard Shader Ball | 3.130e-3 | −28% | **−43%** | +110% | 76.7 | 126.7 | 123.1 | **−8%** |

Tone-mapped equal-sample changes (PT / unified against GI): Pavilion −4% / −17%, close-up −8% /
−15%, coated floor −4% / −11%, Cornell −24% / −17%, glass & mirror −12% / −11%, ring studio −2% /
−2%, plates +1% / −23%, UV sphere −2% / −57%, Shader Ball −26% / −37%. Equal time assumes MSE ∝
1/frames. At equal time Standard MIS itself beats ReSTIR GI (by 1–49%) and unified ReSTIR PT
(by 24–175%) on every scene except the Shader Ball, where unified ReSTIR PT is 7% below MIS and
ReSTIR GI 1% above: converged accumulations gain little from reuse, whose value is per frame.

Temporal reuse on every frame of a static accumulation ("T") doubles the error because
consecutive frames reuse the same samples: in an ablation on Cornell / glass / Pavilion, capping
the temporal confidence at 1–4 recovered most of the loss, and dropping temporal reuse was within
7% of the best cap while saving two shifts per pixel, so ReSTIR PT reuses temporally only while
the view changes (`restir_pt_temporal`). The papers recommend accumulating without temporal reuse
for converged images.

## Interactive preview (orbiting camera)

The camera orbits every frame, which resets the accumulation and keeps ReSTIR history, so every
frame uses temporal reuse. Tone-mapped MSE of the 16th single frame against a 1,024-frame MIS
reference of that view, mean of 3 seed sequences, 320×240:

| Scene | GI | PT | Unified | Frame ms (640×480) GI / PT / unified |
| --- | ---: | ---: | ---: | --- |
| Pavilion | 3.22e-2 | −37% | −69% | 27.9 / 89.2 / 72.4 |
| Pavilion close-up | 3.32e-2 | −44% | −65% | 30.9 / 120.0 / 110.7 |
| Coated floor | 3.55e-2 | −45% | −68% | 40.1 / 113.3 / 106.1 |
| Cornell box | 1.64e-3 | −49% | −37% | 14.9 / 26.0 / 25.2 |
| Cornell glass & mirror | 2.53e-3 | −18% | −7% | 14.7 / 47.2 / 38.4 |
| Ring studio | 4.11e-4 | 0% | +8% | 12.9 / 43.5 / 30.7 |
| Veach plates | 2.75e-3 | −1% | −58% | 6.3 / 33.2 / 19.5 |
| Imported UV sphere | 7.65e-3 | −9% | −67% | 8.9 / 22.5 / 22.2 |
| Shader Ball | 1.44e-2 | −58% | −75% | 76.7 / 158.3 / 152.1 |

## Mean radiance against MIS (bias check)

512 accumulated frames at 320×240 against the 1,024-frame MIS reference, all pixels, relative
difference ± tile-clustered standard error. ReSTIR GI: Cornell +0.25 ± 0.03%, glass & mirror
+0.22 ± 0.08%, close-up +0.19 ± 0.09%, UV sphere +0.07 ± 0.01%, others within ±0.02%. ReSTIR PT and
unified: every scene within ±0.09% and within 2.3 standard errors (Cornell +0.007 ± 0.010% /
+0.005 ± 0.010%, glass +0.07 ± 0.07% / +0.08 ± 0.07%, Pavilion −0.09 ± 0.06% / −0.07 ± 0.06%,
UV sphere −0.02 ± 0.01% / +0.01 ± 0.01%, Shader Ball −0.01 ± 0.01% / −0.02 ± 0.01%).

## Memory

Reservoir storage per pixel (`FrameResourcePlan.reservoirBytesPerPixel`): ReSTIR GI 208 B (DI 96,
GI 112); ReSTIR PT 418 B (DI 96, then two 64 B path reservoirs, three 16 B paired shifts, the
16 B indirect estimate, a 128 B history `PrimarySurface` and the 2 B duplication map); unified
322 B. The primary-surface cache grew from 120 to 128 B in every mode. At 1920×1080 unified
ReSTIR PT needs 114 B/pixel (225 MiB) more than ReSTIR GI; the pairing textures take 316 KiB once.

## Default

`IndirectReuse.automatic` resolves to unified ReSTIR PT for scene 6 (imported meshes and scene
graphs), where it wins at equal time (UV sphere −14%, Shader Ball −8%), and to ReSTIR GI for the
procedural scenes, where the extra shifts cost 22–105% more error at equal time despite up to 20%
lower error at equal sample count (none on the ring and plates scenes). Interactive (orbiting)
frames have 37–75% lower error with unified ReSTIR PT in seven of nine scenes, but take 1.7–3.6×
longer.

## Equivalence and cost against `main`

`VIBE_INDIRECT_REUSE=gi VIBE_ACCELERATION=flat python3 tests/benchmark.py --baseline <main.swift of
ba3fd91> --rounds 1 --frames 8 --output-tolerance 0`: with ReSTIR GI forced, Cornell and both mesh
scenarios render mean raw radiance identical to `ba3fd91`'s shaders. The three Pavilion scenarios
differ by at most 5e-6 relative, from the renormalized mirror reflections in `sample_bsdf` (see
`PBRT2023`); with that one change reverted all six scenarios were identical at zero tolerance and
timings matched within 2.5% (Pavilion 25.30 vs 25.31 ms, instanced scene graph 44.61 vs 45.71 ms
on the flat BVH). That report is [`PERFORMANCE-restir-pt-raw.txt`](PERFORMANCE-restir-pt-raw.txt),
first section.

## Benchmark (`tests/benchmark.py`)

Default hardware traversal, `--rounds 2 --frames 12`, median GPU ms per frame, 640×480, with
`VIBE_INDIRECT_REUSE` set to each mode (the default, `automatic`, gives the GI column for the
procedural scenes and the unified column for scene 6). Unedited reports are in
[`PERFORMANCE-restir-pt-raw.txt`](PERFORMANCE-restir-pt-raw.txt).

| Scenario | MetalFX | ReSTIR GI | Unified ReSTIR PT | Change |
| --- | --- | ---: | ---: | ---: |
| Default Pavilion | off | 25.14 | 48.03 | +91% |
| Default Pavilion | on | 29.27 | 52.07 | +78% |
| Pavilion with coated OpenPBR floor | off | 31.74 | 61.81 | +95% |
| Pavilion with coated OpenPBR floor | on | 36.00 | 65.84 | +83% |
| Cornell box | off | 11.55 | 16.72 | +45% |
| Cornell box | on | 14.97 | 20.38 | +36% |
| Imported mesh (8,130 triangles) | off | 7.36 | 11.83 | +61% |
| Imported mesh (8,130 triangles) | on | 12.54 | 15.42 | +23% |
| Instanced scene graph | off | 17.20 | 20.09 | +17% |
| Instanced scene graph | on | 20.75 | 23.70 | +14% |
| Default Pavilion, MIS (no ReSTIR) | off | 21.35 | 21.29 | 0% |

With the benchmark's 1.61× on the UV-sphere mesh, unified ReSTIR PT's equal-time error there is
−25% (−14% with the interleaved 1.83× above).

# ReSTIR spatial neighbour selection — September 29, 2026

Compatibility-guided selection (`REFERENCES.md` `COMPATRESTIR2026`; the default for imported scene graphs through `SpatialNeighborSelection.automatic`, while procedural scenes keep uniform selection)
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
