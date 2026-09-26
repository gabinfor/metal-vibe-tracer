#!/usr/bin/env python3
"""Offline checks for runtime preparation, run on scratch copies of the scripts.

Each check gets a temporary ROOT whose build/ caches are symlinks to the verified
repository caches; the scripts only read those, so the shared caches are never modified.
"""
import ctypes
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SUPPORT = ["buildsupport.py"]


def scratch(directory, scripts):
    root = pathlib.Path(directory)
    (root / "scripts").mkdir()
    for name in SUPPORT + scripts:
        shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
    return root


def run(arguments, **options):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=600, **options)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout + result.stderr


def check_oidn():
    match = re.search(r'"' + platform.machine() + r'": \(\s*"([^"]+)",\s*"([0-9a-f]{64})"',
                      (ROOT / "scripts/prepare_oidn.py").read_text())
    assert match, "pinned OIDN archive for this architecture"
    archive = (ROOT / "build/oidn-cache" / match.group(1)).resolve()
    if not archive.is_file():
        print("SKIP: OIDN preparation checks need the cached archive " + str(archive))
        return
    with tempfile.TemporaryDirectory(prefix="vibe-oidn-check-") as directory:
        root = scratch(directory, ["prepare_oidn.py"])
        (root / "build/oidn-cache").mkdir(parents=True)
        (root / "build/oidn-cache" / archive.name).symlink_to(archive)
        script = [sys.executable, str(root / "scripts/prepare_oidn.py"), "--arch", platform.machine()]
        run(script)
        runtime = root / "build/OIDN"
        manifest = json.loads((runtime / "VIBE_RUNTIME.json").read_text())
        for name in ["lib/libOpenImageDenoise_core.2.5.0.dylib", "lib/libOpenImageDenoise_device_metal.2.5.0.dylib",
                     "lib/libOpenImageDenoise_device_cpu.2.5.0.dylib", "lib/libtbb.12.18.dylib"]:
            assert name in manifest["files"], "manifest records " + name
        # A pruned runtime is detected on the fast path and prepared again.
        core = runtime / "lib/libOpenImageDenoise_core.2.5.0.dylib"
        core.unlink()
        run(script)
        assert core.is_file(), "missing OIDN core library is restored"
        # A truncated library is detected as well.
        with (runtime / "lib/libtbb.12.18.dylib").open("r+b") as library:
            library.truncate(4096)
        run(script)
        assert hashlib.sha256((runtime / "lib/libtbb.12.18.dylib").read_bytes()).hexdigest() == \
            manifest["files"]["lib/libtbb.12.18.dylib"], "truncated TBB library is restored"
        # A runtime recorded for another architecture is not accepted.
        state = json.loads((runtime / "VIBE_RUNTIME.json").read_text())
        state["architecture"] = "x86_64" if platform.machine() == "arm64" else "arm64"
        (runtime / "VIBE_RUNTIME.json").write_text(json.dumps(state))
        run(script)
        assert json.loads((runtime / "VIBE_RUNTIME.json").read_text())["architecture"] == platform.machine()
        assert (root / "build/oidn-cache" / archive.name).is_symlink(), "cached archive left untouched"
        assert not list((root / "build").glob("oidn-stage-*")), "staging directories are cleaned up"
        libc = ctypes.CDLL(None)
        assert libc.getxattr(os.fsencode(str(root / "build")), b"com.apple.fileprovider.ignore#P", None, 0, 0, 0) > 0, \
            "build/ is excluded from iCloud syncing"
    print("PASS: OIDN preparation rejects pruned, truncated and wrong-architecture runtimes")


