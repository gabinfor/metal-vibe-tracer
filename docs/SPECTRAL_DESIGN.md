# Spectral light transport: design for the renderer integration

Status, 2026-10-03: **implemented.** Spectral light transport is integrated as designed below, with
the changes recorded in §11 ("Decisions taken in the integration"), which supersedes the plan where
they differ. §1–§10 are kept as the design that was implemented. Citation keys refer to
[REFERENCES.md](../REFERENCES.md) (`PETERS2019`, `FOURIERSRGB2019`, `PETERSBLOG2025`, `HERO2014`,
`CIEDATA`, `OPENPBR`, `ZPP2026`).

The approach follows Christoph Peters' spectral rendering series (`PETERSBLOG2025`): reflectance
from sRGB through three Fourier coefficients reconstructed with the bounded MESE (`PETERS2019`,
`FOURIERSRGB2019`), four wavelengths per path sample from one random number, importance sampled
in proportion to illuminant × L1 norm of the colour-matching functions, and XYZ → linear sRGB
before anything downstream. It extends the existing renderer (AGENTS.md); RGB transport keeps its
behaviour bit for bit, and Automatic chooses RGB unless a scene needs wavelengths (§11).

## 1. What exists now

`scripts/generate_spectral_tables.py` (stdlib Python, CPython 3.9+) writes `build/SpectralTables`.
`build.sh` and `tests/verify.py` run it. Since the integration the first run solves only the coarse
grid, about 100 s on an M4 (10 processes); `FourierSRGB256.bin` is generated only with
`--lut256` (about 8 minutes). Later runs reuse the output while the script, its pinned inputs and
its parameters are unchanged. The large tables are regenerated only when the code that produces
them changes.

| Output | Content | Size |
|---|---|---|
| `FourierSRGB256.bin` | Opt-in (`--lut256`) test reference: 8-bit sRGB → (c0, c1, c2), 3 × uint16 per entry, index `(r·256 + g)·256 + b` | 96 MiB + 64 B header |
| `FourierSRGB86.bin` | Exactly solved coarse grid at codes 0, 3, …, 255, float32 | 7.3 MiB |
| `SpectralTables.metal` | MSL include: CIE 1931 2° CMFs, phase warp, XYZ ↔ linear sRGB, six Y-normalized presets, six 1025-node wavelength inverse CDFs, accessors, bounded MESE | 151 KB source, ≈ 42 KB constants |
| `SpectralTables.json` | Manifest: parameters, input and output SHA-256, statistics, licences | — |

Header of both `.bin` files (little-endian, 64 bytes): 8-byte magic (`VTFSRGB\0` or `VTFSRGBC`),
`uint32` format version, size per axis, channel count (3), bits (16 or 32), then 3 × (scale,
offset) as float32 for decoding c = q / 65535 · scale + offset. The values are c0 ∈ [0, 1] and
c1, c2 ∈ [−1/π, 1/π].

`tests/SpectralTables.py` verifies the tables. The numbers quoted below come from its output.

### Conventions

