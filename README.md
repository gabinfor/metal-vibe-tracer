# Vibe Tracer

A standalone macOS AppKit and Metal path tracer with six procedural scenes, an OBJ/OpenUSD mesh studio, editable materials, four lighting strategies, and PNG/OpenEXR export. The existing renderer remains in `main.swift`; project, inspector, asset-loading, and export code lives in `Sources/`.

See [REFERENCES.md](REFERENCES.md) for citations, implementation mappings, and differences from the published methods. Update it alongside changes to externally derived methods or dependencies.

## Development direction

The current direction, confirmed September 4, 2026, is to retain and extend this Swift/Metal renderer. Adobe OpenPBR BSDFs and image texture support are now integrated into it. OBJ geometry, a bounded MaterialX graph compiler, and OpenUSD scene import are integrated. The official OpenUSD SDK supplies scene composition; rendering stays in Swift/Metal, including ReSTIR and MetalFX.

## Build and run

Requires macOS 26 or later, a Metal GPU, and Xcode 26 command-line tools. MetalFX denoising is enabled only when the GPU reports support; this integration was verified on an Apple M4. From this directory:

```sh
./build.sh
open build/VibeTracer.app
```

The build preprocesses pinned, vendored OpenPBR headers and bundles the resulting shader plus upstream license/attributions. The first build downloads a checksum-pinned 40.7 MB official OpenUSD 26.8 wheel and bundles it. Later builds use the cached runtime. OpenUSD import requires Apple’s `/usr/bin/python3` CPython 3.9 from the command-line tools; no system Python packages are installed. Metal shaders compile at runtime; the separately downloadable Metal command-line toolchain is not required.

## Inspector and navigation

Use **Inspector** to show/hide the scrollable sidebar. The window can shrink to 700×440. The inspector has six pages; selecting Materials no longer changes the scene.

- **Render:** ReSTIR/MIS/NEE/BSDF strategy, MetalFX, Pause/Resume, Restart, sample and time limits, preview scale, scattering depth, exposure, a cool/warm white-balance adjustment, filmic/Reinhard/linear-clip tone maps, and a raw/MetalFX divider. Limits of zero mean unlimited. The status bar shows completed samples, FPS, GPU milliseconds, elapsed active render time, and render dimensions.
- **Camera:** presets, numeric position/target and FOV, aperture radius, focus distance, and named saved views. Drag to orbit, Shift-drag to pan, scroll to zoom. Click a surface to select its material/object group. Aperture zero is the original pinhole camera.
- **Lighting:** sky presets, sun direction/intensity, HDRI loading/rotation/brightness, finite-light color/intensity/size, and the existing fog preview. Sky/HDRI lighting applies to Pavilion and Mesh Studio; finite-light controls apply to Cornell, Veach, and Ring scenes. Veach's four emitters share the light controls.
- **Materials & Textures:** scene-aware object/group selection, OpenPBR presets, tint, roughness, metalness, coat, anisotropy, fuzz, IOR, transmission, normal strength, UV repeat/offset/rotation, image previews, scalar-map channel selection, and portable material presets. Numeric fields and sliders include per-property reset buttons.
- **Objects:** imported hierarchy, rename/reparent, shared mesh instances, per-node visibility/transforms, deletion, OBJ append, and frame selection/all. Procedural objects retain visibility, translation, XYZ rotation, uniform scale, and transform reset. Transforms pivot around the scene origin. Architecture and Cornell room surfaces are grouped; finite emitters use Lighting controls.
- **Project & Export:** New/Open/Save/Save As, independent output dimensions, export sample count, selected-display/raw choice, PNG, HDR OpenEXR, and current-preview PNG capture.

