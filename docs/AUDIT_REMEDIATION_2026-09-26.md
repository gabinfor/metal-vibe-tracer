# Audit remediation — 2026-09-26

This record supersedes `AUDIT.md` (2026-09-07) and `docs/AUDIT_FIX_PLAN_2026-09-11.md` as the current status of known findings. Those files remain as history.

## Scope

- **Base:** `7a54652` ("Improve HDRI and interchange coverage", 2026-09-21).
- **Audit:** 146 findings, R-01 to R-146. By severity: 2 critical, 7 high, 39 medium, 73 low, 25 info. Critical and high findings were confirmed by hand; the others were batch-verified against the source.
- **Constraints:** `AGENTS.md` applies. The existing Swift/Metal renderer, ReSTIR DI/GI and MetalFX are kept and extended; no engine was replaced and no dependency was added. `REFERENCES.md` is updated alongside the code.
- **Work packages** (commits on the `fix-integration` branch; the hashes may change when the work lands):

| Package | Commit | Findings |
| --- | --- | --- |
| lights | `a3d6b85` | R-01 R-07 R-10 R-11 R-12 R-48 R-52 R-53 R-98 R-119 |
| geometry | `2edfcff` | R-03 R-33 R-50 R-51 R-57 R-97 R-119 R-130 (OBJ) |
| bsdf-legacy | `e1422f0` | R-05 R-06 R-22 R-49 R-54 R-55 R-93 |
| materialx | `a2103fc` | R-23–R-28 R-73 R-74 R-129 R-130 (XML) |
| integrator | `d2b8b70` | R-13 R-56 R-64 R-99 R-110 R-122 R-127 |
| gpu-memory | `046c622` | R-04 R-17–R-21 R-37 R-58–R-60 R-62 R-100 R-101 R-125 R-128 |
| presentation | `dc18290` | R-14–R-16 R-46 R-61 R-63 R-84 R-123 R-124 R-126 |
| persistence | `abff582` | R-08 R-09 R-34–R-36 R-38 R-39 R-44 R-45 R-70 R-72 R-75–R-78 |
| frontend | `d6ddc20` | R-02 R-42 R-43 R-47 R-85–R-92 R-94 R-131 R-132 |
| usd | `141ff1e` | R-29–R-32 R-65–R-69 R-71 R-95 R-113 R-137 |
| oidn-export | `b30e262` | R-40 R-41 R-79–R-83 R-106 |
| build | `ed8e709` | R-96 R-102–R-104 R-134–R-136 R-138 R-143 |
| integration | `56b2b05` `108d761` `920a494` `cf79830` | Merge fixes: the imported sun angle resets accumulation; autosave reads are bounded by the project file limit; the verify.py runner is merged; the guarded OpenUSD import is parsed; direct kernel dispatches bind the primary-surface cache |
| tests | `59c0ee9` `0eb96bb` `4f518a6` | R-105 R-107–R-109 R-111 R-112 R-114–R-118 R-139–R-141 |
| swift6 | `ddec29d` | R-133 |
| docs | 18fc005, c6971af | R-120 R-121 R-142 R-144 R-145 R-146 |
| project-format (follow-up, `main`) | `f435fd8` `88bf52f` | R-45 R-74 |
| renderer-followups (follow-up, `main`) | `a0586f2` `9f80023` `4df8853` `84db5e3` | R-101; watertight intersection; sleep-proof time limits; guide re-trace (R-57 follow-up) |

Tests named below live in `tests/`. `Fix_<package>.swift` files run inside `tests/verify.py`; `USDChecks.py`, `Fix_build.py` and `Fix_tests.py` are Python checks that `verify.py` also runs.

## Findings

Dispositions: **fixed** or **partial** (see "Remaining limitations"). No finding was closed as "not a defect". R-45, R-74, R-101 and R-136 were partial on 2026-09-26 and were fixed on 2026-09-28 (see "Follow-up, 2026-09-28").

