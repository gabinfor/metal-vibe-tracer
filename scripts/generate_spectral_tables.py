#!/usr/bin/env python3
"""Generate the spectral-rendering tables into build/SpectralTables (CPython 3.9+, stdlib only).

Outputs, written atomically and regenerated only when the script, its pinned inputs or its
parameters change (see docs/SPECTRAL_DESIGN.md and REFERENCES.md: PETERS2019, FOURIERSRGB2019,
PETERSBLOG2025, CIEDATA):

  FourierSRGB256.bin   8-bit sRGB -> three bounded trigonometric moments (Fourier coefficients)
                       of a reflectance spectrum, 256^3 entries of 3 x uint16 (96 MiB + header).
  FourierSRGB86.bin    The exactly solved coarse grid behind it (codes 0, 3, ..., 255; float32),
                       for continuous inputs (material constants, 16-bit and float textures).
  SpectralTables.metal MSL include: CIE 1931 2-degree CMFs, the phase warp, XYZ -> linear sRGB,
                       normalized illuminant spectra, wavelength inverse CDFs, small accessors
                       and the m = 2 bounded-MESE reconstruction.
  SpectralTables.json  Manifest: parameters, input and output SHA-256, generation statistics.

The moments c = (c0, c1, c2) of each table entry reproduce the entry's sRGB colour under CIE D65
when the reflectance is reconstructed with the bounded MESE (Peters et al. 2019, Eqs. 6, 7, 10
and 11) on Peters' even XYZ phase warp, the reflected spectrum is integrated at 1 nm against the
CIE 1931 colour-matching functions, and XYZ is converted to linear sRGB. This is a local
re-implementation from the papers; only the 95-entry warp table is taken from the authors' BSD
code (Vendor/Spectral/Peters2019/XYZWarp.h, unmodified).
"""
import array
import cmath
import csv
import hashlib
import json
import math
import multiprocessing
import os
import pathlib
import struct
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from buildsupport import atomic_write, atomic_write_text, build_directory, locked, sha256_file  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor" / "Spectral"
FORMAT_VERSION = 1

# Pinned inputs (SHA-256 also published in each CIE metadata file; see Vendor/Spectral/UPSTREAM.md).
INPUTS = {
    "CIE/CIE_xyz_1931_2deg.csv": "fa663e3535a7e0763a745993a1f0a192eb0275ac46ad2d1befd7626841e713c1",
    "CIE/CIE_std_illum_D65.csv": "e76f210bffff3d552ef7113025da5f325d5dfec200dd4b878b1a2f3a507032cb",
    "CIE/CIE_std_illum_A_1nm.csv": "61ef23fe146b8b665c74706717ab28cec7db6c9022993490bdc71991f43cb59b",
    "CIE/CIE_illum_FLs_1nm.csv": "929ee966bf465fca2073ada8965afbc332d163f6f2cb54c710a6e193251ab0cc",
    "CIE/CIE_illum_HPs.csv": "035e09d62b27f4b1e362ff1ba99a50235f0d7886c2781c50d49851b6e4bb4552",
    "CIE/CIE_illum_LEDs_1nm.csv": "2a065526e1502f138d5b96aa8c9b337320e08667aac028ab5ad428bf1179a4b7",
    "Peters2019/XYZWarp.h": "7fcd86e29aac22f02260e6c3a651fd9f0110b5c9a0485f3eb50a626eb46312fe",
}

LAMBDA_MIN, LAMBDA_MAX = 360, 830           # CMF range; 471 samples at 1 nm
WAVELENGTHS = list(range(LAMBDA_MIN, LAMBDA_MAX + 1))
# sRGB primaries (IEC 61966-2-1); the white point is the computed XYZ of the CIE D65 spectrum.
SRGB_PRIMARIES = ((0.64, 0.33), (0.30, 0.60), (0.15, 0.06))
# Moment clamp c0 in [EPSILON, 1 - EPSILON] (the e.g. value of FOURIERSRGB2019, Appendix A); the
# solver clamps target channels to the same interval so that black and white stay reachable.
EPSILON = 1e-4
LUT_SIZE = 256
COARSE_STEP = 3                              # exact solves at codes 0, 3, ..., 255 (86^3 nodes)
MOMENT_NODES = 1024                          # midpoint rule for c_j = (1/pi) int g cos(j phi)
FIX_THRESHOLD = 0.35                         # 8-bit error above which an entry is solved exactly
SOLVER_TOLERANCE = 1e-10                     # max |linear sRGB - target|
ICDF_SEGMENTS = 1024                         # inverse CDF nodes: ICDF_SEGMENTS + 1 per illuminant
DEFENSIVE_FRACTION = 0.1                     # mixture weight of the illuminant-independent pdf
# Presets: (identifier, label, file or None for equal energy, column index in that file)
ILLUMINANTS = (
    ("E", "CIE illuminant E (equal energy)", None, 0),
    ("D65", "CIE standard illuminant D65", "CIE/CIE_std_illum_D65.csv", 1),
    ("A", "CIE standard illuminant A", "CIE/CIE_std_illum_A_1nm.csv", 1),
    ("FL11", "CIE illuminant FL11 (narrow-band fluorescent)", "CIE/CIE_illum_FLs_1nm.csv", 11),
    ("HP1", "CIE illuminant HP1 (standard high-pressure sodium)", "CIE/CIE_illum_HPs.csv", 1),
    ("LED-B3", "CIE illuminant LED-B3 (phosphor-type white LED)", "CIE/CIE_illum_LEDs_1nm.csv", 3),
)
PARAMETERS = {
    "format": FORMAT_VERSION, "lambda": [LAMBDA_MIN, LAMBDA_MAX], "epsilon": EPSILON,
    "lut": LUT_SIZE, "coarseStep": COARSE_STEP, "momentNodes": MOMENT_NODES,
    "fixThreshold": FIX_THRESHOLD, "solverTolerance": SOLVER_TOLERANCE,
    "icdfSegments": ICDF_SEGMENTS, "defensiveFraction": DEFENSIVE_FRACTION,
    "illuminants": [i[0] for i in ILLUMINANTS],
}
OUTPUTS = ("FourierSRGB256.bin", "FourierSRGB86.bin", "SpectralTables.metal")
PI = math.pi
MOMENT_SCALE = 1.0 / PI                      # |c1|, |c2| <= 1/pi for signals in [0, 1]


