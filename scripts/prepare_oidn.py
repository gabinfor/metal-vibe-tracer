#!/usr/bin/env python3
"""Prepare the pinned official Open Image Denoise runtime for the app bundle."""
import hashlib
import json
import pathlib
import platform
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = "2.5.0"
ARCHIVES = {
    "arm64": (
        "oidn-2.5.0.arm64.macos.tar.gz",
        "586142ec125de0bf5b01d3cc4c76985d4fafb0fc91e9f6562e32f3b669f86be5",
    ),
    "x86_64": (
        "oidn-2.5.0.x86_64.macos.tar.gz",
        "afa810e4a184df145659a0ab140c1fd126897a529819f14e083e9c2de191ac31",
    ),
}
ARCH = platform.machine()
if ARCH not in ARCHIVES:
    raise SystemExit(f"OIDN has no pinned macOS runtime for architecture {ARCH!r}.")

ARCHIVE, EXPECTED = ARCHIVES[ARCH]
CACHE = ROOT / "build/oidn-cache" / ARCHIVE
DEST = ROOT / "build/OIDN"
MANIFEST = DEST / "VIBE_RUNTIME.json"

if MANIFEST.exists():
    try:
        state = json.loads(MANIFEST.read_text())
        if state.get("version") == VERSION and state.get("sha256") == EXPECTED:
            print(f"Prepared Open Image Denoise {VERSION} ({ARCH})")
            raise SystemExit(0)
    except (ValueError, OSError):
        pass

CACHE.parent.mkdir(parents=True, exist_ok=True)
if not CACHE.exists() or hashlib.sha256(CACHE.read_bytes()).hexdigest() != EXPECTED:
    url = f"https://github.com/RenderKit/oidn/releases/download/v{VERSION}/{ARCHIVE}"
    partial = CACHE.with_suffix(CACHE.suffix + ".partial")
    print(f"Downloading {url}")
    with urllib.request.urlopen(url) as response, partial.open("wb") as output:
        shutil.copyfileobj(response, output)
    partial.replace(CACHE)
if hashlib.sha256(CACHE.read_bytes()).hexdigest() != EXPECTED:
    raise SystemExit("OIDN archive checksum mismatch")

with tempfile.TemporaryDirectory(prefix="oidn-") as directory:
    extracted = pathlib.Path(directory)
    # The archive is an official, checksum-pinned release artifact.
    with tarfile.open(CACHE, "r:gz") as archive:
        archive.extractall(extracted)
    roots = [path for path in extracted.iterdir() if path.is_dir()]
    if len(roots) != 1 or not (roots[0] / "lib/libOpenImageDenoise.2.dylib").exists():
        raise SystemExit("Unexpected OIDN archive layout")
    if DEST.exists():
        shutil.rmtree(DEST)
    DEST.mkdir(parents=True)
    shutil.copytree(roots[0] / "lib", DEST / "lib", symlinks=True)
    shutil.copytree(roots[0] / "doc", DEST / "doc", symlinks=True)

MANIFEST.write_text(json.dumps({
    "version": VERSION,
    "architecture": ARCH,
    "archive": ARCHIVE,
    "sha256": EXPECTED,
}, indent=2) + "\n")
print(f"Prepared Open Image Denoise {VERSION} ({ARCH})")
