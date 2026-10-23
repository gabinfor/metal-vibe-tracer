# Large-scene storage: design proposal

Status: **2026-10-20. Phases 0–3 are implemented (results below); phase 4 imports Bitterli's scenes (group A) and McGuire's Sponza, San Miguel and Bistro interior (group B); the Bistro exterior's texture budget remains.** Citation keys marked *(proposed)* are not in `REFERENCES.md` yet; they are added, with their adaptations, in the change that implements them.

## Goal

Import and render production test scenes that the current limits reject, such as McGuire's San Miguel (about 10 M triangles and hundreds of materials) and the Amazon Lumberyard Bistro exterior (2.8 M triangles). The Swift/Metal renderer, ReSTIR and MetalFX stay as they are (`AGENTS.md`). Radiance must not change: the Mitsuba comparison (`scripts/compare_mitsuba.py`) and the GPU suite are the acceptance checks.

## Where the limits come from

| Limit | Value | Cause |
| --- | --- | --- |
| Stored triangles | 1,000,000 | Chosen, not derived (500,000 at `47c0ad2`, doubled in `e1222d9`). The real guard is `meshBudget`: a quarter of `recommendedMaxWorkingSetSize`, about 3 GiB on a 16 GB M4. |
| Rendered triangles | 64,000,000 | Instancing bound. Until phase 0, the ReSTIR DI reservoir stored `triangle + 2` as `float(...)` (`restir_di_encode`), exact only up to 2^24 ≈ 16.7 M rendered triangles; it is now stored bit-exactly. |
| Materials | 64 | `SurfaceSettings[64]` uploaded with `setBytes` (4 KB cap, `static_assert` at `main.swift:1848`), `array<texture2d<float>, 256> maps` (64 × 4), `SpectralScene.materials[64]`, `GraphHeader[64]`, and the `objectID = 64 + node` pick encoding. |
| Scene nodes | 256 | Instance and pick encoding bound. |
| USD import | — | `usd_bridge.py` returns every triangle as JSON (about 600 bytes per triangle), which is 6 GB for San Miguel. |

### Bytes per triangle today

- `MeshTriangle`: 128 B, unindexed. It holds three positions, three normals and the UVs as `float4`s. `uvc.z`, `uvc.w` and `na.w` carry the subset, slot and node.
- Software BLAS nodes (`MeshWideNode`, 128 B) share the triangle buffer, which is addressed in 128-byte units.
- The Metal hardware BLAS is built from the same records: vertex stride 16, indices `8k, 8k+1, 8k+2`. Its compacted size is **86 B per triangle** (phase 0). Fix_accel measured **leaks on shared edges with welded or packed vertices** and none with this unwelded layout (`Acceleration.swift:844`); phase 0 confirmed it on macOS 27.
- Resident total today: about **214 B per triangle** with hardware traversal (128 + 86).

## Research summary

Primary sources were checked where marked ✓. The rest is from a literature search, still to be verified when implemented.

- **Indexed, attribute-compressed vertices** reach about 12–26 B per triangle at the usual vertex/triangle ratio of about 0.5. Octahedral normals in 32 bits are the standard choice for glossy shading (Cigolle et al., JCGT 2014 *(proposed `OCTNORMAL2014`)*).
- **Position quantization** (16-bit per meshlet) saves a further 3 B per triangle but risks cracks on shared edges and outside conservative bounds. It is rejected here: the hardware path is already sensitive to vertex layout, and validation against Mitsuba requires exact geometry.
- **AMD Dense Geometry Format** uses 128-byte blocks of up to 64 triangles. It reports 6–10× smaller triangle leaves and about 50% smaller BVHs (Barczak et al., HPG 2024 *(proposed `DGF2024`)*). It needs driver/hardware support that Metal does not expose. It is related work, not adopted.
- **NVIDIA cluster acceleration structures (RTX Mega Geometry)** are build/update amortisation for NVIDIA hardware. Related work, not adopted.
- **Compressed wide BVH (CWBVH8):** 80-byte nodes with quantized child boxes (Ylitie, Karras, Laine, HPG 2017 *(proposed `CWBVH2017`)*). It is a candidate for the software fallback only, in a later phase, because the M4 uses the hardware path.
- **Metal** ✓ (macOS 27 SDK headers and Apple documentation):
  - `MTLAccelerationStructureTriangleGeometryDescriptor` takes `vertexFormat`, `vertexStride` and a `uint16`/`uint32` index buffer.
  - **Per-primitive data** (`primitiveDataBuffer`, macOS 13+) stores small records in the structure. Apple warns that large records increase its size.
  - macOS 26 adds `MTLAccelerationStructureUsageMinimizeMemory` and `PreferFastIntersection`.
  - Built sizes are device-specific, so they are measured, not assumed.

