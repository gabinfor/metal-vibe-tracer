"""Converts a Mitsuba 3 scene (XML) into a USD stage the app imports (USDA with OpenPBR materials).

Usage: build/mitsuba-venv/bin/python -I scripts/mitsuba_to_usd.py SCENE.xml OUT.usda [--report FILE]

Docs: docs/SCENE_STORAGE_DESIGN.md (phase 4). Development tool, not bundled. Geometry is loaded by
Mitsuba itself (world space, its OBJ welding and normals), so a Mitsuba render of the same XML is a
reference for the app's render of the USD. Materials map to OpenPBR as follows (REFERENCES.md
MITSUBA3, GULBRANDSEN2014, OPENPBR):
  diffuse              base_color, specular_weight 0 (Lambertian)
  plastic/roughplastic base_color = diffuse_reflectance x r, r = Mitsuba's diffuse albedo over
                       rho (1 - its specular albedo) (plastic_ratio: internal scattering, nonlinear),
                       specular_ior = int_ior / ext_ior, specular_roughness = sqrt(alpha)
  conductor/rough...   base_metalness 1; base_color = F0 and specular_color = the 82-degree edge tint
                       (OpenPBR's F82-tint Fresnel), both from Mitsuba's own conductor Fresnel at the
                       named or given (eta, k); specular_reflectance -> specular_weight (a texture
                       multiplies base_color instead)
  dielectric/rough...  transmission_weight 1, specular_ior = int_ior / ext_ior, roughness sqrt(alpha)
  thindielectric       as dielectric (thin walls are not represented)
  twosided             its inner BSDF (the app's meshes are two-sided)
  bumpmap              its inner BSDF; the height texture becomes a tangent-space normal map
                       (bump_normal_map); normalmap passes its texture to geometry_normal
  mask                 geometry_opacity (the app renders it as coverage, like Mitsuba's mask)
  area emitter         emission_color x emission_luminance = radiance (one-sided, like Mitsuba's;
                       rectangles and disks keep Mitsuba's side under mirroring transforms)
Mitsuba ids are global, so BSDFs nested in others (e.g. inside a bumpmap) resolve by id.
Textures: bitmap files keep their path (sRGB unless raw); checkerboards are baked to PNG.
"""
import argparse
import json
import math
import os
import pathlib
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zlib

import numpy as np
import mitsuba as mi

mi.set_variant('scalar_rgb')
parser = argparse.ArgumentParser()
parser.add_argument('scene', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path)
parser.add_argument('--report', type=pathlib.Path)
args = parser.parse_args()
root_dir = args.scene.resolve().parent
report = []

# ------------------------------------------------------------------------------------------------
# XML: defaults, $variables, references and transforms.
tree = ET.parse(args.scene)
scene_xml = tree.getroot()
defaults = {d.get('name'): d.get('value') for d in scene_xml.iter('default')}


def value(text):
    return re.sub(r'\$(\w+)', lambda m: defaults.get(m.group(1), m.group(0)), text or '')


def floats(text):
    return [float(x) for x in re.split(r'[,\s]+', value(text).strip()) if x]


def prop(node, name):
    for child in node:
        if child.get('name') == name:
            return child
    return None


def transform(node):
    m = np.eye(4)
    if node is None:
        return m
    for op in node:
        if op.tag == 'matrix':
            m = np.array(floats(op.get('value'))).reshape(4, 4) @ m
        elif op.tag == 'translate':
            v = floats(op.get('value')) if op.get('value') else [float(value(op.get(k, '0'))) for k in 'xyz']
            t = np.eye(4); t[:3, 3] = v; m = t @ m
        elif op.tag == 'scale':
            v = floats(op.get('value')) if op.get('value') else [float(value(op.get(k, '1'))) for k in 'xyz']
            v = v * 3 if len(v) == 1 else v
            m = np.diag(v + [1]) @ m
        elif op.tag == 'rotate':
            axis = floats(op.get('value')) if op.get('value') else [float(value(op.get(k, '0'))) for k in 'xyz']
            angle = math.radians(float(value(op.get('angle'))))
            a = np.array(axis) / np.linalg.norm(axis)
            K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
            r = np.eye(4); r[:3, :3] = np.eye(3) + math.sin(angle) * K + (1 - math.cos(angle)) * K @ K
            m = r @ m
        elif op.tag == 'lookat':
            o, t, u = (np.array(floats(op.get(k))) for k in ('origin', 'target', 'up'))
            d = (t - o) / np.linalg.norm(t - o)
            left = np.cross(u, d); left /= np.linalg.norm(left)
            up = np.cross(d, left)
            l = np.eye(4); l[:3, 0], l[:3, 1], l[:3, 2], l[:3, 3] = left, up, d, o
            m = l @ m
        else:
            report.append(f'transform op {op.tag} unsupported')
    return m


