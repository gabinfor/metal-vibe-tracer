# Technical audit fix plan — 2026-09-11

Status: implemented. F1–F8 have code or documentation dispositions. Final release validation passed on 2026-09-21 with Xcode 27, Swift 6.4, and an Apple M4.

## Objective and constraints

Address all findings from the September 11 quick and technical audits: resource budgeting, retained textures, low-depth GI weighting, unnecessary frame allocations, large-scene editing/persistence responsiveness, runtime preparation, contradictory audit documentation, and oversized source files. Deliver reviewable incremental changes with regression evidence.

Read `AGENTS.md` before implementing. Keep the existing Swift/Metal renderer, ReSTIR DI/GI, MetalFX, Adobe OpenPBR, OIDN, and the supported import/project workflows. Do not replace the engine, introduce a new dependency without need, expand USD/MaterialX feature scope, or implement the unrelated roadmap in the historical `AUDIT.md`. Preserve version 1/2 project compatibility and third-party notices.

Update `REFERENCES.md` in the same commits as changes to rendering methods, formulas, datasets, or platform integration. Preserve citation keys, identify affected symbols and adaptations, and verify relevant primary documentation before making new API or algorithm claims. A planned change must not be recorded as implemented. Existing tests passing does not prove an untested audit finding is fixed.

This file began as the implementation plan requested on September 11 and now records the resulting implementation and validation disposition. No separate task or subagent was created.

## Baseline and evidence

- Reviewed revision: `c1588b7cb673684f17c4eb611838498ff0e89ceb`.
- At audit time, tracked files were clean; `docs/images/` contained unrelated untracked assets. Preserve them and any subsequent user changes.
- `./build.sh` passed on the local Apple M4/macOS environment.
- `MTL_DEBUG_LAYER=1 python3 tests/verify.py` passed after running with GPU access. The sandbox-only attempt could not obtain a Metal device; that was an environment restriction, not a shader failure.
- The full suite exercised runtime shader compilation, six scenes/four strategies, energy/furnace tests, materials, MetalFX, OIDN, persistence/UI construction, USD and the 63,882-triangle reference. Expected unsupported external MaterialX-composition warnings remain.
- The passing suite does not cover cumulative candidate texture budgets, release through empty-map restore, or targeted low-depth GI energy.
- Temporary evidence: `/tmp/vibe-deeper-audit-tests.log`, `/tmp/vibe-quick-audit-build.log`, and `/tmp/vibe-technical-audit/main.swift`. These paths are ephemeral: reproduce the important evidence rather than depend on their survival.
- The isolated restore probe returned: `payloadNil=true, mask=0, retainsOldTexture=true, dimensions=16x16` after restoring an empty material state over a loaded texture.

Use symbol names below as durable locations; source line numbers will change. Reinspect the baseline if implementation begins on a different revision.

## Work packages and order

| ID | Finding | Evidence status | Priority / dependency |
| --- | --- | --- | --- |
| F1 | Batch texture preparation bypasses aggregate budgeting; decoded limits are checked after allocation | Confirmed source control flow | High; implement with F2 |
| F2 | Empty-map restore retains obsolete GPU textures | Reproduced on GPU | High; foundation for accurate accounting |
| F3 | GI terminal-vertex MIS can omit complementary energy at depth 1–2 | Source-level defect hypothesis; image impact unmeasured | High; establish focused regression first |
| F4 | All modes allocate ReSTIR reservoirs; frame budget omits realistic overlap | Confirmed allocation inventory | Medium; use F1/F2 accounting model |
| F5 | Material binding edits rebuild geometry/BVH; heavy persistence work runs on UI thread | Confirmed call paths; latency unmeasured | Medium; after resource transactions are sound |
| F6 | OpenUSD runtime cache accepts partial extraction | Confirmed source control flow | Medium; independent implementation |
| F7 | Historical audit presents contradictory current-state instructions | Confirmed documentation | Update early, finalize with actual results |
| F8 | Renderer/shaders and controller/UI are concentrated in large files | Maintainability finding | Incremental extraction after behavior fixes |

