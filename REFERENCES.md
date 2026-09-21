# Metal Vibe Tracer references

Last reviewed: **2026-09-11**. Web references below were checked on the dates recorded by each entry.

This document records the algorithmic basis, identifiable formula sources, and API dependencies of the current renderer. It distinguishes implementation references from related work. The supplied `main.swift` did not include a complete bibliography, so matching an existing formula to a publication does not establish the original file's copying history or authorship.

Stable citation keys below may be used in source comments and project documentation. Code locations use symbol names in [main.swift](main.swift) and [Sources](Sources), rather than line numbers that drift after edits.

## Rendering and sampling

### RESTIR2020 — Direct-light reservoir reuse

Benedikt Bitterli, Chris Wyman, Matt Pharr, Peter Shirley, Aaron Lefohn, and Wojciech Jarosz. **Spatiotemporal Reservoir Resampling for Real-time Ray Tracing with Dynamic Direct Lighting.** *ACM Transactions on Graphics* 39(4), Article 148, 17 pages, 2020. [Author publication page](https://research.nvidia.com/labs/rtr/publication/bitterli2020spatiotemporal/). [DOI: 10.1145/3386569.3392481](https://doi.org/10.1145/3386569.3392481).

**Used in:** `restir_temporal_kernel`, `shading_kernel`, and direct-light reservoir target/weight evaluation. This project adapts ReSTIR DI for primary diffuse surfaces, with temporal and spatial reuse, history rejection, and capped history counts. It does not reproduce the paper's full unbiased estimator or incorporate NVIDIA's RTXDI SDK.

### RESTIRGI2021 — First-indirect-bounce path reuse

Yaobin Ouyang, Shiqiu Liu, Markus Kettunen, Matt Pharr, and Jacopo Pantaleoni. **ReSTIR GI: Path Resampling for Real-Time Path Tracing.** *Computer Graphics Forum* 40(8), pp. 17–29, High-Performance Graphics 2021. [Official NVIDIA publication page](https://research.nvidia.com/publication/2021-06_restir-gi-path-resampling-real-time-path-tracing). [DOI: 10.1111/cgf.14378](https://doi.org/10.1111/cgf.14378).

**Used in:** `gi_geometry`, `eval_restir_gi_target`, `gi_connection_visible`, the GI reservoir textures, GI candidate/temporal reuse in `restir_temporal_kernel`, and spatial reuse/reconnection in `shading_kernel`. For a diffuse primary hit `x1`, the local subset samples one diffuse `x2`, estimates outgoing radiance there with one direct-light sample and complementary MIS, converts the primary BSDF proposal from solid angle to area measure, and temporally/spatially reuses the `x2` path suffix. Reconnection re-evaluates the current primary BSDF, geometry term, scalar RGB target, and visibility. The ordinary tracer supplies deeper diffuse, glossy, and transmission paths.

**Visibility correction (2026-09-08):** `gi_connection_visible` recomputes its direction from the offset origin to the stored secondary point, keeping the traced ray and endpoint distance consistent.

**Adaptations and limits:** this is a bounded first-indirect-bounce diffuse subset, not the complete paper implementation. It omits glossy/specular shift mappings, full path reconnection, pairwise/generalized MIS, and reuse beyond `x2`; uses simple normal/depth/material compatibility; caps temporal history; and accepts the bias from correlated practical reuse. Standard MIS remains the reference strategy.

### MIS1995 — Multiple importance sampling

Eric Veach and Leonidas J. Guibas. **Optimally Combining Sampling Techniques for Monte Carlo Rendering.** *Proceedings of SIGGRAPH 1995*, pp. 419–428, 1995. [Author publication page](https://graphics.stanford.edu/papers/combine/). [DOI: 10.1145/218380.218498](https://doi.org/10.1145/218380.218498).

**Used in:** `power_heuristic`, `emission_weight`, and the light/BSDF contributions in `shading_kernel`. The renderer uses the power heuristic with exponent two. Scene 2 is a procedural illustration inspired by the glossy-surface/variable-light-size experiment; it is not a reproduction of the original benchmark's exact geometry, materials, or measurements.

### PBRT2023 — Path tracing and sampling implementation reference

Matt Pharr, Wenzel Jakob, and Greg Humphreys. **Physically Based Rendering: From Theory to Implementation.** 4th edition, MIT Press, 2023. [Online book](https://pbr-book.org/4ed/contents). Relevant sections: [13.4, A Better Path Tracer](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer) [8.6, Halton Sampler](https://pbr-book.org/4ed/Sampling_and_Reconstruction/Halton_Sampler), [5.2, Projective Camera Models](https://www.pbr-book.org/4ed/Cameras_and_Film/Projective_Camera_Models), [6.5, Triangle Meshes](https://www.pbr-book.org/4ed/Shapes/Triangle_Meshes), and [12.5, Infinite Area Lights](https://www.pbr-book.org/4ed/Light_Sources/Infinite_Area_Lights).

**Used in:** complementary light/BSDF weighting, throughput accounting, and compensated Russian roulette in `shading_kernel`; mathematical context for `frameJitter`. The local jitter is an unscrambled base-2/base-3 Halton sequence, centered on zero and repeated every 1,024 samples, rather than pbrt's full sampler. Excluding ideal reflection/refraction chains from the scattering budget and choosing separate roulette survival ceilings are local adaptations, not pbrt's termination policy. Finite scattering depth and approximate ReSTIR reuse still limit claims of unbiasedness for the whole renderer.

**Studio extensions:** `lens_ray` uses a uniform circular aperture and a focus plane perpendicular to camera forward. G-buffer and shading passes reuse the same per-pixel lens sample; MetalFX guides recover that sample's lens origin. This is a thin-lens approximation, not a multi-element optical model. `OBJMesh.build` and the resource-aware `trace_scene` overload implement a local median BVH with a bounded traversal stack and determinant/barycentric triangle intersection. They do not copy pbrt code or implement its watertight triangle algorithm or SAH builder. Positive uniform-scale object transforms preserve ray distance, normals, and tangent frames through `object_ray`/`world_hit`.

`eval_environment` evaluates a rotated latitude/longitude image in linear RGB. `sample_direct_light`/`eval_environment_pdf` now disable the sun-cone proposal for HDR maps and zero-intensity procedural suns, and use all proposals for imported emitters when the environment intensity is zero. Sampled and evaluated mixture probabilities change together. No luminance-distribution environment sampler was added. Primary diffuse ReSTIR DI estimates the full direct integral, so its BSDF emitter-hit contribution is excluded; conventional NEE vertices use complementary power-heuristic weights through `emission_weight`. The previous unconditional ReSTIR BSDF weight double-counted direct lighting and was reverted on 2026-09-08. Finite-light size affects intersected geometry, proposal/evaluated PDFs, and reservoir geometry terms consistently. Scene-light color/intensity affect both visible emission and sampled emission. These controls reset accumulation and reuse history.

### POLYHAVENHDRI — HDRI regression assets

Poly Haven, **Art Studio**, **Studio Small 01**, and **Photo Studio Loft Hall** environment maps. [Poly Haven HDRIs](https://polyhaven.com/hdris), CC0; individual asset pages are linked from `Examples/HDRI/README.md`. Retrieved 2026-09-07.

**Used in:** `scripts/fetch_test_hdris.py` and the local files under `Examples/HDRI`. These are optional regression inputs and are not bundled with the application or redistributed by this repository.

## Surface reflection

### GGX2007 — Microfacet distribution and masking

Bruce Walter, Stephen R. Marschner, Hongsong Li, and Kenneth E. Torrance. **Microfacet Models for Refraction through Rough Surfaces.** *Eurographics Symposium on Rendering*, 2007. [Author publication page and paper](https://www.cs.cornell.edu/~srm/publications/EGSR07-btdf.html).

**Used in:** mathematical background for GGX reflection/refraction in the vendored Adobe implementation. The former local `ggx_D` and `ggx_G1` functions have been replaced. OpenPBR now supplies rough transmission and multiple-scattering compensation; ideal legacy mirrors/glass retain local delta paths.

### VNDF2018 — Historical visible-normal sampler

Eric Heitz. **Sampling the GGX Distribution of Visible Normals.** *Journal of Computer Graphics Techniques* 7(4), pp. 1–13, 2018; corrected June 17, 2019. [Paper and errata](https://jcgt.org/published/0007/04/01/).

**Historical use:** the removed `sample_ggx_visible_normal` followed the projected-disk construction. The current Adobe sampler uses the spherical-cap method below.

### SCAPS2023 — Spherical-cap visible-normal sampling

Jonathan Dupuy and Anis Benyoub. **Sampling Visible GGX Normals with Spherical Caps.** 2023, arXiv:2306.05044v2. [Author paper](https://arxiv.org/abs/2306.05044v2).

**Used in:** the vendored `openpbr_sample_aniso_ggx_smith_vndf`; also used by the local metal-energy table generator. Upstream anisotropic stretching, reflection sampling, and PDFs are kept together.

### OPENPBR — Surface material specification

Academy Software Foundation, OpenPBR contributors. **OpenPBR Surface.** Living specification. [Official specification](https://academysoftwarefoundation.github.io/OpenPBR/).

**Used in:** material vocabulary and parameter mapping in `prepare_openpbr` and `MaterialEditor`. The integrated Adobe revision targets OpenPBR 1.1.1; this application exposes a subset, not full specification or interchange conformance.

### ADOBEOPENPBR — Integrated BSDF implementation

Adobe. **Adobe's OpenPBR BSDF.** Apache-2.0 reference implementation. [Repository](https://github.com/adobe/openpbr-bsdf); pinned revision **c91aad1d1ce1693e803f039d7c92c2965c4eb013**, retrieved September 4, 2026. Original files and license: [Vendor/OpenPBR](Vendor/OpenPBR/); provenance: [UPSTREAM.md](Vendor/OpenPBR/UPSTREAM.md).

**Used in:** `prepare_openpbr`, `eval_bsdf`, `eval_bsdf_pdf`, `eval_bsdf_with_pdf`, and non-delta `sample_bsdf`. Plain legacy diffuse materials use a local Lambert fast path, the zero-diffuse-roughness and zero-specular-weight limit of these inputs. The GPU adapter checks compare it with full upstream evaluation/PDF, including the negligible upstream EON epsilon term. OpenPBR material presets continue to use the layered implementation. Direct-light evaluation and PDF share one preparation; ReSTIR reservoir work runs only for eligible diffuse primary hits. Evaluation returns BSDF times cosine; the local adapter divides by the absolute shading cosine to fit existing lighting code. Sampling retains the full lobe PDF. Local ideal reflection/refraction paths remain because this upstream implementation does not provide delta lobes. The exposed subset includes base tint, roughness, metalness, coat, anisotropy, fuzz, IOR, transmission weight, and a rough-glass preset. Texture evaluation, geometric frames, ray offsets, guide buffers, and GUI are local. Interior volume integration, subsurface scattering, opacity, thin films, dispersion, and the full parameter set are not integrated.

**Local energy-table adaptation:** vendored files remain unmodified. `scripts/prepare_shaders.py` substitutes only the two ideal-metal energy-complement lookup bodies in the generated shader. `Shaders/MetalEnergy.metal` contains 129 roughness by 129 square-root-cosine nodes, generated with the pinned VNDF/Smith functions and 16,384 Hammersley samples per node. Its hemispherical average exactly integrates the interpolated angular table. Ordinary builds consume this checked-in data; GPU regeneration is optional through `scripts/generate_metal_energy.py`. The original 32-node angular grid produced approximately 1.068 and 0.952 white-furnace means at N·V=0.02 for roughness 0.04 and 0.1 in local repeated measurements. The replacement resolves those tested discrepancies. This is an integration-specific correction, not an upstream release or proof of energy conservation for every parameter combination. The anisotropic compensation remains the upstream approximation.

### SHEEN2022 — Upstream fuzz model and lookup data

Tizian Zeltner, Brent Burley, and Matt Jen-Yuan Chiang. **Practical Multiple-Scattering Sheen Using Linearly Transformed Cosines.** SIGGRAPH 2022 Talk. [Authors' code, paper links, and Apache-2.0 license](https://github.com/tizian/ltc-sheen).

**Used through Adobe:** `impl/openpbr_fuzz_lobe.h` and `impl/data/openpbr_ltc_array.h`. Adobe identifies its Disney-sheen routines and fitted lookup data as derived from this reference. Those comments and attribution remain in the vendor tree; the application bundles a third-party attribution document and Apache license.


### BASIS2017 — Orthonormal frames

Tom Duff, James Burgess, Per Christensen, Christophe Hery, Andrew Kensler, Max Liani, and Ryusuke Villemin. **Building an Orthonormal Basis, Revisited.** *Journal of Computer Graphics Techniques* 6(1), pp. 1–8, 2017. [Paper and code](https://jcgt.org/published/0006/01/01/).

**Used through Adobe:** the normal-only overload of `openpbr_make_basis` in `openpbr_basis.h` explicitly credits this construction. Analytic primitive tangents and the tangent-projection overload supply the textured material frames.

### IMAGEWORKS2017 — Fresnel averaging background

Christopher Kulla and Alejandro Conty. **Revisiting Physically Based Shading at Imageworks.** SIGGRAPH 2017 course, *Physically Based Shading in Theory and Practice*. [Official course and slides](https://blog.selfshadow.com/publications/s2017-shading-course/).

**Used through Adobe:** `openpbr_average_fresnel` in `impl/openpbr_lobe_utils.h` cites slide 18 for the average Fresnel approximation. This is also related background for microfacet energy compensation; the local table generator uses Adobe's actual VNDF and separable Smith functions, as documented under ADOBEOPENPBR.

### FRESNEL1994 — Schlick approximation

Christophe Schlick. **An Inexpensive BRDF Model for Physically-based Rendering.** *Computer Graphics Forum* 13(3), pp. 233–246, 1994. [Publisher / DOI: 10.1111/1467-8659.1330233](https://onlinelibrary.wiley.com/doi/10.1111/1467-8659.1330233).

**Used in:** `conductor_fresnel`, ideal metal/glass branch weights in `sample_bsdf`, and MetalFX material guides. Only the fifth-power Fresnel approximation is used, not Schlick's entire BRDF model. Metal color represents RGB normal-incidence reflectance `F0`; this is not a spectral complex-IOR conductor model.

## Random numbers and display

### HASH2020 — GPU PCG hash

Mark Jarzynski and Marc Olano. **Hash Functions for GPU Rendering.** *Journal of Computer Graphics Techniques* 9(3), pp. 21–38, 2020; revised October 23, 2020. [Paper, code resources, and errata](https://jcgt.org/published/0009/03/02/).

**Used in:** the PCG-style integer permutation in `pcg_hash`. `rand_f` locally feeds each hashed value back as its next seed and converts the upper 24 bits to `[0, 1)`. Statistical results for an upstream hash or generator do not by themselves certify this local sequence construction.

### PCG2014 — Underlying generator family

Melissa E. O'Neill. **PCG: A Family of Simple Fast Space-Efficient Statistically Good Algorithms for Random Number Generation.** Technical Report HMC-CS-2014-0905, Harvey Mudd College, 2014. [Author's paper page](https://www.pcg-random.org/paper.html).

**Relationship:** foundational attribution for the PCG family underlying `HASH2020`. This project uses the GPU hash form above, not a vendored PCG library or the standard stateful PCG32 API.

### HILLFIT — Tone-mapping curve

Stephen Hill. **`RRTAndODTFit` / `ACESFitted`**, as credited in *Baking Lab*, `BakingLab/ACES.hlsl`, maintained by MJP and David Neubelt; undated source file, `master` version inspected September 4, 2026. [Upstream source and attribution](https://github.com/TheRealMJP/BakingLab/blob/master/BakingLab/ACES.hlsl).

**Used in:** `tonemap` and the matching CPU display conversion in [tests/GPUChecks.swift](tests/GPUChecks.swift). The existing rational-polynomial coefficients match Hill's `RRTAndODTFit`. The local code omits the upstream ACES input/output color matrices and adds a simple gamma-2.2 display conversion. Describe this as an adapted filmic fit, not a complete ACES color-management pipeline. The upstream file identifies its code as MIT-licensed; preserve applicable upstream notices when incorporating source.

### REINHARD2002 — Global display curve

Erik Reinhard, Michael Stark, Peter Shirley, and James Ferwerda. **Photographic Tone Reproduction for Digital Images.** 2002. [University of Utah technical report](https://www-old.cs.utah.edu/docs/techreports/2002/pdf/UUCS-02-001.pdf).

**Used in:** the optional `present_kernel` Reinhard mode applies the global `x/(1+x)` curve independently to RGB channels. It omits the paper's luminance normalization, automatic key, white-point extension, and local operator. Exposure (`2^EV`), the simple reciprocal red/blue white-balance gains, linear clipping, and the split raw/MetalFX presentation are local display controls. White balance is an artistic cool/warm adjustment, not calibrated Kelvin chromatic adaptation. Display controls leave HDR samples unchanged.

### OBJ2026 — OBJ format reference

Wavefront Technologies. **Object Files (.obj), Advanced Visualizer Appendix B1**, documented via the Library of Congress's [Wavefront OBJ format description](https://www.loc.gov/preservation/digital/formats/fdd/fdd000507.shtml) (updated February 18, 2025; reviewed September 4, 2026).

**Used in:** `OBJMesh.parts`/`load`, `MeshTriangle`, `SceneGraph.addOBJ`, and the mesh Studio import UI. The parser is local Swift code, with `v`/`vt`/`vn`/`f`, relative indices, missing-attribute defaults, and convex face triangulation. It preserves `o`/`g` hierarchy and named `usemtl` face subsets with editable bindings; it does not parse MTL shading, freeform surfaces, animation, or vertex colors. The imported data is embedded in `ProjectDocument`; no external loader library or mesh dataset is bundled. The original specification mirrors linked by the Library of Congress were unavailable to this session; the accessible institutional format description was verified. Synthetic test fixtures are locally generated.

### MATERIALX — Bounded material graph interchange

Academy Software Foundation, MaterialX project contributors. **MaterialX 1.39.5**, reviewed September 4, 2026. [Specification](https://materialx.org/Specification.html), [pinned standard node definitions](https://github.com/AcademySoftwareFoundation/MaterialX/blob/v1.39.5/libraries/stdlib/stdlib_defs.mtlx), [OpenPBR 1.1.1 surface definition](https://github.com/AcademySoftwareFoundation/MaterialX/blob/v1.39.5/libraries/bxdf/open_pbr_surface.mtlx), and [normal-map reference](https://github.com/AcademySoftwareFoundation/MaterialX/blob/v1.39.5/libraries/stdlib/genglsl/mx_normalmap.glsl).

**Used in:** `MaterialXImporter`, `MXCompiler`, `MaterialXProgram`, `MaterialLibrary.prepareMaterialX`, `resolve_materialx`, `prepare_openpbr`, and the material inspector. The local XML compiler reads self-contained 1.38/1.39 documents, resolves standard-node connections/nodegraph interfaces, and emits a bounded expression program for the existing Metal path tracer. OpenPBR surface input names/defaults follow the pinned definition. Supported expressions cover constants, UV0, local images, component-wise multiply/add/subtract, mix, clamp, scalar extract, tangent-space normalmap, constant-angle rotate2d (degrees converted to radians), and limited numeric conversions. This is independent Swift/Metal integration, **not** the MaterialX SDK, ShaderGen, a full MaterialX implementation, or a new rendering engine. Unsupported surface models, custom nodes, XInclude, color spaces, and surface features are rejected with an import report.

**Adaptations:** programs evaluate at surface resolution in existing primary/secondary/guide paths. Image UVs bridge MaterialX's bottom-left convention and the renderer's top-left storage; normal maps account for the corresponding bitangent sign and retain local hemisphere guards. Images use `METALTEXTURES` with explicit sRGB or linear decoding, periodic bilinear/mip-linear filtering, and approximate ray-cone LOD. The exposed OpenPBR mapping clamps roughness to 0.03–1 and IOR to 1.01–2.5; weights and colors use 0–1. It does not reproduce every MaterialX closure or unrestricted HDR shader parameter. Programs and image bytes are embedded in project/material files; editing constants rebuilds instruction buffers and reuses unchanged images. Synthetic tests are locally authored; no upstream test assets or MaterialX source files are bundled.

**Scene bridge:** `SceneGraph`, `MeshAsset`, `SceneNode`, and `SceneMaterial` use local stable IDs, parent transforms, shared mesh assets and face-subset bindings. `SceneGraph.worldTransform`/`renderTriangles` compose local transforms and transform normals with the inverse transpose; see `PBRT2023` [transformation background](https://pbr-book.org/4ed/Geometry_and_Transformations/Transformations). The GPU bridge currently flattens visible instances into a rebuilt median-split BVH. USD composition now occurs upstream in `OPENUSD`; this GPU representation remains a flattened BVH, not a two-level accelerator or native hardware instancing.

### OPENUSD — Implemented SDK scene import

OpenUSD contributors / Pixar Animation Studios. **OpenUSD 26.08**, official `usd-core` 26.8 binary distribution, verified September 4, 2026. [Official release package](https://pypi.org/project/usd-core/26.8/), [framework introduction](https://openusd.org/release/intro.html), [UsdGeomMesh](https://openusd.org/release/api/class_usd_geom_mesh.html), [UsdGeomXformCache](https://openusd.org/release/api/class_usd_geom_xform_cache.html), and [UsdShadeMaterialBindingAPI](https://openusd.org/release/api/class_usd_shade_material_binding_a_p_i.html).

**Used in:** `scripts/prepare_usd.py`, `scripts/usd_bridge.py::import_stage`, `USDImporter.load`, `USDImportJob`, `StudioController.importUSD`, `SceneNode.matrix`, and `SceneGraph.renderTriangles`. The SDK opens USDA/USDC/USDZ, composes layers/references/payloads/selected variants and resolves package assets. The local helper snapshots polygon geometry, indexed primvars, bound material subsets, instances, hierarchy, visibility, transforms, and perspective cameras. It converts stage units to meters and Z-up to Y-up. Ear clipping is local code; USD does not perform our polygon tessellation. Gf row-vector matrices become Swift column-vector matrices; normals use inverse transpose, with winding/UV corner swaps for negative determinants. The renderer flattens shared assets for its existing BVH. SDK license and exact wheel SHA-256 are retained in `Vendor/OpenUSD` and the bundle.

**Limits:** selected-time snapshots, no USD export or live stage editing. Subdivision uses control cages; skinning, point instancers, curves and volumes are unsupported. Orbit cameras omit roll/shift and use the imported vertical FOV. No Hydra renderer is embedded. The wheel does not include the optional MaterialX Sdf plugin; external `.mtlx` references produce SDK composition warnings retained in the report. Supported direct UsdShade graphs use the local translator. See [official MaterialX architecture guide](https://openusd.org/release/api/_page__material_x__in__hydra__u_s_d.html).

### USDPREVIEW — PreviewSurface and UsdLux adaptation

OpenUSD contributors. **UsdPreviewSurface Specification** and **UsdLuxRectLight**, 26.08 documentation, verified September 4, 2026. [Shading specification](https://openusd.org/release/spec_usdpreviewsurface.html), [rectangular lights](https://openusd.org/release/api/class_usd_lux_rect_light.html).

**Used in:** `MaterialTranslator.material`/`node` translate metallic-workflow PreviewSurface color, roughness, metalness, IOR, coat and normal inputs, UsdUVTexture channels/scale/bias, st readers and Transform2d into bounded `MATERIALX` programs. PreviewSurface shading is approximated by the existing OpenPBR BSDF; their lobes are not numerically identical. Unsupported opacity/emission/displacement and specular workflow fall back with diagnostics. Textures are linear or sRGB; no OCIO/ACES pipeline is implemented.

`import_stage` converts rectangular lights into one-sided triangle emitters. `SceneState.emissions`, `MaterialLibrary.rebuildArguments`, `trace_scene`, `sample_direct_light`, `eval_light_pdf`, `imported_geometry` and ReSTIR target evaluation integrate them into the existing tracer. Radiance maps from color × intensity × 2^exposure, divided by transformed area in square meters for normalized lights. Uniform triangle-area sampling is mixed 50/50 with the environment proposal; `PBRT2023` supplies the area-to-solid-angle Jacobian background. The implementation is local code, not a copied USD renderer. Light textures, temperature, shaping, linking and filters are not evaluated. Dome transform/tint and distant angular size/tint are omitted and reported. Finite-light and environment sampled/evaluated PDFs are GPU-tested. Existing fixed ray offsets can affect millimeter-scale geometry; no cross-engine radiometric equivalence is claimed.

## Apple platform integration

### OIDN250 — Offline final-frame denoising

Intel Corporation. **Intel Open Image Denoise 2.5.0**, 2026. [Official source and API documentation](https://github.com/RenderKit/oidn), [official release](https://github.com/RenderKit/oidn/releases/tag/v2.5.0).

**Used in:** `scripts/prepare_oidn.py`, `OIDNDenoiser`, `OIDNProgress`, `OIDNOptions`, `StudioController.beginOfflineDenoise`, `StudioController.startOIDNPreview`, `PathTracerRenderer.offlineDenoisedPreview`, and the export/settings controls. The checksum-pinned official macOS runtime is bundled without modification and loaded through OIDN's C99 ABI for final-frame processing. The local adapter copies the converged `rgba32Float` accumulation and configured primary-surface guides to an `RT` filter as `FLOAT3`, sets `hdr=true`, and writes the returned linear radiance into a new Metal texture. Fast, balanced, and high OIDN quality levels; color/albedo/normal guide selection; and the `cleanAux` noisy-guide hint are exposed. The texture can be displayed and captured in the viewport or passed to PNG/OpenEXR export. PNG display mapping occurs afterward; OpenEXR retains linear denoised values. Raw and MetalFX sources remain available.

**Adaptations and limits:** albedo and world-normal guides now use the same progressive jittered box reconstruction as beauty, avoiding a final-sample/accumulated-color mismatch. Default `cleanAux=false` tells OIDN that residual low-sample edge noise may remain. A robust sampled 99th-percentile luminance supplies `inputScale`. Before filtering, an optional local test suppresses an isolated radiance outlier only when at least four neighboring pixels agree on diffuse material, normal, and albedo; this prevents a Monte Carlo firefly from becoming a broad false highlight and never changes raw accumulation. Both protections can be disabled in Settings. Reflected and transmitted geometry remains in radiance rather than the primary guides. Non-finite inputs become zero, radiance is nonnegative, albedo is clamped to 0–1, and normals are normalized. Cancellation uses OIDN's progress monitor. Output size receives a conservative host-memory preflight. OIDN's trained weights, device execution, and reconstruction are upstream behavior; the project does not implement or claim authorship of them. Exact archives, licenses, and dependency notices are recorded in `Vendor/OIDN/UPSTREAM.md` and the bundled `OIDN/doc` directory.

### METALFXAPI — Native temporal denoising API

Apple Inc. **MTLFXTemporalDenoisedScaler.** *Apple Developer Documentation*, living API documentation. [API reference](https://developer.apple.com/documentation/metalfx/mtlfxtemporaldenoisedscaler).

**Used in:** `MetalFXDenoiser` and `PathTracerRenderer.encodePresentation`. The project supplies current noisy HDR color, depth, motion, material guides, reflection distance, and a denoise mask to Apple's native denoiser at equal input/output resolution. Preview scale now selects that internal resolution; `present_kernel` scales the result to the viewport. A separate export renderer uses the requested image dimensions. Denoiser internals and model training are Apple's implementation; this project does not implement or claim authorship of them. SDK availability and device support checks govern activation.

### METALFX2026 — Neural-rendering integration guidance

Apple Inc. **Build real-time neural rendering pipelines with Metal.** *WWDC26*, session 359, 2026. [Session, transcript, and resources](https://developer.apple.com/videos/play/wwdc2026/359/).

**Used in:** integration guidance for temporal denoising and auxiliary inputs in `metalfx_guides_kernel` and `encodePresentation`. Ideal reflected/refracted material tracing, native-resolution operation, and the history-reset policy are this project's integration choices. For SDK-dependent texture semantics, use the installed SDK declarations and GPU validation alongside the talk; do not infer undocumented denoiser internals from the presentation.

### METALBLIT — Texture readback

Apple Inc. **MTLBlitCommandEncoder.** *Apple Developer Documentation*, living API documentation. [API reference](https://developer.apple.com/documentation/metal/mtlblitcommandencoder).

**Used in:** texture-to-buffer copies for PNG capture and GPU test readback. Row padding, completion/error handling, and image encoding are local application code.

### METALTEXTURES — Image loading and mipmaps

Apple Inc. **MTKTextureLoader.** Living API documentation. [API reference](https://developer.apple.com/documentation/metalkit/mtktextureloader).

**Used in:** `MaterialLibrary.load` for image decoding, sRGB color textures, linear data maps, and mip generation. `sample_material_map` uses Metal repeat/linear/mip-linear sampling with an explicit approximate ray-cone footprint. That footprint, analytic UVs/tangent frames, and the normal-map hemisphere guards are local implementations. This is not OpenImageIO integration, UDIM support, displacement, or anisotropic footprint filtering. Clear/failed-load behavior and texture resource lifetime are managed by the host.

### COREIMAGE2026 — HDR image import and PNG/OpenEXR encoding

Apple Inc. **CIImage / CIContext.** Living API documentation. [CIContext](https://developer.apple.com/documentation/coreimage/cicontext), [OpenEXR writer](https://developer.apple.com/documentation/coreimage/cicontext/writeopenexrrepresentation(of:to:options:)). Also verified against the installed macOS SDK's `CIContext.h`.

**Used in:** `MaterialLibrary.setEnvironment` converts image pixels to linear extended sRGB and clamps negative color-conversion results before storing radiance. `RenderImage.write` encodes floating-point OpenEXR from linear HDR, or PNG from the display texture tagged sRGB. An image flip preserves the renderer's top-left orientation; GPU/decoder round-trip tests verify this and HDR values above one. Atomic file replacement, `.vtrace`/`.vmat` JSON with embedded binary assets, project validation, autosave, and undo snapshots are local application code. This image import/export path uses Apple frameworks; the separate OpenUSD runtime is documented under `OPENUSD`.

### METALMATH — Shader arithmetic optimization

Apple Inc. **MTLMathMode.relaxed.** Living API documentation. [API reference](https://developer.apple.com/documentation/metal/mtlmathmode/relaxed).

**Used in:** `shaderCompileOptions`. The installed SDK describes relaxed mode as allowing aggressive floating-point optimizations while preserving infinities and NaNs. This retains the renderer's non-finite path guards. It replaces safe mode after GPU regression checks of energy, intersections, BSDF/PDF consistency, and MetalFX. Floating-point reassociation and changed random draw assignment can change individual Monte Carlo samples; bit-identical renders are not expected. The offline energy-table baker retains safe math.

## Scene inspiration and related work

### CORNELLBOX — Scene inspiration

Cornell University Program of Computer Graphics. **Cornell Box Comparison.** Online reference scene and comparison resource. [Institutional source](https://www.graphics.cornell.edu/online/box/compare).

**Relationship:** scene 1 uses the Cornell-box test-scene concept. Local dimensions, RGB materials, lights, and objects are procedural choices; the project does not use Cornell's measured reflectance data or establish agreement with the physical reference box. Scene 2's inspiration is credited under `MIS1995`.

### ASWF_SHADERBALL — Downloaded reference scene

ASWF USD Working Group. **Standard Shader Ball**, repository revision `3b75c2dad6a494897557dcca0098257bcf42a8c6`. Geometry/textures: Chris Rydalch; specification/validation: André Mazzone. [Primary asset and documentation](https://github.com/usd-wg/assets/tree/3b75c2dad6a494897557dcca0098257bcf42a8c6/full_assets/StandardShaderBall). CC-BY-4.0; complete LICENCE/README retained by the downloader. This reimplementation acknowledges Thomas Anagnostou's original Simball inspiration; its documentation shows Houdini Karma renders.

**Used in:** `scripts/fetch_reference_scene.py`, `Examples/OpenUSD/ShaderBall-triangulated.usda`, and optional `tests/USDChecks.swift` integration rendering. The local override selects triangulated surface geometry and the USD PreviewSurface plastic variant at frame 3. The original source is unchanged. The imported scene has 63,882 triangles including five rectangle lights; internal subdivision cages and material fallbacks remain in the import report. This is an interoperability/visual inspection reference, not a validated pixel match to Karma. Downloads, generated `.vtrace` snapshots and PNGs stay under ignored `build/reference-scenes`/`build/checks`; they are not bundled with the app.

### ORCA_BISTRO — Larger reference candidate, not imported

Amazon Lumberyard / NVIDIA ORCA. **Amazon Lumberyard Bistro**, 2017. [Primary download, license and geometry counts](https://developer.nvidia.com/orca/amazon-lumberyard-bistro), [ORCA formats and Falcor camera/light files](https://developer.nvidia.com/orca). CC-BY-4.0. The scene originates in Lumberyard and ORCA supplies assets for rendering research with Falcor setup files. Available downloads use FBX, not a ready-made native USD stage. Interior: 1,046,609 triangles; exterior: 2,832,120. These exceed our 500,000-triangle limit. No Bistro assets have been downloaded or integrated; conversion and larger-scene acceleration remain future work.

### SMS2020 — Related work; full method not implemented

Tizian Zeltner, Iliyan Georgiev, and Wenzel Jakob. **Specular Manifold Sampling for Rendering High-Frequency Caustics and Glints.** *ACM Transactions on Graphics* 39(4), 2020. [Author publication page and errata](https://rgl.epfl.ch/publications/Zeltner2020Specular). [DOI: 10.1145/3386569.3392408](https://doi.org/10.1145/3386569.3392408).

**Relationship:** explains the established method named by the legacy symbol `sample_specular_manifold_caustic`. The current **Ring boost** is an artistic approximation with a simplified Jacobian and empirical gain. It is not an implementation or validation of this paper's estimator, and its original derivation is undocumented. This citation is related-work context, not a claim that the paper's code was incorporated.

## Local methods and provenance limits

The procedural sky, fog preview, scene construction, ring-boost approximation, MetalFX guide tracing, analytic UVs, ray-cone filtering approximation, normal-map guards, dense metal-energy lookup adaptation, and finite-roughness gold-cylinder treatment include project-specific choices. No verified external derivation is recorded for the inherited sky or ring-boost formulas. Do not attribute them to a named physical sky model or published caustic solver without evidence. The removed custom denoiser is not part of the current implementation.

## Evaluated for future integration — not implemented

The following alternatives were reviewed on September 4, 2026. They remain unimplemented; OpenPBR, OBJ, bounded MaterialX, and the OpenUSD SDK integration are described in the implemented sections above.

### Alternatives reviewed — no integration yet

Reviewed September 4, 2026. The assessments below concern suitability for this Swift/Metal renderer, not universal quality rankings.

| Key | Primary source | Assessment |
| --- | --- | --- |
| CYCLES | Blender project. **Cycles**, living renderer. [Project and Apache-2.0 licensing](https://www.cycles-renderer.org/); [rendering features and Metal backend](https://www.blender.org/features/rendering/). | A production renderer with Apple Metal support. A candidate for adopting a complete rendering engine; extracting its shader system would require substantial adaptation to the current integrator. |
| MDLSDK | NVIDIA. **Material Definition Language SDK**, living SDK. [Official repository](https://github.com/NVIDIA/MDL-SDK). | Programmable material definitions, compiled BSDFs, and distilling/baking. Documented code-generation backends include PTX, LLVM IR, HLSL, GLSL, and native CPU code; no direct MSL backend is listed. A Metal integration would require additional translation or adaptation. |
| OSL | Academy Software Foundation contributors. **Open Shading Language**, living implementation. [Official GPU support history](https://github.com/AcademySoftwareFoundation/OpenShadingLanguage/blob/main/CHANGES.md). | Expressive shader programming and closures. The documented GPU implementation targets CUDA/OptiX; it is not a ready-made Metal shading runtime for this project. |
| PBRTV4 | pbrt contributors. **pbrt-v4**, living implementation of `PBRT2023`. [Official user's guide](https://pbrt.org/users-guide-v4). | Useful spectral/volume rendering reference and validation renderer. Its documented GPU backend requires CUDA and OptiX; reuse in Metal would require a port. |
| MITSUBA3 | Mitsuba contributors. **Mitsuba 3**, living research renderer. [Official project](https://mitsuba-renderer.org/). | Supports spectral/polarized and differentiable rendering variants. Its documented JIT targets use LLVM or CUDA; it is not a drop-in Metal BSDF library. |
| GLTFPBR | Khronos Group. **Physically Based Rendering in glTF**, living specification overview. [Official PBR extension overview](https://www.khronos.org/gltf/pbr). | Candidate for a smaller initial asset-import scope than OpenUSD. Standardized materials include extensions for transmission, volume, coat, anisotropy, and iridescence. Supported extensions and their mapping to OpenPBR would need explicit implementation and validation. |
| OPENIMAGEIO | OpenImageIO contributors. **OpenImageIO TextureSystem**, living documentation. [Official texture-system documentation](https://openimageio.readthedocs.io/en/stable/texturesys.html). | Candidate complement for image access and texture preparation. Its host-side cache/texture API does not replace the renderer's Metal texture bindings, sampling, or ray-footprint filtering. |

## Keeping this document current

- Update this document in the same change that introduces, replaces, or removes an externally derived algorithm, formula, dataset, or integration dependency.
- Keep citation keys stable. Record authors, title, year/version, venue where applicable, a primary-source link or DOI, affected symbols, and substantive adaptations.
- Distinguish direct implementation references, mathematical background, scene inspiration, and related work. Do not label a method as implemented merely because it was discussed.
- For copied code or assets, record the exact upstream version and preserve its required attribution/license notices. Bibliographic citation does not replace those notices.
- Verify new metadata and links against the author, publisher, or official platform documentation. Date living documentation; label unresolved provenance rather than guessing.
- Keep README references and nearby source comments linked to these keys. When a method is removed, remove its active-use claim or mark it as historical.

## September 7 audit implementation

- `PBRT2023`: `ray_epsilon`, `ray_origin`, `trace_scene` and shadow/guide origins use a local position-dependent tolerance for imported scenes and a relative triangle determinant cutoff. [Managing Rounding Error](https://pbr-book.org/4ed/Shapes/Managing_Rounding_Error) was reviewed as background. This remains a local heuristic rather than PBRT's conservative error-bound construction.
- `MATERIALX` / `ADOBEOPENPBR`: `MaterialXProgram.diffuseRoughness`, `GraphHeader.info.z`, `resolve_materialx` and `prepare_openpbr` carry `base_diffuse_roughness` into the pinned Adobe BSDF. Old programs omit the optional register and default to zero. Imported parameter defaults now persist for inspector reset. XML element, nesting, expression-depth, instruction and image limits bound the local compiler.
- `USDPREVIEW` / `OPENUSD`: translation preserves literal UVs, connected UV scale/translation and unauthored MaterialX defaults; `USDImporter.load` uses the renderer's `atan2(x,z)` azimuth convention. The ASWF audit import now imports the rough-diffuse material; active unsupported emission and external `.mtlx` composition remain explicit in its report.
- `OBJMesh.build` uses in-place index median partition instead of recursive full-triangle sorting/copying. This is local implementation code and retains a median-split BVH.
- Apple pipeline/resource lifecycle: `PathTracerRenderer` retains immutable compiled functions/pipelines for picking, restore and same-device exports. [MTLComputePipelineState](https://developer.apple.com/documentation/metal/mtlcomputepipelinestate) was reviewed September 7, 2026. Material argument updates publish complete snapshots, propagate bind failures, cache emitter membership, and release cleared image bindings. Render and decoded-asset memory receive conservative preflight limits based on the device's recommended working-set size.
- Persistence/UI lifecycle: periodic autosaves remain serialized off the main thread; application termination synchronously orders and flushes the final immutable snapshot and lets the user cancel quit after a write failure. Camera clipping/zoom scale with the scene, same-scene assignments preserve camera state, and picking rejects callbacks from an obsolete render generation.

Validation on Apple M4, September 7, 2026: `./build.sh`, the focused Studio/MaterialX/OpenUSD suite, and the complete `MTL_DEBUG_LAYER=1 python3 tests/verify.py` suite passed before the final inspector-only cleanup. Coverage includes runtime shader compilation, six scenes and four strategies, energy/furnace checks, first-bounce GI reservoir population, MetalFX history, the bundled OIDN HDR filter including the isolated-firefly regression, configurable OIDN paths, controller export, stable albedo/normal/depth/material viewport paths, project round trips, fault-injected binding rollback, area-only emitter PDFs, all imported-scene integrators, and a fresh 63,882-triangle ASWF Shader Ball import/render. The final cleanup removes the unused Whitted entry, top-aligns the inspector, and makes all inspection modes G-buffer-only; `./build.sh` passes afterward. The generated audit artifacts use new names and do not replace the September 4 preview.

### GI sampling endpoint correction — 2026-09-08

`sample_cosine_hemisphere` centers the radial draw in its 24-bit random bin before taking its square root. An exact-zero radial draw previously produced a tangent direction whose floating-point dot-product PDF could remain slightly positive. The resulting inverse-PDF GI reservoir weights reached millions and spread bright patches through reuse. This local numerical correction retains the cosine proposal; it does not clamp radiance or disable GI. `tests/GPUChecks.swift` exercises a PCG seed whose second draw is exactly zero.

## September 11 audit fixes

- `MIS1995` / `RESTIRGI2021`: `restir_gi_has_complementary_bsdf` makes the secondary direct-light MIS weight conditional on the path-depth budget actually permitting its complementary BSDF continuation. At terminal secondary vertices, the single available NEE technique receives unit weight. The existing bounded first-bounce reuse and its documented bias remain unchanged.
- Apple Image I/O and Metal resource lifecycle: `MaterialLibrary.validateEncodedImage` reads per-image pixel dimensions with `CGImageSourceCopyPropertiesAtIndex` before Metal texture decoding. Candidate accounting deduplicates shared texture objects, includes ordinary, MaterialX, and environment textures, and includes old/new overlap during replacement. Apple documents the [individual image properties](https://developer.apple.com/documentation/imageio/individual-image-properties) and describes [`recommendedMaxWorkingSetSize`](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize) as an approximate performance-safe allocation threshold; local byte estimates and safety fractions remain project policy rather than platform guarantees. Reviewed September 11, 2026.
- Frame resources: `PathTracerRenderer.FrameResourcePlan`, `renderMemoryError`, and `renderFrame` derive estimates and allocations from the active strategy. Full-resolution ReSTIR DI/GI reservoirs are allocated only for beauty-mode ReSTIR; other strategies and inspection modes bind safe 1×1 placeholders and skip reservoir access. Export preflight includes the live preview frame set.
- Scene graph bridge: `SceneGraph.renderTriangles` retains source subset identity in host-only `MeshTriangle.na.w`; `MaterialLibrary.setMeshBindings` uses it with the flattened node identity to replace material slots and emitter bindings without rebuilding unchanged BVH bounds. Shader normal interpolation continues to read only `.xyz`.
- Project/runtime lifecycle: explicit project file encoding, writing, reading, validation, and candidate material/mesh preparation run on serialized worker queues with generation/revision checks before UI publication. OpenUSD preparation validates required modules and an isolated SDK smoke import, extracts to staging, and atomically publishes a versioned runtime; OIDN cache reuse also checks its required library and documentation directory.
