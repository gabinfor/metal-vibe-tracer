# HDRI test pack

The renderer accepts equirectangular `.hdr` and `.exr` environments. These test maps are high-quality 4K captures from [Poly Haven](https://polyhaven.com/hdris), released under CC0. They are kept outside the application bundle because each map is tens of megabytes.

Run `python3 scripts/fetch_test_hdris.py` from the repository root to download:

- [Art Studio](https://polyhaven.com/a/art_studio) — mixed daylight and warm practicals
- [Studio Small 01](https://polyhaven.com/a/studio_small_01) — hard lamps and strong contrast
- [Photo Studio Loft Hall](https://polyhaven.com/a/photo_studio_loft_hall) — warm daylight and directional shadows

Load them through Lighting → Load HDRI / environment image…. The script writes only to this directory and can be rerun safely. Each download is checked against a pinned size and SHA-256 before it replaces a local file; a mismatched existing file is downloaded again.

| File | Bytes | SHA-256 |
| --- | --- | --- |
| `art_studio_4k.hdr` | 26,553,881 | `426c5059a81a3b33939a8a3eb95c4bbc378f94ab19cbbe62dac479b17aa5c988` |
| `studio_small_01_4k.hdr` | 26,230,914 | `11bf6bde36c53fa3e72de5e448c5fef9cdf8c77e06af5c323c873674b6664072` |
| `photo_studio_loft_hall_4k.hdr` | 25,245,847 | `6b1e43955efa60a24e8021994d3ab6e630ba142fbd02d1530a0cc0ab53ec41a2` |
