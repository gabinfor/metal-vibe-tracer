# Metal Vibe Tracer historical audit — September 7, 2026

Date: 2026-09-07. Requested scope: renderer correctness, performance, visuals, GUI, import/export, persistence, and features.

> This file is a historical record of the September 7 audit. Its descriptions of
> working-tree state, unfinished drafts, and commands awaiting execution are not
> current instructions. For the September 11 follow-up and its implementation
> status, see `docs/AUDIT_FIX_PLAN_2026-09-11.md`.

## Current release status

The implementation changes described in this historical audit are present in
the current release candidate. On 2026-09-21, `./build.sh`,
`/usr/bin/python3 tests/USDChecks.py`, and
`MTL_DEBUG_LAYER=1 /usr/bin/python3 tests/verify.py` passed on an Apple M4
with Xcode 27 and Swift 6.4. The full suite covered runtime shader compilation,
all scenes and strategies, energy/BRDF checks, MetalFX, OIDN, persistence, UI,
MaterialX, OpenUSD, and the ASWF Shader Ball.

This file remains historical evidence and a record of broader limitations. Use
the September 11 plan for implementation status. The app is not yet signed or
notarized for clean-machine distribution.

**Implementation update, 2026-09-07:** the shipping-priority findings and the concrete draft work in this audit were implemented and exercised with Metal API Validation. The detailed findings below are design history and a roadmap for larger interchange/color-management work.

Implemented in this pass: ordered final autosave flush and quit-failure handling; transactional material/mesh/environment publication with propagated binding failures; decoded-asset/project/MaterialX structural bounds and GPU-memory preflight; cleared-resource release; cached emitter membership; enabled-light proposal probabilities; idle presentation suppression; compiled-pipeline reuse; faster BVH construction and graph flattening; metadata-only hierarchy edits; consistent import busy guards and generation-safe picking; bounded USD helper termination; scale-aware camera zoom/clipping/framing; persistent MaterialX parameter defaults and diffuse roughness; corrected USD sun/UV/default semantics; unused material reclamation; menu, precision, framing and dirty-state fixes.

Validation: `./build.sh` passed. The focused suite and full `MTL_DEBUG_LAYER=1 python3 tests/verify.py` suite passed on Apple M4, covering runtime shader compilation, all six scenes/four strategies, energy and furnace tests, MetalFX lifecycle, transactional failure injection, persistence, AppKit inspectors, MaterialX, OpenUSD, all imported-scene integrators, and the 63,882-triangle ASWF Shader Ball. New reference artifacts are `openusd-audit-reference.png`, `StandardShaderBall-audit.vtrace`, and `import-report-audit.txt`.

Still intentionally outside this incremental renderer pass: an OCIO/ACES pipeline, exact Karma pixel matching, external MaterialX Sdf plugin composition, subdivision evaluation, skinning, point instancers, curves/volumes, a multi-million-triangle two-level accelerator, and clean-machine signed distribution. These are product-scale features rather than fixes that can be truthfully marked complete by this audit.

## Historical working-tree state at the start of that audit

The statements in this section describe an intermediate September 7 session and are retained only to explain the original audit evidence. They do not describe the current repository and must not be followed as implementation instructions.

- `build/audit-before/main.swift` and `build/audit-before/StudioModel.swift` contain copies made before this audit's edits. Other source files do not have equivalent audit snapshots.
- `build/audit-build.log` reports a successful **Swift app build** after the draft edits. The app compiles its Metal source at runtime, so this does **not** validate shader compilation, GPU output, speed, or GUI behavior.
- The requested elevated GPU regression command was rejected before execution by automatic approval review because its reviewer had hit a usage limit. There are no new audit GPU results or measured speedups.
- That rejected command also contained proposed test-file writes. They did not execute: **`tests/AuditChecks.swift` does not exist, `--audit-only` is not implemented, and the audit regression cases below still need to be written.** Do not assume those tools exist from the prior conversation.
- Existing September 4 test artifacts (`build/openusd-full-check.log`, the reference PNG/project) concern the **pre-audit implementation**. They are not evidence for the current drafts.
- No subagents were used. No implementation should be marked complete based solely on this handoff.

