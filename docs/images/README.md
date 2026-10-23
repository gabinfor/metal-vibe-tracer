# Documentation images

Metal Vibe Tracer rendered these images for the project documentation. They are not bundled with the application.

The README images were rendered on 2026-10-20 on an Apple M4 with `python3 scripts/render_showcase.py`, using the renderer code of `8bd999a`. The script reads the shots from `scripts/showcase.json` and exports each one through the app's Export path (`StudioController.startExport`, spectral transport by default, Open Image Denoise). The PNG output was cropped where noted and converted to JPEG (quality 90) with `sips`.

| File | Content |
| --- | --- |
| `pavilion-hdri.jpg` | Built-in Architectural Pavilion lit by the Poly Haven **Art Studio** HDRI (CC0), with a thin-lens camera. 1920×1080, 1024 spp. |
| `cornell-glass-mirror.jpg` | Built-in Cornell Glass & Mirror scene, showing the glass sphere's caustic. 1200×1200, 1024 spp. |
| `spectral-incandescent-a.jpg`, `spectral-fluorescent-fl11.jpg`, `spectral-sodium-hp1.jpg` | Built-in Cornell Glass & Mirror scene with the area light's **Light spectrum** set to CIE A, FL11 and HP1. 1000×1000, 1024 spp each. |
| `spectral-newton-series.jpg`, `spectral-abbe-row.jpg` | The bundled spectral examples (`Examples/Spectral`, `SCHOTTGLASS`, `DIAMANTI2014`): Newton's colour series (1600×900, 512 spp) and the Abbe row (1600×900, 1024 spp). Rendered on 2026-10-23 with the code committed alongside them. |
| `pavilion-depth-of-field.jpg` | Built-in Pavilion close-up with a 0.09 aperture radius focused on the copper sphere, lit by the Poly Haven **Studio Small 01** HDRI (CC0). Rendered at 1600×1200, 1024 spp, and cropped to 1600×900 (rows 100–999) to match the twilight image beside it. |
| `pavilion-twilight.jpg` | Built-in Pavilion from a low camera, with the roof beams against the **Twilight / Studio** sky preset. 1920×1080, 1024 spp. |
| `shaderball-loft.jpg` | ASWF Standard Shader Ball, side view, lit by the Poly Haven **Photo Studio Loft Hall** HDRI (CC0). Rendered at 1600×1200, 512 spp, and cropped to 1200×1200 (columns 380–1579) to match the Cornell image beside it (attribution below). |
| `sponza-noon.jpg`, `san-miguel-golden.jpg`, `bistro-exterior-golden.jpg`, `bistro-interior.jpg` | Production scenes from Morgan McGuire's Computer Graphics Archive, imported from OBJ with their MTL materials translated to OpenPBR MaterialX (`MTL2026`, `MCGUIRE2017`), with procedural skies; the daylight Bistro exterior switches the scene's emission off and the evening Bistro interior scales its lamps' emission maps by 60 with the CIE A illuminant as their spectrum (`emissionScale` and `lightSpectrum` in `scripts/showcase.json`; since MTL emission has no absolute scale, the scale is applied to the compiled programs by `ProjectDocument.scaleImportedEmission`, which `scripts/render_showcase.py` and **File › Open Example Scene** share through `ShowcaseShot`). Rendered on 2026-10-23 at 1600×900, 128 spp, with the code committed alongside them, on top of `a6f247a` (MTL glass, anisotropic texture filtering, calibrated bump strength). The Bistro exterior's textures are decoded at reduced size to fit the GPU texture budget of a 16 GB M4. Attribution below. |
| `validation-veach-mis.jpg` | `scripts/compare_mitsuba.py` side-by-side of the built-in Veach MIS scene (Metal Vibe Tracer \| Mitsuba 3.9.1 \| relative block difference), RGB, Standard MIS, 4,096 / 16,384 spp, 2026-10-22, resized to 1600 px wide. |
| `validation-bathroom.jpg` | `scripts/compare_scene.py` side-by-side of Bitterli's Contemporary Bathroom by Mareck (CC0), converted to OpenUSD (Metal Vibe Tracer \| Mitsuba 3.9.1 `volpath` \| relative block difference), 2026-10-21 at `2124b70`. |
| `filtering-before-after.jpg` | 1:1 crops of 1920×1080, 128-spp Sponza renders before and after anisotropic ray-cone filtering (the "after" render applied the footprint scale at every hit, which looks the same at primary hits as the committed version). |
| `glass-before-after.jpg` | 1:1 crops of 960×540, 64-spp Bistro exterior renders before and after MTL glass translation. |
| `bump-before-after.jpg` | 1:1 crops of 1920×1080, 128-spp Sponza gallery renders with bump strength `-bm`/512 and 4× that (`-bm`/128, the new constant). |
| `grazing-cylinder.png` | Built-in grazing-angle cylinder regression comparison (commit `86f8c7d`, 2026-09-08). Not shown in the README. |

## Attribution: `shaderball-loft.jpg`

This image is an adapted work: a render of the **ASWF Standard Shader Ball** by the ASWF USD Working Group. Geometry and textures are by Chris Rydalch; specification and validation are by André Mazzone. The asset is inspired by Thomas Anagnostou's Simball.

- Source: https://github.com/usd-wg/assets/tree/3b75c2dad6a494897557dcca0098257bcf42a8c6/full_assets/StandardShaderBall (pinned commit `3b75c2dad6a494897557dcca0098257bcf42a8c6`)
- License: Creative Commons Attribution 4.0 International (CC-BY-4.0), https://creativecommons.org/licenses/by/4.0/
- Changes: `scripts/fetch_reference_scene.py` added a separate override layer that selects the triangulated geometry and the USD PreviewSurface plastic variant at frame 3. The official OpenUSD SDK imported the scene into a flattened snapshot, which mapped supported PreviewSurface shading approximately to OpenPBR and reported the fallbacks. Metal Vibe Tracer then rendered it with its own path tracer, with the Poly Haven Photo Studio Loft Hall environment added to the scene's own lights. The render is not a pixel match to the Houdini Karma renders in the asset's documentation. The source asset files are unchanged.

Anyone sharing this image must keep this attribution and the license link (CC-BY-4.0, section 3). See `THIRD_PARTY_NOTICES.md` and `REFERENCES.md` (`ASWF_SHADERBALL`).

## Attribution: production scenes

Renders of scenes from Morgan McGuire's Computer Graphics Archive (https://casual-effects.com/data/), July 2017, imported without changes to the source files:

- **Crytek Sponza** © 2010 Frank Meinl, Crytek. Creative Commons Attribution 3.0 (https://creativecommons.org/licenses/by/3.0/).
- **San Miguel 2.0** © Guillermo M. Leal Llaguno. Creative Commons Attribution 3.0 (https://creativecommons.org/licenses/by/3.0/).
- **Amazon Lumberyard Bistro** © 2017 Amazon Lumberyard. Creative Commons Attribution 4.0 (https://creativecommons.org/licenses/by/4.0/).

Changes: the scenes were rendered by Metal Vibe Tracer with its own MTL-to-OpenPBR translation, cameras, procedural sky and sun; the renders are adapted works. See `REFERENCES.md` (`MCGUIRE2017`, `MTL2026`). The app does not bundle these scenes; **File › Open Example Scene** downloads them from the archive on request and shows these credits.