Keyboard shortcuts: Cmd-O opens, Cmd-S saves, Cmd-Z/Shift-Cmd-Z undo/redo, Cmd-P pauses/resumes, Cmd-R restarts accumulation, and Cmd-E opens export controls. Changes to exposure, white balance, comparison, and tone mapping preserve raw accumulated samples. MetalFX operates at the internal render resolution, is available with ReSTIR on supported GPUs, and maintains its own temporal history.

## Projects and materials

Version 2 `.vtrace` projects embed texture bytes, the environment image, mesh assets, stable scene-node/material IDs, parent transforms, face bindings, MaterialX expression programs, per-scene state, camera, render controls, and saved views. Version 1 projects remain readable; their single imported mesh migrates when another OBJ is appended. They do not depend on original asset paths. Version and value validation runs before loading, and failed asset decoding preserves the active project. `.vmat` presets carry one material, including its MaterialX program/images when present, or manual maps and UV/channel settings. Undo/Redo restores project edits (up to 40 actions); render samples and pause state are not project edits.

Changes autosave after a one-second debounce and on normal quit to `~/Library/Application Support/VibeTracer/Autosave.vtrace`. Pending snapshots are serialized in order, and quit flushes the final state before termination; a failed final write offers Cancel Quit. The last autosave is restored on startup. Explicit project saves are atomic and remain separate from the recovery file.

Base-color images decode as sRGB and multiply tint. Roughness and metalness maps use linear data and replace scalar values; select R/G/B/A for packed maps. Tangent-space normals use +Y and remain linear. **Clear** restores the scalar parameter's effect. Maps use repeat wrapping, mipmaps, and an approximate ray-cone footprint, and are evaluated at primary and secondary hits. UV repeat/offset/rotation and normal strength can be edited independently.

**Original scene material** preserves its original type while allowing maps. A metalness map promotes it to OpenPBR; editing surface parameters or tint also creates a custom OpenPBR surface. Original ideal mirrors/glass retain their delta behavior; new rough surfaces have a roughness floor of 0.03. Volumetric absorption, subsurface scattering, opacity, thin films, dispersion, UDIMs, and displacement remain outside the exposed material model.

## OpenUSD scenes

In **Objects**, choose **Open USD scene…** for `.usd`, `.usda`, `.usdc`, or `.usdz`. Import opens a complete scene, including supported lighting and cameras, and replaces the current imported content. It composes references, payloads, and selected variants with the official SDK at the stage’s start time. Cancel leaves the active scene intact. The report lists fallbacks and unsupported features and remains available in Objects. Save as `.vtrace` to embed meshes, material images, matrices, lights, and the report for portable reopening; Undo restores the previous project.

Supported: polygon meshes (including concave faces), indexed UV0/normals, material face subsets, hierarchy, shared mesh assets, nonuniform/mirrored transforms, stage units/up-axis, visibility, perspective cameras as saved views, rectangular area lights, one textured dome, and one distant light. PreviewSurface’s metallic workflow and supported direct MaterialX UsdShade nodes map to the existing bounded OpenPBR evaluator. Area-light radiance is editable in Materials. Original imported matrices are retained beneath the inspector’s local transform adjustments.

This is snapshot import, not full USD round-trip editing. Subdivision uses control cages; point instancers, skinned animation, volumes/curves, arbitrary shader networks, USD export, and external `.mtlx` Sdf composition are not implemented. OCIO/ACES color management, camera roll/lens shift, and some light features are not represented. The importer reports approximations; PreviewSurface-to-OpenPBR shading is not an exact BSDF match. Existing limits remain 256 nodes, 56 imported materials and 500,000 rendered triangles. See [OpenUSD coverage and reference scenes](Examples/OpenUSD/README.md).

## MaterialX materials

A small walkthrough is included in [Examples/MaterialX](Examples/MaterialX/README.md).

In **Materials**, use **Import MaterialX…** to load a self-contained `.mtlx` document. On an imported mesh, supported materials enter the scene library and the first is assigned to the selected face subset. On a procedural surface, the first supported material replaces that slot. The import report lists rejected materials and ignored look assignments. Select a mesh child to change its subset bindings; edits to a shared material affect every assignment.

