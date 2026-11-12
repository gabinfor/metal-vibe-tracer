"""Renders a Mitsuba scene with Metal Vibe Tracer's Mitsuba importer and with Mitsuba 3, and compares them.

Usage: build/mitsuba-venv/bin/python -I scripts/compare_scene.py SCENE.xml [--reference V3.xml] [--name N]
       [--scale S] [--samples N] [--mitsuba-samples N] [--strategy 0|1] [--metal-ms] [--out DIR]

The app imports SCENE.xml natively (a "mitsuba" shot through scripts/render_showcase.py); Mitsuba renders
--reference (default SCENE.xml), for a scene whose own file Mitsuba 3 cannot load (Water Caustic's 0.6 file).
Both renders use the reference's film size (times --scale) and path depth: the app's comes from its import of
SCENE.xml (max_depth - 1), which is checked against the reference's max_depth. RGB transport and linear radiance
without a denoiser; Mitsuba keeps the scene's own pixel filter and renders with its volpath integrator (see the
reference render below). A cached reference EXR is reused when its settings file (NAME-mitsuba.json, or
NAME-mitsuba-ms.json with --metal-ms) matches the run's file, a SHA-256 of that file's contents, size, depth,
sample count, integrator, Mitsuba version and --metal-ms, and is otherwise an error: delete it after changing the
scene (a file it includes is not hashed). When the reference's max_depth is -1 (unbounded) or above 65, the app
renders at its cap of 64 and the result says so ("note"). Writes metrics like scripts/compare_mitsuba.py, the
import report printed by the driver, and a side-by-side image (app | Mitsuba | relative block difference).
Differences come from the material mapping (MitsubaImporter.material: OpenPBR's energy-compensated rough lobes,
Beckmann as GGX, Lambertian instead of principledthin's Disney diffuse reflection) and from noise; see
REFERENCES.md BITTERLI2016 and scripts/mitsuba_probes.py for bisecting a difference.

--metal-ms (off by default) renders a different reference, NAME-mitsuba-ms.exr: every GGX roughconductor carries
the OpenPBR metal multiple-scattering lobe that the app's rough metals have and Mitsuba's lack, through
scripts/compare_mitsuba.py's openpbr_metal_ms (scale = specular_reflectance x Favg(F0)^2, a white F82 tint, F0
from eta and k), so a remaining difference is not the rough-metal energy compensation. It needs constant alpha,
eta, k and specular_reflectance on those conductors (scripts/mitsuba_probes.py variant MODE constant:... makes a
copy with a textured property replaced by a constant); Beckmann ones are left as they are and listed.
"""
import argparse
import ast
import hashlib
import itertools
import json
import math
import pathlib
import re
import subprocess
import time
import xml.etree.ElementTree as ET

import numpy as np
import mitsuba as mi
import drjit as dr

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('scene', type=pathlib.Path)
parser.add_argument('--reference', type=pathlib.Path, help='the file Mitsuba renders (default: SCENE)')
parser.add_argument('--name')
parser.add_argument('--scale', type=float, default=0.5)
parser.add_argument('--samples', type=int, default=1024)
parser.add_argument('--mitsuba-samples', type=int, default=4096)
parser.add_argument('--strategy', type=int, default=1, help='app strategy: 1 Standard MIS, 0 ReSTIR')
parser.add_argument('--metal-ms', action='store_true',
                    help="reference with the OpenPBR metal multiple-scattering lobe on GGX roughconductors (docstring)")
parser.add_argument('--out', type=pathlib.Path, default=ROOT / 'build/scene-compare')
args = parser.parse_args()
scene_file = args.scene.resolve()
reference_file = (args.reference or args.scene).resolve()
name = args.name or args.scene.parent.name
# Absolute: render_showcase.py resolves shot paths against the repository root.
out = (args.out / name).resolve()
out.mkdir(parents=True, exist_ok=True)

# The reference's film size and max_depth, with <default> values substituted (Mitsuba's defaults when absent:
# a 768 x 576 film, max_depth -1).
tree = ET.parse(reference_file)
root = tree.getroot()
defaults = {d.get('name'): d.get('value') for d in root.iter('default')}
resolve = lambda v: defaults.get(v[1:], v) if v.startswith('$') else v
film = root.find('sensor/film')
if film is None:
    raise SystemExit(f'compare_scene.py: {reference_file} has no sensor film')
size = {n: film.find(f"integer[@name='{n}']") for n in ('width', 'height')}
width = int(int(resolve(size['width'].get('value')) if size['width'] is not None else 768) * args.scale)
height = int(int(resolve(size['height'].get('value')) if size['height'] is not None else 576) * args.scale)
integrator = root.find('integrator')
depth_node = next((n for n in integrator.iter('integer') if n.get('name') == 'max_depth'), None) if integrator is not None else None
max_depth = int(resolve(depth_node.get('value'))) if depth_node is not None else -1
depth = max(1, min(64, max_depth - 1 if max_depth > 0 else 64))

