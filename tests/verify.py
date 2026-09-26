#!/usr/bin/env python3
"""Compile the app and run the actual Metal kernels without opening a window."""
from pathlib import Path
import subprocess
import sys
import tempfile
import platform
import os

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'scripts/prepare_shaders.py')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'scripts/prepare_usd.py')], check=True)
subprocess.run([sys.executable, str(root / 'scripts/prepare_oidn.py')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'tests/USDChecks.py')] + [a for a in sys.argv[1:] if a == '--require-reference'], check=True)
subprocess.run([sys.executable, str(root / 'scripts/prepare_oidn.py'), '--arch', platform.machine()], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'tests/USDChecks.py')], check=True)
subprocess.run([sys.executable, str(root / 'tests/Fix_build.py')], check=True)
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
    source += '\n' + (root / 'tests' / 'Fix_oidn-export.swift').read_text()
    source += '\n' + (root / 'tests' / 'MaterialXChecks.swift').read_text()
source += '\n' + (root / 'tests' / 'USDChecks.swift').read_text()
source += '\n' + (root / 'tests' / 'Fix_integration.swift').read_text()
source += '\n' + (root / 'tests' / 'Fix_lights.swift').read_text()
source += '\n' + (root / 'tests' / 'Fix_geometry.swift').read_text()
if '--studio-only' not in sys.argv and '--usd-only' not in sys.argv:
    source += '\n' + (root / 'tests' / 'Fix_bsdf-legacy.swift').read_text()
if '--usd-only' not in sys.argv:
    source += '\n' + (root / 'tests' / 'Fix_materialx.swift').read_text()
if '--studio-only' not in sys.argv and '--usd-only' not in sys.argv:
    source += '\n' + (root / 'tests' / 'Fix_integrator.swift').read_text()
if '--studio-only' not in sys.argv and '--usd-only' not in sys.argv:
    source += '\n' + (root / 'tests' / 'Fix_gpu-memory.swift').read_text()
    source += '\n' + (root / 'tests' / 'Fix_presentation.swift').read_text()
if '--usd-only' not in sys.argv:
    source += '\n' + (root / 'tests' / 'Fix_persistence.swift').read_text()
    source += '\n' + (root / 'tests' / 'Fix_frontend.swift').read_text()
if '--studio-only' not in sys.argv:
    source += '\n' + (root / 'tests' / 'Fix_usd.swift').read_text()
source += '\n' + (root / 'tests' / 'Fix_build.swift').read_text()
with tempfile.TemporaryDirectory(prefix='vibe-tracer-tests-') as directory:
    folder = Path(directory)
    swift = folder / 'main.swift'
    swift.write_text(source)
    binary = folder / 'GPUChecks'
    subprocess.run(['xcrun', 'swiftc', '-O', '-D', 'VIBE_TESTING', '-target', platform.machine() + '-apple-macosx26.0', '-module-cache-path', str(folder / 'cache'),
                    str(swift), '-o', str(binary)], check=True)
    sys.exit(subprocess.run([str(binary)] + [a for a in sys.argv[1:] if a == '--require-reference'], cwd=root).returncode)
    # Unbundled test binary: resources resolve under the explicit repository root only.
    sys.exit(subprocess.run([str(binary)], cwd=root, env={**os.environ, 'VIBE_TRACER_REPOSITORY': str(root)}).returncode)