Preserve the Swift/Metal renderer, ReSTIR, MetalFX, stable reference keys, and upstream notices, per `AGENTS.md`. Update `REFERENCES.md` with the final implementation and actual validation outcomes.

## Draft changes recorded at that historical checkpoint

| Area | Files / symbols | Present draft |
| --- | --- | --- |
| Shader reuse | `main.swift`: `PathTracerRenderer.init(device:sharing:)`, `shaderLibrary`, `materialFunction`, `pickPipeline`; `StudioRendering.swift`: `pick`, `startExport`; `StudioUI.swift`: `restore` | Keep compiled functions/pipelines on the renderer; picking and restore reuse them; export can share pipelines on the same device. |
| Placeholder resources | `main.swift`: `MaterialLibrary.init` | Reuse three default textures across 256 map bindings instead of allocating a texture for every binding. |
| BVH build | `StudioModel.swift`: `OBJMesh.build` | In-place median partition of triangle indices, bounded selection fallback, final ordered-triangle gather; removes recursive triangle-array copies and repeated complete sorts. No speed measurement yet. |
| Mesh preparation | `SceneGraph.swift`: `renderTriangles`, `validate` | Precompute material slots per subset, use asset lookup dictionaries, reserve output capacity; require affine position/normal homogeneous components. |
| Fine geometry | `main.swift`: `ray_epsilon`, `ray_origin`, `trace_scene`, `light_visible`, path/guide origins | Imported graph scenes use a position-dependent tolerance and relative triangle determinant test. Procedural tolerance mostly remains unchanged. This is a heuristic, not a proven error-bound algorithm. |
| Materials | `MaterialX.swift`, `main.swift`: `diffuseRoughness`, `GraphHeader.info.z`, `prepare_openpbr` | Optional persisted output register for `base_diffuse_roughness`, passed into Adobe OpenPBR. Header remains 64 bytes; absent output defaults to zero. Must test old/new documents and GPU semantics. |
| USD | `USDImporter.swift`: sun mapping; `usd_bridge.py`: translator | Corrected azimuth to `atan2(x,z)`; skip unauthored/unconnected direct MaterialX inputs; preserve literal UV coordinates and connected UV scale/translation; reject connected rotation. |
| GUI | `StudioUI.swift`, `SceneGraphUI.swift`, `USDImporter.swift` | More numeric precision, Pause/Resume label, import/Save As/framing menus, frame-all button, bounded/aspect-aware framing, imported-light picking, stale pick-resource guard, import menu validation/busy flag, dirty indicator. |
| Autosave | `StudioUI.swift`: `autosaveQueue`, `autosave` | JSON encoding/writing moved to a serial background queue. **Shutdown flush is missing; see P1-01.** |

## P1 — correctness, reliability, and misleading output

### P1-01 — Final autosave can be lost at quit (introduced by draft)

**Confirmed control-flow risk.** `AppDelegate.applicationWillTerminate` invokes `studio.autosave()`. The new implementation only enqueues work on `autosaveQueue`; process termination need not wait for it. The former synchronous path did not have this particular race.

**Implement:** retain asynchronous periodic saves, but provide an ordered final flush with an appropriate termination lifecycle. Resolve pending debounce timers and prior queued writes. Avoid blocking the main queue on work that synchronously requires it. Ensure an older queued snapshot cannot overwrite the final one. Keep explicit Save's success/dirty state tied to actual disk success.

**Accept:** edit and quit immediately, then relaunch and recover the final edit; repeat with a large embedded USD project and previously queued saves. Verify failure reporting, no deadlock, and no reordered writes. This should be addressed before shipping the draft autosave change.

### P1-02 — Imported fine geometry and shadows disappear with procedural-scale tolerances

**Confirmed original code defect; draft fix unverified.** Original mesh intersections rejected `t < 0.001` meters, used absolute determinant cutoff `1e-9`, and offset spawned rays by 1 mm. Shadow endpoints tolerated 2 mm. The reference scene contains millimeter details and light/backplane separations considerably smaller than that.