# ---------------------------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------------------------

def verify_inputs(vendor=VENDOR):
    for name, digest in INPUTS.items():
        actual = sha256_file(vendor / name)
        if actual != digest:
            raise SystemExit("generate_spectral_tables.py: %s has SHA-256 %s, expected %s" % (name, actual, digest))


def read_table(path):
    with open(path, newline="") as handle:
        return [[float(v) for v in row] for row in csv.reader(handle) if row]


def resample(rows, column):
    """Linear interpolation onto WAVELENGTHS with zero extrapolation (the CIE metadata methods)."""
    points = [(r[0], r[column]) for r in rows]
    out = []
    j = 0
    for lam in WAVELENGTHS:
        if lam < points[0][0] or lam > points[-1][0]:
            out.append(0.0)
            continue
        while points[j + 1][0] < lam:
            j += 1
        (x0, y0), (x1, y1) = points[j], points[j + 1]
        out.append(y0 + (y1 - y0) * (lam - x0) / (x1 - x0))
    return out


def parse_warp(path):
    text = pathlib.Path(path).read_text()
    start = text.index("pXYZWarpEven[] = {") + len("pXYZWarpEven[] = {")
    values = [float(v.strip().rstrip("f")) for v in text[start:text.index("}", start)].split(",")]
    if len(values) != 95:
        raise SystemExit("generate_spectral_tables.py: unexpected warp table length %d" % len(values))
    return values


def inverse3(m):
    (a, b, c), (d, e, f), (g, h, i) = m
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]


def apply3(m, v):
    return [m[r][0] * v[0] + m[r][1] * v[1] + m[r][2] * v[2] for r in range(3)]


class Data:
    """Colorimetric data at 1 nm over 360-830 nm, derived only from the pinned inputs."""

    def __init__(self, vendor=VENDOR):
        self.cmf = [tuple(r[1:4]) for r in read_table(vendor / "CIE/CIE_xyz_1931_2deg.csv")]
        assert len(self.cmf) == len(WAVELENGTHS)
        self.warp = parse_warp(vendor / "Peters2019/XYZWarp.h")
        self.illuminants = []
        for _, _, name, column in ILLUMINANTS:
            spd = [1.0] * len(WAVELENGTHS) if name is None else resample(read_table(vendor / name), column)
            y = sum(s * c[1] for s, c in zip(spd, self.cmf))
            self.illuminants.append([s / y for s in spd])   # luminance Y = 1 (1 nm sums)
        d65 = self.illuminants[1]
        white = [sum(s * c[k] for s, c in zip(d65, self.cmf)) for k in range(3)]
        primaries = [[x / y for x, y in SRGB_PRIMARIES], [1.0, 1.0, 1.0],
                     [(1 - x - y) / y for x, y in SRGB_PRIMARIES]]
        scale = apply3(inverse3(primaries), white)
        self.rgb_to_xyz = [[primaries[r][k] * scale[k] for k in range(3)] for r in range(3)]
        self.xyz_to_rgb = inverse3(self.rgb_to_xyz)
        self.white = white
        # Reflectance -> linear sRGB under D65: rgb_k = sum_lambda W_k(lambda) g(lambda).
        self.weights = [[0.0] * len(WAVELENGTHS) for _ in range(3)]
        for i, c in enumerate(self.cmf):
            rgb = apply3(self.xyz_to_rgb, c)
            for k in range(3):
                self.weights[k][i] = rgb[k] * d65[i]
        self.phases = [self.phase(lam) for lam in WAVELENGTHS]
        self.cos1 = [2.0 * math.cos(p) for p in self.phases]
        self.cos2 = [2.0 * math.cos(2.0 * p) for p in self.phases]

    def phase(self, lam):
        """Peters' even XYZ warp: piecewise linear in 5 nm steps (XYZWarp.h applyXYZWarpEven)."""
        t = (lam - 360.0) * 0.2
        i = min(max(int(math.floor(t)), 0), 93)
        f = t - i
        return self.warp[i] * (1.0 - f) + self.warp[i + 1] * f

    def srgb_cmf_l1(self):
        """|r| + |g| + |b| of the linear-sRGB colour-matching functions at 1 nm."""
        return [sum(abs(v) for v in apply3(self.xyz_to_rgb, c)) for c in self.cmf]


# ---------------------------------------------------------------------------------------------
# Bounded MESE for three real moments (PETERS2019 Sec. 3; FOURIERSRGB2019 Sec. 2)
# ---------------------------------------------------------------------------------------------