This is a bounded local importer/evaluator, not the MaterialX SDK or a visual node editor. It accepts 1.38/1.39 XML and the `open_pbr_surface` model. Supported nodes are `constant`, `texcoord` (UV0), `image`, `multiply`, `add`, `subtract`, `mix`, `clamp`, scalar `extract`, `normalmap`, `rotate2d` (constant degrees), and matching-width/scalar-broadcast `convert`. Nodegraph outputs and interface inputs resolve into the same program. Authored constants and default surface inputs are editable in the inspector; graph structure remains imported. Reset buttons restore the persisted imported default. Graph parameters use linear values.

Images use relative local paths at import, then embed their bytes. Supported color spaces are linear/lin_rec709/raw/none and srgb/srgb_texture. Images use periodic addressing and linear/mipmap filtering. UV arithmetic can tile/offset coordinates; `place2d`, additional UV sets, UDIMs, procedural noise, custom definitions, XInclude, OCIO transforms, and look assignment rules are unsupported. Missing images and unsupported connected nodes reject the affected material. Each material supports up to 64 instructions, with 128 graph images total.

Mapped OpenPBR inputs are base color/weight/metalness, specular roughness/weight/IOR/anisotropy, coat weight/roughness, fuzz weight, transmission weight, and surface normal. The renderer retains its roughness floor (0.03), IOR range (1.01–2.5), and 0–1 color/weight limits. Other authored surface inputs must be recognized default values; non-default subsurface, emission, opacity, dispersion, thin-film, and volume features are rejected. No `.mtlx` graph export is implemented. `REFERENCES.md` documents the implementation and adaptations.

## Meshes, environments, and export

**Import OBJ** reads positions, optional UVs/normals, positive and negative indices, and convex polygon faces (fan triangulation). Missing normals use face normals. A median-split CPU BVH accelerates triangle intersections inside the existing Metal tracer, including shadows, reflections, transmission, picking, and denoiser guide rays. Import opens Mesh Studio, appends assets, and frames the new import. `o` and `g` become parent/mesh nodes; `usemtl` creates face subsets with named materials. Select a mesh in Objects or click it in the viewport, then choose a subset and material in Materials. Instances share geometry and initially share materials; assignments can be changed per instance. Parent visibility is inherited, and reparenting preserves local transform values. MTL shading, curves, vertex colors, and animation are not imported. Triangulate concave polygons before import. Limits are 256 scene nodes, 56 imported materials plus eight procedural slots, and 500,000 triangles across instances. The initial GPU bridge flattens visible instances and rebuilds the BVH after edits; complex imports and embedded project files can take noticeable time.

HDRI loading accepts equirectangular HDR/EXR and supported ordinary images, converts to linear extended sRGB, and clamps negative converted channels to zero. The environment uses the existing sun-cone/cosine mixture proposals with matching PDFs, not a luminance importance map; small bright features may converge slowly.

**Render and export** uses a separate renderer at the requested dimensions and sample count, pauses the preview, and supports cancellation. PNG applies display adjustments. OpenEXR preserves HDR radiance without exposure/tone mapping (raw or MetalFX according to the source choice). Both encoders preserve top-left orientation and write atomically. Output dimensions range from 16 to 8192 per axis; large sizes depend on available GPU memory. The divider is for preview comparison and is omitted from full-resolution exports.

## Performance

Plain scene diffuse surfaces take a Lambert fast path instead of preparing all OpenPBR layers for each ReSTIR candidate. Layered direct lighting shares BSDF preparation between evaluation and PDF, reservoir work skips ineligible surfaces, and materials without maps skip footprint calculations. Shader arithmetic uses Metal's relaxed mode, which preserves NaN/Inf handling. OpenPBR presets, texture filtering, denoising, resolution, and path-depth settings are retained.