| ID | Sev. | Finding (short) | Disposition | Note | Test |
| --- | --- | --- | --- | --- | --- |
| R-01 | crit | HDRI row-CDF search read texel (0,0) | fixed | `environment_cdf_index` selects the marginal axis explicitly | Fix_lights (chi-square) |
| R-02 | crit | Focused field re-committed stale value on rebuild | fixed | Unchanged commits ignored; safe graph-node lookup | Fix_frontend |
| R-03 | high | Imported ray epsilon scaled with \|p\| only | fixed | Per-hit error bounds (`HitRecord.error`) | Fix_geometry |
| R-04 | high | Inspection-view switch reallocated all frame textures | fixed | Only reservoirs reallocated; `reservoirHistoryReset` | Fix_gpu-memory |
| R-05 | high | Inspector normal maps used +bitangent | fixed | Shared `tangent_space_normal`, +Y up | Fix_bsdf-legacy |
| R-06 | high | Normal maps built on the flat triangle normal | fixed | Built on the interpolated shading normal | Fix_bsdf-legacy |
| R-07 | high | Imported DistantLight contributed no light | fixed | Independent sun, UsdLux irradiance; works with HDRI | Fix_lights |
| R-08 | high | Undo of Open kept the opened file's URL | fixed | Association undone with the document | Fix_persistence |
| R-09 | high | Unrestorable autosave overwritten | fixed | Moved to `Autosave-unrestorable-<date>.vtrace` | Fix_persistence |
| R-10 | med | Procedural sun disc wider than sampled cone | fixed | One size per preset (`procedural_sun_one_minus_cos`) | Fix_lights |
| R-11 | med | HDRI PDF re-derived from direction | fixed | Chosen cell's PDF (`environment_cell_pdf`) | Fix_lights |
| R-12 | med | Emitter PDF used absolute 1e-5 plane tolerance | fixed | Hit triangle index, O(1) | Fix_lights |
| R-13 | med | GI reconnection had no Jacobian bound | fixed | `restir_gi_accepts_shift`, J in [0.1, 10] | Fix_integrator |
| R-14 | med | Display-only edits did not repaint while paused | fixed | Repaint without tracing | Fix_presentation |
| R-15 | med | Paused resize discarded render, later traced | fixed | Paused render kept | Fix_presentation |
| R-16 | med | Paused refresh re-ran MetalFX, used up reset | fixed | Refresh presents the stored output | Fix_presentation |
| R-17 | med | Preflight omitted MetalFX scaler memory | fixed | Measured per device (`scalerBytesPerPixel`) | Fix_gpu-memory |
| R-18 | med | MetalFX denoiser never released | fixed | Released when unused | Fix_gpu-memory |
| R-19 | med | restore() did not budget maps + MaterialX jointly | fixed | Joint budget | Fix_gpu-memory |
| R-20 | med | Library replacement not counted against live library | fixed | Shares textures, budgets the old+new peak | Fix_gpu-memory |
| R-21 | med | Temporal miss branch wrote reservoirs out of bounds | fixed | Writes guarded outside ReSTIR | Fix_gpu-memory |
| R-22 | med | Maps on original materials used legacy literals | fixed | Promotion takes inspector-consistent scalars | Fix_bsdf-legacy |
| R-23 | med | Gray/gray+alpha images read (g,0,0) | fixed | Swizzled views | Fix_materialx |
| R-24 | med | sRGB skipped for 16-bit PNGs | fixed | CPU sRGB expansion | Fix_materialx |
| R-25 | med | rotate2d direction opposite to MaterialX 1.39 | fixed | `mx_rotate_vector2`; USD path negates | Fix_materialx |
| R-26 | med | sRGB colorspace applied to float/vector images | fixed | color3/color4 only; others reported | Fix_materialx |
| R-27 | med | Connection resolution false cycles | fixed | Node names no longer shadow inputs | Fix_materialx |
| R-28 | med | OpenPBR defaults missing subsurface/geometry inputs | fixed | Spec defaults accepted | Fix_materialx |
| R-29 | med | Unauthored focusDistance gave 0.1 mm pivot | fixed | Pivot from view ray; focus only if authored | Fix_usd, USDChecks.py |
| R-30 | med | Bridge dropped ND_image colorSpace | fixed | `Usd.ColorSpaceAPI` | USDChecks.py, Fix_usd |
| R-31 | med | Disk light power loss; sphere as square | fixed | Equal-area octagon / 80-face sphere | USDChecks.py, Fix_usd |
| R-32 | med | Degenerate n-gon aborted import | fixed | Dropped and reported | USDChecks.py, Fix_usd |
| R-33 | med | OBJ dropped sub-0.1 mm triangles | fixed | Relative degeneracy test, count reported | Fix_geometry |
| R-34 | med | Project I/O guards bypassable | fixed | Central busy guards | Fix_persistence |
| R-35 | med | Quit did not wait for explicit Save | fixed | Quit waits | Fix_persistence |
| R-36 | med | Open/New/USD replaced unsaved work silently | fixed | Save/Don't Save/Cancel + `Autosave-previous.vtrace` | Fix_persistence |
| R-37 | med | App saved projects its open path rejects | fixed | Save refuses; 512 MiB embedded, ~1.3 GiB file | Fix_gpu-memory |
| R-38 | med | Huge uvc.z crashed on open | fixed | Slot validation | Fix_persistence |
| R-39 | med | Undo of display edit discarded samples | fixed | Samples and OIDN preview kept | Fix_persistence |
| R-40 | med | Default robust input scale mis-exposed OIDN | fixed | OIDN auto scale by default | Fix_oidn-export |
| R-41 | med | OIDN preprocessing slow, firefly loop uncancellable | fixed | Parallel with cancellation points | Fix_oidn-export (cancel paths) |
| R-42 | med | Slow drags treated as clicks | fixed | 3 pt drag threshold | Fix_frontend |
| R-43 | med | Rename dialog crash during open | fixed | No force unwrap; guarded | Fix_frontend |
| R-44 | med | Undo/imports rebuilt GPU resources on main thread | fixed | Off-main preparation with reuse | Fix_persistence |
| R-45 | med | Uncoalesced full-project autosaves | fixed (2026-09-28) | Coalesced, revision skip, 5 s camera debounce; format-3 binary sidecars written once per content, unreferenced ones collected | Fix_persistence, Fix_project-format |
| R-46 | med | draw(in:) blocked on currentDrawable | fixed | In-flight check first | Fix_presentation |
| R-47 | med | Full-resolution map decode on main thread | fixed | Cached small thumbnails | Fix_frontend |
| R-48 | med | Environment-PDF test never ran | fixed | Non-uniform 64×32 fixture, chi-square | Fix_lights |
| R-49 | low | Back faces mirrored the tangent frame | fixed | One perturbed normal on both sides | Fix_bsdf-legacy |
| R-50 | low | Procedural UVs upside down | fixed | Row 0 at top (visible change) | Fix_geometry |
| R-51 | low | Absolute 1 mm t_min for primitives in graph mode | fixed | Scaled `ray_t_min` | Fix_geometry |
| R-52 | low | Sphere-light cone PDF cancellation | fixed | `sphere_cone_one_minus_cos` | Fix_lights |
| R-53 | low | Sun cone proposals below horizon | fixed | `environment_sun_probability` = 0 | Fix_lights |
| R-54 | low | Delta glass Schlick used incident cosine on exit | fixed | cos θt when exiting | Fix_bsdf-legacy |
| R-55 | low | Delta branches crossed geometric surface | fixed | Retried about the geometric normal or rejected | Fix_bsdf-legacy |
| R-56 | low | ReSTIR passes shared an RNG stream | fixed | `decorrelate_shading_seed` | Fix_integrator |
| R-57 | low | Guide rays offset along shading normal | fixed | Geometric-normal offset | Fix_geometry |
| R-58 | low | Environment CDFs/staging unbudgeted | fixed | Budgeted before allocation | Fix_gpu-memory |
| R-59 | low | 11 B/px predecode estimate not conservative | fixed | Float-aware estimate, cumulative pre-checks | Fix_gpu-memory |
| R-60 | low | Rollback republished stale buffers | fixed | Pending edits stay pending | Fix_gpu-memory |
| R-61 | low | Mode switches miscounted in-flight frames | fixed | Counted by submit mode | Fix_presentation |
| R-62 | low | setEnvironment(nil) aliased slot 0 | fixed | Dedicated placeholder | Fix_gpu-memory |
| R-63 | low | Paused scene edits left stale display for capture/pick | fixed | Last display invalidated | Fix_presentation |
| R-64 | low | Depth 1 behaved like depth 2 | fixed | "Path depth", pbrt `maxDepth` semantics | Fix_integrator |
| R-65 | low | Placeholder Mesh aborted import | fixed | Skipped and reported | USDChecks.py |
| R-66 | low | Zero-scaled Xform aborted import | fixed | Subtree hidden and reported | USDChecks.py |
| R-67 | low | Some domes and light APIs dropped silently | fixed | Constant dome imported; others reported | USDChecks.py, Fix_usd |
| R-68 | low | Bright small normalized lights failed import | fixed | Clamped to 1e8 and reported | USDChecks.py, Fix_usd |
| R-69 | low | Interface-connected varname read as `st` | fixed | Value-producing attribute resolved | USDChecks.py |
| R-70 | low | USD open kept previous association/views | fixed | Untitled, no stale views | Fix_persistence |
| R-71 | low | Fallback displayColor shared across prims | fixed | Per-prim colour key | USDChecks.py |
| R-72 | low | OBJ/MaterialX/.vmat parsed on main thread; O(n·parts) | fixed | Off-main, linear lookup, early node limit | Fix_persistence |
| R-73 | low | MaterialX files read fully before size checks | fixed | Checked first; out-of-folder reported | Fix_materialx |
| R-74 | low | Shared images re-read/uploaded per shader | fixed (2026-09-28) | Decoded and bound once; stored once per project in the format-3 asset table | Fix_materialx, Fix_project-format |
| R-75 | low | Undo checkpoints before fallible operations | fixed | No undo step on failure | Fix_persistence |
| R-76 | low | Popups/gestures mutated state during busy I/O | fixed | Guarded | Fix_persistence |
| R-77 | low | Unbound materials deleted on object removal | fixed | Kept; "Remove unused materials" | Fix_persistence |
| R-78 | low | Reset / procedural sky left partial state | fixed | Transactional, accumulation reset | Fix_persistence |
| R-79 | low | Camera live during OIDN preview | fixed | Gestures locked | Fix_oidn-export |
| R-80 | low | OIDN preflight 84 B/px too small | fixed | 132 B/px + scratch + resident frames | Fix_oidn-export |
| R-81 | low | Stale `oidnPreviewWasPaused` | fixed | Clear only with a preview; state kept | Fix_oidn-export |
| R-82 | low | OIDN preview in inspection mode used stale beauty | fixed | Requires Beauty viewport | Fix_oidn-export |
| R-83 | low | Half-float EXR clipped above 65504 | fixed | Local float32 EXR encoder | Fix_oidn-export |
| R-84 | low | 2.2 power curve tagged sRGB | fixed | Piecewise sRGB OETF | Fix_presentation |
| R-85 | low | Plain click marked document edited | fixed | Clicks select only | Fix_frontend |
| R-86 | low | Colour wells uncoalesced undo | fixed | One step per burst | Fix_frontend |
| R-87 | low | Camera fields stale, fixed limits | fixed | Refresh; ±1e6 ranges | Fix_frontend |
| R-88 | low | Scroll ignored precise/line deltas; empty undo | fixed | Line ×10; zero deltas ignored | Fix_frontend |
| R-89 | low | Page switches invisible with hidden inspector | fixed | Inspector revealed | Fix_frontend |
| R-90 | low | Comma decimals rejected | fixed | Locale parsing; revert on error | Fix_frontend |
| R-91 | low | No accessibility labels | fixed | Labels on wells/popups | Fix_frontend |
| R-92 | low | Busy/Pause labels refreshed only per frame | fixed | Refreshed on state change | Fix_frontend |
| R-93 | low | Light colour well stored sRGB as linear | fixed | sRGB↔linear conversion | Fix_bsdf-legacy |
| R-94 | low | Errors cleared themselves | fixed | Persistent error indicator | Fix_frontend |
| R-95 | low | Quit orphaned the python3 helper | fixed | Helper terminated on quit | Fix_usd |
| R-96 | low | Resources fell back to working directory | fixed | Bundle-only; tests use `VIBE_TRACER_REPOSITORY` | Fix_build.swift |
| R-97 | low | Unbounded closest-hit shadow traversal | fixed | Any-hit `scene_occluded`, near-first | Fix_geometry |
| R-98 | low | eval_light_pdf looped over emitters | fixed | O(1) via hit triangle | Fix_lights |
| R-99 | low | Primary ray traced 2–3 times per pixel | fixed | `PrimarySurface` cache | Fix_integrator |
| R-100 | low | Emitter buffer re-uploaded on every rebuild | fixed | Reused when unchanged | Fix_gpu-memory |
| R-101 | low | Imported triangles held in ≥3 copies | fixed (2026-09-28) | Graph meshes flattened into the GPU buffer and BVH-ordered in place; `SceneGraph` assets are the only host copy | Fix_gpu-memory, Fix_renderer-followups, Fix_usd-pivot |
| R-102 | low | OIDN fast path checked 1 of 5 dylibs; unlocked | fixed | File-table manifest, lock, atomic publish | Fix_build.py |
| R-103 | low | Corrupt OpenUSD wheel never discarded | fixed | Moved to `rejected/`, refetched; module list from bridge | Fix_build.py |
| R-104 | low | build.sh updated the bundle in place | fixed | Staged, checked, swapped | ./build.sh + check_bundle.py |
| R-105 | low | Motion-vector/jitter sign untested | fixed | Motion sign/scale, jitter sign, MetalFX matrices and depth checked via renderFrame; SKIP without MetalFX | Fix_tests.swift |
| R-106 | low | EXR/HDR/cancel export paths untested | fixed | EXR, sources and cancel tests | Fix_oidn-export |
| R-107 | low | Fix-plan acceptance criteria had no tests | fixed | F4 preflight beside a live render; F5 picking/editGraph/Save-during-Open/quit flush; F6 concurrent, interrupted and wrong-manifest preparation | Fix_tests.swift, Fix_tests.py |
| R-108 | low | benchmark.py accepted incompatible baselines | fixed | Baseline needs matching Uniforms layout, argument buffer and bindings, and radiance within `--output-tolerance` | benchmark.py gate |
| R-109 | low | Oversized-render test machine-dependent | fixed | Oversized size derived from the device's budget | StudioChecks.swift |
| R-110 | low | F3 tested only helper arithmetic | fixed | Depth 1–3 radiance across strategies | Fix_integrator |
| R-111 | low | Loose strategy energy tolerances | fixed | Per-pixel pairing against MIS with tile-clustered SE (4 SE); paired SE bound for the cylinder | GPUChecks.swift |
| R-112 | low | MetalFX energy never compared to raw | fixed | Region means vs raw (Cornell within 8%); documented as a display estimate | GPUChecks.swift |
| R-113 | low | ASWF check skipped silently, no counts | fixed | Counts asserted; `--require-reference` | USDChecks.swift, USDChecks.py |
| R-114 | low | PERFORMANCE.md figures stale | fixed | Re-measured through renderFrame at `0eb96bb`; raw report committed; old speedups withdrawn | benchmark.py → PERFORMANCE.md, PERFORMANCE-raw.txt |
| R-115 | low | Harness split on comment markers | fixed | Explicit ordered part list; markers must occur exactly once | harness.py, verify.py |
| R-116 | low | Constant material fixtures | fixed | Non-constant fixtures: linear-light mip filtering of sRGB/linear maps; GPU MaterialX subtract/clamp | Fix_tests.swift, Fix_bsdf-legacy |
| R-117 | low | GPU suite hard-requires MetalFX | fixed | MetalFX checks SKIP when unsupported; fallback presents and budgets the raw render (`simulateUnsupportedMetalFX` test seam) | Fix_tests.swift |
| R-118 | low | Checks use a test copy of frame orchestration | fixed | GPU checks call production `renderFrame`; multi-frame inspection, strategy and resize runs | GPUChecks.swift, Fix_tests.swift |
| R-119 | low | No P1-02 / P1-03 regression tests | fixed | Microgeometry and oblique-sun fixtures | Fix_geometry, Fix_lights |
| R-120 | low | ASWF render committed without attribution | fixed | `docs/images/README.md`, notices corrected | — (docs) |
| R-121 | low | REFERENCES cited dead symbols, unmapped HDRI sampler | fixed | Remapped; review date 2026-09-26 | — (symbol grep) |
| R-122 | info | Temporal reuse never ran during camera motion | fixed | `Uniforms.reservoirHistory` | Fix_integrator |
| R-123 | info | Filmic/Reinhard brightened negative input | fixed | Negative/NaN clamped | Fix_presentation |
| R-124 | info | Non-reversed depth quantized background | fixed | Reversed-Z, `isDepthReversed` | Fix_presentation |
| R-125 | info | Argument-buffer lifetime rule unwritten | fixed | Resources declared/retained; comment fixed | Fix_gpu-memory |
| R-126 | info | `captureNextFrame` dead code | fixed | Removed | — (removed code) |
| R-127 | info | `lens.z` documented as reserved | fixed | `uses_scene_graph` / `sceneGraphMode` | Fix_integrator |
| R-128 | info | Shared-struct layouts not asserted on GPU | fixed | Size/offset checks | Fix_gpu-memory |
| R-129 | info | DOCTYPE guard bypass via UTF-7 | fixed | UTF-8/ASCII only | Fix_materialx |
| R-130 | info | No line numbers; `vt u`, continuations rejected | fixed | OBJ and XML locations; `vt u`, continuations | Fix_geometry, Fix_materialx |
| R-131 | info | Duplicate framing button | fixed | One button | Fix_frontend |
| R-132 | info | No Window menu / standard shortcuts / title | fixed | ⌘W ⌘M ⌘H, Window menu, project title | Fix_frontend |
| R-133 | info | Swift 5 mode without strict concurrency | fixed | `-swift-version 6` everywhere, zero warnings; `@MainActor` renderer/app; one OIDN-options race fixed | Fix_swift6.swift |
| R-134 | info | Executable and OIDN arch could disagree | fixed | One `uname -m` for both; manifest records arch | Fix_build.py |
| R-135 | info | OpenUSD version hard-coded in globs | fixed | Single `VERSION` constant | USDChecks.py |
| R-136 | info | build/ in iCloud; conflict copies | fixed (2026-09-28) | `com.apple.fileprovider.ignore#P`; stale conflict copies and old module cache deleted | — (checked by hand) |
| R-137 | info | Python ABI checked only at build | fixed | Bridge refuses non-3.9 interpreters | USDChecks.py |
| R-138 | info | HDRIs downloaded without checksums | fixed | Pinned size + SHA-256 | — (network script) |
| R-139 | info | USDChecks.py bare asserts | fixed | Explicit `check()` that still runs under `python -O` | USDChecks.py |
| R-140 | info | Furnace rim assertion checked test-only code | fixed | Test-only branch removed; the furnace asserts production GGX | GPUChecks.swift |
| R-141 | info | Tests write into shared build/ | fixed | Per-run `build/checks/runs/verify-*` directories, `latest` link, `build/verify.lock` | harness.py |
| R-142 | info | OpenUSD README listed stale outputs | fixed | `-audit` names | — (docs) |
| R-143 | info | OpenPBR.metal lost upstream attribution | fixed | `clang -E -P -C` + modification notice | Fix_build.py, Fix_build.swift |
| R-144 | info | Fix plan marked implemented without evidence | fixed | Plan superseded; F1–F7 partial; REFERENCES corrected | — (docs) |
| R-145 | info | Cycles listed as engine-adoption candidate | fixed | Reworded as validation/reference only | — (docs) |
| R-146 | info | Hill fit without notice decision | fixed | Attribution recorded; full Baking Lab MIT notice added to THIRD_PARTY_NOTICES.md (2026-09-28) | — (docs) |