Suggested commits: baseline tests/document status; F1/F2; F3; F4; F5 geometry; F5 persistence; F6; F8 extractions; final evidence/documentation. Keep behavior changes and purely mechanical moves separate. Run focused checks during each package and one full validation at the end; repeat the full suite only when subsequent substantive changes justify it.

## F1/F2 — Texture preparation, budgeting, and release

### Entry points

- `main.swift`: `MaterialLibrary.init`, `load`, `clear`, `validateDecodedTexture`, `rebuildArguments`, `bind`.
- `Sources/StudioModel.swift`: `MaterialLibrary.restore`, `texture(data:channel:)`, `setEnvironment`.
- `Sources/MaterialX.swift`: `MaterialLibrary.prepareMaterialX`.
- `Sources/SceneGraphUI.swift`: `editGraph`, particularly material pruning.
- Tests: `MaterialChecks.swift`, `MaterialXChecks.swift`, `StudioChecks.swift`.

### Implementation

1. Build a complete candidate material resource snapshot before publication. Include ordinary maps, graph textures/program buffers, payloads, settings, emission state and bindings. Intermediate `prepareMaterialX` publication followed by a second binding rebuild should not expose or strand a partially prepared state.
2. Initialize absent maps to the existing shared defaults for their channels. Handle every slot, including the legacy eight-surface state padded to 64 slots. Never initialize an empty restored slot from an arbitrary previous texture.
3. Reuse a texture only when its payload and decoding interpretation match: channel/color-space role, origin and mip policy matter. Preserve MaterialX's existing unchanged-image reuse. Global content deduplication is optional; correct accounting and same-entry reuse are required.
4. Replace per-image checks against `images + graphTextures` with a candidate accounting object. Track all pending decoded resources, deduplicate shared `MTLTexture` instances by identity, and separately represent steady-state residency and preparation peak. Account for old resources that remain live until publication/GPU completion. Avoid counting shared default textures 256 times.
5. Inspect encoded image dimensions using a supported metadata path before invoking `MTKTextureLoader.newTexture`. Verify the relevant ImageIO/Metal documentation, including supported HDR formats. Validate dimensions and perform overflow-safe conservative estimates for decoded format and mip chains. If metadata is unavailable, use an explicit bounded fallback or actionable rejection; do not silently bypass the preflight. Keep actual postdecode `allocatedSize` checks as a second guard.
6. Include environment textures in scene accounting. `setEnvironment` currently has its own dimensions/byte limits and CPU Float32 staging; account for those allocations and avoid redundant whole-image copies where practical.
7. Expose a small internal budget override/accounting seam for tests. Test with small textures and a small budget rather than deliberately exhausting the machine. Keep production defaults tied to the device and make overflow an error.
8. Publish once all decoding, accounting and buffer creation succeeds. On failure retain the prior CPU state, argument buffer, mesh/emitter consistency and renderability. Replacing resources must not invalidate already-submitted GPU work. Remove force-unwrapped initial GPU allocations in touched initialization paths and propagate failure.
9. Inspect multi-step graph-edit rollback. It currently attempts a second allocation-heavy restore with `try?`; prefer retaining and republishing the previous immutable snapshot over reconstructing it during an allocation failure. A failed rollback must not be silently presented as a successful restoration.

### Acceptance and tests

- Reproduce the audit's loaded-map → empty-state restore. Payload and mask clear, binding resolves to the shared default, and the old texture is no longer retained by the library after outstanding GPU work and test references are released.
- Repeat via material pruning, legacy restore, channel clear, and replacing one map. Rendering/picking remain correct and serialized state matches bindings.
- Load several small images that each fit a test budget but exceed it together. Both ordinary-map restore and MaterialX preparation reject the batch without publishing partial state.
- Reused resources are counted once; identical bytes interpreted as sRGB and linear remain distinct when required.
- Oversized metadata is rejected before texture allocation. Cover malformed metadata, mip accounting, arithmetic overflow and environment limits without huge real allocations.
- Inject early and late binding failures, including after graph preparation and during material-prune/mesh edits. Assert previous resource identity/state and successful subsequent GPU rendering, not only that an exception occurred.

## F3 — Depth-aware ReSTIR GI weighting

### Entry points and suspected failure

