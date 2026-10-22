"""Renders built-in scenes with Metal Vibe Tracer and Mitsuba 3, and compares their radiance.

Usage: build/mitsuba-venv/bin/python scripts/compare_mitsuba.py [--scenes NAME ...] [--samples N]
       [--mitsuba-samples N] [--skip-vibe] [--out DIR]

Setup (once): python3 -m venv build/mitsuba-venv && build/mitsuba-venv/bin/pip install mitsuba==3.9.1 numpy

Each scene below is the geometry of trace_scene in main.swift, rebuilt as a Mitsuba scene: the same
camera (CameraState conventions, vertical field of view, box pixel filter), Lambertian DIFFUSE
materials, smooth glass for DIELECTRIC, and conductors for GLOSSY (rough ones with the OpenPBR metal
multiple-scattering lobe added by a Python BSDF, openpbr_metal_ms). Metal Vibe Tracer exports raw
linear radiance (OpenEXR, no denoiser) through scripts/render_showcase.py; Mitsuba renders with
its Metal backend. Each configuration is compared on mean radiance per channel, relative MSE, and
region means, and a side-by-side image (Vibe | Mitsuba | relative difference) is written.

Known model differences are listed per scene in NOTES and printed with the results.
"""
import argparse
import copy
import json
import math
import subprocess
import sys
from pathlib import Path

import numpy as np
import mitsuba as mi
import drjit as dr

ROOT = Path(__file__).resolve().parents[1]

parser = argparse.ArgumentParser()
parser.add_argument('--scenes', nargs='*', default=[])
parser.add_argument('--samples', type=int, default=4096, help='Metal Vibe Tracer samples per pixel')
parser.add_argument('--mitsuba-samples', type=int, default=16384)
parser.add_argument('--skip-vibe', action='store_true', help='reuse existing Metal Vibe Tracer EXRs')
parser.add_argument('--out', type=Path, default=ROOT / 'build/mitsuba')
arguments = parser.parse_args()
mi.set_variant('metal_ad_rgb')


def T(*matrix):  # resolved per call: each variant has its own transform type
    return mi.ScalarTransform4f(*matrix)


# ---------------------------------------------------------------------------------------------
# Camera: CameraState.apply + makeUniforms (eye from yaw, pitch and distance around the target).
def camera(yaw, pitch, distance, fov, target, width, height):
    t = np.array(target, dtype=float)
    eye = t + distance * np.array([math.cos(pitch) * math.sin(yaw), math.sin(pitch),
                                   -math.cos(pitch) * math.cos(yaw)])
    return {
        'type': 'perspective', 'fov': fov, 'fov_axis': 'y',
        'to_world': T().look_at(origin=eye.tolist(), target=t.tolist(), up=[0, 1, 0]),
        'film': {'type': 'hdrfilm', 'width': width, 'height': height, 'pixel_format': 'rgb',
                 'rfilter': {'type': 'box'}},
        'sampler': {'type': 'independent'},
    }


def rgb(v):
    return {'type': 'rgb', 'value': list(v) if hasattr(v, '__len__') else [v] * 3}


def diffuse(albedo):
    return {'type': 'diffuse', 'reflectance': rgb(albedo)}


# intersect_quad(corner, u, v, normal): the parallelogram corner + [0,1]u + [0,1]v.
def quad(corner, u, v, normal, bsdf=None, emitter=None):
    c, u, v, n = (np.array(x, dtype=float) for x in (corner, u, v, normal))
    n = n / np.linalg.norm(n)
    center = c + 0.5 * (u + v)
    m = np.eye(4)
    m[:3, 0], m[:3, 1], m[:3, 2], m[:3, 3] = 0.5 * u, 0.5 * v, n, center
    shape = {'type': 'rectangle', 'to_world': T(m.tolist())}
    # The normal is M^-T z, which points along n whatever the handedness of (u, v, n).
    if bsdf:
        shape['bsdf'] = copy.deepcopy(bsdf)  # shared BSDF objects make Mitsuba merge shapes
    if emitter is not None:
        shape['emitter'] = {'type': 'area', 'radiance': rgb(emitter)}
    return shape


# intersect_box(center, half_size, yaw): world = R(yaw) local with x' = cos x - sin z (a rotation by
# -yaw about +y in Mitsuba's right-handed convention).
def box(center, half, yaw, bsdf):
    return {'type': 'cube', 'bsdf': copy.deepcopy(bsdf),
            'to_world': T().translate(list(center)).rotate([0, 1, 0], -math.degrees(yaw)).scale(list(half))}


