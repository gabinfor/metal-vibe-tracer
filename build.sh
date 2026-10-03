#!/bin/zsh
set -eu
cd -- "$(dirname -- "$0")"
# One architecture for the executable and the bundled OIDN runtime.
arch="$(uname -m)"
python3 scripts/prepare_shaders.py
# Spectral tables for spectral light transport (docs/SPECTRAL_DESIGN.md): the coarse Fourier sRGB
# grid is solved once into build/SpectralTables (about two minutes), then reused. The 96 MiB
# FourierSRGB256.bin is an opt-in test reference (--lut256), never bundled.
python3 scripts/generate_spectral_tables.py
/usr/bin/python3 scripts/prepare_usd.py
python3 scripts/prepare_oidn.py --arch "$arch"
app="build/MetalVibeTracer.app"
# Assemble a staging bundle (compile first) and swap it in only once it is complete and checked.
stage="build/.MetalVibeTracer.app.stage-$$"
retired="build/.MetalVibeTracer.app.retired-$$"
trap 'rm -rf -- "$stage" "$retired"' EXIT
rm -rf -- "$stage"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources" "$stage/Contents/Frameworks" build/module-cache
# Swift 6 language mode: actor isolation and Sendable violations are compile errors.
xcrun swiftc -O -swift-version 6 -target "$arch-apple-macosx26.0" -module-cache-path build/module-cache main.swift Sources/*.swift -o "$stage/Contents/MacOS/MetalVibeTracer"
cp build/ShaderResources/OpenPBR.metal "$stage/Contents/Resources/"
cp Vendor/OpenPBR/LICENSE "$stage/Contents/Resources/OpenPBR-LICENSE"
cp Vendor/OpenPBR/UPSTREAM.md "$stage/Contents/Resources/OpenPBR-UPSTREAM.md"
cp THIRD_PARTY_NOTICES.md "$stage/Contents/Resources/THIRD_PARTY_NOTICES.md"
# CC BY-SA 4.0 (CIE data) and BSD-3-Clause (Peters' phase warp); notices in THIRD_PARTY_NOTICES.md.
cp build/SpectralTables/SpectralTables.metal build/SpectralTables/FourierSRGB86.bin "$stage/Contents/Resources/"
cp Vendor/Spectral/UPSTREAM.md "$stage/Contents/Resources/Spectral-UPSTREAM.md"
cp scripts/usd_bridge.py "$stage/Contents/Resources/"
cp -RL build/OpenUSD "$stage/Contents/Resources/OpenUSD"
cp Vendor/OpenUSD/UPSTREAM.md "$stage/Contents/Resources/OpenUSD-UPSTREAM.md"
cp -RH build/OIDN "$stage/Contents/Frameworks/OIDN"
cp Vendor/OIDN/UPSTREAM.md "$stage/Contents/Resources/OIDN-UPSTREAM.md"
cp REFERENCES.md "$stage/Contents/Resources/REFERENCES.md"
cat > "$stage/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>MetalVibeTracer</string>
    <key>CFBundleIdentifier</key><string>local.vibetracer.app</string>
    <key>CFBundleName</key><string>Metal Vibe Tracer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/python3 scripts/check_bundle.py "$stage" "$arch"
if [[ -e "$app" ]]; then mv -- "$app" "$retired"; fi
if ! mv -- "$stage" "$app"; then
    [[ -e "$retired" ]] && mv -- "$retired" "$app"
    exit 1
fi
printf 'Built %s\n' "$PWD/$app"