## Behaviour changes users will notice

- **Imported USD sun brightness.** A `DistantLight` is now an independent directional sun, lit even with an HDRI. Its irradiance at normal incidence follows UsdLux: intensity × 2^exposure × π·sin²(angle/2) when unnormalized, and intensity × 2^exposure when normalized. Default unnormalized suns are therefore much dimmer, and previously imported scenes look different. The angle is clamped to 0.1–90° and irradiance to 10,000, both with report lines.
- **USD area lights.** Disks and spheres keep their authored power: equal-area octagons and 80-face spheres. Untextured domes now light the scene with a constant color.
- **MaterialX `rotate2d` direction.** It now matches MaterialX 1.39: a positive angle rotates clockwise. Existing `.mtlx` graphs using `rotate2d` render rotated the other way; USD `Transform2d` results are unchanged.
- **Procedural UV orientation.** Textures on procedural walls, box sides and the ring were upside down and are now upright, so saved projects with such textures look flipped relative to before.
- **Path depth.** "Scattering depth" is now **Path depth** with pbrt semantics: depth 1 is direct lighting only, which previously rendered like depth 2. Low-depth renders change.
- **Display encoding.** The viewport and PNG use the exact piecewise sRGB curve instead of a 2.2 power curve, so the deepest shadows are slightly darker. Negative or NaN radiance displays as black.
- **OpenEXR export.** Files are 32-bit float RGB without an alpha channel. Values above 65504 are preserved.
- **OIDN input scale.** By default OIDN chooses its own HDR scale. The optional robust setting keys on lit non-emissive surfaces, and projects saved with it enabled switch to that scale. An OIDN preview needs the Beauty viewport and locks camera gestures.
- **HDRI and sun sampling.** Environment lighting is sampled correctly: the CDF bug concentrated samples on the top or bottom row. Noise patterns and convergence change. Procedural sun discs changed size slightly to match their sampled cones.
- **Normal maps and original materials.** Inspector normal maps use +Y green, like MaterialX. Maps on "Original scene material" slots now promote with inspector-consistent scalars.
- **Projects.** Open, New and Open USD Scene prompt Save / Don't Save / Cancel. Autosaves coalesce, and camera-only changes wait 5 s. Unrestorable autosaves are kept aside. Quit waits for saves. Save refuses projects that Open would reject (512 MiB embedded images, about 1.3 GiB per file).
- **Interaction.** Clicks select without editing the camera, and drags start after 3 pt. Line-based wheels zoom 10× per line. Numeric fields accept locale decimals. Errors persist in a status indicator. Standard ⌘W ⌘M ⌘H shortcuts and a Window menu are available, and the title shows the project name.
- **ReSTIR in motion.** Temporal reuse continues while the camera moves, and GI shifts with extreme Jacobians are rejected. Noise during orbiting and at contact corners changes.
- **Build.** The OIDN runtime is prepared once more on the first build, which records the new manifest. The app only loads resources from its bundle. The app, the test suite and the benchmark compile in the Swift 6 language mode and need a Swift 6 toolchain (validated with Swift 6.4).
- **Tests.** Outputs go to `build/checks/runs/verify-*`, and `build/checks/latest` points to the newest run. `build/verify.lock` serializes suite runs. MetalFX checks print `SKIP` on unsupported GPUs. MetalFX output is documented as a display estimate, not radiometric data; use raw or OIDN OpenEXR for linear radiance.