`main.swift`: GI candidate generation in `restir_temporal_kernel`; GI contribution and ordinary path continuation in `shading_kernel`; `emission_weight`; `eval_restir_gi_target`.

The GI candidate always multiplies secondary direct lighting by `power_heuristic(lightPDF, secondaryBSDFPDF)`. The ordinary continuation supplies the complementary BSDF emitter-hit contribution at sufficient depth. With `scatteringLimit = max(1, depth - 1)`, depth 1 and 2 stop before sampling the secondary diffuse BSDF. Conventional NEE at that vertex is suppressed by `restirGISecondary`, leaving the GI light contribution downweighted without its counterpart. Conventional terminal NEE already uses weight one.

### Implementation

1. Write down the estimator partition for camera → primary diffuse → secondary diffuse → light, including what each mode samples, when MIS applies, and where the scattering budget ends. Verify against the existing `MIS1995`, `PBRT2023` and `RESTIRGI2021` primary references. Do not change the general ReSTIR bias policy to fix this boundary case.
2. Add a focused regression before changing the estimator. Use a fixture/region dominated by this indirect contribution, avoiding visible emitters that hide the error in a whole-image mean. Disable fog, ring boost and denoisers. Compare depths 1, 2, 3 and a normal production depth.
3. Make secondary GI light weighting conditional on whether a complementary secondary BSDF sample is actually available under the same depth semantics. Consider a shared depth predicate rather than duplicating subtly different arithmetic across kernels. Alternatively partition the terminal contribution explicitly; document the chosen estimator.
4. Ensure the ordinary path does not also add the same secondary NEE contribution. Preserve primary ReSTIR DI emitter-hit exclusion, delta-chain behavior, deeper diffuse paths, and glossy/transmission handling.
5. Preserve current depth-1/depth-2 compatibility unless an intentional user-facing semantic correction is justified and documented. Do not silently redefine the whole depth control while fixing MIS.
6. Reset relevant accumulation/reservoir history on depth changes as before. Update the affected reference entries and shader comments in this commit.

### Acceptance and tests

- A deterministic weighting/terminal-depth check demonstrates the old missing-complement case and passes after the fix.
- A targeted raw-radiance fixture confirms the expected correction. Use enough samples/repetitions to distinguish systematic energy loss from Monte Carlo variation; record seed/sample policy and tolerances. The existing 25% ReSTIR scene-average tolerance is not sufficient acceptance evidence.
- Test primary/secondary diffuse eligibility, emissive/sky escape, and non-diffuse paths. No double counting at depth 3 or higher; ordinary MIS/NEE behavior and delta-chain regressions remain intact.
- If reproduction disproves the hypothesis, document the complete compensating code path and numerical evidence. Do not introduce a speculative estimator change merely to mark F3 complete.

## F4 — Conditional frame resources and realistic memory preflight

### Entry points

`PathTracerRenderer.renderMemoryError`, `renderFrame`, `encodePresentation`, `presentCurrentFrame`, mode/size transitions, `MetalFXDenoiser`; `StudioController.startExport`, OIDN preparation/cancellation; GPU harness allocations in `tests/GPUChecks.swift`.

Baseline inventory: 18 RGBA32F and five RGBA16F full-resolution textures = 328 B/pixel, approximately 2.53 GiB at 3840×2160 before MetalFX and scene/output resources. DI reservoirs cost 96 B/pixel; GI reservoirs cost 112 B/pixel, totaling approximately 1.61 GiB at 4K. These are format-based sizes, not measured process peaks.

### Implementation