def lagrange3(c0, c1, c2):
    """Real Lagrange multipliers (L0, L1, L2) of the bounded MESE, or None for invalid moments.

    Eq. 6 and 7 map the bounded moments to exponential moments gamma, Levinson's recursion
    (FOURIERSRGB2019 Alg. 1) gives q = C(gamma)^-1 e0 and Eq. 10 the multipliers. For an even
    (mirrored) signal all multipliers are real; the reflectance is Eq. 11:
    g(phi) = atan(L0 + 2 L1 cos(phi) + 2 L2 cos(2 phi)) / pi + 1/2.
    """
    if not (0.0 < c0 < 1.0):
        return None
    g0p = complex(math.sin(PI * c0), -math.cos(PI * c0)) / (4.0 * PI)   # exp(pi i (c0 - 1/2)) / 4pi
    g0 = 2.0 * g0p.real
    g1 = 2j * PI * g0p * c1
    g2 = 1j * PI * (2.0 * g0p * c2 + g1 * c1)
    q0 = 1.0 / g0
    u1 = q0 * g1
    d1 = 1.0 - abs(u1) ** 2
    if d1 <= 0.0:
        return None
    a0, a1 = q0 / d1, -u1 * q0 / d1
    u2 = a0 * g2 + a1 * g1
    d2 = 1.0 - abs(u2) ** 2
    if d2 <= 0.0:
        return None
    q = (2.0 * PI * a0 / d2, 2.0 * PI * (a1 - u2 * a1.conjugate()) / d2, 2.0 * PI * (-u2 * a0) / d2)
    gamma = (g0p, g1, g2)                                                # gamma'_0 = gamma_0'
    out = []
    for l in range(3):
        s = 0j
        for k in range(3 - l):
            s += gamma[k] * sum(q[j + k + l].conjugate() * q[j] for j in range(3 - k - l))
        out.append((s / (PI * 1j * q[0])).real)
    return out


def reflectance(lagrange, phase):
    return math.atan(lagrange[0] + 2.0 * lagrange[1] * math.cos(phase) + 2.0 * lagrange[2] * math.cos(2.0 * phase)) / PI + 0.5


def moments_of_lagrange(lagrange, nodes=MOMENT_NODES):
    """c_j = (1/pi) int_{-pi}^{0} g(phi) cos(j phi) dphi for the even signal (midpoint rule)."""
    h = PI / nodes
    l0, l1, l2 = lagrange
    c0 = c1 = c2 = 0.0
    for i in range(nodes):
        cp = math.cos(-PI + (i + 0.5) * h)
        c2p = 2.0 * cp * cp - 1.0
        v = math.atan(l0 + 2.0 * l1 * cp + 2.0 * l2 * c2p) / PI + 0.5
        c0 += v
        c1 += v * cp
        c2 += v * c2p
    return [c0 * h / PI, c1 * h / PI, c2 * h / PI]


def clamp_moments(c):
    return (min(max(c[0], EPSILON), 1.0 - EPSILON), c[1], c[2])


# ---------------------------------------------------------------------------------------------
# Colour model and solver
# ---------------------------------------------------------------------------------------------

def srgb_eotf(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def srgb_oetf(v):
    v = min(max(v, 0.0), 1.0)
    return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1.0 / 2.4) - 0.055


def code_target(code):
    return min(max(srgb_eotf(code / 255.0), EPSILON), 1.0 - EPSILON)


def rgb_of_lagrange(data, lagrange):
    l0, l1, l2 = lagrange
    w0, w1, w2 = data.weights
    c1, c2 = data.cos1, data.cos2
    r = g = b = 0.0
    for i in range(len(w0)):
        v = math.atan(l0 + l1 * c1[i] + l2 * c2[i]) / PI + 0.5
        r += w0[i] * v
        g += w1[i] * v
        b += w2[i] * v
    return r, g, b


def rgb_and_jacobian(data, lagrange):
    l0, l1, l2 = lagrange
    w0, w1, w2 = data.weights
    c1, c2 = data.cos1, data.cos2
    r = g = b = 0.0
    j = [0.0] * 9
    for i in range(len(w0)):
        a1, a2 = c1[i], c2[i]
        s = l0 + l1 * a1 + l2 * a2
        v = math.atan(s) / PI + 0.5
        dv = 1.0 / (PI * (1.0 + s * s))
        x, y, z = w0[i], w1[i], w2[i]
        r += x * v
        g += y * v
        b += z * v
        x *= dv
        y *= dv
        z *= dv
        j[0] += x; j[1] += x * a1; j[2] += x * a2
        j[3] += y; j[4] += y * a1; j[5] += y * a2
        j[6] += z; j[7] += z * a1; j[8] += z * a2
    return (r, g, b), j


def solve3(m, f):
    a, b, c, d, e, g_, g, h, i = m
    det = a * (e * i - g_ * h) - b * (d * i - g_ * g) + c * (d * h - e * g)
    return ((f[0] * (e * i - g_ * h) - b * (f[1] * i - g_ * f[2]) + c * (f[1] * h - e * f[2])) / det,
            (a * (f[1] * i - g_ * f[2]) - f[0] * (d * i - g_ * g) + c * (d * f[2] - f[1] * g)) / det,
            (a * (e * f[2] - f[1] * h) - b * (d * f[2] - f[1] * g) + f[0] * (d * h - e * g)) / det)