**Implement/review:** validate the draft `ray_epsilon`/`ray_origin`, relative determinant test, and mesh minimum distance. Check all primary, secondary, shadow, and MetalFX guide paths use consistent geometric normals and tolerances. Prefer explicit error bounds if the heuristic fails distant/tiny geometry. Do not claim that the heuristic implements PBRT's bounded-error method.

**Accept:** a 20-micrometer triangle 0.5 mm from a ray origin is hittable; an occluder less than 1 mm away still shadows; spawned rays avoid self-hit. Test scaled copies, large translations, negative/nonuniform transforms, grazing rays, and both reflected/refracted paths. Preserve existing procedural energy/MetalFX regressions.

### P1-03 — Imported sun points in the wrong direction

**Confirmed original mapping mismatch; draft correction present.** `renderFrame` reconstructs direction as `(sin(az)*cos(el), sin(el), cos(az)*cos(el))`; `USDImporter.load` previously computed azimuth with `atan2(z,x)`.

**Implement/review:** retain consistent `atan2(x,z)` conversion. Check up-axis conversion and source light orientation together. The UI currently restricts elevation to `0...89` even though imported lights may be below the horizon; preserve such values without clamping merely on edit.

**Accept:** author non-symmetric distant-light directions (including ±X, ±Z and an oblique direction), import Y-up and Z-up stages, and compare the renderer's reconstructed vector with the SDK result. A vertical-only fixture cannot catch the azimuth bug.

### P1-04 — Resource mutations are not consistently transactional

**Confirmed source issue; failure paths need execution tests.** `MaterialLibrary.restore` assigns `emissions` and prepares graph buffers before all replacement steps succeed. `setMesh` publishes CPU/GPU mesh fields before `rebuildArguments` succeeds; `setEnvironment` likewise publishes texture/data first. `rebuildArguments` changes some resource properties before its final allocation succeeds. `bind` catches an allocation error with `assertionFailure` and returns; the caller still dispatches the kernel without knowing bindings failed.

**Implement:** build a complete candidate resource set before publication, or roll back every relevant field. Make bind/encode failures propagate so the frame is not dispatched with missing or mismatched bindings. Preserve already-encoded command resources until completion. Avoid force-unwrapped fallback-buffer allocation.

**Accept:** inject texture decode and buffer-allocation failures at each step. The previous scene, materials, argument buffer and CPU snapshot must agree afterward; no kernel dispatch occurs with invalid bindings, and the UI displays one useful error.

### P1-05 — Export and asset decoding can exceed practical memory limits

**Confirmed capacity gap; exact failure behavior unmeasured.** Project validation permits 8192×8192. The renderer's base frame textures alone total approximately 184 bytes/pixel (ten RGBA32F and three RGBA16F textures), about 11.5 GiB at that size, before MetalFX, output, imported textures, preview resources and allocation overlap. Map count limits do not bound decoded texture memory. The allowed maximum environment also has large Float32 CPU copies.

**Implement:** estimate memory before allocation using device limits and a conservative budget; provide a useful dimension/scale reduction action. Bound decoded image dimensions/bytes and aggregate scene texture cost. Avoid whole-file duplicate buffers where possible; consider tiled export separately, since temporal denoising and screen-space reuse complicate it.

**Accept:** oversized export/image requests fail recoverably before allocating a multi-GiB set; the active project remains usable. Verify representative 1080p/4K export memory and cancellation on the target M4.

### P1-06 — USD material/color interpretation can silently change the reference

**Confirmed supported-subset limitations plus translator defects.** Original `UsdUVTexture` translation ignored literal `st`, defaulting to mesh UVs; connected Transform2d scale/translation were read as literals. Direct ND shader declarations with no authored value were emitted with a guessed zero, replacing standard defaults. Drafts address these cases but have no new tests. `sourceColorSpace=auto` still guesses from the receiving value type, not image metadata. Direct MaterialX image color-space metadata is not fully carried through. The ASWF texture documentation specifies ACEScg, while the renderer has no OCIO/ACES workflow.

**Implement:** test draft connection/value fixes; preserve declared color-space intent or reject/report unsupported spaces rather than silently treating them as linear Rec.709. Define and document an accurate `auto` rule, including scalar channels from color images. Validate source output types and report unsupported shader behavior precisely.

