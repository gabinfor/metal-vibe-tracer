"""Renders a Mitsuba 3 scene with Mitsuba and its USD conversion with Metal Vibe Tracer, and compares them.

Usage: build/mitsuba-venv/bin/python -I scripts/compare_scene.py SCENE.xml [--name N] [--scale S]
       [--samples N] [--mitsuba-samples N] [--strategy 0|1] [--out DIR]

The USD comes from scripts/mitsuba_to_usd.py (run here). Both renders use the XML's resolution
(times --scale) and path depth (Mitsuba max_depth = app depth + 1), RGB transport, and linear
radiance without a denoiser; Mitsuba keeps the scene's own pixel filter and renders with its
volpath integrator (see the reference render below). A cached reference EXR is reused; delete it
after changing the integrator or the scene. Writes metrics like
scripts/compare_mitsuba.py and a side-by-side image (app | Mitsuba | relative block difference).
Differences come from the material mapping documented in mitsuba_to_usd.py (OpenPBR's
energy-compensated rough lobes, Beckmann as GGX, solid thin glass) and from noise; see
REFERENCES.md BITTERLI2016 and scripts/mitsuba_probes.py for bisecting a difference.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

import numpy as np
import mitsuba as mi

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('scene', type=pathlib.Path)
parser.add_argument('--name')
parser.add_argument('--scale', type=float, default=0.5)
parser.add_argument('--samples', type=int, default=1024)
parser.add_argument('--mitsuba-samples', type=int, default=4096)
parser.add_argument('--strategy', type=int, default=1, help='app strategy: 1 Standard MIS, 0 ReSTIR')
parser.add_argument('--out', type=pathlib.Path, default=ROOT / 'build/scene-compare')
args = parser.parse_args()
name = args.name or args.scene.parent.name
out = args.out / name
out.mkdir(parents=True, exist_ok=True)

defaults = {d.get('name'): d.get('value') for d in ET.parse(args.scene).getroot().iter('default')}
width = int(int(defaults.get('resx', 1024)) * args.scale)
height = int(int(defaults.get('resy', 1024)) * args.scale)
max_depth = int(defaults.get('max_depth', 65))
depth = max(1, min(64, max_depth - 1 if max_depth > 0 else 64))

usd = out / f'{name}.usda'
subprocess.run([sys.executable, '-I', str(ROOT / 'scripts/mitsuba_to_usd.py'), str(args.scene), str(usd),
                '--report', str(out / 'conversion.json')], check=True, stdout=subprocess.DEVNULL)
conversion = json.loads((out / 'conversion.json').read_text())

shot = [{'name': f'{name}-vibe', 'usd': str(usd), 'width': width, 'height': height, 'samples': args.samples,
         'raw': True, 'strategy': args.strategy, 'lightTransport': 0, 'depth': depth}]
(out / 'shot.json').write_text(json.dumps(shot))
subprocess.run(['python3', str(ROOT / 'scripts/render_showcase.py'), '--shots', str(out / 'shot.json'), '--out', str(out)],
               check=True, stdout=subprocess.DEVNULL)

reference = out / f'{name}-mitsuba.exr'
mi.set_variant('metal_ad_rgb')
if not reference.exists():
    # volpath, not path: for surfaces it is the same estimator, but Mitsuba 3.9.1's path integrator
    # renders a mask's directly lit reflection at opacity^2 (measured with scripts/mitsuba_probes.py;
    # volpath and the app give opacity x radiance).
    scene = mi.load_file(str(args.scene), resx=width, resy=height, max_depth=max_depth, integrator='volpath')
    passes, per = max(1, args.mitsuba_samples // 512), min(512, args.mitsuba_samples)
    total = sum(np.array(mi.render(scene, spp=per, seed=s), dtype=np.float64) for s in range(passes)) / passes
    mi.Bitmap(total.astype(np.float32)).write(str(reference))
ref = np.array(mi.Bitmap(str(reference)), dtype=np.float64)[..., :3]
vibe = np.array(mi.Bitmap(str(out / f'{name}-vibe.exr')), dtype=np.float64)[..., :3]
assert vibe.shape == ref.shape, (vibe.shape, ref.shape)

lum = lambda x: x @ np.array([0.2126, 0.7152, 0.0722])
k = 8
hb, wb = height // k, width // k
block = lambda x: lum(x)[:hb * k, :wb * k].reshape(hb, k, wb, k).mean(axis=(1, 3))
bv, br = block(vibe), block(ref)
valid = br > 0.02 * br.mean()
rel = np.abs(bv - br) / np.maximum(br, 1e-6)
result = {'scene': name, 'width': width, 'height': height, 'depth': depth, 'vibe_samples': args.samples,
          'mitsuba_samples': args.mitsuba_samples, 'strategy': args.strategy,
          'mean_ratio_rgb': (vibe.mean(axis=(0, 1)) / ref.mean(axis=(0, 1))).round(4).tolist(),
          'block_rel_median': round(float(np.median(rel[valid])), 4),
          'block_rel_p90': round(float(np.percentile(rel[valid], 90)), 4),
          'triangles': conversion['triangles'], 'conversion_report': conversion['report']}
(out / 'result.json').write_text(json.dumps(result, indent=1))
print(json.dumps(result))


def srgb(x, scale):
    x = np.clip(x * scale, 0, 1)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def heat(r):
    t = np.clip(r / 0.2, 0, 1)[..., None]
    stops = np.array([[0, 0, 0], [0.1, 0.2, 0.8], [0.8, 0.2, 0.6], [1, 0.6, 0.1], [1, 1, 1]])
    pos = t * (len(stops) - 1)
    i = np.clip(pos.astype(int), 0, len(stops) - 2)[..., 0]
    f = pos[..., 0] - i
    return stops[i] * (1 - f[..., None]) + stops[i + 1] * f[..., None]


scale = 0.6 / max(1e-6, float(np.percentile(lum(ref), 95)))
smooth = np.kron(np.where(valid, rel, 0), np.ones((k, k)))
smooth = np.pad(smooth, ((0, height - smooth.shape[0]), (0, width - smooth.shape[1])))
gap = np.ones((height, 8, 3))
sheet = np.concatenate([srgb(vibe, scale), gap, srgb(ref, scale), gap, heat(smooth)], axis=1)
mi.Bitmap(sheet.astype(np.float32), mi.Bitmap.PixelFormat.RGB).convert(
    mi.Bitmap.PixelFormat.RGB, mi.Struct.Type.UInt8, srgb_gamma=False).write(str(out / f'{name}-compare.png'))
