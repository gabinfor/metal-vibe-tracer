#!/usr/bin/env python3
"""F6 acceptance gaps (R-107): wrong manifests, cached reruns, concurrent callers and
interrupted preparation, run on scratch copies like tests/Fix_build.py. The shared
build/ caches are only read through symlinks, never modified."""
import json
import os
import pathlib
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def check(condition, message):
    # Explicit failures still run under python -O / PYTHONOPTIMIZE.
    if not condition:
        sys.exit("FAIL: Fix_tests.py: " + str(message))


def scratch(directory, scripts):
    root = pathlib.Path(directory)
    (root / "scripts").mkdir()
    for name in ["buildsupport.py"] + scripts:
        shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
    return root


def start(arguments, **options):
    return subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **options)


def finish(process, label):
    output = process.communicate(timeout=600)[0]
    check(process.returncode == 0, label + ": " + output)
    return output


def check_oidn():
    match = re.search(r'"' + platform.machine() + r'": \(\s*"([^"]+)",\s*"([0-9a-f]{64})"',
                      (ROOT / "scripts/prepare_oidn.py").read_text())
    check(match, "pinned OIDN archive for this architecture")
    archive = (ROOT / "build/oidn-cache" / match.group(1)).resolve()
    if not archive.is_file():
        print("SKIP: OIDN preparation checks need the cached archive " + str(archive))
        return
    with tempfile.TemporaryDirectory(prefix="vibe-oidn-f6-") as directory:
        root = scratch(directory, ["prepare_oidn.py"])
        (root / "build/oidn-cache").mkdir(parents=True)
        (root / "build/oidn-cache" / archive.name).symlink_to(archive)
        script = [sys.executable, str(root / "scripts/prepare_oidn.py"), "--arch", platform.machine()]
        runtime = root / "build/OIDN"
        manifest = runtime / "VIBE_RUNTIME.json"
        # Concurrent callers on an empty cache: one prepares, the others reuse it.
        processes = [start(script) for _ in range(3)]
        for index, process in enumerate(processes):
            finish(process, "concurrent OIDN preparation %d" % index)
        state = json.loads(manifest.read_text())
        check(state["architecture"] == platform.machine(), "concurrent callers publish one valid runtime")
        check(not list((root / "build").glob("oidn-stage-*")) and not list((root / "build").glob(".OIDN-retired-*")),
              "concurrent preparation leaves no staging or retired directories")
        # A cached rerun reuses the runtime without republishing it.
        inode = runtime.stat().st_ino
        finish(start(script), "cached OIDN rerun")
        check(runtime.stat().st_ino == inode, "a valid cached runtime is reused")
        # A manifest for another OIDN version is not accepted.
        wrong = dict(state, version="0.0.0")
        manifest.write_text(json.dumps(wrong))
        finish(start(script), "OIDN wrong-version manifest")
        check(json.loads(manifest.read_text())["version"] == state["version"], "wrong-version manifest is replaced")
        # Publication is manifest-last: a runtime without its manifest is prepared again.
        manifest.unlink()
        finish(start(script), "OIDN missing manifest")
        check(manifest.is_file(), "a runtime missing its manifest is prepared again")
        # An interrupted preparation never leaves a partially published runtime.
        manifest.write_text(json.dumps(wrong))
        process = start(script)
        time.sleep(0.3)
        process.send_signal(signal.SIGKILL)
        process.communicate(timeout=60)
        survivor = json.loads(manifest.read_text()) if manifest.is_file() else None
        check(survivor is not None and survivor["version"] in (state["version"], "0.0.0"),
              "a killed preparation leaves the previous or the complete new runtime")
        finish(start(script), "OIDN preparation after interruption")
        check(json.loads(manifest.read_text())["version"] == state["version"], "preparation recovers after interruption")
    print("PASS: OIDN preparation with concurrent callers, cached rerun, wrong/missing manifest and interruption (F6)")


def check_usd():
    version = re.search(r'^VERSION = "([^"]+)"$', (ROOT / "scripts/prepare_usd.py").read_text(), re.M).group(1)
    wheels = sorted((ROOT / "build/usd-wheel").glob(f"usd_core-{version}-cp39-*.whl"))
    runtimes = sorted(path for path in (ROOT / "build").glob(f"OpenUSD-{version}-cp39-*") if " " not in path.name)
    if len(wheels) != 1 or len(runtimes) != 1:
        print("SKIP: OpenUSD preparation checks need the cached wheel and runtime")
        return
    wheel, runtime = wheels[0].resolve(), runtimes[0]
    with tempfile.TemporaryDirectory(prefix="vibe-usd-f6-") as directory:
        root = scratch(directory, ["prepare_usd.py", "usd_bridge.py"])
        build = root / "build"
        (build / "usd-wheel").mkdir(parents=True)
        (build / "usd-wheel" / wheel.name).symlink_to(wheel)
        (build / runtime.name).symlink_to(runtime.resolve(), target_is_directory=True)
        # A published runtime whose manifest names another version is rejected.
        wrong = build / "OpenUSD"
        (wrong / "pxr").mkdir(parents=True)
        state = json.loads((runtime / "VIBE_RUNTIME.json").read_text())
        (wrong / "VIBE_RUNTIME.json").write_text(json.dumps(dict(state, version="0.0")))
        for child in (runtime / "pxr").iterdir():
            (wrong / "pxr" / child.name).symlink_to(child.resolve())
        script = ["/usr/bin/python3", str(root / "scripts/prepare_usd.py")]
        environment = {**os.environ, "PIP_NO_INDEX": "1", "PIP_DISABLE_PIP_VERSION_CHECK": "1"}
        # Two concurrent callers: both succeed and publish the validated runtime.
        processes = [start(script, env=environment) for _ in range(2)]
        for index, process in enumerate(processes):
            finish(process, "concurrent OpenUSD preparation %d" % index)
        check(wrong.is_symlink() and json.loads((wrong / "VIBE_RUNTIME.json").read_text())["version"] == version,
              "a wrong-version runtime is replaced by the validated one")
        target = os.readlink(str(wrong))
        finish(start(script, env=environment), "cached OpenUSD rerun")
        check(os.readlink(str(wrong)) == target and (build / runtime.name).is_symlink(),
              "a valid cached OpenUSD runtime is reused offline and the shared runtime is untouched")
        check(not list(build.glob("openusd-stage-*")) and not list(build.glob(".OpenUSD-*")),
              "OpenUSD preparation leaves no staging, link or legacy directories")
    print("PASS: OpenUSD preparation with a wrong-version manifest, concurrent callers and cached rerun (F6)")


check_oidn()
check_usd()
