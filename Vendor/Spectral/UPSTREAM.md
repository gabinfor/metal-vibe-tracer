# Spectral rendering data

Inputs of `scripts/generate_spectral_tables.py`, which pins every file below by SHA-256 and
refuses to run if one differs. All files are unmodified upstream copies (the CSVs keep CIE's
formatting; `XYZWarp.h` keeps its CRLF line endings and copyright header). Retrieved 2026-10-02.
See `REFERENCES.md` (`CIEDATA`, `PETERS2019`, `FOURIERSRGB2019`) and `THIRD_PARTY_NOTICES.md`.
Nothing here is bundled with the application yet; the generated tables live in `build/SpectralTables`.

## CIE datasets (`CIE/`)

Publisher: International Commission on Illumination (CIE), Vienna, AT. Each dataset page on
<https://cie.co.at/data-tables> links the CSV and a DataCite metadata file (`*_metadata*.json`,
kept beside the CSV), which records the licence, the MD5/SHA-256 checksums, column meanings,
validation sums and the interpolation/extrapolation method. Licence of every dataset (from its
metadata `rightsList`): **Creative Commons Attribution-ShareAlike 4.0 International**
(<https://creativecommons.org/licenses/by-sa/4.0/>).

| File | Dataset (DOI) | Range / step | SHA-256 |
|---|---|---|---|
| `CIE_xyz_1931_2deg.csv` | Colour-matching functions of CIE 1931 standard colorimetric observer, CIE 2019 ([10.25039/CIE.DS.xvudnb9b](https://doi.org/10.25039/CIE.DS.xvudnb9b)); source CIE 018:2019 Table 6 | 360–830 nm, 1 nm | `fa663e3535a7e0763a745993a1f0a192eb0275ac46ad2d1befd7626841e713c1` |
| `CIE_std_illum_D65.csv` | CIE standard illuminant D65, CIE 2019 ([10.25039/CIE.DS.hjfjmt59](https://doi.org/10.25039/CIE.DS.hjfjmt59)); source ISO/CIE 11664-2:2022 Table B.1 | 300–830 nm, 1 nm | `e76f210bffff3d552ef7113025da5f325d5dfec200dd4b878b1a2f3a507032cb` |
| `CIE_std_illum_A_1nm.csv` | CIE standard illuminant A – 1 nm, CIE 2018 ([10.25039/CIE.DS.8jsxjrsn](https://doi.org/10.25039/CIE.DS.8jsxjrsn)); ISO/CIE 11664-2:2022 Table A.1 | 300–830 nm, 1 nm | `61ef23fe146b8b665c74706717ab28cec7db6c9022993490bdc71991f43cb59b` |
| `CIE_illum_FLs_1nm.csv` | Relative SPDs of illuminants representing typical fluorescent lamps, 1 nm, CIE 2018 ([10.25039/CIE.DS.54hy6srn](https://doi.org/10.25039/CIE.DS.54hy6srn)); CIE 015:2018 Tables 10.1–10.3 | 380–780 nm, 1 nm; columns FL1–FL12, FL3.1–FL3.15 | `929ee966bf465fca2073ada8965afbc332d163f6f2cb54c710a6e193251ab0cc` |
| `CIE_illum_HPs.csv` | Relative SPDs of high pressure discharge lamp illuminants, CIE 2018 ([10.25039/CIE.DS.f6rvvnev](https://doi.org/10.25039/CIE.DS.f6rvvnev)); CIE 015:2018 Table 11 | 380–780 nm, 5 nm; HP1 standard HPS, HP2 colour-enhanced HPS, HP3–HP5 metal halide | `035e09d62b27f4b1e362ff1ba99a50235f0d7886c2781c50d49851b6e4bb4552` |
| `CIE_illum_LEDs_1nm.csv` | Relative SPDs of illuminants representing typical LED lamps, 1 nm, CIE 2018 ([10.25039/CIE.DS.dhcw57sd](https://doi.org/10.25039/CIE.DS.dhcw57sd)); CIE 015:2018 Tables 12.1/12.2 | 380–780 nm, 1 nm; LED-B1–B5, BH1, RGB1, V1, V2 | `2a065526e1502f138d5b96aa8c9b337320e08667aac028ab5ad428bf1179a4b7` |

Every SHA-256 above equals the one published in the dataset's metadata file. The download URLs
are `https://files.cie.co.at/Publications-datasets/<file>` (metadata: `<file>_metadata.json` or
`<file>_metadata_v2.json`, as named here).

CIE asks that the data be cited as, for example, "CIE 2019, Colour-matching functions of CIE 1931
standard colorimetric observer, International Commission on Illumination (CIE), Vienna, AT, DOI:
10.25039/CIE.DS.xvudnb9b"; the other datasets follow the same pattern with their own title and DOI.

**Use and changes.** The generator reads the CMFs at 1 nm over 360–830 nm and the presets D65, A,
FL11, HP1 and LED-B3 (plus the synthetic equal-energy E). Following each file's metadata, spectra
are linearly interpolated onto 1 nm (only HP1 needs it) and are zero outside their tabulated range
(FL, HP and LED data stop at 380 and 780 nm). Each preset is normalized to luminance Y = 1. The
generated `SpectralTables.metal`, `FourierSRGB256.bin` and `FourierSRGB86.bin` are adapted
material of these datasets and are therefore licensed under CC BY-SA 4.0 as well; the attribution
and licence notice is written into each output's header or manifest.

## Peters' phase warp (`Peters2019/XYZWarp.h`)

Christoph Peters, Karlsruhe Institute of Technology. `LookupTableCode/XYZWarp.h` from the
supplementary code of "Spectral Rendering with the Bounded MESE and sRGB Data" (MAM 2019),
<https://momentsingraphics.de/Media/MAM2019/Peters2019-SpectralRenderingMAMCode.zip>
(archive SHA-256 `47dd65516c8a3c7eac0912f74bbd9ed0708fafed9c6bac78c5808298138879b8`). The
SIGGRAPH 2019 supplementary archive
<https://momentsingraphics.de/Media/Siggraph2019/Peters2019-CompactSpectraCode.zip>
(SHA-256 `1375d16459c1be3dc9ac1cd7e5f286245d76345dc687646a9fcbbdeb64e0d7b4`) contains a
byte-identical copy. File SHA-256 `7fcd86e29aac22f02260e6c3a651fd9f0110b5c9a0485f3eb50a626eb46312fe`.
The same 95 values appear in Peters' spectral path tracer
(<https://github.com/MomentsInGraphics/path_tracer/tree/spectral>, commit
`4fc5b1da354085fcda6f41aadbaa3d450d18822a`, `tools/illuminant_spectra.py`; that tools directory
is GPL-3.0 and was not used).

Licence: BSD 3-Clause, "Copyright (c) 2019, Christoph Peters", in the file header and reproduced
in `THIRD_PARTY_NOTICES.md`. Only the `pXYZWarpEven` table is used: the generator parses it and
interpolates it linearly in 5 nm steps, as `applyXYZWarpEven` does. `SpectralTables.metal`
contains the table and carries the notice. No other code from Peters' archives or repository is
copied; the bounded MESE, the solver, the table construction and the sampling are local
implementations from the papers.

## Rejected source

The Lamp Spectral Power Distribution Database (LSPDD, <https://lspdd.org>), which Peters' path
tracer uses for its HPS/LED/CFL spectra, is licensed CC BY-NC-ND 4.0 (per that repository's
`data/lspdd/attribution.txt`). NoDerivatives rules out the resampled and normalized tables, and
NonCommercial is not compatible with this project's other licences, so the CIE HP1 and LED-B3
illuminants are used instead.
