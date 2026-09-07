# Third-party components

## Adobe OpenPBR BSDF

Copyright 2026 Adobe. Licensed under the Apache License, Version 2.0.
Source: https://github.com/adobe/openpbr-bsdf
Pinned revision: c91aad1d1ce1693e803f039d7c92c2965c4eb013.

The complete license is provided in Vendor/OpenPBR/LICENSE and in the app bundle
as OpenPBR-LICENSE. Original copyright and attribution comments remain in the
vendored files. The generated shader adapts two metal energy lookup functions;
see Vendor/OpenPBR/UPSTREAM.md and REFERENCES.md. The local adapter, texture
infrastructure, and editor are separate from the vendored upstream source.

## Sheen implementation and lookup data included through Adobe

“Practical Multiple-Scattering Sheen Using Linearly Transformed Cosines,”
Tizian Zeltner, Brent Burley, and Matt Jen-Yuan Chiang (2022).
Source: https://github.com/tizian/ltc-sheen — Apache License, Version 2.0.

Adobe's openpbr_fuzz_lobe.h identifies its Disney-sheen routines as derived from
this reference, and openpbr_ltc_array.h attributes the fitted LTC data to it.
Their upstream attribution comments are retained in Vendor/OpenPBR.

Bibliographic references and the provenance limits of inherited renderer
formulas are documented separately in REFERENCES.md.

## OpenUSD SDK

OpenUSD contributors / Pixar Animation Studios. Official `usd-core` 26.8 binary
runtime, unmodified, from https://pypi.org/project/usd-core/26.8/.
The complete Tomorrow Open Source Technology License 1.0 and bundled dependency
notices are in `Vendor/OpenUSD/LICENSE.txt` and in the app's
`Resources/OpenUSD/usd_core-26.8.dist-info/LICENSE.txt`.
Pinned binary and integration details: `Vendor/OpenUSD/UPSTREAM.md`.

## Optional reference asset: ASWF Standard Shader Ball

Geometry and textures: Chris Rydalch. Specification and validation: André Mazzone.
Source: https://github.com/usd-wg/assets/tree/main/full_assets/StandardShaderBall
Pinned repository commit: 3b75c2dad6a494897557dcca0098257bcf42a8c6.
Creative Commons Attribution 4.0 International (CC-BY-4.0).
The downloader preserves the asset's complete LICENCE and README beside it.
The original Simball inspiration is credited to Thomas Anagnostou; this download
is the ASWF reimplementation, with its own CC-BY-4.0 license.
Local adaptations select the triangulated/plastic variants in a separate layer,
map supported shading to OpenPBR, and snapshot into this renderer. Original
source files are unchanged. Assets and generated renders/projects are optional
local downloads, not bundled with the application. See Examples/OpenUSD/README.md.
