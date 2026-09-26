#!/usr/bin/env python3
"""Prepare the pinned official Open Image Denoise runtime for the app bundle."""
import argparse
import json
import pathlib
import platform
import shutil
import tarfile
import tempfile
import urllib.request

from buildsupport import atomic_write_text, build_directory, file_table, locked, replace_directory, sha256_file

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
# Every library the dlopen'ed stub needs at runtime; all must be in the recorded file table.
REQUIRED = (
    "lib/libOpenImageDenoise.2.dylib",
    "lib/libOpenImageDenoise_core.2.5.0.dylib",
    "lib/libOpenImageDenoise_device_cpu.2.5.0.dylib",
    "lib/libOpenImageDenoise_device_metal.2.5.0.dylib",
    "lib/libtbb.12.dylib",
)
CONTENTS = ("lib", "doc")
parser = argparse.ArgumentParser(description=__doc__)
# build.sh and tests/verify.py pass the architecture of the executable they compile.
parser.add_argument("--arch", default=platform.machine())
ARCH = parser.parse_args().arch
if ARCH not in ARCHIVES:
    raise SystemExit(f"OIDN has no pinned macOS runtime for architecture {ARCH!r}.")

ARCHIVE, EXPECTED = ARCHIVES[ARCH]
BUILD = build_directory(ROOT)
CACHE = BUILD / "oidn-cache" / ARCHIVE
DEST = BUILD / "OIDN"
MANIFEST_NAME = "VIBE_RUNTIME.json"


def runtime_valid(path: pathlib.Path) -> bool:
    try:
        state = json.loads((path / MANIFEST_NAME).read_text())
        files = state.get("files")
        return (
            state.get("version") == VERSION
            and state.get("architecture") == ARCH
            and state.get("sha256") == EXPECTED
            and isinstance(files, dict)
            and all(item in files for item in REQUIRED)
            and (path / REQUIRED[0]).is_file()
            and file_table(path, CONTENTS) == files
        )
    except (ValueError, OSError):
        return False


with locked(BUILD / "oidn-prepare.lock"):
    if runtime_valid(DEST):
        print(f"Prepared Open Image Denoise {VERSION} ({ARCH})")
        raise SystemExit(0)

    CACHE.parent.mkdir(parents=True, exist_ok=True)
    if not CACHE.is_file() or sha256_file(CACHE) != EXPECTED:
        url = f"https://github.com/RenderKit/oidn/releases/download/v{VERSION}/{ARCHIVE}"
        print(f"Downloading {url}")
        with tempfile.NamedTemporaryFile(dir=CACHE.parent, prefix=ARCHIVE + ".", suffix=".partial", delete=False) as output:
            partial = pathlib.Path(output.name)
            try:
                with urllib.request.urlopen(url, timeout=60) as response:
                    shutil.copyfileobj(response, output)
            except BaseException:
                partial.unlink()
                raise
        if sha256_file(partial) != EXPECTED:
            partial.unlink()
            raise SystemExit(f"OIDN archive checksum mismatch for {url}")
        partial.replace(CACHE)

    with tempfile.TemporaryDirectory(prefix="oidn-stage-", dir=BUILD) as directory:
        extracted = pathlib.Path(directory) / "archive"
        # The archive is an official, checksum-pinned release artifact.
        with tarfile.open(CACHE, "r:gz") as archive:
            archive.extractall(extracted)
        roots = [path for path in extracted.iterdir() if path.is_dir()]
        if len(roots) != 1 or not all((roots[0] / item).exists() for item in REQUIRED):
            raise SystemExit("Unexpected OIDN archive layout")
        stage = pathlib.Path(directory) / "runtime"
        stage.mkdir()
        for item in CONTENTS:
            shutil.copytree(roots[0] / item, stage / item, symlinks=True)
        atomic_write_text(stage / MANIFEST_NAME, json.dumps({
            "version": VERSION,
            "architecture": ARCH,
            "archive": ARCHIVE,
            "sha256": EXPECTED,
            "files": file_table(stage, CONTENTS),
        }, indent=2) + "\n")
        if not runtime_valid(stage):
            raise SystemExit("Prepared OIDN runtime failed validation")
        replace_directory(stage, DEST)

print(f"Prepared Open Image Denoise {VERSION} ({ARCH})")
