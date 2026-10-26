# Participating media, per-light spectra and spot lights: design

Status, 2026-10-23: **implemented** (phase 1 of the spectral showcase plan), with the changes recorded in
§8, which supersede §1–§7 where they differ. Citation keys refer to [REFERENCES.md](../REFERENCES.md). The renderer
direction in `AGENTS.md` holds: the Swift/Metal renderer is extended, not replaced.

The goal is the effects that the spectral examples (`Examples/Spectral`) cannot show yet:
- light whose colour comes from its spectrum, not from an RGB tint: lasers, sodium, blackbody;
- beams and cones of light;
- light scattered by particles: haze, milky water, and the blue-and-orange Tyndall effect, which
  only a wavelength-dependent scattering coefficient produces.

## 1. Scope

In scope:
1. **Per-light spectra.** Every emitter can carry its own spectrum: an illuminant preset, a blackbody
   temperature or a narrow band (a laser or line source). Today one scene-wide preset applies to all
   emitters (`SpectralScene.lightIlluminant`).
2. **Spot lights.** UsdLux `ShapingAPI` cones (`OPENUSD`) on rectangle and disk lights.
3. **Homogeneous participating media,** spectral and RGB:
   - a scene medium filling all space (haze);
   - interior media of closed transmissive objects, from the OpenPBR `transmission_*` inputs (`OPENPBR`).
4. **Scenes** that show them (§7).

Out of scope here: heterogeneous media (OpenVDB, `UsdVol`), media emission, light tracing and
photon methods (the prism fan, phase 3), fluorescence (phase 2), and ReSTIR reuse through media.

## 2. Per-light spectra

**Model.** An emitter's spectral radiance is L(λ) = intensity × ρ_tint(λ) × S(λ). Here ρ_tint is the
bounded upsampling of its RGB colour (as now), and S is its spectrum, normalised to luminance
Y = Σ S ȳ = 1 like the presets. With that normalisation the intensity keeps its photometric meaning
whichever spectrum is chosen.

| Kind | S(λ) | Parameters |
| --- | --- | --- |
| Inherit | the scene preset (`lightIlluminant`) | none; the default, so existing scenes are unchanged |
| Preset | `vibe_illuminant_spd[k]` | E, D65, A, FL11, HP1, LED-B3 |
| Blackbody | Planck's law B_λ(T) (`PLANCK`, with c₂ = hc/k = 1.438776877 × 10⁻² m·K) | temperature in kelvin |
| Narrow band | Gaussian of the given centre and full width at half maximum, truncated to 360–830 nm | centre, FWHM in nm |

**GPU.** Each material slot gets an emitter record next to its OpenPBR spectral parameters:
`MaterialResources.spectralMaterials` grows from 3 to 6 float4 per slot (§4, §5 use the rest).
`emitter_spectrum(e, slot, wl)` replaces `emitter_spectrum(e, wl)` at every emission evaluation. The
slot comes from the hit (`HitRecord.mat.slot`) or, for a light sample, from its triangle index
(`LightSample.isDirectional - 2`), which ReSTIR reservoirs already store. Procedural scenes' lights
keep the scene preset.

**Exact colour for camera rays** (`spectral_emission_rgb`): the 1 nm sum over S, generalised from
the preset table to the analytic kinds.

**Wavelength sampling.** `spectral_icdf_kernel` mixes the scene's illuminants by equal weights
(`spectralIlluminantWeights`), with the 10% defensive term. Blackbody and narrow-band emitters join
the mixture as analytic shapes: up to 8 distinct shapes, the rest counted as D65. Without this, a
laser's few nanometres would be sampled about 1% of the time, so its colour would be noise.

**RGB transport.** An emitter's RGB colour becomes the linear sRGB of its normalised spectrum times
its tint (computed on the host). A narrow band outside the sRGB gamut is clipped at zero, as the
display already does.