**Accept:** constant UVs, connected scale/translation, missing authored defaults, packed channels, sRGB versus linear images, and unsupported ACEScg tags have explicit expected results. Compare representative texels numerically. Keep reference differences visible in the report.

### P1-07 — The ASWF reference is not yet a matched benchmark

**Confirmed from original import reports.** Internal subdivision uses control cages; the neutral material fell back because its emission network is unsupported; `sss_bars` fell back because diffuse roughness was unsupported; external `.mtlx` composition is unavailable in the bundled SDK. The new diffuse-roughness draft should address one fallback, but no fresh reference import/render has been validated. Cameras are reduced to orbit camera semantics; color management remains limited.

**Implement:** keep the original asset and separate override unchanged; remove avoidable fallbacks one at a time. Verify `base_diffuse_roughness` reaches the upstream BSDF and survives persistence. Do not simply ignore an active emission network. Capture a feature-parity manifest alongside every comparative image.

**Accept:** fresh import report identifies precisely what is approximated; the rough-diffuse material imports without fallback; a locked camera/light/material/color pipeline precedes any pixel/energy comparison to Karma. Existing `build/checks/openusd-reference.png` is an old preview, not evidence for draft changes.

## P2 — performance and editing reliability

### P2-01 — Shader compilation repeated during interaction

**Confirmed original behavior; draft optimization present.** Picking called `makeLibrary` and built its pipeline per click. Project restore/undo recreated the Metal library. Export recreated library and pipelines.

**Implement/review:** retain renderer-owned compiled resources and same-device sharing; verify ownership and initialization failures. Keep shader-source changes isolated for the benchmark harness, which deliberately creates old/new implementations.

**Accept:** repeated picks/restores do not invoke library compilation; export shares immutable pipelines but has independent accumulation/history/material state. Report measured interaction latency, not an assumed FPS gain.

### P2-02 — BVH rebuilding copies and sorts large arrays recursively

**Confirmed original algorithm; new median-partition draft unmeasured.** `OBJMesh.build` copied/sorted full triangles at each tree level. `SceneGraph.renderTriangles` also searched material arrays inside the triangle loop. The drafts partition integer indices and precompute subset slots.

**Implement/review:** validate leaf ranges, parent/child bounds, full triangle preservation, tie handling, recursion/stack limits and equivalent intersection results. Benchmark regular, clustered, identical-centroid and adversarial inputs. Do not infer traversal improvements from faster construction: topology quality is still median-split.

**Accept:** median timings for fixed 100k/500k-triangle inputs against `build/audit-before/StudioModel.swift`, equivalent hits versus brute force, valid bounds, and no worse GPU traversal beyond an explained tolerance. Use fixed geometry and warmup; retain benchmark conditions.

### P2-03 — Every graph edit rebuilds geometry; every binding rebuild rescans emitters

**Confirmed.** `editGraph` flattens and rebuilds a BVH for renames and material assignments as well as transforms. `rebuildArguments` scans all `orderedTriangles` to rebuild the emitter list for unrelated texture/object changes.

**Implement:** distinguish hierarchy metadata, binding, geometry/visibility, and emission changes. Reuse topology where valid; update triangle material IDs without sorting/rebuilding geometry. Cache emitter indices until geometry or emission membership changes. Make invalidation explicit rather than relying on incidental rebuilds.

**Accept:** rename does not rebuild BVH; material edits update visible shading; transforms and visibility update intersections; emitter membership/radiance edits remain correct under undo and instancing.

### P2-04 — Cleared textures remain resident; restores decode unchanged maps

**Confirmed.** `clear` removes payload/name/mask but retains the old `images` texture; `setEnvironment(nil)` retains the previous HDR texture. `restore` starts from existing images and leaves nil-map entries intact. This is largely invisible because masks disable sampling, but GPU memory remains occupied. Original initialization also allocated 256 placeholder textures; draft reduces that to three.

**Implement:** replace cleared bindings with shared defaults and release unused HDR/graph textures once in-flight work completes. Reuse matching existing decoded maps on restore, and consider deduplication by payload and color-space role. Ensure aliases are immutable.

**Accept:** load/clear large textures repeatedly and observe memory return toward baseline after completion; undo restores bytes/appearance; editing one slot never mutates another shared default.