## Memory model after remediation

Per pixel: 120 B of frame textures, plus 104 B of the `PrimarySurface` cache (120 B since the 2026-09-28 graph-emission change), plus 208 B of ReSTIR DI/GI reservoirs (ReSTIR only), plus 55 B of MetalFX textures and the measured MetalFX scaler allocations (MetalFX only). The scaler figure is measured once per device, about 280–350 B/pixel on M4. `Uniforms` gained `reservoirHistoryReset` (offset 244) and `reservoirHistory` (offset 248) in former padding; the stride stays 304 bytes.

## Validation

Full suite `MTL_DEBUG_LAYER=1 python3 tests/verify.py`, 0 FAIL at every stage, on Apple M4 (16 GB), macOS 27, Swift 6.4:

| Stage | PASS |
| --- | --- |
| Integration | 76 |
| After the test step | 87 |
| After the Swift 6 step | 88 |

- `./build.sh` passed in the Swift 6 language mode.
- After the test step, `--studio-only` gave 53 PASS and `--usd-only` gave 21 PASS.
- Each package passed the full suite in its own worktree before integration, according to the package reports and, for bsdf-legacy, its run log.
- Final validation in the user's checkout (`~/Vibe Tracer`, 2026-09-28): `./build.sh` passed (Swift 6 mode, bundle check), and `MTL_DEBUG_LAYER=1 python3 tests/verify.py` exited 0 with 88 PASS and 0 FAIL. A first attempt started on 2026-09-27 failed only because the Mac slept mid-run and the 5-minute USD import timeout, which then measured wall-clock time, expired; the re-run under `caffeinate` passed. Since `4df8853` the timeout excludes system sleep (see "Follow-up, 2026-09-28").

