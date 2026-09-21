#!/bin/zsh
set -eu
cd -- "$(dirname -- "$0")"
python3 scripts/prepare_shaders.py
/usr/bin/python3 scripts/prepare_usd.py
python3 scripts/prepare_oidn.py
app="build/MetalVibeTracer.app"
mkdir -p "$app/Contents/Resources"
cp build/ShaderResources/OpenPBR.metal "$app/Contents/Resources/"
cp Vendor/OpenPBR/LICENSE "$app/Contents/Resources/OpenPBR-LICENSE"
cp Vendor/OpenPBR/UPSTREAM.md "$app/Contents/Resources/OpenPBR-UPSTREAM.md"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp scripts/usd_bridge.py "$app/Contents/Resources/"
rm -rf "$app/Contents/Resources/OpenUSD"
cp -RL build/OpenUSD "$app/Contents/Resources/OpenUSD"
cp Vendor/OpenUSD/UPSTREAM.md "$app/Contents/Resources/OpenUSD-UPSTREAM.md"
mkdir -p "$app/Contents/Frameworks"
rm -rf "$app/Contents/Frameworks/OIDN"
cp -R build/OIDN "$app/Contents/Frameworks/OIDN"
cp Vendor/OIDN/UPSTREAM.md "$app/Contents/Resources/OIDN-UPSTREAM.md"
cp REFERENCES.md "$app/Contents/Resources/REFERENCES.md"
mkdir -p "$app/Contents/MacOS" build/module-cache
xcrun swiftc -O -target "$(uname -m)-apple-macosx26.0" -module-cache-path build/module-cache main.swift Sources/*.swift -o "$app/Contents/MacOS/MetalVibeTracer"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>MetalVibeTracer</string>
    <key>CFBundleIdentifier</key><string>local.vibetracer.app</string>
    <key>CFBundleName</key><string>Metal Vibe Tracer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf 'Built %s\n' "$PWD/$app"