### P2-05 — Light sampling wastes most environment proposals when the sun is disabled

**Confirmed sampling strategy; no bias claim.** Scene 0/6 environment proposals choose the sun cone 60% of the time even if sun intensity is zero. Imported area-lit scenes still reserve half of proposals for environment even when it is entirely black. Emitters are chosen uniformly by triangle count regardless of area/power, and `eval_light_pdf` loops over all emitters on a BSDF light hit.

**Implement:** derive proposal probabilities from enabled lights and measurable power/area; consider an alias table/CDF and a direct triangle-to-emitter PDF lookup. Update sampling and PDF evaluation together, including ReSTIR's area-measure target and temporal history reset.

**Accept:** sampled/evaluated PDFs agree; MIS/NEE/BSDF energy agrees within statistical uncertainty; variance and GPU time improve on area-only, HDR-only, mixed and zero-light cases. Do not optimize this by dropping valid PDFs or double-counting emission.

### P2-06 — Paused rendering still submits display work continuously

**Confirmed.** `draw(in:)` obtains a drawable and encodes display work on every MTKView tick while paused/completed. Presentation work does not use the tracing in-flight semaphore. `presentCurrentFrame` may run MetalFX again when presentation refresh is requested, so display refresh and temporal input advancement need clear separation.

**Implement:** use event-driven redraw while idle and keep display-only changes separate from new denoiser inputs. Request redraw for resize/exposure/compare/capture. Ensure pause behavior is coherent immediately after a scene edit or when textures are absent.

**Accept:** near-idle GPU utilization while paused/completed; exposure and compare changes repaint; no extra path samples; no repeated temporal accumulation of the same noisy frame.

### P2-07 — Main-thread import/restore/edit work can stall the GUI

**Confirmed paths; latency unmeasured.** USD composition is background work, but final decode/material resource preparation, graph flattening and BVH upload occur synchronously on restore. OBJ parsing, project open/save, undo and many graph edits run on the main thread. Large JSON projects and 40 undo snapshots amplify cost.

**Implement:** profile each stage; move CPU work to cancellable jobs using immutable snapshots and publish atomically on the UI thread. Reuse unchanged resources rather than rebuilding entire scenes for camera-only undo. Put explicit bounds on undo memory, not only action count.

**Accept:** UI remains responsive on the downloaded reference and near-limit scenes; cancellation/failure leaves the previous project intact; stale job results cannot replace newer user work.

### P2-08 — Import busy guards and stale picking are only partly covered

**Confirmed gaps.** The new `isBusy`/menu validation blocks several actions during USD import, but `StudioRendering` export entry points and `SceneGraphUI` mutations still use export-only checks. Modal UI should not be the only protection. A pick result is now rejected if resources/scene changed, but camera/transform changes on the same resources can still make the result stale.

**Implement:** centralize operation state/guarding across mutations and capture a generation or immutable picking snapshot. Report cancellation distinctly. Ensure timeout really bounds process termination; current `terminate` followed by an unconditional `waitUntilExit` assumes the helper exits promptly.

**Accept:** import plus undo/export/second import/camera edits cannot apply conflicting state; old pick callbacks are ignored after relevant scene/camera changes; cancellation reliably restores pause state.

### P2-09 — Camera framing and interaction need consistent scale and clip semantics

**Confirmed original issues; partial draft fixes.** Framing originally lacked a distance cap and narrow-viewport adjustment. Scene assignment always invokes a preset, even when assigning the same index (the test helper previously reset an imported camera). Wheel zoom uses a fixed 0.04-unit step, too coarse for centimeter-scale USD scenes. Projection/MetalFX depth use fixed near=0.05/far=100 despite much wider supported camera/scene extents. Imported zero focus distance becomes a 0.05-unit orbit pivot.

**Implement:** validate draft frame-all/selection behavior, adopt scene-relative or multiplicative zoom, preserve current camera on same-scene assignment, and use consistent near/far parameters across render and denoiser guides. Distinguish camera orbit pivot from optical focus.

**Accept:** frame visible selection/all at portrait/landscape sizes; tiny and large scenes remain navigable; persisted camera stays valid; switching/restoring/tests do not accidentally apply presets; depth/motion guides agree with the camera projection.