# Mitsuba ids are global: a BSDF nested in another (e.g. the twosided BSDF inside a bumpmap) can be
# referenced on its own, and then renders without the wrapper.
definitions = {}
for child in scene_xml.iter():
    if child.tag in ('bsdf', 'texture') and child.get('id') and child.get('id') not in definitions:
        definitions[child.get('id')] = child


def resolve(node):
    return definitions[node.get('id')] if node.tag == 'ref' else node


# ------------------------------------------------------------------------------------------------
# Spectra, IORs and conductors through Mitsuba itself.
def rgb(node, default):
    if node is None:
        return list(default)
    if node.tag in ('rgb', 'spectrum'):
        v = floats(node.get('value'))
        return v * 3 if len(v) == 1 else v[:3]
    if node.tag == 'float':
        return [float(value(node.get('value')))] * 3
    return list(default)


def ior(node, name, default):
    p = prop(node, name)
    if p is None:
        return default
    raw = value(p.get('value'))
    try:
        return float(raw)
    except ValueError:
        b = mi.load_dict({'type': 'dielectric', name: raw, ('ext_ior' if name == 'int_ior' else 'int_ior'): 1.0})
        return float(mi.traverse(b)['eta']) if name == 'int_ior' else 1.0 / float(mi.traverse(b)['eta'])


def conductor_colors(node):
    """F0 and the OpenPBR 82-degree tint of a conductor, from Mitsuba's smooth conductor."""
    spec = {'type': 'conductor'}
    for key in ('material', 'eta', 'k'):
        p = prop(node, key)
        if p is not None:
            spec[key] = value(p.get('value')) if key == 'material' else {'type': 'rgb', 'value': rgb(p, [0, 0, 0])}
    if 'material' not in spec and 'eta' not in spec:
        spec['material'] = 'Cu'  # Mitsuba's default conductor
    b = mi.load_dict(spec)

    def reflectance(mu):
        si = mi.SurfaceInteraction3f()
        si.wi = mi.Vector3f(math.sqrt(max(0.0, 1 - mu * mu)), 0, mu)
        _, weight = b.sample(mi.BSDFContext(), si, 0.5, mi.Point2f(0.5, 0.5))
        return np.array([weight[0], weight[1], weight[2]], dtype=float)

    f0 = reflectance(1.0)
    mu = 1 / 7  # OpenPBR's F82 angle, cos 81.79 deg
    schlick = f0 + (1 - f0) * (1 - mu) ** 5
    tint = np.clip(reflectance(mu) / np.maximum(schlick, 1e-6), 0, 1)
    # specular_reflectance is applied by material() (specular_weight), not folded into F0.
    return (np.clip(f0, 0, 1)).tolist(), tint.tolist()


# ------------------------------------------------------------------------------------------------
# Textures.
textures_dir = args.output.parent / (args.output.stem + '-textures')


def png(path, pixels):
    h, w, _ = pixels.shape
    raw = b''.join(b'\x00' + pixels[y].tobytes() for y in range(h))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def to_srgb(c):
    c = np.clip(np.array(c, dtype=float), 0, 1)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * c ** (1 / 2.4) - 0.055)