The September 4 Apple M4 paired test reduced the default Pavilion with MetalFX from 92.00 to 23.72 ms per frame at 640×480 (3.88×). A coated OpenPBR floor improved from 107.12 to 65.51 ms. See [tests/PERFORMANCE.md](tests/PERFORMANCE.md) for method, limitations, and all results.

For an interleaved before/after GPU comparison, run `python3 tests/benchmark.py /path/to/previous/main.swift` from this directory after building. The previous source must use the current 288-byte uniform layout, 256-map scene/MaterialX argument buffer, and matching shader resources. Older incompatible baselines are rejected rather than compared with incompatible buffers. This test warms both pipelines, alternates execution order, and measures GPU command-buffer time at 640×480, excluding CPU image readback. Results depend on scene, other GPU work, and temperature; they are not a native-window FPS guarantee.

## Changes

- Use Adobe's pinned OpenPBR 1.1.1 implementation for non-delta BSDF evaluation, sampling, and PDFs, including rough transmission and microfacet multiple-scattering compensation. Add a denser local metal-energy table to resolve measured grazing-angle lookup errors. Primary OpenPBR/glossy surfaces use MIS even in ReSTIR mode. Exact ideal mirror/glass paths remain compatible with the existing renderer.
- Exclude ideal mirror/glass chains from the scattering-depth budget. They terminate through energy-compensated Russian roulette instead of becoming black at a fixed bounce count. The gold cylinder uses a finite-roughness OpenPBR conductor so near-horizontal views do not compound a colored perfect-mirror tint across dozens of interior reflections. MetalFX material guides also follow longer chains.
- Use Apple’s `MTLFXTemporalDenoisedScaler` at native resolution for ReSTIR. It receives each noisy HDR frame, depth, pixel motion, world normals, diffuse/specular albedo, roughness, and reflection distance. Deterministic reflected/refracted material guides preserve information inside smooth metal and glass surfaces. A denoise mask identifies noiseless sky and emitter pixels. The custom à-trous filter has been removed. Captures follow the selected display.
- Preserve visible emitter radiance and the first glass hit's entry/exit information through the G-buffer.
- Apply complementary MIS weights to light sampling and BSDF paths; honor BSDF-only and light-only modes throughout the path. Rough glossy bounces use the same BRDF and PDF as direct lighting.
- Sample one consistent sky radiance function with a complete sun/sky mixture density. Store actual sphere-light intersections.
- Use area measure for finite-light reservoir reuse, count rejected candidates, and validate history against previous position, normal, and material. Match camera rays to reprojection matrices.
- Handle rays inside boxes and parallel to box faces; keep random values below one; bound Russian roulette probabilities and use running-average accumulation.
- Implement the fog toggle as a bounded, approximate single-scatter camera effect.
- Allocate render targets atomically, skip zero-size drawables, cap queued frames, report GPU errors, and publish sample counts after GPU completion.
- Pad capture rows, check GPU completion, prevent concurrent capture requests, write PNG files atomically, and preserve capture/save status messages.
- Report startup errors, keep controls within the minimum window size, and quit when the window closes.

## Approximation limits

The ReSTIR mode applies reservoir reuse to primary diffuse surfaces and uses MIS for glossy surfaces and later bounces. It uses practical temporal/spatial reuse with history rejection and limited history counts. It is not a fully unbiased reference implementation. Standard MIS with fog and ring boost off is the comparison mode.

The original “SMS” routine is a simplified artistic ring-caustic boost with an empirical gain, not a full specular-manifold solver. It is now labeled **Ring boost**, is off by default, and does not solve glass caustics. Glass and mirror paths still participate in ordinary path tracing. Fog is a camera-segment preview with approximate light attenuation, not a full multiple-scattering volume integrator. Scene 4's fog is controlled explicitly by the Atmosphere menu.

