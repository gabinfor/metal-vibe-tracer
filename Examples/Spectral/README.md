# Spectral example scenes

Small OpenUSD stages that show wavelength-dependent light, included with Metal Vibe Tracer. Open them from **File › Open Example Scene** or the **Spectral examples** section of the File page. Each opens as a new untitled project, with the camera of its stage and the settings of the `scripts/showcase.json` shot of the same name. Their effects render fully in spectral light transport, the default (**Light transport → Automatic**). RGB transport ignores thin film, dispersion and lamp presets, and evaluates the Rayleigh law at three wavelengths.

The stages are plain USDA files written by `scripts/make_spectral_examples.py`; change a scene there and rerun it, rather than editing a stage by hand. They use OpenPBR materials (`ND_open_pbr_surface_surfaceshader`), UsdLux lights (with `ShapingAPI` cones), implicit `Sphere`, `Cube` and `Cylinder` prims, which the importer tessellates, and the renderer's custom `vibe:spectrum` and `vibe:medium` attributes ([docs/VOLUME_DESIGN.md](../../docs/VOLUME_DESIGN.md)). Sources for the material values are in [REFERENCES.md](../../REFERENCES.md) under the keys given below.

| Stage | Shows | Set-up |
| --- | --- | --- |
| [`NewtonSeries.usda`](NewtonSeries.usda) | Thin-film interference | Back row: soap films (`thin_film_ior` 1.33) 100–800 nm thick over a black base whose own interface is index-matched, so only the film reflects. Their colours run through the first to fourth interference orders. Front row: anodized titanium, oxide films (`thin_film_ior` 2.4) 30–150 nm thick over a metal (`DIAMANTI2014`). A white dome and an overhead softbox give the spheres something to reflect. |
| [`AbbeRow.usda`](AbbeRow.usda) | Dispersion | 60° prisms of SCHOTT N-SF11, F2, N-BK7 and N-FK51A, Abbe numbers 25.7 to 84.5 (`SCHOTTGLASS`). Each prism is turned to minimum deviation for the camera's view through it, and a thin white slit stands 2 m beyond it where its d-line ray lands, as in a prism spectroscope. Through each prism the slit spreads into a spectrum: widest through N-SF11, narrowest through N-FK51A. Slits that fall in view also show the white source itself. A dim white dome lights the glass and the grey studio backdrop, and the saved view **USD: Overview** shows the layout from above: each slit stands behind and to the left of its prism. |
| [`TyndallTank.usda`](TyndallTank.usda) | Rayleigh scattering | A 2.2 m block of medium inside an invisible index-matched boundary (`specular_weight` 0). Its scattering follows (550/λ)⁴ (`vibe:medium:rayleigh` on the material; `BUCHOLTZ1995`). A 2° white beam (a disk light with a `ShapingAPI` cone) crosses it: blue light scatters out near the entry, and the beam that reaches the card is orange. |
| [`LampSpectra.usda`](LampSpectra.usda) | Lamp spectra | The same red, green and blue spheres under five spot lamps of equal luminance in light haze (`vibe:medium` on the default prim): a 2700 K blackbody, D65, FL11, HP1 (sodium) and LED-B3 (`vibe:spectrum`). Sodium's few lines turn green and blue to mud and black. |

Every scene stands in a photo-studio cyclorama, a floor that curves up into a back wall, so no horizon or floor edge shows behind it. None relies on caustics seen on diffuse surfaces (light → glass → matte surface → camera), which a unidirectional path tracer finds only by chance: the Abbe row's slits are viewed *through* the prisms, not projected onto a screen, and the Tyndall tank's container is index-matched, so shadow rays reach the beam through it.

To render the README-size images:

```sh
python3 scripts/render_showcase.py --only spectral-newton-series spectral-abbe-row spectral-tyndall-tank spectral-lamp-spectra
```
