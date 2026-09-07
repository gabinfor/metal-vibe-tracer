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
