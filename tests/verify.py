#!/usr/bin/env python3
"""Compile the app and run the actual Metal kernels without opening a window."""
from pathlib import Path
import subprocess
import sys
import tempfile
import platform

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'scripts/prepare_shaders.py')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'scripts/prepare_usd.py')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'tests/USDChecks.py')], check=True)
source = (root / 'main.swift').read_text()
# Retain production definitions, replacing only the GUI entry point.
source = source.split('// 5. App Entry Point')[0]
source += '\n' + '\n'.join(p.read_text() for p in sorted((root / 'Sources').glob('*.swift')))
gpu_checks = (root / 'tests' / 'GPUChecks.swift').read_text()
if '--studio-only' in sys.argv or '--usd-only' in sys.argv:
    source += '\n' + gpu_checks.split('for scene in UInt32(0)...5')[0]
else:
    source += '\n' + gpu_checks
    source += '\n' + (root / 'tests' / 'MaterialChecks.swift').read_text()
if '--usd-only' in sys.argv:
    studio = (root / 'tests' / 'StudioChecks.swift').read_text()
    source += '\n' + 'let application=' + studio.split('let application=')[1].split('for page in')[0]
else:
    source += '\n' + (root / 'tests' / 'StudioChecks.swift').read_text()
    source += '\n' + (root / 'tests' / 'MaterialXChecks.swift').read_text()
source += '\n' + (root / 'tests' / 'USDChecks.swift').read_text()
with tempfile.TemporaryDirectory(prefix='vibe-tracer-tests-') as directory:
    folder = Path(directory)
    swift = folder / 'main.swift'
    swift.write_text(source)
    binary = folder / 'GPUChecks'
    subprocess.run(['xcrun', 'swiftc', '-O', '-target', platform.machine() + '-apple-macosx26.0', '-module-cache-path', str(folder / 'cache'),
                    str(swift), '-o', str(binary)], check=True)
    sys.exit(subprocess.run([str(binary)], cwd=root).returncode)
