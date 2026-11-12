#!/usr/bin/env python3
"""Compile the app and run the actual Metal kernels without opening a window.
Usage: python3 tests/verify.py [--studio-only | --usd-only | --only FILE ...] [--require-reference]

--only runs just the named test files (e.g. Fix_light-tree.swift), with the shared helpers and OpenUSD fixtures
their suite needs and their full-suite checks: the quick check while working on a change. The full suite gates
releases and changes to shared rendering paths (CONTRIBUTING.md).
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import platform

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness

FLAGS = {'--studio-only', '--usd-only', '--only', '--require-reference'}
arguments = sys.argv[1:]
only = []
if '--only' in arguments:
    start = arguments.index('--only') + 1
    end = next((i for i in range(start, len(arguments)) if arguments[i].startswith('--')), len(arguments))
    only, arguments = arguments[start:end], arguments[:start] + arguments[end:]
    if not only:
        raise SystemExit('verify.py: --only needs at least one test file')
unknown = [a for a in arguments if a not in FLAGS]
if unknown:
    raise SystemExit('verify.py: unknown argument(s) ' + ' '.join(unknown) + '; expected ' + ', '.join(sorted(FLAGS)))
if sum(f in arguments for f in ('--studio-only', '--usd-only', '--only')) > 1:
    raise SystemExit('verify.py: --studio-only, --usd-only and --only are exclusive')
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
    ('Fix_obj-materials.swift', {'full', 'studio'}),
    ('Fix_gltf.swift', {'full', 'studio'}),
    ('Fix_mitsuba.swift', {'full', 'studio'}),
    ('Fix_mitsuba-materials.swift', {'full', 'studio'}),
    ('Fix_caustics.swift', {'full', 'studio'}),
    ('Fix_example-scenes.swift', {'full', 'studio'}),
    ('Fix_scaling.swift', {'full', 'studio'}),
    ('Fix_usd.swift', {'full', 'usd'}), ('Fix_usd-pivot.swift', {'full', 'usd'}),
    ('Fix_tests.swift', {'full'}),
    ('Fix_build.swift', ALL), ('Fix_swift6.swift', ALL),
    ('Fix_renderer-followups.swift', {'full'}),
    ('Fix_shaderball-emission.swift', {'full'}),
    ('Fix_thin-translucency.swift', {'full'}),
    ('Fix_usd-lighting.swift', {'full', 'usd'}),
    ('Fix_accel.swift', ALL),
    ('Fix_compat-neighbors.swift', {'full'}),
    ('Fix_restir-pt.swift', {'full'}),
    ('Fix_splatting.swift', {'full'}),
    ('Fix_spmis.swift', {'full'}),
    ('Fix_restcv.swift', {'full'}),
    ('Fix_zsampling.swift', {'full'}),
    ('Fix_zsampler-blocks.swift', {'full'}),
    ('Fix_ui-modes.swift', {'full', 'studio'}),
    ('Fix_start-screen.swift', {'full', 'studio'}),
    ('Fix_spectral.swift', {'full', 'studio'}),
    ('Fix_spectral-mis.swift', {'full'}),
    ('Fix_volumes.swift', {'full'}),
    ('Fix_clamp.swift', {'full'}),
    ('Fix_veach-plates.swift', {'full'}),
    ('Fix_light-tree.swift', {'full'}),
]
if only:
    files = {name.partition(':')[0] for name, _ in PARTS}
    missing = [f for f in only if f not in files]
    if missing:
        raise SystemExit('verify.py: not a suite test file: ' + ' '.join(missing))
    # The base of the smallest suite that has every named file (the GPU helpers and the studio controller for
    # files of the OpenUSD suite, all of StudioChecks.swift for the Studio suite's), then the named files in suite
    # order, with their full-suite checks.
    # Files of the full suite only also use helpers from all of GPUChecks.swift and MaterialChecks.swift.
    named = [modes for name, modes in PARTS if name in only]
    usd, full = all('usd' in m for m in named), any(m == {'full'} for m in named)
    base = ['GPUChecks.swift', 'MaterialChecks.swift'] if full else ['GPUChecks.swift:helpers']
    base.append('StudioChecks.swift:controller' if usd else 'StudioChecks.swift')
    PARTS = [(name, ALL) for name in base] + \
        [(name, ALL) for name, _ in PARTS if ':' not in name and name in only and name not in base]
# One GPU suite at a time per checkout; each run writes into its own output directory.
lock = harness.suite_lock()
root = harness.ROOT
output = harness.output_directory('verify')
# VIBE_SUITE_MODE lets files shared by several suites skip their full-suite-only GPU checks.
environment = {**os.environ, harness.OUTPUT_VARIABLE: str(output), 'VIBE_TRACER_REPOSITORY': str(root), 'VIBE_SUITE_MODE': mode}
subprocess.run([sys.executable, str(root / 'scripts/prepare_shaders.py')], check=True)
subprocess.run([sys.executable, str(root / 'scripts/generate_spectral_tables.py')], check=True)
subprocess.run(['/usr/bin/python3', str(root / 'scripts/prepare_usd.py')], check=True)
subprocess.run([sys.executable, str(root / 'scripts/prepare_oidn.py'), '--arch', platform.machine()], check=True)
# -E ignores PYTHONOPTIMIZE and friends, so assert-based helper checks cannot pass vacuously.
# USDChecks.py also writes the OpenUSD fixtures the GPU files read, so --only runs keep it; the other
# offline checks belong to the suites.
subprocess.run(['/usr/bin/python3', '-E', str(root / 'tests/USDChecks.py')] + reference, check=True, env=environment)
if not only:
    subprocess.run([sys.executable, '-E', str(root / 'tests/Fix_build.py')], check=True, env=environment)
    subprocess.run([sys.executable, '-E', str(root / 'tests/Fix_tests.py')], check=True, env=environment)
    # Offline spectral-table checks (round trip, sampling, noise, reproducibility, float32 include).
    subprocess.run([sys.executable, '-E', str(root / 'tests/SpectralTables.py')], check=True, env=environment)
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
