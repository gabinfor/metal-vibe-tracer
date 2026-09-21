#!/usr/bin/env python3
"""Prepare and atomically publish the pinned OpenUSD runtime."""

import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = "26.8"
EXPECTED = "f5bd2691fb18461b600e9d106d0101a713851dfe3f7f06c59ae61704563bdf87"
BUILD = ROOT / "build"
DEST = BUILD / "OpenUSD"
RUNTIME = BUILD / f"OpenUSD-{VERSION}-cp39-{EXPECTED[:12]}"
MANIFEST = "VIBE_RUNTIME.json"
REQUIRED = (
    "pxr/Usd/__init__.py",
    "pxr/UsdGeom/__init__.py",
    "pxr/UsdShade/__init__.py",
    "pxr/Usd/_usd.so",
)


def state_valid(path: pathlib.Path, smoke: bool = False) -> bool:
    try:
        state = json.loads((path / MANIFEST).read_text())
        valid = (
            state.get("version") == VERSION
            and state.get("python") == "cp39"
            and state.get("sha256") == EXPECTED
            and all((path / item).is_file() for item in REQUIRED)
        )
        if not valid:
            return False
        if smoke:
            environment = {
                "PATH": "/usr/bin:/bin",
                "HOME": os.environ.get("HOME", "/tmp"),
                "PYTHONNOUSERSITE": "1",
            }
            result = subprocess.run(
                [sys.executable, "-I", "-c",
                 "import sys;sys.path.insert(0,sys.argv[1]);from pxr import Usd,UsdGeom,UsdShade;assert Usd.Stage.CreateInMemory()",
                 str(path)],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
            )
            return result.returncode == 0
        return True
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


if sys.version_info[:2] != (3, 9):
    raise SystemExit("OpenUSD bundle requires /usr/bin/python3 (CPython 3.9).")

BUILD.mkdir(parents=True, exist_ok=True)
with (BUILD / "openusd-prepare.lock").open("a+") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if DEST.exists() and state_valid(DEST, smoke=True):
        print("Prepared OpenUSD " + VERSION)
        raise SystemExit(0)

    wheels = BUILD / "usd-wheel"
    wheels.mkdir(parents=True, exist_ok=True)
    found = list(wheels.glob("usd_core-26.8-cp39-*.whl"))
    if not found:
        subprocess.run(
            [sys.executable, "-m", "pip", "download", "--only-binary=:all:", "--no-deps",
             "--dest", str(wheels), "usd-core==" + VERSION], check=True)
        found = list(wheels.glob("usd_core-26.8-cp39-*.whl"))
    if len(found) != 1:
        raise SystemExit("Expected the OpenUSD 26.8 CPython 3.9 macOS wheel. Run with /usr/bin/python3.")
    wheel = found[0]
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
    if digest != EXPECTED:
        raise SystemExit("OpenUSD wheel checksum mismatch")

    if not state_valid(RUNTIME, smoke=True):
        with tempfile.TemporaryDirectory(prefix="openusd-stage-", dir=BUILD) as temporary:
            stage = pathlib.Path(temporary) / "runtime"
            stage.mkdir()
            with zipfile.ZipFile(wheel) as archive:
                root = stage.resolve()
                for member in archive.infolist():
                    target = (stage / member.filename).resolve()
                    if root != target and root not in target.parents:
                        raise SystemExit("OpenUSD wheel contains an unsafe path")
                archive.extractall(stage)
            (stage / MANIFEST).write_text(json.dumps({
                "version": VERSION,
                "python": "cp39",
                "wheel": wheel.name,
                "sha256": digest,
            }, indent=2) + "\n")
            if not state_valid(stage, smoke=True):
                raise SystemExit("Prepared OpenUSD runtime failed validation")
            if RUNTIME.exists():
                shutil.rmtree(RUNTIME)
            os.replace(stage, RUNTIME)

    link = BUILD / f".OpenUSD-link-{os.getpid()}"
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(RUNTIME.name, target_is_directory=True)
    legacy = BUILD / f".OpenUSD-legacy-{os.getpid()}"
    if DEST.exists() and not DEST.is_symlink():
        os.replace(DEST, legacy)
    os.replace(link, DEST)
    if legacy.exists():
        shutil.rmtree(legacy)

print("Prepared OpenUSD " + VERSION)
