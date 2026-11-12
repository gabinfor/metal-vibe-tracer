# Scene browser thumbnails

One 480 × 270 JPEG per scene of the scene browser (`SceneCatalog.entries`), shown on its card and in its details pane. They are bundled with the app (`build.sh` copies this folder to `Contents/Resources/Examples/Thumbnails`), and `scene-ids.txt` lists the ids that have one, which `scripts/check_bundle.py` checks.

Metal Vibe Tracer rendered them on 2026-11-11 (the ten Bitterli scenes below, Cornell Fog and the five spectral scenes on 2026-11-12) on an Apple M4 with

```
python3 scripts/render_showcase.py --thumbnails
```

at 960 × 540 from the scene's `scripts/showcase.json` shot (a built-in scene: its default view, except Cornell Fog, below), spectral transport, not denoised, at the shot's `thumbnailSamples` or else its sample count capped at 256 (256 spp for the built-in and Bitterli scenes, whose shots carry none, 128 spp for the McGuire scenes; 512 spp for Newton's Colour Series, Abbe Row, Lamp Spectra and Lantern Arcade, and 1,024 spp for Tyndall Tank and the Veach Bidir Room, whose noise 256 spp leaves visible after the downsample), downsampled to 480 × 270 and saved as JPEG at quality 0.85. Each image was rendered by the checkout of the commit that last changed it (Little Lamp's with the Mitsuba importer's emitter-in-glass conversion, Modern Hall's with the area-averaged mip levels of `METALTEXTURES`).

## Built-in and bundled scenes

`pavilion`, `cornell-box`, `veach-mis`, `cornell-glass-mirror`, `cornell-fog` and `reflective-ring` are the application's built-in scenes. `newton-series`, `abbe-row`, `tyndall-tank`, `lamp-spectra` and `lantern-arcade` are the OpenUSD stages of [`Examples/Spectral`](../Spectral/README.md), whose notes give their sources. The Cornell Fog Study opens with its atmosphere clear, so `cornell-fog.jpg` renders the `cornell-fog` shot (`"fog": 1`, a `thumbnailOnly` shot that the README showcase run skips): the default view with **Atmosphere: Fog preview** switched on, which is what the Lighting page's **Atmosphere** popup gives after opening the scene from the browser and choosing it. The preview is a mild single-scatter haze, seen as a halo around the light and a lifted, slightly desaturated wall colour.

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

## Benedikt Bitterli's Rendering Resources scenes

Each of these images is an adapted work: a render of a scene from [Benedikt Bitterli's Rendering Resources](https://benedikt-bitterli.me/resources/) (`BITTERLI2016` in `REFERENCES.md`). The six CC0 scenes need no credit, which is listed anyway; the four CC BY 3.0 ones credit their author and carry the license.

| Image | Scene | Author | License |
| --- | --- | --- | --- |
| `veach-bidir.jpg` | Veach, Bidir Room | Benedikt Bitterli (after Eric Veach's test scene) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| `veach-ajar.jpg` | Veach, Ajar | Benedikt Bitterli | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| `glass-of-water.jpg` | Glass of Water | aXel | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| `bathroom.jpg` | Contemporary Bathroom | Mareck | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| `water-caustic.jpg` | Water Caustic | Benedikt Bitterli | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| `lamp.jpg` | Little Lamp | UP3D | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| `kitchen.jpg` | Country Kitchen | © Jay-Artist | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| `white-room.jpg` | The White Room | © Jay-Artist | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| `grey-white-room.jpg` | The Grey & White Room | © Wig42 | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| `modern-hall.jpg` | Modern Hall | © NewSee2l035 | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |

Changes: the scene files were opened through the Mitsuba importer, which translates their Mitsuba materials to OpenPBR and keeps the scene's own camera, area emitters and path depth, and rendered at 960 × 540 with the showcase shot's view. Five scenes have square films (the Veach Bidir Room, Contemporary Bathroom, Water Caustic, Little Lamp and Modern Hall): at 16:9 the thumbnail keeps the camera's horizontal field of view, so its vertical field of view shrinks and the image is the horizontal band of the square frame that 16:9 covers (the vertical field of view 20.1° for the Veach Bidir Room and Little Lamp, 32.6° for Contemporary Bathroom, 11.0° for Water Caustic and 43.0° for Modern Hall), so the frame has no black bars at its sides. Water Caustic uses light tracing + photons caustics. Rendered on 2026-11-12 with 256 spp (the Veach Bidir Room 1,024 spp), spectral transport and no denoiser, so the images keep some grain, Contemporary Bathroom and Water Caustic most.

## Withheld

The Happy Buddha and Chinese Dragon (© 1996 Stanford University) have no thumbnail until the Stanford 3D Scanning Repository's terms are confirmed for redistributed renders (`STANFORD3DSCAN`); `SceneCatalog.thumbnailExempt` lists them and `scene-ids.txt` omits them.
