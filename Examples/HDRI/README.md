# HDRI test pack

The renderer accepts equirectangular `.hdr` and `.exr` environments. These test maps are high-quality 4K captures from [Poly Haven](https://polyhaven.com/hdris), released under CC0. They are kept outside the application bundle because each map is tens of megabytes.

Run `python3 scripts/fetch_test_hdris.py` from the repository root to download:

- [Art Studio](https://polyhaven.com/a/art_studio) — mixed daylight and warm practicals
- [Studio Small 01](https://polyhaven.com/a/studio_small_01) — hard lamps and strong contrast
- [Photo Studio Loft Hall](https://polyhaven.com/a/photo_studio_loft_hall) — warm daylight and directional shadows

Load them through Lighting → Load HDRI / environment image…. The script writes only to this directory and can be rerun safely.
