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
                                           82-degree edge tint of Mitsuba's smooth conductor, without
                                           specular_reflectance.
  tests/fixtures/mitsuba/plastic-ratios.json
                                           Mitsuba's plastic diffuse albedo over rho (1 - its specular albedo),
                                           computed to convergence from Mitsuba's BSDF on a
                                           grid of IOR, alpha, distribution, nonlinear and reflectance;
                                           tests/Fix_mitsuba.swift checks MitsubaImporter.plasticRatio against
                                           them.

The scalar_rgb variant is used. The script stops unless Mitsuba is 3.9.1.
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
    """F0 and the OpenPBR 82-degree tint of a named conductor."""
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


GAUSS_LEGENDRE_4 = np.polynomial.legendre.leggauss(4)


def plastic_ratio(kind, eta, alpha, distribution, nonlinear, rho, n, segments):
    """Mitsuba's plastic diffuse albedo / (rho (1 - specular albedo)), averaged over incidence cosines 0.3, 0.5, 0.7
    and 0.9, computed to convergence.
    Specular albedo: the mean of Mitsuba's sampled weight for the specular component over an n x n midpoint grid
    (one sample for the smooth plastic's delta lobe). Diffuse albedo: 2 pi times the integral over mu_o of
    bsdf.eval for the diffuse component (which depends only on mu_o), by 4-point Gauss-Legendre on `segments`
    equal intervals of [0, 1]."""
    spec = {'type': kind, 'int_ior': eta, 'ext_ior': 1.0, 'nonlinear': nonlinear,
            'diffuse_reflectance': {'type': 'rgb', 'value': [rho] * 3}}
    if kind == 'roughplastic':
        spec.update(alpha=alpha, distribution=distribution)
    b = mi.load_dict(spec)
    specular = mi.BSDFContext(mi.TransportMode.Radiance, mi.BSDFFlags.All, 0)
    diffuse = mi.BSDFContext(mi.TransportMode.Radiance, mi.BSDFFlags.All, 1)
    grid = 1 if kind == 'plastic' else n
    ratios = []
    for mu in (0.3, 0.5, 0.7, 0.9):
        si = mi.SurfaceInteraction3f()
        si.wi = mi.Vector3f(math.sqrt(1 - mu * mu), 0, mu)
        total = 0.0
        for i in range(grid):
            u = (i + 0.5) / grid
            for j in range(grid):
                total += float(b.sample(specular, si, u, mi.Point2f(u, (j + 0.5) / grid))[1][0])
        specular_albedo = total / (grid * grid)
        integral = 0.0
        for k in range(segments):
            for x, w in zip(*GAUSS_LEGENDRE_4):
                m = (k + 0.5 + 0.5 * x) / segments
                integral += 0.5 * w / segments * float(b.eval(diffuse, si, mi.Vector3f(math.sqrt(1 - m * m), 0, m))[0])
        ratios.append(2 * math.pi * integral / (rho * (1 - specular_albedo)))
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

# Plastic ratios on the grid of the importer's tests, and at half the resolution to estimate their error.
N, SEGMENTS = 1024, 2048
rows = []
change = 0.0
for eta in (1.3, 1.49, 1.9):
    for alpha in (None, 0.01, 0.1, 0.3):
        for distribution in ((None,) if alpha is None else ('beckmann', 'ggx')):
            for nonlinear in (False, True):
                for rho in (0.05, 0.5, 0.95):
                    kind = 'plastic' if alpha is None else 'roughplastic'
                    ratio = plastic_ratio(kind, eta, alpha, distribution, nonlinear, rho, N, SEGMENTS)
                    coarse = plastic_ratio(kind, eta, alpha, distribution, nonlinear, rho, N // 2, SEGMENTS // 2)
                    change = max(change, abs(coarse / ratio - 1))
                    rows.append({'eta': eta, 'alpha': alpha, 'distribution': distribution,
                                 'nonlinear': nonlinear, 'rho': rho, 'ratio': ratio})
fixture = {'mitsuba': VERSION, 'variant': 'scalar_rgb',
           'method': f'Mitsuba diffuse albedo / (rho (1 - specular albedo)), averaged over incidence cosines 0.3, 0.5, '
                     f'0.7, 0.9 (converged): specular albedo '
                     f'from the sampled weight on a {N} x {N} midpoint grid (one sample for the smooth plastic), '
                     f'diffuse albedo by integrating bsdf.eval over mu_o with 4-point Gauss-Legendre on {SEGMENTS} '
                     f'intervals; int_ior = eta, ext_ior = 1; distribution null for the smooth plastic. '
                     f'At half that resolution the ratios differ by at most {change:.1e} (relative).',
           'rows': rows}
(ROOT / 'tests/fixtures/mitsuba/plastic-ratios.json').write_text(json.dumps(fixture, indent=1) + '\n')
print(f'Mitsuba {mi.__version__}: {len(iors)} IOR names, {len(conductors)} conductors, {len(rows)} plastic ratios '
      f'(half-resolution change {change:.1e})')
print('bk7', iors['bk7'], 'water', iors['water'], 'Au', conductors['Au'], 'none', conductors['none'])
