#!/usr/bin/env python3
"""Offline checks of the generated spectral tables (build/SpectralTables; docs/SPECTRAL_DESIGN.md).

Run by tests/verify.py after scripts/generate_spectral_tables.py. Pure Python plus an optional
Metal check of the generated MSL include (tests/SpectralGPU.swift), skipped without a GPU.
The colour checks use the coarse grid interpolated as the renderer does (FourierSRGB86.bin,
linear-light trilinear); the opt-in FourierSRGB256.bin (generator --lut256) is checked too
when the manifest lists it. tests/Fix_spectral.swift measures the renderer's float32 conversion.
Usage: python3 tests/SpectralTables.py [--no-gpu] [--quick]
"""
import array
import json
import math
import multiprocessing
import os
import pathlib
import random
import re
import struct
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import generate_spectral_tables as gen  # noqa: E402

TABLES = ROOT / "build" / "SpectralTables"
QUICK = "--quick" in sys.argv
_LUT = None
_GRID = None
_AXIS = None
_DATA = None


def check(condition, message):
    # Explicit failures: unlike assert, these still run under python -O.
    if not condition:
        sys.exit("FAIL: SpectralTables.py: " + str(message))


def report(message):
    print("SpectralTables: " + message, flush=True)


# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

def lut_entry(lut, code):
    return struct.unpack_from("<3H", lut, 64 + 6 * ((code[0] * 256 + code[1]) * 256 + code[2]))


def parse_array(text, name):
    match = re.search(r"constant float %s\[[^=]*= \{(.*?)\n\};" % re.escape(name), text, re.S)
    check(match, "array %s in SpectralTables.metal" % name)
    return [float(v.rstrip("f")) for v in re.findall(r"-?[0-9.]+(?:e[-+]?[0-9]+)?f", match.group(1))]


def lab(data, rgb):
    xyz = gen.apply3(data.rgb_to_xyz, rgb)
    def f(t):
        return t ** (1.0 / 3.0) if t > (6.0 / 29.0) ** 3 else t / (3.0 * (6.0 / 29.0) ** 2) + 4.0 / 29.0
    fx, fy, fz = (f(xyz[k] / data.white[k]) for k in range(3))
    return 116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)


def load_grid():
    grid = (TABLES / "FourierSRGB86.bin").read_bytes()
    check(len(grid) == 64 + 12 * gen.COARSE_N ** 3 and grid[:8] == b"VTFSRGBC", "FourierSRGB86.bin layout")
    values = array.array("f")
    values.frombytes(grid[64:])
    if sys.byteorder != "little":
        values.byteswap()
    return array.array("d", values)


def has_lut():
    manifest = json.loads((TABLES / "SpectralTables.json").read_text())
    return "FourierSRGB256.bin" in manifest["outputs"] and (TABLES / "FourierSRGB256.bin").is_file()


def _init(lut_path):
    global _LUT, _GRID, _AXIS, _DATA
    _LUT = pathlib.Path(lut_path).read_bytes() if lut_path else None
    _GRID = load_grid()
    _AXIS = gen.interpolation_axis()
    _DATA = gen.Data()


def moments_of(code, source):
    """Moments of an 8-bit code: the 256^3 table's entry, or the coarse grid interpolated in linear light."""
    if source == "lut":
        return gen.decode_moments(lut_entry(_LUT, code))
    return tuple(gen.interpolate(_GRID, _AXIS, code))


def _round_trip(job):
    codes, source = job
    worst = (0.0, None)
    total = 0.0
    worst_e = 0.0
    total_e = 0.0
    bounded = True
    for code in codes:
        c = moments_of(code, source)
        lam = gen.lagrange3(*gen.clamp_moments(c))
        if lam is None:
            return None
        rgb = gen.rgb_of_lagrange(_DATA, lam)
        err = max(abs(gen.srgb_oetf(rgb[k]) * 255.0 - code[k]) for k in range(3))
        target = [gen.srgb_eotf(v / 255.0) for v in code]
        de = math.dist(lab(_DATA, [max(v, 0.0) for v in rgb]), lab(_DATA, target))
        if err > worst[0]:
            worst = (err, code)
        worst_e = max(worst_e, de)
        total += err
        total_e += de
        for p in _DATA.phases[::10]:
            v = gen.reflectance(lam, p)
            bounded = bounded and 0.0 < v < 1.0
    return worst, total, worst_e, total_e, bounded, len(codes)


