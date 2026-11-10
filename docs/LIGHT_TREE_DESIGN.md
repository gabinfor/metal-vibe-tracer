# Light tree: many-light sampling for imported emitters

Status: **2026-11-04. Implemented** as **Render › Light sampling** (`LightSampling`) and the default for imported scenes (§5). Citations: `CONTY2018` (the method) and `PBRT2023` §12.6.3 (`BVHLightSampler`, the formulation followed here); see [REFERENCES.md](../REFERENCES.md).

## 1. Problem

Next-event estimation in imported scenes chooses an emitter triangle from one global table, in proportion to area × luminance (`imported_emitter_area_pdf`). The receiver plays no part in that choice: a lamp in the next room, or one facing away, is chosen as often as the lamp overhead, and its sample is wasted (zero geometry term, or a tiny contribution). Scenes with many lights spread through a large space, such as the Bistro interior's lamps, spend most light samples this way. ReSTIR DI resamples these candidates but cannot fix their source distribution.

## 2. Method

A bounding volume hierarchy over the emitter triangles, with up to eight triangles per leaf (§3). Each node stores pbrt-v4's `LightBounds`: spatial bounds, total power φ (area × the slot's selection weight, the same weight power sampling uses), the cone of emitter normals (axis w, cos θ_o) and the emission angle beyond it (cos θ_e: 0 for a one-sided Lambertian triangle, the cone angle for a UsdLux spot, whose emission is zero outside it).

A node's importance at a receiver p is pbrt's conservative bound: φ × cos θ′ / d², where d² is the squared distance to the bounds' centre (clamped below by half the diagonal) and θ′ is the smallest possible angle between an emitter normal in the cone and the direction to p, widened by the angle the bounds subtend; it is zero when θ′ exceeds the emission angle. Sampling walks from the root, choosing each child in proportion to its importance and rescaling one uniform number at each step, then chooses within the leaf in proportion to power; the triangle's probability is the product of the choices, divided by its area for an area density.

**No receiver normal.** pbrt's importance can also bound the receiver's cosine. Here the BSDF-hit side (`eval_light_pdf`) has no shading normal, and MIS needs the sampled and evaluated PDFs to agree exactly, so the importance uses p only. Volume scattering points, which have no normal, need nothing special.

**PDF of a BSDF hit.** The hit's rendered-triangle ID is found in the emitter list (sorted by ID when the tree is on) by binary search, which gives its leaf position; its share of the leaf's power and the choices above it are recomputed from the leaf up to the root through parent links, with the same importance function, so it equals the sampling probability up to rounding (≤ 3e-6 relative in `tests/Fix_light-tree.swift`).

## 3. Layout and build

The tree follows the emitter list in the same buffer (`MaterialLibrary.lightTreeList`): the ID-sorted triangle IDs, each one's leaf position, the total, node count, node and leaf offsets, the box node bounds are quantised in, padding to 16 bytes, the nodes and, per leaf position, the emitter's ID, power and leaf node. With power sampling the list is unchanged and ends with a zero node count, so power renders are as before.

**Compact nodes.** Each node is 32 bytes, after pbrt-v4's `CompactLightBounds`: the cone axis octahedral-encoded in 2 × 16 bits, power as a float, cos θ_o and cos θ_e in 16 bits each (rounded down, which widens the angles), the bounds in 6 × 16 bits within the tree's box (rounded outward), the second child or a leaf's first position, and the parent (27 bits) with a leaf's emitter count (5 bits). Nodes are stored depth first, so a node's first child is the next node and the two children are read from consecutive memory. Rounding only widens the bounds, so the importance stays conservative, and sampling and PDF evaluation decode the same values.

**Leaves of several emitters.** `LightTree.build` (Sources/LightTree.swift) follows pbrt-v4's build: at each node, 12 centroid buckets per axis and the split with the lowest surface area orientation heuristic (SAOH, pbrt's `EvaluateCost`). pbrt always splits down to one light. Here a range of at most eight emitters stays one leaf when its best split would cost at least 75% of the unsplit range's SAOH, which is what happens for emitters sharing their place and facing: the triangles of one lamp or panel. They gain nothing from separate importance tests, and choosing among them by power saves the walk's last levels. Separate lights, or triangles facing different ways, still split, because their split costs far less (smaller bounds or narrower normal cones).

**No tree where it cannot help.** When the build keeps every emitter in one leaf (at most eight emitters sharing their place and facing), the tree would be power sampling, so the list is built without a tree and the GPU takes the power path without walking. A tree deeper than the 64 levels the GPU walks, or with more nodes than the 27-bit parent field holds, also falls back to power sampling.

The build is iterative and runs when the emitter list is rebuilt: on emission, emitter-light, geometry and transform changes, and when the mode changes.

## 4. Correctness

Both selections are unbiased estimators of the same integral; only their variance differs. `tests/Fix_light-tree.swift` checks the host tree (every emitter in exactly one leaf, links, power sums, enclosing quantised bounds, coincident and degenerate emitters), that light samples and BSDF hits agree on the PDF, that power and tree selection both match a quadrature reference of a 588-emitter ceiling within five standard errors, that the tree rarely chooses an emitter facing away from the receiver (never on that fixture), that it lowers variance where nearby lights dominate (20–100× on that fixture), and that a few emitters build no tree. The light-related GPU checks (lights, USD lighting, ReSTIR PT, volumes, Shader Ball emission, acceleration) pass with `VIBE_LIGHT_SAMPLING=tree`.

A sample can fail where every emitter below a node faces away from p although the node's merged cone does not: the walk stops and the sample contributes nothing, as in pbrt. This wastes samples (not bias) when nearly all lights face away.

## 5. Default

`LightSampling.automatic` resolves to the light tree. At equal time it lowered error by 60–87% in Lamp Spectra, 8–17% in the Bistro interior (37,436 emitters), 15% in the Tyndall Tank and 5–9% on the Shader Ball, tied in scenes with few or no emitters and in Abbe Row, and cost about 5% in San Miguel (4,032 emitters, +5% frame time for no error gain). The compact nodes and multi-emitter leaves cut the tree's frame-time cost from +8–11% to +5–8% in the largest scenes and halved its memory; see [tests/PERFORMANCE.md](../tests/PERFORMANCE.md), "Light tree". **Power** stays selectable on the Render page.

## 6. Not done

- The receiver-normal bound (§2), which would need the shading normal in every `eval_light_pdf` caller.
- Splitting (`CONTY2018`'s adaptive tree splitting into several samples per shading point).
- The sun and environment keep their fixed share of light samples; the tree covers emitter triangles only.