OpenPBR compensation is approximate. White-furnace tests check finite sets of roughness and view angles, not all possible layered configurations. Normal mapping uses hemisphere guards and geometric-normal ray offsets; it is not a full energy-preserving microgeometry transport solution. MetalFX receives unaveraged frames and maintains its own temporal history. Shared Halton jitter aligns the color and guide buffers, and motion vectors exclude that jitter. Smooth orbit/zoom resets the raw accumulation while preserving MetalFX history; scene/settings changes, presets, resize, re-enabling MetalFX, and explicit Reset invalidate denoiser history. Mirrors and glass participate in native denoising rather than being bypassed. The material guides approximate ideal reflection/transmission with bounded auxiliary paths; complex multiple reflections may still lose detail. MetalFX can soften fine details and does not converge identically to the raw progressive average. Turn it off to inspect or capture the raw render at high sample counts. Procedural primitives remain analytic; imported triangles now use the local BVH.

## Verification

```sh
python3 tests/verify.py
```

The test runner compiles the production Swift definitions, compiles the real Metal shaders on the GPU, checks box intersections and dielectric total internal reflection, renders all 24 scene/strategy combinations at a non-aligned size, checks visible-light emission and fog, and compares mean Cornell-box radiance across strategies. The suite also checks 20 white-furnace angle/roughness combinations against unit energy and independent BRDF integration, compares low-sample denoising against a high-sample reference, checks raw-buffer invariance and non-ReSTIR bypass, validates stationary/moving-camera motion and history resets, and inspects reflection hit-distance and material guides. It explicitly verifies that the native MetalFX path ran. Render comparisons are saved in `build/checks` (raw, denoised, high-sample reference, left to right). It also checks OpenPBR eval/sample/PDF consistency (including rough-glass entry and exit), real texture decoding, sRGB versus linear data, mipmaps, wrapping, failed-load preservation, mapped secondary reflections, and all four lighting strategies with OpenPBR presets. `build/checks/openpbr-textures.png` shows the original scene, mapped raw render, and MetalFX output. It requires GPU access and opens no window. The MaterialX checks cover multi-object/subset imports, shared instances, hierarchy validation, CPU graph validation, GPU arithmetic and sRGB/UV/normal evaluation, portable graph/image round trips, inspector edits, and rendering strategies. The Studio checks additionally exercise project validation and embedded assets, OBJ/BVH/visibility/transforms, thin-lens focus, light-size PDFs, PNG orientation, HDR EXR round trips, render scale/limits, inspector construction, undo/redo, and an independent export. Native file-panel interactions still require manual verification.

For API validation, run `MTL_DEBUG_LAYER=1 python3 tests/verify.py`. Physical mouse gestures and native file dialogs still require manual verification. To run the Studio and MaterialX integration coverage, use `python3 tests/verify.py --studio-only`. Inspector and export artifacts are written to `build/checks/studio/`.

The grazing-cylinder regression follows a ray through more than 40 interior reflections to the floor, verifies that the interior receives light with and without MetalFX, and compares scattering budgets of 16 and 64. `build/checks/cylinder-grazing.png` shows raw, MetalFX, and the larger-budget reference from left to right.

To regenerate the local metal-energy table (requires a Metal GPU), run `python3 scripts/generate_metal_energy.py`. Ordinary builds use the checked-in `Shaders/MetalEnergy.metal`. Vendor sources remain unmodified; generated lookup substitutions and citations are documented in `REFERENCES.md`.

OpenUSD tests exercise the real SDK process, layered references, native instances, USDC/USDZ, units/axis transforms, concave faces, primvars, cancellation, portable emission state, one-sided area lights and sampled/evaluated GPU PDF agreement. If the optional ASWF asset is downloaded, the suite imports it, saves `build/reference-scenes/StandardShaderBall-audit.vtrace` plus `import-report-audit.txt`, and renders `build/checks/openusd-audit-reference.png`.