1. Introduce an explicit frame-resource requirements/description type. Derive both allocation and estimated bytes from it, preventing estimator/allocation drift. Distinguish beauty/guide resources, DI/GI reservoirs, MetalFX resources and export output.
2. Allocate full-resolution DI/GI reservoirs only when the active rendering path needs them. Preserve beauty accumulation and guide behavior during inspection-view transitions; do not discard history that the UI expects to resume.
3. Adapt kernel bindings and early-exit writes safely. The current temporal kernel writes zero to reservoir textures even in non-ReSTIR modes, and host code force-requires every texture. Merely substituting 1×1 textures creates out-of-bounds writes. Use guarded access, specialized kernels/function constants, or another documented strategy, with valid bindings for the compiled signature.
4. Make resize/strategy/denoiser transitions transactional. Maintain old resources until outstanding command buffers finish. A failed allocation should preserve a displayable previous frame and allow recovery at a smaller size.
5. Coordinate preflight across preview and export. Include live scene assets, existing preview frame resources, candidate export resources, resize overlap, staging/readback, and conservative MetalFX/OIDN working-space headroom. Shared resources count once; separate copies count separately. Do not claim exact accounting of opaque framework allocations.
6. Keep hard input-size validation, overflow checks and device budget separate from approximate framework headroom. Use one coherent model so independent 70%-frame and 25%-asset budgets cannot overcommit when combined with export. Report an actionable lower-resolution/scale error before expensive preparation where possible.
7. Avoid sacrificing quality or disabling ReSTIR/MetalFX to meet the target. Tiled rendering is outside this fix unless the implementation reveals a specific necessity.

### Acceptance and tests

- Allocation inventory matches descriptions for each strategy, beauty/inspection mode and MetalFX state. Non-ReSTIR rendering has no full-size reservoir allocation.
- Test MIS ↔ ReSTIR, resize up/down, paused display refresh, OIDN preview, inspection ↔ beauty and export/cancel transitions with Metal API Validation. Assert correct reset/resume behavior and no invalid texture access.
- Use a test budget to reject a candidate that fits alone but not alongside the live preview. Verify no publication or partial-state loss on rejection.
- Record before/after owned resource bytes at 1080p and 4K where the device allows. Report measured peaks separately from estimates; do not force an oversized run.
- Compare fixed-input raw output and sample progression before/after the allocation-only changes. Shader specialization must preserve the estimator.

## F5 — Large-scene edits and persistence responsiveness

### Geometry/binding work

Entry points: `SceneGraph.renderTriangles`, `OBJMesh.build`, `MaterialLibrary.setMesh`, `StudioController.editGraph`, `graphBindings`.

1. Replace the broad geometry-rebuild default with explicit edit categories: metadata, material binding/emission, and geometry/visibility/hierarchy. Validate the graph for every applicable edit even when no flattening occurs.
2. Retain enough mapping from source node/asset/subset to flattened and BVH-ordered triangles to update material slots without sorting or rebuilding unchanged bounds. The current flattened triangle stores material slot in `uvc.z` and node index in `uvc.w`; subset identity is lost, so do not assume it can be recovered from material slot when multiple subsets share a material.
3. Update the correct triangle fields and emitter membership transactionally on binding changes. Handle shared instances, node order changes, deleted nodes, hidden geometry and undo. Geometry/transform edits may continue using the existing median BVH; a new accelerator is outside scope.
4. Metadata-only rename must not rebuild geometry or unnecessarily reset lighting accumulation. Keep picking selection and stable document IDs consistent.
5. Measure binding-edit and transform-edit latency on a fixed scene. If remaining CPU flatten/BVH work blocks interaction, prepare candidates on a worker from immutable graph input, then publish on the controller's owning thread with generation checks. Coalesce superseded interactive edits rather than queueing unlimited builds.

Acceptance: material reassignment changes shading without a BVH build; metadata edits invoke neither flattening nor BVH construction; transforms/visibility still update intersections. Emissive reassignment, shared-instance bindings, undo/redo and stale-job completion all behave correctly. Instrument build counts and record latency for fixed 100k/near-limit fixtures; avoid flaky wall-clock assertions in the suite.

### Persistence work

Entry points: `openProject`, `saveProject`, `restore`, `checkpoint`/`applyUndo`, autosave methods, and `AppDelegate.applicationShouldTerminate`.

