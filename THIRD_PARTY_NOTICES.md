# Third-party components

## Adobe OpenPBR BSDF

Copyright 2026 Adobe. Licensed under the Apache License, Version 2.0.
Source: https://github.com/adobe/openpbr-bsdf
Pinned revision: c91aad1d1ce1693e803f039d7c92c2965c4eb013.

The complete license is provided in Vendor/OpenPBR/LICENSE and in the app bundle
as OpenPBR-LICENSE. Original copyright and attribution comments remain in the
vendored files. The generated shader adapts two metal energy lookup functions;
see Vendor/OpenPBR/UPSTREAM.md and REFERENCES.md. As a modified file under
Apache-2.0 section 4(b), the bundled OpenPBR.metal keeps the upstream per-file
copyright and license comments and begins with a "Modified by Metal Vibe
Tracer" notice that describes the changes. The local adapter, texture
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
source files are unchanged. The downloaded assets and renders/projects generated
by the tests are optional local files under build/, not bundled with the
application. See Examples/OpenUSD/README.md.

The repository does contain one derived render of this asset:
docs/images/openusd-reference.png, a Metal Vibe Tracer image of the adapted
scene described above. It is derived from the CC-BY-4.0 asset
(https://creativecommons.org/licenses/by/4.0/); its adjacent attribution and
statement of changes are in docs/images/README.md. It is not bundled with the
application.

## Intel Open Image Denoise

Copyright Intel Corporation. Licensed under the Apache License,
Version 2.0. Source: https://github.com/RenderKit/oidn. The application bundles
the official, unmodified Open Image Denoise 2.5.0 macOS runtime for offline
final-frame denoising. Its complete license and bundled dependency notices are
preserved under `Contents/Frameworks/OIDN/doc`. Pinned archive details and the
boundary between upstream code and local integration are documented in
`Vendor/OIDN/UPSTREAM.md` and `REFERENCES.md`.

## Tone-mapping fit from Baking Lab

The filmic display curve in `tonemap` (main.swift) uses the rational fit
`RRTAndODTFit` by Stephen Hill (@self_shadow), as published in Baking Lab by MJP
and David Neubelt: https://github.com/TheRealMJP/BakingLab/blob/master/BakingLab/ACES.hlsl.
Only the fit's two rational-polynomial expressions and their five numeric
coefficients are reproduced; the ACES color matrices and the surrounding source are
not. Baking Lab is distributed under the MIT License, reproduced in full below from
https://github.com/TheRealMJP/BakingLab/blob/master/LICENSE (retrieved 2026-09-28).
See REFERENCES.md (HILLFIT).

```text
MIT License

Copyright (c) 2016 MJP

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## CIE colorimetric datasets (spectral tables)

Colour-matching functions of the CIE 1931 standard colorimetric observer (CIE 2019,
doi:10.25039/CIE.DS.xvudnb9b), CIE standard illuminants D65 (CIE 2019,
doi:10.25039/CIE.DS.hjfjmt59) and A (CIE 2018, doi:10.25039/CIE.DS.8jsxjrsn), and the CIE
fluorescent (doi:10.25039/CIE.DS.54hy6srn), high-pressure discharge
(doi:10.25039/CIE.DS.f6rvvnev) and LED (doi:10.25039/CIE.DS.dhcw57sd) illuminant tables
(CIE 2018). International Commission on Illumination (CIE), Vienna, AT.
Licensed under Creative Commons Attribution-ShareAlike 4.0 International
(https://creativecommons.org/licenses/by-sa/4.0/).

Unmodified copies with their metadata are in `Vendor/Spectral/CIE`. The tables that
`scripts/generate_spectral_tables.py` writes to `build/SpectralTables` (resampled to 1 nm,
normalized to luminance Y = 1, zero outside the tabulated range, combined into wavelength
sampling tables and a sRGB-to-spectrum lookup) are adapted material and are licensed under
CC BY-SA 4.0. The application bundles two of them, `SpectralTables.metal` and
`FourierSRGB86.bin`, under the same licence (CC BY-SA 4.0); the opt-in `FourierSRGB256.bin`
is not bundled. Details, checksums and changes: `Vendor/Spectral/UPSTREAM.md`; see REFERENCES.md
(CIEDATA).

## Phase warp from Christoph Peters' bounded-MESE code (spectral tables)

`Vendor/Spectral/Peters2019/XYZWarp.h`, unmodified, from the supplementary code of
"Spectral Rendering with the Bounded MESE and sRGB Data" (MAM 2019) and "Using Moments to
Represent Bounded Signals for Spectral Rendering" (SIGGRAPH 2019):
https://momentsingraphics.de/MAM2019.html. The generator reads its 95-entry `pXYZWarpEven`
table, which `build/SpectralTables/SpectralTables.metal` (bundled as `SpectralTables.metal`)
reproduces with the notice below. All other spectral code
is a local implementation from the papers; see REFERENCES.md (PETERS2019, FOURIERSRGB2019).

```text
Copyright (c) 2019, Christoph Peters
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the Karlsruhe Institute of Technology nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
