# Metal Vibe Tracer

An experimental path tracer for macOS, built with Swift, AppKit, and Metal. Explore lighting and materials in real time, import scenes, and export denoised renders.

## Features

- **Path tracing:** ReSTIR direct lighting and first-bounce diffuse GI, with Standard MIS, light-only, and BSDF-only comparison modes.
- **Materials:** OpenPBR surfaces, image textures, normal maps, and a supported subset of MaterialX graphs.
- **Scenes:** six procedural test scenes, OBJ import, and OpenUSD scene import with hierarchy, instances, materials, lights, and cameras.
- **Lighting:** procedural skies, HDRI environments, editable area lights, and a thin-lens camera.
- **Denoising:** MetalFX interactive preview and Open Image Denoise for in-app snapshots and offline exports.
- **Viewport:** beauty, albedo, world normals, depth, and material/roughness views.
- **Projects:** portable `.vtrace` files with embedded assets, saved camera views, undo/redo, and autosave recovery.
- **Export:** PNG and linear HDR OpenEXR at independent resolutions and sample counts.

## Requirements

- macOS 26 or later
- A Metal-capable GPU; tested on Apple M4
- Xcode 26 command-line tools
- Internet access for the first build

MetalFX preview requires a supported GPU. OpenUSD import uses the command-line tools’ `/usr/bin/python3` (CPython 3.9).

## Getting started

```sh
git clone https://github.com/gabinfor/metal-vibe-tracer.git
cd metal-vibe-tracer
./build.sh
open build/MetalVibeTracer.app
```

The first build downloads pinned OpenUSD 26.8 and Open Image Denoise 2.5.0 runtimes. Later builds reuse the cache. OpenPBR shader sources are vendored, and Metal shaders compile at runtime; the separate Metal command-line toolchain is not required.

## Usage

Choose a scene in the inspector, then adjust its camera, lighting, materials, and objects. Use **Render** to change the sampling strategy or viewport mode. **Settings…** is available in the top toolbar and the macOS application menu.

| Action | Control |
| --- | --- |
| Orbit / pan / zoom | Drag / Shift-drag / scroll |
| Select a surface | Click in the viewport |
| Open / save project | ⌘O / ⌘S |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Pause or resume / restart | ⌘P / ⌘R |
| Export controls | ⌘E |
| Settings | ⌘, |
| Show or hide inspector | ⌘I |

Use **OIDN Preview Current Frame** to denoise the current accumulation inside the app. For a final image, open **Export**, choose a resolution and sample count, and select OIDN, raw, or MetalFX output. PNG includes display adjustments; OpenEXR preserves linear HDR radiance.

Projects embed imported assets and can be reopened without the original files. The app restores its latest autosave on startup.

See the [user guide](docs/USER_GUIDE.md) for material controls, project behavior, import coverage, and export details.

## Example assets

- [MaterialX examples](Examples/MaterialX/README.md)
- [OpenUSD examples and reference scenes](Examples/OpenUSD/README.md)
- [Poly Haven HDRI test selection](Examples/HDRI/README.md)

To download the optional 4K HDRI selection locally:

```sh
python3 scripts/fetch_test_hdris.py
```

## Development

The renderer and embedded Metal kernels live in `main.swift`. App controls, project handling, importers, and export code are in `Sources/`.

```sh
./build.sh
python3 tests/verify.py
```

The verification suite runs the production shaders on Metal and checks rendering, materials, denoising, imports, project persistence, and UI construction. GPU access is required. Diagnostic images are written to `build/checks/`. Native file dialogs and mouse interactions require manual checks.

For Metal API validation:

```sh
MTL_DEBUG_LAYER=1 python3 tests/verify.py
```

See [performance notes](tests/PERFORMANCE.md) for measurements and [REFERENCES.md](REFERENCES.md) for algorithm sources, dependency versions, and implementation adaptations.

## Known limitations

- ReSTIR GI currently reuses the first diffuse indirect vertex. Deeper and glossy transport use ordinary path tracing; practical reservoir reuse is not a fully unbiased reference estimator. Use Standard MIS with fog and ring boost disabled for comparisons.
- HDRI sampling has no luminance importance map, so small bright features can converge slowly.
- OpenUSD import is a scene snapshot, with partial material and light support. Animation, subdivision evaluation, volumes, curves, and USD export are unsupported.
- MaterialX support is a bounded importer, with no node editor or graph export. OCIO/ACES color management, UDIMs, displacement, and several advanced material features are unsupported.
- MetalFX can soften detail. OIDN works on the accumulated image; raw output remains available for comparison.
- Fog and the optional ring-caustic boost are approximate preview effects.

## Acknowledgments

Built with Apple Metal and MetalFX, Adobe OpenPBR, OpenUSD, and Intel Open Image Denoise. Optional HDRI test assets are from Poly Haven under CC0.

Third-party licenses and attribution are retained with the vendored dependencies and bundled resources. Full citations and implementation notes are in [REFERENCES.md](REFERENCES.md).
