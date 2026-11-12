# Mitsuba importer fixtures

Mesh files for the shape readers of `MitsubaImporter` (`tests/Fix_mitsuba.swift`), and plastic ratios for its materials (last item). Each mesh file holds the triangle (0, 0, 0), (1, 0, 0), (0, 1, 0) with normals +z and texture coordinates (0, 0.5), (1, 0.75), (0, 1) in Mitsuba's own convention, which the PLY and serialized readers return unchanged. The tests do not need Mitsuba; the OBJ files they read are written by the test.

- `tri-binary.ply`: written by Mitsuba 3.9.1 (`Mesh.write_ply`, binary little-endian, texture coordinates as `s t`).
- `tri.ply`: the same header with `format ascii 1.0` and the same values as text, derived from `tri-binary.ply` by the script, because Mitsuba writes only binary PLY.
- `tri.serialized`: **not written by Mitsuba**: 3.9.1 has no `.serialized` writer. The script builds the bytes from the layout in Mitsuba's `serialized` plugin documentation (version 4, a zlib stream per sub-mesh, an offset table and a count at the end of the file). Two sub-meshes: index 0 is the triangle in single precision with normals and texture coordinates; index 1 is the triangle moved to z = 5 in double precision without normals or texture coordinates. Mitsuba 3.9.1 loads both sub-meshes (`shape_index` 0 and 1) to the values above, which the script prints.
- `plastic-ratios.json`: Mitsuba 3.9.1's plastic ratios, the quantity `scripts/mitsuba_to_usd.py` `plastic_ratio` estimates with 32 x 32 BSDF samples, computed to convergence (the specular albedo from 1024 x 1024 samples, the diffuse albedo by integrating `bsdf.eval`; the file's `method` gives the estimated error), on a grid of IOR, alpha, distribution, `nonlinear` and reflectance, for `MitsubaImporter.plasticRatio`. Written, with `Sources/MitsubaTables.swift`, by `build/mitsuba-venv/bin/python -I scripts/generate_mitsuba_tables.py`, not by the script below.

Regenerate the mesh files from the repository root (the script is in this README so that the command is reproducible; save it as `make_fixtures.py` outside the repository):

```
build/mitsuba-venv/bin/python -I make_fixtures.py tests/fixtures/mitsuba
```

```python
# Usage: build/mitsuba-venv/bin/python -I make_fixtures.py tests/fixtures/mitsuba
import struct, sys, tempfile, zlib
import numpy as np
import mitsuba as mi
mi.set_variant('scalar_rgb')
out = sys.argv[1]

positions = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], np.float32)
normals = np.array([[0, 0, 1]] * 3, np.float32)
# Mitsuba's own texture-coordinate convention (what the PLY and serialized readers return unchanged).
uvs = np.array([[0, 0.5], [1, 0.75], [0, 1]], np.float32)

source = tempfile.mkdtemp() + '/source.ply'
header = ['ply', 'format ascii 1.0', 'element vertex 3'] + ['property float ' + n for n in 'x y z nx ny nz u v'.split()]
header += ['element face 1', 'property list uchar int vertex_indices', 'end_header']
with open(source, 'w') as f:
    f.write('\n'.join(header) + '\n')
    for p, n, uv in zip(positions, normals, uvs):
        f.write(' '.join(str(float(x)) for x in (*p, *n, *uv)) + '\n')
    f.write('3 0 1 2\n')
mesh = mi.load_dict({'type': 'ply', 'filename': source})
mesh.write_ply(out + '/tri-binary.ply')

# Mitsuba writes binary PLY only: the ASCII file carries the same header and the same values as text.
data = open(out + '/tri-binary.ply', 'rb').read()
end = data.index(b'end_header\n') + len(b'end_header\n')
header = data[:end].decode()
print(header)
assert 'binary_little_endian' in header
lines = [l for l in header.splitlines()]
props = [l.split()[-1] for l in lines if l.startswith('property') and 'list' not in l]
n = len(props)
vertex = np.frombuffer(data[end:end + 4 * n * 3], np.float32).reshape(3, n)
ascii_header = header.replace('binary_little_endian', 'ascii')
with open(out + '/tri.ply', 'w') as f:
    f.write(ascii_header)
    for row in vertex:
        f.write(' '.join(repr(float(x)) for x in row) + '\n')
    f.write('3 0 1 2\n')

# Mitsuba 3.9.1 cannot write .serialized: two sub-meshes laid out as documented in its serialized plugin.
def submesh(name, pos, nrm, uv, double):
    flags = (0x2000 if double else 0x1000) | (1 if nrm is not None else 0) | (2 if uv is not None else 0)
    t = np.float64 if double else np.float32
    body = struct.pack('<I', flags) + name.encode() + b'\0' + struct.pack('<QQ', len(pos), 1)
    for a in (pos, nrm, uv):
        if a is not None:
            body += a.astype(t).tobytes()
    body += np.array([0, 1, 2], '<u4').tobytes()
    return struct.pack('<HH', 0x041C, 4) + zlib.compress(body)

first = submesh('tri', positions, normals, uvs, False)
second = submesh('far', positions + [0, 0, 5], None, None, True)
offsets = [0, len(first)]
blob = first + second + b''.join(struct.pack('<Q', o) for o in offsets) + struct.pack('<I', 2)
open(out + '/tri.serialized', 'wb').write(blob)

# Cross-check every file with Mitsuba itself.
def load(kind, name, **extra):
    t = mi.traverse(mi.load_dict({'type': kind, 'filename': out + '/' + name, **extra}))
    return {k: np.array(t[k]) for k in ('vertex_positions', 'faces', 'vertex_texcoords', 'vertex_normals') if k in t}
for kind, name, extra in (('ply', 'tri.ply', {}), ('ply', 'tri-binary.ply', {}), ('serialized', 'tri.serialized', {}),
                          ('serialized', 'tri.serialized', {'shape_index': 1})):
    r = load(kind, name, **extra)
    print(name, extra, {k: v.round(3).tolist() for k, v in r.items()})
```