## Proposed design

### Phase 0: measure and fix — done 2026-10-20

1. **DI reservoir encoding fixed.** `restir_di_pack_light` / `restir_di_unpack_light` store the light ID's bits in `posDir.w`, offset by `0x00800000` into the normal floats so no ID is a denormal that a store could flush; 0 stays +0.0, which empty reservoirs write. `tests/Fix_accel.swift` (`fixDILightIDChecks`) round-trips IDs up to 0x7E7FFFFF (about 2.1 × 10^9) through an `rgba32Float` texture.
2. **Hardware watertightness, macOS 27.0.1, Apple M4** (`scripts/measure_acceleration.swift`; 2,433 shared-edge and vertex targets × 6 eyes × 2 instances, the second rotated, scaled and translated = 29,196 rays per case):

   | BLAS input | Leaks (closest / any hit), every usage flag | Compacted size |
   | --- | --- | --- |
   | Production `MeshTriangle` records (stride 16, indices `8k..8k+2`) | 0 / 0 | 86.1 B/triangle |
   | Unwelded packed `float3` + identity `uint32` indices | 0 / 0 | 86.1 B/triangle |
   | Unwelded packed `float3`, no index buffer | 25 / 25 | 45.0 B/triangle |
   | Welded packed `float3` + indices | 25 / 25 | 45.0 B/triangle |
   | Welded stride-16 `float3` + indices | 25 / 25 | 45.0 B/triangle |

   Metal evidently switches to a compact internal format (45 B per triangle) whenever vertices can be shared, and on this device that format leaks at shared edges. **A watertight hardware BLAS costs 86 B per triangle whatever the input.** `MinimizeMemory` saves at most 2% (44.2 B on unindexed input) and nothing on watertight inputs; `PreferFastIntersection` changes nothing measurable.
3. **Build and traversal, 10 M triangles:**
   - Watertight inputs: 821 MiB BLAS, 0.9 s build and compaction, about 377 Mrays/s on incoherent closest-hit rays.
   - Leaky compact inputs: 429 MiB, 0.4 s, about 448 Mrays/s.
   - The 1 M-triangle throughput numbers were too noisy to use: another GPU job was running.
   - Raw output is kept in `build/measure-acceleration.txt` (not committed); summary in `tests/PERFORMANCE.md`.

### Phase 1: indexed geometry — done 2026-10-20 (GPU representation)

Implemented for the two-level paths (software and hardware); the flat median-BVH reference path keeps its `MeshTriangle` buffer. The document model, importers and project format still hold `MeshTriangle` arrays (phase 3), and the encoding happens at publish.

- **Streams** (`MeshStreams`): `MeshFace` (three absolute `uint32` vertex indices plus the stored `uvc.z`, 16 B) and `MeshVertex` (position, normal and UV as exact `float`s, 32 B), welded per asset only when all eight attribute bit patterns are equal; BLAS nodes in their own buffer; and, for a graph-less mesh only, a `UInt32` per face carrying its stored `uvc.w` and `na.w` (such a mesh may hold flattened scene-graph triangles). Argument-buffer IDs 394–397.
- **Exactness:** `face_triangle` / `instance_source` (MSL) and `StoredTriangles` (Swift) rebuild every `MeshTriangle` field the renderer reads, so renders are unchanged: the ASWF Shader Ball, raw EXR, renders byte-identically to `main` with Standard MIS/RGB and with the defaults (ReSTIR PT, spectral).
- **Hardware BLAS:** built from a transient unwelded input (packed `float3` corners, identity indices, 36 B per triangle plus 12 B per triangle of the largest asset), freed after compaction; `hardwareLeaks` probes the same input.
- **Measured** (`scripts/measure_mesh_memory.py`, 999,698-triangle welded grid, 0.50 vertices per triangle, Apple M4):

  | Traversal | Before (old layout, derived) | Phase 1 (measured) |
  | --- | --- | --- |
  | Software two-level | 160 B/triangle (128 triangle + 32 BLAS) | **64 B** (16 faces + 16 vertices + 32 BLAS) |
  | Hardware | 246 B/triangle | **150 B** (+ 86 watertight BLAS) |

  Publish (BVH build, welding, buffers, and the hardware build) takes 0.28 s (software) and 0.36 s (hardware) for 1 M triangles.