# The app: width and height are explicit, since render_showcase.py gives every shot a size; the path depth is
# the importer's, read back from the driver's output.
shot = [{'name': f'{name}-vibe', 'mitsuba': str(scene_file), 'width': width, 'height': height, 'samples': args.samples,
         'raw': True, 'strategy': args.strategy, 'lightTransport': 0}]
(out / 'shot.json').write_text(json.dumps(shot))
run = subprocess.Popen(['python3', str(ROOT / 'scripts/render_showcase.py'), '--shots', str(out / 'shot.json'), '--out', str(out)],
                       stdout=subprocess.PIPE, text=True)
lines = []
for line in run.stdout:
    lines.append(line.rstrip('\n'))
    if line.startswith(f'{name}-vibe:'):
        print(line, end='', flush=True)
if run.wait() != 0:
    raise SystemExit('\n'.join(lines[-20:]) + '\ncompare_scene.py: the app render failed')
(out / 'app-output.txt').write_text('\n'.join(lines) + '\n')
imported = next(i for i, line in enumerate(lines) if line.startswith(f'{scene_file.name}: imported in'))
triangles = int(re.search(r'(\d+) triangles', lines[imported]).group(1))
materials = int(re.search(r'(\d+) MaterialX materials', lines[imported]).group(1))
report = [line[2:] for line in itertools.takewhile(lambda line: line.startswith('  '), lines[imported + 1:])]
final = next(re.search(r': (\d+)x(\d+), \d+ spp, (\d+) s, .* depth (\d+)$', line) for line in lines
             if line.startswith(f'{name}-vibe: ') and ' camera ' in line)
assert (int(final.group(1)), int(final.group(2))) == (width, height), final.group(0)
assert int(final.group(4)) == depth, f'app path depth {final.group(4)}, Mitsuba max_depth {max_depth}'
app_seconds = int(final.group(3))

# Mitsuba's unbounded depth, or one beyond the app's cap, passes the depth check at 64: say so in the result.
note = None
if max_depth < 0 or max_depth - 1 > 64:
    note = (f'Mitsuba max_depth {max_depth} ({"unbounded" if max_depth < 0 else "above 65"}); the app renders at its '
            f'cap of 64 bounces, so longer paths are missing from the app side')
    print(f'compare_scene.py: note: {note}', flush=True)

suffix = '-mitsuba-ms' if args.metal_ms else '-mitsuba'
reference = out / f'{name}{suffix}.exr'
settings = {'file': str(reference_file), 'sha256': hashlib.sha256(reference_file.read_bytes()).hexdigest(),
            'width': width, 'height': height, 'max_depth': max_depth, 'spp': args.mitsuba_samples,
            'integrator': 'volpath', 'variant': 'metal_ad_rgb', 'mitsuba': mi.__version__, 'metal_ms': args.metal_ms}
settings_file = out / f'{name}{suffix}.json'
mi.set_variant('metal_ad_rgb')


def register_openpbr_metal_ms():
    """Registers scripts/compare_mitsuba.py's openpbr_metal_ms (that script's metal_average_fresnel,
    metal_energy_tables, metal_complement and register_openpbr_metal_ms, executed without the rest of it, which
    parses its own arguments and renders) and returns its metal_average_fresnel."""
    wanted = {'metal_average_fresnel', 'metal_energy_tables', 'metal_complement', 'register_openpbr_metal_ms'}
    tree = ast.parse((ROOT / 'scripts/compare_mitsuba.py').read_text())
    body = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in wanted]
    assert {n.name for n in body} == wanted, 'compare_mitsuba.py no longer defines the metal lobe'
    namespace = {'ROOT': ROOT, 'np': np, 'mi': mi, 'dr': dr, 'math': math}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(ROOT / 'scripts/compare_mitsuba.py'), 'exec'), namespace)
    namespace['METAL_ENERGY'], namespace['METAL_AVERAGE_ENERGY'] = namespace['metal_energy_tables']()
    namespace['register_openpbr_metal_ms']()
    return namespace['metal_average_fresnel']