## Repository move (2026-09-27)

During the remediation, the repository was moved from the iCloud-synced `~/Documents/ChatGPT/Vibe Tracer` to `~/Vibe Tracer`. Evicted (dataless) iCloud files had caused build and test timeouts. The build package's `com.apple.fileprovider.ignore#P` attribute keeps `build/` local in a synced location, but a checkout outside iCloud-synced folders is the reliable choice. `build/module-cache.stale-before-move` was unused and was deleted on 2026-09-28, together with the stale conflict copies (R-136).

## Follow-up, 2026-09-28

Commits on `main` after the remediation record (`git log --oneline c6971af..HEAD`):

| Commit | Change | Closes |
| --- | --- | --- |
| `f435fd8` | fix(project-format): content-addressed asset table for projects and autosave sidecars | R-45, R-74 |
| `88bf52f` | test(project-format): format 3 round trips, dedup, sidecar reuse, collection and validation | R-45, R-74 (tests) |
| `a0586f2` | fix(renderer-followups): keep one host copy of imported triangles | R-101 |
| `9f80023` | fix(renderer-followups): watertight ray/triangle intersection | Former "Triangle intersection" limitation |
| `4df8853` | fix(renderer-followups): time limits exclude system sleep | USD import timeout during sleep (see "Validation") |
| `84db5e3` | fix(renderer-followups): MetalFX specular guides read the primary-surface cache | Specular-guide re-trace left by R-57 |
| `881050d` | fix(usd-pivot): stream the scene graph for the USD orbit pivot and bounds | R-101 residual (USD pivot copy) |
| `613c787` | feat(materialx): graph-driven OpenPBR emission in the compiler, GPU VM and light sampling | ASWF `neutral` material fallback |
| `ff32d34` | feat(usd): map PreviewSurface emissiveColor to OpenPBR emission | PreviewSurface emission fallback |
| `751b164` | test(materialx): graph emission radiance, strategy agreement and the ASWF shader ball | Tests for the two above |
| `78cd868` | fix(materialx): coat emission with the MaterialX generalized_schlick_edf factor | Frame-time cost of the first coat attenuation |
| `29d46aa` | fix(usd): emissive-only stages are lit by their materials, without the neutral sky | Inspection sky on emissive-only stages ("Graph emission" limitation) |
| `5890d3a` | perf(usd): convert mesh arrays at once in the USD bridge | Slow large USD imports (per-value Gf conversion) |