def _valid_plane(r):
    invalid = 0
    for g in range(256):
        for b in range(256):
            if gen.lagrange3(*gen.clamp_moments(gen.decode_moments(lut_entry(_LUT, (r, g, b))))) is None:
                invalid += 1
    return invalid


def pool(workers=None):
    path = str(TABLES / "FourierSRGB256.bin") if has_lut() else ""
    return multiprocessing.get_context("spawn").Pool(workers or os.cpu_count() or 1, _init, (path,))


# ---------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------

def check_inputs_and_manifest(data):
    gen.verify_inputs()
    manifest = json.loads((TABLES / "SpectralTables.json").read_text())
    check(manifest["key"] == gen.cache_key() and manifest["coarseKey"] == gen.lut_cache_key(gen.COARSE_SOURCES)
          and ("FourierSRGB256.bin" not in manifest["outputs"] or manifest["lutKey"] == gen.lut_cache_key()),
          "tables were generated by the current script (run scripts/generate_spectral_tables.py)")
    check(set(gen.DEFAULT_OUTPUTS) <= set(manifest["outputs"]), "the manifest lists the default outputs")
    for name in manifest["outputs"]:
        check(gen.sha256_file(TABLES / name) == manifest["outputs"][name], "SHA-256 of " + name)
    # CIE's published validation sums (column sums of the 1 nm table, from its metadata file).
    meta = json.loads((gen.VENDOR / "CIE/CIE_xyz_1931_2deg.csv_metadata.json").read_text())
    sums = json.loads(meta["datatableInfo"]["validations"][0]["validationValue"])
    for k in range(3):
        check(abs(sum(c[k] for c in data.cmf) - sums[k + 1]) < 1e-9, "CMF column sum %d" % k)
    # D65 white point of the 1931 observer (CIE 015:2018: x = 0.31272, y = 0.32903, tabulated from
    # 5 nm data; the 1 nm sums give 0.312727, 0.329023).
    x, y = data.white[0] / sum(data.white), data.white[1] / sum(data.white)
    check(abs(x - 0.31272) < 1e-5 and abs(y - 0.32903) < 1e-5, "D65 chromaticity %.6f %.6f" % (x, y))
    nominal = ((3.2406, -1.5372, -0.4986), (-0.9689, 1.8758, 0.0415), (0.0557, -0.2040, 1.0570))
    check(all(abs(data.xyz_to_rgb[r][c] - nominal[r][c]) < 6e-4 for r in range(3) for c in range(3)),
          "XYZ -> sRGB matrix matches IEC 61966-2-1 to its published precision")
    white = gen.apply3(data.xyz_to_rgb, data.white)
    check(max(abs(v - 1.0) for v in white) < 1e-12, "D65 white maps to (1, 1, 1)")
    report("inputs pinned; CMF sums match CIE validation; D65 xy = (%.5f, %.5f); white -> %s" % (x, y, white))


def check_include(data):
    text = (TABLES / "SpectralTables.metal").read_text()
    check("// Copyright (c) 2019, Christoph Peters" in text and "THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS" in text
          and "CC BY-SA 4.0" in text, "the include carries the BSD notice of the warp and the CIE licence")
    for k, name in enumerate("xyz"):
        values = parse_array(text, "vibe_cmf_" + name)
        check(len(values) == 471 and max(abs(v - c[k]) for v, c in zip(values, data.cmf)) < 1e-8 * 2, "CMF " + name)
    warp = parse_array(text, "vibe_phase_warp")
    check(warp == [float("%.9g" % v) for v in data.warp] and abs(warp[0] + math.pi) < 1e-8 and warp[-1] == 0.0, "phase warp")
    spd = parse_array(text, "vibe_illuminant_spd")
    icdf = parse_array(text, "vibe_wavelength_icdf")
    n = len(gen.ILLUMINANTS)
    check(len(spd) == n * 471 and len(icdf) == n * (gen.ICDF_SEGMENTS + 1), "table sizes")
    for i, preset in enumerate(gen.ILLUMINANTS):
        s = spd[i * 471:(i + 1) * 471]
        y = sum(v * c[1] for v, c in zip(s, data.cmf))
        check(abs(y - 1.0) < 1e-6, "%s luminance normalization (Y = %.8f)" % (preset[0], y))
        check(min(s) >= 0.0, "%s nonnegative" % preset[0])
    # E: Y = 1 means sum(ybar) * S_E = 1; XYZ of E is then (sum x, 1, sum z) / sum y.
    e = spd[:471]
    check(max(e) - min(e) < 1e-9 and abs(e[0] * sum(c[1] for c in data.cmf) - 1.0) < 1e-7, "E is constant with Y = 1")
    report("MSL include: CMFs, warp and %d presets present; every preset has Y = 1" % n)
    return [icdf[i * (gen.ICDF_SEGMENTS + 1):(i + 1) * (gen.ICDF_SEGMENTS + 1)] for i in range(n)], spd


