#!/usr/bin/env python3
"""Prepare and atomically publish the pinned OpenUSD runtime."""

import fcntl
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

from buildsupport import build_directory, replace_directory, sha256_file

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = "26.8"
EXPECTED = "f5bd2691fb18461b600e9d106d0101a713851dfe3f7f06c59ae61704563bdf87"
BUILD = build_directory(ROOT)
DEST = BUILD / "OpenUSD"
RUNTIME = BUILD / f"OpenUSD-{VERSION}-cp39-{EXPECTED[:12]}"
MANIFEST = "VIBE_RUNTIME.json"
WHEEL_PATTERN = f"usd_core-{VERSION}-cp39-*.whl"
# Validate exactly the modules the bridge imports, so the runtime cannot drift from it.
# The bridge may guard the import (`try:from pxr import ...`) to report a missing SDK.
_BRIDGE_IMPORT = re.search(r"^(?:try:\s*)?from pxr import ([\w ,]+)$", (ROOT / "scripts/usd_bridge.py").read_text(), re.M)
if not _BRIDGE_IMPORT:
    raise SystemExit("scripts/usd_bridge.py no longer has a 'from pxr import' line")
MODULES = tuple(name.strip() for name in _BRIDGE_IMPORT.group(1).split(","))
REQUIRED = tuple(f"pxr/{name}/__init__.py" for name in MODULES) + ("pxr/Usd/_usd.so",)


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
                 "import sys;sys.path.insert(0,sys.argv[1]);from pxr import " + ",".join(MODULES)
                 + ";assert Usd.Stage.CreateInMemory()",
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


def fetch_wheel(wheels: pathlib.Path) -> list:
    subprocess.run(
        [sys.executable, "-m", "pip", "download", "--only-binary=:all:", "--no-deps",
         "--dest", str(wheels), "usd-core==" + VERSION], check=True)
    return list(wheels.glob(WHEEL_PATTERN))


def reject_wheel(wheel: pathlib.Path) -> pathlib.Path:
    rejected = wheel.parent / "rejected"
    rejected.mkdir(exist_ok=True)
    target = rejected / f"{wheel.name}.{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
    os.replace(wheel, target)
    return target


with (BUILD / "openusd-prepare.lock").open("a+") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if DEST.exists() and state_valid(DEST, smoke=True):
        print("Prepared OpenUSD " + VERSION)
        raise SystemExit(0)

    wheels = BUILD / "usd-wheel"
    wheels.mkdir(parents=True, exist_ok=True)
    found = list(wheels.glob(WHEEL_PATTERN))
    if not found:
        found = fetch_wheel(wheels)
    if len(found) != 1:
        raise SystemExit(f"Expected one OpenUSD {VERSION} CPython 3.9 macOS wheel in {wheels}. Run with /usr/bin/python3.")
    wheel = found[0]
    digest = sha256_file(wheel)
    if digest != EXPECTED:
        # A truncated or tampered cached wheel is set aside and fetched again once.
        print(f"OpenUSD wheel checksum mismatch; moved {wheel} to {reject_wheel(wheel)}", file=sys.stderr)
        found = fetch_wheel(wheels)
        if len(found) != 1:
            raise SystemExit(f"Expected one OpenUSD {VERSION} CPython 3.9 macOS wheel in {wheels}.")
        wheel = found[0]
        digest = sha256_file(wheel)
        if digest != EXPECTED:
            raise SystemExit(f"OpenUSD wheel checksum mismatch after download; moved {wheel} to {reject_wheel(wheel)}")

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
            replace_directory(stage, RUNTIME)

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
