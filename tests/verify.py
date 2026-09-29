#!/usr/bin/env python3
"""Compile the app and run the actual Metal kernels without opening a window.
Usage: python3 tests/verify.py [--studio-only | --usd-only] [--require-reference]
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import platform

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness

FLAGS = {'--studio-only', '--usd-only', '--require-reference'}
unknown = [a for a in sys.argv[1:] if a not in FLAGS]
if unknown:
    raise SystemExit('verify.py: unknown argument(s) ' + ' '.join(unknown) + '; expected ' + ', '.join(sorted(FLAGS)))
if '--studio-only' in sys.argv and '--usd-only' in sys.argv:
    raise SystemExit('verify.py: --studio-only and --usd-only are exclusive')
mode = 'studio' if '--studio-only' in sys.argv else 'usd' if '--usd-only' in sys.argv else 'full'
reference = [a for a in sys.argv[1:] if a == '--require-reference']
ALL = {'full', 'studio', 'usd'}
# Appended in this order. 'helpers'/'controller' select the marked section of a file.
PARTS = [
    ('GPUChecks.swift', {'full'}), ('GPUChecks.swift:helpers', {'studio', 'usd'}),
    ('MaterialChecks.swift', {'full'}),
    ('StudioChecks.swift', {'full', 'studio'}), ('StudioChecks.swift:controller', {'usd'}),
    ('Fix_oidn-export.swift', {'full', 'studio'}),
    ('MaterialXChecks.swift', {'full', 'studio'}),
    ('USDChecks.swift', ALL),
    ('Fix_integration.swift', ALL), ('Fix_lights.swift', ALL), ('Fix_geometry.swift', ALL),
    ('Fix_bsdf-legacy.swift', {'full'}),
    ('Fix_materialx.swift', {'full', 'studio'}),
    ('Fix_integrator.swift', {'full'}),
    ('Fix_gpu-memory.swift', {'full'}), ('Fix_presentation.swift', {'full'}),
    ('Fix_persistence.swift', {'full', 'studio'}), ('Fix_frontend.swift', {'full', 'studio'}),
    ('Fix_project-format.swift', {'full', 'studio'}),
    ('Fix_usd.swift', {'full', 'usd'}), ('Fix_usd-pivot.swift', {'full', 'usd'}),
    ('Fix_tests.swift', {'full'}),
    ('Fix_build.swift', ALL), ('Fix_swift6.swift', ALL),
    ('Fix_renderer-followups.swift', {'full'}),
    ('Fix_shaderball-emission.swift', {'full'}),
    ('Fix_usd-lighting.swift', {'full', 'usd'}),
    ('Fix_accel.swift', ALL),
    ('Fix_compat-neighbors.swift', {'full'}),
]
# One GPU suite at a time per checkout; each run writes into its own output directory.
lock = harness.suite_lock()
root = harness.ROOT
output = harness.output_directory('verify')
environment = {**os.environ, harness.OUTPUT_VARIABLE: str(output), 'VIBE_TRACER_REPOSITORY': str(root)}
subprocess.run([sys.executable, str(root / 'scripts/prepare_shaders.py')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'scripts/prepare_usd.py')], check=True)
subprocess.run([sys.executable, str(root / 'scripts/prepare_oidn.py'), '--arch', platform.machine()], check=True)
# -E ignores PYTHONOPTIMIZE and friends, so assert-based helper checks cannot pass vacuously.
subprocess.run(['/usr/bin/python3', '-E', str(root / 'tests/USDChecks.py')] + reference, check=True, env=environment)
subprocess.run([sys.executable, '-E', str(root / 'tests/Fix_build.py')], check=True, env=environment)
subprocess.run([sys.executable, '-E', str(root / 'tests/Fix_tests.py')], check=True, env=environment)
source = harness.production_source()
for name, modes in PARTS:
    if mode not in modes:
        continue
    file, _, section = name.partition(':')
    text = {'helpers': harness.gpu_helpers, 'controller': harness.studio_controller}[section]() if section \
        else harness.test_file(file)
    source += '\n' + text
with tempfile.TemporaryDirectory(prefix='vibe-tracer-tests-') as directory:
    binary = harness.compile_swift(source, Path(directory), 'GPUChecks')
    # Unbundled test binary: resources resolve under the explicit repository root only.
    # A generous bound turns an unexpected hang into a failure.
    try:
        code = subprocess.run([str(binary)] + reference, cwd=root, env=environment, timeout=3600).returncode
    except subprocess.TimeoutExpired:
        raise SystemExit('FAIL: the GPU suite did not finish within an hour')
print(f'Test output: {output.relative_to(root)} (build/checks/latest)')
sys.exit(code)