def solve_lagrange(data, target, start=(0.0, 0.0, 0.0), tolerance=SOLVER_TOLERANCE, iterations=80):
    """Levenberg-Marquardt in Lagrange-multiplier space, where every point is a valid spectrum."""
    lam = list(start)
    rgb, jac = rgb_and_jacobian(data, lam)
    f = [target[k] - rgb[k] for k in range(3)]
    err = max(abs(v) for v in f)
    mu = 0.0
    n = 0
    while err > tolerance and n < iterations:
        n += 1
        jt = (jac[0], jac[3], jac[6], jac[1], jac[4], jac[7], jac[2], jac[5], jac[8])
        normal = [sum(jt[3 * r + k] * jac[3 * k + c] for k in range(3)) for r in range(3) for c in range(3)]
        gradient = [sum(jt[3 * r + k] * f[k] for k in range(3)) for r in range(3)]
        while True:
            damped = list(normal)
            for d in (0, 4, 8):
                damped[d] *= 1.0 + mu
            try:
                step = solve3(damped, gradient)
            except ZeroDivisionError:
                return lam, err
            trial = [lam[k] + step[k] for k in range(3)]
            rgb_t, jac_t = rgb_and_jacobian(data, trial)
            f_t = [target[k] - rgb_t[k] for k in range(3)]
            err_t = max(abs(v) for v in f_t)
            if err_t < err:
                mu = mu * 0.1 if mu > 1e-12 else 0.0
                break
            mu = max(mu * 10.0, 1e-6)
            if mu > 1e8:
                return lam, err
        lam, jac, f, err = trial, jac_t, f_t, err_t
    return lam, err


def encode_moments(c):
    q = (c[0], c[1] / (2.0 * MOMENT_SCALE) + 0.5, c[2] / (2.0 * MOMENT_SCALE) + 0.5)
    return tuple(min(max(int(round(v * 65535.0)), 0), 65535) for v in q)


def decode_moments(q):
    return (q[0] / 65535.0, (q[1] / 65535.0 - 0.5) * 2.0 * MOMENT_SCALE, (q[2] / 65535.0 - 0.5) * 2.0 * MOMENT_SCALE)


def linear_srgb_of_moments(data, c):
    lam = lagrange3(*clamp_moments(c))
    return None if lam is None else rgb_of_lagrange(data, lam)


def code_error(data, c, code):
    """Largest 8-bit sRGB deviation of the reconstructed reflectance's colour from `code`."""
    rgb = linear_srgb_of_moments(data, c)
    if rgb is None:
        return float("inf")
    return max(abs(srgb_oetf(rgb[k]) * 255.0 - code[k]) for k in range(3))


# ---------------------------------------------------------------------------------------------
# Lookup-table generation (process pool; results do not depend on the number of workers)
# ---------------------------------------------------------------------------------------------

_DATA = None
_COARSE = None
COARSE_CODES = list(range(0, 256, COARSE_STEP))
COARSE_N = len(COARSE_CODES)


def _init_worker(coarse=None):
    global _DATA, _COARSE
    _DATA = Data()
    _COARSE = coarse


def solve_code(data, code, start=(0.0, 0.0, 0.0)):
    target = [code_target(v) for v in code]
    lam, err = solve_lagrange(data, target, start)
    if err > 1e-9 and any(start):
        lam, err = solve_lagrange(data, target)
    return moments_of_lagrange(lam), lam, err


def _coarse_line(job):
    """Exact solves along one (r, g) line of the coarse grid, warm-started along b."""
    r, g = job
    out = array.array("d")
    worst = 0.0
    lam = (0.0, 0.0, 0.0)
    for b in COARSE_CODES:
        c, lam, err = solve_code(_DATA, (r, g, b), lam)
        worst = max(worst, err)
        out.extend(c)
    return out.tobytes(), worst