- **Project format 3 (R-45, R-74).** Embedded maps, MaterialX images, the environment and mesh triangles are stored once each in an asset table keyed by SHA-256 (CryptoKit; `REFERENCES.md` `SHA256FIPS`). Triangles are binary records. `.vtrace` files and `.vmat` presets keep the table inline and stay self-contained. Autosaves and recovery copies keep payloads as `AutosaveAssets/<digest>` sidecars, written once. Sidecars that no recovery file references are collected after a successful write, with a 10-minute grace period. Version 1 and 2 projects open and are saved as format 3, and identical images count once against the 512 MiB limit. `Fix_project-format` reports the autosave bytes per revision for its fixture: 5,059,502 in the version 2 layout on every revision. In format 3 they are 3,670,014 for the first revision, 25,675 for a camera-only revision and 75,311 after a new map.
- **R-101.** Scene-graph meshes are flattened straight into the shared GPU triangle buffer and put into BVH order in place (`OBJMesh.buildInPlace`). `meshTriangles` only shares a legacy document's own array. Framing reads the buffer, and graph-edit rollback rebinds the previous buffers. Per `a0586f2`, peak host bytes while publishing a 500,000-triangle graph mesh fell from +218.9 MiB to +96.7 MiB.
- **Watertight intersection.** `intersect_mesh_triangle` implements Woop, Benthin and Wald (JCGT 2013; `REFERENCES.md` `WOOP2013`), and BVH boxes are enlarged per ray so traversal never culls a triangle the test would hit. Of 14,598 rays aimed at shared edges and vertices, 2,614 missed before and none miss now. The imported-mesh benchmark is about 1.2 ms (10%) slower per frame (`tests/PERFORMANCE.md`).
- **Time limits.** `USDImportJob` and the progressive render time limit measure awake time (`awakeSeconds`, `CLOCK_UPTIME_RAW`), so system sleep no longer uses them up. Cancellation and SIGKILL escalation are unchanged.
- **MetalFX guides.** Glossy and dielectric guide pixels take their geometric normal and rounding bound from the `PrimarySurface` cache instead of re-tracing the primary ray. Per `84db5e3`, the guide kernel alone went from 0.81 to 0.74 ms on Pavilion at 640×480.
- **USD orbit pivot (R-101 residual).** `USDImporter.load` computes the scene bounds and each supported camera's orbit pivot in one streamed pass (`USDImporter.sceneExtent` over `SceneGraph.forEachRenderTriangle`) instead of flattening every triangle with `SceneGraph.renderTriangles`, which is now used only by tests. The pivot keeps the former two-sided Möller–Trumbore test rather than the renderer's watertight one: it only places the orbit target, a missed view ray falls back to the bounds depth, and pivots and bounds are bit-identical to the flattened computation (`Fix_usd-pivot`, including an unsupported camera ahead of the others). Measured on Apple M4: for 400,000 instanced triangles and 9 rays the scan's heap peak is +0.00 MiB against +48.8 MiB flattened, at 148 against 144 ms. The import of a 240-mesh, 48,000-triangle stage peaks at +1.26 to +1.45 MiB, against +6.21 MiB before.
- **Graph-driven emission.** The ASWF Standard Shader Ball's `neutral` material no longer falls back ("Unsupported surface input emission_color"). OpenPBR `emission_color` × `emission_luminance` (nits; MaterialX v1.39.5 `open_pbr_surface.mtlx`, OpenPBR 1.1.1), constant or connected, compiles to an emission register. It is evaluated per hit, emitted from the front face, attenuated by the coat with MaterialX's `generalized_schlick_edf` factor, and added to the path while the surface keeps scattering. `tests/benchmark.py` against `2cf62b4` (scenes without emission, identical mean radiance) measured per-scenario median changes of −3.7% to +4.4%, within run-to-run noise, after a first version that prepared Adobe's BSDF a second time for coated emission was replaced by that closed form (it had cost up to 6%, consistently). PreviewSurface `emissiveColor` maps to `emission_color` at unit luminance. Graph emitters join the imported light list, selected by area × a host estimate (`MaterialXProgram.emissionWeight`: images treated as 1). Light samples (`imported_graph_emission`) and BSDF hits evaluate the actual radiance and share one PDF, so the MIS estimator stays unbiased; the estimate only affects noise (`REFERENCES.md` `MATERIALX`). An `image` without a file now evaluates to its `default`, as in the neutral material's default variant, and `clamp` addressing is supported. `tests/Fix_shaderball-emission.swift` checks textured radiance at hits and light samples (exact), sampled against evaluated PDFs (relative error 5e-7), BSDF/light/MIS/ReSTIR agreement on a graph-emissive quad (floor means 0.2260/0.2246/0.2246/0.2246), and zero ASWF material fallbacks, and imports the `bulb` variant. `PrimarySurface` grew from 104 to 120 bytes per pixel.
- **Emissive-only USD stages.** A stage without UsdLux lights whose imported materials emit (a compiled MaterialX program with a positive `MaterialXProgram.emissionWeight`, or constant emissions) is treated as lit: `USDImporter.load` adds no neutral inspection sky, leaves the environment and sun at 0, and reports "No UsdLux lights: emissive materials light the scene; no environment or sun added." A stage with neither lights nor emission, including an explicit zero `emission_luminance`, still gets the neutral sky. `tests/Fix_usd-lighting.swift` imports OpenPBR and PreviewSurface emissive-only stages, renders the OpenPBR one with its imported lighting (floor mean 0.296, background exactly 0), and checks both unlit cases.
- **USD bridge conversion.** Profiling a 204,800-triangle stage (vertex normals, face-varying UVs) with cProfile put 90 of 100 s in `vec`, which iterated each Gf vector (about 40 µs per value, through a per-element `IndexError`). `usd_bridge.py` now converts each mesh's points, normals and UVs once with `rows` (the Vt buffer protocol; half-precision arrays per element) and `vec` reads by index. The snapshot takes 4.6 to 4.9 s instead of 96.6 to 98.2 s for that stage (7.4 s against 98.3 s for the whole helper process, including SDK start-up and the 106 MB JSON write), 2.2 s instead of 31 to 32 s for the ASWF Shader Ball and 0.72 s instead of 11 s for the 48,000-triangle `pivot-shared` stage. Deterministic-ID snapshots of every `USDChecks.py` fixture and the Shader Ball are byte-identical before and after. `tests/USDChecks.py` checks that on a fixture with float and half primvars against the former conversion, and that the new path is at least three times faster (measured: 15 times).
- **R-136.** The stale `build/` conflict copies and `build/module-cache.stale-before-move` were deleted on 2026-09-28.
- **Behaviour changes.** The ASWF reference's neutral objects now use their authored OpenPBR material (default base colour 0.8, no specular) instead of the 0.18 displayColor fallback, so they render lighter. Builds from before format 3 cannot open format-3 projects. A recovery copy moved out of `~/Library/Application Support/VibeTracer/` needs its `AutosaveAssets` folder beside it; alternatively, open it and use Save As. The imported-mesh benchmark's mean raw radiance changed by 2.9% (0.6370 to 0.6186) with the watertight test.