def texture(node):
    """(file, colour space, uv scale) of a texture node, or None."""
    node = resolve(node)
    kind = node.get('type')
    to_uv = transform(prop(node, 'to_uv'))
    scale = [to_uv[0, 0], to_uv[1, 1]]
    if kind == 'bitmap':
        file = value(prop(node, 'filename').get('value'))
        raw = prop(node, 'raw')
        space = 'raw' if raw is not None and value(raw.get('value')) == 'true' else 'srgb_texture'
        return str((root_dir / file).resolve()), space, scale
    if kind == 'checkerboard':
        c0 = rgb(prop(node, 'color0'), [0.4] * 3)
        c1 = rgb(prop(node, 'color1'), [0.2] * 3)
        textures_dir.mkdir(parents=True, exist_ok=True)
        n = 256
        cells = (np.add.outer(np.arange(n) // (n // 2), np.arange(n) // (n // 2)) % 2).astype(bool)
        image = np.where(cells[..., None], to_srgb(c1), to_srgb(c0))
        path = textures_dir / f"checker-{abs(hash((tuple(c0), tuple(c1)))) % 10**8}.png"
        png(path, (image * 255 + 0.5).astype(np.uint8))
        report.append(f'checkerboard baked to {path.name} ({n} px, 8-bit sRGB)')
        return str(path), 'srgb_texture', scale
    report.append(f'texture {kind} unsupported; constant used')
    return None


def plastic_ratio(kind, eta, alpha, distribution, nonlinear, rho):
    """Mitsuba's plastic diffuse albedo / (rho (1 - specular albedo)), averaged over four incidences."""
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


def plastic_texture(tex, factor, name):
    """A nonlinear plastic's diffuse texture with rho' = rho r(rho) per texel and channel (sRGB PNG);
    r is measured at 17 reflectances (plastic_ratio) and interpolated."""
    file, space, scale = tex
    b = mi.Bitmap(file)
    a = np.array(b, dtype=np.float64)
    if a.ndim == 2:
        a = a[..., None]
    a = a[..., :3] if a.shape[2] >= 3 else np.repeat(a[..., :1], 3, 2)
    if b.component_format() == mi.Struct.Type.UInt8:
        a = a / 255.0
        if space == 'srgb_texture':
            a = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    grid = np.linspace(0, 1, 17)
    ratios = np.array([factor(max(r, 1e-3)) for r in grid])
    out = np.clip(a * np.interp(a, grid, ratios), 0, 1)
    textures_dir.mkdir(parents=True, exist_ok=True)
    path = textures_dir / f'{ident(name, set())}-{pathlib.Path(file).stem}-plastic.png'
    png(path, (to_srgb(out) * 255 + 0.5).astype(np.uint8))
    report.append(f'{name}: nonlinear plastic texture baked with its internal-scattering factor')
    return str(path), 'srgb_texture', scale


def colour_input(node, name, default):
    p = prop(node, name)
    if p is not None and p.tag in ('texture', 'ref'):
        t = texture(p)
        if t:
            return {'texture': t}
    return {'value': rgb(p, default)}


# ------------------------------------------------------------------------------------------------
# BSDF -> OpenPBR inputs.
def material(node, names):
    node = resolve(node)
    kind = node.get('type')
    inner = lambda: next(c for c in node if c.tag in ('bsdf', 'ref'))
    if kind == 'twosided':
        return material(inner(), names)
    if kind in ('bumpmap', 'normalmap'):
        m = material(inner(), names)
        tex = next((c for c in node if c.tag in ('texture', 'ref') and c is not inner()), None)
        t = texture(tex) if tex is not None else None
        if t is None:
            report.append(f'{names}: {kind} texture unsupported; dropped')
        elif kind == 'normalmap':
            # Mitsuba's normal map is tangent-space (dp/du, dp/dv, n), as the app's normalmap node.
            m['geometry_normal'] = {'normalmap': t[0]}
        else:
            scale = prop(node, 'scale')
            m['bump'] = {'texture': t, 'scale': float(value(scale.get('value'))) if scale is not None else 1.0}
        return m
    if kind == 'mask':
        # OpenPBR geometry_opacity: coverage, stochastic in both renderers.
        m = material(inner(), names)
        opacity = colour_input(node, 'opacity', [1, 1, 1])
        if 'texture' in opacity:
            m['geometry_opacity'] = {'texture': opacity['texture']}
        elif sum(opacity['value']) / 3 < 1:
            m['geometry_opacity'] = {'value': sum(opacity['value']) / 3}
        return m
    roughness = lambda: math.sqrt(float(value(prop(node, 'alpha').get('value')))) if prop(node, 'alpha') is not None else 0.1 ** 0.5
    if kind == 'diffuse':
        return {'base_color': colour_input(node, 'reflectance', [0.5] * 3), 'specular_weight': {'value': 0.0}}
    if kind in ('plastic', 'roughplastic'):
        eta = ior(node, 'int_ior', 1.49) / ior(node, 'ext_ior', 1.000277)
        # OpenPBR's coated base has diffuse albedo rho' (1 - E_spec(mu)) for incidence mu; Mitsuba's plastic
        # scatters inside its coating (rho / (eta^2 (1 - R_int x)), x = rho if nonlinear, else 1, times its
        # transmittance in and out, from roughness-dependent tables for roughplastic). rho' = rho r, with r
        # Mitsuba's diffuse albedo over rho (1 - its specular albedo), averaged over incidence (plastic_ratio).
        # Smooth plastics: r = (1 - Fdr_int) / (1 - Fdr_int x) analytically, which the probes confirm.
        nonlinear = prop(node, 'nonlinear') is not None and value(prop(node, 'nonlinear').get('value')) == 'true'
        alpha = float(value(prop(node, 'alpha').get('value'))) if kind == 'roughplastic' and prop(node, 'alpha') is not None else 0.1
        distribution = value(prop(node, 'distribution').get('value')) if prop(node, 'distribution') is not None else 'beckmann'
        def factor(rho):
            return plastic_ratio(kind, eta, alpha, distribution, nonlinear, rho)
        diffuse = colour_input(node, 'diffuse_reflectance', [0.5] * 3)
        if 'texture' in diffuse and nonlinear:
            # The factor depends on rho: the texture is baked per texel and channel (plastic_texture).
            base = {'texture': plastic_texture(diffuse['texture'], factor, names)}
        elif 'texture' in diffuse:
            base = {'texture': diffuse['texture'], 'tint': [factor(0.5)] * 3}  # constant for a linear plastic
        else:
            base = {'value': [min(1.0, c * factor(c)) for c in diffuse['value']]}
        return {'base_color': base, 'specular_ior': {'value': eta},
                'specular_roughness': {'value': roughness() if kind == 'roughplastic' else 0.0}}
    if kind in ('conductor', 'roughconductor'):
        f0, tint = conductor_colors(node)
        # specular_reflectance scales Mitsuba's whole Fresnel, grazing angles included; OpenPBR's
        # specular_weight scales the metal lobe the same way. A colour keeps its chroma in base_color.
        # A texture can only scale base_color (F0): base_color = texture x F0.
        tinted = colour_input(node, 'specular_reflectance', [1, 1, 1])
        # OpenPBR's metal Fresnel is Schlick from F0 with its 82-degree value tinted by specular_color.
        m = {'base_metalness': {'value': 1.0}, 'specular_roughness': {'value': roughness() if kind == 'roughconductor' else 0.0}}
        if min(tint) < 0.999:
            m['specular_color'] = {'value': tint}
        if 'texture' in tinted:
            m['base_color'] = {'texture': tinted['texture'], 'tint': f0}
        else:
            s = tinted['value']
            weight = min(1.0, max(s))
            m['base_color'] = {'value': [f * (c / weight if weight > 0 else 1) for f, c in zip(f0, s)]}
            if weight < 1:
                m['specular_weight'] = {'value': weight}
        return m
    if kind in ('dielectric', 'roughdielectric', 'thindielectric'):
        if kind == 'thindielectric':
            report.append(f'{names}: thindielectric converted to a solid dielectric')
        eta = ior(node, 'int_ior', 1.5046) / ior(node, 'ext_ior', 1.000277)
        return {'transmission_weight': {'value': 1.0}, 'base_color': {'value': [1, 1, 1]}, 'specular_ior': {'value': eta},
                'specular_roughness': {'value': roughness() if kind == 'roughdielectric' else 0.0}}
    report.append(f'{names}: BSDF {kind} unsupported; grey diffuse used')
    return {'base_color': {'value': [0.5] * 3}, 'specular_weight': {'value': 0.0}}


# ------------------------------------------------------------------------------------------------
# Shapes, loaded through Mitsuba (world-space vertices).
def unit_shape(kind, m):
    if kind == 'rectangle':
        p = np.array([[-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0]], float)
        uv = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], float)
        f = np.array([[0, 1, 2], [0, 2, 3]])
    elif kind == 'disk':
        n = 64
        a = np.linspace(0, 2 * math.pi, n, endpoint=False)
        p = np.vstack([[0, 0, 0], np.stack([np.cos(a), np.sin(a), np.zeros(n)], 1)])
        uv = np.vstack([[0.5, 0.5], np.stack([0.5 + 0.5 * np.cos(a), 0.5 + 0.5 * np.sin(a)], 1)])
        f = np.array([[0, 1 + i, 1 + (i + 1) % n] for i in range(n)])
    elif kind == 'cube':
        q = mi.load_dict({'type': 'cube'})
        t = mi.traverse(q)
        p = np.array(t['vertex_positions']).reshape(-1, 3); uv = np.array(t['vertex_texcoords']).reshape(-1, 2)
        f = np.array(t['faces']).reshape(-1, 3)
        return (np.c_[p, np.ones(len(p))] @ m.T)[:, :3], None, uv, f
    else:
        return None
    world = (np.c_[p, np.ones(len(p))] @ m.T)[:, :3]
    # Mitsuba orients rectangles and disks by the normal-transformed +z (one-sided emitters emit
    # along it); a mirroring transform reverses the triangles' winding, from which the app takes the
    # front face, so the winding is reversed back to agree with that normal.
    nrm = np.linalg.inv(m[:3, :3]).T @ np.array([0, 0, 1.0])
    nrm /= np.linalg.norm(nrm)
    if np.linalg.det(m[:3, :3]) < 0:
        f = f[:, ::-1]
    return world, np.tile(nrm, (len(p), 1)), uv, f


