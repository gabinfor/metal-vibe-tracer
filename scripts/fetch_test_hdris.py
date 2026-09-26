#!/usr/bin/env python3
"""Download the small local Poly Haven HDRI test selection (CC0 assets)."""
import hashlib
import os
import tempfile
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Examples/HDRI"
# Pinned (size, SHA-256); sizes and MD5s match api.polyhaven.com/files/<asset> for the 4k HDR files.
ASSETS = {
    "art_studio_4k.hdr": (
        "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/art_studio_4k.hdr",
        26553881, "426c5059a81a3b33939a8a3eb95c4bbc378f94ab19cbbe62dac479b17aa5c988"),
    "studio_small_01_4k.hdr": (
        "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/studio_small_01_4k.hdr",
        26230914, "11bf6bde36c53fa3e72de5e448c5fef9cdf8c77e06af5c323c873674b6664072"),
    "photo_studio_loft_hall_4k.hdr": (
        "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/photo_studio_loft_hall_4k.hdr",
        25245847, "6b1e43955efa60a24e8021994d3ab6e630ba142fbd02d1530a0cc0ab53ec41a2"),
}


def matches(path, size, digest):
    if not path.is_file() or path.stat().st_size != size:
        return False
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest() == digest


DEST.mkdir(parents=True, exist_ok=True)
for name, (url, size, digest) in ASSETS.items():
    path = DEST / name
    if matches(path, size, digest):
        print(f"Verified: {path}")
        continue
    if path.exists():
        print(f"Replacing {path}: size or SHA-256 differs from the pinned asset")
    print(f"Downloading {name}")
    handle, name_partial = tempfile.mkstemp(prefix="." + name + ".", suffix=".partial", dir=DEST)
    partial = Path(name_partial)
    try:
        with urlopen(url, timeout=30) as source, os.fdopen(handle, "wb") as target:
            while chunk := source.read(1024 * 1024):
                target.write(chunk)
        if not matches(partial, size, digest):
            raise SystemExit(f"Downloaded {name} does not match the pinned size and SHA-256")
    except BaseException:
        partial.unlink(missing_ok=True)
        raise
    os.chmod(partial, 0o644)
    partial.replace(path)
    print(f"Saved: {path} ({path.stat().st_size / 1024 / 1024:.1f} MiB)")