def check_usd():
    version = re.search(r'^VERSION = "([^"]+)"$', (ROOT / "scripts/prepare_usd.py").read_text(), re.M).group(1)
    wheels = sorted((ROOT / "build/usd-wheel").glob(f"usd_core-{version}-cp39-*.whl"))
    runtimes = sorted(path for path in (ROOT / "build").glob(f"OpenUSD-{version}-cp39-*") if " " not in path.name)
    if len(wheels) != 1 or len(runtimes) != 1:
        print("SKIP: OpenUSD preparation checks need the cached wheel and runtime")
        return
    wheel, runtime = wheels[0].resolve(), runtimes[0]
    with tempfile.TemporaryDirectory(prefix="vibe-usd-check-") as directory:
        root = scratch(directory, ["prepare_usd.py", "usd_bridge.py"])
        build = root / "build"
        (build / "usd-wheel").mkdir(parents=True)
        (build / runtime.name).symlink_to(runtime.resolve(), target_is_directory=True)
        # A published runtime lacking a module the bridge imports (UsdLux) must be rejected.
        partial = build / "OpenUSD"
        (partial / "pxr").mkdir(parents=True)
        shutil.copy2(runtime / "VIBE_RUNTIME.json", partial / "VIBE_RUNTIME.json")
        for child in (runtime / "pxr").iterdir():
            if child.name != "UsdLux":
                (partial / "pxr" / child.name).symlink_to(child.resolve())
        # A corrupted cached wheel is set aside and fetched again (offline, from a local link).
        corrupt = build / "usd-wheel" / wheel.name
        corrupt.write_bytes(b"not a wheel")
        links = root / "links"
        links.mkdir()
        (links / wheel.name).symlink_to(wheel)
        environment = {**os.environ, "PIP_NO_INDEX": "1", "PIP_FIND_LINKS": str(links),
                       "PIP_DISABLE_PIP_VERSION_CHECK": "1"}
        output = run(["/usr/bin/python3", str(root / "scripts/prepare_usd.py")], env=environment)
        assert "checksum mismatch" in output and str(build / "usd-wheel" / "rejected") in output, output
        rejected = list((build / "usd-wheel" / "rejected").iterdir())
        assert len(rejected) == 1 and rejected[0].read_bytes() == b"not a wheel", "corrupt wheel moved aside"
        fetched = build / "usd-wheel" / wheel.name
        assert fetched.is_file() and not fetched.is_symlink(), "wheel fetched again"
        assert (build / "OpenUSD").is_symlink(), "incomplete runtime replaced by the validated one"
        assert (build / "OpenUSD/pxr/UsdLux/__init__.py").is_file()
        assert (build / runtime.name).is_symlink(), "shared runtime left untouched"
    print("PASS: OpenUSD preparation recovers from a corrupt wheel and rejects runtimes missing bridge modules")


def check_shaders():
    with tempfile.TemporaryDirectory(prefix="vibe-shader-check-") as directory:
        root = scratch(directory, ["prepare_shaders.py"])
        for name in ["Vendor", "Shaders"]:
            (root / name).symlink_to(ROOT / name, target_is_directory=True)
        upstream = root / "upstream.metal"
        run([sys.executable, str(root / "scripts/prepare_shaders.py"), "--upstream-only", "--output", str(upstream)])
        assert not (root / "build/ShaderResources/OpenPBR.metal").exists(), "upstream-only output stays private"
        assert "vibe_metal_energy" not in upstream.read_text()
        run([sys.executable, str(root / "scripts/prepare_shaders.py")])
        shipped = (root / "build/ShaderResources/OpenPBR.metal").read_text()
        assert "Modified by Metal Vibe Tracer" in shipped and "{ return vibe_metal_energy(alpha, cos_theta); }" in shipped
        headers = len(re.findall(r"Licensed under the Apache License", shipped))
        assert headers >= 10, f"upstream per-file license comments retained ({headers})"
        assert not list((root / "build/ShaderResources").glob("*.partial")), "atomic write leaves no temporary"
    print("PASS: shader preparation keeps upstream notices and never publishes the upstream-only variant")


check_oidn()
check_usd()
check_shaders()