Follow-up validation (2026-09-28, `main`): `./build.sh` passed (Swift 6 mode, bundle check); `MTL_DEBUG_LAYER=1 python3 tests/verify.py` exited 0 with 97 PASS, 0 FAIL and no compiler warnings, on Apple M4 16 GB, macOS 27, Swift 6.4.

USD orbit pivot validation (2026-09-28): `./build.sh` passed; `MTL_DEBUG_LAYER=1 python3 tests/verify.py` exited 0 with 98 PASS, 0 FAIL and no compiler warnings. With the former flattened pivot restored, `Fix_usd-pivot` fails its import heap check.

Graph-emission validation (2026-09-28, `78cd868`): `./build.sh` passed (Swift 6 mode, bundle check, no warnings); `MTL_DEBUG_LAYER=1 python3 tests/verify.py --require-reference` exited 0 with 101 PASS, 0 FAIL and no compiler warnings, on the same machine.

Emissive-only lighting and bridge conversion validation (2026-09-28, `5890d3a`): `/usr/bin/python3 tests/USDChecks.py` passed; `MTL_DEBUG_LAYER=1 python3 tests/verify.py --require-reference` exited 0 with 104 PASS, 0 FAIL and no compiler warnings; `./build.sh` passed (Swift 6 mode, bundle check). Without the `USDImporter.load` change, `Fix_usd-lighting` fails its neutral-sky check.