def interpolation_axis():
    """Per code: coarse cell index and the linear-light interpolation weight inside it."""
    axis = []
    for code in range(256):
        i = min(code // COARSE_STEP, COARSE_N - 2)
        lo, hi = srgb_eotf(COARSE_CODES[i] / 255.0), srgb_eotf(COARSE_CODES[i + 1] / 255.0)
        axis.append((i, (srgb_eotf(code / 255.0) - lo) / (hi - lo)))
    return axis


def interpolate(coarse, axis, code):
    (i, fx), (j, fy), (k, fz) = axis[code[0]], axis[code[1]], axis[code[2]]
    out = [0.0, 0.0, 0.0]
    for di, wx in ((0, 1.0 - fx), (1, fx)):
        for dj, wy in ((0, 1.0 - fy), (1, fy)):
            for dk, wz in ((0, 1.0 - fz), (1, fz)):
                w = wx * wy * wz
                if w == 0.0:
                    continue
                base = (((i + di) * COARSE_N + (j + dj)) * COARSE_N + (k + dk)) * 3
                out[0] += w * coarse[base]
                out[1] += w * coarse[base + 1]
                out[2] += w * coarse[base + 2]
    return out


def _lut_plane(r):
    """One red plane of the 256^3 table: interpolate, verify every entry, solve outliers exactly."""
    axis = interpolation_axis()
    out = array.array("H")
    worst = 0.0
    total = 0.0
    fixed = 0
    for g in range(256):
        for b in range(256):
            code = (r, g, b)
            q = encode_moments(interpolate(_COARSE, axis, code))
            err = code_error(_DATA, decode_moments(q), code)
            if err > FIX_THRESHOLD:
                fixed += 1
                start = lagrange3(*clamp_moments(decode_moments(q))) or (0.0, 0.0, 0.0)
                c, _, _ = solve_code(_DATA, code, start)
                q2 = encode_moments(c)
                err2 = code_error(_DATA, decode_moments(q2), code)
                if err2 < err:
                    q, err = q2, err2
            worst = max(worst, err)
            total += err
            out.extend(q)
    if sys.byteorder != "little":
        out.byteswap()
    return out.tobytes(), worst, total, fixed


def lut_header(magic, size, kind):
    header = magic + struct.pack("<IIII", FORMAT_VERSION, size, 3, kind)
    header += struct.pack("<6f", 1.0, 0.0, 2.0 * MOMENT_SCALE, -MOMENT_SCALE, 2.0 * MOMENT_SCALE, -MOMENT_SCALE)
    return header + b"\0" * (64 - len(header))


def generate_luts(workers):
    with multiprocessing.get_context("spawn").Pool(workers, _init_worker) as pool:
        results = pool.map(_coarse_line, [(r, g) for r in COARSE_CODES for g in COARSE_CODES], chunksize=8)
    coarse = array.array("d")
    for chunk, _ in results:
        coarse.frombytes(chunk)
    coarse_worst = max(w for _, w in results)
    with multiprocessing.get_context("spawn").Pool(workers, _init_worker, (coarse,)) as pool:
        planes = pool.map(_lut_plane, range(256), chunksize=1)
    lut = bytearray(lut_header(b"VTFSRGB\0", LUT_SIZE, 16))
    for chunk, _, _, _ in planes:
        lut += chunk
    coarse32 = array.array("f", coarse)
    if sys.byteorder != "little":
        coarse32.byteswap()
    grid = lut_header(b"VTFSRGBC", COARSE_N, 32) + coarse32.tobytes()
    stats = {
        "coarseNodes": COARSE_N ** 3, "coarseMaxSolverResidual": coarse_worst,
        "lutMax8BitError": max(p[1] for p in planes), "lutMean8BitError": sum(p[2] for p in planes) / 256 ** 3,
        "lutEntriesSolvedExactly": sum(p[3] for p in planes),
    }
    return bytes(lut), grid, stats


# ---------------------------------------------------------------------------------------------
# Wavelength sampling
# ---------------------------------------------------------------------------------------------

def sampling_density(data, index, defensive=DEFENSIVE_FRACTION):
    """Normalized pdf at 1 nm: (1 - a) I s / int(I s) + a s / int(s), with s = |r| + |g| + |b|."""
    s = data.srgb_cmf_l1()
    spd = data.illuminants[index]
    def normalized(values):
        total = sum(0.5 * (values[i] + values[i + 1]) for i in range(len(values) - 1))
        return [v / total for v in values]
    a, b = normalized([x * y for x, y in zip(spd, s)]), normalized(s)
    return [(1.0 - defensive) * x + defensive * y for x, y in zip(a, b)]


def mixture_density(densities, weights):
    """Power-weighted mixture of normalized densities (several illuminants in one scene)."""
    total = float(sum(weights))
    return [sum(w * d[i] for w, d in zip(weights, densities)) / total for i in range(len(densities[0]))]


def inverse_cdf(density, segments=ICDF_SEGMENTS):
    """Wavelengths at u = i / segments of the CDF of a piecewise-linear 1 nm density (exact)."""
    cdf = [0.0]
    for i in range(len(density) - 1):
        cdf.append(cdf[-1] + 0.5 * (density[i] + density[i + 1]))
    total = cdf[-1]
    out = [float(LAMBDA_MIN)]
    j = 0
    for n in range(1, segments):
        y = total * n / segments
        while cdf[j + 1] < y:
            j += 1
        p0, p1, rest = density[j], density[j + 1], y - cdf[j]
        dp = p1 - p0
        if abs(dp) < 1e-12 * max(p0, 1e-30):
            t = rest / p0
        else:
            t = (-p0 + math.sqrt(max(p0 * p0 + 2.0 * dp * rest, 0.0))) / dp
        out.append(LAMBDA_MIN + j + min(max(t, 0.0), 1.0))
    out.append(float(LAMBDA_MAX))
    for i in range(1, len(out)):            # keep nodes strictly increasing (finite table pdf)
        if out[i] <= out[i - 1]:
            out[i] = math.nextafter(out[i - 1], math.inf)
    return out


def sample_wavelength(table, u):
    """lambda(u) and its pdf for the piecewise-linear table: p = 1 / (segments * width)."""
    segments = len(table) - 1
    x = min(max(u, 0.0), 1.0) * segments
    i = min(int(x), segments - 1)
    width = table[i + 1] - table[i]
    return table[i] + (x - i) * width, 1.0 / (segments * width)


# ---------------------------------------------------------------------------------------------
# OpenPBR dispersion (specification "Dispersion": Cauchy fit from specular_ior and Abbe number)
# ---------------------------------------------------------------------------------------------

LAMBDA_C, LAMBDA_D, LAMBDA_F = 656.3, 587.6, 486.1


def cauchy_coefficients(ior_d, abbe_number, dispersion_scale):
    """(A, B) of n(lambda) = A + B / lambda^2 with lambda in nm; B = 0 without dispersion."""
    if dispersion_scale <= 0.0:
        return ior_d, 0.0
    vd = abbe_number / dispersion_scale
    b = (ior_d - 1.0) / (vd * (LAMBDA_F ** -2 - LAMBDA_C ** -2))
    return ior_d - b / LAMBDA_D ** 2, b


# ---------------------------------------------------------------------------------------------
# MSL include
# ---------------------------------------------------------------------------------------------

def msl_float(v):
    text = "%.9g" % v
    return text + ("f" if any(ch in text for ch in ".en") else ".0f")


def floats(values, per_line=8):
    items = [msl_float(v) for v in values]
    return ",\n".join("    " + ", ".join(items[i:i + per_line]) for i in range(0, len(items), per_line))


MSL_FUNCTIONS = r"""
// Index of a preset in vibe_illuminant_spd / vibe_wavelength_icdf.
enum VibeIlluminant : uint { VIBE_ILLUMINANT_E = 0, VIBE_ILLUMINANT_D65 = 1, VIBE_ILLUMINANT_A = 2,
    VIBE_ILLUMINANT_FL11 = 3, VIBE_ILLUMINANT_HP1 = 4, VIBE_ILLUMINANT_LED_B3 = 5 };

// Linear interpolation in a 1 nm table starting at VIBE_LAMBDA_MIN; zero outside the range.
inline float vibe_spectral_lookup(constant float *table, float lambda) {
    float x = lambda - VIBE_LAMBDA_MIN;
    if (!(x >= 0.0f && x <= float(VIBE_SPECTRAL_SAMPLES - 1))) return 0.0f;
    uint i = min(uint(x), VIBE_SPECTRAL_SAMPLES - 2u);
    return mix(table[i], table[i + 1u], x - float(i));
}

inline float3 vibe_cmf_xyz(float lambda) {
    return float3(vibe_spectral_lookup(vibe_cmf_x, lambda), vibe_spectral_lookup(vibe_cmf_y, lambda),
                  vibe_spectral_lookup(vibe_cmf_z, lambda));
}

inline float3 vibe_xyz_to_linear_srgb(float3 xyz) { return VIBE_XYZ_TO_LINEAR_SRGB * xyz; }

// Peters' even XYZ warp (PETERS2019 Sec. 4.1): wavelength -> phase in [-pi, 0].
inline float vibe_fourier_phase(float lambda) {
    float t = clamp((lambda - 360.0f) * 0.2f, 0.0f, 94.0f);
    uint i = min(uint(t), 93u);
    return mix(vibe_phase_warp[i], vibe_phase_warp[i + 1u], t - float(i));
}

// Wavelength for a uniform u in [0, 1] from a preset's inverse CDF, and its density (1/nm) for
// the piecewise-linear table actually sampled. Hero-style stratification: u_k = (u + k) / 4.
inline float vibe_sample_wavelength(uint illuminant, float u, thread float &pdf) {
    constant float *table = vibe_wavelength_icdf[illuminant];
    float x = clamp(u, 0.0f, 1.0f) * float(VIBE_ICDF_SEGMENTS);
    uint i = min(uint(x), VIBE_ICDF_SEGMENTS - 1u);
    float width = table[i + 1u] - table[i];
    pdf = 1.0f / (float(VIBE_ICDF_SEGMENTS) * width);
    return table[i] + (x - float(i)) * width;
}

// FourierSRGB256.bin / FourierSRGB86.bin entry -> bounded trigonometric moments (c0, c1, c2).
inline float3 vibe_decode_fourier_moments(ushort3 q) {
    float3 v = float3(q) * (1.0f / 65535.0f);
    return float3(v.x, (v.y - 0.5f) * (2.0f * VIBE_MOMENT_SCALE), (v.z - 0.5f) * (2.0f * VIBE_MOMENT_SCALE));
}

// Bounded MESE for three real moments (PETERS2019 Eqs. 6, 7, 10; FOURIERSRGB2019 Alg. 1):
// the real Lagrange multipliers (L0, L1, L2). c0 is clamped to [eps, 1 - eps]; moments outside
// the valid set are pulled back with the Appendix A biasing, so any input yields a reflectance.
inline float2 vibe_cmul(float2 a, float2 b) { return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }
inline float2 vibe_conj(float2 a) { return float2(a.x, -a.y); }
inline float3 vibe_fourier_lagrange(float3 c) {
    const float pi = 3.14159265358979f;
    float c0 = clamp(c.x, VIBE_MOMENT_EPSILON, 1.0f - VIBE_MOMENT_EPSILON);
    float2 g0p = float2(sinpi(c0), -cospi(c0)) * (1.0f / (4.0f * pi));     // Eq. 6
    float g0 = 2.0f * g0p.x;
    float2 g1 = (2.0f * pi * c.y) * float2(-g0p.y, g0p.x);                   // Eq. 7, l = 1
    float2 g2 = pi * float2(-(2.0f * c.z * g0p.y + c.y * g1.y), 2.0f * c.z * g0p.x + c.y * g1.x);
    // Levinson's algorithm with biasing (FOURIERSRGB2019 Alg. 2, epsilon = 1e-4, then 1).
    float q0 = 1.0f / g0;
    float2 u1 = q0 * g1;
    float n1 = dot(u1, u1);
    float keep = 0.9999f;
    if (n1 >= 1.0f) { u1 *= keep * rsqrt(n1); g1 = u1 / q0; n1 = keep * keep; keep = 0.0f; }
    float d1 = 1.0f / (1.0f - n1);
    float a0 = q0 * d1;
    float2 a1 = -u1 * (q0 * d1);
    float2 u2 = a0 * g2 + vibe_cmul(a1, g1);
    float n2 = dot(u2, u2);
    if (n2 >= 1.0f) {
        u2 *= keep * rsqrt(n2);
        g2 = (u2 - vibe_cmul(a1, g1)) / a0;
        n2 = keep * keep;
    }
    float d2 = 1.0f / (1.0f - n2);
    float b0 = a0 * d2;
    float2 b1 = (a1 - vibe_cmul(u2, vibe_conj(a1))) * d2;
    float2 b2 = -u2 * (a0 * d2);
    // Eq. 10 with q = 2 pi b: lambda_l = 2 pi / (pi i b0) sum_k gamma'_k sum_j conj(b_{j+k+l}) b_j.
    float2 r0 = float2(b0 * b0 + dot(b1, b1) + dot(b2, b2), 0.0f);           // sum_j conj(q_j) q_j
    float2 r1 = vibe_cmul(vibe_conj(b1), float2(b0, 0.0f)) + vibe_cmul(vibe_conj(b2), b1);
    float2 r2 = vibe_cmul(vibe_conj(b2), float2(b0, 0.0f));
    float2 s0 = vibe_cmul(g0p, r0) + vibe_cmul(g1, r1) + vibe_cmul(g2, r2);
    float2 s1 = vibe_cmul(g0p, r1) + vibe_cmul(g1, r2);
    float2 s2 = vibe_cmul(g0p, r2);
    float scale = 2.0f / b0;                                                  // Re(2 pi s / (pi i b0)) = 2 Im(s) / b0
    return float3(s0.y, s1.y, s2.y) * scale;
}

// Eq. 11: reflectance at a phase from the Lagrange multipliers, in (0, 1).
inline float vibe_fourier_reflectance(float3 lagrange, float phase) {
    float c1 = cos(phase);
    float series = lagrange.x + 2.0f * lagrange.y * c1 + 2.0f * lagrange.z * (2.0f * c1 * c1 - 1.0f);
    return atan(series) * 0.318309886f + 0.5f;
}
"""


def warp_notice():
    """The BSD 3-Clause header of XYZWarp.h, which must accompany the reproduced warp table."""
    lines = (VENDOR / "Peters2019/XYZWarp.h").read_text().replace("\r", "").split("\n")
    end = lines.index("#pragma once")
    return [line for line in lines[:end] if line.startswith("//")]


def msl_include(data, icdfs):
    lines = [
        "// Generated by scripts/generate_spectral_tables.py; do not edit (docs/SPECTRAL_DESIGN.md).",
        "// CIE 1931 2-degree colour-matching functions and CIE illuminant spectra: CIE datasets",
        "// (doi:10.25039/CIE.DS.xvudnb9b, .hjfjmt59, .8jsxjrsn, .54hy6srn, .f6rvvnev, .dhcw57sd),",
        "// CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/); this file is adapted",
        "// material (resampled to 1 nm, normalized) and is shared under the same license.",
        "// The bounded-MESE functions are a local implementation of PETERS2019 / FOURIERSRGB2019.",
        "// vibe_phase_warp reproduces pXYZWarpEven from Vendor/Spectral/Peters2019/XYZWarp.h, whose",
        "// notice follows:",
    ] + warp_notice() + [
        "#pragma once",
        "#include <metal_stdlib>",
        "using namespace metal;",
        "constant float VIBE_LAMBDA_MIN = %d.0f;" % LAMBDA_MIN,
        "constant float VIBE_LAMBDA_MAX = %d.0f;" % LAMBDA_MAX,
        "constant uint VIBE_SPECTRAL_SAMPLES = %du;" % len(WAVELENGTHS),
        "constant uint VIBE_ICDF_SEGMENTS = %du;" % ICDF_SEGMENTS,
        "constant uint VIBE_ILLUMINANT_COUNT = %du;" % len(ILLUMINANTS),
        "constant float VIBE_MOMENT_EPSILON = %s;" % msl_float(EPSILON),
        "constant float VIBE_MOMENT_SCALE = %s;  // 1 / pi" % msl_float(MOMENT_SCALE),
        "// Columns of a float3x3 are given; xyz_to_rgb maps CIE XYZ (Y = 1 for the D65 white) to",
        "// linear sRGB with the IEC primaries and the computed D65 white, so a reflectance of 1",
        "// under D65 is exactly (1, 1, 1).",
        "constant float3x3 VIBE_XYZ_TO_LINEAR_SRGB = float3x3(%s);" % ", ".join(
            "float3(%s)" % ", ".join(msl_float(data.xyz_to_rgb[r][c]) for r in range(3)) for c in range(3)),
        "constant float3x3 VIBE_LINEAR_SRGB_TO_XYZ = float3x3(%s);" % ", ".join(
            "float3(%s)" % ", ".join(msl_float(data.rgb_to_xyz[r][c]) for r in range(3)) for c in range(3)),
    ]
    for k, name in enumerate("xyz"):
        lines.append("constant float vibe_cmf_%s[%d] = {\n%s\n};" % (name, len(WAVELENGTHS), floats([c[k] for c in data.cmf])))
    lines.append("constant float vibe_phase_warp[95] = {\n%s\n};" % floats(data.warp))
    lines.append("// Presets (%s), 1 nm, normalized to luminance Y = sum(S * ybar) = 1." % ", ".join(i[0] for i in ILLUMINANTS))
    lines.append("constant float vibe_illuminant_spd[%d][%d] = {\n%s\n};" % (
        len(ILLUMINANTS), len(WAVELENGTHS), ",\n".join("  {\n%s\n  }" % floats(s) for s in data.illuminants)))
    lines.append("// Inverse CDFs of p ~ (1 - %.2g) S |rgb cmf| + %.2g |rgb cmf| (normalized terms), nm." % (DEFENSIVE_FRACTION, DEFENSIVE_FRACTION))
    lines.append("constant float vibe_wavelength_icdf[%d][%d] = {\n%s\n};" % (
        len(ILLUMINANTS), ICDF_SEGMENTS + 1, ",\n".join("  {\n%s\n  }" % floats(t) for t in icdfs)))
    return "\n".join(lines) + "\n" + MSL_FUNCTIONS


# ---------------------------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------------------------

# Functions whose source determines the two lookup tables. Editing anything else (the MSL
# include, sampling tables, documentation) regenerates only the cheap outputs; the table checks in
# tests/SpectralTables.py verify the reused tables independently.
LUT_SOURCES = ("verify_inputs", "read_table", "resample", "parse_warp", "inverse3", "apply3", "Data",
               "lagrange3", "moments_of_lagrange", "clamp_moments", "srgb_eotf", "srgb_oetf", "code_target",
               "rgb_of_lagrange", "rgb_and_jacobian", "solve3", "solve_lagrange", "encode_moments",
               "decode_moments", "linear_srgb_of_moments", "code_error", "_init_worker", "solve_code",
               "_coarse_line", "interpolation_axis", "interpolate", "_lut_plane", "lut_header", "generate_luts")
LUT_OUTPUTS = ("FourierSRGB256.bin", "FourierSRGB86.bin")


def lut_cache_key():
    import inspect
    module = sys.modules[__name__]
    digest = hashlib.sha256()
    for name in LUT_SOURCES:
        digest.update(inspect.getsource(getattr(module, name)).encode())
    lut_parameters = {k: PARAMETERS[k] for k in ("format", "lambda", "epsilon", "lut", "coarseStep",
                                                   "momentNodes", "fixThreshold", "solverTolerance")}
    digest.update(json.dumps({"inputs": INPUTS, "parameters": lut_parameters,
                              "primaries": SRGB_PRIMARIES, "illuminants": ILLUMINANTS}, sort_keys=True).encode())
    return digest.hexdigest()


def cache_key():
    digest = hashlib.sha256()
    digest.update((ROOT / "scripts" / "generate_spectral_tables.py").read_bytes())
    digest.update(json.dumps({"inputs": INPUTS, "parameters": PARAMETERS}, sort_keys=True).encode())
    return digest.hexdigest()


def read_manifest(target):
    try:
        return json.loads((target / "SpectralTables.json").read_text())
    except (OSError, ValueError):
        return {}


def outputs_match(target, manifest, names):
    recorded = manifest.get("outputs", {})
    return all((target / name).is_file() and sha256_file(target / name) == recorded.get(name) for name in names)


def main(argv):
    target = pathlib.Path(argv[argv.index("--output") + 1]) if "--output" in argv else build_directory(ROOT) / "SpectralTables"
    workers = int(argv[argv.index("--jobs") + 1]) if "--jobs" in argv else (os.cpu_count() or 1)
    force = "--force" in argv
    verify_inputs()
    key, lut_key = cache_key(), lut_cache_key()
    target.mkdir(parents=True, exist_ok=True)
    with locked(target.parent / ".spectral-tables.lock"):
        previous = read_manifest(target)
        if not force and previous.get("key") == key and outputs_match(target, previous, OUTPUTS):
            print("Spectral tables up to date (%s)" % target)
            return 0
        started = time.time()
        data = Data()
        icdfs = [inverse_cdf(sampling_density(data, i)) for i in range(len(ILLUMINANTS))]
        include = msl_include(data, icdfs).encode()
        digests = {"SpectralTables.metal": hashlib.sha256(include).hexdigest()}
        if not force and previous.get("lutKey") == lut_key and outputs_match(target, previous, LUT_OUTPUTS):
            stats = previous["statistics"]
            digests.update({name: previous["outputs"][name] for name in LUT_OUTPUTS})
            print("Reusing the unchanged Fourier sRGB tables")
        else:
            print("Generating the Fourier sRGB tables with %d worker(s); this takes several minutes once" % workers)
            lut, grid, stats = generate_luts(workers)
            stats["seconds"] = round(time.time() - started, 1)
            for name, payload in (("FourierSRGB256.bin", lut), ("FourierSRGB86.bin", grid)):
                atomic_write(target / name, payload)
                digests[name] = hashlib.sha256(payload).hexdigest()
        atomic_write(target / "SpectralTables.metal", include)
        manifest = {
            "key": key, "lutKey": lut_key, "parameters": PARAMETERS, "inputs": INPUTS,
            "outputs": {name: digests[name] for name in OUTPUTS},
            "illuminants": [{"id": i[0], "label": i[1], "source": i[2], "column": i[3]} for i in ILLUMINANTS],
            "whiteXYZ": data.white, "xyzToLinearSRGB": data.xyz_to_rgb, "statistics": stats,
            "licenses": {"CIE data and derived tables": "CC BY-SA 4.0",
                         "Peters2019/XYZWarp.h phase warp": "BSD-3-Clause (Christoph Peters, 2019)"},
        }
        atomic_write_text(target / "SpectralTables.json", json.dumps(manifest, indent=1) + "\n")
        print("Spectral tables in %s: max 8-bit error %.3f, mean %.4f, %d exact re-solves" % (
            target, stats["lutMax8BitError"], stats["lutMean8BitError"], stats["lutEntriesSolvedExactly"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
