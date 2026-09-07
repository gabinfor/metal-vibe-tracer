# Open Image Denoise runtime

Intel Open Image Denoise 2.5.0, downloaded from the official RenderKit GitHub release.

- Source: https://github.com/RenderKit/oidn
- Release: https://github.com/RenderKit/oidn/releases/tag/v2.5.0
- Apple Silicon binary: `oidn-2.5.0.arm64.macos.tar.gz`
- Apple Silicon SHA-256: `586142ec125de0bf5b01d3cc4c76985d4fafb0fc91e9f6562e32f3b669f86be5`
- Intel binary: `oidn-2.5.0.x86_64.macos.tar.gz`
- Intel SHA-256: `afa810e4a184df145659a0ab140c1fd126897a529819f14e083e9c2de191ac31`
- License: Apache License 2.0.

`scripts/prepare_oidn.py` verifies the archive and copies its unmodified dynamic
libraries and documentation into ignored `build/OIDN`. `build.sh` bundles that
runtime under `Contents/Frameworks/OIDN`. The complete upstream license and
dependency notices remain in the bundled `doc` directory.

`Sources/OIDN.swift` is original integration code against OIDN's C99 ABI. It
dynamically loads the bundled library, copies the renderer's converged linear HDR
radiance and primary-surface albedo/normal guides into an `RT` filter, requests
high-quality final-frame processing, and copies the result back to a Metal
texture. OIDN itself and its trained weights are unmodified upstream binaries.
