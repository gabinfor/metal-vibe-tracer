#!/usr/bin/env python3
"""Check a staged app bundle before build.sh publishes it.

Runs the bundled helpers from cwd=/ with a minimal environment, so a bundle that only
works because of files next to the checkout is rejected.
Usage: check_bundle.py <MetalVibeTracer.app> <arch>
"""
import json
import pathlib
import platform
import subprocess
import sys

from buildsupport import file_table

app = pathlib.Path(sys.argv[1]).resolve()
arch = sys.argv[2]
contents = app / "Contents"
resources = contents / "Resources"
oidn = contents / "Frameworks/OIDN"
executable = contents / "MacOS/MetalVibeTracer"
environment = {"PATH": "/usr/bin:/bin", "HOME": "/tmp", "PYTHONNOUSERSITE": "1"}
problems = []

for path in [executable, contents / "Info.plist", resources / "OpenPBR.metal", resources / "usd_bridge.py",
             resources / "OpenUSD/VIBE_RUNTIME.json", resources / "OpenPBR-LICENSE",
             resources / "THIRD_PARTY_NOTICES.md", oidn / "VIBE_RUNTIME.json"]:
    if not path.is_file():
        problems.append(f"missing {path.relative_to(app)}")

# The bundle must be self-contained: no symlink may lead outside it.
for path in contents.rglob("*"):
    if path.is_symlink() and app not in path.resolve().parents:
        problems.append(f"{path.relative_to(app)} links outside the bundle")


def archs(path):
    result = subprocess.run(["/usr/bin/lipo", "-archs", str(path)], capture_output=True, text=True)
    return result.stdout.split() if result.returncode == 0 else []


if executable.is_file() and arch not in archs(executable):
    problems.append(f"executable lacks {arch}")

try:
    state = json.loads((oidn / "VIBE_RUNTIME.json").read_text())
    if state.get("architecture") != arch:
        problems.append(f"OIDN runtime is {state.get('architecture')}, executable is {arch}")
    if file_table(oidn, ("lib", "doc")) != state.get("files"):
        problems.append("OIDN runtime files differ from its manifest")
    for name, value in (state.get("files") or {}).items():
        if name.endswith(".dylib") and not value.startswith("link:") and arch not in archs(oidn / name):
            problems.append(f"{name} lacks {arch}")
except (OSError, ValueError, AttributeError) as error:
    problems.append(f"OIDN manifest unreadable: {error}")

if not problems:
    # The bridge imports the bundled OpenUSD at module load; --help then exits.
    bridge = subprocess.run(["/usr/bin/python3", "-I", str(resources / "usd_bridge.py"), "--help"],
                            cwd="/", env=environment, capture_output=True, text=True, timeout=60)
    if bridge.returncode != 0:
        problems.append("bundled usd_bridge.py failed from cwd=/: " + bridge.stderr.strip()[-400:])
    if platform.machine() == arch:
        loader = subprocess.run(["/usr/bin/python3", "-I", "-c", "import ctypes,sys;ctypes.CDLL(sys.argv[1])",
                                 str(oidn / "lib/libOpenImageDenoise.2.dylib")],
                                cwd="/", env=environment, capture_output=True, text=True, timeout=60)
        if loader.returncode != 0:
            problems.append("bundled OIDN failed to load from cwd=/: " + loader.stderr.strip()[-400:])

if problems:
    raise SystemExit("App bundle check failed:\n  " + "\n  ".join(problems))
print("Checked app bundle layout and bundled helpers")