def check_mese():
    rng = random.Random(7)
    worst = 0.0
    tested = 0
    while tested < 40:
        c = (rng.uniform(0.02, 0.98), rng.uniform(-0.25, 0.25), rng.uniform(-0.25, 0.25))
        lam = gen.lagrange3(*c)
        if lam is None:
            continue
        back = gen.moments_of_lagrange(lam, 4096)
        worst = max(worst, max(abs(a - b) for a, b in zip(c, back)))
        tested += 1
    check(worst < 1e-9, "bounded MESE reproduces its moments (Theorem 5), max error %.2e" % worst)
    check(gen.lagrange3(0.1, 0.3, 0.0) is None, "moments outside the valid set are detected")
    report("bounded MESE reproduces 40 random moment vectors to %.1e" % worst)


def check_lut(data):
    """The coarse grid as the renderer interpolates it, and the 256^3 table when generated."""
    grid = load_grid()
    sources = ["grid"]
    lut = None
    if has_lut():
        lut = (TABLES / "FourierSRGB256.bin").read_bytes()
        check(len(lut) == 64 + 6 * 256 ** 3 and lut[:8] == b"VTFSRGB\0", "FourierSRGB256.bin layout")
        check(struct.unpack_from("<IIII", lut, 8) == (gen.FORMAT_VERSION, 256, 3, 16), "FourierSRGB256.bin header")
        check(struct.unpack_from("<6f", lut, 24)[0] == 1.0, "c0 scale")
        sources.append("lut")
    else:
        report("FourierSRGB256.bin not generated (opt-in: generate_spectral_tables.py --lut256); checking the grid")
    global _LUT, _GRID, _AXIS
    _LUT, _GRID, _AXIS = lut, grid, gen.interpolation_axis()
    # White furnace and neutral greys: flat spectra.
    for source in sources:
        for code in ((255, 255, 255), (128, 128, 128), (10, 10, 10), (0, 0, 0)):
            lam = gen.lagrange3(*gen.clamp_moments(moments_of(code, source)))
            values = [gen.reflectance(lam, p) for p in data.phases]
            level = gen.code_target(code[0])
            check(max(abs(v - level) for v in values) < 2e-4, "%s: grey %s is flat at %.5f (range %.6f..%.6f)" % (
                source, code, level, min(values), max(values)))
        lam = gen.lagrange3(*gen.clamp_moments(moments_of((255, 255, 255), source)))
        white = min(gen.reflectance(lam, p) for p in data.phases)
        check(white > 0.9998, "white furnace: reflectance of sRGB white >= 0.9998 (%.6f)" % white)
        report("%s: white furnace: sRGB white reflects >= %.6f at every wavelength; greys are flat" % (source, white))
    # Every grid node (and every table entry) decodes to valid moments.
    nodes = len(grid) // 3
    invalid = sum(1 for i in range(0, nodes, 7 if QUICK else 1)
                  if gen.lagrange3(*gen.clamp_moments(grid[3 * i:3 * i + 3])) is None)
    check(invalid == 0, "%d grid nodes are invalid moments" % invalid)
    report("all %s grid nodes are valid moments" % ("sampled" if QUICK else "{:,}".format(nodes)))
    with pool() as workers:
        if lut is not None:
            started = time.time()
            invalid = sum(workers.map(_valid_plane, range(0, 256, 15 if QUICK else 1)))
            check(invalid == 0, "%d table entries decode to invalid moments" % invalid)
            report("all %s entries decode to valid moments (%.0f s)" % ("sampled" if QUICK else "16,777,216", time.time() - started))
        # Dense round trip: every code on a stride-5 grid (52^3) plus random codes.
        rng = random.Random(11)
        codes = [(r, g, b) for r in range(0, 256, 5) for g in range(0, 256, 5) for b in range(0, 256, 5)]
        codes += [tuple(rng.randrange(256) for _ in range(3)) for _ in range(20000 if QUICK else 100000)]
        if QUICK:
            codes = codes[::8]
        for source in sources:
            chunks = [(codes[i:i + 2000], source) for i in range(0, len(codes), 2000)]
            started = time.time()
            results = workers.map(_round_trip, chunks)
            check(all(r is not None for r in results), "%s: round trip decoded invalid moments" % source)
            worst = max((r[0] for r in results), key=lambda w: w[0])
            count = sum(r[5] for r in results)
            mean = sum(r[1] for r in results) / count
            worst_e = max(r[2] for r in results)
            mean_e = sum(r[3] for r in results) / count
            check(all(r[4] for r in results), "reflectance bounded in (0, 1)")
            # Plain trilinear grid interpolation reaches ~0.8 steps at the gamut boundary; the renderer
            # solves the cells worse than 0.35 steps exactly at load, and tests/Fix_spectral.swift
            # requires < 0.5 for all 16,777,216 codes of that refined path.
            bound = 0.85 if source == "grid" else 0.5
            check(worst[0] < bound, "%s: 8-bit round trip: max error %.3f at %s" % ((source,) + worst))
            report("%s round trip sRGB -> moments -> spectrum -> XYZ -> sRGB over %d codes (double precision): 8-bit error "
                   "max %.3f (at %s), mean %.4f; CIELAB dE76 max %.4f, mean %.5f; reflectance in (0, 1) (%.0f s)" % (
                       {"grid": "Runtime grid interpolation", "lut": "FourierSRGB256"}[source], count, worst[0], worst[1], mean,
                       worst_e, mean_e, time.time() - started))
    return lut


