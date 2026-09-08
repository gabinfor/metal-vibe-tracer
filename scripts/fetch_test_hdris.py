#!/usr/bin/env python3
"""Download the small local Poly Haven HDRI test selection (CC0 assets)."""
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Examples/HDRI"
ASSETS = {
    "art_studio_4k.hdr": "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/art_studio_4k.hdr",
    "studio_small_01_4k.hdr": "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/studio_small_01_4k.hdr",
    "photo_studio_loft_hall_4k.hdr": "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/photo_studio_loft_hall_4k.hdr",
}

DEST.mkdir(parents=True, exist_ok=True)
for name, url in ASSETS.items():
    path = DEST / name
    if path.exists() and path.stat().st_size > 1024:
        print(f"Exists: {path}")
        continue
    partial = path.with_suffix(path.suffix + ".partial")
    print(f"Downloading {name}")
    try:
        with urlopen(url, timeout=30) as source, partial.open("wb") as target:
            while chunk := source.read(1024 * 1024):
                target.write(chunk)
    except Exception:
        partial.unlink(missing_ok=True)
        raise
    partial.replace(path)
    print(f"Saved: {path} ({path.stat().st_size / 1024 / 1024:.1f} MiB)")