- **Wavelengths:** 360–830 nm, data at 1 nm (the CMF table's range). FL, HP and LED presets are
  zero outside 380–780 nm, as their metadata prescribes.
- **Reflectance colour is defined under D65.** A reflectance ρ(λ) has the linear-sRGB colour
  M · Σλ ρ(λ) S_D65(λ) x̄ȳz̄(λ), with S_D65 normalized to Y = 1. M is built from the IEC
  primaries and the *computed* white of the CIE D65 spectrum (x, y) = (0.312727, 0.329023), so
  ρ ≡ 1 maps to (1, 1, 1) exactly. M matches the published IEC 61966-2-1 matrix to its four
  decimals. Peters' lookup (`FOURIERSRGB2019` Sec. 3.2) integrates against illuminant E instead. This
  renderer uses D65 so that under D65 light an sRGB albedo renders as that albedo, which is the
  parity test in §9. Under E, A, FL11 or HPS the colours legitimately differ from RGB mode.
- **Phase warp:** Peters' even XYZ warp φ(λ) ∈ [−π, 0], 95 nodes at 5 nm, linear in between
  (`Vendor/Spectral/Peters2019/XYZWarp.h`, BSD-3-Clause).
- **Reflectance:** g(φ) = atan(L0 + 2 L1 cos φ + 2 L2 cos 2φ) / π + 1/2, where L = Lagrange
  multipliers of the moments c via Eqs. 6, 7 and 10 of `PETERS2019` (`vibe_fourier_lagrange`).
  The value is always in (0, 1). c0 is clamped to [1e-4, 1 − 1e-4]. Moments outside the valid
  set, which lossy compression or filtering of non-table data can produce, are pulled back with
  Alg. 2 of `FOURIERSRGB2019`.
- **Illuminant presets** (`VibeIlluminant`): E, D65, A, FL11, HP1 (standard high-pressure
  sodium), LED-B3 (phosphor white LED). Each is normalized to luminance Y = Σ S ȳ = 1 at 1 nm.

### Measured (tests/SpectralTables.py)

- **sRGB → moments → spectrum → XYZ → sRGB**, 1 nm, double precision: 8-bit error max 0.43 and
  mean 0.024 over 240,608 codes (every code on a stride-5 grid plus 100,000 random codes). The
  generator checks all 16.7 M entries and reports max 0.438 and mean 0.018. CIELAB ΔE76 is at
  most 0.30 (mean 0.006). The largest error is at black: c0 ≥ 1e-4 gives linear 1e-4, which
  encodes to 0.33 of an 8-bit step, plus rounding.
- **Validity and boundedness:** all 16,777,216 entries decode to valid moments. Reflectance is in
  (0, 1) everywhere. **White furnace:** sRGB white reflects ≥ 0.99987 at every wavelength, and
  greys are flat to 2e-4.
- **GPU, float32, relaxed math** (as `shaderCompileOptions()`): the include reproduces the double
  results to 2.9e-6 in linear sRGB, and its Lagrange multipliers agree to 8.6e-6 relative. Six
  invalid moment vectors are biased to bounded reflectances. Wavelength sampling agrees to
  3e-5 nm and 7e-8 relative in pdf.
- **Wavelength sampling:** 10 nm histograms of stratified samples are within 0.2% of the table's
  pdf and within 0.6% of the analytic pdf in bins above 0.5% mass. E[Y·S/p] = 1 to 2e-5 for
  every preset.
- **Colour noise** of one 4-wavelength sample (relative RMS of the linear-sRGB channels over the
  luminance; independent → jittered): grey under D65 0.90 → 0.23, skin 0.91 → 0.27, red 2.27 →
  1.06, blue 3.60 → 0.88. Under FL11, grey goes 0.81 → 0.20; under HP1, 0.45 → 0.23. Across 6
  presets × 6 colours, jittered sampling is never worse than independent (worst ratio 0.89, HP1
  blue, the spikiest case). Jittered sampling uniform in λ instead of by illuminant × CMF is
  6–27× noisier under FL11 and 1.0–10× under HP1; it is better only for blue under A (1.53
  against 1.90). The test prints the full table.

### Table format choice

The table needs 16 bits per moment for an exact round trip. On the same entries, quantization
measured max 0.26 8-bit steps at 16-bit linear, 0.31 at 12-bit and 0.83 at 10-bit (both with a
Fourier-sRGB-like nonlinear encoding, a local re-derivation of `FOURIERSRGB2019` Sec. 3.2), and
2.5 at 8-bit. Metal has no 3-channel 16-bit pixel format, so the table is a flat `uint16` buffer
(`packed_ushort3` in MSL). It is not a texture. It is read only when an 8-bit image is converted
(§2), so the 96 MiB file can be memory-mapped at import, and only the pages that the image's
colours touch are faulted in. If bundle size matters more than exactness at 8-bit codes, the
86³ grid alone (4.9 MiB as `rgba16Unorm`, see §2) can replace the 256³ table everywhere. In
3,000-code random samples it measured max 0.26 steps with code-space trilinear interpolation and
0.26–0.39 with linear-light trilinear interpolation, before 16-bit quantization.

Generation: an exact Levenberg–Marquardt solve per coarse node is done in Lagrange space, where
every point is a valid spectrum, with an analytic Jacobian at 1 nm. Moments then follow by a
1024-node midpoint rule. The 256³ entries are interpolated from the coarse grid in linear light,
and every quantized entry is decoded exactly as the GPU would decode it and checked. 61,392
entries above 0.35 steps are re-solved exactly. Results do not depend on the number of worker
processes: the test regenerates plane r = 0 bit for bit.

## 2. Data flow: where conversions happen

RGB inputs are converted to spectral data once per input, as late as the data allows. Every
conversion produces moments c (bounded inputs) or moments plus a scale (emission).

**Bounded colours** (OpenPBR `base_color`, `specular_color`, `coat_color`, `fuzz_color`,
`transmission_color`, `thin_film`-free tints; UsdPreviewSurface `diffuseColor`, `specularColor`):

1. *8-bit sRGB colour images* (`MaterialLibrary.decodeTexture`, `srgb: true`): convert each texel
   on the CPU through `FourierSRGB256.bin` into an `rgba16Unorm` **moment texture** (c0, c1, c2,
   alpha). Filtering then averages moments. Moments are linear in the spectrum and the valid set
   is convex, so a filtered texel is the exact moment vector of the averaged reflectance. Mip
   generation stays a plain box filter. Memory: 8 B per texel instead of 4 B, only for colour
   images used by spectral materials. Linear data maps (roughness, normals, masks) are unchanged.
2. *16-bit, float and linear colour images, material constants, inspector colours and USD
   constants*: convert with `FourierSRGB86.bin`. On the CPU, interpolate trilinearly in linear
   light (as `interpolate` in the generator) when uploading constants (`Material`,
   `SurfaceSettings`, MaterialX constant registers).
3. *Colours computed per hit* (MaterialX graphs mixing images and constants, `resolve_materialx`):
   evaluate the graph in RGB as now, then convert its colour outputs at the BSDF input. Use a 3D
   `rgba16Unorm` texture of the coarse grid (86³, 4.9 MiB) sampled with hardware trilinear
   filtering at the sRGB-encoded colour (measured max 0.26 steps at the node spacing). This keeps
   graph semantics in RGB, the way artists author them; spectral graph evaluation is out of scope.

**Emission, HDRI and sky** (unbounded RGB radiance e): with s = max(e_r, e_g, e_b) and ĉ = e / s,
the spectral radiance is L_e(λ) = s · ρ_ĉ(λ) · S_D65(λ), with S_D65 normalized to Y = 1. Its
linear sRGB is e within the table's precision, and a white emitter is exactly D65.

- OpenPBR / MaterialX emission (`openpbr_emission`, the MaterialX emission register):
  `emission_luminance` × `emission_color` gives e, which is converted as above.
- Area, sphere and directional lights and UsdLux lights: the same RGB upsampling by default.
  Optionally, a light can carry an **illuminant preset** (`spectrum` = E, D65, A, FL11, HP1,
  LED-B3). Then L_e(λ) = intensity · ρ_tint(λ) · S_preset(λ), where the tint is bounded and
  converted like a reflectance. UsdLux `colorTemperature` can later map to a Planckian spectrum
  (A is the 2856 K case), which needs no table.
- HDRI environment (`eval_environment`, `MaterialLibrary.setEnvironment`): convert per lookup
  through the 3D coarse-grid texture with the emission scale. A per-texel moment image (2×
  environment memory) is the fallback if the lookup cost shows. Environment importance sampling
  stays luminance-based and does not change.
- Procedural sky (`eval_procedural_sky`): its RGB output is upsampled like emission. A physically
  based spectral sky model is separate future work; REFERENCES.md records no external derivation
  for the current sky.
- Fog / homogeneous media: RGB extinction coefficients are upsampled with the emission scale
  (positivity is all they need). Coat, transmission and volume transmittance colours are bounded
  and convert as reflectances; extinction then follows per wavelength as −log T(λ) / depth.

**Albedo and normal guides** for MetalFX and OIDN (`metalfx_guides_kernel`,
`DenoiserMaterialGuide`) stay RGB, computed from the RGB inputs as now.

## 3. Wavelength sampling and the 4-wavelength throughput

Per path sample, one u ∈ [0, 1) gives four wavelengths λk = F⁻¹((u + k) / 4), k = 0…3, with the
density p(λk) of the piecewise-linear table actually sampled, p = 1 / (1024 · node spacing)
(`vibe_sample_wavelength`). Sampling the table, rather than the analytic density, is what keeps
f / p unbiased (§1). The density is

p(λ) ∝ 0.9 · S(λ) s(λ) / ∫S s + 0.1 · s(λ) / ∫s, with s = |r̄| + |ḡ| + |b̄| (linear-sRGB CMFs).

The 10% defensive term keeps every wavelength that any CMF sees samplable. RGB-upsampled
emitters, the sky and environment maps all have energy where HP1 or FL11 have none.

**Scene illuminant:** Swift builds the scene's density on light changes as a power-weighted
mixture (`mixture_density` in the generator). The weight of each emitter is its luminous power:
RGB emitters, the environment and the sky count with the D65 shape, preset lights with their
preset. Swift inverts the mixture into a 1025-float buffer (4 KB), which costs microseconds.
Single-illuminant scenes and tests can index the six preset tables in the include directly.

**Types** (compiled only into the spectral pipeline variant, see §7):

```metal
struct Wavelengths { float4 lambda; float4 phase; float4 invPdf; uint heroOnly; uint hero; };
typedef float4 Spectrum;  // throughput / radiance at the four wavelengths
```

The phase is precomputed once per path (`vibe_fourier_phase`), so each reflectance evaluation
costs one Lagrange preparation per material input (about 60 flops, shared by all four
wavelengths) plus one atan per wavelength. On reaching an emitter, the path adds

XYZ += (1/4) Σk β(λk) Le(λk) x̄ȳz̄(λk) · invPdf_k.

At accumulation, the shading kernel converts the sample's XYZ to linear sRGB with
`VIBE_XYZ_TO_LINEAR_SRGB`. Everything downstream is unchanged: accumulation textures, MetalFX,
OIDN, tone mapping, PNG and EXR export, and readback. Monochromatic or narrow-band light can
produce out-of-gamut, negative linear sRGB. The ReSTCV policy already covers this: the
accumulation keeps negatives, and MetalFX, the display, exports and OIDN clamp at zero.

## 4. BSDF components (OpenPBR adapter)

Principle: **sample with wavelength-independent probabilities and evaluate per wavelength.** Lobe
selection weights, pdfs and MIS weights stay scalar. They are computed from the RGB parameters
exactly as now, so path sampling, NEE MIS and the ReSTIR targets keep one pdf per path. Only the
values become `Spectrum`. The exception is dispersion, below.

- **Adobe OpenPBR BSDF (`ADOBEOPENPBR`):** the vendored code works component-wise on `vec3`
  colours. Cross-channel terms (luminance-based lobe probabilities, average Fresnel) affect only
  the scalar sampling quantities. Phase 1 evaluates `eval_bsdf` with
  (ρ(λ0), ρ(λ1), ρ(λ2)) and again with (ρ(λ3), ·, ·), sharing `prepare_openpbr`'s geometric
  preparation, and the sampled direction and pdf come from the RGB-parameter preparation. Phase 2
  generates a `float4` variant in `scripts/prepare_shaders.py`, by type substitution recorded as
  an Apache-2.0 §4(b) modification like the energy-table substitution, and measures the
  difference. Vendored files stay unmodified.
- **Base / diffuse (EON, local Lambert fast path):** ρ_base(λ) from moments. The Lambert fast
  path is ρ(λ)/π.
- **Metal (F82-tint):** F0(λ) = ρ_base(λ) and the F82 tint is ρ_specular(λ), per wavelength, with
  the same formula. Measured complex-IOR spectra (n(λ), k(λ)) are optional later presets.
- **Dielectric specular / transmission:** `specular_ior` is scalar. Fresnel is evaluated per
  wavelength only when dispersion is on. Otherwise it is wavelength-independent and computed
  once.
- **Dispersion (`OPENPBR` "Dispersion"):** n(λ) = A + B / λ² with
  B = (n_d − 1) / (V_d (λF⁻² − λC⁻²)), A = n_d − B / λd², and
  V_d = `transmission_dispersion_abbe_number` / `transmission_dispersion_scale` (C, d, F lines at
  656.3, 587.6 and 486.1 nm). `cauchy_coefficients` in the generator implements this, and the
  tests check that it reproduces n_d and V_d. When B ≠ 0 at a **delta** refraction, the four
  wavelengths cannot share a direction. Following the hero-wavelength convention (`HERO2014`),
  the path keeps one wavelength, the hero j = ⌊4 u_h⌋, where u_h is the second dimension of the
  `Z_WAVELENGTH` event (§6): β(λj) ← 4 β(λj), the others become zero, and `heroOnly` is set. Choosing j uniformly
  keeps the estimator unbiased under stratification: always keeping k = 0 would sample only the
  first stratum. Later events reuse the same hero. For **rough** dispersive transmission, the
  sampled direction is valid for all wavelengths. Phase 1 also terminates to the hero (simple and
  unbiased). Phase 2 can keep all four with the spectral MIS of `HERO2014` (balance weights over
  the four wavelengths' pdfs).
- **Thin film** (`thin_film_weight`, `thin_film_thickness` in µm, `thin_film_ior`; not integrated
  in RGB mode): Airy reflectance per wavelength with the phase 4π n d cos θt / λ. Spectral
  transport is where this becomes exact; RGB mode would need an approximation.
- **Coat:** `coat_color` ρ_coat(λ) feeds the existing absorption expression per wavelength.
  Coat IOR and dispersion follow the dielectric rules.
- **Fuzz:** `fuzz_color` → ρ_fuzz(λ). The LTC lobe (`SHEEN2022`) is achromatic, so only the tint
  is spectral.
- **Emission:** §2.

## 5. ReSTIR DI / GI / PT and ReSTCV

**Target functions** stay scalar: p̂ = luminance of the sample's contribution integrated over its
four wavelengths, Y = (1/4) Σk f(λk) ȳ(λk) / p(λk). `pt_luminance` applied to the converted
linear sRGB gives the same value.

**The wavelength set travels with the sample.** A reservoir's sample is the pair (path, u). Every
shift is the identity on u: the receiver evaluates the shifted path at the sample's own
wavelengths. The shift Jacobians therefore do not change, and GRIS (`RESTIRPT2022`) stays valid.
The pairwise, Talbot and Algorithm 6 MIS weights evaluate every domain's target at the same
(T(x), u), so they stay consistent without storing other pixels' wavelengths. Each pixel's
canonical sample uses that pixel's fresh u. The bias status of every mode is therefore unchanged
from RGB mode (REFERENCES.md: `RESTIR2020`, `RESTIRGI2021`, `RESTIRPT2022`, `SPMIS2026`,
`RESTCV2026`).

The alternative, re-evaluating reused samples under the receiver's wavelengths, was rejected. It
would need the suffix radiance at wavelengths the source never traced (GI and PT reconnection
reuse stored suffix radiance), so it is either biased (re-upsampling the RGB suffix loses
narrow-band spectra such as FL11 lines) or impossible. It would also make MIS weights depend on
each neighbour's u, which would then have to be stored.

**Storage consequences:** anything later multiplied by a receiver-evaluated spectral throughput
is stored per wavelength, together with u. Final, integrated contributions stay linear sRGB.

| Structure | RGB mode | Spectral mode |
|---|---|---|
| `DIReservoir` / `LightSample.emission` | `float3` | `half4` Le(λk) and 16-bit u (or re-evaluate Le from the light at u) |
| `GIReservoir.radiance` | `float3` | `half4` suffix radiance and 16-bit u |
| `PTReservoir.rcRadiance` | `packed_float3` (12 B) | `half4` (8 B) and 16-bit u, so the struct stays 64 B |
| `PTReservoir.F`, `PTControl.estimate`, accumulation | linear sRGB | unchanged (integrated) |

- **ReSTIR PT random replay:** derive u, and the hero index for dispersion, from the base path's
  reservoir key (`PTReservoir.seed`) through the `Z_WAVELENGTH` event (§6). A replayed offset
  path then reproduces the same wavelengths automatically, and the 16-bit u in the table above is
  only a cache. Paths with `heroOnly` set have their delta segments
  wavelength-specific. They stay shiftable through replay. Reconnection across a dispersive delta
  vertex is already excluded, because delta vertices are not connectable.
- **ReSTCV:** α_ij = min(ρ_i / ρ_j, 2) per channel stays computed from the RGB reflectance
  estimate (`pt_reflectance`), which depends only on geometry and materials. The from-j
  difference terms therefore stay zero-mean (`RESTCV2026` bias argument). Only efficiency can
  change, and it should improve: the per-pixel F_i estimates integrate many samples' wavelengths,
  which suppresses exactly the per-sample colour noise that spectral transport adds.
- **Per-frame colour noise:** f(Y) W shading shows one path's four wavelengths per pixel and
  frame. Expect more chroma noise than RGB mode in the raw ReSTIR output: the §1 measurements give
  roughly 0.2–1.0 relative RMS per channel for one sample under D65. ReSTCV, temporal
  accumulation and MetalFX absorb most of it. The test plan measures it.

## 6. Sampler dimension

The Z++ sampler (`ZPP2026`; REFERENCES.md "October 2 Z++ sampler") reserves the event stream
`Z_WAVELENGTH` (12) at path vertex 0 for this. u is one dimension per path sample, drawn once and
never per bounce. Every pass that needs it (pass 1 `restir_temporal_kernel` / the ReSTIR PT
initial kernels, pass 2 `shading_kernel`, and the MetalFX guides) calls
`sampler_event(s, 0u, Z_WAVELENGTH)` and then one `rand_f(s)`, exactly where and how the lens
sample is drawn (`lens_ray` with `Z_LENS`). All passes of a pixel therefore see the same u. An
alternative is one joint `rand_f3` with the lens (2D aperture + u), which keeps the three
dimensions jointly stratified but couples the wavelength to the depth-of-field setting. The
separate event is preferred, so that lens on/off does not change the wavelength sequence. In
PCG mode the same call sites draw from the PCG state.

The hero choice at dispersive events (§4) is the next dimension of the same event: a second
`rand_f` after u. It too is drawn at vertex 0, whether or not a dispersive interface is hit, so the
dimension layout never depends on the path. ReSTIR PT re-derives both from the reservoir key:
`pt_sampler(r.seed, 0, …)` rebuilds the pixel's Z++ sampler from `PTReservoir.seed`, which holds
the Z key at generation, and then `sampler_event(…, 0u, Z_WAVELENGTH)` gives the same u (§5).
ReSTIR DI and GI reservoirs come from other pixels' samples, so they store u (§5).

## 7. Modes, UI and persistence

- `enum LightTransport: UInt32 { case rgb, spectral }`, as `PathTracerRenderer.lightTransport`,
  passed in `Uniforms` and as a Metal **function constant**. The spectral pipelines are a separate
  specialization, compiled lazily on first use, so RGB pipelines and their results stay bit
  identical (the `tests/benchmark.py` zero-tolerance check).
- Render inspector: a **Light transport** popup (RGB / Spectral), next to the ReSTIR mode
  controls (`StudioController.restirModeControls`). It follows the **Sampler** popup's pattern in
  `Sources/StudioUI.swift`: a `lightTransportChoices` table of (mode, title), the shared popup
  builder with the current and automatic labels, one undo step per change, and an accumulation
  reset. Persistence follows `ProjectDocument`'s optional `sampler: UInt32?` field. Lights get an optional **Spectrum** menu (RGB tint /
  preset).
- `ProjectDocument.lightTransport` and the per-light `spectrum` are optional fields. Absent
  values open as `.rgb` and no preset. Exports copy the interactive mode. In `-D VIBE_TESTING`
  builds, `VIBE_LIGHT_TRANSPORT=spectral` selects the spectral mode.
- Bundling: `build.sh` copies `SpectralTables.metal` and `FourierSRGB86.bin` into the app's
  resources, and `FourierSRGB256.bin` too if §1's exact path is kept. `check_bundle.py` is updated
  to expect them. `THIRD_PARTY_NOTICES.md` (bundled already) carries the CC BY-SA 4.0 and BSD
  notices.

## 8. Memory and performance expectations

- Constant data: 42 KB in the include (CMFs 5.6 KB, presets 11 KB, inverse CDFs 25 KB), plus a
  4 KB scene inverse-CDF buffer.
- Coarse-grid 3D texture: 4.9 MiB. The 256³ table is 96 MiB on disk and mapped only during image
  conversion.
- Moment textures: 2× the memory of the colour images they replace.
- Reservoirs: PT unchanged (64 B), GI +8 B per pixel, DI +4–8 B per pixel.
- Registers: the throughput goes from 3 to 4 floats, and the wavelength state adds about 12 floats
  per path.
- Arithmetic: one Lagrange preparation per coloured input per hit, and 4 atan per reflectance.
- Peters measured 2–36% frame-time overhead for 4 wavelengths (`PETERSBLOG2025` part 2, RTX 5070
  Ti, ≤ 0.3 ms absolute). Expect the same order on Apple GPUs. The Adobe BSDF evaluated twice
  (phase 1) is likely the largest cost. The spectral pipelines exist only when selected.

## 9. Test plan for the integration step

1. **RGB unchanged:** with `.rgb`, every `tests/benchmark.py` scenario is bit-identical to the
   pre-integration shaders.
2. **Gray-world parity:** grey and white materials under D65 (the sky, environment and RGB lights
   are D65-shaped) in spectral mode match RGB mode within noise. For example, Cornell with white
   walls: mean radiance within 3 SE over 1,024 frames, per channel.
3. **Colour round trip in renders:** a flat-lit (D65, unshadowed) plane per sRGB test colour
   (the codes from §1, including saturated cyan 18, 239, 253) renders within 0.5 8-bit steps of
   its albedo after convergence. The spectral and RGB Cornell box differ only by noise under D65.
4. **Monochromatic behaviour:** a narrow preset (or a 1 nm-wide test spectrum) at 500 nm lights a
   white plane. The converged colour is the CMF chromaticity at 500 nm, out of gamut (negative
   red), and the clamped display shows the expected hue. RGB mode cannot produce this
   (`PETERSBLOG2025` part 3).
5. **Illuminant presets:** under HP1, A and FL11, a white plane's linear sRGB equals the preset's
   computed sRGB (from the table) within noise, and E[Y] equals the light's luminance.
6. **Dispersion prism:** a dispersive dielectric prism (`transmission_dispersion_scale` 1, Abbe
   20) under a narrow white beam. The exit angles of 486.1 / 587.6 / 656.3 nm match Snell's law
   with the Cauchy n(λ) on monochromatic presets. The white beam's converged energy is conserved
   to 1% against the non-dispersive prism, and the hero termination introduces no bias: the mean
   over the screen equals the non-dispersive case for an integrating detector.
7. **ReSTIR consistency:** spectral ReSTIR DI/GI/PT (with and without ReSTCV and SPMIS) against
   spectral MIS reference: the same bias tolerances as the RGB tests (`Fix_restir-pt.swift`,
   `Fix_spmis.swift`, `Fix_restcv.swift`), and identity shifts reproduce the base path exactly
   with u carried.
8. **Persistence and UI:** projects round-trip `lightTransport` and light `spectrum`. Old projects
   open in RGB mode. Exports copy the mode. MetalFX, OIDN and the EXR/PNG paths receive linear
   sRGB and pass their existing checks.
9. **Performance:** frame time and equal-time MSE, RGB vs spectral, recorded in
   `tests/PERFORMANCE.md`.

## 10. Open questions

- **8-bit images:** pre-converted moment textures (exact per texel, filtering in moment space,
  2× memory) or runtime conversion through the 86³ texture (memory-neutral, ≤ 0.26 steps,
  filtering in RGB)? Measure both. If runtime conversion is good enough, `FourierSRGB256.bin`
  becomes a test reference and is not bundled.
- **Adobe BSDF:** two `float3` evaluations, or a generated `float4` variant (§4)?
- **Emission scale:** whether s = max component is best, or luminance-based normalization behaves
  better for very saturated emitters (both are exact in colour).
- **Spectral MIS for rough dispersion** (`HERO2014`) is worth it only if the prism test shows
  visible hero noise.
- **Spectral sky:** the procedural sky stays RGB-upsampled until a physically based spectral sky
  model with a verifiable source is chosen.

## 11. Decisions taken in the integration (2026-10-03)

The renderer integration follows §2–§8 with the changes below. Measurements: `tests/PERFORMANCE.md`
("Spectral light transport"), `tests/Fix_spectral.swift` and `tests/SpectralTables.py`.

**Tables: the coarse grid at render time, refined where it is inexact; `FourierSRGB256.bin` is
opt-in.** Every bounded colour (material constants, filtered texture colours, MaterialX outputs, the
normalized colour of every emitter) converts where it is used, through `FourierSRGB86.bin`: its 86³
exact solutions are loaded once into a float4 device buffer and interpolated trilinearly in linear
light (8 loads; the generator's `interpolate`), then reconstructed by the bounded MESE. Greys skip the
grid: their spectra are exactly flat. Measured over all 16,777,216 8-bit codes on the GPU, the plain
interpolation reaches **0.79 8-bit steps** at saturated cyans such as (0, 231, 254) (821 codes above
0.5, mean 0.013); the same happens in double precision (0.786 at that code), so it is interpolation
error near the gamut boundary, not float32 rounding. The "exact re-solve" option therefore became a
one-time refinement when the grid is loaded (`PathTracerRenderer.refineSpectralGrid`, about
369 ms on the M4): a GPU pass over every code flags the cells it reproduces worse than
0.35 steps (5,189 of 614,125; the generator's re-solve threshold), and a second pass solves the 64
codes of each such cell exactly (Levenberg–Marquardt in Lagrange space, then the moments, as the
generator does) into an 8 MiB block that `spectral_moments` interpolates at one-code spacing. The
round trip of the renderer's float32 path is then **max 0.459, mean 0.012 8-bit steps**
over all codes (22 above 0.4, none above 0.5; `tests/Fix_spectral.swift`), against 0.438
for the 256³ table, whose 16-bit quantization adds error. The 256³ table became a test reference:
the generator writes it only with `--lut256`, `build.sh` neither generates nor bundles it, and
`tests/SpectralTables.py` checks it when the manifest lists it. The first build solves only the grid:
**100 s instead of about 470 s** on the M4 (10 processes), then nothing until the generator
changes. 8-bit textures stay RGB and are filtered in RGB as before, then converted per hit
(memory-neutral), so the moment textures of §2 and §10 were not implemented. GPU memory: 17.7 MiB (18.6 MB) for
the grid and its refinement blocks, shared by the renderers of a device.

**Library variant by preprocessor, not function constant.** Spectral libraries compile the same
source with `VIBE_SPECTRAL=1` after `SpectralTables.metal`. RGB libraries see only the RGB code
(`Spectrum` is `float3`, every conversion helper is the identity and `Wavelengths` is empty), and
`tests/benchmark.py --baseline <main> --output-tolerance 0` renders every procedural scenario
bit-identically. The spectral pipelines (both scene libraries) compile on first use, concurrently,
in the background in the application (2.9 s on the M4 the first time; Metal's shader
cache makes later launches fast); frames trace in RGB meanwhile and accumulation restarts when
they are ready. Test builds compile them synchronously.

**Sampling PDFs at the path's wavelengths.** §4 asked for lobe probabilities and PDFs from the RGB
parameters, which costs a third OpenPBR preparation per vertex. Instead the preparation of lanes
0–2 (base colour ρ(λ0..2), wavelengths λ0..2) samples directions and gives the PDF, and lane 3's
value is divided by that same PDF. This is the generating density for every lane (HERO2014 Sec. 4.1:
divide by the probability that generated the path), so the estimator stays unbiased, NEE MIS uses
one consistent PDF, and ReSTIR targets, shifts and Jacobians evaluate it at the sample's own
wavelengths. The lane-3 preparation is skipped when every lane equals lane 0 (a grey base colour
without thin film or dispersion).

**Hero wavelength on arrival.** A path keeps one wavelength (the lane chosen by `heroU`, times
four) from its first dispersive vertex on, delta or rough: `spectral_arrive` runs before the vertex
scatters (NEE and BSDF sampling) and never touches its emission, in pass 1, pass 2, ReSTIR PT's
generation and every shift. Terminating rough dispersive transmission as well keeps NEE MIS
consistent with a single PDF; the spectral MIS of `HERO2014` Sec. 3.2 for rough dispersion is not
implemented. A ReSTIR PT suffix that passed a dispersive vertex holds only the hero lane, unscaled,
and is flagged (`PT_RC_DISPERSIVE`), so a receiver whose prefix kept four lanes applies the factor
of four itself. `tests/Fix_spectral.swift` checks Snell's law with the Cauchy fit at the F, d and
C lines and that terminating every path through a glass sphere keeps the image mean.

**Wavelength sampling.** One equal-weight mixture of the illuminants a scene's emitters use (D65 for
the sky, environment maps and RGB-coloured lights; the light and sun presets), built by
`spectral_icdf_kernel` when they change (a preset's generated table when only one is used). The
power weighting of §3 needs emitter powers the renderer does not track; any mixture with the
defensive term is unbiased.

**Unscattered paths are exact.** Camera rays that reach an emitter or the sky add its exact linear
sRGB (`emitter_rgb`, `environment_rgb`: the RGB colour for D65, a 1 nm sum for a preset) instead of
a four-wavelength estimate, so visible lights and the sky carry no colour noise and MetalFX's
noise-free mask for them stays valid.

**Accumulation keeps negative values.** A single spectral sample is often outside the sRGB gamut,
so the progressive average keeps negative channels (as ReSTCV's estimates); MetalFX receives the
clamped frame, and display, PNG/EXR export and OIDN clamp at zero.

**Reservoir layouts.** DI reservoirs keep RGB emission and store u in `weights.w`; GI reservoirs
store their secondary radiance per wavelength in `radiance.xyzw` and u in `weights.w`; ReSTIR PT
stores `rcRadiance` as its maximum and four 16-bit fractions in the same 12 bytes and re-derives
its wavelengths from the replay seed. Every reservoir size is unchanged.

**Caching that did not pay.** Converting a vertex's albedo once into a cached `Material` field, and
the area light's colour once per kernel into `Wavelengths`, cut the conversions but made the frame
5–30% slower (register pressure in the path loops). The kept caches cost no registers: the area
light's Lagrange multipliers are solved on the host per frame (`SpectralColour`,
`SpectralScene.lightLagrange`), the CMFs and the phase are read from a per-nanometre float4 table,
and a D65 sun lets the environment convert in one piece.

**Default: Automatic, which is RGB unless the scene needs wavelengths.** Spectral transport costs
6–71% more frame time at 640 × 480 (Cornell with ReSTIR GI 12.6 → 18.0 ms, Pavilion 27.7 → 41.5 ms), well above Peters' ≤ 0.3 ms / 2–36%,
and RGB scenes render statistically identical images (grey-world parity, colour round trips within
half an 8-bit step), so at equal time it loses wherever the scene is RGB (1.15–1.71 times RGB's time to equal error).
Automatic therefore resolves to Spectral only for an illuminant preset other than D65, dispersion
or thin film, where RGB cannot render the effect: narrow-line spectra (FL11, HP1) on coloured surfaces, dispersion's colour fringes and thin-film iridescence, while RGB scenes differ only by RGB's interreflection error (up to 3% in one channel in the Pavilion).

Not done: spectral sky models, Planckian `colorTemperature`, measured conductor spectra, per-light
spectra for imported UsdLux lights (they follow the Light spectrum preset), and phase 2 of §4 (a
generated float4 variant of the upstream BSDF).