def check_reproducible(lut):
    """Regenerate plane r = 0 from scratch (with its coarse lines) and compare bit for bit."""
    started = time.time()
    with multiprocessing.get_context("spawn").Pool(os.cpu_count() or 1, gen._init_worker) as workers:
        lines = workers.map(gen._coarse_line, [(r, g) for r in gen.COARSE_CODES[:2] for g in gen.COARSE_CODES])
    grid = (TABLES / "FourierSRGB86.bin").read_bytes()
    coarse = array.array("d")
    for chunk, _ in lines:
        coarse.frombytes(chunk)
    stored = array.array("f")
    stored.frombytes(grid[64:64 + 12 * len(coarse) // 3])
    check(list(array.array("f", coarse)) == list(stored), "coarse grid lines r = 0, 3 reproduce bit for bit")
    if lut is None:
        report("regenerated coarse lines r = 0, 3 bit for bit (%.0f s)" % (time.time() - started))
        return
    gen._DATA = gen.Data()
    gen._COARSE = coarse + array.array("d", [0.0]) * (3 * gen.COARSE_N ** 3 - len(coarse))
    plane, _, _, _ = gen._lut_plane(0)
    check(plane == lut[64:64 + len(plane)], "LUT plane r = 0 reproduces bit for bit")
    report("regenerated coarse lines and LUT plane r = 0 bit for bit (%.0f s)" % (time.time() - started))


def check_sampling(data, icdfs):
    s = data.srgb_cmf_l1()
    for i, preset in enumerate(gen.ILLUMINANTS):
        table = icdfs[i]
        exact = gen.inverse_cdf(gen.sampling_density(data, i))
        check(max(abs(a - b) for a, b in zip(table, exact)) < 1e-4, preset[0] + " table matches the generator")
        check(table[0] == 360.0 and table[-1] == 830.0 and all(b > a for a, b in zip(table, table[1:])), preset[0] + " monotonic")
        density = gen.sampling_density(data, i)
        # Histogram of stratified samples vs the analytic density, in 10 nm bins.
        bins = [0] * 47
        n = 200000
        for k in range(n):
            lam, _ = gen.sample_wavelength(table, (k + 0.5) / n)
            bins[min(int((lam - 360.0) // 10), 46)] += 1
        def table_mass(lo, hi):
            # Exact mass of the table's piecewise-constant pdf in [lo, hi].
            total = 0.0
            for j in range(len(table) - 1):
                a, b = max(table[j], lo), min(table[j + 1], hi)
                if b > a:
                    total += (b - a) / ((len(table) - 1) * (table[j + 1] - table[j]))
            return total
        worst = 0.0
        worst_table = 0.0
        for b in range(47):
            mass = sum(0.5 * (density[j] + density[j + 1]) for j in range(10 * b, min(10 * b + 10, 470)))
            own = table_mass(360.0 + 10 * b, 370.0 + 10 * b if b < 46 else 830.0)
            if own > 2e-3:
                worst_table = max(worst_table, abs(bins[b] / n - own) / own)
            # Each table segment holds 1/1024 of the mass, so the sparse tails are coarse.
            if mass > 5e-3:
                worst = max(worst, abs(bins[b] / n - mass) / mass)
        check(worst_table < 0.01, "%s histogram vs table pdf: max relative bin error %.4f" % (preset[0], worst_table))
        check(worst < 0.01, "%s histogram vs analytic pdf: max relative bin error %.4f" % (preset[0], worst))
        # Unbiasedness of f / p with the table pdf: E[ybar S / p] = sum ybar S = 1 (Y of the preset).
        spd = data.illuminants[i]
        def f(lam):
            x = lam - 360.0
            j = min(int(x), 469)
            t = x - j
            return ((1 - t) * spd[j] + t * spd[j + 1]) * ((1 - t) * data.cmf[j][1] + t * data.cmf[j + 1][1])
        m = 1 << 16
        estimate = 0.0
        for k in range(m):
            lam, pdf = gen.sample_wavelength(table, (k + 0.5) / m)
            estimate += f(lam) / pdf
        estimate /= m
        trapezoid = sum(0.5 * (f(360.0 + j) + f(361.0 + j)) for j in range(470))
        check(abs(estimate - trapezoid) < 2e-3 * trapezoid, "%s: E[f/p] %.6f vs %.6f" % (preset[0], estimate, trapezoid))
        support = all(density[j] > 0.0 for j in range(471) if s[j] > 1e-6)
        check(support, preset[0] + " pdf covers every wavelength with nonzero CMF (defensive mixture)")
        report("%-6s inverse CDF: 10 nm histogram within %.2f%% of the table pdf, %.2f%% of the analytic pdf "
               "(bins > 0.5%% mass); E[Y S/p] = %.5f (exact %.5f)" % (preset[0], 100 * worst_table, 100 * worst, estimate, trapezoid))
    # Power-weighted mixture of two presets.
    mix = gen.mixture_density([gen.sampling_density(data, 1), gen.sampling_density(data, 4)], [3.0, 1.0])
    total = sum(0.5 * (mix[j] + mix[j + 1]) for j in range(470))
    check(abs(total - 1.0) < 1e-12, "mixture density is normalized")
    table = gen.inverse_cdf(mix)
    lam, pdf = gen.sample_wavelength(table, 0.5)
    check(360.0 < lam < 830.0 and pdf > 0.0, "mixture table samples")
    report("power-weighted mixture (D65 : HP1 = 3 : 1) is normalized and samples")


def reflectance_at(data, lam_mult, lam):
    return gen.reflectance(lam_mult, data.phase(lam))


def check_noise(data, icdfs, lut):
    """Colour noise of m = 4 jittered vs independent wavelengths, by quadrature over u."""
    colours = {"grey": (128, 128, 128), "red": (200, 30, 30), "green": (40, 160, 60), "blue": (40, 60, 200),
               "skin": (230, 180, 150), "cyan": (18, 239, 253)}
    rgb_cmf = [gen.apply3(data.xyz_to_rgb, c) for c in data.cmf]
    uniform = [360.0 + 470.0 * k / gen.ICDF_SEGMENTS for k in range(gen.ICDF_SEGMENTS + 1)]
    m_quad = 512 if QUICK else 2048
    lines = []
    worst_ratio = 0.0
    for i, preset in enumerate(gen.ILLUMINANTS):
        spd = data.illuminants[i]
        for name, code in colours.items():
            lam_mult = gen.lagrange3(*gen.clamp_moments(moments_of(code, "grid")))
            def f(lam):
                x = lam - 360.0
                j = min(int(x), 469)
                t = x - j
                s = (1 - t) * spd[j] + t * spd[j + 1]
                c = [(1 - t) * rgb_cmf[j][k] + t * rgb_cmf[j + 1][k] for k in range(3)]
                rho = reflectance_at(data, lam_mult, lam)
                return [rho * s * v for v in c]
            def stats(table):
                one = []
                for k in range(m_quad):
                    lam, pdf = gen.sample_wavelength(table, (k + 0.5) / m_quad)
                    one.append([v / pdf for v in f(lam)])
                mean = [sum(e[k] for e in one) / m_quad for k in range(3)]
                y = 0.2126 * mean[0] + 0.7152 * mean[1] + 0.0722 * mean[2]
                var1 = [sum((e[k] - mean[k]) ** 2 for e in one) / m_quad for k in range(3)]
                q = m_quad // 4
                jit = []
                for k in range(q):
                    e4 = [sum(one[k + q * s][c] for s in range(4)) / 4.0 for c in range(3)]
                    jit.append(e4)
                varj = [sum((e[c] - mean[c]) ** 2 for e in jit) / q for c in range(3)]
                # Relative RMS colour noise per pixel sample, normalized by luminance.
                ind = math.sqrt(sum(v / 4.0 for v in var1) / 3.0) / y
                jt = math.sqrt(sum(varj) / 3.0) / y
                return ind, jt
            ind, jt = stats(icdfs[i])
            uind, ujt = stats(uniform)
            check(jt <= ind * (1.0 + 1e-9), "%s/%s: jittered (%.4f) worse than independent (%.4f)" % (preset[0], name, jt, ind))
            worst_ratio = max(worst_ratio, jt / ind)
            lines.append("%-6s %-5s  independent %.4f  jittered %.4f  (x%.2f)   uniform-pdf jittered %.4f" % (
                preset[0], name, ind, jt, jt / ind, ujt))
    report("relative RMS colour noise of one 4-wavelength sample (sRGB channels / luminance):")
    for line in lines:
        print("    " + line)
    report("jittered m = 4 never exceeds independent sampling (worst ratio %.2f)" % worst_ratio)


def check_dispersion():
    for ior, abbe, scale in ((1.5, 20.0, 1.0), (1.33, 55.0, 1.0), (2.4, 20.0, 0.5)):
        a, b = gen.cauchy_coefficients(ior, abbe, scale)
        n = lambda lam: a + b / lam ** 2  # noqa: E731
        vd = (n(gen.LAMBDA_D) - 1.0) / (n(gen.LAMBDA_F) - n(gen.LAMBDA_C))
        check(abs(n(gen.LAMBDA_D) - ior) < 1e-12 and abs(vd - abbe / scale) < 1e-9, "Cauchy fit %s" % ((ior, abbe, scale),))
    check(gen.cauchy_coefficients(1.5, 20.0, 0.0) == (1.5, 0.0), "no dispersion at scale 0")
    report("OpenPBR Cauchy/Abbe dispersion fit reproduces n_d and V_d")


def check_gpu(data, lut, icdfs):
    if "--no-gpu" in sys.argv:
        report("GPU check skipped (--no-gpu)")
        return
    rng = random.Random(5)
    codes = [(r, g, b) for r in (0, 255) for g in (0, 255) for b in (0, 255)] + [(128, 128, 128), (18, 239, 253)]
    codes += [tuple(rng.randrange(256) for _ in range(3)) for _ in range(4096)]
    with tempfile.TemporaryDirectory(prefix="vibe-spectral-") as directory:
        d = pathlib.Path(directory)
        binary = d / "SpectralGPU"
        result = subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", str(ROOT / "tests/SpectralGPU.swift"),
                                 "-o", str(binary)], capture_output=True, text=True, timeout=600)
        check(result.returncode == 0, "SpectralGPU.swift compiles: " + result.stderr[-2000:])
        moments = bytearray()
        # The 16-bit encoding of each code's moments (the table's, or the interpolated grid's).
        encoded = [lut_entry(lut, code) if lut is not None else gen.encode_moments(moments_of(code, "grid")) for code in codes]
        for q in encoded:
            moments += struct.pack("<4H", *(tuple(q) + (0,)))
        # Moments outside the valid set (e.g. after lossy compression): Alg. 2 biasing must still
        # give a bounded reflectance.
        invalid = [(0.1, 0.3, 0.0), (0.02, -0.3, 0.3), (0.5, 0.31, 0.31), (0.97, 0.3, -0.3), (0.0, 0.0, 0.0), (1.0, 0.0, 0.0)]
        for c in invalid:
            moments += struct.pack("<4H", *(gen.encode_moments(c) + (0,)))
        (d / "moments.bin").write_bytes(bytes(moments))
        samples = []
        for i in range(len(gen.ILLUMINANTS)):
            for k in range(257):
                samples.append((k / 256.0 * 0.999999 + 1e-7, i))
        (d / "samples.bin").write_bytes(b"".join(struct.pack("<fI", u, i) for u, i in samples))
        run = subprocess.run([str(binary), str(TABLES / "SpectralTables.metal"), str(d / "moments.bin"),
                              str(d / "samples.bin"), str(d)], capture_output=True, text=True, timeout=600)
        if run.returncode != 0 and "no Metal device" in run.stderr:
            report("GPU check skipped: no Metal device")
            return
        check(run.returncode == 0, "SpectralGPU runs: " + run.stderr[-2000:])
        count = len(codes) + len(invalid)
        colour = struct.unpack("<%df" % (4 * count), (d / "colour.bin").read_bytes())
        lagr = struct.unpack("<%df" % (4 * count), (d / "lagrange.bin").read_bytes())
        waves = struct.unpack("<%df" % (2 * len(samples)), (d / "wavelength.bin").read_bytes())
    worst = (0.0, None)
    worst_lin = 0.0
    worst_l = 0.0
    for n, code in enumerate(codes):
        rgb = colour[4 * n:4 * n + 3]
        err = max(abs(gen.srgb_oetf(rgb[k]) * 255.0 - code[k]) for k in range(3))
        if err > worst[0]:
            worst = (err, code)
        ref = gen.linear_srgb_of_moments(data, gen.decode_moments(encoded[n]))
        worst_lin = max(worst_lin, max(abs(rgb[k] - ref[k]) for k in range(3)))
        lam = gen.lagrange3(*gen.clamp_moments(gen.decode_moments(encoded[n])))
        if max(abs(v) for v in lam) < 50.0:
            worst_l = max(worst_l, max(abs(lagr[4 * n + k] - lam[k]) / (1.0 + abs(lam[k])) for k in range(3)))
    for n in range(len(codes), len(codes) + len(invalid)):
        rgb = colour[4 * n:4 * n + 3]
        y = sum(data.rgb_to_xyz[1][k] * rgb[k] for k in range(3))
        check(all(math.isfinite(v) for v in rgb + lagr[4 * n:4 * n + 3]) and -1e-4 <= y <= 1.0 + 1e-4,
              "biased reconstruction of invalid moments %s is bounded (Y = %r)" % (invalid[n - len(codes)], y))
    check(worst[0] < 0.75, "GPU float32 round trip: max 8-bit error %.3f at %s" % worst)
    check(worst_lin < 2e-3, "GPU float32 colour vs float64: %.2e" % worst_lin)
    worst_w = 0.0
    worst_p = 0.0
    # The GPU samples its float32 copy of each table and returns that table's own pdf, which is
    # what keeps f / p unbiased; compare against the include's nodes rounded to float32.
    f32 = lambda v: struct.unpack("<f", struct.pack("<f", v))[0]  # noqa: E731
    tables = [[f32(v) for v in table] for table in icdfs]
    for n, (u, i) in enumerate(samples):
        u32 = struct.unpack("<f", struct.pack("<f", u))[0]
        lam, pdf = gen.sample_wavelength(tables[i], u32)
        worst_w = max(worst_w, abs(waves[2 * n] - lam))
        worst_p = max(worst_p, abs(waves[2 * n + 1] - pdf) / pdf)
    check(worst_w < 1e-3 and worst_p < 1e-4, "GPU wavelength sampling: %.2e nm, pdf %.2e" % (worst_w, worst_p))
    report("GPU (float32, relaxed math) include: %d colours, 8-bit error max %.3f (at %s), linear |GPU - CPU| %.1e, "
           "Lagrange rel. %.1e; %d invalid moment vectors biased to bounded reflectances; wavelength sampling %.1e nm, pdf rel. %.1e" % (
               len(codes), worst[0], worst[1], worst_lin, worst_l, len(invalid), worst_w, worst_p))


def main():
    started = time.time()
    check((TABLES / "SpectralTables.json").is_file(), "build/SpectralTables missing; run scripts/generate_spectral_tables.py")
    data = gen.Data()
    check_inputs_and_manifest(data)
    icdfs, _ = check_include(data)
    check_mese()
    check_dispersion()
    lut = check_lut(data)
    check_sampling(data, icdfs)
    check_noise(data, icdfs, lut)
    if not QUICK:
        check_reproducible(lut)
    check_gpu(data, lut, icdfs)
    report("all checks passed in %.0f s" % (time.time() - started))


if __name__ == "__main__":
    main()