### P2-10 — Input parsing and project validation need structural/memory bounds

**Confirmed missing bounds, not a demonstrated exploit.** MaterialX's 16 MB XML byte cap does not bound element depth/count; recursive descendant traversal and graph resolution can exhaust stack. Project JSON is loaded whole with embedded data before structural validation. Geometry asset storage, unused assets, camera target magnitude and aggregate image bytes are not uniformly bounded. A fallback `displayColor` keyed only by failed material path can incorrectly share the first prim's display color among different prims.

**Implement:** add parser structural limits and aggregate asset budgets; validate before expensive GPU allocation; retain accurate fallback identity and reason. Reject malformed topology/primvars with a prim path, not a generic exception. Keep format validation separate from resource allocation failure handling.

**Accept:** deeply nested graphs, huge embedded assets, malformed primvars and distinct fallback colors fail or load predictably without crashing or changing the active scene.

## P3 — GUI and feature improvements

| ID | Finding / opportunity | Suggested implementation and acceptance |
| --- | --- | --- |
| P3-01 | Numeric fields originally displayed only 3–4 significant digits. | Review the 8-digit draft and test end-edit without unintended value changes. Separate broad numeric entry limits from useful slider ranges; support imported negative sun elevation and large translations without truncation. |
| P3-02 | Imported emitters were excluded by `pick_kernel`, though their radiance editor exists. | Validate draft pickability for front/back faces and correct scene node. Add light-specific names/icons and a direct Lighting-panel link; source USD often names every emitter `light`. |
| P3-03 | Hierarchy is a large popup with indented names. | Add a searchable outline with expansion, selection, visibility and material summary. Preserve selection/scroll position while editing. Avoid a complete inspector rebuild that loses focus for every operation. |
| P3-04 | Material slots are never reclaimed when deleting geometry. | Provide delete-unused-materials and explicit material deletion/reassignment, releasing image/emission state. Repeated import/delete should not permanently exhaust 56 slots; retain shared materials still in use. |
| P3-05 | Material reset uses the value present when the inspector was opened, not a stable original/default. | Store meaningful parameter metadata/defaults and units. Distinguish reset-to-imported from reset-to-standard; constrain physical sliders without hiding valid data. |
| P3-06 | Project association and dirty state need explicit lifecycle handling. | Draft dirty indicator is set by generic `changed`, including click-only camera callbacks. Clear it appropriately after successful open/save; show document name/path; preserve intended association during undo/new/import. Review recovery UX and save-on-quit semantics without adding unnecessary confirmation prompts. |
| P3-07 | Toolbar/menus lack several direct commands and busy-state feedback. | Validate draft Save As, OBJ/USD import, Frame Selection/All, dynamic Undo/Redo labels and Pause label. Keep menu/toolbar availability consistent. Add visible import stage/progress and actionable error summaries. |
| P3-08 | USD frame/variant/camera controls are inaccessible at import. | Add a small import-options UI for chosen camera, authored time and variants, with useful defaults and a concise capability report. Persist provenance separately from the flattened snapshot. |
| P3-09 | Missing color-management workflow prevents fair visual comparisons. | Add an explicit working/display color pipeline and tagged image conversion before cosmetic tone-map changes. Compare raw linear exports first, then matched display transforms. |
| P3-10 | Large-scene acceleration and interchange remain limited. | After correctness, consider two-level instancing, binned SAH or Metal acceleration structures while preserving the renderer. Bistro's interior exceeds the current 500k triangles and needs FBX→USD conversion; raising the cap alone is insufficient. |
| P3-11 | USD subdivision, skinning, point instancers, supported material models and external MaterialX are incomplete. | Prioritize features demanded by chosen reference assets. Detect/report skinned meshes specifically rather than silently rendering their undeformed points. Keep full USD export/layer editing as a separate scope. |
| P3-12 | Packaging relies on Apple CPython 3.9 and an in-place extracted runtime. | Verify runtime ABI/version and add actionable startup diagnostics. Prepare SDK/bundle atomically so interrupted extraction/build cannot look complete based on one `__init__.py`. Test clean-machine distribution, signing, document types and double-click opening before calling the app standalone for end users. |

