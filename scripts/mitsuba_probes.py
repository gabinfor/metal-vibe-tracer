"""Bisection and probe scenes for Mitsuba comparisons (scripts/compare_scene.py).

Usage:
  build/mitsuba-venv/bin/python -I scripts/mitsuba_probes.py variant SCENE.xml MODE
      Writes scene_<MODE>.xml beside SCENE.xml (relative paths keep resolving) and prints its path.
      MODE flat: every BSDF becomes a two-sided diffuse 0.5; drop:KIND: only BSDFs containing KIND
      (e.g. roughconductor) are flattened. Nested BSDF ids keep a flattened copy, since Mitsuba ids
      are global. A scene that matches when flattened has no transport or emitter error.
  build/mitsuba-venv/bin/python -I scripts/mitsuba_probes.py plate OUTDIR NAME front|back 'BSDF XML'
      A 1.2 x 1.2 plate with the given BSDF over a grey floor under a large area light.
  build/mitsuba-venv/bin/python -I scripts/mitsuba_probes.py glint OUTDIR NAME 'BSDF XML'
      The plate reflecting a small, bright disk light in its mirror direction.
Compare a written scene with: scripts/compare_scene.py SCENE --scale 1 --out build/mitsuba-probes/results.
Results of 2026-10-21 are in REFERENCES.md, BITTERLI2016. Development tool, not bundled.
"""
import pathlib
import sys
import xml.etree.ElementTree as ET


def variant(src, mode):
    src = pathlib.Path(src)
    tree = ET.parse(src); root = tree.getroot()
    nested = []

    def flat(b):
        for n in b.iter('bsdf'):
            if n is not b and n.get('id'):
                nested.append(n.get('id'))
        for c in list(b):
            b.remove(c)
        for k in list(b.attrib):
            if k != 'id':
                del b.attrib[k]
        b.set('type', 'twosided')
        inner = ET.SubElement(b, 'bsdf', type='diffuse')
        ET.SubElement(inner, 'rgb', name='reflectance', value='0.5, 0.5, 0.5')

    def kinds(b):
        return {b.get('type')} | {k for c in b if c.tag == 'bsdf' for k in kinds(c)}

    def visit(node, kind):
        for c in list(node):
            if c.tag == 'bsdf':
                if kind is None or kind in kinds(c):
                    flat(c)
            else:
                visit(c, kind)
    visit(root, mode[5:] if mode.startswith('drop:') else None)
    for i in nested:
        e = ET.Element('bsdf', id=i); flat(e); root.insert(0, e)
    out = src.with_name(f'scene_{mode.replace(":", "_")}.xml')
    tree.write(out)
    return out


HEAD = '''<scene version="3.0.0">
  <default name="resx" value="192"/><default name="resy" value="192"/><default name="max_depth" value="8"/><default name="integrator" value="path"/>
  <integrator type="$integrator"><integer name="max_depth" value="$max_depth"/></integrator>
  <sensor type="perspective"><float name="fov" value="40"/><string name="fov_axis" value="y"/>
    <transform name="to_world"><lookat origin="0, 1.2, 4" target="0, 0, 0" up="0, 1, 0"/></transform>
    <film type="hdrfilm"><integer name="width" value="$resx"/><integer name="height" value="$resy"/><rfilter type="box"/></film>
    <sampler type="independent"><integer name="sample_count" value="64"/></sampler></sensor>
  <bsdf type="twosided" id="grey"><bsdf type="diffuse"><rgb name="reflectance" value="0.5, 0.5, 0.5"/></bsdf></bsdf>
  <shape type="rectangle"><transform name="to_world"><rotate x="1" angle="-90"/><scale value="6"/><translate y="-1.3"/></transform><ref id="grey"/></shape>
'''


def probe(outdir, name, bsdf, side='front', glint=False):
    out = pathlib.Path(outdir) / name; out.mkdir(parents=True, exist_ok=True)
    rot = '' if side == 'front' else '<rotate y="1" angle="180"/>'
    # A mask cannot be nested in twosided (it transmits); write it as given, with the id added.
    probe_bsdf = (bsdf.replace('<bsdf type="mask"', '<bsdf type="mask" id="probe"', 1) if bsdf.lstrip().startswith('<bsdf type="mask"')
                  else f'<bsdf type="twosided" id="probe">{bsdf}</bsdf>')
    body = f'''  {probe_bsdf}
  <shape type="rectangle"><transform name="to_world">{rot}<scale value="1.2"/></transform><ref id="probe"/></shape>
'''
    if glint:
        body += '''  <shape type="disk"><transform name="to_world"><scale value="0.08"/><lookat origin="0.3, 1.0, 3.5" target="-0.3, 0, -0.5" up="0, 1, 0"/></transform>
    <emitter type="area"><rgb name="radiance" value="200, 200, 200"/></emitter></shape>
'''
    radiance = '0.5, 0.5, 0.5' if glint else '4, 4, 4'
    body += f'''  <shape type="rectangle"><transform name="to_world"><scale x="2.5" y="1.2"/><rotate x="1" angle="200"/><translate y="2.2" z="5"/></transform>
    <emitter type="area"><rgb name="radiance" value="{radiance}"/></emitter></shape>
</scene>'''
    (out / 'scene.xml').write_text(HEAD + body)
    return out / 'scene.xml'


if __name__ == '__main__':
    command = sys.argv[1]
    if command == 'variant':
        print(variant(sys.argv[2], sys.argv[3]))
    elif command == 'plate':
        print(probe(sys.argv[2], sys.argv[3], sys.argv[5], side=sys.argv[4]))
    elif command == 'glint':
        print(probe(sys.argv[2], sys.argv[3], sys.argv[4], glint=True))
    else:
        raise SystemExit(__doc__)