def sphere(center, radius, bsdf=None, emitter=None):
    shape = {'type': 'sphere', 'center': list(center), 'radius': radius}
    if bsdf:
        shape['bsdf'] = copy.deepcopy(bsdf)  # shared BSDF objects make Mitsuba merge shapes
    if emitter is not None:
        shape['emitter'] = {'type': 'area', 'radiance': rgb(emitter)}
    return shape


GLASS = {'type': 'dielectric', 'int_ior': 1.52, 'ext_ior': 1.0}


# GLOSSY below roughness 0.02 is a delta mirror with Schlick Fresnel from F0 = colour; above, the
# OpenPBR metal with GGX alpha = roughness^2 (roughness clamped to 0.03). Mitsuba's conductors take a
# complex IOR, so F0 is mapped to (eta, k) with Gulbrandsen's artist-friendly metallic Fresnel and a
# white edge tint (Gulbrandsen 2014, JCGT 3(4)), which reproduces F0 at normal incidence and rises to
# 1 at grazing, like Schlick.
def gulbrandsen(f0):
    r = np.clip(np.array(f0, dtype=float), 0, 0.999)
    eta = (1 - r) / (1 + r)
    k = np.sqrt(np.maximum(0, (r * (eta + 1) ** 2 - (eta - 1) ** 2) / (1 - r)))
    return {'eta': rgb(eta.tolist()), 'k': rgb(k.tolist())}


def glossy(color, roughness):
    if roughness < 0.02:
        return {'type': 'conductor', **gulbrandsen(color)}
    alpha = max(0.03, roughness) ** 2
    single = {'type': 'roughconductor', 'distribution': 'ggx', 'alpha': alpha, **gulbrandsen(color)}
    return {'type': 'twosided', 'bsdf': {'type': 'openpbr_metal_ms', 'alpha': alpha, 'nested': single,
            'scale': rgb((metal_average_fresnel(color) ** 2).tolist())}}


# The OpenPBR metal adds Adobe's microfacet multiple-scattering lobe to the single-scattering GGX
# lobe (ADOBEOPENPBR: OpenPBR_MetalMicrofacetMultipleScatteringLobe, initialised in openpbr_bsdf.h
# with scale = Favg^2 for metalness 1 and specular weight 1):
#   f_ms(i, o) = scale min((1 - E(mu_i)) (1 - E(mu_o)) / (1 - E_avg), 1 / mu_o) / pi  (o: light side),
# active for alpha >= 0.04^2, with 1 - E the ideal-metal energy complement of the GGX lobe. Mitsuba's
# roughconductor has no such lobe; it lifts the roughness-0.45 Veach plate by 17%. The complement is
# read from the renderer's own table (Shaders/MetalEnergy.metal) with its lookup's interpolation.
def metal_average_fresnel(f0):  # openpbr_metal_average_fresnel_with_f82_tint with a white F82 tint
    r = np.clip(np.array(f0, dtype=float), 0, 1)
    return np.clip(r + (1 - r) / 21, 0, 1)


def metal_energy_tables():
    import re
    text = (ROOT / 'Shaders/MetalEnergy.metal').read_text()
    def array(name, count):
        body = re.search(r'constant float ' + name + r'\[' + str(count) + r'\] = \{(.*?)\};', text, re.S)[1]
        values = np.array([float(v.rstrip('f')) for v in body.replace('\n', '').split(',') if v.strip()])
        assert values.size == count, name
        return values
    return array('vibeMetalEnergy', 129 * 129).reshape(129, 129), array('vibeMetalAverageEnergy', 129)


METAL_ENERGY, METAL_AVERAGE_ENERGY = metal_energy_tables()


def metal_complement(alpha):
    """vibe_metal_energy at a fixed alpha (129 sqrt-cosine nodes) and vibe_metal_average_energy."""
    x = min(max(math.sqrt(alpha) * 128, 0), 128)
    ix = min(int(x), 127)
    f = x - ix
    return (METAL_ENERGY[ix] * (1 - f) + METAL_ENERGY[ix + 1] * f,
            METAL_AVERAGE_ENERGY[ix] * (1 - f) + METAL_AVERAGE_ENERGY[ix + 1] * f)