- **Remaining saving:** hardware mode still builds the software BLAS (32 B per triangle) beside the hardware one, for asset bounds and the software fallback; skipping it would bring hardware to about 118 B.
- Full GPU suite: 180 PASS.

#### Original proposal

Per mesh asset, as structure-of-arrays GPU buffers:

| Stream | Encoding | Bytes |
| --- | --- | --- |
| Position | packed `float3`, exact | 12 per vertex |
| Normal | 32-bit octahedral | 4 per vertex |
| UV | `float2` | 8 per vertex |
| Triangle | three `uint32` indices | 12 per triangle |
| Subset | `uint16` per triangle | 2 per triangle |

That is about **26 B per triangle** at V/T = 0.5, against 128 today, roughly 5× smaller.

With the watertight 86 B hardware BLAS, the resident total is about **112 B per triangle against 214 today**, roughly 1.9× smaller. For San Miguel (10 M triangles) that is about 1.1 GB instead of 2.1 GB, and the 3 GiB `meshBudget` of a 16 GB M4 holds about 27 M triangles instead of 15 M.

- **Shader:** `mesh_hit_attributes` fetches three indices, then positions, normals and UVs. The watertight `WOOP2013` test reads the same positions. The slot and node come from the instance binding (`instance_triangle` already supplies them). The `uvc.z`/`uvc.w`/`na.w` side channels go away.
- **Hardware BLAS:** welded input leaks (phase 0), so each build writes a **transient unwelded stream**: packed `float3` positions plus identity `uint32` indices, 48 B per triangle. It compacts the structure (86 B per triangle) and frees the stream. BLAS refits are not used (instances refit the TLAS), so the stream is never needed again. The run-time probe keeps gating the hardware default and should also cover the transient layout. Its build input is a third of today's 128-byte records.
- **Software BLAS:** nodes move to their own buffer, which ends the 128-byte coupling. The 4-wide 128-byte node stays for now.
- **Emitters and NEE:** keep rendered triangle IDs (32-bit). With the phase 0 fix they are exact up to 2^32.

### Phase 2: material table — done 2026-10-20

- **Capacities:** `SceneLimits.materials` 1,024 (1,016 imported plus the eight procedural slots), `graphImages` 4,096, `nodes` 65,535; MSL `MATERIAL_SLOTS` / `GRAPH_IMAGES` match (checked in `Fix_gpu-memory`). Object IDs of imported nodes start at `MATERIAL_SLOTS`.
- **Settings:** `SurfaceSettings` for every slot is one buffer bound at index 1 (replacing the 4 KB `setBytes`), rebuilt on the next bind after an edit.
- **Spectral parameters** moved from `SpectralScene` (now 368 bytes) into the material argument buffer (`spectralMaterials`), read through `Wavelengths.images`.
- **Argument buffer:** small members at IDs 0–14, then `graphImages[4096]` at 16 and `maps[4096]` at 4112 (`MaterialLibrary.Argument`).
- **Projects:** in memory every `SceneState` has full capacity; files store the slots up to the last one in use, at least 64 (`SceneState.trimmed`), and decoding pads them back (`padded`). Existing 8- and 64-slot projects open unchanged.
- **USD bridge** caps follow (`MATERIALS` 1,016, `NODES` 65,535).
- `tests/Fix_accel.swift` (`fixMaterialSlotChecks`) traces 300 quads bound to slots 8–307 and checks each slot's settings, a base-colour map at texture index 1,152, an emitter at slot 307, and the project trim/pad round trip. Full GPU suite: 181 PASS.

#### Original proposal

- `SurfaceSettings`, `ObjectSettings`, emissions, spectral parameters and `GraphHeader` move from `setBytes` and fixed arrays into **device buffers sized to the material count**.
- Textures move to an argument-buffer array sized to the scene, or a table of `gpuResourceID`s, both indexed by `slot * 4 + channel`.
- Slots stay 16-bit (`PrimarySurface.flags` and the SPMIS key already reserve 16 bits).
- The pick encoding `64 + node` becomes a tagged ID.
- Proposed caps: **1,024 materials**, 4,096 material textures, and 65,536 scene nodes.

