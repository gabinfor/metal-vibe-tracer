# Documentation images

Metal Vibe Tracer rendered these images for the project documentation (commit `86f8c7d`, 2026-09-08; re-added in `7eaa8a7`, 2026-09-21). They are not bundled with the application and are not referenced by the current README.

| File | Content |
| --- | --- |
| `pavilion-restir.png` | Built-in Pavilion scene with ReSTIR direct lighting and first-bounce GI. |
| `openpbr-materials.png` | Built-in procedural scene comparing OpenPBR materials and textures. |
| `grazing-cylinder.png` | Built-in grazing-angle cylinder regression comparison. |
| `openusd-reference.png` | ASWF Standard Shader Ball imported and rendered by Metal Vibe Tracer (attribution below). |

## Attribution: `openusd-reference.png`

This image is an adapted work: a render of the **ASWF Standard Shader Ball** by the ASWF USD Working Group. Geometry and textures are by Chris Rydalch; specification and validation are by André Mazzone. The asset is inspired by Thomas Anagnostou's Simball.

- Source: https://github.com/usd-wg/assets/tree/3b75c2dad6a494897557dcca0098257bcf42a8c6/full_assets/StandardShaderBall (pinned commit `3b75c2dad6a494897557dcca0098257bcf42a8c6`)
- License: Creative Commons Attribution 4.0 International (CC-BY-4.0), https://creativecommons.org/licenses/by/4.0/
- Changes: `scripts/fetch_reference_scene.py` added a separate override layer that selects the triangulated geometry and the USD PreviewSurface plastic variant at frame 3. The official OpenUSD SDK imported the scene into a flattened snapshot, which mapped supported PreviewSurface shading approximately to OpenPBR and reported the fallbacks. Metal Vibe Tracer then rendered it with its own path tracer, which is not a pixel match to the Houdini Karma renders in the asset's documentation. The source asset files are unchanged.

Anyone sharing this image must keep this attribution and the license link (CC-BY-4.0, section 3). See `THIRD_PARTY_NOTICES.md` and `REFERENCES.md` (`ASWF_SHADERBALL`).
