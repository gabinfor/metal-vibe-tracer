# Documentation images

Metal Vibe Tracer rendered these images for the project documentation. They are not bundled with the application.

The README images were rendered on 2026-10-20 on an Apple M4 with the renderer of `8bd999a` with `python3 scripts/render_showcase.py`. The script reads the shots from `scripts/showcase.json` and exports each one through the app's Export path (`StudioController.startExport`, spectral transport by default, Open Image Denoise). The PNG output was converted to JPEG (quality 90) with `sips`.

| File | Content |
| --- | --- |
| `pavilion-hdri.jpg` | Built-in Architectural Pavilion lit by the Poly Haven **Art Studio** HDRI (CC0), with a thin-lens camera. 1920×1080, 1024 spp. |
| `cornell-glass-mirror.jpg` | Built-in Cornell Glass & Mirror scene, showing the glass sphere's caustic. 1200×1200, 1024 spp. |
| `shaderball-studio.jpg` | ASWF Standard Shader Ball imported from OpenUSD and lit by the Poly Haven **Studio Small 01** HDRI (CC0). 1600×1200, 512 spp (attribution below). |
| `spectral-incandescent-a.jpg`, `spectral-fluorescent-fl11.jpg`, `spectral-sodium-hp1.jpg` | Built-in Cornell Glass & Mirror scene with the area light's **Light spectrum** set to CIE A, FL11 and HP1. 1000×1000, 1024 spp each. |
| `pavilion-depth-of-field.jpg` | Built-in Pavilion close-up with a 0.09 aperture radius focused on the copper sphere, lit by the Poly Haven **Studio Small 01** HDRI (CC0). 1600×1200, 1024 spp. |
| `pavilion-twilight.jpg` | Built-in Pavilion under the **Twilight / Studio** sky preset, with the light spectrum set to CIE A. 1920×1080, 1024 spp. |
| `shaderball-loft.jpg` | ASWF Standard Shader Ball, side view, lit by the Poly Haven **Photo Studio Loft Hall** HDRI (CC0). 1600×1200, 512 spp (attribution below). |
| `grazing-cylinder.png` | Built-in grazing-angle cylinder regression comparison (commit `86f8c7d`, 2026-09-08). Not shown in the README. |

## Attribution: `shaderball-studio.jpg` and `shaderball-loft.jpg`

These images are adapted works: a render of the **ASWF Standard Shader Ball** by the ASWF USD Working Group. Geometry and textures are by Chris Rydalch; specification and validation are by André Mazzone. The asset is inspired by Thomas Anagnostou's Simball.

- Source: https://github.com/usd-wg/assets/tree/3b75c2dad6a494897557dcca0098257bcf42a8c6/full_assets/StandardShaderBall (pinned commit `3b75c2dad6a494897557dcca0098257bcf42a8c6`)
- License: Creative Commons Attribution 4.0 International (CC-BY-4.0), https://creativecommons.org/licenses/by/4.0/
- Changes: `scripts/fetch_reference_scene.py` added a separate override layer that selects the triangulated geometry and the USD PreviewSurface plastic variant at frame 3. The official OpenUSD SDK imported the scene into a flattened snapshot, which mapped supported PreviewSurface shading approximately to OpenPBR and reported the fallbacks. Metal Vibe Tracer then rendered it with its own path tracer, with a Poly Haven environment (Studio Small 01 or Photo Studio Loft Hall) added to the scene's own lights. The renders are not a pixel match to the Houdini Karma renders in the asset's documentation. The source asset files are unchanged.

Anyone sharing these images must keep this attribution and the license link (CC-BY-4.0, section 3). See `THIRD_PARTY_NOTICES.md` and `REFERENCES.md` (`ASWF_SHADERBALL`).