1. Capture an immutable document snapshot on the UI thread. Move file read/JSON decode/validation and explicit save encoding/writing off that thread. Also move expensive asset decoding and CPU scene preparation used by restore where supported; keep AppKit/controller publication on the owning thread. Do not access mutable renderer arrays from workers.
2. Assign operation/document revision identities. A save completion clears dirty state only if it saved the current document revision; editing while a save runs must not mark newer work saved. Save As association must not migrate to an unrelated document opened during the operation.
3. Serialize competing writes to the same destination and supersede/cancel stale loads/restores safely. Use atomic file replacement. Retain the current project until a full replacement is ready. Integrate busy state and error reporting consistently with import/export/OIDN operations.
4. Preserve ordered autosaves and the final quit flush. Reconcile pending explicit saves, loads and undo restores with termination; no deadlock from a worker that needs the main thread while the main thread waits. Define cancellation and failure behavior explicitly.
5. Measure undo snapshot retention before redesigning it: Swift value/Data sharing already avoids some copying. Bound pending jobs, and avoid eagerly duplicating assets solely to support background work. Do not introduce a new project format unless necessary.

Acceptance: edit during save; repeated Save/Save As; open during pending save; failing decode/resource preparation; undo/redo completion; immediate quit after edit; large embedded assets; cancellation/stale completion. Assert final bytes, document association, dirty state and renderability. Manually confirm the UI remains responsive during a representative large save/open; record scene/file sizes and measured timings.

## F6 — Recoverable dependency preparation

Entry points: `scripts/prepare_usd.py`, related runtime lookup in `scripts/usd_bridge.py`, `build.sh`; review OIDN cache validation for the same incomplete-install pattern.

1. Replace the `pxr/Usd/__init__.py` existence sentinel with a verified completion manifest containing version, interpreter ABI, selected archive and checksum. Validate required runtime components and a bounded isolated `pxr.Usd` smoke import before accepting the cache. Keep pinned artifacts and CPython compatibility checks.
2. Extract into a unique staging directory on the destination filesystem; validate there; write the completion marker last; publish with a recoverable directory-swap protocol. Keep the previous valid runtime until the replacement is ready. An interrupted swap must be detectable and recoverable.
3. Handle concurrent preparation safely with a lock or equivalent protocol, including rechecking state after acquiring it. Make partial downloads recoverable and validate archive hashes before extraction. Do not mutate system Python.
4. Ensure app bundling copies a complete validated runtime and does not leave mixed-version files across builds. Audit OIDN's manifest-only fast path: validate required libraries so a missing library cannot be accepted merely because its manifest survived.

Acceptance: fresh preparation, cached rerun, wrong manifest/version, missing library, corrupted archive, interruption during extraction/publication and concurrent callers. Use temporary destinations and small fixture archives where possible; retain one real pinned-runtime smoke test. Valid cached builds remain usable offline. Failure gives a clear recovery message and does not destroy the previous valid installation.

## F7/F8 — Documentation and incremental source separation

### Documentation

- Rewrite the top of `AUDIT.md` to unambiguously identify the old report as historical. Remove or quarantine obsolete imperative instructions about untracked files, untested drafts and missing shutdown flushing. Preserve useful history with dates rather than erasing it.
- Add a current finding/status table linking this plan, implementation commits and actual validation. Keep open issues open until acceptance evidence exists.
- Correct overly broad reference claims about cleared-resource release and conservative memory preflight as fixes land. Preserve stable keys and historical dates; update the overall review date only to reflect work actually reviewed.
- Keep README/user guide behavior and limits aligned with final depth/memory/persistence semantics. Do not claim new USD features, unbiased ReSTIR, full color management, or distribution readiness.

### Source separation

- After behavior fixes, extract coherent units from `main.swift`: shader loading/source, shared Swift GPU types, material resources, frame resources/renderer, viewport and application entry. Use existing `Sources/` and `Shaders/` conventions. These are proposed boundaries, not required exact filenames.
- Move the embedded renderer shader into a maintained shader resource if practical, preserving composition with generated OpenPBR/MetalEnergy source, runtime compilation, error diagnostics and bundled/development lookup. Update `build.sh` resource packaging and attribution accordingly.
- Separate persistence/operation coordination from `StudioUI.swift` presentation code. Avoid unnecessary public mutable state merely to make extensions compile.
- Update `tests/verify.py` and `tests/benchmark.py` as needed. The current verifier splits production/test files using exact source strings; moving code without replacing this discovery scheme can silently omit definitions or tests. Prefer explicit production source lists/entry-point boundaries and reusable harness helpers. Continue executing production kernels, not a copied implementation.
- Keep extraction commits mechanical. Validate source/resource discovery from both repository and built app, with no dependence on the launch working directory for bundled execution.

