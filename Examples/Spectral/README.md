# Spectral example scenes

Small OpenUSD stages that show wavelength-dependent light, included with Metal Vibe Tracer. Open them from **File › Open Example Scene** or the **Spectral examples** section of the File page. Each opens as a new untitled project, with the camera of its stage and the settings of the `scripts/showcase.json` shot of the same name. Their effects render in spectral light transport, the default (**Light transport → Automatic**); RGB transport ignores thin film and dispersion.

The stages are plain USDA files written by `scripts/make_spectral_examples.py`; change a scene there and rerun it, rather than editing a stage by hand. They use only OpenPBR materials (`ND_open_pbr_surface_surfaceshader`), UsdLux lights and implicit `Sphere` and `Cylinder` prims, which the importer tessellates. Sources for the material values are in [REFERENCES.md](../../REFERENCES.md) under the keys given below.

| Stage | Shows | Set-up |
| --- | --- | --- |
| [`NewtonSeries.usda`](NewtonSeries.usda) | Thin-film interference | Back row: soap films (`thin_film_ior` 1.33) 100–800 nm thick over a black base whose own interface is index-matched, so only the film reflects. Their colours run through the first to fourth interference orders. Front row: anodized titanium, oxide films (`thin_film_ior` 2.4) 30–150 nm thick over a metal (`DIAMANTI2014`). A white dome and an overhead softbox give the spheres something to reflect. |
| [`AbbeRow.usda`](AbbeRow.usda) | Dispersion | 60° prisms of SCHOTT N-SF11, F2, N-BK7 and N-FK51A, Abbe numbers 25.7 to 84.5 (`SCHOTTGLASS`). Each prism is turned to minimum deviation for the camera's view through it, and a thin white slit stands 2 m beyond it where its d-line ray lands, as in a prism spectroscope. Through each prism the slit spreads into a spectrum: widest through N-SF11, narrowest through N-FK51A. Slits that fall in view also show the white source itself. A dim white dome lights the glass and the grey studio backdrop, and the saved view **USD: Overview** shows the layout from above: each slit stands behind and to the left of its prism. |

Both scenes stand in a photo-studio cyclorama, a floor that curves up into a back wall, so no horizon or floor edge shows behind them. Both scenes avoid caustics seen on diffuse surfaces (light → glass → matte surface → camera). A unidirectional path tracer finds those paths only by chance, so the slits are viewed *through* the prisms, not projected onto a screen.

To render the README-size images:

```sh
python3 scripts/render_showcase.py --only spectral-newton-series spectral-abbe-row
```