def register_openpbr_metal_ms():
    """Registers openpbr_metal_ms for the current variant (a Python BSDF subclasses that variant's BSDF)."""
    class OpenPBRMetalMS(mi.BSDF):
        """Single-scattering nested BSDF plus the OpenPBR metal multiple-scattering lobe (above)."""
        MS_PROBABILITY = 0.25

        def __init__(self, props):
            mi.BSDF.__init__(self, props)
            self.nested = props['nested']
            c = props['scale']  # an RGB colour; the srgb texture uplifts it in spectral variants
            self.scale = mi.load_dict({'type': 'srgb', 'color': [float(c[0]), float(c[1]), float(c[2])]})
            alpha = props['alpha']
            complement, average = metal_complement(alpha)
            self.active_ms = alpha >= 0.04 ** 2
            self.complement = mi.Float(complement.tolist())
            self.inv_average = 1.0 / max(average, 1e-12)
            flags = mi.BSDFFlags.GlossyReflection | mi.BSDFFlags.FrontSide
            self.m_components = [flags]
            self.m_flags = flags

        def energy_complement(self, cosine):
            y = dr.sqrt(dr.clip(cosine, 0, 1)) * 128
            iy = dr.minimum(mi.UInt32(y), 127)
            f = y - mi.Float(iy)
            return dr.lerp(dr.gather(mi.Float, self.complement, iy), dr.gather(mi.Float, self.complement, iy + 1), f)

        def ms_value(self, si, wo, active):
            cos_i, cos_o = mi.Frame3f.cos_theta(si.wi), mi.Frame3f.cos_theta(wo)
            valid = active & (cos_i > 0) & (cos_o > 0)
            factors = self.energy_complement(cos_i) * self.energy_complement(cos_o) * self.inv_average
            factors = dr.minimum(factors, dr.rcp(dr.maximum(cos_o, 1e-12)))
            value = self.scale.eval(si, valid) * (factors * dr.inv_pi * cos_o)
            return dr.select(valid, value, 0.0), dr.select(valid, cos_o * dr.inv_pi, 0.0)

        def eval_pdf(self, ctx, si, wo, active=True):
            value, pdf = self.nested.eval_pdf(ctx, si, wo, active)
            if not self.active_ms:
                return value, pdf
            ms, ms_pdf = self.ms_value(si, wo, active)
            q = self.MS_PROBABILITY
            return value + ms, (1 - q) * pdf + q * ms_pdf

        def eval(self, ctx, si, wo, active=True):
            return self.eval_pdf(ctx, si, wo, active)[0]

        def pdf(self, ctx, si, wo, active=True):
            return self.eval_pdf(ctx, si, wo, active)[1]

        def sample(self, ctx, si, sample1, sample2, active=True):
            if not self.active_ms:
                return self.nested.sample(ctx, si, sample1, sample2, active)
            q = self.MS_PROBABILITY
            bs, _ = self.nested.sample(ctx, si, sample1, sample2, active)
            diffuse = sample1 < q
            bs.wo = dr.select(diffuse, mi.warp.square_to_cosine_hemisphere(sample2), bs.wo)
            bs.sampled_type = mi.UInt32(+mi.BSDFFlags.GlossyReflection)
            bs.sampled_component = mi.UInt32(0)
            bs.eta = 1.0
            value, pdf = self.eval_pdf(ctx, si, bs.wo, active)
            bs.pdf = pdf
            ok = active & (pdf > 0) & (mi.Frame3f.cos_theta(bs.wo) > 0)
            return bs, dr.select(ok, value / dr.maximum(pdf, 1e-12), 0.0)

        def traverse(self, callback):
            self.nested.traverse(callback)

        def to_string(self):
            return 'OpenPBRMetalMS[]'

    mi.register_bsdf('openpbr_metal_ms', OpenPBRMetalMS)


WHITE, RED, GREEN = diffuse(0.73), diffuse([0.65, 0.05, 0.05]), diffuse([0.12, 0.45, 0.15])


def cornell_walls():
    return {
        'floor': quad([-1, -1, -1], [2, 0, 0], [0, 0, 2], [0, 1, 0], WHITE),
        'ceiling': quad([-1, 1, -1], [2, 0, 0], [0, 0, 2], [0, -1, 0], WHITE),
        'back': quad([1, 1, 1], [-2, 0, 0], [0, -2, 0], [0, 0, -1], WHITE),
        'red': quad([-1, 1, 1], [0, 0, -2], [0, -2, 0], [1, 0, 0], RED),
        'green': quad([1, 1, -1], [0, 0, 2], [0, -2, 0], [-1, 0, 0], GREEN),
    }