def load_shape(node):
    kind = node.get('type')
    m = transform(prop(node, 'to_world'))
    if kind in ('obj', 'ply', 'serialized'):
        spec = {'type': kind, 'filename': str(root_dir / value(prop(node, 'filename').get('value'))),
                'to_world': mi.ScalarTransform4f(m.tolist())}
        fn = prop(node, 'face_normals')
        if fn is not None:
            spec['face_normals'] = value(fn.get('value')) == 'true'
        t = mi.traverse(mi.load_dict(spec))
        p = np.array(t['vertex_positions']).reshape(-1, 3)
        n = np.array(t['vertex_normals']).reshape(-1, 3) if 'vertex_normals' in t and len(t['vertex_normals']) else None
        uv = np.array(t['vertex_texcoords']).reshape(-1, 2) if 'vertex_texcoords' in t and len(t['vertex_texcoords']) else None
        f = np.array(t['faces']).reshape(-1, 3)
        return p, n, uv, f
    shape = unit_shape(kind, m)
    if shape is None:
        report.append(f'shape {kind} unsupported; skipped')
    return shape


# ------------------------------------------------------------------------------------------------
# USDA writer.
def ident(text, used):
    base = re.sub(r'[^A-Za-z0-9_]', '_', text) or 'X'
    base = ('_' + base) if base[0].isdigit() else base
    name, k = base, 1
    while name in used:
        k += 1; name = f'{base}_{k}'
    used.add(name)
    return name


