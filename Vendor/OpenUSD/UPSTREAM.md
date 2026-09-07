# OpenUSD runtime

Official `usd-core` 26.8 (OpenUSD 26.08), downloaded from PyPI; verified September 4, 2026.

- Source: https://github.com/PixarAnimationStudios/OpenUSD
- Release: https://pypi.org/project/usd-core/26.8/
- Binary: `usd_core-26.8-cp39-none-macosx_10_15_universal2.whl`
- SHA-256: `f5bd2691fb18461b600e9d106d0101a713851dfe3f7f06c59ae61704563bdf87`
- License: Tomorrow Open Source Technology License 1.0; the complete wheel license and bundled dependency notices are preserved verbatim in `LICENSE.txt`.

`scripts/prepare_usd.py` verifies the wheel checksum and extracts it into ignored `build/OpenUSD`. `build.sh` copies this unmodified runtime, including its dist-info license, into the app. The app runs its local `usd_bridge.py` with `/usr/bin/python3 -I` (CPython 3.9 from Apple's command-line tools). It does not install into system Python. The runtime must match this interpreter ABI.

The bridge is original integration code using Usd, UsdGeom, UsdShade, UsdLux, Ar, Sdf and Gf. It creates a bounded snapshot consumed by the existing Swift/Metal renderer. It does not use Hydra or replace the renderer. This wheel does not provide the optional MaterialX Sdf file-format plugin. Direct supported UsdShade networks are translated locally; external `.mtlx` composition is not supported by this runtime. See REFERENCES.md and Examples/OpenUSD/README.md for coverage and limitations.