def scene_cornell():
    s = cornell_walls()
    s['light'] = quad([-0.25, 0.999, -0.25], [0.5, 0, 0], [0, 0, 0.5], [0, -1, 0], emitter=[18, 15, 10])
    s['tall'] = box([-0.33, -0.4, 0.35], [0.3, 0.6, 0.3], 0.32, WHITE)
    s['short'] = box([0.33, -0.7, -0.25], [0.3, 0.3, 0.3], -0.30, WHITE)
    return s


def scene_glass_mirror():
    s = cornell_walls()
    s['light'] = quad([-0.2, 0.999, -0.2], [0.4, 0, 0], [0, 0, 0.4], [0, -1, 0], emitter=[24, 20, 15])
    s['glass'] = sphere([-0.45, -0.55, -0.1], 0.45, GLASS)
    s['mirror'] = sphere([0.45, -0.55, 0.25], 0.45, glossy([0.95] * 3, 0.001))
    return s


def scene_veach():
    s = {'floor': quad([-10, -1, -10], [20, 0, 0], [0, 0, 20], [0, 1, 0],
                       {'type': 'twosided', 'bsdf': diffuse(0.2)})}
    xs, roughness = [-2.4, -0.8, 0.8, 2.4], [0.005, 0.04, 0.15, 0.45]
    for i in range(4):
        u = np.array([-1.2, 0, 0])
        v = np.array([0, -1.4 * math.sin(0.6), -1.4 * math.cos(0.6)])
        c = np.array([xs[i] - 0.6, -0.85, -0.5]) - u - v
        n = np.cross(u, v)
        plate = glossy([0.95, 0.92, 0.88], roughness[i])
        if plate['type'] == 'conductor':
            plate = {'type': 'twosided', 'bsdf': plate}
        s[f'plate{i}'] = quad(c, u, v, n, plate)
    for i, (r, e) in enumerate(zip([0.55, 0.18, 0.055, 0.016], [6, 45, 450, 4000])):
        s[f'light{i}'] = sphere([xs[i], 1.8, 1.2], r, emitter=[e] * 3)
    return s


# name: (scene index, builder, camera, image size, notes)
SCENES = {
    'cornell': (1, scene_cornell, dict(yaw=0.0, pitch=0.0, distance=3.4, fov=40, target=[0, 0, 0]), (512, 512),
                'Lambertian walls and boxes, one area light: both renderers solve the same integral.'),
    'glass-mirror': (3, scene_glass_mirror, dict(yaw=0.0, pitch=0.05, distance=3.0, fov=40, target=[0, -0.2, 0]),
                     (512, 512), 'Mirror: Schlick F0 0.95 (Vibe) vs Gulbrandsen conductor with F0 0.95 (Mitsuba).'),
    'veach-mis': (2, scene_veach, dict(yaw=0.0, pitch=0.38, distance=5.6, fov=38, target=[0, 0.3, 0.3]),
                  (768, 432), 'Plates: OpenPBR metal (Vibe) vs GGX Gulbrandsen conductor plus the OpenPBR metal multiple-scattering lobe (Mitsuba); the single-scattering Fresnel is Schlick vs Gulbrandsen. The camera\'s right is world -x: plate 3 (roughness 0.45) is on the image left.'),
}
# Metal Vibe Tracer configurations: (label, strategy, light transport, Mitsuba variant)
MODES = [('mis-rgb', 1, 0, 'metal_ad_rgb'), ('restir-rgb', 0, 0, 'metal_ad_rgb'),
         ('mis-spectral', 1, 1, 'metal_ad_spectral')]
DEPTH = 16  # Path depth: 1 is direct light only, so Mitsuba's max_depth is DEPTH + 1.

selected = {k: v for k, v in SCENES.items() if not arguments.scenes or k in arguments.scenes}
vibe_dir, mitsuba_dir, report_dir = (arguments.out / d for d in ('vibe', 'mitsuba', 'compare'))
for d in (vibe_dir, mitsuba_dir, report_dir):
    d.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------------------------
if not arguments.skip_vibe:
    shots = []
    for name, (index, _, cam, (w, h), _) in selected.items():
        for label, strategy, transport, _ in MODES:
            shots.append({'name': f'{name}-{label}', 'scene': index, 'width': w, 'height': h, 'raw': True,
                          'samples': arguments.samples, 'strategy': strategy, 'lightTransport': transport,
                          'depth': DEPTH, **cam})
    shot_file = arguments.out / 'vibe-shots.json'
    shot_file.write_text(json.dumps(shots, indent=1))
    subprocess.run(['python3', str(ROOT / 'scripts/render_showcase.py'), '--shots', str(shot_file),
                    '--out', str(vibe_dir)], check=True)