### Phase 3: limits, import and projects — done 2026-10-20

- **Document model:** `MeshAsset.geometry` is a `MeshGeometry` (Sources/MeshGeometry.swift) with the GPU encoding: 32-byte exact vertices welded by attribute bits and 16-byte faces (indices and subset), 32 B per triangle at V/T = 0.5 against 128. `MeshAsset.triangles` remains a decoding view for small meshes, tools and tests. Validation, flattening, comparison and publishing use the geometry; publishing copies vertices and permutes faces into BLAS order, with no re-welding.
- **OBJ** welds shared `v`/`vt`/`vn` corners while parsing. **USD:** `usd_bridge.py` writes one binary `.vtmesh` sidecar per distinct asset instead of JSON triangles (see `OPENUSD` in REFERENCES.md for the 1-ulp tie-rounding change it brings).
- **Project format 4:** graph meshes are `MeshGeometry.payload`; formats 1–3 open (format 3's 128-byte graph payloads weld on load) and save as format 4. The legacy graph-less mesh keeps the 128-byte payload.
- **Limits:** `SceneLimits.triangles` 16 M stored (not 32 M: San Miguel is about 10 M, and the 3 GiB `meshBudget` of a 16 GB M4 binds near 20 M with hardware traversal); the flat reference path keeps 1 M (`SceneLimits.flatTriangles`); the open-file bound is about 4.2 GiB (4.9 GiB since the embedded-image limit rose to 1 GiB, below).
- **Measured** (`scripts/measure_mesh_memory.py`, welded grid, Apple M4): 10 M triangles publish in 1.07 s (software) and 2.31 s (hardware), with 575 MiB and 1,396 MiB of GPU mesh memory (60 and 146 B per triangle) and a 320 MB document; document plus GPU is about 178 B per triangle against about 374 before phase 1.
- Full GPU suite: 181 PASS.

#### Original proposal

- `SceneLimits.triangles` rises to **32 M stored**; on a 16 GB M4, `meshBudget` binds first, at about 27 M. Rendered triangles are bounded by 32-bit IDs. Memory stays governed by `meshBudget` and `renderMemoryError`, which now count the actual streams and structures.
- **USD bridge:** emits indexed meshes as a binary sidecar (positions, normals, UVs, indices, subsets), not JSON triangles. **OBJ:** keeps shared vertices instead of expanding faces.
- **Project format 4:** stores the indexed streams. Formats 1–3 open and convert. The proposal's ~1.85 GiB file cap was not adopted; the bound is `ProjectDocument.maximumFileBytes` (see Limits).

### Phase 4: validation — group A done 2026-10-20

Bitterli's Mitsuba 3 scenes (`BITTERLI2016` in REFERENCES.md) go through `scripts/mitsuba_to_usd.py` into the app's USD import and are compared with Mitsuba's render of the same XML by `scripts/compare_scene.py`; see `BITTERLI2016` for the per-scene numbers. Veach Bidir agreed within 1% and most others within 2–7% at first. On 2026-10-21 bisection found conversion bugs (mirrored lights, conductor reflectance, plastic internal scattering, nested BSDF ids) and a Mitsuba `path` integrator quirk with masks; after them five of seven scenes agree within 2.5%, Veach Ajar is +5% from OpenPBR's energy-conserving rough metals, and Country Kitchen (−3%) and Modern Hall (+4.5%) keep localized residuals (`BITTERLI2016` in REFERENCES.md). Alpha cutouts (stochastic coverage from OpenPBR `geometry_opacity`) now run in every traversal; with them Country Kitchen's mean ratio moves from 0.97 to 0.99. 

**Group B (2026-10-20):** a streaming OBJ reader, MTL materials translated to OpenPBR MaterialX, and bump-to-normal conversion (`MTL2026`, `MCGUIRE2017` in REFERENCES.md). Crytek Sponza (262 k triangles), San Miguel (10.0 M triangles, 287 materials, 12 s import) and the Bistro interior (1.0 M) import and render, with alpha-cutout foliage. The Bistro exterior needs 671 MiB of textures. The embedded-image limit rose from 512 MiB to 1 GiB (`ProjectDocument.embeddedAssetLimit`), so it imports, saves (a 1,095 MiB project, written in 4.1 s) and reopens (3.0 s); the open-file bound becomes about 4.9 GiB. Its 233 textures are 940 Mpixel, about 4.7 GiB as RGBA8 with mipmaps, against a GPU texture budget of about 3 GiB on a 16 GB M4 (`MaterialLibrary.textureBudget`). Since 2026-10-21 the largest MaterialX images are decoded at reduced size until the scene fits (113 at 2048 px, 77 at 1024 px; 2,613 MiB), and the exterior renders. Block compression (ASTC/BC) would keep more detail and is not implemented. There is no reference renderer comparison for these scenes yet.

#### Original proposal

- GPU suite: updated layout tests and new tests for indexed attributes, mirrored instances, transient unwelded builds, more than 64 materials, and the DI encoding above 2^24.
- Mitsuba comparison unchanged: radiance must match the current results (Cornell within 0.02%).
- Large-scene tests: Crytek Sponza (262 k triangles) and San Miguel (10 M). Record memory, build time and frame time in `tests/PERFORMANCE.md`.

### Scaling to larger Macs — 2026-10-21

The app was developed on a 16 GB, 10-core M4; on larger Macs nothing fixed should bind before the hardware does.

- **Memory:** the budgets already scale with `recommendedMaxWorkingSetSize` (a quarter each for meshes and textures, 70% for render frames). The static caps no longer bind first: stored triangles rise from 16 M to 2^30 and rendered triangles from 64 M to 2^31 − 1, both addressing bounds (32-bit offsets and IDs). Texture downscaling (`METALTEXTURES`) applies only when the budget is exceeded, so larger Macs show full-resolution images.
- **Project entries:** a single entry was capped at 256 MiB, so one mesh asset above about 6 M triangles saved but could not be reopened (measured: a 9,005,768-triangle mesh, 274 MiB payload, 369 MiB project, "an asset key or size is out of range"). Entries are now bounded by the largest mesh payload, and the same project reopens.
- **Viewport:** the view follows the display's refresh rate (120 Hz on ProMotion) instead of a fixed 60, and `PathTracerRenderer.samplesPerFrame` encodes as many samples per frame (`renderFrame(samples:)`) as fit in 80% of a display interval at the measured GPU busy time per sample (the union of command-buffer intervals, since consecutive buffers overlap; decaying over about 16 frames). One sample per frame while the view changes or MetalFX runs. Batched samples accumulate bit-identically to separate frames (`tests/Fix_scaling.swift`).
- **Export:** two command buffers stay in flight, each holding about 100 ms of samples, so the GPU does not wait for the main thread between samples, and the display passes run once per batch instead of once per sample.

Measured on the 16 GB M4 with `scripts/measure_throughput.py` (raw 1920×1080 export of 32 samples; viewport samples per second at 60 Hz on a 1280×800 drawable): every case is GPU-bound here, so throughput is unchanged within run-to-run noise (about ±15%). Before → after: pavilion, ReSTIR 3.1 → 2.8 export samples/s, 25 → 29 viewport samples/s at 640×400; Cornell, Standard MIS 11.8 → 10.2 and 60 → 60; Sponza 0.8 → 0.7 and 7 → 7; Bistro exterior 0.2 → 0.2. Even 320×200 Cornell frames take 10–16 ms of GPU time (latency-bound paths, not pixel-bound), so this GPU has no idle time for batching to fill; on a 48×32 view (0.36 ms per sample) the batch size reaches 64. The gains apply where a GPU finishes a frame faster than the display or the export loop asks for one, which is the larger-Mac case and cannot be measured on this machine.

**Cutout fast path (2026-10-21):** scenes with an alpha-cutout material used to force every triangle non-opaque in hardware traversal, so every candidate hit returned to the shader. Instances are now opaque in the instance structure unless one of their bound slots has a cutout (`MaterialLibrary.instanceOpacity`); `mesh_closest` lets opaque instances commit in hardware, and `mesh_occluded` stops at any opaque or uncut hit before the endpoint slack, checking slack and cutouts only in the last [tMax − S, tMax). Material and binding edits rebuild the instance structure when an instance's opacity changes (`refreshInstanceOpacity`), so an opaque instance never holds a cutout (`tests/Fix_accel.swift`). Sponza marks 349 of 381 instances opaque. Same-harness A/B on the M4 (GPU time per 640×400 sample, median of 16 frames, three alternating rounds): Sponza Standard MIS 104 / 102 / 92 → 91 / 79 / 79 ms, ReSTIR 142 / 179 / 122 → 121 / 111 / 105 ms (about 15–23% less); Bistro exterior (two rounds, median of 8) MIS 285 / 287 → 257 / 257 ms, ReSTIR 447 / 464 → 418 / 413 ms (about 10% less; more of its instances hold cutouts). The rest of these scenes' cost is ordinary path tracing: removing every MaterialX material makes Sponza slower (brighter default albedo lengthens paths), and software traversal is about twice as slow.

### Showcase quality fixes — 2026-10-22

Framing the Sponza, San Miguel and Bistro showcase renders exposed three rendering gaps, now fixed (citations in REFERENCES.md):

- **Texture filtering** (`RAYCONES2021`, `PBRT2023`): the isotropic ray-cone footprint, enlarged by 1/|cos θ|, blurred receding floors, walls and drapes by up to four mip levels, and a full-pixel footprint filtered again what the jittered samples already filter. Footprints are now ellipses fed to the hardware's anisotropic filter as explicit gradients, and the camera cone is scaled by pbrt-v4's max(1/8, 1/√spp). Sponza's floor tiles, fabric weave and stone grain resolve. A first version that also scaled every bounce's footprint made a 1920×1080, 128-spp Sponza export take 328 s instead of 204 s (wall time, including import and OIDN) from incoherent rays reading fine mip levels; the scale now applies at primary hits only, as pbrt applies it to camera rays. A same-harness measurement of this version against the old filtering is still to be done.
- **MTL glass** (`MTL2026`): `illum` 4/6/7/9 rendered as opaque `illum` 2, so Bistro's window panes (`Kd` 1) were white. They are now smooth OpenPBR transmission filtered by `Tf`, thin-walled when `Ni` is 1 ("light does not bend"), through new per-slot `transmission_color` and `geometry_thin_walled` support (`MATERIALX`). Paths now continue through the windows into the buildings: a 960×540, 64-spp Bistro exterior export took 179 s instead of 67 s. Bistro's `MASTER_Glass_Exterior` still glows: it is authored with emission (`Ke` 0.2 × a grime map) to fake lit interiors. Constant dissolve without a mask is glass too (San Miguel's glassware, `d` 0.5, rendered half-transparent white before). The daylight showcase shots switch the scenes' emission off (`emissionScale` in `scripts/showcase.json`), which leaves `MASTER_Glass_Exterior` as dark reflective panes and the interior lamps unlit; with emission on, the lamps' emission maps (radiance at most 1) barely light the room, so the evening interior shot scales them by 60 with an incandescent spectrum. Smooth glass also misled the denoiser: its OIDN albedo and normal guides were the glass's own (white, flat), which blurred everything behind San Miguel's glassware; the guides now come from the surface behind smooth glass (`OIDN250`).
- **Bump strength** (`MTL2026`): the `-bm`/512 convention made Sponza's height maps 3–5× flatter than the archive's authored normal maps; the constant is now 128, calibrated on their median slopes. McGuire's `sponza.mtl` still gives no bump map to the arches, floor and ceiling (`sponza_arch_bump.png` ships unreferenced).

Full GPU suite: 189 PASS (2026-10-23).

## Not adopted, and why

- **Quantized positions, DGF and meshlet decode at traversal:** crack risk, hardware support Metal lacks, or complexity for about 3 B per triangle of extra saving.
- **CWBVH8 for the software path:** deferred. It only helps devices without hardware ray tracing.
- **Streaming and out-of-core geometry:** not needed below about 30 M triangles on a 16 GB machine.

## Risks

- Hardware watertightness with welded input fails on macOS 27 (phase 0). The transient unwelded build avoids it, at the cost of up to 48 B per triangle of peak memory per batch during builds; batches stay within `meshBudget`.
- The 45 B compact format would halve BLAS memory if a later OS or device makes it watertight. The probe table above should be re-run on OS updates.
- The change touches the importers, the project format, shaders and roughly 30 test files. It is staged so that each phase passes the full GPU suite on its own.