Acceptance: no rendering/schema/shortcut changes attributable to refactoring; clean build and full test suite; application starts from a different working directory; runtime shaders and notices are present in the bundle; references point to current symbols/files. No arbitrary line-count target is required.

## Final verification and handoff

## Implementation result — September 11, 2026

- **F1/F2:** Encoded image dimensions are checked before decode; candidate scene textures are deduplicated and budgeted cumulatively, including old/new replacement overlap. Empty map restore publishes channel defaults and releases obsolete texture references. Argument encoder state is restored on transactional failures.
- **F3:** Terminal ReSTIR GI secondary vertices use unit NEE weight when the configured path-depth budget does not permit a complementary BSDF continuation. A deterministic helper regression covers the endpoint decision.
- **F4:** ReSTIR DI/GI reservoirs are full resolution only for beauty-mode ReSTIR. Other strategies and inspection modes use 1×1 placeholders and skip reservoir access. Render preflight includes live-frame overlap, MetalFX, scene textures, and headroom.
- **F5:** Material-only graph edits rebind flattened triangle slots using retained subset/node metadata without rebuilding BVH geometry. Project open/save preparation and I/O run on a serial worker queue with generation/revision guards; final autosave remains ordered and synchronous at quit.
- **F6:** OpenUSD preparation now uses locked, versioned staging, manifest-last publication, safe archive paths, isolated smoke import, and complete-runtime checks. OIDN cache reuse checks its library and documentation directory.
- **F7:** `AUDIT.md` is explicitly historical and points here; `REFERENCES.md` records the new ImageIO/Metal and renderer adaptations with primary documentation links.
- **F8:** `AppDelegate` was extracted into `Sources/AppDelegate.swift`, while the tightly coupled renderer/shader source remains in place to preserve runtime composition. This is an incremental maintainability boundary with no rendering behavior change.

Validation completed:

- `./build.sh` — passed, including pinned shader/OpenUSD/OIDN preparation and app bundle assembly.
- `/usr/bin/python3 tests/USDChecks.py` — passed, including runtime manifest/hash and OpenUSD/USDC/USDZ checks.
- `git diff --check` — passed.
- `MTL_DEBUG_LAYER=1 /usr/bin/python3 tests/verify.py` — passed on Apple M4 with Xcode 27 and Swift 6.4, including final MaterialX and OpenUSD checks.
- `python3 -m compileall -q scripts tests` — passed.
- `git diff --check` — passed.

Remaining distribution work is outside this renderer audit: code signing,
notarization, clean-machine installation testing, and publishing a versioned
release artifact.

Existing commands (run sequentially to avoid shared preparation races until F6 is fixed):

```sh
./build.sh
MTL_DEBUG_LAYER=1 python3 tests/verify.py --studio-only
MTL_DEBUG_LAYER=1 python3 tests/verify.py
```

Use the focused command while developing affected areas; once final build/full validation passes, do not repeat it without a reason. `--usd-only` also exists. Any new focused flags or tests must actually be wired into the harness and documented. GPU-unavailable execution is not a pass; obtain permitted GPU access or report that specific limitation.

Before completion:

- All F1–F8 entries have code/document changes plus acceptance evidence, or an explicit evidence-backed disposition for a disproven hypothesis. Do not silently defer F5/F8 because the correctness fixes are done.
- Meaningful new tests fail on the audited behavior and pass after the fixes. Keep low-budget memory and fault-injection tests bounded; do not stress the machine to exhaustion.
- Run native smoke checks for material pruning, binding changes, strategy transitions, paused/inspection views, Save/Open/Undo, quit recovery and export/OIDN cancellation.
- Capture numerical low-depth GI results and measured resource/latency data with revision, device, dimensions, scene, samples, strategy and denoiser state. Separate estimates from measurements. Preserve existing reference images; write new evidence under distinct names.
- Review `git diff` for unrelated edits and ensure the preexisting `docs/images/` assets remain intact.
- Update this plan's status table or a linked completion report with commits, commands/results, remaining limitations and any intentional behavior changes. Final response should summarize fixes, test evidence and residual risk without claiming unsupported renderer features.