def wrap_rough_metals(root, average_fresnel):
    """Wraps each GGX roughconductor in openpbr_metal_ms, as compare_mitsuba.py's glossy() does, with
    scale = s_max x Favg(F0 s / s_max)^2 for specular_reflectance s and F0 the normal-incidence Fresnel of eta, k."""
    def value(node, name, default):
        e = next((c for c in node if c.get('name') == name), None)
        if e is None:
            return np.array(default, float)
        if e.tag not in ('float', 'rgb'):
            raise SystemExit(f'compare_scene.py: --metal-ms needs a constant {name} on every GGX roughconductor '
                             f'(a {e.tag} here); see scripts/mitsuba_probes.py variant MODE constant:...')
        v = [float(resolve(x)) for x in e.get('value').replace(',', ' ').split()]
        return np.array(v * 3 if len(v) == 1 else v, float)
    skipped = 0
    for parent in list(root.iter()):
        for i, b in enumerate(list(parent)):
            if b.tag != 'bsdf' or b.get('type') != 'roughconductor':
                continue
            if next((c.get('value') for c in b if c.get('name') == 'distribution'), 'beckmann') != 'ggx':
                skipped += 1
                continue
            if next((c.get('value') for c in b if c.get('name') == 'material'), 'none') != 'none':
                raise SystemExit('compare_scene.py: --metal-ms reads eta and k, not a named conductor material')
            alpha = float(value(b, 'alpha', [0.1])[0])
            eta, k, s = value(b, 'eta', [0, 0, 0]), value(b, 'k', [1, 1, 1]), value(b, 'specular_reflectance', [1, 1, 1])
            f0 = ((eta - 1) ** 2 + k ** 2) / ((eta + 1) ** 2 + k ** 2)
            scale = s.max() * average_fresnel(f0 * s / max(s.max(), 1e-9)) ** 2
            wrapper = ET.Element('bsdf', type='openpbr_metal_ms')
            if b.get('id'):
                wrapper.set('id', b.get('id'))
                del b.attrib['id']
            ET.SubElement(wrapper, 'float', name='alpha', value=str(alpha))
            ET.SubElement(wrapper, 'rgb', name='scale', value=', '.join(str(x) for x in scale))
            b.set('name', 'nested')
            parent.remove(b)
            wrapper.append(b)
            parent.insert(i, wrapper)
            print(f'compare_scene.py: --metal-ms: roughconductor alpha {alpha} gets the lobe at scale {scale.round(4).tolist()}')
    if skipped:
        print(f'compare_scene.py: --metal-ms: {skipped} Beckmann roughconductors left single-scattering')


if reference.exists():
    cached = json.loads(settings_file.read_text()) if settings_file.exists() else {}
    if {k: cached.get(k) for k in settings} != settings:
        raise SystemExit(f'compare_scene.py: {reference} was rendered with other settings ({settings_file}); delete it')
    mitsuba_seconds = cached.get('seconds')
else:
    # volpath, not path: for surfaces it is the same estimator, but Mitsuba 3.9.1's path integrator
    # renders a mask's directly lit reflection at opacity^2 (measured with scripts/mitsuba_probes.py;
    # volpath and the app give opacity x radiance). The film size and integrator are written into the XML,
    # since Mitsuba rejects parameters a file does not declare.
    for n in ('width', 'height'):
        if size[n] is None:
            size[n] = ET.SubElement(film, 'integer', name=n)
    size['width'].set('value', str(width))
    size['height'].set('value', str(height))
    if integrator is not None:
        root.remove(integrator)
    volpath = ET.Element('integrator', type='volpath')
    ET.SubElement(volpath, 'integer', name='max_depth', value=str(max_depth))
    root.insert(0, volpath)
    if args.metal_ms:
        wrap_rough_metals(root, register_openpbr_metal_ms())
    mi.file_resolver().prepend(str(reference_file.parent))
    start = time.time()
    scene = mi.load_string(ET.tostring(root, encoding='unicode'))
    passes, per = max(1, args.mitsuba_samples // 512), min(512, args.mitsuba_samples)
    total = sum(np.array(mi.render(scene, spp=per, seed=s), dtype=np.float64) for s in range(passes)) / passes
    mi.Bitmap(total.astype(np.float32)).write(str(reference))
    mitsuba_seconds = round(time.time() - start)
    settings_file.write_text(json.dumps({**settings, 'seconds': mitsuba_seconds}, indent=1))
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
          'mitsuba_samples': args.mitsuba_samples, 'strategy': args.strategy, 'vibe_seconds': app_seconds,
          'mitsuba_seconds': mitsuba_seconds,
          'mean_ratio_rgb': (vibe.mean(axis=(0, 1)) / ref.mean(axis=(0, 1))).round(4).tolist(),
          'block_rel_median': round(float(np.median(rel[valid])), 4),
          'block_rel_p90': round(float(np.percentile(rel[valid], 90)), 4),
          'triangles': triangles, 'materials': materials, 'import_report': report,
          'reference': reference.name, 'metal_ms': args.metal_ms, **({'note': note} if note else {})}
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