## Suggested implementation order

1. Inventory the current draft and fix its shutdown-save risk (P1-01); do not treat the audit modifications as a validated base.
2. Add focused regression cases for sun orientation, tiny geometry/shadows, transactional resource failure, MaterialX diffuse roughness/defaults/UVs, persistence, emitter picking and import state guards.
3. Run existing production shader/MetalFX/Studio/MaterialX/USD coverage. Repair failures before performance work.
4. Benchmark the draft shader reuse/BVH changes; then optimize invalidation and resource retention (P2-01 through P2-04).
5. Address memory budgeting and responsive import/undo/export.
6. Improve enabled-light sampling with numerical energy/PDF checks.
7. Refresh the ASWF reference with a recorded feature-parity report; then implement the prioritized GUI/interchange features.

## Verification plan for the next model

Existing commands (not executed after the current audit drafts):

```sh
./build.sh
MTL_DEBUG_LAYER=1 python3 tests/verify.py --studio-only
MTL_DEBUG_LAYER=1 python3 tests/verify.py
```

`--usd-only` exists. **`--audit-only` does not.** Add focused audit coverage deliberately, without duplicating production implementations in assertions. If creating an original-builder comparison, extract the saved baseline into a test-only benchmark namespace and use the same geometry/process/compiler settings for both.

Important cases:

- Triangle BVH integrity and brute-force hit parity; degenerate/identical-centroid/near-capacity inputs; timings across multiple repetitions.
- Microgeometry: original absolute determinant and 1 mm minimum-distance thresholds should demonstrably fail the new fixture; corrected code should hit/shadow reliably.
- Rotated Y-up/Z-up USD distant lights; independently reconstruct the renderer direction.
- Literal `st`, connected UV transformations, unsupported spaces, unauthored shader defaults, diffuse roughness GPU value and BRDF effect; old graph programs without the new optional register.
- Shared pipeline identity on one device and independent export history; default-texture count on a **fresh** material library, not one already populated by prior tests.
- Late resource allocation/decode failure rollback and stopped dispatch; large-memory preflight.
- Imported emitter click selection, stale callbacks, Frame All/Selection, precision preservation, busy menus, keyboard editing, narrow-window layout and inspector scroll/focus.
- Immediate quit after edit with large autosave; final bytes and ordering verified after relaunch.
- Existing MIS/NEE/BSDF energy checks and MetalFX history/raw invariance must still pass. New faster construction is not proof of better rendering.
- Save new reference images under new names. Do not overwrite/describe the September 4 image as if it came from the draft. Record renderer revision/source hashes, scene variant/time, camera, lights, working/display spaces, SPP, strategy and all fallbacks.

## Primary references reviewed

- Existing `REFERENCES.md` / `Vendor/OpenPBR/UPSTREAM.md` / `Vendor/OpenUSD/UPSTREAM.md` remain the provenance record.
- PBRT 4e, [Managing Rounding Error](https://pbr-book.org/4ed/Shapes/Managing_Rounding_Error): background for ray-origin correctness, not proof of the local tolerance heuristic.
- MaterialX [OpenPBR surface definition, v1.39.5](https://github.com/AcademySoftwareFoundation/MaterialX/blob/v1.39.5/libraries/bxdf/open_pbr_surface.mtlx): input names/defaults, including diffuse roughness.
- OpenUSD [UsdPreviewSurface specification](https://openusd.org/release/spec_usdpreviewsurface.html): UV/image/material translation contract.
- Apple [MTLComputePipelineState](https://developer.apple.com/documentation/metal/mtlcomputepipelinestate): immutable compiled pipeline resource background.

## Scope and evidence limits

The review examined the production Swift/Metal renderer, all application source areas, USD/MaterialX adapters, build/runtime preparation, persistence paths and existing tests. Findings labeled confirmed are based on identifiable source control flow or the prior documented import output. Memory, latency, energy and visual behavior of the new drafts still require measurement. There was no fresh native-app interaction audit, fuzz campaign, device matrix, clean-machine packaging test or post-draft GPU run. Do not represent this report as exhaustive proof of correctness, and do not claim unmeasured performance improvements.
