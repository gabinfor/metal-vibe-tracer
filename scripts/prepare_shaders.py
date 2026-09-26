#!/usr/bin/env python3
"""Preprocess the pinned OpenPBR MSL headers for Metal's runtime compiler."""
from pathlib import Path
import subprocess
import re
import sys
from buildsupport import atomic_write_text, build_directory
root = Path(__file__).resolve().parents[1]
# --output lets scripts/generate_metal_energy.py read the upstream-only variant
# without replacing the shared resource that build.sh and tests/verify.py bundle.
target = Path(sys.argv[sys.argv.index('--output') + 1]) if '--output' in sys.argv else \
    build_directory(root) / 'ShaderResources' / 'OpenPBR.metal'
# -C keeps the upstream per-file copyright and license comments in the shipped source.
result = subprocess.run(['xcrun', 'clang', '-E', '-P', '-C', '-x', 'c++',
    '-D__METAL_VERSION__=310', '-DOPENPBR_LANGUAGE_TARGET_MSL=1',
    str(root / 'Vendor/OpenPBR/openpbr.h')], check=True, capture_output=True, text=True)
source = result.stdout
adaptation = ''
if '--upstream-only' not in sys.argv:
    adaptation = (root / 'Shaders/MetalEnergy.metal').read_text()
    # Leave vendored sources intact. Replace only the two generated lookup bodies;
    # a changed upstream signature must fail explicitly rather than silently drift.
    for name, expression in [
        ('energy_complement', 'vibe_metal_energy(alpha, cos_theta)'),
        ('average_energy_complement', 'vibe_metal_average_energy(alpha)'),
    ]:
        pattern = r'(float openpbr_look_up_ideal_metal_' + name + r'\([^{}]+\)\s*)\{[^{}]*\}'
        source, count = re.subn(pattern, lambda m: m[1] + '{ return ' + expression + '; }', source)
        if count != 1:
            raise RuntimeError('Unexpected upstream metal lookup: ' + name)
atomic_write_text(target, '// Copyright 2026 Adobe. Apache-2.0; see bundled OpenPBR-LICENSE.\n'
    '// Modified by Metal Vibe Tracer: preprocessed from the pinned Vendor/OpenPBR headers for\n'
    '// Metal runtime compilation' + ('' if not adaptation else
    '; the two ideal-metal energy lookups now call Shaders/MetalEnergy.metal') + '.\n'
    '#include <metal_stdlib>\nusing namespace metal;\n' + adaptation + source)
print('Prepared pinned Adobe OpenPBR shader resource')
