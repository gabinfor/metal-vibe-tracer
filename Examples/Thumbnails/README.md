# Scene browser thumbnails

One 480 × 270 JPEG per scene of the scene browser (`SceneCatalog.entries`), shown on its card and in its details pane. They are bundled with the app (`build.sh` copies this folder to `Contents/Resources/Examples/Thumbnails`), and `scene-ids.txt` lists the ids that have one, which `scripts/check_bundle.py` checks.

Metal Vibe Tracer rendered them on 2026-11-11 on an Apple M4 with

```
python3 scripts/render_showcase.py --thumbnails
```

at 960 × 540 from the scene's `scripts/showcase.json` shot (a built-in scene: its default view), spectral transport, not denoised, at the shot's sample count capped at 256 (256 spp for the built-in and spectral scenes, 128 spp for the McGuire scenes), downsampled to 480 × 270 and saved as JPEG at quality 0.85. The renderer code is the checkout of the commit that added this folder.

## Built-in and bundled scenes

`pavilion`, `cornell-box`, `veach-mis`, `cornell-glass-mirror`, `cornell-fog` and `reflective-ring` are the application's built-in scenes. `newton-series`, `abbe-row`, `tyndall-tank`, `lamp-spectra` and `lantern-arcade` are the OpenUSD stages of [`Examples/Spectral`](../Spectral/README.md), whose notes give their sources. `cornell-fog.jpg` shows the Cornell Fog Study's default state, in which the fog preview is off, so it looks like the Cornell Box with a brighter light.

## Morgan McGuire's Computer Graphics Archive scenes

Each of these images is an adapted work: a render of a model from [Morgan McGuire's Computer Graphics Archive](https://casual-effects.com/data/) (`MCGUIRE2017` in `REFERENCES.md`), and carries its license.

| Image | Scene | Author | License |
| --- | --- | --- | --- |
| `sponza.jpg` | Crytek Sponza | © 2010 Frank Meinl, Crytek | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| `san-miguel.jpg` | San Miguel 2.0 | © Guillermo M. Leal Llaguno | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| `bistro-exterior.jpg`, `bistro-interior.jpg` | Amazon Lumberyard Bistro | © 2017 Amazon Lumberyard | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `bedroom.jpg` | Bedroom | © 2017 fhernand | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/): this image is shared under CC BY-SA 4.0 |
| `breakfast-room.jpg` | Breakfast Room | © Wig42 | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| `fireplace-room.jpg` | Fireplace Room (Benedikt Bitterli's The Grey & White Room) | © Wig42 | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| `living-room.jpg` | Living Room (Benedikt Bitterli's The White Room) | © 2012 Jay-Artist | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |

Changes: the models were imported from OBJ with their MTL materials translated to OpenPBR, lit with a procedural sky or sun, framed by the showcase shot's camera and rendered. The Bistro exterior switches the scene's emission off and the interior scales its lamps' emission by 60.

## Withheld

The Happy Buddha and Chinese Dragon (© 1996 Stanford University) have no thumbnail until the Stanford 3D Scanning Repository's terms are confirmed for redistributed renders (`STANFORD3DSCAN`); `SceneCatalog.thumbnailExempt` lists them and `scene-ids.txt` omits them.