def render_mitsuba(name, variant):
    path = mitsuba_dir / f'{name}-{variant}.exr'
    if path.exists():
        return np.array(mi.Bitmap(str(path)), dtype=np.float64)[..., :3]
    mi.set_variant(variant)
    register_openpbr_metal_ms()
    index, build, cam, (w, h), _ = SCENES[name]
    scene = mi.load_dict({'type': 'scene', 'integrator': {'type': 'path', 'max_depth': DEPTH + 1},
                          'camera': camera(**cam, width=w, height=h), **build()}, optimize=False)
    passes, per_pass = max(1, arguments.mitsuba_samples // 1024), min(1024, arguments.mitsuba_samples)
    total = None
    for seed in range(passes):
        img = mi.render(scene, spp=per_pass, seed=seed)
        img = np.array(img, dtype=np.float64)
        total = img if total is None else total + img
    total /= passes
    mi.Bitmap(total.astype(np.float32)).write(str(path))
    return total


def to_srgb(x, scale):
    x = np.clip(x * scale, 0, 1)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def heat(rel):
    # 0 -> black, 0.1 (10 %) and above -> white, through blue, magenta and orange.
    t = np.clip(rel / 0.1, 0, 1)[..., None]
    stops = np.array([[0, 0, 0], [0.1, 0.2, 0.8], [0.8, 0.2, 0.6], [1, 0.6, 0.1], [1, 1, 1]])
    pos = t * (len(stops) - 1)
    i = np.clip(pos.astype(int), 0, len(stops) - 2)[..., 0]
    f = pos[..., 0] - i
    return stops[i] * (1 - f[..., None]) + stops[i + 1] * f[..., None]


results = []
for name, (index, _, cam, (w, h), note) in selected.items():
    for label, strategy, transport, variant in MODES:
        vibe = np.array(mi.Bitmap(str(vibe_dir / f'{name}-{label}.exr')), dtype=np.float64)[..., :3]
        ref = render_mitsuba(name, variant)
        assert vibe.shape == ref.shape, (vibe.shape, ref.shape)
        mean_v, mean_r = vibe.mean(axis=(0, 1)), ref.mean(axis=(0, 1))
        lum = lambda x: x @ np.array([0.2126, 0.7152, 0.0722])
        rel_mse = float(np.mean((lum(vibe) - lum(ref)) ** 2) / np.mean(lum(ref)) ** 2)
        # Relative difference of 9x9 block means, so per-pixel noise does not dominate.
        k = 9
        hb, wb = h // k, w // k
        block = lambda x: lum(x)[:hb * k, :wb * k].reshape(hb, k, wb, k).mean(axis=(1, 3))
        bv, br = block(vibe), block(ref)
        valid = br > 0.02 * br.mean()
        block_rel = np.abs(bv - br) / np.maximum(br, 1e-6)
        row = {'scene': name, 'mode': label, 'mitsuba': variant,
               'mean_ratio_rgb': (mean_v / mean_r).round(4).tolist(),
               'relative_mse': round(rel_mse, 5),
               'block_rel_median': round(float(np.median(block_rel[valid])), 4),
               'block_rel_p95': round(float(np.percentile(block_rel[valid], 95)), 4)}
        results.append(row)
        print(json.dumps(row))
        scale = 0.5 / max(1e-6, float(np.percentile(lum(ref), 90)))
        rel = np.abs(lum(vibe) - lum(ref)) / np.maximum(lum(ref), 0.05 * lum(ref).mean())
        smooth = np.kron(np.where(valid, block_rel, 0), np.ones((k, k)))
        smooth = np.pad(smooth, ((0, h - smooth.shape[0]), (0, w - smooth.shape[1])))
        gap = np.ones((h, 8, 3))
        sheet = np.concatenate([to_srgb(vibe, scale), gap, to_srgb(ref, scale), gap, heat(smooth)], axis=1)
        mi.Bitmap(sheet.astype(np.float32), mi.Bitmap.PixelFormat.RGB).convert(
            mi.Bitmap.PixelFormat.RGB, mi.Struct.Type.UInt8, srgb_gamma=False).write(
            str(report_dir / f'{name}-{label}.png'))

(report_dir / 'results.json').write_text(json.dumps({'results': results,
    'notes': {k: v[4] for k, v in selected.items()}, 'vibe_samples': arguments.samples,
    'mitsuba_samples': arguments.mitsuba_samples, 'mitsuba_version': mi.__version__}, indent=1))
for name in selected:
    print(f'{name}: {SCENES[name][4]}')