**Authoring.**
- UsdLux `inputs:enableColorTemperature` / `inputs:colorTemperature` set a blackbody. This was
  previously reported as not applied.
- Custom attributes `vibe:spectrum` (token: `inherit`, `E`, `D65`, `A`, `FL11`, `HP1`, `LED-B3`,
  `blackbody`, `narrowband`), `vibe:spectrum:temperature`, `vibe:spectrum:center` and
  `vibe:spectrum:fwhm` cover the other kinds.
- `SceneState.emitterLights[slot]` stores the result and persists it in projects (optional,
  so older projects open unchanged).
- The Materials page shows and edits an emitter's spectrum.

## 3. Spot lights (UsdLux ShapingAPI)

From the `ShapingAPI` specification (`OPENUSD`, checked 2026-10-23):

- θ_off = acos(axis · ω) and θ_cut = radians(`shaping:cone:angle`).
- Emission is zero beyond θ_cut. With softness s in (0, 1], θ_start = lerp(s, θ_cut, 0), and emission
  is scaled by 1 − smoothstep(θ_start, θ_cut, θ_off).
- The focus f ≥ 0 scales emission by |axis · ω|^f.
- Defaults: angle 90°, softness 0, focus 0. `focusTint` is not applied and is reported.

The axis is the light's −Z, the direction a rectangle or disk light emits along, which is its
emitting face's normal. So no per-node data is needed and the shape survives node edits. Sphere
lights with shaping are reported as not applied.

**Where it applies.**
- In `light_spectrum` (NEE and every reused light sample), from the sample's own direction `ls.wi`,
  so a reservoir moved to another pixel is re-evaluated there.
- At BSDF hits on emitters, from the ray direction.

Emitter selection weights and `eval_light_pdf` are unchanged, so the light and BSDF strategies keep
consistent MIS pdfs. A narrow cone wastes some light samples, which only adds variance.

**Beams.** A small disk with a cone of a few degrees is a near-collimated beam. It remains an area
light, so MIS and NEE work unchanged. There are no delta lights.

## 4. Homogeneous media

**Coefficients** (`ADOBEOPENPBR` `openpbr_create_volume_from_openpbr_params`, the OpenPBR
Transmission section):
- σ_t = −ln(transmission_color) / transmission_depth;
- σ_s = transmission_scatter / transmission_depth;
- σ_a = σ_t − σ_s, shifted by grey if any channel is negative;
- Henyey–Greenstein anisotropy g = `transmission_scatter_anisotropy` (`HG1941`).

In spectral transport the colours are upsampled like other bounded colours (`docs/SPECTRAL_DESIGN.md`
§2), so σ(λ) = −ln ρ_color(λ) / depth.

**Scene medium.** `ProjectDocument.medium` holds: density (σ_t at 550 nm, per metre), scattering
colour (single-scattering albedo, RGB), anisotropy, and a Rayleigh switch. With the switch on,
σ_s(λ) = σ_s(550) (550/λ)⁴ (`BUCHOLTZ1995`; air's exponent is about 4.08, and particles much smaller
than the wavelength give 4). In RGB transport the Rayleigh law is evaluated at the sRGB primaries'
dominant wavelengths. Authoring:
- UI: Lighting page, **Atmosphere**.
- USD: custom attributes on the default prim, `vibe:medium:density`, `vibe:medium:albedo`,
  `vibe:medium:anisotropy` and `vibe:medium:rayleigh`. USD has no homogeneous-fog schema, and
  `UsdVol` needs field assets.

**Interior media and boundaries.**
- A slot has an interior medium when its MaterialX program sets `transmission_weight` > 0 and
  `transmission_depth` > 0 and is not thin-walled.
- The medium applies between entering a front face and leaving through a back face of that slot.
  One level is tracked: the scene medium, or one object's interior. Overlapping media are not
  supported.