def arr(values, fmt):
    return '[' + ', '.join(fmt(v) for v in values) + ']'


out = ['#usda 1.0', '(', '    defaultPrim = "Scene"', '    metersPerUnit = 1', '    upAxis = "Y"', ')', '',
       'def Xform "Scene"', '{']
materials, shapes_out, used = {}, [], set()
mat_used = set()


def bump_normal_map(bump, p, uv, f, name):
    """Mitsuba's bumpmap as a tangent-space normal map (PNG).

    Mitsuba displaces by d = scale x h (h: the texture's luminance after sRGB decoding unless raw) and
    shades with n' ~ n - (d_u / |dp/du|) T_u - (d_v / |dp/dv|) T_v (bumpmap.cpp). With |dp/du| and |dp/dv|
    the area-weighted UV stretch of the first mesh using the material (one isotropic stretch per
    material, right-handed UVs), the normal map holds (-d_u / |dp/du|, +d_v / |dp/dv|, 1): the app's
    bitangent follows USD st, whose v runs opposite to Mitsuba's (texture rows run down Mitsuba's v).
    """
    file, space, tscale = bump['texture']
    b = mi.Bitmap(file)
    a = np.array(b, dtype=np.float64)
    if a.ndim == 2:
        a = a[..., None]
    if b.component_format() == mi.Struct.Type.UInt8:
        a = a / 255.0
        if space == 'srgb_texture':
            a = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    h = a[..., :3] @ np.array([0.2126, 0.7152, 0.0722]) if a.shape[2] >= 3 else a[..., 0]
    rows, cols = h.shape
    # Central differences per unit of Mitsuba (u, v), wrapping like the default repeat filter.
    du = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) / 2 * cols * tscale[0]
    dv = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) / 2 * rows * tscale[1]
    tri = p[f]; tuv = uv[f]
    e1, e2 = tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]
    d1, d2 = tuv[:, 1] - tuv[:, 0], tuv[:, 2] - tuv[:, 0]
    det = d1[:, 0] * d2[:, 1] - d2[:, 0] * d1[:, 1]
    ok = np.abs(det) > 1e-12
    dpdu = (e1[ok] * d2[ok, 1:2] - e2[ok] * d1[ok, 1:2]) / det[ok, None]
    dpdv = (e2[ok] * d1[ok, 0:1] - e1[ok] * d2[ok, 0:1]) / det[ok, None]
    area = np.linalg.norm(np.cross(e1[ok], e2[ok]), axis=1)
    lu = float(np.sum(np.linalg.norm(dpdu, axis=1) * area) / max(area.sum(), 1e-12))
    lv = float(np.sum(np.linalg.norm(dpdv, axis=1) * area) / max(area.sum(), 1e-12))
    n = np.stack([-bump['scale'] * du / max(lu, 1e-12), bump['scale'] * dv / max(lv, 1e-12), np.ones_like(h)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    textures_dir.mkdir(parents=True, exist_ok=True)
    path = textures_dir / f'{name}-bump-normal.png'
    png(path, (np.clip(n * 0.5 + 0.5, 0, 1) * 255 + 0.5).astype(np.uint8))
    report.append(f'{name}: bump map converted to a normal map (UV stretch {lu:.3g} x {lv:.3g})')
    return str(path)


def material_prim(key, node, emission, label, geometry=None):
    if key in materials:
        return materials[key]
    name = ident(label, mat_used)
    inputs = material(node, label) if node is not None else {'base_color': {'value': [0.5] * 3}, 'specular_weight': {'value': 0.0}}
    if 'bump' in inputs:
        bump = inputs.pop('bump')
        if geometry is not None and geometry[1] is not None:
            inputs['geometry_normal'] = {'normalmap': bump_normal_map(bump, geometry[0], geometry[1], geometry[2], name)}
        else:
            report.append(f'{name}: bump map dropped (its mesh has no UVs)')
    if emission is not None:
        scale = max(max(emission), 1e-12)
        inputs['emission_color'] = {'value': [c / scale for c in emission]}
        inputs['emission_luminance'] = {'value': scale}
    lines = [f'    def Material "{name}"', '    {',
             f'        token outputs:mtlx:surface.connect = </Scene/Materials/{name}/Surface.outputs:out>',
             '        def Shader "Surface"', '        {',
             '            uniform token info:id = "ND_open_pbr_surface_surfaceshader"']
    images = []
    normal_maps = []
    for key2, v in inputs.items():
        typ = 'color3f' if key2 in ('base_color', 'specular_color', 'emission_color') else 'float'
        if 'normalmap' in v:
            lines.append(f'            float3 inputs:{key2}.connect = </Scene/Materials/{name}/Tex_{key2}_map.outputs:out>')
            normal_maps.append((key2, v['normalmap']))
            continue
        if 'texture' in v:
            file, space, scale = v['texture']
            tex = f'Tex_{key2}'
            source = f'{tex}_tint' if 'tint' in v else tex
            lines.append(f'            {typ} inputs:{key2}.connect = </Scene/Materials/{name}/{source}.outputs:out>')
            images.append((tex, file, space, scale, v.get('tint')))
        elif typ == 'color3f':
            c = v['value']
            lines.append(f'            {typ} inputs:{key2} = ({c[0]:.9g}, {c[1]:.9g}, {c[2]:.9g})')
        else:
            lines.append(f'            {typ} inputs:{key2} = {v["value"]:.9g}')
    lines += ['            token outputs:out', '        }']
    for tex, file, space, scale, tint in images:
        if tint is not None:
            lines += [f'        def Shader "{tex}_tint"', '        {', '            uniform token info:id = "ND_multiply_color3"',
                      f'            color3f inputs:in1.connect = </Scene/Materials/{name}/{tex}.outputs:out>',
                      f'            color3f inputs:in2 = ({tint[0]:.9g}, {tint[1]:.9g}, {tint[2]:.9g})',
                      '            color3f outputs:out', '        }']
        channel = 'float' if tex == 'Tex_geometry_opacity' else 'color3'
        lines += [f'        def Shader "{tex}"', '        {', f'            uniform token info:id = "ND_image_{channel}"',
                  f'            asset inputs:file = @{file}@ (', f'                colorSpace = "{space}"', '            )']
        if scale != [1, 1]:
            lines += [f'            float2 inputs:texcoord.connect = </Scene/Materials/{name}/{tex}_uv.outputs:out>']
        lines += [f'            {"float" if channel == "float" else "color3f"} outputs:out', '        }']
        if scale != [1, 1]:
            lines += [f'        def Shader "{tex}_uv"', '        {', '            uniform token info:id = "ND_multiply_vector2"',
                      f'            float2 inputs:in1.connect = </Scene/Materials/{name}/{tex}_tc.outputs:out>',
                      f'            float2 inputs:in2 = ({scale[0]:.9g}, {scale[1]:.9g})', '            float2 outputs:out', '        }',
                      f'        def Shader "{tex}_tc"', '        {', '            uniform token info:id = "ND_texcoord_vector2"',
                      '            float2 outputs:out', '        }']
    for key2, file in normal_maps:
        lines += [f'        def Shader "Tex_{key2}_map"', '        {', '            uniform token info:id = "ND_normalmap"',
                  f'            float3 inputs:in.connect = </Scene/Materials/{name}/Tex_{key2}.outputs:out>',
                  '            float3 outputs:out', '        }',
                  f'        def Shader "Tex_{key2}"', '        {', '            uniform token info:id = "ND_image_vector3"',
                  f'            asset inputs:file = @{file}@ (', '                colorSpace = "raw"', '            )',
                  '            float3 outputs:out', '        }']
    lines.append('    }')
    materials[key] = (name, lines)
    return materials[key]


count = 0
for i, node in enumerate(scene_xml.iter('shape')):
    loaded = load_shape(node)
    if loaded is None:
        continue
    p, n, uv, f = loaded
    bsdf_node = next((c for c in node if c.tag in ('bsdf', 'ref') and (c.tag == 'bsdf' or c.get('id') in definitions)), None)
    emitter = next((c for c in node if c.tag == 'emitter'), None)
    emission = rgb(prop(emitter, 'radiance'), [1, 1, 1]) if emitter is not None and emitter.get('type') == 'area' else None
    label = (bsdf_node.get('id') if bsdf_node is not None and bsdf_node.get('id') else f'{node.get("type")}{i}')
    key = (bsdf_node.get('id') if bsdf_node is not None and bsdf_node.tag == 'ref' else f'shape{i}', tuple(emission) if emission else None)
    mname, _ = material_prim(key, bsdf_node, emission, label + ('_emitter' if emission else ''), (p, uv, f))
    name = ident(node.get('id') or f'{node.get("type")}{i}', used)
    count += len(f)
    lines = [f'    def Mesh "{name}"', '    {', '        uniform token subdivisionScheme = "none"',
             f'        int[] faceVertexCounts = {arr([3] * len(f), str)}',
             f'        int[] faceVertexIndices = {arr(f.reshape(-1).tolist(), str)}',
             f'        point3f[] points = {arr(p.tolist(), lambda v: f"({v[0]:.9g}, {v[1]:.9g}, {v[2]:.9g})")}',
             f'        rel material:binding = </Scene/Materials/{mname}>']
    if n is not None:
        lines += [f'        normal3f[] normals = {arr(n.tolist(), lambda v: f"({v[0]:.9g}, {v[1]:.9g}, {v[2]:.9g})")} (', '            interpolation = "vertex"', '        )']
    if uv is not None:
        # USD st has its origin at the bottom left; Mitsuba's at the top left.
        lines += [f'        texCoord2f[] primvars:st = {arr(uv.tolist(), lambda v: f"({v[0]:.9g}, {1 - v[1]:.9g})")} (', '            interpolation = "vertex"', '        )']
    lines += ['        uniform token[] apiSchemas = ["MaterialBindingAPI"]', '    }']
    shapes_out += lines

out += shapes_out
out += ['    def Scope "Materials"', '    {']
for _, (_, lines) in materials.items():
    out += ['    ' + l for l in lines]
out += ['    }']

# Camera: Mitsuba's camera looks along +z with x to the left; USD's along -z with x to the right.
sensor = next(scene_xml.iter('sensor'))
m = transform(prop(sensor, 'to_world')) @ np.diag([-1, 1, -1, 1])
film = sensor.find('film')
width = int(value(prop(film, 'width').get('value'))) if film is not None and prop(film, 'width') is not None else 768
height = int(value(prop(film, 'height').get('value'))) if film is not None and prop(film, 'height') is not None else 576
fov = float(value(prop(sensor, 'fov').get('value')))
axis = value(prop(sensor, 'fov_axis').get('value')) if prop(sensor, 'fov_axis') is not None else 'x'
aspect = width / height
tan_x = math.tan(math.radians(fov) / 2) if axis == 'x' else math.tan(math.radians(fov) / 2) * aspect
focal = 50.0
horizontal = 2 * focal * tan_x
out += ['    def Camera "Camera"', '    {', f'        float focalLength = {focal}',
        f'        float horizontalAperture = {horizontal:.9g}', f'        float verticalAperture = {horizontal / aspect:.9g}',
        '        float2 clippingRange = (0.001, 100000)',
        '        matrix4d xformOp:transform = ' + '(' + ', '.join('(' + ', '.join(f'{m[r][c]:.9g}' for r in range(4)) + ')' for c in range(4)) + ')',
        '        uniform token[] xformOpOrder = ["xformOp:transform"]', '    }', '}']
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text('\n'.join(out) + '\n')
summary = {'triangles': count, 'materials': len(materials), 'width': width, 'height': height,
           'vertical_fov': math.degrees(2 * math.atan(tan_x / aspect)), 'report': sorted(set(report))}
print(json.dumps(summary, indent=1))
if args.report:
    args.report.write_text(json.dumps(summary, indent=1))