## Remaining limitations and partial fixes

- **R-101 (residual):** the `SceneGraph` assets are the document's host copy of imported triangles, beside the GPU buffer. *(Updated 2026-09-28: `USDImporter.load` no longer builds a transient flattened copy to place the orbit pivot; see "USD orbit pivot" under "Follow-up, 2026-09-28".)*
- **Project format 3:** builds from before format 3 cannot open format-3 projects or autosaves.
- **Graph emission:** `standard_surface` (including its emission) is not compiled; only `open_pbr_surface` is. Emission on procedural-scene slots is BSDF-sampled only. The light-selection weight treats every image as 1, so mostly dark emission maps are light-sampled inefficiently. Light samples read emission images at mip 0 while BSDF hits use the ray-cone level. Reused ReSTIR DI samples keep the coat-attenuated radiance of their original receiver. *(Updated 2026-09-28: `USDImporter.load` no longer adds the inspection sky when emissive materials light a stage without UsdLux lights; see "Emissive-only USD stages" under "Follow-up, 2026-09-28".)*
- Out of scope, unchanged: OCIO/ACES colour management, a matched Karma benchmark, external MaterialX Sdf composition, subdivision, skinning, point instancers, a two-level accelerator for multi-million-triangle scenes, and signed/notarized distribution.