- A **medium boundary** is a transmissive slot with `specular_weight` = 0: no reflection or
  refraction, only a change of medium. Shadow rays pass through boundaries and accumulate the
  transmittance of each segment. Any other surface still blocks them, glass included, so light
  reaches media behind real glass only through BSDF sampling, as today.

**Integrator** (`volume_path`, a non-inlined function that `shading_kernel` calls when
`Uniforms.media` is set):
- Distance sampling in a chromatic medium uses a single-sample mixture over the four wavelength lanes,
  weighted by throughput × albedo (`ADOBEOPENPBR` `openpbr_sample_event_distance` and its weight
  functions, applied to `Spectrum` lanes instead of RGB channels). The pdf is
  p(t) = Σ_k w_k σ_t,k e^(−σ_t,k t). A scattering event's weight is T(t) σ_s / p(t), and reaching
  the surface weighs T(d) / Σ_k w_k T_k(d).
  - This is the balance-heuristic spectral MIS of `PBRT2023` (Ch. 14, "Spectral Multiple Importance
    Sampling"), with the lane mixture as the proposal.
  - It keeps all four wavelengths: unlike delta dispersion, a shared distance is valid for every lane.
- Scattering uses Henyey–Greenstein phase sampling, with NEE from medium vertices (phase × transmittance)
  and the power heuristic against phase sampling.
- Surface vertices behave exactly as in the existing path loop (BSDF sampling, NEE, Russian roulette,
  dispersion hero lanes), with media tracked across refractive and boundary surfaces.
- When media are present, the host resolves the strategy to **Standard MIS** for the frame and skips
  the ReSTIR passes; the inspector says so. The G-buffer pass still runs for MetalFX's guides.
- The preview camera fog (`apply_camera_fog`) is skipped when a scene medium is set.

## 5. GPU data

Per slot, `spectralMaterials[6 * slot + i]`:

As implemented, 8 float4 per slot (`SLOT_PARAMETERS`, `MaterialLibrary.slotStride`):

| i | Content |
| --- | --- |
| 0 | `SpectralMaterial` (dispersion, thin-film weight, thickness, IOR) |
| 1 | `specular_color` (rgb) |
| 2 | `transmission_color` (rgb), w = thin-walled |
| 3 | emitter spectrum: kind (0 inherit, 1 preset, 2 blackbody, 3 narrow band), a, b, 1 / luminance |
| 4 | the emitter spectrum's linear sRGB at luminance one (RGB transport) |
| 5 | emitter shaping: cone angle and smooth start in radians, focus, 1 when shaped |
| 6 | interior medium: `transmission_scatter` (rgb), w = `transmission_depth` (0 when none) |
| 7 | interior medium: anisotropy, index-matched boundary flag, Rayleigh flag, 0 |

`Uniforms` gains `float4 mediumScatter` (rgb albedo, w = density) and `float4 mediumOptions`
(anisotropy, Rayleigh, media present, 0); it grows from 304 to 336 bytes. The scene medium's box is not a
uniform: `medium_box` reads the imported scene's world bounds from the node buffer's header
(`MeshSceneHeader.lo/hi`), or the procedural scenes' fog boxes.

## 6. Validation

Each check goes in the test suite (`tests/Fix_volumes.swift`, `tests/Fix_spectral.swift`):

1. **Beer–Lambert:** an absorbing slab in front of a uniform emitter matches exp(−σ_a d) per channel
   and per wavelength lane.
2. **Furnace:** a sphere of albedo-1 medium under a uniform white environment renders the
   environment's radiance (energy conservation, any g).
3. **Spectral and RGB agreement** for a grey medium.
4. **Single scattering:** a thin isotropic slab lit by a distant source matches the analytic
   single-scattering radiance.
5. **Blackbody at 2856 K** reproduces CIE A's chromaticity.
6. **Narrow band:** a 532 nm laser's chromaticity matches the CMF at 532 nm; the wavelength mixture
   samples it with the expected probability.
7. **Spot cone:** a disk light's radiance is zero beyond the cone and follows the smoothstep inside;
   NEE and BSDF-hit estimates agree.
8. **Strategy fallback:** a scene with media renders with Standard MIS, and without media it renders
   exactly as before (zero-tolerance baseline in `tests/benchmark.py`).

## 7. Scenes

- **Tyndall tank:** a glass-boundary cube of Rayleigh-scattering medium, lit along its length by a
  white beam. Seen from the side it looks blue; the beam leaves orange.
- **Light shafts:** a spot light through a slatted screen into haze, with a dichroic (thin-film)
  panel splitting the beam into complementary reflected and transmitted colours.
- **Lamp spectra:** the same white objects under sodium, fluorescent, LED, a 2700 K blackbody and a
  laser line, side by side in light haze.

## 8. Decisions taken in the implementation

- **Light selection of spot cones.** Emitters are chosen in proportion to radiance × area, which made a
  narrow, bright beam (a laser line in the lamp-spectra drafts) take almost every light sample. A shaped light's weight is
  scaled by sin² of its cone angle at the middle of its soft edge, which is approximately the fraction of
  the hemisphere's power the cone emits (`EmitterLight.selectionScale`). Both MIS strategies read the same
  weights.
- **Rayleigh interior media** (USD `vibe:medium:rayleigh` on a material, `MaterialXProgram.mediumRayleigh`)
  are a local extension, not OpenPBR:
  - σ_s(λ) = luminance(`transmission_scatter`) / depth × (550/λ)⁴;
  - `transmission_color` adds absorption on top, so white gives a purely scattering medium.

  OpenPBR's own rule shifts negative absorption by grey. With a white `transmission_color` that makes
  extinction grey (the bluest lane's scattering), which absorbs red as strongly as blue scatters.
- **Medium boundaries** are slots with a constant `specular_weight` of 0, a `transmission_weight` of 1 and
  a positive `transmission_depth`. They change the medium without refraction (OpenPBR's
  `specular_weight` 0 removes the interface).
- **Colour temperature.** UsdLux defines `colorTemperature` as an RGB white point normalised so that
  6500 K is white. The importer uses the physical Planck spectrum normalised to luminance one instead, and
  reports it (`PLANCK`).
- **Per-light presets in RGB transport** stay white, like the scene-wide presets. Blackbody and narrow-band
  lights take their spectrum's colour.
- **MIS weights.** At media and surface vertices the phase or BSDF pdf is scaled by the lane mean of the
  segment's transmittance, on both the NEE and the emitter-hit side, so the weights sum to one.
- **Validation** (`tests/Fix_volumes.swift`, 2026-10-23, Apple M4):
  - Free flights match the analytic transmittance and scattering integrals per lane within 1%, with all
    lanes or a single hero lane.
  - HG integrates to one with mean cosine g.
  - Blackbody 2855.5 K gives CIE A's chromaticity: (0.44757, 0.40744) against (0.44757, 0.40745).
  - Beer–Lambert gives 0.244 (RGB) and 0.250 (spectral) against 0.25.
  - Both white furnaces reproduce the environment within 0.2%.
  - Spot light and BSDF strategies agree within 5%, with no light outside the cone.
- **Scenes** (`Examples/Spectral`): **Tyndall Tank** and **Lamp Spectra** are implemented. The lamp scene's
  532 nm laser line was dropped: its 0.5° cone left almost every haze point outside it, so its light came
  from rare paths that scatter into the beam and showed as green fireflies across the undenoised image.
  Equiangular sampling (`KULLA2012`) is the fix that would bring it back.
  - The light-shafts scene with a dichroic panel is deferred. Shadow rays do not pass thin-walled glass, so
    its coloured shafts could only be found by BSDF or phase sampling hitting a small light. That needs
    thin-walled shadow transmittance (with the film's spectral Fresnel) or light tracing (phase 3).
