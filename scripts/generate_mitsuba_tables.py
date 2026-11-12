"""Write the values the Mitsuba importer takes from Mitsuba 3.9.1: named IORs, named conductors and plastic ratios.

Usage: build/mitsuba-venv/bin/python -I scripts/generate_mitsuba_tables.py

Run by hand (Mitsuba is not available to the build or the tests); both outputs are checked in
(docs/MITSUBA_IMPORT_DESIGN.md section 5, REFERENCES.md MITSUBA3):

  Sources/MitsubaTables.swift              MitsubaTables.ior: every name Mitsuba's dielectric plugins accept
                                           (lookup_ior in include/mitsuba/render/ior.h, enumerated from the
                                           list Mitsuba prints for an unknown name) with the value Mitsuba
                                           uses. MitsubaTables.conductors: every material preset the
                                           conductor plugin accepts (each pair of data/ior/<name>.eta.spd and
                                           .k.spd files in the package, and "none"), with F0 and the OpenPBR
                                           82-degree edge tint as scripts/mitsuba_to_usd.py conductor_colors
                                           computes them, without specular_reflectance.
  tests/fixtures/mitsuba/plastic-ratios.json
                                           plastic ratios measured as scripts/mitsuba_to_usd.py plastic_ratio
                                           measures them, on a grid of IOR, alpha, distribution, nonlinear
                                           and reflectance; tests/Fix_mitsuba.swift checks
                                           MitsubaImporter.plasticRatio against them.

The scalar_rgb variant is used, as the converter does. The script stops unless Mitsuba is 3.9.1.
"""
import json
import math
import pathlib
import re

import numpy as np
import mitsuba as mi

VERSION = '3.9.1'
if mi.__version__ != VERSION:
    raise SystemExit(f'generate_mitsuba_tables.py: needs Mitsuba {VERSION}, found {mi.__version__}')
mi.set_variant('scalar_rgb')
ROOT = pathlib.Path(__file__).resolve().parents[1]


def ior_names():
    """The names lookup_ior accepts, from the list in Mitsuba's error message for an unknown name."""
    try:
        mi.load_dict({'type': 'dielectric', 'int_ior': 'no such material'})
    except Exception as error:
        listed = re.search(r'Valid choices are:(.*?)(?:\n|$)', str(error))
        if listed:
            return [name.strip() for name in listed.group(1).split(',')]
    raise SystemExit('generate_mitsuba_tables.py: Mitsuba did not list its IOR names')


def named_ior(name):
    return float(mi.traverse(mi.load_dict({'type': 'dielectric', 'int_ior': name, 'ext_ior': 1.0}))['eta'])


def conductor_names():
    folder = pathlib.Path(mi.__file__).parent / 'data' / 'ior'
    stems = {p.name[:-len('.eta.spd')] for p in folder.glob('*.eta.spd')}
    return sorted(s for s in stems if (folder / f'{s}.k.spd').exists()) + ['none']


def conductor_colors(material):
    """F0 and the OpenPBR 82-degree tint of a named conductor (scripts/mitsuba_to_usd.py conductor_colors)."""
    b = mi.load_dict({'type': 'conductor', 'material': material})

    def reflectance(mu):
        si = mi.SurfaceInteraction3f()
        si.wi = mi.Vector3f(math.sqrt(max(0.0, 1 - mu * mu)), 0, mu)
        _, weight = b.sample(mi.BSDFContext(), si, 0.5, mi.Point2f(0.5, 0.5))
        return np.array([weight[0], weight[1], weight[2]], dtype=float)

    f0 = reflectance(1.0)
    # AlSb's red eta and k convert to 0 in RGB, where Mitsuba's Fresnel is 0 / 0 at exactly normal incidence
    # (NaN) and 1 at every other angle: such a channel takes the value just off normal incidence.
    f0 = np.where(np.isnan(f0), reflectance(0.99999), f0)
    mu = 1 / 7
    schlick = f0 + (1 - f0) * (1 - mu) ** 5
    tint = np.clip(reflectance(mu) / np.maximum(schlick, 1e-6), 0, 1)
    return np.clip(f0, 0, 1).tolist(), tint.tolist()


