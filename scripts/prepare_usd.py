#!/usr/bin/env python3
"""Prepare the pinned, official OpenUSD wheel without modifying system Python."""
import hashlib, json, pathlib, subprocess, sys, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
VERSION='26.8'
DEST=ROOT/'build/OpenUSD'
EXPECTED='f5bd2691fb18461b600e9d106d0101a713851dfe3f7f06c59ae61704563bdf87'
if sys.version_info[:2]!=(3,9):raise SystemExit('OpenUSD bundle requires /usr/bin/python3 (CPython 3.9).')
if not (DEST/'pxr/Usd/__init__.py').exists():
    wheels=ROOT/'build/usd-wheel'; wheels.mkdir(parents=True,exist_ok=True)
    found=list(wheels.glob('usd_core-26.8-cp39-*.whl'))
    if not found:
        subprocess.run([sys.executable,'-m','pip','download','--only-binary=:all:','--no-deps','--dest',str(wheels),'usd-core=='+VERSION],check=True)
        found=list(wheels.glob('usd_core-26.8-cp39-*.whl'))
    if len(found)!=1: raise SystemExit('Expected the OpenUSD 26.8 CPython 3.9 macOS wheel. Run with /usr/bin/python3.')
    if hashlib.sha256(found[0].read_bytes()).hexdigest()!=EXPECTED:raise SystemExit("OpenUSD wheel checksum mismatch")
    DEST.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(found[0]) as archive: archive.extractall(DEST)
    (DEST/'VIBE_RUNTIME.json').write_text(json.dumps({'version':VERSION,'wheel':found[0].name,'sha256':hashlib.sha256(found[0].read_bytes()).hexdigest()},indent=2))
print('Prepared OpenUSD '+VERSION)
