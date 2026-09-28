# Adobe OpenPBR BSDF

Source: https://github.com/adobe/openpbr-bsdf
Revision: c91aad1d1ce1693e803f039d7c92c2965c4eb013
Retrieved: 2026-09-04
License: Apache-2.0 (see LICENSE).

Headers, lookup-table data, and upstream README are unmodified. Only the
header trees, README, and license are vendored. Renderer adapters live in main.swift.
The build preprocesses the MSL configuration into a bundled shader resource;
it does not download or execute upstream build scripts.

Local generated-shader adaptation: scripts/prepare_shaders.py replaces only the
ideal-metal energy-complement and average-complement lookup bodies with the
denser checked-in Shaders/MetalEnergy.metal table. It is regenerated with the
pinned VNDF/Smith functions by scripts/generate_metal_energy.py. No vendored
header is modified. See REFERENCES.md (ADOBEOPENPBR) for rationale and validation.

Modification notice (Apache-2.0 section 4(b)): the generated
build/ShaderResources/OpenPBR.metal, bundled as Contents/Resources/OpenPBR.metal,
is a modified form of these headers. scripts/prepare_shaders.py preprocesses them
with `clang -E -P -C`, keeping the upstream per-file copyright and license
comments, and prefixes the file with a "Modified by Metal Vibe Tracer" line that
names the preprocessing and the energy-lookup substitution. The upstream-only
variant (--upstream-only --output) used by the energy-table generator is never
bundled. tests/Fix_build.py and tests/Fix_build.swift check these notices.