def plastic_ratio(kind, eta, alpha, distribution, nonlinear, rho):
    """Mitsuba's plastic diffuse albedo / (rho (1 - specular albedo)), averaged over four incidences
    (scripts/mitsuba_to_usd.py plastic_ratio)."""
    spec = {'type': kind, 'int_ior': eta, 'ext_ior': 1.0, 'nonlinear': nonlinear,
            'diffuse_reflectance': {'type': 'rgb', 'value': [rho] * 3}}
    if kind == 'roughplastic':
        spec.update(alpha=alpha, distribution=distribution)
    b = mi.load_dict(spec)
    n = 32
    grid = [((i + 0.5) / n, (j + 0.5) / n) for i in range(n) for j in range(n)]
    ratios = []
    for mu in (0.3, 0.5, 0.7, 0.9):
        si = mi.SurfaceInteraction3f()
        si.wi = mi.Vector3f(math.sqrt(1 - mu * mu), 0, mu)
        albedo = []
        for component in (0, 1):  # specular, diffuse
            ctx = mi.BSDFContext(mi.TransportMode.Radiance, mi.BSDFFlags.All, component)
            total = 0.0
            for u, v in grid:
                _, w = b.sample(ctx, si, u, mi.Point2f(u, v))
                total += float(w[0])
            albedo.append(total / len(grid))
        ratios.append(albedo[1] / max(1e-6, rho * (1 - albedo[0])))
    return float(np.mean(ratios))


def f32(x):
    return str(np.float32(x))  # the shortest text that reads back as the same float32


def swift_vector(v):
    return 'SIMD3(' + ', '.join(f32(x) for x in v) + ')'


# Named IORs and conductors.
iors = {name: named_ior(name) for name in ior_names()}
conductors = {name: conductor_colors(name) for name in conductor_names()}
lines = [
    f'// Generated by scripts/generate_mitsuba_tables.py from Mitsuba {VERSION} (scalar_rgb); do not edit.',
    '// REFERENCES.md: MITSUBA3. ior: the names include/mitsuba/render/ior.h accepts, with the values Mitsuba uses;',
    '// conductors: the conductor plugin\'s material presets (data/ior) and "none", F0 and the OpenPBR 82-degree',
    '// edge tint clamp(F(1/7) / (F0 + (1 - F0)(1 - 1/7)^5), 0, 1) of Mitsuba\'s smooth conductor.',
    'enum MitsubaTables {',
    f'  static let mitsubaVersion = "{VERSION}"',
    '  static let ior: [String: Float] = [',
]
lines += [f'    "{name}": {f32(value)},' for name, value in iors.items()]
lines += ['  ]', '  static let conductors: [String: (f0: SIMD3<Float>, tint: SIMD3<Float>)] = [']
lines += [f'    "{name}": ({swift_vector(f0)}, {swift_vector(tint)}),' for name, (f0, tint) in conductors.items()]
lines += ['  ]', '}', '']
(ROOT / 'Sources/MitsubaTables.swift').write_text('\n'.join(lines))

# Plastic ratios on the grid of the importer's tests.
rows = []
for eta in (1.3, 1.49, 1.9):
    for alpha in (None, 0.01, 0.1, 0.3):
        for distribution in ((None,) if alpha is None else ('beckmann', 'ggx')):
            for nonlinear in (False, True):
                for rho in (0.05, 0.5, 0.95):
                    kind = 'plastic' if alpha is None else 'roughplastic'
                    ratio = plastic_ratio(kind, eta, alpha, distribution, nonlinear, rho)
                    rows.append({'eta': eta, 'alpha': alpha, 'distribution': distribution,
                                 'nonlinear': nonlinear, 'rho': rho, 'ratio': ratio})
fixture = {'mitsuba': VERSION, 'variant': 'scalar_rgb',
           'method': 'scripts/mitsuba_to_usd.py plastic_ratio: 32 x 32 BSDF samples per component at incidence '
                     'cosines 0.3, 0.5, 0.7, 0.9; int_ior = eta, ext_ior = 1; distribution null for the smooth plastic',
           'rows': rows}
(ROOT / 'tests/fixtures/mitsuba/plastic-ratios.json').write_text(json.dumps(fixture, indent=1) + '\n')
print(f'Mitsuba {mi.__version__}: {len(iors)} IOR names, {len(conductors)} conductors, {len(rows)} plastic ratios')
print('bk7', iors['bk7'], 'water', iors['water'], 'Au', conductors['Au'], 'none', conductors['none'])
