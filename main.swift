import Cocoa
import Metal
import MetalKit
import MetalFX
import simd
import UniformTypeIdentifiers
import CoreImage
import ImageIO

// Algorithm/API citations and adaptation notes: REFERENCES.md (stable keys below).
// ============================================================================
// 1. Metal Shading Language: ReSTIR DI/GI and Path Tracing
// ============================================================================

/// Unbundled test builds (compiled with -D VIBE_TESTING) name the repository explicitly.
func runtimeRepositoryRoot() -> String? {
#if VIBE_TESTING
    return ProcessInfo.processInfo.environment["VIBE_TRACER_REPOSITORY"]
#else
    return nil
#endif
}

/// Resolves a shader, helper script or library inside the application bundle. Only test builds
/// may fall back to an absolute repository path; the working directory is never consulted.
func runtimeResourceURL(bundled: URL?, repositoryPath: String,
                        repository: String? = runtimeRepositoryRoot()) -> URL? {
    let manager = FileManager.default
    if let bundled, manager.fileExists(atPath: bundled.path) { return bundled }
    guard let repository, repository.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: repository, isDirectory: true).appendingPathComponent(repositoryPath)
    return manager.fileExists(atPath: url.path) ? url : nil
}

func loadOpenPBRSource() -> String {
    if let url = runtimeResourceURL(bundled: Bundle.main.resourceURL?.appendingPathComponent("OpenPBR.metal"),
                                    repositoryPath: "build/ShaderResources/OpenPBR.metal"),
       let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    return "#error Missing OpenPBR.metal. Build with build.sh before running.\n"
}

func shaderCompileOptions() -> MTLCompileOptions {
    let options = MTLCompileOptions()
    // Permit reassociation while retaining NaN/Inf handling in path guards.
    options.mathMode = .relaxed
    return options
}

let metalSource = loadOpenPBRSource() + """
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;

#define PI 3.14159265358979323846f
#define TWO_PI 6.28318530717958647692f

// Scene kernels (PathTracerRenderer.proceduralKernels) compile with VIBE_MESHES=0: scenes 0-5
// then carry no imported-mesh traversal or emitter code, which otherwise costs them registers.
// The default library, used for scene 6, by the checks and by the argument encoder, has it all.
#ifndef VIBE_MESHES
#define VIBE_MESHES 1
#endif
constant bool MESHES = VIBE_MESHES;
constant bool HARDWARE_MESHES = VIBE_MESHES;

// Light transport (PathTracerRenderer.lightTransport; docs/SPECTRAL_DESIGN.md). Spectral
// libraries compile with VIBE_SPECTRAL=1 after the generated SpectralTables.metal include
// (REFERENCES.md: PETERSBLOG2025, PETERS2019, FOURIERSRGB2019, HERO2014, CIEDATA): each path
// carries four wavelengths and its throughput is a Spectrum of their values. RGB libraries compile
// the `#else` branches, whose code is the RGB renderer's, with Spectrum = float3.
#ifndef VIBE_SPECTRAL
#define VIBE_SPECTRAL 0
#endif
#if VIBE_SPECTRAL
typedef float4 Spectrum;
#define SPECTRAL_KEEPS_NEGATIVE true
#else
typedef float3 Spectrum;
#define SPECTRAL_KEEPS_NEGATIVE false
#endif

// --- PRNG (PCG Hash) ---
// References: HASH2020, PCG2014; float conversion and seed feedback are local.
uint pcg_hash(uint input) {
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand_f(thread uint &seed) {
    seed = pcg_hash(seed);
    // Use 24 random bits so rounding cannot produce the excluded endpoint 1.
    return float(seed >> 8u) * (1.0f / 16777216.0f);
}

float2 rand_f2(thread uint &seed) {
    return float2(rand_f(seed), rand_f(seed));
}

// Both ReSTIR passes seed per pixel and sample identically through lens_ray.
// Pass 2 rehashes afterwards so its draws are independent of pass 1's.
void decorrelate_shading_seed(thread uint &seed) {
    seed = pcg_hash(seed ^ 0x27d4eb2fu);
}
float3 rand_f3(thread uint &seed) {
    return float3(rand_f(seed), rand_f(seed), rand_f(seed));
}
// Resampling decisions (reservoir updates, neighbour and cell choices) always draw from the
// PCG stream, in either sampler mode; see Sampler.
float rand_decision(thread uint &seed) { return rand_f(seed); }
// Sampling events of the Z sampler; a PCG stream ignores them (it is one sequential stream).
void sampler_event(thread uint &, uint, uint) {}
void sampler_candidate(thread uint &, uint, uint, uint, uint) {}

// --- Z++ sampler (REFERENCES.md: ZPP2026, ZSAMPLING2020, PBRT2023) ---
// Owen-scrambled low-discrepancy constituents indexed along a recursively shuffled Morton
// (Z) curve of the image, so that the Monte Carlo error of neighbouring pixels complements
// (blue-noise-like "Z noise") while every pixel's samples over successive frames form
// consecutive blocks of the sequence (Z++ temporal Z sampling). One 32-bit key per pixel
// and frame identifies all of its samples: dimension d's sequence index is a per-dimension
// base-4 digit shuffle of the key, so ReSTIR PT's random replay stores the key as its seed.
// 1D constituents are van der Corput points, 2D ones the first two Sobol' dimensions and 3D
// ones the O2m3 sequence of ZPP2026 Sec. 4.3 (Fig. 15), which is a (0, 2m, 3)-net over
// every aligned block of 4^m points, with (0, 2m, 2)-net pairwise projections.
uint z_mix(uint v) {
    // 32-bit integer finalizer (Wellons' lowbias32); local constants.
    v ^= v >> 16; v *= 0x7feb352du; v ^= v >> 15; v *= 0x846ca68bu; v ^= v >> 16;
    return v;
}
// The six permutations of four quadrants that fix quadrant 0, 8 bits each (digit -> 2-bit
// image). Any permutation of four is one of them followed by an XOR with a digit (S4 = S3 V4).
constant ulong Z_PERMUTATIONS = 0x6c9c78d8b4e4ul;
// Recursive quadrant shuffle of a Z index (PBRT2023 ZSobolSampler::GetSampleIndex): each of the
// low Z_SHUFFLE_DIGITS base-4 digits is permuted by one of the 24 permutations of four, chosen by
// a hash of the digits above it and of `dimension`. It maps every aligned block of 4^m indices
// onto an aligned block, so Z-order stratification survives the shuffle. The digits above
// (index bits 24-31: frames beyond 2^24 of one accumulation, or ReShuffle's hashed block) are
// kept; they only move samples within their first 2^-24.
#define Z_SHUFFLE_DIGITS 12u
uint z_shuffle(uint index, uint dimension) {
    uint seed = z_mix(dimension * 0x9e3779b9u + 0x632be5abu);
    uint result = index & ~((1u << (2u * Z_SHUFFLE_DIGITS)) - 1u);
    for (uint digitIndex = Z_SHUFFLE_DIGITS; digitIndex-- > 0u; ) {
        uint shift = 2u * digitIndex, digit = (index >> shift) & 3u;
        uint h = z_mix((index >> (shift + 2u)) ^ seed);
        uint sigma = ((h >> 16) * 6u) >> 16;
        uint image = uint(Z_PERMUTATIONS >> (8u * sigma + 2u * digit)) & 3u;
        result |= (image ^ (h & 3u)) << shift;
    }
    return result;
}
// Nested uniform (Owen) scrambling of a 0.32 fixed-point coordinate: the Laine-Karras hash
// with the constants of PBRT2023's FastOwenScrambler. Bit k flips depending only on bits
// above it, so every dyadic net stays a net.
uint z_owen(uint v, uint seed) {
    v = reverse_bits(v);
    v ^= v * 0x3d20adeau;
    v += seed;
    v *= (seed >> 16) | 1u;
    v ^= v * 0x05526c56u;
    v ^= v * 0x53a22864u;
    return reverse_bits(v);
}
uint z_owen_seed(uint dimension, uint axis) {
    uint h = (dimension ^ (axis << 24)) * 0x9e3779b9u;
    return (h ^ (h >> 16)) * 0x85ebca6bu;
}
// Second Sobol' dimension (the binary Pascal matrix) of sequence index i, as a 0.32 fraction.
// Digit r + 1 is the coefficient of x^r in sum_j i_j (x + 1)^j, a Taylor shift by one in GF(2),
// which five shift-XOR steps compute (a local derivation of the O(log m) evaluation that
// ZPP2026 Sec. 5.3.6 obtains for O2m3 by diagonal factoring).
uint z_sobol1(uint i) {
    i ^= (i & 0xAAAAAAAAu) >> 1;
    i ^= (i & 0xCCCCCCCCu) >> 2;
    i ^= (i & 0xF0F0F0F0u) >> 4;
    i ^= (i & 0xFF00FF00u) >> 8;
    i ^= (i & 0xFFFF0000u) >> 16;
    return reverse_bits(i);
}
// O2m3 (ZPP2026 Fig. 15): the three coordinates of the point with bit-reversed index V.
uint z_o2m3_x(uint V) {
    V ^= ((V << 2) & 0xF3CF3CF3u) ^ ((V << 3) & 0x41041041u);
    V ^= (V << 4) & 0x3F03F03Fu;
    V ^= (V << 8) & 0x0FFF000Fu;
    V ^= (V << 16) & 0x00FFFFFFu;
    return V;
}
uint z_o2m3_y(uint V) { return z_o2m3_x(((V >> 1) & 0x45145145u) ^ (V & 0xB5EB5EB5u) ^ ((V << 1) & 0x8A28A28Au)); }
uint z_o2m3_z(uint V) { return z_o2m3_x(((V >> 1) & 0x45145145u) ^ (V & 0x7AD7AD7Au) ^ ((V << 1) & 0x8A28A28Au)); }
float z_float(uint v) { return float(v >> 8) * (1.0f / 16777216.0f); }
// Morton index of a pixel, x in the even bits.
uint z_morton(uint2 p) {
    uint2 v = p & 0xFFFFu;
    v = (v | (v << 8)) & 0x00FF00FFu; v = (v | (v << 4)) & 0x0F0F0F0Fu;
    v = (v | (v << 2)) & 0x33333333u; v = (v | (v << 1)) & 0x55555555u;
    return v.x | (v.y << 1);
}

// A pixel's random numbers. In PCG mode every draw continues `state`, exactly as the earlier
// `thread uint &seed` streams did. In Z mode sampling draws come from the Z sampler: each
// sampling event (sampler_event: a path vertex and a stream such as BSDF or NEE) owns 32
// consecutive dimensions, and each rand_f / rand_f2 / rand_f3 call takes the event's next
// one, a 1D, 2D or 3D constituent. sampler_candidate adds `bits` low index bits for one of
// several candidates of an event (the index's block of 2^bits then covers them). Resampling
// decisions stay on `state` (rand_decision), which Z mode seeds as PCG mode does.
struct Sampler {
    uint state;
    uint key;
    uint dimension;
    uint sub;
    uint subBits;
    bool z;
};
// Sequence index of `dimension`: a nested binary scramble of the key (Owen scrambling of the key
// read as a fraction, so each bit flips depending only on the bits above it). Like z_shuffle it
// maps aligned blocks onto aligned blocks, so per-frame masks and per-pixel nets survive, and
// independent scrambles decorrelate the dimensions (padding). The key's pixel part is already
// quadrant-shuffled (z_pixel_key), which randomizes each node's pairing of its four children.
uint z_index(thread const Sampler &s, uint dimension) {
    return z_owen((s.key << s.subBits) | s.sub, z_owen_seed(dimension, 3u));
}
// A dimension's scrambles also depend on the key's top 8 bits, which a still accumulation keeps
// (the ReShuffle-like model draws them from a hash of its start): each accumulation is then one of
// 256 independent Owen randomizations, while all pixels and frames of it share one (masks and nets).
uint z_dimension(thread Sampler &s) { return s.dimension++ | ((s.key >> 24) << 17); }
float rand_f(thread Sampler &s) {
    if (!s.z) return rand_f(s.state);
    uint d = z_dimension(s);
    return z_float(z_owen(reverse_bits(z_index(s, d)), z_owen_seed(d, 0u)));
}
float2 rand_f2(thread Sampler &s) {
    if (!s.z) return rand_f2(s.state);
    uint d = z_dimension(s), i = z_index(s, d);
    return float2(z_float(z_owen(reverse_bits(i), z_owen_seed(d, 0u))),
                  z_float(z_owen(z_sobol1(i), z_owen_seed(d, 1u))));
}
float3 rand_f3(thread Sampler &s) {
    if (!s.z) return rand_f3(s.state);
    uint d = z_dimension(s), V = reverse_bits(z_index(s, d));
    return float3(z_float(z_owen(z_o2m3_x(V), z_owen_seed(d, 0u))),
                  z_float(z_owen(z_o2m3_y(V), z_owen_seed(d, 1u))),
                  z_float(z_owen(z_o2m3_z(V), z_owen_seed(d, 2u))));
}
float rand_decision(thread Sampler &s) { return rand_f(s.state); }
// Whether draws are Z constituents, which callers may join into one rand_f3 where the PCG
// stream draws them conditionally.
bool sampler_joint(thread uint &) { return false; }
bool sampler_joint(thread Sampler &s) { return s.z; }
// Sampling event streams (32 dimensions each, 16 per path vertex). ReSTIR PT's streams are
// Z_PT + its pt_seed stream (0 BSDF, 1 NEE, 2 roulette), apart from the shading pass's.
// Z_PT + 0..2 occupy streams 9-11. Z_WAVELENGTH (vertex 0) holds spectral transport's wavelength
// numbers (wavelength_numbers): u, then the hero choice, drawn identically by every pass of a pixel
// (as the lens is), so ReSTIR PT re-derives them from the reservoir key. Streams 13-15 are free.
constant uint Z_BSDF = 0u, Z_NEE = 1u, Z_ROULETTE = 2u, Z_LENS = 3u, Z_DI = 4u,
    Z_GI_BSDF = 5u, Z_GI_NEE = 6u, Z_CAUSTIC = 7u, Z_FOG = 8u, Z_PT = 9u, Z_WAVELENGTH = 12u;
void sampler_event(thread Sampler &s, uint pathVertex, uint stream) {
    s.dimension = (pathVertex * 16u + stream) * 32u; s.sub = 0u; s.subBits = 0u;
}
void sampler_candidate(thread Sampler &s, uint pathVertex, uint stream, uint index, uint bits) {
    sampler_event(s, pathVertex, stream); s.sub = index; s.subBits = bits;
}

// --- Data Types ---
struct Ray {
    float3 origin;
    float3 direction;
};

enum MaterialType {
    DIFFUSE = 0,
    GLOSSY = 1,
    DIELECTRIC = 2,
    EMISSIVE = 3,
    OPENPBR = 4
};

struct Material {
    MaterialType type;
    float3 albedo;
    float3 emission;
    float roughness;
    float ior;
    uint slot;
    float metalness;
    float coat;
    float anisotropy;
    float fuzz;
    float transmission;
    float3 tangent;
    float coatRoughness, specularWeight, baseWeight, diffuseRoughness;
    uint usesMaterialX;
    bool inside;
    float3 geometricNormal;
};

struct HitRecord {
    float t;
    float3 position;
    float3 normal;
    bool front_face;
    Material mat;
    float2 uv;
    float3 tangent;
    float3 bitangent;
    float2 uvDensity;
    float3 geometricNormal;
    uint objectID;
    uint triangle; // Mesh triangle index; 0xffffffff for analytic primitives.
    float error; // absolute bound on position rounding along geometricNormal
};

struct LightSample {
    float3 position;
    float3 wi;
    float3 emission;
    float dist;
    float pdf;
    uint isDirectional;
    // Spectral transport: the wavelength number of the path that drew the sample (Wavelengths.u).
    // Reused samples are evaluated at their own wavelengths, so emission stays the RGB value it
    // was drawn with. Zero in RGB libraries.
    float u;
};

struct Uniforms {
    float4 cameraPos;      // xyz = pos, w = fov
    float4 cameraTarget;   // xyz = target, w = maximum path depth (1 = direct lighting only); see scattering_limit
    float4 cameraUp;       // xyz = up, w = 0
    float4 sunParams;      // xyz = sun direction, w = sun intensity
    float4x4 currentViewProj;
    float4x4 prevViewProj;
    uint frameIndex;
    uint sceneIndex;
    uint samplingMode;     // 0 = ReSTIR DI+GI, 1 = MIS, 2 = Light, 3 = BSDF
    uint enableSMS;        // Legacy field name: 1 = artistic ring boost, 0 = off
    uint skyMode;          // 0 = Golden Hour, 1 = High Noon, 2 = Twilight/Studio
    uint enableFog;        // 1 = single-scatter camera fog, 0 = off
    uint viewportMode;     // 0 = beauty, 1 = albedo, 2 = normals, 3 = depth, 4 = material
    uint width;
    uint height;
    uint indirectReuse;    // IndirectReuse, ReSTIR PT and sampler options (former padding); see indirect_reuse_mode, sampler_z
    float2 jitter;         // Shared subpixel offset, in pixels, excluding the 0.5 pixel center.
    uint sampleIndex;      // Continues across orbit changes, independently of accumulation.
    uint reservoirHistoryReset; // 1 = DI/GI history reservoirs were just allocated; skip temporal reuse
    uint reservoirHistory; // Consecutive ReSTIR frames; camera moves keep it, cuts reset it.
    uint spatialNeighbors; // ReSTIR spatial reuse: 0 = uniform, 1 = compatibility-guided, 3 = stochastic pairwise MIS
    float4 environment; // intensity, rotation, image enabled, BVH node count
    float4 lens; // aperture radius, focus distance, scene-graph mode (see uses_scene_graph), independent sun 1 - cos(half angle)
    float4 light; // RGB multiplier, size multiplier
};

// lens.z = 1 renders scene 6 from the imported scene graph: per-triangle material
// slots and emission, an identity root transform, and float-scaled ray offsets.
bool uses_scene_graph(constant Uniforms &u) { return u.lens.z > 0; }

// Uniforms.indirectReuse: bits 0-1 select IndirectReuse (0 ReSTIR GI, 1 ReSTIR PT for
// paths of three or more vertices, 2 ReSTIR PT for every path); bit 2 enables the
// duplication-map confidence reduction (RESTIRPTE2026 Sec. 5, biased); bit 3 keeps temporal
// reuse on while a static view accumulates; bit 4 marks a reservoir-splatting frame (splat_frame);
// bit 5 shades ReSTIR PT with spatio-temporal control variates (restir_pt_control_variates).
uint indirect_reuse_mode(constant Uniforms &u) { return min(u.indirectReuse & 3u, 2u); }
bool restir_gi_active(constant Uniforms &u) { return indirect_reuse_mode(u) == 0; }
bool restir_pt_active(constant Uniforms &u) { return indirect_reuse_mode(u) != 0; }
bool restir_pt_unified(constant Uniforms &u) { return indirect_reuse_mode(u) == 2; }
bool restir_di_active(constant Uniforms &u) { return indirect_reuse_mode(u) != 2; }
bool restir_pt_decorrelates(constant Uniforms &u) { return (u.indirectReuse & 4u) != 0; }
// ReSTIR PT temporal reuse runs while the view changes (the first frame of an accumulation),
// and on every frame only with bit 3 (PathTracerRenderer.ptTemporalWhileAccumulating). Over a
// static accumulation it correlates frames (RESTIRPT2022 and RESTIRPTE2026 Sec. 7.4 recommend
// accumulating without it); spatial reuse continues on every frame.
bool restir_pt_temporal(constant Uniforms &u) { return u.frameIndex <= 1u || (u.indirectReuse & 8u) != 0u; }
// Bit 4: this frame reuses temporally by multi-layer reservoir splatting (HONG2026) instead of
// reprojection. The host sets it while the view changes (PathTracerRenderer.temporalReuse).
bool splat_frame(constant Uniforms &u) { return (u.indirectReuse & 16u) != 0u; }
// Bit 5: ReSTIR PT pixels are shaded with ReSTCV's accumulated colour estimate (RESTCV2026) instead
// of the reservoirs' resampled contribution (PathTracerRenderer.controlVariates). The host sets it
// only with paired spatial reuse, the MIS the method is defined with.
bool restir_pt_control_variates(constant Uniforms &u) { return restir_pt_active(u) && (u.indirectReuse & 32u) != 0u; }
// Bit 6: sampling draws come from the Z++ sampler instead of per-pixel PCG streams
// (PathTracerRenderer.sampler; REFERENCES.md ZPP2026). Bits 7-8 select its temporal model
// (ZTemporal): 0 per-pixel, 1 temporal interlacing (TZ), 2 spatiotemporal interlacing (STZ),
// 3 a fresh random block per accumulation (ReShuffle-like).
bool sampler_z(constant Uniforms &u) { return (u.indirectReuse & 64u) != 0u; }
uint sampler_z_temporal(constant Uniforms &u) { return (u.indirectReuse >> 7) & 3u; }

// Z++ key of a pixel for this frame: the recursively shuffled Morton index (Ahmed and Wonka's
// pixel ordering) XOR a temporal index t (ZPP2026 Eq. 3). A progressive accumulation that
// started at sample s0 is at frame j = frameIndex - 1, and t = T(s0) XOR j: over its first
// 2^n frames a pixel's keys are then one aligned block of 2^n keys, so every dimension gives
// it a complete (0, n)-net, and each frame is a Z mask. While the camera moves every frame
// starts an accumulation, and T sets how successive frames relate: the identity (per-pixel
// model), the TZ interlacing of Eq. 5, or a hash (a fresh block, as ReShuffle decorrelates).
// STZ also applies Eq. 6 to the pixel index. Unlike the paper, the XOR precedes the
// per-dimension shuffle (z_index), so one key serves all dimensions; see REFERENCES.md.
uint z_pixel_key(uint2 gid, constant Uniforms &u) {
    uint model = sampler_z_temporal(u);
    uint j = max(u.frameIndex, 1u) - 1u, s0 = u.sampleIndex - j;
    uint t = model == 1u || model == 2u ? s0 ^ ((s0 & 0xAAAAAAAAu) << 1) : model == 3u ? z_mix(s0 ^ 0x2c1b3c6du) : s0;
    uint k = z_shuffle(z_morton(gid), 0xffffffffu);
    if (model == 2u) k ^= k << 2;
    return k ^ t ^ j;
}
// Pass 1 and pass 2 of a pixel start from this sampler (the PCG state both passes used before).
Sampler pixel_sampler(uint2 gid, constant Uniforms &u) {
    Sampler s;
    s.state = (gid.y * u.width + gid.x) ^ (u.sampleIndex * 1999999973u);
    s.z = sampler_z(u);
    s.key = s.z ? z_pixel_key(gid, u) : 0u;
    s.dimension = 0u; s.sub = 0u; s.subBits = 0u;
    return s;
}

// ============================================================================
// Procedural Physical Sky
// ============================================================================

// Sun cones test sin^2 through a cross product: 1 - cos is below float
// resolution near one for sub-degree suns (the UsdLux default is 0.53 degrees).
bool in_sun_cone(float3 d, float3 sunDir, float oneMinusCos) {
    float3 c = cross(d, sunDir);
    return dot(d, sunDir) > 0.0f && dot(c, c) <= oneMinusCos * (2.0f - oneMinusCos);
}
// One disc size per preset, shared by emission, cone sampling and its PDF.
float procedural_sun_one_minus_cos(uint skyMode) {
    return skyMode == 0 ? 8e-4f : (skyMode == 1 ? 7e-4f : 9e-4f);
}
// lens.w > 0: an imported directional sun (UsdLux DistantLight) evaluated
// outside the environment; sunParams.w is its irradiance at normal incidence.
float sun_one_minus_cos(constant Uniforms &u) {
    return u.lens.w > 0.0f ? u.lens.w : procedural_sun_one_minus_cos(u.skyMode);
}
float3 independent_sun_radiance(float3 d, constant Uniforms &u) {
    if (u.lens.w <= 0.0f || u.sunParams.w <= 0.0f || !in_sun_cone(d, normalize(u.sunParams.xyz), u.lens.w)) return float3(0.0f);
    return float3(u.sunParams.w / (PI * u.lens.w * (2.0f - u.lens.w)));
}

float3 eval_procedural_sky(float3 d, float4 sunParams, uint skyMode) {
    float3 sunDir = normalize(sunParams.xyz);
    float sunCos = dot(d, sunDir);
    float y = d.y;

    if (skyMode == 0) {
        float3 zenith  = float3(0.08f, 0.18f, 0.46f);
        float3 horizon = float3(0.96f, 0.52f, 0.22f);
        float3 ground  = float3(0.12f, 0.10f, 0.08f);

        float3 col;
        if (y >= 0.0f) {
            col = mix(horizon, zenith, pow(y, 0.40f));
            float mie = max(0.0f, sunCos);
            col += float3(1.0f, 0.70f, 0.30f) * pow(mie, 6.0f) * 3.0f;
            if (in_sun_cone(d, sunDir, procedural_sun_one_minus_cos(skyMode))) {
                col += float3(1.0f, 0.78f, 0.45f) * (sunParams.w * 0.45f);
            }
        } else {
            col = mix(ground, horizon * 0.35f, pow(1.0f + y, 5.0f));
        }
        return col * 1.5f;
    } else if (skyMode == 1) {
        float3 zenith  = float3(0.16f, 0.42f, 0.92f);
        float3 horizon = float3(0.74f, 0.85f, 0.96f);
        float3 ground  = float3(0.14f, 0.15f, 0.12f);

        float3 col;
        if (y >= 0.0f) {
            col = mix(horizon, zenith, pow(y, 0.48f));
            float mie = max(0.0f, sunCos);
            col += float3(1.0f, 0.98f, 0.92f) * pow(mie, 12.0f) * 2.2f;
            if (in_sun_cone(d, sunDir, procedural_sun_one_minus_cos(skyMode))) {
                col += float3(1.0f, 0.98f, 0.94f) * (sunParams.w * 0.40f);
            }
        } else {
            col = mix(ground, horizon * 0.40f, pow(1.0f + y, 4.0f));
        }
        return col * 1.8f;
    } else {
        float3 zenith  = float3(0.04f, 0.06f, 0.14f);
        float3 horizon = float3(0.46f, 0.26f, 0.42f);
        float3 ground  = float3(0.04f, 0.04f, 0.05f);

        float3 col;
        if (y >= 0.0f) {
            col = mix(horizon, zenith, pow(y, 0.55f));
            float mie = max(0.0f, sunCos);
            col += float3(0.95f, 0.65f, 0.75f) * pow(mie, 10.0f) * 1.8f;
            if (in_sun_cone(d, sunDir, procedural_sun_one_minus_cos(skyMode))) {
                col += float3(1.0f, 0.85f, 0.78f) * (sunParams.w * 0.35f);
            }
        } else {
            col = mix(ground, horizon * 0.25f, pow(1.0f + y, 3.0f));
        }
        return col * 1.6f;
    }
}

// ============================================================================
// Geometry Primitives

struct ObjectSettings {
    float4 positionScale;
    float4 rotationHidden;
    float4 uvTransform;
    uint4 channels;
};
struct MeshTriangle { float4 a, b, c, na, nb, nc, uvab, uvc; };
struct MeshNode { float4 lo, hi; int4 links; };
struct GraphInstruction { int4 code; float4 value, extra, auxiliary; };
struct GraphHeader { int4 roots0, roots1, roots2, info; };
struct MaterialResources {
    array<texture2d<float>, 256> maps [[id(0)]];
    texture2d<float> environmentMap [[id(256)]];
    device MeshTriangle *triangles [[id(257)]];
    device MeshNode *nodes [[id(258)]];
    device ObjectSettings *objects [[id(259)]];
    array<texture2d<float>,128> graphImages [[id(260)]];
    device GraphInstruction *graphInstructions [[id(388)]];
    device GraphHeader *graphHeaders [[id(389)]];
    device float4 *emissions [[id(390)]];
    device uint *emitters [[id(391)]];
    texture2d<float> environmentRows [[id(392)]];
    texture2d<float> environmentColumns [[id(393)]];
};

// Radiance of the area light of scenes 1, 3, 4 and 5 before the light tint (Uniforms.light).
float3 procedural_light_emission(uint sceneIndex) {
    if (sceneIndex == 5u) return float3(45.0f, 42.0f, 38.0f);
    return (sceneIndex == 4) ? float3(32.0f, 28.0f, 22.0f) :
           (sceneIndex == 3) ? float3(24.0f, 20.0f, 15.0f) : float3(18.0f, 15.0f, 10.0f);
}

// ============================================================================
// Spectral light transport (docs/SPECTRAL_DESIGN.md; REFERENCES.md PETERSBLOG2025)
// ============================================================================
// Scene data stays RGB everywhere (materials, textures, MaterialX graphs, lights, reservoirs'
// emission). A path converts it to its four wavelengths where it is used: bounded colours through
// the bounded MESE of their trigonometric moments (PETERS2019, FOURIERSRGB2019), emitters through a
// linear decomposition into white and the MESE spectra of the saturated sRGB corners (SMITS1999),
// times the emitter's illuminant S (D65 for RGB colours, so that an RGB emitter keeps its colour;
// spectral_emission). Contributions become linear sRGB where they
// are added, at the wavelengths of the estimator that produced them. In RGB libraries every helper
// below is the identity and Wavelengths is empty.
#if VIBE_SPECTRAL
// Per-slot wavelength-dependent OpenPBR parameters (MaterialLibrary.spectralMaterials).
struct SpectralMaterial {
    float dispersion;        // OpenPBR "dispersion" parameter 20 / V_d (V_d = Abbe number / dispersion scale); 0 = none
    float thinFilmWeight;    // thin_film_weight
    float thinFilmThickness; // thin_film_thickness, micrometres
    float thinFilmIOR;       // thin_film_ior
};
// Scene spectral state (PathTracerRenderer.spectralScene, buffer 27).
struct SpectralScene {
    uint lightIlluminant;    // VibeIlluminant of area and sphere lights and imported emitters (D65 = their RGB colour)
    uint sunIlluminant;      // VibeIlluminant of the sun (procedural disc, imported DistantLight)
    uint padding0, padding1;
    float nodes[88];          // linear sRGB of the coarse grid's nodes, codes 0, 3, ..., 255 (86 used)
    SpectralMaterial materials[64];
};
static_assert(sizeof(SpectralScene) == 1392, "Swift writes a 1392-byte SpectralScene");
// Buffer 28 (SpectralShaderCache.grid): the exactly solved 86^3 grid of FourierSRGB86.bin as float4
// (c0, c1, c2, 0), indexed (r * 86 + g) * 86 + b. Buffer 29 (PathTracerRenderer.spectralSampling),
// written by spectral_icdf_kernel: the scene's 1025-node wavelength inverse CDF, then at float4 257
// per nanometre the linear-sRGB CMFs and the cosine of Peters' phase (rgb, cos phase), then the
// emission basis (two float4 per nanometre: R, G, B and C, M, Y), then the kernel's scratch.
constant uint SPECTRAL_GRID = 86u;
constant uint SPECTRAL_CMF_TABLE = 257u;   // float4 offset of the per-nanometre (rgb CMF, cos phase) table
constant uint SPECTRAL_BASIS = 257u + 471u;   // float4 offset of the per-nanometre emission basis (2 per nm)
constant uint SPECTRAL_SCRATCH = 4u * (257u + 3u * 471u);   // float offset of the kernel's scratch

// Four wavelengths of one path sample from one number u: lambda_k = F^-1((u + k) / 4) for the scene's
// piecewise-linear inverse CDF (illuminant x |rgb CMF| with a 10% defensive term). A path keeps only
// its numbers: the wavelengths, their densities, CMFs and reflectance phases are read back from the
// sampling buffer where they are used (a few loads), because every register a path keeps live
// costs more in the path loops than those loads (tests/PERFORMANCE.md, "Spectral transport cost").
// The scene pointers ride along so that emitters and the environment can be evaluated wherever a
// Spectrum is formed.
struct Wavelengths {
    float u, heroU;         // the path's wavelength numbers (Z_WAVELENGTH dimensions 0 and 1)
    bool heroOnly;          // set at the path's first dispersive vertex (HERO2014); the lanes other
                            // than spectral_hero(wl) then carry zero throughput
    constant SpectralScene *scene;
    const device float4 *grid;
    const device float *icdf;
    constant Uniforms *uniforms;
    constant MaterialResources *images;
};

Wavelengths spectral_wavelengths(float u, float heroU, constant SpectralScene *scene, const device float4 *grid,
                                 const device float *icdf, constant Uniforms *uniforms, constant MaterialResources *images) {
    Wavelengths wl;
    wl.scene = scene; wl.grid = grid; wl.icdf = icdf; wl.uniforms = uniforms; wl.images = images;
    wl.u = u; wl.heroU = heroU; wl.heroOnly = false;
    return wl;
}
// The same scene with other wavelength numbers (reused samples, ReSTIR PT paths).
Wavelengths spectral_wavelengths(float u, float heroU, thread const Wavelengths &context) {
    Wavelengths wl = context;
    wl.u = u; wl.heroU = heroU; wl.heroOnly = false;
    return wl;
}
Wavelengths spectral_wavelengths(float u, thread const Wavelengths &context) {
    return spectral_wavelengths(u, context.heroU, context);
}
// The lane kept at the path's first dispersive vertex, chosen uniformly by heroU (HERO2014).
uint spectral_hero(thread const Wavelengths &wl) { return min(uint(wl.heroU * 4.0f), 3u); }

// Lane k's wavelength lambda_k = F^-1((u + k) / 4) and its share of the four-wavelength estimate,
// 1 / (4 p(lambda_k)) with the density actually sampled, 1 / (segments x node spacing), so f / p
// stays unbiased.
float spectral_lambda(thread const Wavelengths &wl, uint k, thread float &weight) {
    float x = (wl.u + float(k)) * 0.25f * float(VIBE_ICDF_SEGMENTS);
    uint i = min(uint(x), VIBE_ICDF_SEGMENTS - 1u);
    float low = wl.icdf[i], width = wl.icdf[i + 1u] - low;
    weight = 0.25f * float(VIBE_ICDF_SEGMENTS) * width;
    return low + (x - float(i)) * width;
}
float spectral_lambda(thread const Wavelengths &wl, uint k) {
    float share;
    return spectral_lambda(wl, k, share);
}
float4 spectral_lambdas(thread const Wavelengths &wl) {
    return float4(spectral_lambda(wl, 0u), spectral_lambda(wl, 1u), spectral_lambda(wl, 2u), spectral_lambda(wl, 3u));
}
// The 1 nm bin of lambda. Colours are defined by 1 nm sums (the generator's colour model, the
// XYZ -> sRGB matrix and the presets' luminance), so CMFs, illuminants, the emission basis and the
// reflectance phase are all evaluated at the nearest node: the estimator's expectation is then
// exactly those sums (a grey under D65 renders as RGB does, a reflectance's colour is its 1 nm sum).
uint spectral_bin(float lambda) {
    return min(uint(clamp(lambda - VIBE_LAMBDA_MIN + 0.5f, 0.0f, float(VIBE_SPECTRAL_SAMPLES - 1u))), VIBE_SPECTRAL_SAMPLES - 1u);
}
// cos of Peters' warped phase (PETERS2019 Sec. 4.1) at each lambda_k's 1 nm bin.
float4 spectral_cos_phase(thread const Wavelengths &wl) {
    const device float4 *cmf = (const device float4 *)wl.icdf + SPECTRAL_CMF_TABLE;
    return float4(cmf[spectral_bin(spectral_lambda(wl, 0u))].w, cmf[spectral_bin(spectral_lambda(wl, 1u))].w,
                  cmf[spectral_bin(spectral_lambda(wl, 2u))].w, cmf[spectral_bin(spectral_lambda(wl, 3u))].w);
}
// Linear sRGB of a Spectrum: sum_k s_k M xyz(lambda_k) / (4 p(lambda_k)), with the CMFs of
// lambda_k's 1 nm bin.
float3 spectrum_rgb(Spectrum s, thread const Wavelengths &wl) {
    const device float4 *cmf = (const device float4 *)wl.icdf + SPECTRAL_CMF_TABLE;
    float3 rgb = float3(0.0f);
    for (uint k = 0u; k < 4u; ++k) {
        float weight;
        float lambda = spectral_lambda(wl, k, weight);
        rgb += (s[k] * weight) * cmf[spectral_bin(lambda)].xyz;
    }
    return rgb;
}
float spectrum_max(Spectrum s) { return max(max(s.x, s.y), max(s.z, s.w)); }
float wavelength_u(thread const Wavelengths &wl) { return wl.u; }
// The wavelengths of a reused sample (DI, GI) that carries its own number u.
Wavelengths sample_wavelengths(float u, thread const Wavelengths &wl) {
    if (u == wl.u) return wl;
    return spectral_wavelengths(u, wl);
}

// Trigonometric moments of a bounded linear sRGB colour: the coarse grid's exact solutions
// interpolated trilinearly in linear light (the generator's `interpolate`, so 8-bit codes match
// the cells FourierSRGB256 was built from). Cells in which that reproduces an 8-bit code worse than
// 0.35 steps (5,278 of 614,125, saturated colours at the gamut boundary; spectral_refine_flags_kernel)
// are refined: their lower-corner node holds slot + 1 in w, and a block of the grid buffer holds the
// exact moments of the cell's 4 x 4 x 4 codes (spectral_refine_solve_kernel), interpolated in the same
// way at one-code spacing. tests/Fix_spectral.swift measures the round trip over every code.
constant uint SPECTRAL_REFINED = 86u * 86u * 86u;     // float4 offset of the refined blocks
constant uint SPECTRAL_REFINED_CAPACITY = 8192u;      // blocks (PathTracerRenderer.spectralGridBytes)
float3 spectral_eotf(float3 v) { return select(pow((v + 0.055f) / 1.055f, float3(2.4f)), v / 12.92f, v <= 0.04045f); }
// Position in coarse-node units (code / 3) of a linear colour in [0, 1].
float3 spectral_code85(float3 c) {
    return select(1.055f * pow(c, float3(1.0f / 2.4f)) - 0.055f, 12.92f * c, c <= 0.0031308f) * 85.0f;
}
uint3 spectral_cell(float3 code85) { return min(uint3(max(code85, 0.0f)), uint3(SPECTRAL_GRID - 2u)); }
float3 spectral_moments_coarse(float3 c, float3 code85, uint3 i, thread const Wavelengths &wl) {
    constant float *nodes = wl.scene->nodes;
    float3 low = float3(nodes[i.x], nodes[i.y], nodes[i.z]);
    float3 high = float3(nodes[i.x + 1u], nodes[i.y + 1u], nodes[i.z + 1u]);
    float3 t = saturate((c - low) / (high - low));
    const device float4 *grid = wl.grid;
    float3 m = float3(0.0f);
    for (uint a = 0u; a < 2u; ++a) for (uint b = 0u; b < 2u; ++b) {
        uint row = ((i.x + a) * SPECTRAL_GRID + (i.y + b)) * SPECTRAL_GRID + i.z;
        float w = (a == 0u ? 1.0f - t.x : t.x) * (b == 0u ? 1.0f - t.y : t.y);
        m += w * ((1.0f - t.z) * grid[row].xyz + t.z * grid[row + 1u].xyz);
    }
    return m;
}
float3 spectral_moments(float3 c, thread const Wavelengths &wl) {
    float3 code85 = spectral_code85(c);
    uint3 i = spectral_cell(code85);
    float slot = wl.grid[(i.x * SPECTRAL_GRID + i.y) * SPECTRAL_GRID + i.z].w;
    if (!(slot > 0.0f)) return spectral_moments_coarse(c, code85, i, wl);
    uint3 s = min(uint3(max(code85 * 3.0f - float3(3u * i), 0.0f)), uint3(2u));
    float3 n0 = float3(3u * i + s);
    float3 low = spectral_eotf(n0 / 255.0f), high = spectral_eotf((n0 + 1.0f) / 255.0f);
    float3 t = saturate((c - low) / (high - low));
    const device float4 *block = wl.grid + SPECTRAL_REFINED + 64u * (uint(slot) - 1u);
    float3 m = float3(0.0f);
    for (uint a = 0u; a < 2u; ++a) for (uint b = 0u; b < 2u; ++b) {
        uint row = ((s.x + a) * 4u + (s.y + b)) * 4u + s.z;
        float w = (a == 0u ? 1.0f - t.x : t.x) * (b == 0u ? 1.0f - t.y : t.y);
        m += w * ((1.0f - t.z) * block[row].xyz + t.z * block[row + 1u].xyz);
    }
    return m;
}
// A bounded linear sRGB colour as the Lagrange multipliers of its bounded MESE (w = 1), or, for a
// grey, its value (x, w = 2): greys are exactly flat (their moments c1 = c2 = 0), so white reflects one.
float4 spectral_lagrange(float3 rgb, thread const Wavelengths &wl) {
    float3 c = saturate(rgb);
    // Greys are exactly flat. Near-greys too (within 1e-4, far below an 8-bit step): near white the
    // bounded multipliers diverge.
    float lo = min(c.x, min(c.y, c.z)), hi = max(c.x, max(c.y, c.z));
    if (hi - lo <= 1e-4f) return float4((c.x + c.y + c.z) / 3.0f, 0.0f, 0.0f, 2.0f);
    return float4(vibe_fourier_lagrange(spectral_moments(c, wl)), 1.0f);
}
// Bounded reflectance rho(lambda_k) from those multipliers (PETERS2019 Eq. 11).
Spectrum spectral_from_lagrange(float4 L, thread const Wavelengths &wl) {
    if (L.w == 2.0f) return Spectrum(L.x);
    float4 x = spectral_cos_phase(wl);
    float4 series = L.x + 2.0f * L.y * x + 2.0f * L.z * (2.0f * x * x - 1.0f);
    return atan(series) * 0.318309886f + 0.5f;
}
Spectrum spectral_reflectance(float3 rgb, thread const Wavelengths &wl) {
    return spectral_from_lagrange(spectral_lagrange(rgb, wl), wl);
}
// An illuminant's 1 nm bin at lambda (spectral_bin).
float spectral_illuminant(uint illuminant, float lambda) {
    return vibe_illuminant_spd[min(illuminant, VIBE_ILLUMINANT_COUNT - 1u)][spectral_bin(lambda)];
}
// Emission is upsampled linearly (Smits' decomposition, SMITS1999, with the bounded-MESE spectra of
// the six saturated sRGB corners as its basis): e = lo (1, 1, 1) + (mid - lo) secondary + (hi - mid)
// primary, where hi >= mid >= lo are e's sorted channels, the primary is the corner of e's largest
// channel and the secondary the corner of its two largest. The spectrum reproduces e's colour (the
// basis spectra's own colours to the table's precision), white is exactly the illuminant, and no
// colour is solved at run time: the basis is tabulated per nanometre in the sampling buffer.
struct SpectralEmissionWeights { float lo, secondary, primary; uint secondaryIndex, primaryIndex; };
SpectralEmissionWeights spectral_emission_weights(float3 e) {
    e = max(e, 0.0f);
    float hi = max(e.x, max(e.y, e.z)), lo = min(e.x, min(e.y, e.z)), mid = e.x + e.y + e.z - hi - lo;
    SpectralEmissionWeights w;
    w.primaryIndex = e.x == hi ? 0u : e.y == hi ? 1u : 2u;
    // The secondary (C, M, Y) is indexed by the channel it lacks: the smallest other than the primary.
    w.secondaryIndex = w.primaryIndex != 2u && e.z == lo ? 2u : w.primaryIndex != 1u && e.y == lo ? 1u : 0u;
    w.lo = lo; w.secondary = max(mid - lo, 0.0f); w.primary = max(hi - mid, 0.0f);
    return w;
}
float spectral_emission_basis(SpectralEmissionWeights w, const device float4 *basis, uint bin) {
    return w.lo + w.secondary * basis[2u * bin + 1u][w.secondaryIndex] + w.primary * basis[2u * bin][w.primaryIndex];
}
// Unbounded RGB radiance e of an emitter with illuminant S (normalized to luminance one).
Spectrum spectral_emission(float3 e, uint illuminant, thread const Wavelengths &wl) {
    if (!(max(e.x, max(e.y, e.z)) > 0.0f)) return Spectrum(0.0f);
    SpectralEmissionWeights w = spectral_emission_weights(e);
    const device float4 *basis = (const device float4 *)wl.icdf + SPECTRAL_BASIS;
    constant float *spd = vibe_illuminant_spd[min(illuminant, VIBE_ILLUMINANT_COUNT - 1u)];
    Spectrum result;
    for (uint k = 0u; k < 4u; ++k) {
        uint bin = spectral_bin(spectral_lambda(wl, k));
        result[k] = spectral_emission_basis(w, basis, bin) * spd[bin];
    }
    return result;
}
// The exact linear sRGB of that emission (1 nm sums), for paths without a scattering vertex
// (camera rays that see an emitter or the sky): their wavelength integral needs no sampling.
// With D65 the upsampled spectrum reproduces e within the basis' precision, so e is returned.
float3 spectral_emission_rgb(float3 e, uint illuminant, thread const Wavelengths &wl) {
    if (illuminant == VIBE_ILLUMINANT_D65 || !(max(e.x, max(e.y, e.z)) > 0.0f)) return e;
    SpectralEmissionWeights w = spectral_emission_weights(e);
    const device float4 *basis = (const device float4 *)wl.icdf + SPECTRAL_BASIS;
    constant float *spd = vibe_illuminant_spd[min(illuminant, VIBE_ILLUMINANT_COUNT - 1u)];
    float3 xyz = float3(0.0f);
    for (uint i = 0u; i < VIBE_SPECTRAL_SAMPLES; ++i) {
        float S = spd[i];
        if (S == 0.0f) continue;
        xyz += spectral_emission_basis(w, basis, i) * S * float3(vibe_cmf_x[i], vibe_cmf_y[i], vibe_cmf_z[i]);
    }
    return VIBE_XYZ_TO_LINEAR_SRGB * xyz;
}
Spectrum emitter_spectrum(float3 e, thread const Wavelengths &wl) { return spectral_emission(e, wl.scene->lightIlluminant, wl); }
float3 emitter_rgb(float3 e, thread const Wavelengths &wl) { return spectral_emission_rgb(e, wl.scene->lightIlluminant, wl); }

SpectralMaterial spectral_material(Material m, thread const Wavelengths &wl) {
    SpectralMaterial none = { 0.0f, 0.0f, 0.0f, 1.4f };
    return m.slot < 64u ? wl.scene->materials[m.slot] : none;
}
// Whether the material's index of refraction depends on wavelength (OpenPBR "Dispersion").
bool spectral_dispersive(Material m, thread const Wavelengths &wl) {
    return (m.type == DIELECTRIC || (m.type == OPENPBR && m.transmission > 0.0f && m.metalness < 1.0f))
        && spectral_material(m, wl).dispersion > 0.0f;
}
// HERO2014 at the first dispersive vertex: the four lanes would need four directions, so the path
// keeps lane `hero` (chosen uniformly by heroU), times four, and drops the others. Applied before
// the vertex scatters (NEE and BSDF sampling), never to its emission, in every pass that builds or
// shifts paths, so the integrand of a path and its wavelength numbers is one function.
void spectral_arrive(Material m, thread Spectrum &throughput, thread Wavelengths &wl) {
    if (wl.heroOnly || !spectral_dispersive(m, wl)) return;
    wl.heroOnly = true;
    throughput *= select(Spectrum(0.0f), Spectrum(4.0f), uint4(0u, 1u, 2u, 3u) == spectral_hero(wl));
}
Spectrum spectral_hero_lane(float value, thread const Wavelengths &wl) {
    return select(Spectrum(0.0f), Spectrum(value), uint4(0u, 1u, 2u, 3u) == spectral_hero(wl));
}
// The reflectance of a material's albedo; `rgb` is the value RGB transport uses (the saturated or raw
// albedo, which convert alike).
Spectrum spectral_albedo(Material, float3 rgb, thread const Wavelengths &wl) { return spectral_reflectance(rgb, wl); }
#else
struct Wavelengths {};
float3 spectrum_rgb(Spectrum s, thread const Wavelengths &) { return s; }
float spectrum_max(Spectrum s) { return max(s.x, max(s.y, s.z)); }
float wavelength_u(thread const Wavelengths &) { return 0.0f; }
Wavelengths sample_wavelengths(float, thread const Wavelengths &wl) { return wl; }
Spectrum spectral_reflectance(float3 rgb, thread const Wavelengths &) { return rgb; }
Spectrum emitter_spectrum(float3 e, thread const Wavelengths &) { return e; }
float3 emitter_rgb(float3 e, thread const Wavelengths &) { return e; }
void spectral_arrive(Material, thread Spectrum &, thread Wavelengths &) {}
Spectrum spectral_albedo(Material, float3 rgb, thread const Wavelengths &) { return rgb; }
#endif
float3 rotate_object(float3 p, float3 a) {
    p.yz = float2(cos(a.x)*p.y-sin(a.x)*p.z, sin(a.x)*p.y+cos(a.x)*p.z);
    p.xz = float2(cos(a.y)*p.x+sin(a.y)*p.z, -sin(a.y)*p.x+cos(a.y)*p.z);
    p.xy = float2(cos(a.z)*p.x-sin(a.z)*p.y, sin(a.z)*p.x+cos(a.z)*p.y);
    return p;
}
float3 inverse_rotate(float3 p, float3 a) {
    p = rotate_object(p, float3(0,0,-a.z));
    p = rotate_object(p, float3(0,-a.y,0));
    return rotate_object(p, float3(-a.x,0,0));
}
Ray object_ray(Ray r, ObjectSettings o) {
    return {inverse_rotate(r.origin-o.positionScale.xyz,o.rotationHidden.xyz)/o.positionScale.w,
            inverse_rotate(r.direction,o.rotationHidden.xyz)};
}
void world_hit(thread HitRecord &h, ObjectSettings o) {
    h.t *= o.positionScale.w;
    h.position = rotate_object(h.position*o.positionScale.w,o.rotationHidden.xyz)+o.positionScale.xyz;
    h.normal = rotate_object(h.normal,o.rotationHidden.xyz);
    h.geometricNormal = rotate_object(h.geometricNormal,o.rotationHidden.xyz);
    h.tangent = rotate_object(h.tangent,o.rotationHidden.xyz);
    h.bitangent = rotate_object(h.bitangent,o.rotationHidden.xyz);
    h.uvDensity /= o.positionScale.w;
}
// ============================================================================

bool intersect_sphere_local(Ray r, float3 center, float radius, Material mat, float t_min, float t_max, thread HitRecord &rec) {
    float3 oc = r.origin - center;
    float b = dot(oc, r.direction);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - c;
    if (disc > 0.0f) {
        float s = sqrt(disc);
        float t = -b - s;
        if (t < t_max && t > t_min) {
            rec.t = t;
            rec.position = r.origin + t * r.direction;
            float3 out_norm = (rec.position - center) / radius;
            rec.front_face = dot(r.direction, out_norm) < 0.0f;
            rec.normal = rec.front_face ? out_norm : -out_norm;
            rec.mat = mat;
            rec.uv = float2(atan2(out_norm.z, out_norm.x) / TWO_PI + 0.5f, acos(clamp(out_norm.y, -1.0f, 1.0f)) / PI);
            rec.tangent = normalize(float3(-out_norm.z, 0, out_norm.x) + float3(1e-8f, 0, 0));
            rec.bitangent = cross(out_norm, rec.tangent);
            rec.uvDensity = float2(1.0f / (TWO_PI * radius * max(0.02f, length(out_norm.xz))), 1.0f / (PI * radius));
            rec.geometricNormal = rec.normal;
            return true;
        }
        t = -b + s;
        if (t < t_max && t > t_min) {
            rec.t = t;
            rec.position = r.origin + t * r.direction;
            float3 out_norm = (rec.position - center) / radius;
            rec.front_face = dot(r.direction, out_norm) < 0.0f;
            rec.normal = rec.front_face ? out_norm : -out_norm;
            rec.mat = mat;
            rec.uv = float2(atan2(out_norm.z, out_norm.x) / TWO_PI + 0.5f, acos(clamp(out_norm.y, -1.0f, 1.0f)) / PI);
            rec.tangent = normalize(float3(-out_norm.z, 0, out_norm.x) + float3(1e-8f, 0, 0));
            rec.bitangent = cross(out_norm, rec.tangent);
            rec.uvDensity = float2(1.0f / (TWO_PI * radius * max(0.02f, length(out_norm.xz))), 1.0f / (PI * radius));
            rec.geometricNormal = rec.normal;
            return true;
        }
    }
    return false;
}

bool intersect_quad_local(Ray r, float3 corner, float3 u, float3 v, float3 normal, bool one_sided, Material mat, float t_min, float t_max, thread HitRecord &rec) {
    float denom = dot(normal, r.direction);
    if (one_sided) {
        if (denom >= -1e-6f) return false;
    } else {
        if (abs(denom) < 1e-6f) return false;
    }

    float t = dot(corner - r.origin, normal) / denom;
    if (t < t_min || t > t_max) return false;

    float3 hit = r.origin + t * r.direction;
    float3 p = hit - corner;
    float len_u = length(u);
    float len_v = length(v);
    float3 norm_u = u / len_u;
    float3 norm_v = v / len_v;

    float proj_u = dot(p, norm_u);
    float proj_v = dot(p, norm_v);
    if (proj_u < 0.0f || proj_u > len_u || proj_v < 0.0f || proj_v > len_v) return false;

    rec.t = t;
    rec.position = hit;
    rec.front_face = denom < 0.0f;
    rec.normal = rec.front_face ? normal : -normal;
    rec.mat = mat;
    rec.uv = float2(proj_u / len_u, proj_v / len_v);
    rec.tangent = norm_u;
    rec.bitangent = norm_v;
    rec.uvDensity = float2(1.0f / len_u, 1.0f / len_v);
    rec.geometricNormal = rec.normal;
    return true;
}

bool intersect_box_local(Ray r, float3 center, float3 half_size, float yaw, Material mat, float t_min, float t_max, thread HitRecord &rec) {
    float cos_y = cos(-yaw);
    float sin_y = sin(-yaw);
    float3 rel_orig = r.origin - center;
    float3 loc_orig = float3(cos_y * rel_orig.x - sin_y * rel_orig.z, rel_orig.y, sin_y * rel_orig.x + cos_y * rel_orig.z);
    float3 loc_dir  = float3(cos_y * r.direction.x - sin_y * r.direction.z, r.direction.y, sin_y * r.direction.x + cos_y * r.direction.z);

    float near_t = -1e20f;
    float far_t = 1e20f;
    for (int axis = 0; axis < 3; ++axis) {
        if (abs(loc_dir[axis]) < 1e-8f) {
            if (abs(loc_orig[axis]) > half_size[axis]) return false;
            continue;
        }
        float t0 = (-half_size[axis] - loc_orig[axis]) / loc_dir[axis];
        float t1 = (half_size[axis] - loc_orig[axis]) / loc_dir[axis];
        near_t = max(near_t, min(t0, t1));
        far_t = min(far_t, max(t0, t1));
    }
    if (near_t > far_t) return false;
    // Rays starting inside a box must hit the exit face.
    near_t = near_t > t_min ? near_t : far_t;
    if (near_t <= t_min || near_t >= t_max) return false;

    rec.t = near_t;
    rec.position = r.origin + near_t * r.direction;
    float3 loc_hit = loc_orig + near_t * loc_dir;

    float3 excess = abs(loc_hit) / half_size;
    float3 loc_norm = float3(0.0f);
    if (excess.x > excess.y && excess.x > excess.z) loc_norm = float3(sign(loc_hit.x), 0, 0);
    else if (excess.y > excess.z) loc_norm = float3(0, sign(loc_hit.y), 0);
    else loc_norm = float3(0, 0, sign(loc_hit.z));

    float3 w_norm = float3(cos(yaw) * loc_norm.x - sin(yaw) * loc_norm.z, loc_norm.y, sin(yaw) * loc_norm.x + cos(yaw) * loc_norm.z);
    rec.front_face = dot(r.direction, w_norm) < 0.0f;
    rec.normal = rec.front_face ? w_norm : -w_norm;
    rec.mat = mat;
    // Image row 0 is the top edge: side faces map v downward and u to the
    // viewer's right (cross(up, outward normal)); the bottom mirrors the top.
    // Tangent and bitangent are dP/du and dP/dv, as on imported meshes.
    float3 localT, localB;
    float s = loc_norm.x + loc_norm.y + loc_norm.z;
    if (abs(loc_norm.x) > 0.5f) { localT = float3(0,0,-s); localB = float3(0,-1,0); rec.uv = float2(-s * loc_hit.z, -loc_hit.y) / (2.0f * half_size.zy) + 0.5f; rec.uvDensity = 1.0f / (2.0f * half_size.zy); }
    else if (abs(loc_norm.y) > 0.5f) { localT = float3(s,0,0); localB = float3(0,0,1); rec.uv = float2(s * loc_hit.x, loc_hit.z) / (2.0f * half_size.xz) + 0.5f; rec.uvDensity = 1.0f / (2.0f * half_size.xz); }
    else { localT = float3(s,0,0); localB = float3(0,-1,0); rec.uv = float2(s * loc_hit.x, -loc_hit.y) / (2.0f * half_size.xy) + 0.5f; rec.uvDensity = 1.0f / (2.0f * half_size.xy); }
    rec.tangent = float3(cos(yaw)*localT.x-sin(yaw)*localT.z, localT.y, sin(yaw)*localT.x+cos(yaw)*localT.z);
    rec.bitangent = float3(cos(yaw)*localB.x-sin(yaw)*localB.z, localB.y, sin(yaw)*localB.x+cos(yaw)*localB.z);
    rec.geometricNormal = rec.normal;
    return true;
}

bool intersect_cylinder_ring_local(Ray r, float3 center, float radius, float height, Material mat, float t_min, float t_max, thread HitRecord &rec) {
    float2 oc = r.origin.xz - center.xz;
    float a = dot(r.direction.xz, r.direction.xz);
    float b = dot(oc, r.direction.xz);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - a * c;
    if (disc <= 0.0f || a == 0.0f) return false;

    float s = sqrt(disc);
    float t1 = (-b - s) / a;
    float t2 = (-b + s) / a;

    float ts[2] = { t1, t2 };
    for (int i = 0; i < 2; ++i) {
        float t = ts[i];
        if (t > t_min && t < t_max) {
            float y = r.origin.y + t * r.direction.y;
            if (y >= center.y - height * 0.5f && y <= center.y + height * 0.5f) {
                rec.t = t;
                rec.position = r.origin + t * r.direction;
                float3 outward = normalize(float3(rec.position.x - center.x, 0.0f, rec.position.z - center.z));
                rec.front_face = dot(r.direction, outward) < 0.0f;
                rec.normal = rec.front_face ? outward : -outward;
                rec.mat = mat;
                // v runs downward like the sphere's, so image row 0 is the top rim.
                rec.uv = float2(atan2(outward.z, outward.x) / TWO_PI + 0.5f, 0.5f - (y - center.y) / height);
                rec.tangent = float3(-outward.z, 0, outward.x);
                rec.bitangent = float3(0,-1,0);
                rec.uvDensity = float2(1.0f / (TWO_PI * radius), 1.0f / height);
                rec.geometricNormal = rec.normal;
                return true;
            }
        }
    }
    return false;
}

// ============================================================================
// Scene Graph
// ============================================================================

bool intersect_sphere(Ray r, float3 center, float radius, Material mat, float t_min, float t_max, thread HitRecord &rec, device ObjectSettings *objects = nullptr) {
    if (!objects || mat.type == EMISSIVE) return intersect_sphere_local(r, center, radius, mat, t_min, t_max, rec);
    ObjectSettings o = objects[min(mat.slot,7u)];
    if (o.rotationHidden.w > 0.5f) return false;
    Ray local = object_ray(r,o);
    if (!intersect_sphere_local(local, center, radius, mat, t_min / o.positionScale.w, t_max / o.positionScale.w, rec)) return false;
    world_hit(rec,o); return true;
}
bool intersect_quad(Ray r, float3 corner, float3 u, float3 v, float3 normal, bool one_sided, Material mat, float t_min, float t_max, thread HitRecord &rec, device ObjectSettings *objects = nullptr) {
    if (!objects || mat.type == EMISSIVE) return intersect_quad_local(r, corner, u, v, normal, one_sided, mat, t_min, t_max, rec);
    ObjectSettings o = objects[min(mat.slot,7u)];
    if (o.rotationHidden.w > 0.5f) return false;
    Ray local = object_ray(r,o);
    if (!intersect_quad_local(local, corner, u, v, normal, one_sided, mat, t_min / o.positionScale.w, t_max / o.positionScale.w, rec)) return false;
    world_hit(rec,o); return true;
}
bool intersect_box(Ray r, float3 center, float3 half_size, float yaw, Material mat, float t_min, float t_max, thread HitRecord &rec, device ObjectSettings *objects = nullptr) {
    if (!objects || mat.type == EMISSIVE) return intersect_box_local(r, center, half_size, yaw, mat, t_min, t_max, rec);
    ObjectSettings o = objects[min(mat.slot,7u)];
    if (o.rotationHidden.w > 0.5f) return false;
    Ray local = object_ray(r,o);
    if (!intersect_box_local(local, center, half_size, yaw, mat, t_min / o.positionScale.w, t_max / o.positionScale.w, rec)) return false;
    world_hit(rec,o); return true;
}
bool intersect_cylinder_ring(Ray r, float3 center, float radius, float height, Material mat, float t_min, float t_max, thread HitRecord &rec, device ObjectSettings *objects = nullptr) {
    if (!objects || mat.type == EMISSIVE) return intersect_cylinder_ring_local(r, center, radius, height, mat, t_min, t_max, rec);
    ObjectSettings o = objects[min(mat.slot,7u)];
    if (o.rotationHidden.w > 0.5f) return false;
    Ray local = object_ray(r,o);
    if (!intersect_cylinder_ring_local(local, center, radius, height, mat, t_min / o.positionScale.w, t_max / o.positionScale.w, rec)) return false;
    world_hit(rec,o); return true;
}

// REFERENCES.md: PBRT2023 (roundoff background); local scene-dependent tolerance.
// Imported coordinates are meters, including sub-millimeter details. Keep the
// legacy procedural tolerance while scaling imported offsets with float precision.
float ray_epsilon(float3 p, constant Uniforms &u) {
    return u.sceneIndex==6 && uses_scene_graph(u) ? max(1e-7f, 9.536743e-7f * max(abs(p.x),max(abs(p.y),abs(p.z)))) : 0.001f;
}
float max_abs(float3 p) { return max(abs(p.x),max(abs(p.y),abs(p.z))); }
// Imported-scene rounding bounds (PBRT2023 6.8): a position computed as
// origin+t*direction rounds with |origin| and t, a barycentric one with the
// triangle's vertex magnitudes. 2^-20 and 2^-19 keep margin for relaxed math.
float ray_hit_error(Ray r, float t, float3 p, constant Uniforms &u) {
    return u.sceneIndex==6 && uses_scene_graph(u) ? max(ray_epsilon(p,u), 9.536743e-7f*(max_abs(r.origin)+t)) : ray_epsilon(p,u);
}
float mesh_hit_error(MeshTriangle tri, float3 p, constant Uniforms &u) {
    return u.sceneIndex==6 && uses_scene_graph(u) ? max(1e-7f, 1.907349e-6f*max(max_abs(tri.a.xyz),max(max_abs(tri.b.xyz),max_abs(tri.c.xyz)))) : ray_epsilon(p,u);
}
// A segment ending on a surface: the blocker distance there carries the
// rounding of both endpoints and of the segment length.
float endpoint_tolerance(float3 origin, float3 endpoint, float d, constant Uniforms &u) {
    float legacy=2.0f*ray_epsilon(endpoint,u);
    return u.sceneIndex==6 && uses_scene_graph(u) ? max(legacy, 1.907349e-6f*(max_abs(origin)+max_abs(endpoint)+d)) : legacy;
}
float ray_t_min(float3 origin, constant Uniforms &u) {
    return u.sceneIndex==6 && uses_scene_graph(u) ? ray_epsilon(origin,u)*0.25f : 0.001f;
}
// error is the originating hit's HitRecord.error; it never lowers the legacy offset.
float3 ray_origin(float3 p,float3 geometricNormal,float3 direction,constant Uniforms &u,float error=0.0f) {
    float offset=max(error,ray_epsilon(p,u));
    return p+geometricNormal*(dot(direction,geometricNormal)>=0 ? offset : -offset);
}

bool trace_scene(Ray r, uint sceneIndex, thread HitRecord &rec, device ObjectSettings *objects = nullptr, float lightSize = 1.0f, float3 lightTint = float3(1), float tMin = 0.001f) {
    float closest = 1e20f;
    bool hit = false;
    HitRecord t_rec;

    if (sceneIndex == 0) {
        Material travertine = { DIFFUSE, float3(0.84f, 0.82f, 0.78f), float3(0.0f), 0, 1 };
        travertine.slot = 1;
        Material back_wall  = { DIFFUSE, float3(0.88f, 0.87f, 0.84f), float3(0.0f), 0, 1 };
        Material terracotta = { DIFFUSE, float3(0.78f, 0.28f, 0.18f), float3(0.0f), 0, 1 };
        Material teak_wood  = { DIFFUSE, float3(0.38f, 0.24f, 0.15f), float3(0.0f), 0, 1 };

        if (intersect_quad(r, float3(-8, -1.0f, -8), float3(16, 0, 0), float3(0, 0, 16), float3(0, 1, 0), false, travertine, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        // Walls start at their top-left corner as seen from the room, so image
        // row 0 is the top edge and u runs to the viewer's right.
        if (intersect_quad(r, float3(3.8f, 3.0f, 2.8f), float3(-7.6f, 0, 0), float3(0, -4.0f, 0), float3(0, 0, -1), false, back_wall, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-3.8f, 3.0f, 2.8f), float3(0, 0, -4.8f), float3(0, -4.0f, 0), float3(1, 0, 0), false, terracotta, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        for (int i = 0; i < 4; ++i) {
            float z_pos = -0.6f + float(i) * 0.9f;
            if (intersect_box(r, float3(-0.6f, 2.7f, z_pos), float3(2.8f, 0.06f, 0.16f), 0.0f, teak_wood, 0.001f, closest, t_rec, objects)) {
                hit = true; closest = t_rec.t; rec = t_rec;
            }
        }

        Material plinth_mat = { DIFFUSE, float3(0.90f, 0.90f, 0.88f), float3(0.0f), 0, 1 };
        plinth_mat.slot = 6;
        if (intersect_box(r, float3(1.25f, -0.55f, 1.40f), float3(0.42f, 0.45f, 0.42f), 0.35f, plinth_mat, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material chrome = { GLOSSY, float3(0.96f, 0.96f, 0.98f), float3(0.0f), 0.001f, 1 };
        chrome.slot = 4;
        if (intersect_sphere(r, float3(1.25f, 0.25f, 1.40f), 0.38f, chrome, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material glass = { DIELECTRIC, float3(1.0f), float3(0.0f), 0.0f, 1.52f };
        glass.slot = 5;
        if (intersect_sphere(r, float3(-0.75f, -0.50f, 0.40f), 0.50f, glass, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material copper = { GLOSSY, float3(0.95f, 0.64f, 0.54f), float3(0.0f), 0.10f, 1 };
        copper.slot = 2;
        if (intersect_sphere(r, float3(-0.15f, -0.65f, 1.85f), 0.35f, copper, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        // Finite roughness avoids a many-bounce colored mirror cavity when the
        // hollow ring is viewed almost horizontally.
        Material gold_ring = { GLOSSY, float3(1.0f, 0.85f, 0.45f), float3(0.0f), 0.18f, 1 };
        gold_ring.slot = 3;
        if (intersect_cylinder_ring(r, float3(0.70f, -0.72f, 0.10f), 0.42f, 0.55f, gold_ring, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

    } else if (sceneIndex == 6) {
        Material floor = { DIFFUSE, float3(0.5f), float3(0), 0, 1 }; floor.slot = 1;
        if (intersect_quad(r,float3(-10,-1,-10),float3(20,0,0),float3(0,0,20),float3(0,1,0),false,floor,tMin,closest,t_rec,objects)) { hit=true; closest=t_rec.t; rec=t_rec; }
    } else if (sceneIndex == 1 || sceneIndex == 4) {
        Material white = { DIFFUSE, float3(0.73f), float3(0.0f), 0, 1 };
        Material red   = { DIFFUSE, float3(0.65f, 0.05f, 0.05f), float3(0.0f), 0, 1 };
        Material green = { DIFFUSE, float3(0.12f, 0.45f, 0.15f), float3(0.0f), 0, 1 };
        float3 emit = (sceneIndex == 4) ? float3(32.0f, 28.0f, 22.0f) : float3(18.0f, 15.0f, 10.0f);
        Material light = { EMISSIVE, float3(0.0f), emit, 0, 1 };

        if (intersect_quad(r, float3(-1, -1, -1), float3(2, 0, 0), float3(0, 0, 2), float3(0, 1, 0), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-1,  1, -1), float3(2, 0, 0), float3(0, 0, 2), float3(0, -1, 0), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3( 1,  1,  1), float3(-2, 0, 0), float3(0, -2, 0), float3(0, 0, -1), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-1,  1,  1), float3(0, 0, -2), float3(0, -2, 0), float3(1, 0, 0), true, red, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3( 1,  1, -1), float3(0, 0, 2), float3(0, -2, 0), float3(-1, 0, 0), true, green, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        if (intersect_quad(r, float3(0,0.999f,0)+(float3(-0.25f, 0.999f, -0.25f)-float3(0,0.999f,0))*lightSize, float3(0.5f, 0, 0)*lightSize, float3(0, 0, 0.5f)*lightSize, float3(0, -1, 0), true, light, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material tallBox = white; tallBox.slot=2; Material shortBox=white; shortBox.slot=6;
        if (intersect_box(r, float3(-0.33f, -0.4f, 0.35f), float3(0.3f, 0.6f, 0.3f), 0.32f, tallBox, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_box(r, float3( 0.33f, -0.7f, -0.25f), float3(0.3f, 0.3f, 0.3f), -0.30f, shortBox, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

    } else if (sceneIndex == 2) {
        Material floor_mat = { DIFFUSE, float3(0.2f), float3(0.0f), 0, 1 }; floor_mat.slot=1; floor_mat.slot=1;
        if (intersect_quad(r, float3(-10, -1, -10), float3(20, 0, 0), float3(0, 0, 20), float3(0, 1, 0), false, floor_mat, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        float roughnesses[4] = { 0.005f, 0.04f, 0.15f, 0.45f };
        float xs[4] = { -2.4f, -0.8f, 0.8f, 2.4f };
        for (int i = 0; i < 4; ++i) {
            Material plate_mat = { GLOSSY, float3(0.95f, 0.92f, 0.88f), float3(0.0f), roughnesses[i], 1 };
            plate_mat.slot = uint(i)+2;
            // Top-right corner as seen from the camera: image row 0 is the upper edge.
            float3 u = float3(-1.2f, 0.0f, 0.0f);
            float3 v = float3(0.0f, -1.4f * sin(0.6f), -1.4f * cos(0.6f));
            float3 c = float3(xs[i] - 0.6f, -0.85f, -0.5f) - u - v;
            float3 n = normalize(cross(u, v));
            if (intersect_quad(r, c, u, v, n, false, plate_mat, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        }

        float radii[4] = { 0.55f, 0.18f, 0.055f, 0.016f };
        float3 emits[4] = { float3(6.0f), float3(45.0f), float3(450.0f), float3(4000.0f) };
        for (int i = 0; i < 4; ++i) {
            Material l_mat = { EMISSIVE, float3(0.0f), emits[i], 0, 1 };
            if (intersect_sphere(r, float3(xs[i], 1.8f, 1.2f), radii[i]*lightSize, l_mat, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        }

    } else if (sceneIndex == 3) {
        Material white = { DIFFUSE, float3(0.73f), float3(0.0f), 0, 1 };
        Material red   = { DIFFUSE, float3(0.65f, 0.05f, 0.05f), float3(0.0f), 0, 1 };
        Material green = { DIFFUSE, float3(0.12f, 0.45f, 0.15f), float3(0.0f), 0, 1 };
        Material light = { EMISSIVE, float3(0.0f), float3(24.0f, 20.0f, 15.0f), 0, 1 };

        if (intersect_quad(r, float3(-1, -1, -1), float3(2, 0, 0), float3(0, 0, 2), float3(0, 1, 0), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-1,  1, -1), float3(2, 0, 0), float3(0, 0, 2), float3(0, -1, 0), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3( 1,  1,  1), float3(-2, 0, 0), float3(0, -2, 0), float3(0, 0, -1), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-1,  1,  1), float3(0, 0, -2), float3(0, -2, 0), float3(1, 0, 0), true, red, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3( 1,  1, -1), float3(0, 0, 2), float3(0, -2, 0), float3(-1, 0, 0), true, green, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        if (intersect_quad(r, float3(0,0.999f,0)+(float3(-0.2f, 0.999f, -0.2f)-float3(0,0.999f,0))*lightSize, float3(0.4f, 0, 0)*lightSize, float3(0, 0, 0.4f)*lightSize, float3(0, -1, 0), true, light, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material glass = { DIELECTRIC, float3(1.0f), float3(0.0f), 0.0f, 1.52f }; glass.slot=5;
        if (intersect_sphere(r, float3(-0.45f, -0.55f, -0.1f), 0.45f, glass, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material mirror = { GLOSSY, float3(0.95f), float3(0.0f), 0.001f, 1 }; mirror.slot=4;
        if (intersect_sphere(r, float3( 0.45f, -0.55f, 0.25f), 0.45f, mirror, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

    } else if (sceneIndex == 5) {
        Material floor_mat  = { DIFFUSE, float3(0.85f), float3(0.0f), 0, 1 }; floor_mat.slot=1;
        Material back_wall  = { DIFFUSE, float3(0.45f, 0.50f, 0.55f), float3(0.0f), 0, 1 };
        Material light_mat  = { EMISSIVE, float3(0.0f), float3(45.0f, 42.0f, 38.0f), 0, 1 };

        if (intersect_quad(r, float3(-5, -1, -5), float3(10, 0, 0), float3(0, 0, 10), float3(0, 1, 0), false, floor_mat, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3( 5,  4,  2), float3(-10, 0, 0), float3(0, -5, 0), float3(0, 0, -1), false, back_wall, 0.001f, closest, t_rec, objects))  { hit = true; closest = t_rec.t; rec = t_rec; }

        if (intersect_quad(r, float3(0,1.9f,-0.5f)+(float3(-0.15f, 1.9f, -0.65f)-float3(0,1.9f,-0.5f))*lightSize, float3(0.3f, 0, 0)*lightSize, float3(0, 0, 0.3f)*lightSize, float3(0, -1, 0), true, light_mat, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material gold_ring = { GLOSSY, float3(1.0f, 0.85f, 0.55f), float3(0.0f), 0.18f, 1 }; gold_ring.slot=3;
        if (intersect_cylinder_ring(r, float3(0.45f, -0.75f, -0.15f), 0.42f, 0.5f, gold_ring, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material chrome = { GLOSSY, float3(0.95f), float3(0.0f), 0.001f, 1 }; chrome.slot=4;
        if (intersect_sphere(r, float3(-0.65f, -0.55f, 0.15f), 0.45f, chrome, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
    }
    if (hit && rec.mat.type == EMISSIVE) rec.mat.emission *= lightTint;
    return hit;
}


// REFERENCES.md: WOOP2013 (3.3). The watertight test below decides edges in a translated
// and sheared frame, which rounds like moving each vertex by up to about
// 5 * 2^-24 * (|vertex - origin| + |vertex.z - origin.z|). Boxes are enlarged by a per-ray
// bound on that (and on the slab divisions): the paper's shifted origins, lo - (o + e) and
// hi - (o - e), so traversal never culls a triangle the edge test would hit.
struct MeshBoxRay { float3 low, high; };
MeshBoxRay mesh_box_ray(Ray local, MeshNode root) {
    float e=1.1920929e-6f*(max_abs(local.origin)+max(max_abs(root.lo.xyz),max_abs(root.hi.xyz)));
    return { local.origin+e, local.origin-e };
}
bool mesh_node_hit(MeshNode node, Ray local, MeshBoxRay box, float nearT, float farT) {
    for(int axis=0;axis<3;++axis) {
        if(abs(local.direction[axis])<1e-8f) { if(box.low[axis]<node.lo[axis] || box.high[axis]>node.hi[axis]) farT=-1; }
        else { float a=(node.lo[axis]-box.low[axis])/local.direction[axis], b=(node.hi[axis]-box.high[axis])/local.direction[axis]; nearT=max(nearT,min(a,b)); farT=min(farT,max(a,b)); }
    }
    return nearT<=farT;
}
// Interior nodes store their median-split axis in links.z; the child on the
// ray's near side is popped first so closer hits shrink the search early.
void push_mesh_children(MeshNode node, Ray local, thread int *stack, thread int &top) {
    if(top>=62) return;
    bool leftFirst=local.direction[clamp(node.links.z,0,2)]>=0;
    stack[top++]=leftFirst?node.links.y:node.links.x; stack[top++]=leftFirst?node.links.x:node.links.y;
}
// REFERENCES.md: WOOP2013. Watertight ray/triangle intersection (Woop, Benthin and Wald,
// JCGT 2(1), 2013; also PBRT2023 6.5.3). The ray is translated to the origin and sheared
// and scaled onto +z once per ray, so each 2D edge function depends only on the ray and
// that edge's two vertices, and an edge value of 0 counts as inside for both sides.
// The permutation and shear are folded into three rows applied to every vertex: rows x and
// y are e_kx - S_x e_kz and e_ky - S_y e_kz, row z is S_z e_kz. Their zero and unit entries
// are exact, so this is the paper's per-vertex transform without per-triangle indexing.
struct WatertightRay { float3 origin, x, y, z; };
WatertightRay watertight_ray(Ray r) {
    float3 d=abs(r.direction);
    int kz=d.x>d.y ? (d.x>d.z ? 0 : 2) : (d.y>d.z ? 1 : 2);
    int kx=kz==2 ? 0 : kz+1, ky=kx==2 ? 0 : kx+1;
    // Swapping x and y for a negative z direction preserves the winding.
    if(r.direction[kz]<0) { int s=kx; kx=ky; ky=s; }
    float3 ex=float3(kx==0,kx==1,kx==2), ey=float3(ky==0,ky==1,ky==2), ez=float3(kz==0,kz==1,kz==2);
    WatertightRay w;
    w.origin=r.origin;
    w.x=ex-ez*(r.direction[kx]/r.direction[kz]);
    w.y=ey-ez*(r.direction[ky]/r.direction[kz]);
    w.z=ez*(1.0f/r.direction[kz]);
    return w;
}
// p.x*q.y - p.y*q.x. Neighbours spanning a shared edge in opposite directions compute
// fl(fl(ab) - fl(cd)) and fl(fl(cd) - fl(ab)), exact negatives only while each product is
// rounded on its own: relaxed math would otherwise fuse one product into an FMA (MSL 4.1
// 1.6.3), which measurably reopened cracks. When the rounded products tie, their FMA
// rounding errors (exact) give the exact sign: the paper's double-precision fallback, which
// Metal lacks (it restores accuracy; the float test is already watertight).
float watertight_edge(float2 p, float2 q) {
    #pragma METAL fp contract(off)
    float x=p.x*q.y, y=p.y*q.x, e=x-y;
    if(e==0.0f) e=fma(p.x,q.y,-x)-fma(p.y,q.x,-y);
    return e;
}
// Two-sided hit in [tMin, tMax); b1 and b2 weight vertices b and c.
bool intersect_mesh_triangle(MeshTriangle tri, WatertightRay r, float tMin, float tMax, thread float &t, thread float &b1, thread float &b2) {
    float3 A=tri.a.xyz-r.origin, B=tri.b.xyz-r.origin, C=tri.c.xyz-r.origin;
    float2 a=float2(dot(r.x,A),dot(r.y,A)), b=float2(dot(r.x,B),dot(r.y,B)), c=float2(dot(r.x,C),dot(r.y,C));
    float U=watertight_edge(c,b), V=watertight_edge(a,c);
    // Opposite signs already mean a miss (the test below, applied early).
    if((U<0 && V>0) || (U>0 && V<0)) return false;
    float W=watertight_edge(b,a);
    if((U<0 || V<0 || W<0) && (U>0 || V>0 || W>0)) return false;
    // det = 0: the ray lies in the triangle's plane, or the triangle is degenerate.
    float det=U+V+W;
    if(det==0.0f) return false;
    float T=U*dot(r.z,A)+V*dot(r.z,B)+W*dot(r.z,C);
    float inverse=1.0f/det;
    t=T*inverse; b1=V*inverse; b2=W*inverse;
    return t>=tMin && t<tMax;
}
bool intersect_mesh_triangle(MeshTriangle tri, Ray local, float tMin, float tMax, thread float &t, thread float &b1, thread float &b2) {
    return intersect_mesh_triangle(tri,watertight_ray(local),tMin,tMax,t,b1,b2);
}

// Surface attributes at barycentrics (b1, b2) of a mesh triangle seen along `direction`.
// Traced hits and light samples on graph emitters share it, so both evaluate the
// same MaterialX inputs at the same point.
void mesh_hit_attributes(thread HitRecord &rec, MeshTriangle tri, float b1, float b2, float3 direction) {
    float3 e1=tri.b.xyz-tri.a.xyz, e2=tri.c.xyz-tri.a.xyz; float b0=1-b1-b2;
    float3 ng=normalize(cross(e1,e2)); rec.front_face=dot(ng,direction)<0;
    rec.geometricNormal=rec.front_face?ng:-ng;
    float3 smooth=b0*tri.na.xyz+b1*tri.nb.xyz+b2*tri.nc.xyz;
    rec.normal=dot(smooth,smooth)>1e-12f ? normalize(smooth) : rec.geometricNormal;
    if(dot(rec.normal,rec.geometricNormal)<0) rec.normal=-rec.normal;
    rec.uv=b0*tri.uvab.xy+b1*tri.uvab.zw+b2*tri.uvc.xy;
    float2 d1=tri.uvab.zw-tri.uvab.xy,d2=tri.uvc.xy-tri.uvab.xy; float uvDet=d1.x*d2.y-d1.y*d2.x;
    float3 tangent=abs(uvDet)>1e-8f ? (e1*d2.y-e2*d1.y)/uvDet : e1;
    tangent-=rec.normal*dot(tangent,rec.normal);
    if(dot(tangent,tangent)<1e-12f) tangent=cross(rec.normal,abs(rec.normal.y)<0.9f?float3(0,1,0):float3(1,0,0));
    rec.tangent=normalize(tangent);
    rec.bitangent=cross(rec.front_face?rec.normal:-rec.normal,rec.tangent)*(uvDet<0?-1.0f:1.0f);
    rec.uvDensity=float2(max(length(d1)/max(length(e1),1e-6f),length(d2)/max(length(e2),1e-6f)));
}

// REFERENCES.md: WALD2007, WIDEBVH2008, PBRT2023, WOOP2013. Two-level hierarchy
// (MeshSceneLayout on the host): a 4-wide TLAS over the visible instances in world space and
// a 4-wide binned-SAH BLAS per mesh asset in object space. BLAS nodes follow the stored
// triangles in the triangle buffer; the node buffer holds the header, the instances, the
// TLAS and the subset-to-slot table. A flat BVH (the reference path) leaves nodes[0].lo.w 0.
struct MeshWideNode { float4 lox, loy, loz, hix, hiy, hiz; int4 child; int4 count; };
struct MeshInstance { float4 world[3]; float4 local[3]; uint4 range; uint4 binding; float4 bound; };
struct MeshSceneHeader { uint4 info; uint4 counts; float4 lo, hi; uint4 accelerator; };
static_assert(sizeof(MeshWideNode) == 128 && sizeof(MeshInstance) == 144 && sizeof(MeshSceneHeader) == 80, "Swift mesh layouts");
// Hardware traversal (METALRT, header.counts.w = 1): header.accelerator holds the instance
// acceleration structure's resource ID, read as an argument-buffer member.
struct MeshAccelerator { raytracing::instance_acceleration_structure scene; };
device const MeshAccelerator &mesh_accelerator(constant MaterialResources &images) {
    return *(device const MeshAccelerator *)((device const char *)images.nodes+64);
}
bool mesh_two_level(constant MaterialResources &images) { return as_type<uint>(images.nodes[0].lo.w) == 0x3256544cu; }
device const MeshSceneHeader &mesh_header(constant MaterialResources &images) { return *(device const MeshSceneHeader *)images.nodes; }
device const MeshInstance *mesh_instances(constant MaterialResources &images) {
    return (device const MeshInstance *)((device const char *)images.nodes + sizeof(MeshSceneHeader));
}
float3 instance_point(MeshInstance m, float3 p) { return float3(dot(m.world[0].xyz,p)+m.world[0].w,dot(m.world[1].xyz,p)+m.world[1].w,dot(m.world[2].xyz,p)+m.world[2].w); }
// Object-space ray with the world ray's parameter: the direction is not renormalized.
Ray instance_ray(MeshInstance m, Ray r) {
    return {float3(dot(m.local[0].xyz,r.origin)+m.local[0].w,dot(m.local[1].xyz,r.origin)+m.local[1].w,dot(m.local[2].xyz,r.origin)+m.local[2].w),
            float3(dot(m.local[0].xyz,r.direction),dot(m.local[1].xyz,r.direction),dot(m.local[2].xyz,r.direction))};
}
// The world-space triangle an instance renders, as SceneGraph.forEachRenderTriangle flattens it
// (normals by the inverse transpose; a mirroring transform swaps b and c, and with them the
// barycentrics), with the bound slot in uvc.z, node index + 1 in uvc.w and the subset in na.w.
MeshTriangle instance_triangle(MeshTriangle t, MeshInstance m, constant MaterialResources &images, thread float &b1, thread float &b2) {
    if(m.binding.y==0) return t;
    uint subset=uint(t.uvc.z);
    MeshTriangle w=t;
    w.a=float4(instance_point(m,t.a.xyz),1); w.b=float4(instance_point(m,t.b.xyz),1); w.c=float4(instance_point(m,t.c.xyz),1);
    float3 n[3]={t.na.xyz,t.nb.xyz,t.nc.xyz};
    for(int k=0;k<3;++k) {
        float3 v=m.local[0].xyz*n[k].x+m.local[1].xyz*n[k].y+m.local[2].xyz*n[k].z;
        n[k]=dot(v,v)>1e-12f ? normalize(v) : float3(0,1,0);
    }
    w.na=float4(n[0],float(subset)); w.nb=float4(n[1],0); w.nc=float4(n[2],0);
    if((m.binding.z&1u)!=0) {
        float4 p=w.b; w.b=w.c; w.c=p; p=w.nb; w.nb=w.nc; w.nc=p;
        float2 uv=w.uvab.zw; w.uvab.zw=w.uvc.xy; w.uvc.xy=uv;
        float s=b1; b1=b2; b2=s;
    }
    const device uint *slots=(const device uint *)((device const char *)images.nodes+16*mesh_header(images).info.z);
    w.uvc.z=float(slots[m.binding.x+subset]); w.uvc.w=float(m.binding.y);
    return w;
}
// World triangle of a rendered-triangle ID (HitRecord.triangle, emitter lists): the stored
// triangle itself for a flat BVH, else the instance whose rendered range holds it.
MeshTriangle scene_triangle(uint id, constant MaterialResources &images) {
    if(!mesh_two_level(images)) return images.triangles[id];
    device const MeshInstance *instances=mesh_instances(images);
    uint low=0, high=max(1u,mesh_header(images).info.x)-1;
    while(low<high) { uint middle=(low+high+1)/2; if(instances[middle].range.z<=id) low=middle; else high=middle-1; }
    MeshInstance m=instances[low]; float b1=0, b2=0;
    return instance_triangle(images.triangles[m.range.x+(id-m.range.z)],m,images,b1,b2);
}
// Position rounding of a hit rebuilt from an instance's world corners: the bound of the
// corners themselves (mesh_hit_error) and of the transform that produced them.
float instance_hit_error(MeshTriangle t, MeshInstance m, float3 p, constant Uniforms &u) {
    float local=max(max_abs(t.a.xyz),max(max_abs(t.b.xyz),max_abs(t.c.xyz)));
    return u.sceneIndex==6 && uses_scene_graph(u) ? max(1e-7f, 1.907349e-6f*(m.bound.x+m.bound.y*local)) : ray_epsilon(p,u);
}
// A ray against the four child boxes of a node, conservatively as mesh_node_hit does
// (WOOP2013 3.3: boxes grow by the per-ray bound e through shifted origins).
struct WideRay { float3 low, high, inverse; bool3 parallel; };
WideRay wide_ray(Ray r, float e) {
    WideRay w; w.low=r.origin+e; w.high=r.origin-e; w.parallel=abs(r.direction)<1e-8f;
    w.inverse=1.0f/select(r.direction,float3(1),w.parallel);
    return w;
}
bool4 wide_node_hit(MeshWideNode n, WideRay w, float tMin, float tMax, thread float4 &nearT) {
    float4 ax=(n.lox-w.low.x)*w.inverse.x, bx=(n.hix-w.high.x)*w.inverse.x;
    float4 ay=(n.loy-w.low.y)*w.inverse.y, by=(n.hiy-w.high.y)*w.inverse.y;
    float4 az=(n.loz-w.low.z)*w.inverse.z, bz=(n.hiz-w.high.z)*w.inverse.z;
    float4 lx=w.parallel.x ? float4(-1e30f) : min(ax,bx), hx=w.parallel.x ? float4(1e30f) : max(ax,bx);
    float4 ly=w.parallel.y ? float4(-1e30f) : min(ay,by), hy=w.parallel.y ? float4(1e30f) : max(ay,by);
    float4 lz=w.parallel.z ? float4(-1e30f) : min(az,bz), hz=w.parallel.z ? float4(1e30f) : max(az,bz);
    nearT=max(max(lx,ly),max(lz,float4(tMin)));
    bool4 hit=nearT<=min(min(hx,hy),min(hz,float4(tMax))) && n.child!=0;
    if(w.parallel.x) hit=hit && !(w.low.x<n.lox || w.high.x>n.hix);
    if(w.parallel.y) hit=hit && !(w.low.y<n.loy || w.high.y>n.hiy);
    if(w.parallel.z) hit=hit && !(w.low.z<n.loz || w.high.z>n.hiz);
    return hit;
}
// Children hit, near to far (insertion sort of at most four).
int wide_order(bool4 hit, float4 nearT, thread int *order, thread float *key) {
    int m=0;
    for(int k=0;k<4;++k) if(hit[k]) { int j=m++; while(j>0 && key[j-1]>nearT[k]) { key[j]=key[j-1]; order[j]=order[j-1]; --j; } key[j]=nearT[k]; order[j]=k; }
    return m;
}
// Closest hit in one asset's BLAS, in object space. The host keeps BLAS depth <= 20, so the
// stack (at most 3 net pushes per level) never overflows.
void blas_closest(device const MeshWideNode *nodes, device const MeshTriangle *triangles, Ray local, float rootMax,
                  float tMin, thread float &closest, thread int &hit, thread float &hb1, thread float &hb2) {
    WatertightRay watertight=watertight_ray(local);
    WideRay w=wide_ray(local,1.1920929e-6f*(max_abs(local.origin)+rootMax));
    int stack[64]; int top=0; stack[top++]=0;
    while(top>0) {
        MeshWideNode node=nodes[stack[--top]];
        float4 nearT; int order[4]; float key[4];
        int m=wide_order(wide_node_hit(node,w,tMin,closest,nearT),nearT,order,key);
        for(int j=0;j<m;++j) {
            int k=order[j];
            if(node.child[k]>0 || key[j]>closest) continue;
            int first=-node.child[k]-1;
            for(int q=0;q<node.count[k];++q) {
                float t,b1,b2;
                if(!intersect_mesh_triangle(triangles[first+q],watertight,tMin,closest,t,b1,b2)) continue;
                closest=t; hit=first+q; hb1=b1; hb2=b2;
            }
        }
        for(int j=m-1;j>=0;--j) { int k=order[j]; if(node.child[k]>0 && key[j]<=closest && top<64) stack[top++]=node.child[k]; }
    }
}
// Any hit in [tMin, tMax - slack) of one asset; slack is the endpoint surface's own bound
// (see scene_occluded), from the instance transform and the triangle's local corners.
bool blas_any(device const MeshWideNode *nodes, device const MeshTriangle *triangles, Ray local, MeshInstance instance,
              float tMin, float tMax, bool slack) {
    WatertightRay watertight=watertight_ray(local);
    WideRay w=wide_ray(local,1.1920929e-6f*(max_abs(local.origin)+instance.bound.z));
    int stack[64]; int top=0; stack[top++]=0;
    while(top>0) {
        MeshWideNode node=nodes[stack[--top]];
        float4 nearT; bool4 hit=wide_node_hit(node,w,tMin,tMax,nearT);
        for(int k=0;k<4;++k) {
            if(!hit[k]) continue;
            if(node.child[k]>0) { if(top<64) stack[top++]=node.child[k]; continue; }
            int first=-node.child[k]-1;
            for(int q=0;q<node.count[k];++q) {
                MeshTriangle tri=triangles[first+q];
                float t,b1,b2,local=max(max_abs(tri.a.xyz),max(max_abs(tri.b.xyz),max_abs(tri.c.xyz)));
                float s=slack ? max(1e-7f,1.907349e-6f*(instance.bound.x+instance.bound.y*local)) : 0.0f;
                if(intersect_mesh_triangle(tri,watertight,tMin,tMax-s,t,b1,b2)) return true;
            }
        }
    }
    return false;
}
struct MeshHit { float t, b1, b2; int triangle; uint instance; };
// TLAS traversal. Its boxes are world bounds of transformed object bounds, grown per ray by
// lo.w * (|origin| + hi.w): the rounding of the object-space ray, amplified by the largest
// transform condition number, never culls an instance whose object-space traversal hits.
bool mesh_closest(Ray r, float tMin, float tMax, constant MaterialResources &images, thread MeshHit &h) {
    MeshSceneHeader header=mesh_header(images);
    if(HARDWARE_MESHES && header.counts.w!=0) {
        // Same instances and primitive order as the software hierarchy, so the hit resolves alike.
        raytracing::intersector<raytracing::triangle_data,raytracing::instancing> closest;
        closest.assume_geometry_type(raytracing::geometry_type::triangle);
        auto x=closest.intersect(raytracing::ray(r.origin,r.direction,tMin,tMax),mesh_accelerator(images).scene);
        if(x.type!=raytracing::intersection_type::triangle) return false;
        h.t=x.distance; h.b1=x.triangle_barycentric_coord.x; h.b2=x.triangle_barycentric_coord.y;
        h.triangle=int(x.primitive_id); h.instance=x.instance_id;
        return true;
    }
    device const MeshInstance *instances=mesh_instances(images);
    device const MeshWideNode *tlas=(device const MeshWideNode *)((device const char *)images.nodes+16*header.info.y);
    device const MeshWideNode *blas=(device const MeshWideNode *)images.triangles;
    WideRay w=wide_ray(r,header.lo.w*(max_abs(r.origin)+header.hi.w));
    float closest=tMax; bool found=false;
    int stack[32]; int top=0; stack[top++]=0;
    while(top>0) {
        MeshWideNode node=tlas[stack[--top]];
        float4 nearT; int order[4]; float key[4];
        int m=wide_order(wide_node_hit(node,w,tMin,closest,nearT),nearT,order,key);
        for(int j=0;j<m;++j) {
            int k=order[j];
            if(node.child[k]>0 || key[j]>closest) continue;
            uint index=uint(-node.child[k]-1);
            MeshInstance instance=instances[index];
            int triangle=-1; float b1=0, b2=0;
            blas_closest(blas+instance.range.y,images.triangles+instance.range.x,instance_ray(instance,r),instance.bound.z,tMin,closest,triangle,b1,b2);
            if(triangle>=0) { h.t=closest; h.b1=b1; h.b2=b2; h.triangle=triangle; h.instance=index; found=true; }
        }
        for(int j=m-1;j>=0;--j) { int k=order[j]; if(node.child[k]>0 && key[j]<=closest && top<32) stack[top++]=node.child[k]; }
    }
    return found;
}
bool mesh_occluded(Ray r, float tMin, float tMax, bool slack, constant MaterialResources &images) {
    MeshSceneHeader header=mesh_header(images);
    device const MeshInstance *instances=mesh_instances(images);
    if(HARDWARE_MESHES && header.counts.w!=0) {
        // Any opaque hit before tMax - S (S bounds every triangle's slack), then the candidates
        // in [tMax - S, tMax) against their own slack, exactly as blas_any decides.
        float S=slack ? max(1e-7f,1.907349e-6f*header.hi.w) : 0.0f;
        raytracing::instance_acceleration_structure scene=mesh_accelerator(images).scene;
        raytracing::intersector<raytracing::instancing> any;
        any.assume_geometry_type(raytracing::geometry_type::triangle);
        any.accept_any_intersection(true);
        if(tMax-S>tMin && any.intersect(raytracing::ray(r.origin,r.direction,tMin,tMax-S),scene).type==raytracing::intersection_type::triangle) return true;
        if(!slack) return false;
        raytracing::intersection_params params;
        params.assume_geometry_type(raytracing::geometry_type::triangle);
        params.force_opacity(raytracing::forced_opacity::non_opaque);
        raytracing::intersection_query<raytracing::instancing,raytracing::triangle_data> query(raytracing::ray(r.origin,r.direction,max(tMin,tMax-S),tMax),scene,params);
        while(query.next()) {
            MeshInstance instance=instances[query.get_candidate_instance_id()];
            MeshTriangle tri=images.triangles[instance.range.x+query.get_candidate_primitive_id()];
            float local=max(max_abs(tri.a.xyz),max(max_abs(tri.b.xyz),max_abs(tri.c.xyz)));
            if(query.get_candidate_triangle_distance()<tMax-max(1e-7f,1.907349e-6f*(instance.bound.x+instance.bound.y*local))) { query.abort(); return true; }
        }
        return false;
    }
    device const MeshWideNode *tlas=(device const MeshWideNode *)((device const char *)images.nodes+16*header.info.y);
    device const MeshWideNode *blas=(device const MeshWideNode *)images.triangles;
    WideRay w=wide_ray(r,header.lo.w*(max_abs(r.origin)+header.hi.w));
    int stack[32]; int top=0; stack[top++]=0;
    while(top>0) {
        MeshWideNode node=tlas[stack[--top]];
        float4 nearT; bool4 hit=wide_node_hit(node,w,tMin,tMax,nearT);
        for(int k=0;k<4;++k) {
            if(!hit[k]) continue;
            if(node.child[k]>0) { if(top<32) stack[top++]=node.child[k]; continue; }
            MeshInstance instance=instances[-node.child[k]-1];
            if(blas_any(blas+instance.range.y,images.triangles+instance.range.x,instance_ray(instance,r),instance,tMin,tMax,slack)) return true;
        }
    }
    return false;
}

// REFERENCES.md: PBRT2023, OBJ2026, WOOP2013. Watertight triangle test and median BVH.
bool trace_scene(Ray r, uint sceneIndex, thread HitRecord &rec, constant MaterialResources &images, constant Uniforms &u) {
    float tMin=ray_t_min(r.origin,u);
    bool hit=trace_scene(r,sceneIndex,rec,images.objects,u.light.w,u.light.xyz,tMin);
    if(hit) { rec.objectID=rec.mat.slot; rec.error=ray_hit_error(r,rec.t,rec.position,u); }
    rec.triangle=0xffffffffu;
    if (!MESHES || sceneIndex != 6 || u.environment.w < 1 || (!uses_scene_graph(u) && images.objects[7].rotationHidden.w > 0.5f)) return hit;
    ObjectSettings o=images.objects[7];
    if(uses_scene_graph(u)) { o.positionScale=float4(0,0,0,1);o.rotationHidden=float4(0); }
    Ray local=object_ray(r,o);
    float closest=hit ? rec.t/o.positionScale.w : 1e20f;
    if(mesh_two_level(images)) {
        MeshHit m;
        if(!mesh_closest(local,tMin/o.positionScale.w,closest,images,m)) return hit;
        MeshInstance instance=mesh_instances(images)[m.instance];
        MeshTriangle stored=images.triangles[instance.range.x+uint(m.triangle)];
        float b1=m.b1, b2=m.b2;
        MeshTriangle tri=instance_triangle(stored,instance,images,b1,b2);
        float b0=1-b1-b2;
        // As below: the point rebuilt from barycentrics lies on the world triangle.
        rec.t=m.t; rec.position=b0*tri.a.xyz+b1*tri.b.xyz+b2*tri.c.xyz;
        rec.error=max(mesh_hit_error(tri,rec.position,u),instance_hit_error(stored,instance,rec.position,u));
        mesh_hit_attributes(rec,tri,b1,b2,local.direction);
        rec.mat={DIFFUSE,float3(0.7f),float3(0),0,1}; rec.mat.slot=uses_scene_graph(u) ? uint(tri.uvc.z) : 7;
        if(uses_scene_graph(u) && any(images.emissions[rec.mat.slot].rgb>0)) {rec.mat.type=EMISSIVE;rec.mat.emission=rec.front_face?images.emissions[rec.mat.slot].rgb:float3(0);}
        rec.objectID=uses_scene_graph(u) ? 64+uint(tri.uvc.w)-1 : 7;
        rec.triangle=instance.range.z+uint(m.triangle);
        world_hit(rec,o);
        return true;
    }
    WatertightRay watertight=watertight_ray(local);
    MeshBoxRay box=mesh_box_ray(local,images.nodes[0]);
    int stack[64]; int top=0; stack[top++]=0;
    while(top>0) {
        MeshNode node=images.nodes[stack[--top]];
        if(!mesh_node_hit(node,local,box,tMin/o.positionScale.w,closest)) continue;
        if(node.links.w==0) { push_mesh_children(node,local,stack,top); continue; }
        for(int k=0;k<node.links.w;++k) {
            MeshTriangle tri=images.triangles[node.links.z+k];
            float t,b1,b2;
            if(!intersect_mesh_triangle(tri,watertight,tMin/o.positionScale.w,closest,t,b1,b2)) continue;
            closest=t; hit=true; float b0=1-b1-b2;
            // Rebuild the point from barycentrics: it then lies on the triangle
            // within vertex-magnitude rounding, independent of the ray length.
            rec.t=t; rec.position=b0*tri.a.xyz+b1*tri.b.xyz+b2*tri.c.xyz;
            rec.error=mesh_hit_error(tri,rec.position,u);
            mesh_hit_attributes(rec,tri,b1,b2,local.direction);
            rec.mat={DIFFUSE,float3(0.7f),float3(0),0,1}; rec.mat.slot=uses_scene_graph(u) ? uint(tri.uvc.z) : 7;
            if(uses_scene_graph(u) && any(images.emissions[rec.mat.slot].rgb>0)) {rec.mat.type=EMISSIVE;rec.mat.emission=rec.front_face?images.emissions[rec.mat.slot].rgb:float3(0);}
            rec.objectID=uses_scene_graph(u) ? 64+uint(tri.uvc.w)-1 : 7;
            rec.triangle=uint(node.links.z+k);
            world_hit(rec,o);
        }
    }
    return hit;
}
// Visibility of a segment: any blocker before tMax ends the traversal, and no
// hit attributes are built. A mesh blocker within its own rounding bound of
// tMax is the endpoint surface itself.
bool scene_occluded(Ray r, uint sceneIndex, float tMax, constant MaterialResources &images, constant Uniforms &u) {
    float tMin=ray_t_min(r.origin,u);
    HitRecord rec;
    if(trace_scene(r,sceneIndex,rec,images.objects,u.light.w,u.light.xyz,tMin) && rec.t<tMax) return true;
    if (!MESHES || sceneIndex != 6 || u.environment.w < 1 || (!uses_scene_graph(u) && images.objects[7].rotationHidden.w > 0.5f)) return false;
    ObjectSettings o=images.objects[7];
    if(uses_scene_graph(u)) { o.positionScale=float4(0,0,0,1);o.rotationHidden=float4(0); }
    Ray local=object_ray(r,o);
    float nearT=tMin/o.positionScale.w, farT=tMax/o.positionScale.w;
    if(mesh_two_level(images)) return mesh_occluded(local,nearT,farT,uses_scene_graph(u),images);
    WatertightRay watertight=watertight_ray(local);
    MeshBoxRay box=mesh_box_ray(local,images.nodes[0]);
    int stack[64]; int top=0; stack[top++]=0;
    while(top>0) {
        MeshNode node=images.nodes[stack[--top]];
        if(!mesh_node_hit(node,local,box,nearT,farT)) continue;
        if(node.links.w==0) { push_mesh_children(node,local,stack,top); continue; }
        for(int k=0;k<node.links.w;++k) {
            MeshTriangle tri=images.triangles[node.links.z+k];
            float t,b1,b2,slack=uses_scene_graph(u) ? mesh_hit_error(tri,float3(0),u) : 0.0f;
            if(intersect_mesh_triangle(tri,watertight,nearT,farT-slack,t,b1,b2)) return true;
        }
    }
    return false;
}
// The marginal row CDF is a 1 x H texture; each conditional column CDF is a row
// of the W x H texture. `marginal` selects the axis explicitly, so 1-wide maps work.
uint environment_cdf_index(texture2d<float> cdf, uint count, uint row, float value, bool marginal) {
    uint low = 0, high = max(1u, count) - 1;
    for (uint iteration = 0; iteration < 16 && low < high; ++iteration) {
        uint middle = (low + high) / 2;
        float cumulative = cdf.read(marginal ? uint2(0, middle) : uint2(middle, row), 0).x;
        if (cumulative >= value) high = middle; else low = middle + 1;
    }
    return low;
}

float environment_cdf_value(texture2d<float> cdf, uint x, uint y) {
    return cdf.read(uint2(x, y), 0).x;
}

// Solid-angle density of a lat-long texel; the sampler uses its chosen cell.
float environment_cell_pdf(uint x, uint y, float sinTheta, constant MaterialResources &images) {
    uint width = images.environmentMap.get_width(), height = images.environmentMap.get_height();
    float row = environment_cdf_value(images.environmentRows, 0, y);
    float previousRow = y == 0 ? 0.0f : environment_cdf_value(images.environmentRows, 0, y - 1);
    float column = environment_cdf_value(images.environmentColumns, x, y);
    float previousColumn = x == 0 ? 0.0f : environment_cdf_value(images.environmentColumns, x - 1, y);
    float cellProbability = max(0.0f, row - previousRow) * max(0.0f, column - previousColumn);
    return cellProbability * float(width * height) / (2.0f * PI * PI * max(1e-5f, sinTheta));
}

float environment_image_pdf(float3 wi, constant Uniforms &u, constant MaterialResources &images) {
    uint width = images.environmentMap.get_width(), height = images.environmentMap.get_height();
    float theta = acos(clamp(wi.y, -1.0f, 1.0f));
    float2 uv = float2(atan2(wi.z, wi.x) / TWO_PI + 0.5f + u.environment.y / TWO_PI, theta / PI);
    uv.x = fract(uv.x); uv.y = clamp(uv.y, 0.0f, 1.0f - 1e-7f);
    uint x = min(width - 1, uint(uv.x * float(width))), y = min(height - 1, uint(uv.y * float(height)));
    return environment_cell_pdf(x, y, sin(theta), images);
}

// REFERENCES.md: PBRT2023. Lat-long lookup with luminance-weighted image sampling.
float3 eval_environment(float3 d, constant Uniforms &u, constant MaterialResources &images) {
    float3 result;
    if(u.environment.z>0.5f) {
        constexpr sampler env(coord::normalized,address::repeat,filter::linear);
        float2 uv=float2(atan2(d.z,d.x)/TWO_PI+0.5f+u.environment.y/TWO_PI,acos(clamp(d.y,-1.0f,1.0f))/PI);
        uv.y=clamp(uv.y,0.5f/images.environmentMap.get_height(),1.0f-0.5f/images.environmentMap.get_height());
        result=images.environmentMap.sample(env,uv).rgb;
    } else result=eval_procedural_sky(d,u.lens.w>0 ? float4(u.sunParams.xyz,0) : u.sunParams,u.skyMode);
    // An imported sun is its own directional emitter, independent of environment brightness.
    return result*u.environment.x+independent_sun_radiance(d,u);
}
#if VIBE_SPECTRAL
// eval_environment split into the sun (procedural disc or imported DistantLight), which carries the
// sun illuminant, and everything else (image or procedural sky), upsampled as RGB (D65) radiance.
void environment_parts(float3 d, constant Uniforms &u, constant MaterialResources &images,
                       thread float3 &sky, thread float3 &sun) {
    sun = independent_sun_radiance(d, u);
    if (u.environment.z > 0.5f) {
        constexpr sampler env(coord::normalized,address::repeat,filter::linear);
        float2 uv=float2(atan2(d.z,d.x)/TWO_PI+0.5f+u.environment.y/TWO_PI,acos(clamp(d.y,-1.0f,1.0f))/PI);
        uv.y=clamp(uv.y,0.5f/images.environmentMap.get_height(),1.0f-0.5f/images.environmentMap.get_height());
        sky = images.environmentMap.sample(env,uv).rgb * u.environment.x;
        return;
    }
    float4 sunParams = u.lens.w > 0 ? float4(u.sunParams.xyz, 0) : u.sunParams;
    float3 full = eval_procedural_sky(d, sunParams, u.skyMode);
    // The disc is the only term that depends on the sun's intensity.
    float3 clear = sunParams.w > 0.0f && in_sun_cone(d, normalize(sunParams.xyz), procedural_sun_one_minus_cos(u.skyMode))
        ? eval_procedural_sky(d, float4(sunParams.xyz, 0.0f), u.skyMode) : full;
    sky = clear * u.environment.x;
    sun += (full - clear) * u.environment.x;
}
Spectrum environment_spectrum(float3 d, constant Uniforms &u, constant MaterialResources &images, thread const Wavelengths &wl) {
    if (wl.scene->sunIlluminant == VIBE_ILLUMINANT_D65) return spectral_emission(eval_environment(d, u, images), VIBE_ILLUMINANT_D65, wl);
    float3 sky, sun;
    environment_parts(d, u, images, sky, sun);
    return spectral_emission(sky, VIBE_ILLUMINANT_D65, wl) + spectral_emission(sun, wl.scene->sunIlluminant, wl);
}
// The environment seen without scattering (camera misses): its exact colour.
float3 environment_rgb(float3 d, constant Uniforms &u, constant MaterialResources &images, thread const Wavelengths &wl) {
    if (wl.scene->sunIlluminant == VIBE_ILLUMINANT_D65) return eval_environment(d, u, images);
    float3 sky, sun;
    environment_parts(d, u, images, sky, sun);
    return sky + spectral_emission_rgb(sun, wl.scene->sunIlluminant, wl);
}
// A light sample's emission at the wavelengths `wl`: the environment re-evaluated in its parts,
// any other emitter (area, sphere, imported triangle) with the light illuminant.
Spectrum light_spectrum(LightSample ls, thread const Wavelengths &wl) {
    if (ls.isDirectional == 1u) return environment_spectrum(ls.wi, *wl.uniforms, *wl.images, wl);
    return emitter_spectrum(ls.emission, wl);
}
#else
Spectrum environment_spectrum(float3 d, constant Uniforms &u, constant MaterialResources &images, thread const Wavelengths &) {
    return eval_environment(d, u, images);
}
float3 environment_rgb(float3 d, constant Uniforms &u, constant MaterialResources &images, thread const Wavelengths &) {
    return eval_environment(d, u, images);
}
Spectrum light_spectrum(LightSample ls, thread const Wavelengths &) { return ls.emission; }
#endif
// REFERENCES.md: PBRT2023. Thin-lens focus-plane construction; uniform disk sampling.
template <typename R>
void lens_ray(thread Ray &ray, float3 forward, float3 right, float3 up, constant Uniforms &u, thread R &seed) {
    if(u.lens.x<=0) return;
    sampler_event(seed, 0u, Z_LENS);
    float2 random=rand_f2(seed); float radius=sqrt(random.x)*u.lens.x, angle=TWO_PI*random.y;
    float3 focus=ray.origin+ray.direction*(u.lens.y/max(1e-5f,dot(ray.direction,forward)));
    ray.origin+=radius*(cos(angle)*right+sin(angle)*up); ray.direction=normalize(focus-ray.origin);
}
#if VIBE_SPECTRAL
// The wavelength numbers (u, heroU) of a sampler, drawn from a copy so that its streams continue
// unchanged: in Z mode dimensions 0 and 1 of the vertex-0 Z_WAVELENGTH event under the sampler's key
// (pass 1, pass 2 and ReSTIR PT, whose replay seed is that key, see the same numbers), else a hash
// of the PCG state.
float2 wavelength_numbers(Sampler s) {
    if (s.z) {
        sampler_event(s, 0u, Z_WAVELENGTH);
        float u = rand_f(s);
        return float2(u, rand_f(s));
    }
    uint h = pcg_hash(s.state ^ 0x5bd1e995u);
    return float2(float(h >> 8u), float(pcg_hash(h) >> 8u)) * (1.0f / 16777216.0f);
}
// Kernels of spectral libraries bind the scene's spectral state at buffers 27-29.
#define SPECTRAL_BUFFERS , constant SpectralScene &spectralScene [[buffer(27)]], \
    const device float4 *spectralGrid [[buffer(28)]], const device float *spectralSampling [[buffer(29)]]
#define SPECTRAL_WAVELENGTHS(numbers, u, images) \
    spectral_wavelengths((numbers).x, (numbers).y, &spectralScene, spectralGrid, spectralSampling, &(u), &(images))
// The scene's spectral state without wavelengths, for passes whose samples bring their own.
#define SPECTRAL_CONTEXT(u, images) \
    spectral_wavelengths(0.0f, 0.0f, &spectralScene, spectralGrid, spectralSampling, &(u), &(images))
#else
#define SPECTRAL_BUFFERS
#define SPECTRAL_WAVELENGTHS(numbers, u, images) Wavelengths()
#define SPECTRAL_CONTEXT(u, images) Wavelengths()
#endif
// Four independent images per editable material, preserving each image's size.
// Swift and Metal SurfaceSettings layouts are 64 bytes. Buffers 1/2 are shared
// by primary shading, every secondary hit, and MetalFX material-guide tracing.
struct SurfaceSettings {
    float4 color;
    float4 surface; // roughness, metalness, coat, anisotropy
    float4 detail;  // fuzz, IOR, transmission, UV repeat
    uint enabled;
    uint mapMask;
    float normalStrength;
    uint padding;
};
// All 64 slots are uploaded with setBytes, whose payload limit is 4 KB.
static_assert(sizeof(SurfaceSettings) * 64 <= 4096, "SurfaceSettings payload exceeds setBytes");


float4 sample_material_map(constant MaterialResources &images, uint slot, uint channel,
                          float2 uv, float2 density, float footprint) {
    constexpr sampler filter(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    uint index = slot * 4 + channel;
    float2 size = float2(images.maps[index].get_width(), images.maps[index].get_height());
    float lod = max(0.0f, log2(max(1e-6f, max(size.x * density.x, size.y * density.y) * footprint)));
    return images.maps[index].sample(filter, uv, level(lod));
}


// Tangent-space normal, +Y toward the image top: stored uv.y and the bitangent
// point down the image, so green follows -bitangent. Primitives keep T and B on
// the outward side; a back face sees the negated perturbed normal.
float3 tangent_space_normal(thread const HitRecord &hit, float3 m) {
    return normalize((hit.front_face ? 1.0f : -1.0f) * (hit.tangent * m.x - hit.bitangent * m.y) + hit.normal * m.z);
}

// REFERENCES.md: MATERIALX. Bounded, topologically sorted graph expressions.
void resolve_materialx(thread HitRecord &hit, Ray ray, constant MaterialResources &images, float footprint) {
    GraphHeader h=images.graphHeaders[hit.mat.slot]; if(h.info.y==0) return;
    float4 values[64]; float2 densities[64];
    for(int i=0;i<h.info.y;++i) {
        GraphInstruction n=images.graphInstructions[h.info.x+i];
        float4 a=i>0?values[n.code.y]:float4(0),b=i>0?values[n.code.z]:float4(0),c=i>0?values[n.code.w]:float4(0);
        float2 da=i>0?densities[n.code.y]:float2(0),db=i>0?densities[n.code.z]:float2(0),dc=i>0?densities[n.code.w]:float2(0);
        float4 v=n.value;float2 d=float2(0);
        switch(n.code.x) {
        case 0:break;
        case 1:v=float4(hit.uv.x,1.0f-hit.uv.y,0,0);d=hit.uvDensity;break;
        case 2:{
            // value.z/w select MaterialX clamp (clamp-to-edge) addressing per axis.
            constexpr sampler periodic(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
            constexpr sampler clampU(coord::normalized,s_address::clamp_to_edge,t_address::repeat,filter::linear,mip_filter::linear);
            constexpr sampler clampV(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear,mip_filter::linear);
            constexpr sampler clampUV(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
            uint index=uint(n.value.x);float2 size=float2(images.graphImages[index].get_width(),images.graphImages[index].get_height());
            float lod=max(0.0f,log2(max(1e-6f,max(size.x*da.x,size.y*da.y)*footprint)));
            float2 st=float2(a.x,1.0f-a.y);
            v=n.value.z>0 ? images.graphImages[index].sample(n.value.w>0?clampUV:clampU,st,level(lod))
                : images.graphImages[index].sample(n.value.w>0?clampV:periodic,st,level(lod));
            if(n.value.y>0) v=float4(v.x); break;
        }
        case 3:v=a*b;d=abs(a.xy)*db+abs(b.xy)*da;break;
        case 4:v=a+b;d=da+db;break;
        case 5:v=mix(a,b,c);d=abs(1-c.xy)*da+abs(c.xy)*db+abs(b.xy-a.xy)*dc;break;
        case 6:v=float4(a[uint(n.value.x)]);d=float2(max(da.x,da.y));break;
        case 7:v=clamp(a,b,c);d=da+db+dc;break;
        case 8:{float3 normal=dot(a.xyz,a.xyz)==0?float3(0,0,1):a.xyz*2.0f-1.0f;normal.xy*=n.value.xy;
            v=float4(tangent_space_normal(hit,normal),0);break;}
        case 9:v=a-b;d=da+db;break;
        // MaterialX 1.39 mx_rotate_vector2: (ca*x+sa*y, -sa*x+ca*y).
        case 10:{float angle=n.value.x;v=float4(cos(angle)*a.x+sin(angle)*a.y,-sin(angle)*a.x+cos(angle)*a.y,0,0);d=float2(max(da.x,da.y)*1.414214f);break;}
        case 11:v=a;d=da;break;
        }
        values[i]=all(isfinite(v))?v:float4(0);densities[i]=d;
    }
    hit.mat.type=OPENPBR;hit.mat.usesMaterialX=1;
    hit.mat.diffuseRoughness=h.info.z>=0 ? clamp(values[h.info.z].x,0.0f,1.0f) : 0.0f;
    hit.mat.albedo=clamp(values[h.roots0.x].rgb,0.0f,1.0f);
    hit.mat.roughness=clamp(values[h.roots0.y].x,0.03f,1.0f);
    hit.mat.metalness=clamp(values[h.roots0.z].x,0.0f,1.0f);
    hit.mat.coat=clamp(values[h.roots0.w].x,0.0f,1.0f);
    hit.mat.anisotropy=clamp(values[h.roots1.x].x,0.0f,1.0f);
    hit.mat.fuzz=clamp(values[h.roots1.y].x,0.0f,1.0f);
    hit.mat.ior=clamp(values[h.roots1.z].x,1.01f,2.5f);
    hit.mat.transmission=clamp(values[h.roots1.w].x,0.0f,1.0f);
    hit.mat.coatRoughness=clamp(values[h.roots2.y].x,0.0f,1.0f);
    hit.mat.specularWeight=clamp(values[h.roots2.z].x,0.0f,1.0f);
    hit.mat.baseWeight=clamp(values[h.roots2.w].x,0.0f,1.0f);
    // OpenPBR emission (nits, before coat/fuzz attenuation) leaves the exterior side only;
    // geometry_thin_walled is fixed at false. See openpbr_emission.
    hit.mat.emission=h.info.w>=0 && hit.front_face ? clamp(values[h.info.w].rgb,0.0f,1e8f) : float3(0);
    if(h.roots2.x>=0) {
        float3 normal=values[h.roots2.x].xyz;
        if(dot(normal,normal)>1e-12f) {
            normal=normalize(normal);
            for(int i=0;i<8 && (dot(normal,hit.geometricNormal)<0.2f || dot(normal,-ray.direction)<0.01f);++i) normal=normalize(normal+hit.geometricNormal*1.01f);
            hit.normal=dot(normal,-ray.direction)>0?normal:hit.geometricNormal;
        }
    }
}
void resolve_material(thread HitRecord &hit, Ray ray, constant Uniforms &u,
                      constant SurfaceSettings *settings, constant MaterialResources &images, float footprint) {
    hit.mat.inside = !hit.front_face;
    hit.mat.tangent = hit.tangent;
    hit.mat.geometricNormal = hit.geometricNormal;
    if (hit.mat.type == EMISSIVE || hit.mat.slot >= 64) return;
    uint slot = hit.mat.slot;
    SurfaceSettings config = settings[slot];
    if (config.enabled != 0) {
        hit.mat.type = OPENPBR;
        hit.mat.albedo = config.color.rgb;
        hit.mat.roughness = config.surface.x;
        hit.mat.metalness = config.surface.y;
        hit.mat.coat = config.surface.z;
        hit.mat.anisotropy = config.surface.w;
        hit.mat.fuzz = config.detail.x;
        hit.mat.ior = config.detail.y;
        hit.mat.transmission = config.detail.z;
    }
    if(images.graphHeaders[slot].info.y>0) {
        resolve_materialx(hit,ray,images,footprint/max(0.05f,abs(dot(ray.direction,hit.geometricNormal))));return;
    }
    if (config.mapMask == 0) return;
    float repeat = max(0.01f, config.detail.w);
    float2 uv = hit.uv * repeat, density = hit.uvDensity * repeat;
    ObjectSettings object=images.objects[slot];
    float angle=object.uvTransform.z;
    uv=float2(cos(angle)*uv.x-sin(angle)*uv.y,sin(angle)*uv.x+cos(angle)*uv.y)+object.uvTransform.xy;
    // Isotropic ray-cone footprint, enlarged at grazing incidence. Rough
    // secondary rays expand the cone in shading_kernel; mirror chains preserve it.
    footprint /= max(0.05f, abs(dot(ray.direction, hit.geometricNormal)));
    // Roughness and metalness maps promote an original scene material to OpenPBR.
    // Keep its metal or glass lobe; a matte surface takes the inspector roughness.
    if ((config.mapMask & 6) && hit.mat.type != OPENPBR && (hit.mat.type != GLOSSY || (config.mapMask & 4))) {
        hit.mat.metalness = hit.mat.type == GLOSSY ? 1.0f : 0.0f;
        hit.mat.transmission = hit.mat.type == DIELECTRIC ? 1.0f : 0.0f;
        if (hit.mat.type != DIELECTRIC) hit.mat.ior = config.detail.y;
        if (hit.mat.type == DIFFUSE) hit.mat.roughness = config.surface.x;
        hit.mat.type = OPENPBR;
    }
    if (config.mapMask & 1) hit.mat.albedo *= sample_material_map(images, slot, 0, uv, density, footprint).rgb;
    if (config.mapMask & 2) hit.mat.roughness = clamp(sample_material_map(images, slot, 1, uv, density, footprint)[min(object.channels.x,3u)], 0.03f, 1.0f);
    if (config.mapMask & 4) hit.mat.metalness = clamp(sample_material_map(images, slot, 2, uv, density, footprint)[min(object.channels.y,3u)], 0.0f, 1.0f);
    if (config.mapMask & 8) {
        float3 map = sample_material_map(images, slot, 3, uv, density, footprint).xyz * 2.0f - 1.0f;
        map.xy *= config.normalStrength;
        float3 mapped = tangent_space_normal(hit, float3(map.xy, max(0.05f, map.z)));
        // Keep the shading frame facing the ray and within the geometric surface.
        // Geometry normals remain separate for offsets and visibility.
        for (int i = 0; i < 8 && (dot(mapped, hit.geometricNormal) < 0.2f || dot(mapped, -ray.direction) < 0.01f); ++i)
            mapped = normalize(mapped + hit.geometricNormal);
        hit.normal = dot(mapped, -ray.direction) > 0.0f ? mapped : hit.geometricNormal;
    }
}

// ============================================================================
// Sampling & Math Helpers
// ============================================================================

void make_basis(float3 n, thread float3 &u, thread float3 &v) {
    float3 up = abs(n.z) < 0.999f ? float3(0, 0, 1) : float3(1, 0, 0);
    u = normalize(cross(up, n));
    v = cross(n, u);
}

float power_heuristic(float p_f, float p_g) {
    float scale = max(p_f, p_g);
    if (scale <= 0.0f) return 0.0f;
    float f = p_f / scale;
    float g = p_g / scale;
    return f * f / (f * f + g * g);
}

float3 sample_cosine_hemisphere(float3 n, float2 r) {
    float phi = TWO_PI * r.x;
    // Center the radial draw in its 24-bit bin: an exact zero creates a
    // tangent ray whose rounded dot-product PDF can be tiny but positive.
    // Such a sample acquires enormous inverse-PDF weights during GI reuse.
    float cos_th = sqrt(r.y + (0.5f / 16777216.0f));
    float sin_th = sqrt(max(0.0f, 1.0f - cos_th * cos_th));
    float3 u, v;
    make_basis(n, u, v);
    return normalize(u * (cos(phi) * sin_th) + v * (sin(phi) * sin_th) + n * cos_th);
}
template <typename R>
float3 sample_cosine_hemisphere(float3 n, thread R &seed) {
    return sample_cosine_hemisphere(n, rand_f2(seed));
}

// FRESNEL1994: exact-mirror compatibility path and approximate MetalFX guides.
float3 conductor_fresnel(float3 f0, float voH) {
    return f0 + (1.0f - f0) * pow(1.0f - clamp(voH, 0.0f, 1.0f), 5.0f);
}

// ADOBEOPENPBR: pinned upstream evaluation, sampling, and PDFs share one
// resolved-input adapter. All coordinates are world space; view points outward.
OpenPBR_PreparedBsdf prepare_openpbr(Material mat, float3 n, float3 wo) {
    OpenPBR_ResolvedInputs inputs = openpbr_make_default_resolved_inputs();
    inputs.base_color = clamp(mat.albedo, 0.0f, 1.0f);
    inputs.specular_roughness = max(0.03f, mat.roughness);
    inputs.base_metalness = mat.type == GLOSSY ? 1.0f : mat.metalness;
    inputs.specular_weight = mat.usesMaterialX ? mat.specularWeight : (mat.type == DIFFUSE ? 0.0f : 1.0f);
    if(mat.usesMaterialX) { inputs.base_weight=mat.baseWeight; inputs.base_diffuse_roughness=mat.diffuseRoughness; }
    inputs.specular_ior = max(1.01f, mat.ior);
    inputs.coat_weight = mat.coat;
    inputs.coat_roughness = mat.usesMaterialX ? mat.coatRoughness : 0.12f;
    inputs.specular_roughness_anisotropy = mat.anisotropy;
    inputs.fuzz_weight = mat.fuzz;
    inputs.transmission_weight = mat.transmission;
    float3 outward = mat.transmission > 0.0f && mat.inside ? -n : n;
    inputs.geometry_basis = dot(mat.tangent, mat.tangent) > 0.5f && abs(dot(mat.tangent, outward)) < 0.99f
        ? openpbr_make_basis(outward, mat.tangent, 1.0f) : openpbr_make_basis(outward);
    inputs.geometry_coat_basis = inputs.geometry_basis;
    return openpbr_prepare(inputs, float3(1), OpenPBR_BaseRgbWavelengths_nm, 1.0f, wo);
}

// The layered BSDF prepared for one vertex, as evaluation, sampling and PDFs consume it. RGB: the
// upstream prepared state. Spectral: the upstream BSDF evaluates three colour channels at the
// wavelengths it is given (its stochastic-RGB-wavelength mode, used for dispersion and thin film), so
// `a` holds lanes 0-2 (base colour rho(lambda_0..2) at lambda_0..2) and `b` lane 3. Sampling
// directions, lobe probabilities and PDFs are those of `a`; `b` only evaluates, and is skipped
// when every lane would equal lane 0 (a grey base colour without thin film or dispersion). At a
// dispersive material on a hero path, `a` is prepared at the hero wavelength alone.
#if VIBE_SPECTRAL
struct PreparedBsdf { OpenPBR_PreparedBsdf a, b; uint hero; bool flat; };
OpenPBR_PreparedBsdf prepare_openpbr_lanes(Material mat, float3 n, float3 wo, float3 baseColor, float3 lambda,
                                           SpectralMaterial sm) {
    OpenPBR_ResolvedInputs inputs = openpbr_make_default_resolved_inputs();
    inputs.base_color = baseColor;
    inputs.specular_roughness = max(0.03f, mat.roughness);
    inputs.base_metalness = mat.type == GLOSSY ? 1.0f : mat.metalness;
    inputs.specular_weight = mat.usesMaterialX ? mat.specularWeight : (mat.type == DIFFUSE ? 0.0f : 1.0f);
    if(mat.usesMaterialX) { inputs.base_weight=mat.baseWeight; inputs.base_diffuse_roughness=mat.diffuseRoughness; }
    inputs.specular_ior = max(1.01f, mat.ior);
    inputs.coat_weight = mat.coat;
    inputs.coat_roughness = mat.usesMaterialX ? mat.coatRoughness : 0.12f;
    inputs.specular_roughness_anisotropy = mat.anisotropy;
    inputs.fuzz_weight = mat.fuzz;
    inputs.transmission_weight = mat.transmission;
    // OpenPBR dispersion: the upstream Abbe-number parameterization with V_d = 20 / dispersion.
    inputs.transmission_dispersion_scale = sm.dispersion;
    inputs.transmission_dispersion_abbe_number = 20.0f;
    inputs.thin_film_weight = sm.thinFilmWeight;
    inputs.thin_film_thickness = sm.thinFilmThickness;
    inputs.thin_film_ior = sm.thinFilmIOR;
    float3 outward = mat.transmission > 0.0f && mat.inside ? -n : n;
    inputs.geometry_basis = dot(mat.tangent, mat.tangent) > 0.5f && abs(dot(mat.tangent, outward)) < 0.99f
        ? openpbr_make_basis(outward, mat.tangent, 1.0f) : openpbr_make_basis(outward);
    inputs.geometry_coat_basis = inputs.geometry_basis;
    return openpbr_prepare(inputs, float3(1), lambda, 1.0f, wo);
}
PreparedBsdf prepare_bsdf(Material mat, float3 n, float3 wo, thread const Wavelengths &wl) {
    SpectralMaterial sm = spectral_material(mat, wl);
    float3 albedo = clamp(mat.albedo, 0.0f, 1.0f);
    Spectrum rho = spectral_albedo(mat, albedo, wl);
    PreparedBsdf p;
    p.hero = 4u;
    if (wl.heroOnly && spectral_dispersive(mat, wl)) {
        p.hero = spectral_hero(wl); p.flat = true;
        p.a = prepare_openpbr_lanes(mat, n, wo, float3(rho[p.hero]), float3(spectral_lambda(wl, p.hero)), sm);
        return p;
    }
    p.flat = albedo.x == albedo.y && albedo.y == albedo.z && !(sm.thinFilmWeight > 0.0f) && !spectral_dispersive(mat, wl);
    // The upstream BSDF reads wavelengths only for dispersion and thin film.
    float4 lambda = sm.thinFilmWeight > 0.0f || sm.dispersion > 0.0f ? spectral_lambdas(wl)
        : float4(OpenPBR_BaseRgbWavelengths_nm, OpenPBR_BaseRgbWavelengths_nm.x);
    p.a = prepare_openpbr_lanes(mat, n, wo, rho.xyz, lambda.xyz, sm);
    if (!p.flat) p.b = prepare_openpbr_lanes(mat, n, wo, float3(rho.w), float3(lambda.w), sm);
    return p;
}
Spectrum prepared_lanes(thread const PreparedBsdf &p, float3 a, float b) {
    return p.hero < 4u ? select(Spectrum(0.0f), Spectrum(a.x), uint4(0u, 1u, 2u, 3u) == p.hero) : Spectrum(a, b);
}
// f |cos| at wi.
Spectrum prepared_eval(thread const PreparedBsdf &p, float3 wi) {
    float3 a = openpbr_get_sum_of_diffuse_specular(openpbr_eval(p.a, wi));
    return prepared_lanes(p, a, p.flat || p.hero < 4u ? a.x : openpbr_get_sum_of_diffuse_specular(openpbr_eval(p.b, wi)).x);
}
float prepared_pdf(thread const PreparedBsdf &p, float3 wi) { return openpbr_pdf(p.a, wi); }
// Direction and PDF of `a`; weight = f |cos| / pdf for every lane.
void prepared_sample(thread const PreparedBsdf &p, float3 random, thread float3 &direction, thread Spectrum &weight,
                     thread float &pdf) {
    OpenPBR_DiffuseSpecular result;
    uint lobe;
    openpbr_sample(p.a, random, direction, result, pdf, lobe);
    float3 a = openpbr_get_sum_of_diffuse_specular(result);
    float b = a.x;
    if (!p.flat && p.hero >= 4u) b = pdf > 0.0f ? openpbr_get_sum_of_diffuse_specular(openpbr_eval(p.b, direction)).x / pdf : 0.0f;
    weight = prepared_lanes(p, a, b);
}
#else
typedef OpenPBR_PreparedBsdf PreparedBsdf;
PreparedBsdf prepare_bsdf(Material mat, float3 n, float3 wo, thread const Wavelengths &) { return prepare_openpbr(mat, n, wo); }
Spectrum prepared_eval(thread const PreparedBsdf &p, float3 wi) { return openpbr_get_sum_of_diffuse_specular(openpbr_eval(p, wi)); }
float prepared_pdf(thread const PreparedBsdf &p, float3 wi) { return openpbr_pdf(p, wi); }
void prepared_sample(thread const PreparedBsdf &p, float3 random, thread float3 &direction, thread Spectrum &weight,
                     thread float &pdf) {
    OpenPBR_DiffuseSpecular result;
    uint lobe;
    openpbr_sample(p, random, direction, result, pdf, lobe);
    weight = openpbr_get_sum_of_diffuse_specular(result);
}
#endif

// REFERENCES.md: MATERIALX, OPENPBR. Radiance a MaterialX surface emits toward wo, as in
// the pinned MaterialX v1.39.5 open_pbr_surface graph: emission_color x emission_luminance
// (uniform_edf), mixed by coat_weight with its generalized_schlick_edf coated form, whose
// factor is (1 - F0) (1 - (1 - N.V)^5) for the coat IOR (fixed at 1.6) and coat_color (1).
float3 openpbr_emission(Material mat, float3 n, float3 wo) {
    if (mat.type != OPENPBR || mat.usesMaterialX == 0 || !any(mat.emission > 0.0f)) return float3(0);
    const float coatF0 = 0.6f * 0.6f / (2.6f * 2.6f);
    float grazing = 1.0f - clamp(dot(n, wo), 1.1920929e-7f, 1.0f);
    float coated = (1.0f - coatF0) * (1.0f - pow(grazing, 5.0f));
    return mat.emission * mix(1.0f, coated, clamp(mat.coat, 0.0f, 1.0f));
}

Spectrum eval_bsdf(Material mat, float3 n, float3 wo, float3 wi, thread const Wavelengths &wl) {
    if (mat.transmission == 0.0f && dot(mat.geometricNormal, mat.geometricNormal) > 0.5f && dot(wi, mat.geometricNormal) <= 0.0f) return Spectrum(0);
    float cosine = abs(dot(n, wi));
    if (cosine < 1e-7f || dot(n, wo) <= 0.0f) return Spectrum(0);
    // Uncoated legacy diffuse is the Lambert limit of the OpenPBR inputs.
    // Avoid preparing all layered lobes for every ReSTIR candidate.
    if (mat.type == DIFFUSE) return dot(n, wi) > 0.0f ? spectral_albedo(mat, clamp(mat.albedo, 0.0f, 1.0f), wl) / PI : Spectrum(0);
    PreparedBsdf prepared = prepare_bsdf(mat, n, wo, wl);
    // Upstream already includes cosine; this adapter returns f for existing callers.
    return prepared_eval(prepared, wi) / cosine;
}

float eval_bsdf_pdf(Material mat, float3 n, float3 wo, float3 wi, thread const Wavelengths &wl) {
    if (dot(n, wo) <= 0.0f) return 0.0f;
    if (mat.type == DIFFUSE) return max(0.0f, dot(n, wi)) / PI;
    PreparedBsdf prepared = prepare_bsdf(mat, n, wo, wl);
    return prepared_pdf(prepared, wi);
}

// Direct lighting needs both values; prepare the layered BSDF only once.
Spectrum eval_bsdf_with_pdf(Material mat, float3 n, float3 wo, float3 wi, thread float &pdf, thread const Wavelengths &wl) {
    if (mat.type == DIFFUSE) {
        pdf = eval_bsdf_pdf(mat, n, wo, wi, wl);
        return eval_bsdf(mat, n, wo, wi, wl);
    }
    pdf = 0.0f;
    float cosine = abs(dot(n, wi));
    if (cosine < 1e-7f || dot(n, wo) <= 0.0f) return Spectrum(0);
    PreparedBsdf prepared = prepare_bsdf(mat, n, wo, wl);
    pdf = prepared_pdf(prepared, wi);
    if (mat.transmission == 0.0f && dot(mat.geometricNormal, mat.geometricNormal) > 0.5f && dot(wi, mat.geometricNormal) <= 0.0f) return Spectrum(0);
    return prepared_eval(prepared, wi) / cosine;
}

// 1 - cos(theta_max) of a sphere's cone for x = r^2/d^2, without the
// cancellation of 1 - sqrt(1 - x) for small or distant spheres.
float sphere_cone_one_minus_cos(float x) {
    return x / (1.0f + sqrt(max(0.0f, 1.0f - x)));
}
// Probability of the sun-cone proposal within the environment mixture. The
// procedural disc is emitted only above the horizon; an imported sun is not.
float environment_sun_probability(constant Uniforms &u) {
    if (u.sunParams.w <= 0.0f) return 0.0f;
    if (u.lens.w > 0.0f) return u.environment.x > 0.0f ? 0.60f : 1.0f;
    float w = procedural_sun_one_minus_cos(u.skyMode);
    return u.environment.x > 0.0f && u.environment.z < 0.5f &&
        normalize(u.sunParams.xyz).y >= -sqrt(w * (2.0f - w)) ? 0.60f : 0.0f;
}
float environment_mixture_pdf(float3 wi, float3 n, float imagePdf, constant Uniforms &u) {
    float sunProbability = environment_sun_probability(u);
    float w = sun_one_minus_cos(u);
    float sunPDF = in_sun_cone(wi, normalize(u.sunParams.xyz), w) ? 1.0f / (TWO_PI * w) : 0.0f;
    float rest = u.environment.z > 0.5f ? imagePdf : max(0.0f, dot(n, wi)) / PI;
    return sunProbability * sunPDF + (1.0f - sunProbability) * rest;
}

// OPENUSD/PBRT2023: power-weighted triangle emitter proposal, mixed with the environment.
float imported_light_probability(constant Uniforms &u,constant MaterialResources &images) {
    if(!MESHES || u.sceneIndex!=6 || images.emitters[0]==0) return 0.0f;
    return u.environment.x>0 || (u.lens.w>0 && u.sunParams.w>0) ? 0.5f:1.0f;
}
float imported_geometry(float3 p,float3 position,uint index,constant MaterialResources &images) {
    MeshTriangle t=scene_triangle(index,images);float3 d=position-p;float d2=dot(d,d);
    float3 n=cross(t.b.xyz-t.a.xyz,t.c.xyz-t.a.xyz);
    return d2>1e-12f && dot(n,n)>1e-20f ? max(0.0f,dot(normalize(n),-d*rsqrt(d2)))/d2:0;
}
// emitters = [count, triangle indices, cumulative area x weight (float bits), total].
// emissions[slot].w is the slot's selection weight: the luminance of a constant emitter,
// or the host estimate of a MaterialX emitter (MaterialXProgram.emissionWeight); zero
// for slots outside the list. A triangle's area density is that weight over the total.
float imported_emitter_area_pdf(uint index,constant MaterialResources &images) {
    uint count=images.emitters[0];
    if(count==0) return 0.0f;
    float total=as_type<float>(images.emitters[2*count+1]);uint slot=uint(scene_triangle(index,images).uvc.z);
    if(slot<8 || slot>=64 || !(total>0)) return 0.0f;
    return images.emissions[slot].w/total;
}
// Radiance a MaterialX emitter sends from a sampled point (barycentrics b1, b2) toward p,
// evaluated with the graph exactly as at a BSDF hit on that point (finest image level).
float3 imported_graph_emission(uint index,float b1,float b2,float3 p,float3 position,float3 wi,constant MaterialResources &images) {
    MeshTriangle t=scene_triangle(index,images);uint slot=uint(t.uvc.z);
    if(slot>=64 || images.graphHeaders[slot].info.y==0 || images.graphHeaders[slot].info.w<0) return float3(0);
    HitRecord h={};Ray ray={p,wi};
    h.t=length(position-p);h.position=position;h.triangle=index;
    mesh_hit_attributes(h,t,b1,b2,wi);
    h.mat={DIFFUSE,float3(0.7f),float3(0),0,1};h.mat.slot=slot;
    h.mat.inside=!h.front_face;h.mat.tangent=h.tangent;h.mat.geometricNormal=h.geometricNormal;
    resolve_materialx(h,ray,images,0.0f);
    return openpbr_emission(h.mat,h.normal,-wi);
}
float eval_environment_pdf(float3 wi,float3 n,constant Uniforms &u,constant MaterialResources &images) {
    float image = u.environment.z > 0.5f ? environment_image_pdf(wi,u,images) : 0.0f;
    return (1.0f-imported_light_probability(u,images))*environment_mixture_pdf(wi,n,image,u);
}
// Both proposals sample the same environment, with their full mixture PDF.
// Emitter choice and the point on the emitter form one 3D constituent (rand_f3) in Z mode;
// the draws keep the order of the PCG stream.
template <typename R>
LightSample sample_direct_light(float3 p, float3 n, constant Uniforms &u, thread R &seed, constant MaterialResources &materialImages) {
    LightSample ls = {};
    float importedProbability=imported_light_probability(u,materialImages);
    if(importedProbability>0 && rand_f(seed)<importedProbability) {
        uint count=materialImages.emitters[0],low=0,high=count-1;float3 q=rand_f3(seed);float value=q.x;
        while(low<high) {uint middle=(low+high)/2;if(as_type<float>(materialImages.emitters[1+count+middle])>=value) high=middle; else low=middle+1;}
        uint index=materialImages.emitters[1+low];
        MeshTriangle t=scene_triangle(index,materialImages);float2 r=q.yz;float root=sqrt(r.x);
        ls.position=(1-root)*t.a.xyz+root*(1-r.y)*t.b.xyz+root*r.y*t.c.xyz;
        float3 delta=ls.position-p;ls.dist=length(delta);ls.wi=delta/max(ls.dist,1e-8f);
        float geometry=imported_geometry(p,ls.position,index,materialImages);
        ls.emission=materialImages.emissions[uint(t.uvc.z)].rgb;ls.isDirectional=index+2;
        // Graph-driven emission varies over the surface: evaluate it at this sample.
        if(uses_scene_graph(u) && geometry>1e-12f && !any(ls.emission>0))
            ls.emission=imported_graph_emission(index,root*(1-r.y),root*r.y,p,ls.position,ls.wi,materialImages);
        ls.pdf=geometry>1e-12f ? importedProbability*imported_emitter_area_pdf(index,materialImages)/geometry:0;
        return ls;
    }
    if ((u.sceneIndex == 0 || u.sceneIndex == 6)) {
        float sunProbability = environment_sun_probability(u);
        float imagePdf = 0.0f;
        // With a sun, its choice and the first two draws of either branch share one 3D draw.
        float3 q = sunProbability > 0.0f ? rand_f3(seed) : float3(1.0f);
        if (sunProbability > 0.0f && q.x < sunProbability) {
            // Sun cone sampling; sin^2 is formed from 1 - cos for sub-degree suns.
            float3 sun_d = normalize(u.sunParams.xyz);
            float2 r = q.yz;
            float oneMinusCos = r.x * sun_one_minus_cos(u);
            float cos_th = 1.0f - oneMinusCos;
            float sin_th = sqrt(max(0.0f, oneMinusCos * (2.0f - oneMinusCos)));
            float phi = TWO_PI * r.y;
            float3 su, sv;
            make_basis(sun_d, su, sv);
            ls.wi = normalize(su * (cos(phi) * sin_th) + sv * (sin(phi) * sin_th) + sun_d * cos_th);
            if (u.environment.z > 0.5f) imagePdf = environment_image_pdf(ls.wi, u, materialImages);
        } else if (u.environment.z > 0.5f) {
            uint width = materialImages.environmentMap.get_width(), height = materialImages.environmentMap.get_height();
            float2 c = sunProbability > 0.0f ? q.yz : rand_f2(seed);
            uint y = environment_cdf_index(materialImages.environmentRows, height, 0, c.x, true);
            uint x = environment_cdf_index(materialImages.environmentColumns, width, y, c.y, false);
            // Keep the in-texel offset inside the chosen cell and use that cell's
            // probability; re-deriving it from the direction can pick a neighbour.
            float2 size = float2(width, height), cell = float2(x, y);
            float2 uv = min(cell / size + rand_f2(seed) / size, nextafter((cell + 1.0f) / size, float2(0.0f)));
            float theta = uv.y * PI, phi = (uv.x - 0.5f - u.environment.y / TWO_PI) * TWO_PI;
            float sinTheta = sin(theta);
            ls.wi = normalize(float3(sinTheta * cos(phi), cos(theta), sinTheta * sin(phi)));
            imagePdf = environment_cell_pdf(x, y, sinTheta, materialImages);
        } else {
            // Ambient sky cosine hemisphere sampling -> illuminates shadows & cylinder interior
            ls.wi = sunProbability > 0.0f ? sample_cosine_hemisphere(n, q.yz) : sample_cosine_hemisphere(n, seed);
        }
        ls.position = p + ls.wi * 1e6f;
        ls.dist = 1e6f;
        ls.isDirectional = 1;
        ls.pdf = (1.0f - importedProbability) * environment_mixture_pdf(ls.wi, n, imagePdf, u);
        ls.emission = eval_environment(ls.wi, u, materialImages);
    } else if (u.sceneIndex == 1 || u.sceneIndex == 3 || u.sceneIndex == 4) {
        float3 corner = (u.sceneIndex == 3) ? float3(-0.2f, 0.999f, -0.2f) : float3(-0.25f, 0.999f, -0.25f);
        float3 su = (u.sceneIndex == 3) ? float3(0.4f, 0, 0) : float3(0.5f, 0, 0);
        float3 sv = (u.sceneIndex == 3) ? float3(0, 0, 0.4f) : float3(0, 0, 0.5f);
        float3 emit = procedural_light_emission(u.sceneIndex);

        float3 center=corner+0.5f*(su+sv); su*=u.light.w; sv*=u.light.w; corner=center-0.5f*(su+sv);
        float2 uv = rand_f2(seed);
        float3 light_pos = corner + uv.x * su + uv.y * sv;
        float3 dir = light_pos - p;
        float dist = length(dir);
        dir /= dist;
        float3 light_norm = float3(0, -1, 0);
        float cos_l = max(0.0f, dot(-dir, light_norm));
        if (cos_l > 1e-4f) {
            float area = length(cross(su, sv));
            ls.position = light_pos;
            ls.wi = dir;
            ls.dist = dist;
            ls.emission = emit;
            ls.pdf = (dist * dist) / (area * cos_l);
        }
    } else if (u.sceneIndex == 5) {
        float3 corner = float3(-0.15f, 1.9f, -0.65f);
        float3 su = float3(0.3f, 0, 0);
        float3 sv = float3(0, 0, 0.3f);
        float3 center=corner+0.5f*(su+sv); su*=u.light.w; sv*=u.light.w; corner=center-0.5f*(su+sv);
        float2 uv = rand_f2(seed);
        float3 light_pos = corner + uv.x * su + uv.y * sv;
        float3 dir = light_pos - p;
        float dist = length(dir);
        dir /= dist;
        float3 light_norm = float3(0, -1, 0);
        float cos_l = max(0.0f, dot(-dir, light_norm));
        if (cos_l > 1e-4f) {
            ls.position = light_pos;
            ls.wi = dir;
            ls.dist = dist;
            ls.emission = procedural_light_emission(5u);
            ls.pdf = (dist * dist) / (0.09f * u.light.w * u.light.w * cos_l);
        }
    } else if (u.sceneIndex == 2) {
        // PCG draws the cone sample only outside the sphere; Z mode draws one 3D constituent.
        bool joint = sampler_joint(seed);
        float3 q = joint ? rand_f3(seed) : float3(rand_f(seed), 0.0f, 0.0f);
        int pick = clamp(int(q.x * 4.0f), 0, 3);
        float xs[4] = { -2.4f, -0.8f, 0.8f, 2.4f };
        float radii[4] = { 0.55f, 0.18f, 0.055f, 0.016f };
        float3 emits[4] = { float3(6.0f), float3(45.0f), float3(450.0f), float3(4000.0f) };

        float3 center = float3(xs[pick], 1.8f, 1.2f);
        float radius = radii[pick]*u.light.w;
        float3 d_vec = center - p;
        float d2 = dot(d_vec, d_vec);
        if (d2 > radius * radius) {
            float d = sqrt(d2);
            float3 d_c = d_vec / d;
            float oneMinusCosMax = sphere_cone_one_minus_cos(radius * radius / d2);
            float2 r = joint ? q.yz : rand_f2(seed);
            float oneMinusCos = r.x * oneMinusCosMax;
            float cos_th = 1.0f - oneMinusCos;
            float sin_th = sqrt(max(0.0f, oneMinusCos * (2.0f - oneMinusCos)));
            float phi = TWO_PI * r.y;
            float3 su, sv;
            make_basis(d_c, su, sv);
            ls.wi = normalize(su * (cos(phi) * sin_th) + sv * (sin(phi) * sin_th) + d_c * cos_th);
            // Store an actual point on the emitter, also valid during reuse. The
            // perpendicular form of the discriminant avoids b^2 - c cancellation.
            float3 oc = p - center;
            float b = dot(oc, ls.wi);
            float3 perpendicular = oc - b * ls.wi;
            float disc = radius * radius - dot(perpendicular, perpendicular);
            if (disc >= -1e-3f * radius * radius) {
                ls.dist = -b - sqrt(max(0.0f, disc));
                ls.position = p + ls.wi * ls.dist;
                ls.emission = emits[pick];
                ls.pdf = 0.25f / (TWO_PI * oneMinusCosMax);
            }
        }
    }
    if(u.sceneIndex!=0 && u.sceneIndex!=6) ls.emission*=u.light.xyz;
    return ls;
}

float eval_light_pdf(float3 p, float3 hit_pos, Material mat, constant Uniforms &u) {
    float3 dir = hit_pos - p;
    float dist = length(dir);
    dir /= dist;

    if (u.sceneIndex == 1 || u.sceneIndex == 3 || u.sceneIndex == 4) {
        float3 su = (u.sceneIndex == 3) ? float3(0.4f, 0, 0) : float3(0.5f, 0, 0);
        float3 sv = (u.sceneIndex == 3) ? float3(0, 0, 0.4f) : float3(0, 0, 0.5f);
        float cos_l = max(0.0f, dot(-dir, float3(0, -1, 0)));
        return (cos_l <= 0.0f) ? 0.0f : (dist * dist) / (length(cross(su, sv)) * u.light.w * u.light.w * cos_l);
    } else if (u.sceneIndex == 5) {
        float cos_l = max(0.0f, dot(-dir, float3(0, -1, 0)));
        return (cos_l <= 0.0f) ? 0.0f : (dist * dist) / (0.09f * u.light.w * u.light.w * cos_l);
    } else if (u.sceneIndex == 2) {
        float xs[4] = { -2.4f, -0.8f, 0.8f, 2.4f };
        float radii[4] = { 0.55f, 0.18f, 0.055f, 0.016f };
        for (int i = 0; i < 4; ++i) {
            float3 c = float3(xs[i], 1.8f, 1.2f);
            if (length(hit_pos - c) < radii[i]*u.light.w + 0.01f) {
                float d_vec2 = dot(c - p, c - p), r2 = radii[i] * radii[i] * u.light.w * u.light.w;
                return d_vec2 > r2 ? 0.25f / (TWO_PI * sphere_cone_one_minus_cos(r2 / d_vec2)) : 0.0f;
            }
        }
    }
    return 0.0f;
}

// Imported emitters use the BSDF hit's triangle directly: exact at any
// coordinate magnitude and O(1) in the number of emissive triangles.
float eval_light_pdf(float3 p,float3 hit_pos,Material mat,constant Uniforms &u,constant MaterialResources &images,uint triangle) {
    if(u.sceneIndex!=6) return eval_light_pdf(p,hit_pos,mat,u);
    if(!MESHES || triangle==0xffffffffu || images.emitters[0]==0) return 0.0f;
    float g=imported_geometry(p,hit_pos,triangle,images);
    return g>1e-12f ? imported_light_probability(u,images)*imported_emitter_area_pdf(triangle,images)/g : 0.0f;
}

// Artistic ring-caustic approximation. This is not an unbiased SMS estimator:
// it uses a simplified Jacobian and empirical gain, and handles no glass paths.
// REFERENCES.md: SMS2020 is related work, not this approximation's derivation.
template <typename R>
float3 sample_specular_manifold_caustic(float3 x, float3 n_x, constant Uniforms &u, thread R &seed, constant MaterialResources &materialImages) {
    if (u.sceneIndex != 0 && u.sceneIndex != 5 && u.sceneIndex != 3) return float3(0.0f);

    float3 total_caustic = float3(0.0f);
    LightSample ls = sample_direct_light(x, n_x, u, seed, materialImages);
    if (ls.pdf <= 0.0f) return float3(0.0f);
    float3 y_light = ((u.sceneIndex == 0 || u.sceneIndex == 6)) ? (x + ls.wi * 80.0f) : (x + ls.wi * ls.dist);

    if ((u.sceneIndex == 0 || u.sceneIndex == 6) || u.sceneIndex == 5) {
        float3 cyl_c = ((u.sceneIndex == 0 || u.sceneIndex == 6)) ? float3(0.70f, -0.72f, 0.10f) : float3(0.45f, -0.75f, -0.15f);
        float cyl_r  = 0.42f;
        float cyl_h  = ((u.sceneIndex == 0 || u.sceneIndex == 6)) ? 0.55f : 0.50f;

        float2 d_xz = x.xz - cyl_c.xz;
        float2 seed_dir = (length(d_xz) > 1e-4f) ? normalize(d_xz) : float2(1.0f, 0.0f);
        float3 z = float3(cyl_c.x + cyl_r * seed_dir.x, cyl_c.y, cyl_c.z + cyl_r * seed_dir.y);

        bool converged = false;
        float det_J = 1.0f;

        for (int iter = 0; iter < 4; ++iter) {
            float3 vo = x - z;
            float do_len = max(1e-4f, length(vo));
            float3 wo = vo / do_len;

            float3 vi = y_light - z;
            float di_len = max(1e-4f, length(vi));
            float3 wi = vi / di_len;

            float2 d_norm = float2(cyl_c.x - z.x, cyl_c.z - z.z);
            float d_norm_len = length(d_norm);
            if (d_norm_len < 1e-4f) break;

            float3 n = float3(d_norm.x / d_norm_len, 0.0f, d_norm.y / d_norm_len);
            float3 t1 = float3(-n.z, 0.0f, n.x);
            float3 t2 = float3(0.0f, 1.0f, 0.0f);

            float3 h = wo + wi;
            float2 C = float2(dot(t1, h), dot(t2, h));
            if (length(C) < 1e-3f) {
                converged = true;
                break;
            }

            float inv_d = -(1.0f / do_len + 1.0f / di_len);
            float j11 = inv_d + dot(n, h) / cyl_r;
            float j22 = inv_d;
            det_J = abs(j11 * j22);

            float du = -C.x / (abs(j11) > 1e-4f ? j11 : 1e-4f);
            float dv = -C.y / (abs(j22) > 1e-4f ? j22 : 1e-4f);

            z += t1 * du + t2 * dv;
            float2 offset_xz = float2(z.x - cyl_c.x, z.z - cyl_c.z);
            float len_off = length(offset_xz);
            float2 rad = (len_off > 1e-4f) ? (offset_xz / len_off) * cyl_r : float2(cyl_r, 0.0f);
            z.x = cyl_c.x + rad.x;
            z.z = cyl_c.z + rad.y;
            z.y = clamp(z.y, cyl_c.y - cyl_h * 0.5f, cyl_c.y + cyl_h * 0.5f);
        }

        if (converged && z.y > cyl_c.y - cyl_h * 0.49f && z.y < cyl_c.y + cyl_h * 0.49f) {
            float dist_xz = length(z - x);
            if (dist_xz > 1e-3f) {
                Ray r_xz; r_xz.origin = x + n_x * 0.001f; r_xz.direction = normalize(z - r_xz.origin);
                Ray r_zy; r_zy.origin = z + normalize(float3(cyl_c.x - z.x, 0.0f, cyl_c.z - z.z)) * 0.001f;
                r_zy.direction = normalize(y_light - r_zy.origin);

                bool occ1 = scene_occluded(r_xz, u.sceneIndex, dist_xz - 0.01f, materialImages, u);
                bool occ2 = scene_occluded(r_zy, u.sceneIndex, length(y_light - z) - 0.01f, materialImages, u);

                if (!occ1 && !occ2) {
                    float cos_x = max(0.0f, dot(n_x, normalize(z - x)));
                    float3 gold = float3(1.0f, 0.85f, 0.45f);
                    float caustic_mag = (1.0f / max(0.04f, det_J)) * cos_x;
                    float gain = ((u.sceneIndex == 0 || u.sceneIndex == 6)) ? 0.008f : 0.07f;
                    total_caustic += ls.emission * gold * caustic_mag * gain;
                }
            }
        }
    }
    return total_caustic;
}

float light_geometry(float3 p, LightSample ls, uint sceneIndex, float lightSize,constant MaterialResources &images) {
    if(MESHES && sceneIndex==6 && ls.isDirectional>=2) return imported_geometry(p,ls.position,ls.isDirectional-2,images);
    if (ls.isDirectional == 1) return 1.0f;
    float3 delta = ls.position - p;
    float d2 = dot(delta, delta);
    if (d2 < 1e-10f) return 0.0f;
    float3 normal = float3(0, -1, 0);
    if (sceneIndex == 2) {
        float xs[4] = { -2.4f, -0.8f, 0.8f, 2.4f };
        float radii[4] = { 0.55f, 0.18f, 0.055f, 0.016f };
        float bestError = 1e20f;
        for (int i = 0; i < 4; ++i) {
            float3 offset = ls.position - float3(xs[i], 1.8f, 1.2f);
            float error = abs(length(offset) - radii[i]*lightSize);
            if (error < bestError) { bestError = error; normal = normalize(offset); }
        }
    }
    return max(0.0f, dot(normal, -delta * rsqrt(d2))) / d2;
}

// Spectral transport: the candidate is evaluated at its own wavelengths (LightSample.u), and the
// target is the length of the resulting linear sRGB contribution, as in RGB.
float eval_restir_target_pdf(float3 p, float3 n, float3 rayDir, Material mat, LightSample candidate, uint sceneIndex, float lightSize,constant MaterialResources &images,
                             thread const Wavelengths &context) {
    if (candidate.pdf <= 0.0f) return 0.0f;
    float3 dir = (candidate.isDirectional == 1) ? candidate.wi : normalize(candidate.position - p);
    float cos_th = max(0.0f, dot(n, dir));
    if (cos_th <= 0.0f) return 0.0f;
    Wavelengths wl = sample_wavelengths(candidate.u, context);
    Spectrum bsdf = eval_bsdf(mat, n, -rayDir, dir, wl);
    return length(spectrum_rgb(bsdf * light_spectrum(candidate, wl) * cos_th, wl)) * light_geometry(p, candidate, sceneIndex, lightSize,images);
}

// First-indirect diffuse reconnection in area measure. The stored secondary
// radiance is direction independent because GI candidates require a diffuse x2.
// REFERENCES.md: RESTIRGI2021.
float gi_geometry(float3 x1, float3 n1, float3 x2, float3 n2) {
    float3 delta = x2 - x1;
    float d2 = dot(delta, delta);
    if (d2 < 1e-10f) return 0.0f;
    float3 direction = delta * rsqrt(d2);
    return max(0.0f, dot(n1, direction)) * max(0.0f, dot(n2, -direction)) / d2;
}

// Solid-angle Jacobian of reconnecting a source path x1q -> x2 at x1r
// (RESTIRGI2021, Eq. 11). The area-measure target already applies it, so reuse
// only rejects shifts outside [0.1, 10], mainly short contact-corner
// reconnections whose heavy-tailed weights would persist in history.
float restir_gi_jacobian(float3 x1r, float3 x1q, float3 x2, float3 n2) {
    float3 current = x1r - x2, source = x1q - x2;
    float currentD2 = dot(current, current), sourceD2 = dot(source, source);
    if (currentD2 < 1e-10f || sourceD2 < 1e-10f) return 0.0f;
    float currentCosine = max(0.0f, dot(n2, current * rsqrt(currentD2)));
    float sourceCosine = max(0.0f, dot(n2, source * rsqrt(sourceD2)));
    float jacobian = currentCosine * sourceD2 / (sourceCosine * currentD2);
    return isfinite(jacobian) ? jacobian : 0.0f;
}

bool restir_gi_accepts_shift(float3 x1r, float3 x1q, float3 x2, float3 n2) {
    float jacobian = restir_gi_jacobian(x1r, x1q, x2, n2);
    return jacobian >= 0.1f && jacobian <= 10.0f;
}

// `wl` are the sample's wavelengths (sample_wavelengths of its stored number), at which its
// secondary radiance was traced.
float eval_restir_gi_target(float3 x1, float3 n1, float3 rayDir, Material mat,
                            float3 x2, float3 n2, Spectrum secondaryRadiance, thread const Wavelengths &wl) {
    float geometry = gi_geometry(x1, n1, x2, n2);
    if (geometry <= 0.0f || !all(isfinite(secondaryRadiance))) return 0.0f;
    float3 direction = normalize(x2 - x1);
    return length(spectrum_rgb(eval_bsdf(mat, n1, -rayDir, direction, wl) * secondaryRadiance * geometry, wl));
}

bool gi_connection_visible(float3 x1, float3 n1, float3 x2,
                           constant Uniforms &u, constant MaterialResources &images, float error = 0.0f) {
    float3 delta = x2 - x1;
    float distanceToSample = length(delta);
    if (distanceToSample <= 2.0f * ray_epsilon(x1, u)) return false;
    Ray connection;
    connection.direction = delta / distanceToSample;
    connection.origin = ray_origin(x1, n1, connection.direction, u, error);
    float3 endpointDelta = x2 - connection.origin;
    float endpointDistance = length(endpointDelta);
    connection.direction = endpointDelta / endpointDistance;
    return !scene_occluded(connection, u.sceneIndex,
        endpointDistance - endpoint_tolerance(connection.origin, x2, endpointDistance, u), images, u);
}

// Shadow endpoints are measured from the offset origin to avoid self-occlusion.
bool light_visible(float3 p, float3 n, LightSample ls, uint sceneIndex, constant MaterialResources &materialImages, constant Uniforms &u, float error = 0.0f) {
    if (ls.pdf <= 0.0f) return false;
    Ray shadow;
    shadow.origin = ray_origin(p,n,ls.wi,u,error);
    float3 delta = ls.isDirectional == 1 ? ls.wi : ls.position - shadow.origin;
    float d = ls.isDirectional == 1 ? 1e6f : length(delta);
    float endpointTolerance=ls.isDirectional==1 ? 2*ray_epsilon(p,u) : endpoint_tolerance(shadow.origin,ls.position,d,u);
    if (d <= endpointTolerance) return false;
    shadow.direction = normalize(delta);
    return !scene_occluded(shadow, sceneIndex, d - endpointTolerance, materialImages, u);
}

bool is_delta(Material mat) {
    return mat.type == DIELECTRIC || (mat.type == GLOSSY && mat.roughness < 0.02f);
}

// Returns f * abs(cos(theta)) / PDF, using the same glossy model as NEE. The lobe choice and
// the direction form one 3D constituent (rand_f3) in Z mode. Spectral: per-wavelength values; a
// dispersive dielectric on a hero path (spectral_arrive) refracts the hero wavelength.
template <typename R>
bool sample_bsdf(Material mat, float3 normal, float3 incoming, bool frontFace,
                 thread R &seed, thread float3 &direction,
                 thread Spectrum &weight, thread float &pdf, thread const Wavelengths &wl) {
    pdf = 0.0f;
    // A perturbed shading normal can send a delta event across the geometric
    // surface; repeat such an event about the geometric normal instead.
    float3 geometric = dot(mat.geometricNormal, mat.geometricNormal) > 0.5f ? mat.geometricNormal : normal;
    if (mat.type == DIELECTRIC) {
        float ior = mat.ior;
#if VIBE_SPECTRAL
        if (wl.heroOnly && spectral_dispersive(mat, wl))
            ior = openpbr_dispersion_adjusted_ior(mat.ior, spectral_material(mat, wl).dispersion, spectral_lambda(wl, spectral_hero(wl)));
#endif
        Spectrum tint = spectral_albedo(mat, mat.albedo, wl);
        float eta = frontFace ? 1.0f / ior : ior;
        float r0 = (1.0f - ior) / (1.0f + ior);
        for (int attempt = 0; attempt < 2; ++attempt) {
            float3 m = attempt == 0 ? normal : geometric;
            float cosI = clamp(dot(-incoming, m), 0.0f, 1.0f);
            float sin2T = eta * eta * (1.0f - cosI * cosI);
            // Schlick takes the cosine on the less dense side: cosT when exiting.
            float cosine = eta > 1.0f && sin2T < 1.0f ? sqrt(1.0f - sin2T) : cosI;
            float fresnel = r0 * r0 + (1.0f - r0 * r0) * pow(1.0f - cosine, 5.0f);
            bool reflected = sin2T >= 1.0f || rand_f(seed) < fresnel;
            if (reflected) {
                // Renormalized: rounding in long mirror chains otherwise compounds into
                // non-unit rays that the sphere test (unit-direction form) hits off-surface.
                direction = normalize(reflect(incoming, m));
                weight = tint;
            } else {
                direction = normalize(eta * incoming + (eta * cosI - sqrt(1.0f - sin2T)) * m);
                weight = tint * (eta * eta);
            }
            if ((dot(direction, geometric) > 0.0f) == reflected) return true;
        }
        return false;
    }
    if (is_delta(mat)) {
        float3 m = dot(reflect(incoming, normal), geometric) > 0.0f ? normal : geometric;
        direction = normalize(reflect(incoming, m));
        float cosI = clamp(dot(-incoming, m), 0.0f, 1.0f);
        // Conductor Fresnel (Schlick) per wavelength, with F0 the reflectance spectrum.
        Spectrum f0 = spectral_albedo(mat, mat.albedo, wl);
        weight = f0 + (1.0f - f0) * pow(1.0f - cosI, 5.0f);
        return dot(direction, geometric) > 0.0f;
    }
    if (mat.type == DIFFUSE) {
        // Keep three draws like the generic sampler, including its lobe choice.
        direction = sample_cosine_hemisphere(normal, rand_f3(seed).yz);
        pdf = max(0.0f, dot(normal, direction)) / PI;
        weight = spectral_albedo(mat, clamp(mat.albedo, 0.0f, 1.0f), wl);
        return pdf > 0.0f && (dot(mat.geometricNormal, mat.geometricNormal) <= 0.5f || dot(direction, mat.geometricNormal) > 0.0f);
    }
    mat.inside = !frontFace;
    PreparedBsdf prepared = prepare_bsdf(mat, normal, -incoming, wl);
    float3 random = rand_f3(seed);
    prepared_sample(prepared, random, direction, weight, pdf);
    if (pdf <= 0.0f) return false;
    if (mat.transmission == 0.0f && dot(mat.geometricNormal, mat.geometricNormal) > 0.5f && dot(direction, mat.geometricNormal) <= 0.0f) return false;
    return all(isfinite(weight)) && all(weight >= 0.0f);
}

// Complementary MIS weight for an emitter reached by a BSDF continuation.
// References: MIS1995, PBRT2023 in REFERENCES.md.
float emission_weight(bool previousDelta, bool previousNEE, bool previousMIS,
                      float bsdfPDF, float lightPDF) {
    if (previousDelta || !previousNEE || lightPDF <= 0.0f) return 1.0f;
    return previousMIS ? power_heuristic(bsdfPDF, lightPDF) : 0.0f;
}

// Maximum path depth follows pbrt: depth 1 is direct lighting only. Each
// non-delta continuation consumes one scattering event; the last vertex still
// receives NEE. Every depth-dependent decision derives from this one budget.
int scattering_limit(float pathDepth) {
    return max(0, int(pathDepth) - 1);
}

// ReSTIR GI estimates the x1 -> x2 -> light suffix, so it needs one continuation.
bool restir_gi_enabled(float pathDepth) {
    return scattering_limit(pathDepth) >= 1;
}

// A camera-primary-secondary diffuse path can sample the secondary BSDF only
// when the scattering budget permits the second non-delta continuation.
bool restir_gi_has_complementary_bsdf(float pathDepth) {
    return scattering_limit(pathDepth) >= 2;
}

// Bounded, single-scatter camera fog. This preview does not model multiple scattering.
// Spectral: the medium is grey, so the scattered light is converted at the pixel's wavelengths.
template <typename R>
float3 apply_camera_fog(float3 color, Ray ray, float surfaceDistance,
                        constant Uniforms &u, thread R &seed, constant MaterialResources &materialImages,
                        thread const Wavelengths &wl) {
    float3 lo = (u.sceneIndex == 0 || u.sceneIndex == 6) ? float3(-4, -1, -2) : float3(-1);
    float3 hi = (u.sceneIndex == 0 || u.sceneIndex == 6) ? float3(4, 3, 3) : float3(1);
    if (u.sceneIndex == 2 || u.sceneIndex == 5) { lo = float3(-4, -1, -2); hi = float3(4, 3, 3); }
    float entry = 0.0f, exitT = surfaceDistance;
    for (int axis = 0; axis < 3; ++axis) {
        if (abs(ray.direction[axis]) < 1e-6f) {
            if (ray.origin[axis] < lo[axis] || ray.origin[axis] > hi[axis]) return color;
        } else {
            float a = (lo[axis] - ray.origin[axis]) / ray.direction[axis];
            float b = (hi[axis] - ray.origin[axis]) / ray.direction[axis];
            entry = max(entry, min(a, b));
            exitT = min(exitT, max(a, b));
        }
    }
    if (exitT <= entry) return color;
    float sigmaT = (u.sceneIndex == 0 || u.sceneIndex == 6) ? 0.09f : 0.22f;
    float step = (exitT - entry) / 8.0f;
    float3 scattered = float3(0.0f);
    for (int i = 0; i < 8; ++i) {
        // Z mode: one event per step, so the steps of neighbouring pixels complement each other.
        sampler_event(seed, uint(i), Z_FOG);
        float t = entry + (float(i) + rand_f(seed)) * step;
        float3 point = ray.origin + ray.direction * t;
        LightSample ls = sample_direct_light(point, float3(0, 1, 0), u, seed, materialImages);
        if (light_visible(point, float3(0), ls, u.sceneIndex, materialImages, u)) {
            float lightDistance = ls.isDirectional == 1 ? 3.0f : ls.dist;
            float transmittance = exp(-sigmaT * (t - entry + lightDistance));
            scattered += spectrum_rgb(transmittance * (0.85f * sigmaT) * light_spectrum(ls, wl) * step / (4.0f * PI * ls.pdf), wl);
        }
    }
    return color * exp(-sigmaT * (exitT - entry)) + scattered;
}

// Resolved camera hit, written once by pass 1 and read by the shading and
// MetalFX guide passes instead of retracing and re-resolving the primary ray.
// Position and distance live in gbufferPosDepth; values stay full precision.
struct PrimarySurface {
    packed_float3 normal; uint flags;             // type | front face << 8 | MaterialX << 9 | slot << 16
    packed_float3 geometricNormal; float roughness;
    packed_float3 color; float ior;               // albedo, or emission for EMISSIVE
    packed_float3 tangent; float metalness;
    float coat, anisotropy, fuzz, transmission;
    float coatRoughness, specularWeight, baseWeight, diffuseRoughness;
    uint triangle; float error;                   // HitRecord.triangle and position rounding bound
    packed_float3 emission;                       // Material.emission (MaterialX emission for OPENPBR)
    packed_float3 view;                           // primary ray direction (ReSTIR PT shifts into this pixel)
};
static_assert(sizeof(PrimarySurface) == 128, "Swift allocates 128-byte primary surfaces");

PrimarySurface store_primary_surface(HitRecord hit, float3 view = float3(0.0f)) {
    PrimarySurface s;
    Material m = hit.mat;
    s.normal = hit.normal; s.geometricNormal = hit.geometricNormal; s.tangent = m.tangent;
    s.triangle = hit.triangle; s.error = hit.error;
    s.flags = uint(m.type) | (hit.front_face ? 256u : 0u) | (m.usesMaterialX ? 512u : 0u) | (min(m.slot, 65535u) << 16);
    s.color = m.type == EMISSIVE ? m.emission : m.albedo;
    s.roughness = m.roughness; s.ior = m.ior; s.metalness = m.metalness;
    s.coat = m.coat; s.anisotropy = m.anisotropy; s.fuzz = m.fuzz; s.transmission = m.transmission;
    s.coatRoughness = m.coatRoughness; s.specularWeight = m.specularWeight;
    s.baseWeight = m.baseWeight; s.diffuseRoughness = m.diffuseRoughness;
    s.emission = m.emission; s.view = view;
    return s;
}

HitRecord load_primary_surface(PrimarySurface s, float4 positionDepth) {
    HitRecord hit = {};
    hit.t = positionDepth.w; hit.position = positionDepth.xyz;
    hit.normal = s.normal; hit.geometricNormal = s.geometricNormal; hit.tangent = s.tangent;
    hit.front_face = (s.flags & 256u) != 0;
    hit.triangle = s.triangle; hit.error = s.error;
    Material m = {};
    m.type = MaterialType(s.flags & 255u);
    if (m.type == EMISSIVE) m.emission = s.color; else m.albedo = s.color;
    m.roughness = s.roughness; m.ior = s.ior; m.slot = s.flags >> 16; m.metalness = s.metalness;
    m.coat = s.coat; m.anisotropy = s.anisotropy; m.fuzz = s.fuzz; m.transmission = s.transmission;
    m.tangent = s.tangent; m.coatRoughness = s.coatRoughness; m.specularWeight = s.specularWeight;
    m.baseWeight = s.baseWeight; m.diffuseRoughness = s.diffuseRoughness;
    m.emission = s.emission;
    m.usesMaterialX = (s.flags & 512u) != 0 ? 1u : 0u;
    m.inside = !hit.front_face; m.geometricNormal = s.geometricNormal;
    hit.mat = m;
    return hit;
}

// ReSTIR DI and GI reservoirs of one reuse domain (a primary hit and its view direction): the
// selected sample, the running resampling-weight sum and the confidence M. restir_temporal_kernel
// builds them for the front layer; the reservoir-splatting kernels also for deep layers (HONG2026).
// Spectral transport: a sample is a pair (sample, wavelength number u) and every domain evaluates
// it at its u, so the shifts and their Jacobians are those of RGB mode. The stored layouts carry u
// in weights.w (zero in RGB) and GI's secondary radiance per wavelength in radiance.xyzw.
struct DIReservoir { LightSample sample; float weightSum; float M; };
struct GIReservoir { float3 position, normal; Spectrum radiance; float sourcePdf, weightSum, M, u; };
#if VIBE_SPECTRAL
float4 gi_radiance_texel(Spectrum r) { return r; }
Spectrum gi_radiance(float4 t) { return t; }
#else
float4 gi_radiance_texel(Spectrum r) { return float4(r, 0.0f); }
Spectrum gi_radiance(float4 t) { return t.xyz; }
#endif

// Initial light candidates (RIS M = 4) at a diffuse primary hit. In Z mode the four candidates
// are the consecutive block of four indices under the pixel's key (sampler_candidate), so
// they are stratified; the resampling decisions stay on the PCG stream.
template <typename R>
DIReservoir restir_di_initial(HitRecord rec, float3 view, constant Uniforms &u, thread R &seed,
                              constant MaterialResources &images, thread const Wavelengths &wl) {
    DIReservoir r;
    r.sample = {};
    r.sample.pdf = 0.0f;
    r.sample.position = float3(0.0f);
    r.sample.wi = float3(0.0f);
    r.sample.emission = float3(0.0f);
    r.sample.isDirectional = 0;
    r.weightSum = 0.0f;
    r.M = 0.0f;
    for (int i = 0; i < 4; ++i) {
        sampler_candidate(seed, 1u, Z_DI, uint(i), 2u);
        LightSample cand = sample_direct_light(rec.position, rec.normal, u, seed, images);
        cand.u = wavelength_u(wl);
        r.M += 1.0f; // Zero-weight candidates still count in the estimator.
        if (cand.pdf > 0.0f) {
            float p_hat = eval_restir_target_pdf(rec.position, rec.normal, view, rec.mat, cand, u.sceneIndex, u.light.w, images, wl);
            float proposalPDF = cand.pdf * light_geometry(rec.position, cand, u.sceneIndex, u.light.w, images);
            float w_i = proposalPDF > 0.0f ? p_hat / proposalPDF : 0.0f;
            r.weightSum += w_i;
            if (rand_decision(seed) * r.weightSum < w_i) {
                r.sample = cand;
            }
        }
    }
    return r;
}

// A stored DI sample (the reservoir texture layout) seen from the shading point p; u is the
// reservoir's weights.w.
LightSample restir_di_stored_sample(float4 posDir, float4 emitPdf, float3 p, float u) {
    LightSample s = {};
    s.position = posDir.xyz;
    s.isDirectional = uint(posDir.w);
    s.wi = (s.isDirectional == 1) ? s.position : normalize(s.position - p);
    s.emission = emitPdf.xyz;
    s.pdf = emitPdf.w;
    s.u = u;
    return s;
}

// Temporal DI merge of a history reservoir (confidence M, contribution weight W, wavelength
// number histU) with the history confidence capped at 20. The caller has checked M > 0 and W > 0.
void restir_di_merge(thread DIReservoir &r, HitRecord rec, float3 view, float4 histPosDir, float4 histEmitPdf,
                     float histM, float histW, float histU, constant Uniforms &u, thread uint &seed, constant MaterialResources &images,
                     thread const Wavelengths &wl) {
    LightSample histSample = restir_di_stored_sample(histPosDir, histEmitPdf, rec.position, histU);
    float prev_p_hat = eval_restir_target_pdf(rec.position, rec.normal, view, rec.mat, histSample, u.sceneIndex, u.light.w, images, wl);
    float clampedM = min(histM, 20.0f);
    float w_temporal = prev_p_hat * histW * clampedM;
    r.M += clampedM;
    r.weightSum += w_temporal;
    if (rand_f(seed) * r.weightSum < w_temporal) {
        r.sample = histSample;
    }
}

// The reservoir's stored form: sample position (or direction) and type, emission and PDF, and
// (weight sum, M, W, wavelength number).
void restir_di_encode(DIReservoir r, HitRecord rec, float3 view, constant Uniforms &u, constant MaterialResources &images,
                      thread float4 &posDir, thread float4 &emitPdf, thread float4 &weights, thread const Wavelengths &wl) {
    float current_p_hat = eval_restir_target_pdf(rec.position, rec.normal, view, rec.mat, r.sample, u.sceneIndex, u.light.w, images, wl);
    float W = (r.M > 0.0f && current_p_hat > 0.0f) ? (r.weightSum / (r.M * current_p_hat)) : 0.0f;
    float3 storeDirPos = (r.sample.isDirectional == 1) ? r.sample.wi : r.sample.position;
    posDir = float4(storeDirPos, float(r.sample.isDirectional));
    emitPdf = float4(r.sample.emission, r.sample.pdf);
    weights = float4(r.weightSum, r.M, W, r.sample.u);
}

// ReSTIR GI initial path: x0(camera) -> x1(primary diffuse) -> x2(diffuse) -> sampled light. It
// stores x2 and its one-sample outgoing direct radiance; deeper transport remains in the ordinary
// path continuation. fovScale is tan(fov / 2), for the texture footprint at x2.
template <typename R>
GIReservoir restir_gi_initial(HitRecord rec, float3 view, float fovScale, constant Uniforms &u,
                              constant SurfaceSettings *surfaceSettings, constant MaterialResources &images, thread R &seed,
                              thread const Wavelengths &wl) {
    GIReservoir r;
    r.position = float3(0.0f);
    r.normal = float3(0.0f);
    r.radiance = Spectrum(0.0f);
    r.sourcePdf = 0.0f;
    r.weightSum = 0.0f;
    r.M = 1.0f;
    r.u = wavelength_u(wl);
    float3 giDirection;
    Spectrum giBSDFWeight;
    float giBSDFPdf;
    sampler_event(seed, 1u, Z_GI_BSDF);
    if (sample_bsdf(rec.mat, rec.normal, view, rec.front_face, seed,
                    giDirection, giBSDFWeight, giBSDFPdf, wl) && giBSDFPdf > 0.0f) {
        Ray giRay;
        giRay.origin = ray_origin(rec.position, rec.geometricNormal, giDirection, u, rec.error);
        giRay.direction = giDirection;
        HitRecord secondary;
        if (trace_scene(giRay, u.sceneIndex, secondary, images, u)) {
            resolve_material(secondary, giRay, u, surfaceSettings, images,
                (rec.t + secondary.t) * 2.0f * fovScale / float(u.height));
            if (secondary.mat.type == DIFFUSE) {
                Spectrum secondaryRadiance = Spectrum(0.0f);
                sampler_event(seed, 2u, Z_GI_NEE);
                LightSample giLight = sample_direct_light(secondary.position, secondary.normal, u, seed, images);
                if (giLight.pdf > 0.0f && light_visible(secondary.position,
                    secondary.geometricNormal, giLight, u.sceneIndex, images, u, secondary.error)) {
                    float secondaryCosine = max(0.0f, dot(secondary.normal, giLight.wi));
                    float secondaryBSDFPdf;
                    Spectrum secondaryBSDF = eval_bsdf_with_pdf(secondary.mat, secondary.normal,
                        -giRay.direction, giLight.wi, secondaryBSDFPdf, wl);
                    float mis = restir_gi_has_complementary_bsdf(u.cameraTarget.w)
                        ? power_heuristic(giLight.pdf, secondaryBSDFPdf) : 1.0f;
                    secondaryRadiance = secondaryBSDF * secondaryCosine * light_spectrum(giLight, wl) *
                        (mis / giLight.pdf);
                }
                float3 giDelta = secondary.position - rec.position;
                float d2 = dot(giDelta, giDelta);
                float cosSecondary = max(0.0f, dot(secondary.normal, -giDirection));
                float sourcePdfArea = d2 > 1e-10f ? giBSDFPdf * cosSecondary / d2 : 0.0f;
                float pHat = eval_restir_gi_target(rec.position, rec.normal, view,
                    rec.mat, secondary.position, secondary.normal, secondaryRadiance, wl);
                if (sourcePdfArea > 0.0f && pHat > 0.0f) {
                    r.position = secondary.position;
                    r.normal = secondary.normal;
                    r.radiance = secondaryRadiance;
                    r.sourcePdf = sourcePdfArea;
                    r.weightSum = pHat / sourcePdfArea;
                }
            }
        }
    }
    return r;
}

// Temporal GI merge: the stored secondary point of a history reservoir whose primary hit was
// sourceX1 is reconnected and reweighted at rec. The caller has checked the reservoir's M, W,
// source PDF and normal flag.
void restir_gi_merge(thread GIReservoir &r, HitRecord rec, float3 view, float3 sourceX1, float4 oldGIPosPdf,
                     float4 oldGINormal, Spectrum oldGIRadiance, float oldU, float oldM, float oldW, thread uint &seed,
                     thread const Wavelengths &wl) {
    if (!restir_gi_accepts_shift(rec.position, sourceX1, oldGIPosPdf.xyz, oldGINormal.xyz)) return;
    float pHat = eval_restir_gi_target(rec.position, rec.normal, view, rec.mat,
        oldGIPosPdf.xyz, oldGINormal.xyz, oldGIRadiance, sample_wavelengths(oldU, wl));
    float clampedM = min(oldM, 20.0f);
    float temporalWeight = pHat * oldW * clampedM;
    r.M += clampedM;
    r.weightSum += temporalWeight;
    if (rand_f(seed) * r.weightSum < temporalWeight) {
        r.position = oldGIPosPdf.xyz;
        r.normal = oldGINormal.xyz;
        r.radiance = oldGIRadiance;
        r.sourcePdf = oldGIPosPdf.w;
        r.u = oldU;
    }
}

void restir_gi_encode(GIReservoir r, HitRecord rec, float3 view, thread float4 &posPdf, thread float4 &normal,
                      thread float4 &radiance, thread float4 &weights, thread const Wavelengths &wl) {
    float target = eval_restir_gi_target(rec.position, rec.normal, view, rec.mat, r.position, r.normal, r.radiance,
                                         sample_wavelengths(r.u, wl));
    float W = r.M > 0.0f && target > 0.0f ? r.weightSum / (r.M * target) : 0.0f;
    posPdf = float4(r.position, r.sourcePdf);
    normal = float4(r.normal, r.sourcePdf > 0.0f ? 1.0f : 0.0f);
    radiance = gi_radiance_texel(r.radiance);
    weights = float4(r.weightSum, r.M, W, r.u);
}

// The ReSTIR DI same-surface test of temporal reprojection. position / oldPosition hold
// (point, camera distance), normal / oldNormal (normal, material type).
bool restir_same_surface(float4 position, float4 normal, float4 oldPos, float4 oldNormal) {
    return oldPos.w > 0.0f && oldNormal.w == normal.w &&
        dot(oldNormal.xyz, normal.xyz) > 0.95f &&
        distance(oldPos.xyz, position.xyz) < max(0.01f, position.w * 0.01f);
}
bool restir_same_surface(float4 oldPos, float4 oldNormal, HitRecord rec) {
    return restir_same_surface(float4(rec.position, rec.t), float4(rec.normal, float(rec.mat.type)), oldPos, oldNormal);
}

// Temporal reprojection (backprojection) of a primary hit into the previous frame: the pixel
// whose reservoir is reused. Reservoir history survives camera motion; the same-surface test
// rejects disocclusions.
bool restir_backproject(float3 position, constant Uniforms &u, thread int2 &prevCoord) {
    float4 prevClip = u.prevViewProj * float4(position, 1.0f);
    if (!(prevClip.w > 0.0f) || u.reservoirHistory <= 1 || u.reservoirHistoryReset != 0) return false;
    float2 prevUV = (prevClip.xy / prevClip.w) * float2(0.5f, -0.5f) + 0.5f;
    prevCoord = int2(prevUV * float2(float(u.width), float(u.height)));
    return all(prevUV >= 0.0f) && all(prevUV < 1.0f) && prevCoord.x >= 0 && prevCoord.x < int(u.width) &&
        prevCoord.y >= 0 && prevCoord.y < int(u.height);
}

// ============================================================================
// PASS 1: G-Buffer & ReSTIR Temporal Reuse Kernel
// Reference: RESTIR2020; local reuse approximations are documented in REFERENCES.md.
// ============================================================================

kernel void restir_temporal_kernel(
    texture2d<float, access::write> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::write> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::write> gbufferAlbedoRough [[texture(2)]],
    texture2d<float, access::write> outSamplePosDir [[texture(3)]],
    texture2d<float, access::write> outSampleEmitPdf [[texture(4)]],
    texture2d<float, access::write> outReservoirWeights [[texture(5)]],
    texture2d<float, access::read> histSamplePosDir [[texture(6)]],
    texture2d<float, access::read> histSampleEmitPdf [[texture(7)]],
    texture2d<float, access::read> histReservoirWeights [[texture(8)]],
    texture2d<float, access::read> histPosDepth [[texture(9)]],
    texture2d<float, access::read> histNormalMat [[texture(10)]],
    texture2d<float, access::write> outGIPosPdf [[texture(11)]],
    texture2d<float, access::write> outGINormal [[texture(12)]],
    texture2d<float, access::write> outGIRadiance [[texture(13)]],
    texture2d<float, access::write> outGIWeights [[texture(14)]],
    texture2d<float, access::read> histGIPosPdf [[texture(15)]],
    texture2d<float, access::read> histGINormal [[texture(16)]],
    texture2d<float, access::read> histGIRadiance [[texture(17)]],
    texture2d<float, access::read> histGIWeights [[texture(18)]],
    constant Uniforms &uniforms [[buffer(0)]],
    constant SurfaceSettings *surfaceSettings [[buffer(1)]],
    constant MaterialResources &materialImages [[buffer(2)]],
    device PrimarySurface *primarySurfaces [[buffer(3)]]
    SPECTRAL_BUFFERS,
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) return;

    Sampler seed = pixel_sampler(gid, uniforms);
    // The pixel's wavelengths: pass 2 derives the same ones from the same sampler.
    Wavelengths wl = SPECTRAL_WAVELENGTHS(wavelength_numbers(seed), uniforms, materialImages);
    float aspect = float(uniforms.width) / float(uniforms.height);
    float fov_scale = tan((uniforms.cameraPos.w * 0.5f) * PI / 180.0f);

    float2 jitter = uniforms.jitter + 0.5f;
    float u = ((float(gid.x) + jitter.x) / float(uniforms.width)) * 2.0f - 1.0f;
    float v = ((float(gid.y) + jitter.y) / float(uniforms.height)) * 2.0f - 1.0f;
    v = -v;

    u *= aspect * fov_scale;
    v *= fov_scale;

    float3 camPos = uniforms.cameraPos.xyz;
    float3 forward = normalize(uniforms.cameraTarget.xyz - camPos);
    float3 right = normalize(cross(forward, uniforms.cameraUp.xyz));
    float3 up = cross(right, forward);

    Ray ray;
    ray.origin = camPos;
    ray.direction = normalize(forward + u * right + v * up);
    lens_ray(ray,forward,right,up,uniforms,seed);

    HitRecord rec;
    bool hit = trace_scene(ray, uniforms.sceneIndex, rec, materialImages, uniforms);

    // Non-ReSTIR and inspection passes bind 1x1 placeholder reservoirs. They must
    // not read or write those resources, so the host need not allocate full-size
    // DI/GI history for these modes.
    // ReSTIR PT modes leave the GI reservoirs as placeholders, and unified PT the DI ones.
    bool reservoirsBound = uniforms.viewportMode == 0 && uniforms.samplingMode == 0;
    bool diBound = reservoirsBound && restir_di_active(uniforms);
    bool giBound = reservoirsBound && restir_gi_active(uniforms);
    if (!hit) {
        gbufferPosDepth.write(float4(0.0f, 0.0f, 0.0f, -1.0f), gid);
        gbufferNormalMat.write(float4(0.0f, 0.0f, 0.0f, -1.0f), gid);
        gbufferAlbedoRough.write(float4(0.0f), gid);
        if (diBound) {
            outSamplePosDir.write(float4(0.0f), gid);
            outSampleEmitPdf.write(float4(0.0f), gid);
            outReservoirWeights.write(float4(0.0f), gid);
        }
        if (giBound) {
            outGIPosPdf.write(float4(0.0f), gid);
            outGINormal.write(float4(0.0f), gid);
            outGIRadiance.write(float4(0.0f), gid);
            outGIWeights.write(float4(0.0f), gid);
        }
        return;
    }

    resolve_material(rec, ray, uniforms, surfaceSettings, materialImages, rec.t * 2.0f * fov_scale / float(uniforms.height));
    primarySurfaces[gid.y * uniforms.width + gid.x] = store_primary_surface(rec, ray.direction);
    gbufferPosDepth.write(float4(rec.position, rec.t), gid);
    gbufferNormalMat.write(float4(rec.normal, float(rec.mat.type)), gid);
    float3 surfaceColor = rec.mat.type == EMISSIVE ? rec.mat.emission : rec.mat.albedo;
    float surfaceParameter = rec.mat.type == DIELECTRIC
        ? (rec.front_face ? rec.mat.ior : -rec.mat.ior) : rec.mat.roughness;
    gbufferAlbedoRough.write(float4(surfaceColor, surfaceParameter), gid);

    if (!diBound && !giBound) return;
    if (rec.mat.type != DIFFUSE) {
        if (diBound) {
            outSamplePosDir.write(float4(0.0f), gid);
            outSampleEmitPdf.write(float4(0.0f), gid);
            outReservoirWeights.write(float4(0.0f), gid);
        }
        if (giBound) {
            outGIPosPdf.write(float4(0.0f), gid);
            outGINormal.write(float4(0.0f), gid);
            outGIRadiance.write(float4(0.0f), gid);
            outGIWeights.write(float4(0.0f), gid);
        }
        return;
    }

    // Initial Candidate Generation (RIS M = 4)
    DIReservoir di = restir_di_initial(rec, ray.direction, uniforms, seed, materialImages, wl);

    // Temporal Reprojection. Reservoir history survives camera motion; the
    // reprojected surface test below rejects disocclusions. With reservoir splatting
    // (splat_frame), splat_temporal_kernel merges the temporal candidates instead.
    int2 prevCoord;
    bool temporal = !splat_frame(uniforms) && restir_backproject(rec.position, uniforms, prevCoord);
    if (temporal) {
        float4 histWeights = histReservoirWeights.read(uint2(prevCoord));
        float histM = histWeights.y;
        float histW = histWeights.z;
        bool sameSurface = restir_same_surface(histPosDepth.read(uint2(prevCoord)), histNormalMat.read(uint2(prevCoord)), rec);
        if (sameSurface && histM > 0.0f && histW > 0.0f) {
            restir_di_merge(di, rec, ray.direction, histSamplePosDir.read(uint2(prevCoord)),
                histSampleEmitPdf.read(uint2(prevCoord)), histM, histW, histWeights.w, uniforms, seed.state, materialImages, wl);
        }
    }

    float4 diPosDir, diEmitPdf, diWeights;
    restir_di_encode(di, rec, ray.direction, uniforms, materialImages, diPosDir, diEmitPdf, diWeights, wl);
    outSamplePosDir.write(diPosDir, gid);
    outSampleEmitPdf.write(diEmitPdf, gid);
    outReservoirWeights.write(diWeights, gid);
    // In ReSTIR PT mode (DI bound, GI placeholders) the restir_pt_* passes estimate longer paths.
    if (!giBound) return;

    // Depth 1 has no indirect bounce for GI reservoirs to estimate.
    if (!restir_gi_enabled(uniforms.cameraTarget.w)) {
        outGIPosPdf.write(float4(0.0f), gid);
        outGINormal.write(float4(0.0f), gid);
        outGIRadiance.write(float4(0.0f), gid);
        outGIWeights.write(float4(0.0f), gid);
        return;
    }

    GIReservoir gi = restir_gi_initial(rec, ray.direction, fov_scale, uniforms, surfaceSettings, materialImages, seed, wl);

    // Temporal GI reservoir merge. Primary-surface reprojection defines the
    // reuse domain; the secondary point is reconnected and reweighted at x1.
    if (temporal) {
        float4 oldPos = histPosDepth.read(uint2(prevCoord));
        bool sameSurface = restir_same_surface(oldPos, histNormalMat.read(uint2(prevCoord)), rec);
        float4 oldGIWeights = histGIWeights.read(uint2(prevCoord));
        float4 oldGIPosPdf = histGIPosPdf.read(uint2(prevCoord));
        float4 oldGINormal = histGINormal.read(uint2(prevCoord));
        if (sameSurface && oldGIWeights.y > 0.0f && oldGIWeights.z > 0.0f &&
            oldGIPosPdf.w > 0.0f && oldGINormal.w > 0.0f) {
            restir_gi_merge(gi, rec, ray.direction, oldPos.xyz, oldGIPosPdf, oldGINormal,
                gi_radiance(histGIRadiance.read(uint2(prevCoord))), oldGIWeights.w, oldGIWeights.y, oldGIWeights.z, seed.state, wl);
        }
    }
    float4 giPosPdf, giNormal, giRadiance, giWeights;
    restir_gi_encode(gi, rec, ray.direction, giPosPdf, giNormal, giRadiance, giWeights, wl);
    outGIPosPdf.write(giPosPdf, gid);
    outGINormal.write(giNormal, gid);
    outGIRadiance.write(giRadiance, gid);
    outGIWeights.write(giWeights, gid);
}

// ============================================================================
// Spatial neighbour selection for ReSTIR DI/GI (Uniforms.spatialNeighbors)
// 0: RESTIR2020 uniform taps with a binary normal/depth/material test.
// 1: COMPATRESTIR2026 compatibility-guided selection (Algorithm 1), with the
//    RESTIR2020 Algorithm 6 (1/Z) normalization of the reused confidences.
// ============================================================================

// Uniform mode draws UNIFORM_TAPS taps per reservoir type; compatibility mode
// reuses up to SPATIAL_NEIGHBORS neighbours per reservoir type (DI and GI select
// independently), drawn from COMPAT_CANDIDATES G-buffer taps within
// COMPAT_RADIUS pixels.
constant int UNIFORM_TAPS = 4;
#define SPATIAL_NEIGHBORS 4u
#define COMPAT_CANDIDATES 32u
#define COMPAT_RADIUS 24.0f

// RESTIR2020 uniform tap: a 16-pixel box around the pixel, two random draws.
int2 uniform_neighbor(uint2 gid, thread uint &seed) {
    return int2(gid) + int2((rand_f2(seed) * 2.0f - 1.0f) * 16.0f);
}
// RESTIR2020's binary compatibility test (local thresholds: 0.95 normal cosine,
// 5% depth), used by uniform mode.
bool restir2020_compatible(float4 posDepth, float3 norm, MaterialType type, float4 nPosDepth, float4 nNormMat) {
    return nPosDepth.w > 0.0f && nNormMat.w == float(type) && dot(norm, nNormMat.xyz) > 0.95f &&
        abs(posDepth.w - nPosDepth.w) < 0.05f * posDepth.w;
}

// COMPATRESTIR2026 Eqs. 14-15: h = exp(-|x1 - y1| / s) max(n1 . ny, 0)^8, with
// s = sqrt(Omega d^2 / pi) the world radius of Omega = 0.05 sr at hit distance d.
float restir_compatibility(float3 x1, float3 n1, float depth, float3 y1, float3 ny) {
    float s = depth * sqrt(0.05f / PI);
    if (!(s > 0.0f)) return 0.0f;
    float c = max(dot(n1, ny), 0.0f), c2 = c * c, c4 = c2 * c2;
    return exp(-distance(x1, y1) / s) * (c4 * c4);
}

// Shirley-Chiu concentric map of [0,1)^2 onto the unit disk.
float2 concentric_disk(float2 u) {
    float2 o = 2.0f * u - 1.0f;
    if (o.x == 0.0f && o.y == 0.0f) return float2(0.0f);
    bool wide = abs(o.x) > abs(o.y);
    float r = wide ? o.x : o.y;
    float theta = wide ? (PI * 0.25f) * (o.y / o.x) : PI * 0.5f - (PI * 0.25f) * (o.x / o.y);
    return r * float2(cos(theta), sin(theta));
}

// Candidate k: the R2 sequence (1/g, 1/g^2 for the plastic number g) with a
// random start (Cranley-Patterson rotation), through the concentric map.
int2 compat_candidate(uint2 gid, float2 start, uint k) {
    const float2 r2 = float2(0.75487766624669276f, 0.56984029099805327f);
    float2 offset = concentric_disk(fract(start + float(k) * r2)) * COMPAT_RADIUS;
    return int2(gid) + int2(floor(offset + 0.5f));
}

struct SpatialNeighbors {
    int2 coord[SPATIAL_NEIGHBORS];
    uint count;
};

// COMPATRESTIR2026 Algorithm 1. The pixel itself, off-screen taps and pixels
// without a diffuse primary hit (which hold no reservoirs) score zero. A-ES
// keeps the SPATIAL_NEIGHBORS largest keys log(u)/h, a weighted sample without
// replacement whose first rank is an A-Chao draw proportional to h; the search
// stops once more than SPATIAL_NEIGHBORS taps score above 0.5. Only G-buffer
// values and fresh random numbers decide the set, never reservoir contents.
SpatialNeighbors select_compatible_neighbors(uint2 gid, float3 pos, float3 norm, float depth,
                                             texture2d<float, access::read> gbufferPosDepth,
                                             texture2d<float, access::read> gbufferNormalMat,
                                             constant Uniforms &u, thread uint &seed) {
    SpatialNeighbors result;
    result.count = 0;
    float keys[SPATIAL_NEIGHBORS];
    float2 start = rand_f2(seed);
    uint strong = 0;
    for (uint k = 0; k < COMPAT_CANDIDATES && strong <= SPATIAL_NEIGHBORS; ++k) {
        int2 c = compat_candidate(gid, start, k);
        if (all(c == int2(gid)) || c.x < 0 || c.y < 0 || c.x >= int(u.width) || c.y >= int(u.height)) continue;
        float4 p = gbufferPosDepth.read(uint2(c));
        float4 n = gbufferNormalMat.read(uint2(c));
        if (p.w <= 0.0f || n.w != float(DIFFUSE)) continue;
        float h = restir_compatibility(pos, norm, depth, p.xyz, n.xyz);
        if (!(h > 0.0f)) continue;
        if (h > 0.5f) ++strong;
        bool held = false;
        for (uint i = 0; i < result.count; ++i) held = held || all(result.coord[i] == c);
        if (held) continue;
        float key = log(1.0f - rand_f(seed)) / h;
        uint slot;
        if (result.count < SPATIAL_NEIGHBORS) slot = result.count++;
        else if (key > keys[SPATIAL_NEIGHBORS - 1]) slot = SPATIAL_NEIGHBORS - 1;
        else continue;
        for (; slot > 0 && keys[slot - 1] < key; --slot) {
            keys[slot] = keys[slot - 1];
            result.coord[slot] = result.coord[slot - 1];
        }
        keys[slot] = key;
        result.coord[slot] = c;
    }
    return result;
}

// RESTIR2020 Algorithm 6, line 8: whether neighbour q's target can be nonzero at
// the selected sample, so that q's confidence M belongs in Z. Local, geometric
// form from q's G-buffer: the sample lies above q's shading normal (DI), or
// faces q and reconnects to it within the Jacobian bound (GI; the bound is
// symmetric in J and 1/J). q's albedo, geometric normal, view side and emitter
// facing are not tested; see REFERENCES.md COMPATRESTIR2026.
bool restir_di_in_support(float3 qPosition, float3 qNormal, LightSample y) {
    float3 direction = y.isDirectional == 1 ? y.wi : normalize(y.position - qPosition);
    return dot(qNormal, direction) > 0.0f;
}
bool restir_gi_in_support(float3 x1, float3 qPosition, float3 qNormal, float3 x2, float3 n2) {
    return gi_geometry(qPosition, qNormal, x2, n2) > 0.0f && restir_gi_accepts_shift(x1, qPosition, x2, n2);
}

// ============================================================================
// ReSTIR PT: path reservoirs, hybrid shift and GRIS reuse
// REFERENCES.md: RESTIRPT2022 (GRIS, lobe-free hybrid shift of random replay and
// reconnection, generalized Talbot and defensive pairwise resampling MIS) and
// RESTIRPTE2026 (dual-footprint reconnection criteria, paired spatial reuse, forced NEE
// reconnection, roulette outside replay, vector-weight shading, duplication maps, and
// optionally unified DI + GI reservoirs). Local adaptations are listed there.
// ============================================================================


#define PT_MAX_VERTICES 255u
#define PT_NEIGHBORS 3u
// RESTIRPTE2026 Eq. 5 constant c, the single-vertex roughness threshold (Sec. 4.2 and
// RESTIRPT2022's 0.2), and the temporal confidence cap c_Cap with its Sec. 5 minimum.
constant float PT_FOOTPRINT_C = 0.02f;
constant float PT_ROUGHNESS_MIN = 0.2f;
constant float PT_CONFIDENCE_CAP = 20.0f;
constant float PT_CONFIDENCE_MIN = 1.0f;
constant float PT_DUPLICATION_EXPONENT = 0.1f;

// One selected path per pixel, 64 bytes (RESTIRPTE2026 Algorithm 1 layout, with the
// reconnection vertex stored as a position instead of instance/primitive/barycentrics).
//   F           integrand of the path at this pixel (target p-hat = luminance(F))
//   W, M        unbiased contribution weight and confidence
//   rcPosition  reconnection vertex x_k (a direction when x_k is the environment)
//   rcRadiance  L_k: the path contribution after x_k's scattering (MIS-free when k >= d - 1)
//   rcJacobian  the base path's PSS Jacobian denominator p_{k-1}(w_{k-1}) G(x_{k-1} -> x_k) p_k(w_k)
//   seed        random-replay seed; per-vertex streams come from pt_seed
//   flags       d (bits 0-7), k (8-15, 0 = replay only), NEE-sampled end (16), environment
//               x_k (17), non-delta continuations among x_1..x_{k-1} (18-23)
//   rcDirection w_k, octahedral 2 x 16 bit;  lightPdf  NEE solid-angle PDF of the light
//               vertex from x_{d-1}, kept for the final MIS weight when k = d - 1.
// Spectral transport: F stays linear sRGB (the integrand at the path's wavelengths, converted), and
// L_k, which receivers multiply by their own prefix, is stored per wavelength as its maximum and four
// 16-bit fractions of it (the 12 bytes of rcRadiance). The wavelength numbers are not stored: every
// pass re-derives them from the replay seed (pt_wavelengths), as random replay re-derives its draws.
struct PTReservoir {
    packed_float3 F; float W;
    packed_float3 rcPosition; float M;
#if VIBE_SPECTRAL
    float rcScale; uint rcLanes[2];
#else
    packed_float3 rcRadiance;
#endif
    float rcJacobian;
    uint seed; uint flags; uint rcDirection; float lightPdf;
};
static_assert(sizeof(PTReservoir) == 64, "Swift allocates 64-byte ReSTIR PT reservoirs");

constant uint PT_NEE = 1u << 16;
constant uint PT_ENVIRONMENT = 1u << 17;
// Spectral transport: L_k passed a dispersive vertex, so it holds only the hero lane (unscaled); a
// receiver whose prefix kept all four lanes applies the hero's factor of four (spectral_arrive).
constant uint PT_RC_DISPERSIVE = 1u << 24;
#if VIBE_SPECTRAL
Spectrum pt_rc_radiance(PTReservoir r) {
    return r.rcScale * float4(float(r.rcLanes[0] & 65535u), float(r.rcLanes[0] >> 16), float(r.rcLanes[1] & 65535u),
                              float(r.rcLanes[1] >> 16)) * (1.0f / 65535.0f);
}
void pt_set_rc_radiance(thread PTReservoir &r, Spectrum L) {
    L = max(L, 0.0f);
    float m = spectrum_max(L);
    if (!(m > 0.0f) || !isfinite(m)) { r.rcScale = 0.0f; r.rcLanes[0] = 0u; r.rcLanes[1] = 0u; return; }
    uint4 q = uint4(round(saturate(L / m) * 65535.0f));
    r.rcScale = m; r.rcLanes[0] = q.x | (q.y << 16); r.rcLanes[1] = q.z | (q.w << 16);
}
// A ReSTIR PT path's wavelengths from its replay seed: in Z mode the seed is the pixel's key, so a
// path generated at a pixel has that pixel's wavelengths (wavelength_numbers).
Wavelengths pt_wavelengths(uint seed, thread const Wavelengths &context) {
    Sampler s;
    s.state = pcg_hash(seed ^ pcg_hash(6u));
    s.z = sampler_z(*context.uniforms);
    s.key = seed; s.dimension = 0u; s.sub = 0u; s.subBits = 0u;
    float2 numbers = wavelength_numbers(s);
    return spectral_wavelengths(numbers.x, numbers.y, context);
}
#else
Spectrum pt_rc_radiance(PTReservoir r) { return float3(r.rcRadiance); }
void pt_set_rc_radiance(thread PTReservoir &r, Spectrum L) { r.rcRadiance = L; }
Wavelengths pt_wavelengths(uint, thread const Wavelengths &context) { return context; }
#endif
uint pt_length(PTReservoir r) { return r.flags & 255u; }
uint pt_rc_index(PTReservoir r) { return (r.flags >> 8) & 255u; }
uint pt_rc_scatter(PTReservoir r) { return (r.flags >> 18) & 63u; }
uint pt_flags(uint length, uint k, bool nee, bool environment, int scatter) {
    return length | (k << 8) | (nee ? PT_NEE : 0u) | (environment ? PT_ENVIRONMENT : 0u) | (uint(clamp(scatter, 0, 63)) << 18);
}

PTReservoir pt_empty() {
    PTReservoir r;
    r.F = float3(0.0f); r.W = 0.0f; r.rcPosition = float3(0.0f); r.M = 0.0f;
    pt_set_rc_radiance(r, Spectrum(0.0f)); r.rcJacobian = 0.0f;
    r.seed = 0u; r.flags = 0u; r.rcDirection = 0u; r.lightPdf = 0.0f;
    return r;
}

float pt_luminance(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }

// ReSTCV (REFERENCES.md: RESTCV2026): each path reservoir carries a colour estimate F_i of its
// pixel, accumulated over space and time with control variates. Per pixel, `estimate` is the
// current frame's F_i (the path tree's initial estimate, then the temporal combination) and
// `reflectance` the primary hit's average reflectance rho_i (Eq. 9), 10 bits per channel on a
// square-root scale. The previous frame's final estimate is the history (ptIndirect.xyz).
struct PTControl { packed_float3 estimate; uint reflectance; };
static_assert(sizeof(PTControl) == 16, "Swift allocates 16-byte ReSTCV estimates");
// Spatial compositing weight of the pixel's own estimate; each valid partner's estimator has
// weight one (RESTCV2026 supplemental Sec. 1: c = 1.6 for about 2.4 valid ReSTIR PT neighbours).
constant float PT_CV_CENTER_WEIGHT = 1.6f;
// Upper bound of the coefficient alpha_ij = rho_i / rho_j (Eq. 9).
constant float PT_CV_ALPHA_MAX = 2.0f;

uint pt_encode_reflectance(float3 rho) {
    uint3 q = uint3(round(sqrt(saturate(rho)) * 1023.0f));
    return q.x | (q.y << 10) | (q.z << 20);
}
float3 pt_decode_reflectance(uint v) {
    float3 r = float3(float(v & 1023u), float((v >> 10) & 1023u), float((v >> 20) & 1023u)) * (1.0f / 1023.0f);
    return r * r;
}
// Average reflectance rho of the primary hit, seen along wo: the diffuse albedo and a Fresnel
// estimate of the specular albedo, as the MetalFX albedo guides estimate them. Transmissive and
// ideal-specular types return one, so their pairs keep alpha = 1.
float3 pt_reflectance(Material m, float3 n, float3 wo) {
    float cosine = max(0.0f, dot(n, wo));
    if (m.type == DIFFUSE) return saturate(m.albedo);
    if (m.type == GLOSSY) return conductor_fresnel(saturate(m.albedo), cosine);
    if (m.type == OPENPBR) {
        float f0 = pow((m.ior - 1.0f) / (m.ior + 1.0f), 2.0f);
        return saturate(m.albedo) * (1.0f - m.metalness) * (1.0f - m.transmission) +
            conductor_fresnel(mix(float3(f0), saturate(m.albedo), m.metalness), cosine);
    }
    return float3(1.0f);
}
// alpha_ij = min(rho_i / rho_j, 2) per channel (Eq. 9); a pair of black channels keeps 1.
float3 pt_cv_alpha(float3 rhoI, float3 rhoJ) {
    return select(min(rhoI / max(rhoJ, 1e-8f), PT_CV_ALPHA_MAX), select(float3(PT_CV_ALPHA_MAX), float3(1.0f), rhoI <= 0.0f), rhoJ <= 0.0f);
}

// Octahedral unit-vector encoding with two 16-bit unorm components.
uint pt_encode_direction(float3 d) {
    d /= max(abs(d.x) + abs(d.y) + abs(d.z), 1e-30f);
    float2 e = d.z >= 0.0f ? d.xy : (1.0f - abs(d.yx)) * select(float2(-1.0f), float2(1.0f), d.xy >= 0.0f);
    uint2 q = uint2(round(clamp(e * 0.5f + 0.5f, 0.0f, 1.0f) * 65535.0f));
    return q.x | (q.y << 16);
}
float3 pt_decode_direction(uint v) {
    float2 e = float2(float(v & 65535u), float(v >> 16)) * (2.0f / 65535.0f) - 1.0f;
    float3 d = float3(e, 1.0f - abs(e.x) - abs(e.y));
    float t = max(-d.z, 0.0f);
    d.xy += select(float2(t), float2(-t), d.xy >= 0.0f);
    return normalize(d);
}

// Random replay (RESTIRPT2022 Sec. 7.2): each sampling event at path vertex j draws from its
// own stream (0 BSDF, 1 NEE, 2 roulette, 3-5 resampling), so replaying a prefix at another
// pixel consumes the same numbers whatever the other events consumed.
uint pt_seed(uint seed, uint pathVertex, uint stream) { return pcg_hash(seed ^ pcg_hash(pathVertex * 8u + stream + 1u)); }
// The sampler of one such stream. In Z mode the reservoir's seed is the pixel's Z++ key at
// generation (pt_initial_seed), so a replay anywhere reproduces the base path's numbers; the
// PCG state (resampling decisions) is derived from it as in PCG mode.
Sampler pt_sampler(uint seed, uint pathVertex, uint stream, constant Uniforms &u) {
    Sampler s;
    s.state = pt_seed(seed, pathVertex, stream);
    s.z = sampler_z(u);
    s.key = seed;
    sampler_event(s, pathVertex, Z_PT + stream);
    return s;
}
// Replay seed of a new path tree of the pixel `gid`; deep splatting domains (layer > 0) XOR the
// layer into bits 26-28 of the key (a distant block, so never another pixel's key of this frame).
uint pt_initial_seed(uint2 gid, uint layer, uint pcgSeed, constant Uniforms &u) {
    return sampler_z(u) ? z_pixel_key(gid, u) ^ (layer << 26) : pcgSeed;
}

// RESTIRPTE2026 Eq. 5 right-hand side: c/100 times the squared primary footprint radius
// |x0 - x1|^2 / (<n_x1, x1->x0> / 4 pi) (Mueller et al. 2021).
float pt_footprint_threshold(float primaryDistance, float3 geometricNormal, float3 view) {
    float c = max(abs(dot(geometricNormal, view)), 1e-4f);
    return PT_FOOTPRINT_C * 0.01f * (4.0f * PI) * primaryDistance * primaryDistance / c;
}

// Single-vertex roughness threshold at x_{k-1} (RESTIRPTE2026 Sec. 4.2). Matte and metal
// types use their parameter; layered OpenPBR, whose lobes this path space does not index,
// uses the supplemental's PDF proxy 1 / p(w_{k-1})^2 >= alpha_min (its Eq. 26).
bool pt_rough(Material m, float pdf) {
    if (m.type == DIFFUSE) return true;
    if (m.type == GLOSSY) return !is_delta(m) && m.roughness >= PT_ROUGHNESS_MIN;
    if (m.type == OPENPBR) return pdf > 0.0f && pdf * pdf * PT_ROUGHNESS_MIN <= 1.0f;
    return false;
}

// Reconnection criteria for the pair (x_{k-1}, x_k), without divisions:
// the roughness guard at x_{k-1}, the ray footprint d^2 / (p_{k-1} |cos_k|) >= R and, when
// x_k's continuation is BSDF sampled and x_k is not Lambertian, the inverse ray footprint
// d^2 / (p_k |cos_{k-1}|) >= R (Eq. 5 and footnote 6). distance2 < 0 marks an environment x_k.
bool pt_connectable(Material previous, float previousPdf, float distance2, float cosEnd, float cosStart,
                    bool inverse, float endPdf, float threshold) {
    if (!(previousPdf > 0.0f) || !pt_rough(previous, previousPdf)) return false;
    if (distance2 < 0.0f) return true;
    if (!(cosEnd > 0.0f) || distance2 < threshold * previousPdf * cosEnd) return false;
    return !inverse || (endPdf > 0.0f && distance2 >= threshold * endPdf * cosStart);
}

// Unified DI + GI draws PT_NEE_CANDIDATES light samples at the primary hit and keeps one by
// RIS on the unshadowed contribution (RESTIRPTE2026 Sec. 6.1 and supplemental Sec. 5): the
// path keeps its single-sample PSS integrand with the M-sample MIS weight M p1 / (M p1 + p2)
// (here in power-heuristic form), and W_RIS p1 enters the candidate's contribution weight.
#define PT_NEE_CANDIDATES 4u
float pt_nee_candidates(uint pathVertex, constant Uniforms &u) {
    return restir_pt_unified(u) && pathVertex == 1u ? float(PT_NEE_CANDIDATES) : 1.0f;
}

// One vertex's BSDF, prepared once for its NEE evaluations and its continuation sample
// (sample_bsdf and eval_bsdf_with_pdf prepare the layered OpenPBR BSDF on every call). The
// results equal those functions': both prepare with the resolved Material's inside flag.
struct PTBsdf { Material mat; float3 normal; float3 wo; bool layered; PreparedBsdf prepared; };
PTBsdf pt_prepare(Material m, float3 n, float3 wo, thread const Wavelengths &wl) {
    PTBsdf b;
    b.mat = m; b.normal = n; b.wo = wo;
    b.layered = m.type != DIFFUSE && m.type != EMISSIVE && !is_delta(m);
    if (b.layered) b.prepared = prepare_bsdf(m, n, wo, wl);
    return b;
}
Spectrum pt_eval(thread const PTBsdf &b, float3 wi, thread float &pdf, thread const Wavelengths &wl) {
    if (!b.layered) return eval_bsdf_with_pdf(b.mat, b.normal, b.wo, wi, pdf, wl);
    pdf = 0.0f;
    float cosine = abs(dot(b.normal, wi));
    if (cosine < 1e-7f || dot(b.normal, b.wo) <= 0.0f) return Spectrum(0.0f);
    pdf = prepared_pdf(b.prepared, wi);
    float3 g = b.mat.geometricNormal;
    if (b.mat.transmission == 0.0f && dot(g, g) > 0.5f && dot(wi, g) <= 0.0f) return Spectrum(0.0f);
    return prepared_eval(b.prepared, wi) / cosine;
}
template <typename R>
bool pt_sample(thread const PTBsdf &b, float3 incoming, bool frontFace, thread R &seed,
               thread float3 &direction, thread Spectrum &weight, thread float &pdf, thread const Wavelengths &wl) {
    if (!b.layered) return sample_bsdf(b.mat, b.normal, incoming, frontFace, seed, direction, weight, pdf, wl);
    float3 random = rand_f3(seed);
    prepared_sample(b.prepared, random, direction, weight, pdf);
    if (pdf <= 0.0f) return false;
    float3 g = b.mat.geometricNormal;
    if (b.mat.transmission == 0.0f && dot(g, g) > 0.5f && dot(direction, g) <= 0.0f) return false;
    return all(isfinite(weight)) && all(weight >= 0.0f);
}

// Resampling MIS weights of GRIS reuse. Arguments are target values of one path y in two
// domains, each multiplied by the same shift Jacobian (so shifted values are used as stored).
// Generalized Talbot with confidences (RESTIRPT2022 Eq. 36): the share of the domain whose
// value is `own` among two domains.
float pt_talbot(float own, float ownConfidence, float other, float otherConfidence) {
    float a = ownConfidence * own;
    return a > 0.0f ? a / (a + otherConfidence * other) : 0.0f;
}
// Defensive pairwise MIS with confidences (RESTIRPT2022 Eq. 38, weighted as its real-time
// prototype does): for n neighbours, neighbour j's weight is b_j / (n + 1) and the canonical
// weight is (1 + sum_j (1 - b_j)) / (n + 1), with b_j = c_j p_j / (c_j p_j + (c_c / n) p_c),
// where p_j is y's value in neighbour j's domain and p_c its value in the canonical domain.
float pt_pairwise(float neighbor, float neighborConfidence, float canonical, float canonicalConfidence, float count) {
    float a = neighborConfidence * neighbor;
    return a > 0.0f ? a / (a + canonicalConfidence * canonical / count) : 0.0f;
}

// Streaming RIS over the candidates of the initial path tree: each candidate (x-bar, technique)
// is the only one covering its domain, so its resampling weight is p-hat / p(u), with the
// PSS source density p(u) = product of roulette survival probabilities (RESTIRPTE2026 Sec. 6.2.4)
// and, for RIS light sampling, W_RIS p1. Returns whether the candidate replaces the selection.
// `estimate` sums F / p(u) over the same candidates: the path tree's own (unresampled) estimate
// of the pixel, ReSTCV's initial colour estimate <F_i>_init (RESTCV2026 Sec. 5.1.1).
bool pt_accept(thread float &weightSum, thread uint &risSeed, float3 F, float sourceWeight, thread float3 &estimate) {
    float w = pt_luminance(F) * sourceWeight;
    if (!(w > 0.0f) || !isfinite(w)) return false;
    weightSum += w;
    estimate += F * sourceWeight;
    return rand_f(risSeed) * weightSum < w;
}

// Initial path tree at the primary hit x1 (RESTIRPT2022 Sec. 8; the same sampling decisions,
// scattering budget and MIS weights as shading_kernel's path loop). Candidates are NEE and
// BSDF-sampled emitter paths of at least three vertices (two with unified DI + GI).
// Each records its reconnection vertex: the first x_k (k >= 2) whose pair passes
// pt_connectable, a forced NEE light vertex (RESTIRPTE2026 Sec. 6.2.3), or none (replay only).
PTReservoir pt_generate(HitRecord x1, float3 view, uint seed, float threshold, float coneSpread,
                        constant Uniforms &u, constant SurfaceSettings *settings,
                        constant MaterialResources &images, thread float &firstHitDistance, thread float3 &estimate,
                        thread const Wavelengths &context) {
    // Spectral: the path's wavelengths follow from its seed, so every shift re-derives them.
    Wavelengths wl = pt_wavelengths(seed, context);
    PTReservoir selected = pt_empty();
    float weightSum = 0.0f;
    estimate = float3(0.0f);
    uint risSeed = pt_seed(seed, 0u, 3u);
    const int limit = scattering_limit(u.cameraTarget.w);
    const uint minLength = restir_pt_unified(u) ? 2u : 3u;
    HitRecord current = x1;
    float3 incoming = view;
    Spectrum throughput = Spectrum(1.0f);   // roulette excluded (Sec. 6.2.4)
    float inverseSurvival = 1.0f;
    int scatter = 0;
    float pathDistance = x1.t;
    Material previous = x1.mat;
    float previousPdf = 0.0f;
    // x_{j-1}'s geometric normal and the traced length of x_{j-1} -> x_j. BSDF-sampled segments
    // start at the offset ray origin, so the sampled direction, the traced distance and the
    // shift's reconnection all describe the same segment.
    float3 previousGeometric = float3(0.0f);
    float previousDistance2 = 0.0f;
    // Reconnection vertex of the shared prefix (pairs whose x_k continuation is BSDF sampled).
    uint rcIndex = 0u; int rcScatter = 0;
    float3 rcPosition = float3(0.0f);
    Spectrum suffix = Spectrum(1.0f);
    float rcJacobian = 0.0f; uint rcDirection = 0u;
    uint rcDispersive = 0u;   // PT_RC_DISPERSIVE when the suffix passed a dispersive vertex
    firstHitDistance = 0.0f;
    for (uint j = 1u; j < PT_MAX_VERTICES; ++j) {
        bool delta = is_delta(current.mat);
#if VIBE_SPECTRAL
        // Hero wavelength at a dispersive x_j (before it scatters); a suffix keeps only that lane.
        if (spectral_dispersive(current.mat, wl)) {
            spectral_arrive(current.mat, throughput, wl);
            if (rcIndex != 0u) { suffix *= spectral_hero_lane(1.0f, wl); rcDispersive = PT_RC_DISPERSIVE; }
        }
#endif
        PTBsdf bsdf = pt_prepare(current.mat, current.normal, -incoming, wl);
        // Next-event estimation at x_j: a path of j + 1 vertices.
        if (!delta && j + 1u >= minLength) {
            Sampler neeSeed = pt_sampler(seed, j, 1u, u);
            float candidates = pt_nee_candidates(j, u), lightWeight = 1.0f;
            // Z mode: the RIS light candidates are one stratified block of the event.
            uint candidateBits = candidates > 1.0f ? 2u : 0u;
            sampler_candidate(neeSeed, j, Z_PT + 1u, 0u, candidateBits);
            LightSample ls = sample_direct_light(current.position, current.normal, u, neeSeed, images);
            if (candidates > 1.0f) {
                // RIS over light samples with target luminance(f cos Le); lightWeight = W_RIS p1.
                float sum = 0.0f, chosenTarget = 0.0f;
                for (uint i = 0u; i < PT_NEE_CANDIDATES; ++i) {
                    if (i > 0u) sampler_candidate(neeSeed, j, Z_PT + 1u, i, candidateBits);
                    LightSample candidate = i == 0u ? ls : sample_direct_light(current.position, current.normal, u, neeSeed, images);
                    float target = 0.0f;
                    if (candidate.pdf > 0.0f) {
                        float ignored;
                        Spectrum f = pt_eval(bsdf, candidate.wi, ignored, wl);
                        target = pt_luminance(spectrum_rgb(f * abs(dot(current.normal, candidate.wi)) * light_spectrum(candidate, wl), wl));
                    }
                    float w = target > 0.0f && isfinite(target) ? target / candidate.pdf : 0.0f;
                    sum += w;
                    if (w > 0.0f && rand_decision(neeSeed) * sum < w) { ls = candidate; chosenTarget = target; }
                }
                if (!(chosenTarget > 0.0f)) ls.pdf = 0.0f;
                else lightWeight = sum / candidates / chosenTarget * ls.pdf;
            }
            if (light_visible(current.position, current.geometricNormal, ls, u.sceneIndex, images, u, current.error)) {
                float bsdfPdf;
                Spectrum f = pt_eval(bsdf, ls.wi, bsdfPdf, wl);
                Spectrum emission = light_spectrum(ls, wl);
                Spectrum contribution = f * abs(dot(current.normal, ls.wi)) * emission / ls.pdf;
                float w = scatter < limit ? power_heuristic(candidates * ls.pdf, bsdfPdf) : 1.0f;
                // Reconnection: the prefix's vertex, x_j itself (its NEE direction and light stay
                // fixed), or else the NEE light vertex (forced; the shift then reuses the light
                // sampler's geometry and PDF, a ReSTIR DI shift, and keeps LightSample.isDirectional).
                bool atVertex = rcIndex == 0u && j >= 2u && pt_connectable(previous, previousPdf, previousDistance2,
                    abs(dot(current.geometricNormal, incoming)), abs(dot(previousGeometric, incoming)), false, 0.0f, threshold);
                float forcedJacobian = ls.pdf * light_geometry(current.position, ls, u.sceneIndex, u.light.w, images);
                bool valid = rcIndex != 0u || atVertex || forcedJacobian > 0.0f;
                float3 F = spectrum_rgb(throughput * contribution * w, wl);
                if (valid && any(contribution > 0.0f) && all(isfinite(contribution)) &&
                    pt_accept(weightSum, risSeed, F, inverseSurvival * lightWeight, estimate)) {
                    selected = pt_empty();
                    selected.F = F; selected.seed = seed;
                    if (rcIndex != 0u) {
                        selected.flags = pt_flags(j + 1u, rcIndex, true, false, rcScatter) | rcDispersive;
                        selected.rcPosition = rcPosition; selected.rcJacobian = rcJacobian; selected.rcDirection = rcDirection;
                        pt_set_rc_radiance(selected, suffix * contribution * w);
                    } else if (atVertex) {
                        selected.flags = pt_flags(j + 1u, j, true, false, scatter);
                        selected.rcPosition = current.position;
                        selected.rcJacobian = previousPdf * abs(dot(current.geometricNormal, incoming)) / previousDistance2;
                        selected.rcDirection = pt_encode_direction(ls.wi);
                        pt_set_rc_radiance(selected, emission / ls.pdf);
                        selected.lightPdf = ls.pdf;
                    } else {
                        bool directional = ls.isDirectional == 1u;
                        selected.flags = pt_flags(j + 1u, j + 1u, true, directional, scatter);
                        selected.rcPosition = directional ? ls.wi : ls.position;
                        selected.rcJacobian = forcedJacobian;
                        pt_set_rc_radiance(selected, emission);
                        selected.lightPdf = as_type<float>(ls.isDirectional);
                    }
                }
            }
        }
        // Roulette for the continuation (shading_kernel's policy), applied at initial
        // sampling only: replay never terminates a path by roulette.
        if (j >= 5u) {
            Spectrum compensated = throughput * inverseSurvival;
            float survival = clamp(spectrum_max(compensated), 0.05f, delta ? 0.99f : 0.95f);
            Sampler rouletteSeed = pt_sampler(seed, j, 2u, u);
            if (rand_f(rouletteSeed) >= survival) break;
            inverseSurvival /= survival;
        }
        if (!delta && scatter >= limit) break;
        if (!delta) ++scatter;
        Sampler bsdfSeed = pt_sampler(seed, j, 0u, u);
        float3 direction;
        Spectrum weight;
        float pdf;
        if (!pt_sample(bsdf, incoming, current.front_face, bsdfSeed, direction, weight, pdf, wl)) break;
        if (rcIndex == 0u && j >= 2u && !delta &&
            pt_connectable(previous, previousPdf, previousDistance2, abs(dot(current.geometricNormal, incoming)),
                           abs(dot(previousGeometric, incoming)), current.mat.type != DIFFUSE, pdf, threshold)) {
            rcIndex = j; rcScatter = scatter - 1;
            rcPosition = current.position;
            rcJacobian = previousPdf * abs(dot(current.geometricNormal, incoming)) / previousDistance2 * pdf;
            rcDirection = pt_encode_direction(direction);
            suffix = Spectrum(1.0f);
        } else if (rcIndex != 0u) {
            suffix *= weight;
        }
        throughput *= weight;
        if (!all(isfinite(throughput)) || spectrum_max(throughput) <= 0.0f) break;
        Ray next;
        next.origin = ray_origin(current.position, current.geometricNormal, direction, u, current.error);
        next.direction = direction;
        HitRecord hit;
        bool found = trace_scene(next, u.sceneIndex, hit, images, u);
        if (j == 1u) firstHitDistance = found ? hit.t : 10000.0f;
        if (found) {
            pathDistance += hit.t;
            if (!delta) coneSpread = max(coneSpread, current.mat.type == DIFFUSE ? 0.25f : current.mat.roughness * 0.15f);
            resolve_material(hit, next, u, settings, images, pathDistance * coneSpread);
        }
        // Emitter reached by the BSDF sample: a path of j + 1 vertices.
        if (j + 1u >= minLength) {
            Spectrum emitted = Spectrum(0.0f);
            float lightPdf = 0.0f;
            bool environment = !found;
            if (!found) {
                if (u.sceneIndex == 0 || u.sceneIndex == 6) {
                    emitted = environment_spectrum(direction, u, images, wl);
                    lightPdf = eval_environment_pdf(direction, current.normal, u, images);
                }
            } else if (hit.mat.type == EMISSIVE) {
                emitted = emitter_spectrum(hit.mat.emission, wl);
                lightPdf = eval_light_pdf(current.position, hit.position, hit.mat, u, images, hit.triangle);
            } else {
                emitted = emitter_spectrum(openpbr_emission(hit.mat, hit.normal, -direction), wl);
                if (u.sceneIndex == 6 && any(emitted > 0.0f))
                    lightPdf = eval_light_pdf(current.position, hit.position, hit.mat, u, images, hit.triangle);
            }
            float w = emission_weight(delta, !delta, true, pdf, lightPdf * pt_nee_candidates(j, u));
            float3 F = spectrum_rgb(throughput * emitted * w, wl);
            float distance2 = found ? hit.t * hit.t : -1.0f;
            float endCosine = found ? abs(dot(hit.geometricNormal, direction)) : 1.0f;
            // Reconnection: the prefix's vertex, this emitter (endpoint rule), or none (replay only).
            bool atEnd = rcIndex == 0u && !delta && pt_connectable(current.mat, pdf, distance2, endCosine,
                abs(dot(current.geometricNormal, direction)), false, 0.0f, threshold);
            float endJacobian = environment ? pdf : pdf * endCosine / distance2;
            if (any(emitted > 0.0f) && all(isfinite(emitted)) && (!atEnd || endJacobian > 0.0f) &&
                pt_accept(weightSum, risSeed, F, inverseSurvival, estimate)) {
                selected = pt_empty();
                selected.F = F; selected.seed = seed;
                if (rcIndex != 0u) {
                    selected.flags = pt_flags(j + 1u, rcIndex, false, false, rcScatter) | rcDispersive;
                    selected.rcPosition = rcPosition; selected.rcJacobian = rcJacobian; selected.rcDirection = rcDirection;
                    // k = d - 1 keeps L_k MIS-free: the weight depends on the direction into x_k.
                    pt_set_rc_radiance(selected, rcIndex == j ? emitted : suffix * emitted * w);
                    selected.lightPdf = lightPdf;
                } else if (atEnd) {
                    selected.flags = pt_flags(j + 1u, j + 1u, false, environment, scatter);
                    selected.rcPosition = environment ? direction : hit.position;
                    selected.rcJacobian = endJacobian;
                } else {
                    selected.flags = pt_flags(j + 1u, 0u, false, environment, scatter);
                }
            }
        }
        if (!found || hit.mat.type == EMISSIVE) break;
        previous = current.mat; previousPdf = pdf;
        previousGeometric = current.geometricNormal; previousDistance2 = hit.t * hit.t;
        current = hit; incoming = direction;
    }
    float target = pt_luminance(selected.F);
    if (target > 0.0f && weightSum > 0.0f) {
        selected.W = weightSum / target;
    } else {
        selected = pt_empty();
    }
    if (!all(isfinite(estimate))) estimate = float3(0.0f);
    selected.M = 1.0f;
    return selected;
}

// Hybrid shift (RESTIRPT2022 Sec. 7.4; RESTIRPTE2026 Sec. 2.3 and Eq. 2) of reservoir r's
// path into the pixel whose primary hit is y1 (seen along `view`): random replay of the
// base random numbers for y_2..y_{k-1}, reconnection y_{k-1} -> x_k, then the stored suffix.
// Returns the offset integrand times the PSS Jacobian, F(y) |dT/du|, and the offset path's own
// Jacobian denominator (its rcJacobian as a base path). A shift is undefined (zero) when it is
// not invertible: an earlier offset pair passes the criteria, the reconnection pair fails them,
// the scattering budget differs, a replayed or reconnection vertex is missing or occluded.
struct PTShift { float3 FJ; float jacobian; };

PTShift pt_shift(PTReservoir r, HitRecord y1, float3 view, float threshold, float coneSpread,
                 constant Uniforms &u, constant SurfaceSettings *settings, constant MaterialResources &images,
                 thread const Wavelengths &context) {
    PTShift result = { float3(0.0f), 0.0f };
    // The base path's wavelengths (from its seed), so the shift and its Jacobian are those of RGB.
    Wavelengths wl = pt_wavelengths(r.seed, context);
    uint d = pt_length(r), k = pt_rc_index(r);
    if (d < 2u || y1.mat.type == EMISSIVE) return result;
    bool nee = (r.flags & PT_NEE) != 0u, environment = (r.flags & PT_ENVIRONMENT) != 0u;
    if (k == 0u && nee) return result;
    const int limit = scattering_limit(u.cameraTarget.w);
    HitRecord current = y1;
    float3 incoming = view;
    Spectrum throughput = Spectrum(1.0f);
    int scatter = 0;
    float pathDistance = y1.t;
    Material previous = y1.mat;
    float previousPdf = 0.0f;
    float3 previousGeometric = float3(0.0f);
    float previousDistance2 = 0.0f;
    // Replay samples at y_1 .. y_{k-2} (reconnection) or y_1 .. y_{d-1} (replay only).
    uint steps = k > 0u ? k - 2u : d - 1u;
    for (uint j = 1u; j <= steps; ++j) {
        bool delta = is_delta(current.mat);
        if (!delta && scatter >= limit) return result;
        if (!delta) ++scatter;
        spectral_arrive(current.mat, throughput, wl);
        Sampler bsdfSeed = pt_sampler(r.seed, j, 0u, u);
        float3 direction;
        Spectrum weight;
        float pdf;
        if (!sample_bsdf(current.mat, current.normal, incoming, current.front_face, bsdfSeed, direction, weight, pdf, wl)) return result;
        if (j >= 2u && !delta &&
            pt_connectable(previous, previousPdf, previousDistance2, abs(dot(current.geometricNormal, incoming)),
                           abs(dot(previousGeometric, incoming)), current.mat.type != DIFFUSE, pdf, threshold)) return result;
        throughput *= weight;
        if (!all(isfinite(throughput)) || spectrum_max(throughput) <= 0.0f) return result;
        Ray next;
        next.origin = ray_origin(current.position, current.geometricNormal, direction, u, current.error);
        next.direction = direction;
        HitRecord hit;
        bool found = trace_scene(next, u.sceneIndex, hit, images, u);
        if (found) {
            pathDistance += hit.t;
            if (!delta) coneSpread = max(coneSpread, current.mat.type == DIFFUSE ? 0.25f : current.mat.roughness * 0.15f);
            resolve_material(hit, next, u, settings, images, pathDistance * coneSpread);
        }
        if (k == 0u && j == d - 1u) {
            // Replay-only path: the offset must reach an emitter itself.
            Spectrum emitted = Spectrum(0.0f);
            float lightPdf = 0.0f;
            if (!found) {
                if (u.sceneIndex == 0 || u.sceneIndex == 6) {
                    emitted = environment_spectrum(direction, u, images, wl);
                    lightPdf = eval_environment_pdf(direction, current.normal, u, images);
                }
            } else if (hit.mat.type == EMISSIVE) {
                emitted = emitter_spectrum(hit.mat.emission, wl);
                lightPdf = eval_light_pdf(current.position, hit.position, hit.mat, u, images, hit.triangle);
            } else {
                emitted = emitter_spectrum(openpbr_emission(hit.mat, hit.normal, -direction), wl);
                if (u.sceneIndex == 6 && any(emitted > 0.0f))
                    lightPdf = eval_light_pdf(current.position, hit.position, hit.mat, u, images, hit.triangle);
            }
            if (!any(emitted > 0.0f) || !all(isfinite(emitted))) return result;
            if (!delta && pt_connectable(current.mat, pdf, found ? hit.t * hit.t : -1.0f,
                    found ? abs(dot(hit.geometricNormal, direction)) : 1.0f,
                    abs(dot(current.geometricNormal, direction)), false, 0.0f, threshold)) return result;
            result.FJ = spectrum_rgb(throughput * emitted * emission_weight(delta, !delta, true, pdf, lightPdf * pt_nee_candidates(j, u)), wl);
            result.jacobian = r.rcJacobian;
            return result;
        }
        if (!found || hit.mat.type == EMISSIVE) return result;
        previous = current.mat; previousPdf = pdf;
        previousGeometric = current.geometricNormal; previousDistance2 = hit.t * hit.t;
        current = hit; incoming = direction;
    }
    if (k == 0u || !(r.rcJacobian > 0.0f)) return result;
    // Reconnection y_{k-1} -> x_k.
    if (is_delta(current.mat)) return result;
    spectral_arrive(current.mat, throughput, wl);
    bool bsdfSegment = !(nee && k == d);
    if (bsdfSegment) {
        if (scatter >= limit) return result;
        ++scatter;
    }
    // A BSDF-sampled segment leaves y_{k-1}'s offset ray origin, as in the base path; an NEE
    // segment is measured from the vertex itself, as sample_direct_light measures it.
    float3 direction;
    float distance2 = -1.0f;
    Ray link;
    if (environment) {
        direction = normalize(float3(r.rcPosition));
        link.origin = ray_origin(current.position, current.geometricNormal, direction, u, current.error);
    } else {
        float3 e = float3(r.rcPosition) - current.position;
        if (!(dot(e, e) > 0.0f)) return result;
        link.origin = ray_origin(current.position, current.geometricNormal, e, u, current.error);
        if (bsdfSegment) e = float3(r.rcPosition) - link.origin;
        distance2 = dot(e, e);
        if (!(distance2 > 0.0f)) return result;
        direction = e * rsqrt(distance2);
    }
    float startPdf;
    Spectrum startBSDF = eval_bsdf_with_pdf(current.mat, current.normal, -incoming, direction, startPdf, wl);
    Spectrum start = startBSDF * abs(dot(current.normal, direction));
    if (!any(start > 0.0f) || !(startPdf > 0.0f)) return result;
    // The pair ending at y_{k-1} must fail the criteria with the reconnection direction.
    if (k >= 3u) {
        if (pt_connectable(previous, previousPdf, previousDistance2, abs(dot(current.geometricNormal, incoming)),
                           abs(dot(previousGeometric, incoming)), bsdfSegment && current.mat.type != DIFFUSE, startPdf,
                           threshold)) return result;
    }
    if (nee && k == d) {
        // NEE light vertex: the light sampler's geometry, PDF and visibility test from y_{d-1}.
        LightSample ls;
        ls.isDirectional = as_type<uint>(r.lightPdf);
        ls.position = environment ? current.position + direction * 1e6f : float3(r.rcPosition);
        ls.wi = direction;
        ls.dist = environment ? 1e6f : sqrt(distance2);
        // L_k of a light vertex is its emission (at the path's wavelengths).
        Spectrum emission = pt_rc_radiance(r);
        ls.pdf = environment ? eval_environment_pdf(direction, current.normal, u, images)
            : eval_light_pdf(current.position, ls.position, current.mat, u, images, ls.isDirectional >= 2u ? ls.isDirectional - 2u : 0xffffffffu);
        float geometry = light_geometry(current.position, ls, u.sceneIndex, u.light.w, images);
        if (!(ls.pdf > 0.0f) || !(geometry > 0.0f) || !any(emission > 0.0f)) return result;
        if (!light_visible(current.position, current.geometricNormal, ls, u.sceneIndex, images, u, current.error)) return result;
        float w = scatter < limit ? power_heuristic(pt_nee_candidates(d - 1u, u) * ls.pdf, startPdf) : 1.0f;
        result.FJ = spectrum_rgb(throughput * start * emission * (w * geometry) / r.rcJacobian, wl);
        if (!all(isfinite(result.FJ))) { result.FJ = float3(0.0f); return result; }
        result.jacobian = ls.pdf * geometry;
        return result;
    }
    HitRecord hit;
    float geometry = 1.0f;
    if (environment) {
        link.direction = direction;
        if (trace_scene(link, u.sceneIndex, hit, images, u)) return result;
    } else {
        float3 e = float3(r.rcPosition) - link.origin;
        float expected = length(e);
        link.direction = e / expected;
        if (!trace_scene(link, u.sceneIndex, hit, images, u)) return result;
        float tolerance = 2.0f * endpoint_tolerance(link.origin, float3(r.rcPosition), expected, u) + 1e-4f * expected;
        if (abs(hit.t - expected) > tolerance) return result;
        geometry = abs(dot(hit.geometricNormal, direction)) / distance2;
        if (!(geometry > 0.0f)) return result;
        resolve_material(hit, link, u, settings, images,
            (pathDistance + hit.t) * max(coneSpread, current.mat.type == DIFFUSE ? 0.25f : current.mat.roughness * 0.15f));
    }
    Spectrum value;
    float jacobian;
    if (k == d) {
        // x_k is an emitter the BSDF sample at y_{d-1} reaches.
        Spectrum emitted;
        float lightPdf;
        if (environment) {
            emitted = environment_spectrum(direction, u, images, wl);
            lightPdf = eval_environment_pdf(direction, current.normal, u, images);
        } else {
            emitted = emitter_spectrum(hit.mat.type == EMISSIVE ? hit.mat.emission : openpbr_emission(hit.mat, hit.normal, -direction), wl);
            lightPdf = hit.mat.type == EMISSIVE || u.sceneIndex == 6
                ? eval_light_pdf(current.position, hit.position, hit.mat, u, images, hit.triangle) : 0.0f;
        }
        if (!any(emitted > 0.0f) || !all(isfinite(emitted))) return result;
        if (!pt_connectable(current.mat, startPdf, distance2, environment ? 1.0f : abs(dot(hit.geometricNormal, direction)),
                            abs(dot(current.geometricNormal, direction)), false, 0.0f, threshold)) return result;
        jacobian = startPdf * geometry;
        value = emitted * emission_weight(false, true, true, startPdf, lightPdf * pt_nee_candidates(d - 1u, u));
    } else {
        // x_k scatters towards the stored w_k; the suffix beyond it is L_k.
        if (hit.mat.type == EMISSIVE || is_delta(hit.mat)) return result;
        bool neeEnd = nee && k == d - 1u;
        float3 wk = pt_decode_direction(r.rcDirection);
        spectral_arrive(hit.mat, throughput, wl);
#if VIBE_SPECTRAL
        // L_k passed a dispersive vertex: it holds the hero lane only, and the path's factor of four
        // belongs to its first dispersive vertex, which this prefix has not reached.
        if ((r.flags & PT_RC_DISPERSIVE) != 0u && !wl.heroOnly) {
            wl.heroOnly = true;
            throughput *= spectral_hero_lane(4.0f, wl);
        }
#endif
        float endPdf;
        Spectrum endBSDF = eval_bsdf_with_pdf(hit.mat, hit.normal, -direction, wk, endPdf, wl);
        Spectrum end = endBSDF * abs(dot(hit.normal, wk));
        if (!any(end > 0.0f)) return result;
        if (!pt_connectable(current.mat, startPdf, distance2, abs(dot(hit.geometricNormal, direction)),
                            abs(dot(current.geometricNormal, direction)), !neeEnd && hit.mat.type != DIFFUSE, endPdf,
                            threshold)) return result;
        float w = 1.0f;
        if (neeEnd) {
            w = scatter < limit ? power_heuristic(r.lightPdf, endPdf) : 1.0f;
            jacobian = startPdf * geometry;
        } else {
            if (!(endPdf > 0.0f) || scatter >= limit) return result;
            ++scatter;
            if (k + 1u == d) w = emission_weight(false, true, true, endPdf, r.lightPdf);
            else if (scatter != int(pt_rc_scatter(r)) + 1) return result;
            jacobian = startPdf * geometry * endPdf;
        }
        value = end * pt_rc_radiance(r) * w;
    }
    result.FJ = spectrum_rgb(throughput * start * geometry * value / r.rcJacobian, wl);
    if (!all(isfinite(result.FJ))) { result.FJ = float3(0.0f); return result; }
    result.jacobian = jacobian;
    return result;
}

// Paired spatial reuse (RESTIRPTE2026 Sec. 3): PT_NEIGHBORS self-inverse pairing textures of
// sides 254, 230 and 210 (PathTracerRenderer.makePairingTextures), each flipped, transposed and
// offset per frame (Sec. 3.2). Pixel p's n-th partner q has p as its own n-th partner, so the
// shift of p's path to q, computed once by restir_pt_shift_kernel, serves both pixels.
constant int PT_PAIRING_SIDES[3] = { 254, 230, 210 };
constant int PT_PAIRING_OFFSETS[3] = { 0, 254 * 254, 254 * 254 + 230 * 230 };
int2 pt_partner(int2 p, uint n, constant Uniforms &u, const device char2 *pairing) {
    uint h = pcg_hash(u.sampleIndex * 2654435761u + n * 0x9e3779b9u + 0x632be5abu);
    int side = PT_PAIRING_SIDES[n];
    int2 q = (h & 4u) != 0u ? p.yx : p;
    if ((h & 1u) != 0u) q.x = -q.x;
    if ((h & 2u) != 0u) q.y = -q.y;
    int2 offset = int2(int((h >> 8) % uint(side)), int((h >> 20) % uint(side)));
    int2 t = ((q + offset) % side + side) % side;
    int2 delta = int2(pairing[PT_PAIRING_OFFSETS[n] + t.y * side + t.x]);
    if ((h & 1u) != 0u) delta.x = -delta.x;
    if ((h & 2u) != 0u) delta.y = -delta.y;
    if ((h & 4u) != 0u) delta = delta.yx;
    return p + delta;
}

// Symmetric G-buffer test for a pixel pair: both hold a scattering primary hit of the same
// material type, within 10% depth and 37 degrees of normal. It depends on the G-buffer only.
bool pt_pair_compatible(float4 a, float4 na, float4 b, float4 nb) {
    return a.w > 0.0f && b.w > 0.0f && na.w == nb.w && na.w != float(EMISSIVE) &&
        abs(a.w - b.w) <= 0.1f * max(a.w, b.w) && dot(na.xyz, nb.xyz) >= 0.8f;
}

bool pt_in_frame(int2 p, constant Uniforms &u) {
    return p.x >= 0 && p.y >= 0 && p.x < int(u.width) && p.y < int(u.height);
}

float pt_primary_cone(constant Uniforms &u) {
    return 2.0f * tan((u.cameraPos.w * 0.5f) * PI / 180.0f) / float(u.height);
}

// ReSTIR PT pass A: the initial path tree of every scattering primary hit (pt_generate).
// It also records the first BSDF segment length for the MetalFX specular hit-distance guide.
// With ReSTCV it stores the tree's initial colour estimate and rho_i (PTControl) and keeps the
// previous frame's final estimate in ptIndirect.xyz for temporal reuse.
kernel void restir_pt_initial_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::read_write> ptIndirect [[texture(5)]],
    constant Uniforms &u [[buffer(0)]],
    constant SurfaceSettings *settings [[buffer(1)]],
    constant MaterialResources &images [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    device PTReservoir *reservoirs [[buffer(5)]],
    device PTControl *controls [[buffer(24)]]
    SPECTRAL_BUFFERS,
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;
    uint index = gid.y * u.width + gid.x;
    float4 position = gbufferPosDepth.read(gid);
    float4 normalMaterial = gbufferNormalMat.read(gid);
    PTReservoir result = pt_empty();
    float firstHit = 0.0f;
    float3 estimate = float3(0.0f), reflectance = float3(0.0f);
    if (position.w > 0.0f && normalMaterial.w != float(EMISSIVE) ) {
        HitRecord x1 = load_primary_surface(primarySurfaces[index], position);
        float3 view = float3(primarySurfaces[index].view);
        uint seed = pt_initial_seed(gid, 0u, pcg_hash(index ^ (u.sampleIndex * 1999999973u) ^ 0x2545f491u), u);
        result = pt_generate(x1, view, seed, pt_footprint_threshold(position.w, x1.geometricNormal, view),
                             pt_primary_cone(u), u, settings, images, firstHit, estimate, SPECTRAL_CONTEXT(u, images));
        reflectance = pt_reflectance(x1.mat, x1.normal, -view);
    }
    reservoirs[index] = result;
    if (restir_pt_control_variates(u)) {
        PTControl control = { estimate, pt_encode_reflectance(reflectance) };
        controls[index] = control;
        ptIndirect.write(float4(ptIndirect.read(gid).xyz, firstHit), gid);
    } else {
        ptIndirect.write(float4(0.0f, 0.0f, 0.0f, firstHit), gid);
    }
}

// The temporal domain is the reprojected pixel when it shows the same surface (the ReSTIR DI
// test, with the distance bound widened to three pixel footprints at low resolutions). GRIS
// stays unbiased for any neighbour; the test only avoids shifts into unrelated domains.
// position / oldPosition hold (point, camera distance), normal / oldNormal (normal, material type).
bool pt_same_surface(float4 position, float4 normalMaterial, float3 view, float4 oldPosition, float4 oldNormal,
                     constant Uniforms &u) {
    float footprint = 3.0f * pt_primary_cone(u) * position.w / max(abs(dot(normalMaterial.xyz, view)), 0.25f);
    return oldPosition.w > 0.0f && oldNormal.w == normalMaterial.w &&
        dot(oldNormal.xyz, normalMaterial.xyz) > 0.95f &&
        distance(oldPosition.xyz, position.xyz) < max(max(0.01f, position.w * 0.01f), footprint);
}

// Generalized Talbot MIS with confidences (RESTIRPT2022 Eq. 36, Sec. 8.3) over the canonical
// reservoir c of domain x1 and the temporal reservoir t of domain y1 (depths are camera
// distances), each sample shifted into the other domain; the temporal confidence is capped at cap.
// `difference` receives ReSTCV's reservoir-based difference estimate <F_x1 - F_y1> (RESTCV2026
// Eq. 10 with these Talbot weights and alpha = 1): the same two samples, weights and shifts give
// the two-domain estimates of both pixels, and their difference is correlated to zero variance
// where the domains agree.
PTReservoir pt_temporal_merge(PTReservoir c, HitRecord x1, float3 view, float depth, PTReservoir t, HitRecord y1,
                              float3 oldView, float oldDepth, float cap, uint selectSeed, constant Uniforms &u,
                              constant SurfaceSettings *settings, constant MaterialResources &images,
                              thread float3 &difference, thread const Wavelengths &context) {
    float cone = pt_primary_cone(u);
    float cc = c.M, ct = min(t.M, cap);
    float pc = pt_luminance(c.F), pt = pt_luminance(t.F);
    PTShift toPrevious = { float3(0.0f), 0.0f }, toCurrent = { float3(0.0f), 0.0f };
    if (pc > 0.0f) toPrevious = pt_shift(c, y1, oldView, pt_footprint_threshold(oldDepth, y1.geometricNormal, oldView),
                                         cone, u, settings, images, context);
    if (pt > 0.0f && t.W > 0.0f) toCurrent = pt_shift(t, x1, view, pt_footprint_threshold(depth, x1.geometricNormal, view),
                                                      cone, u, settings, images, context);
    float pcPrevious = pt_luminance(toPrevious.FJ), ptCurrent = pt_luminance(toCurrent.FJ);
    float mc = pt_talbot(pc, cc, pcPrevious, ct), mt = pt_talbot(pt, ct, ptCurrent, cc);
    float wc = c.W > 0.0f ? mc * pc * c.W : 0.0f;
    float wt = mt * ptCurrent * t.W;
    float sum = wc + wt;
    // Eq. 10: m_c W_c (F_x1(x_c) - F_y1(T x_c) J) - m_t W_t (F_y1(x_t) - F_x1(T x_t) J).
    difference = mc * c.W * (float3(c.F) - toPrevious.FJ) - mt * t.W * (float3(t.F) - toCurrent.FJ);
    if (!all(isfinite(difference))) difference = float3(0.0f);
    PTReservoir chosen = c;
    float chosenTarget = pc;
    if (wt > 0.0f && rand_f(selectSeed) * sum < wt) {
        chosen = t;
        float jacobian = pt_rc_index(t) > 0u ? toCurrent.jacobian / t.rcJacobian : 1.0f;
        chosen.F = toCurrent.FJ / jacobian;
        if (pt_rc_index(t) > 0u) chosen.rcJacobian = toCurrent.jacobian;
        chosenTarget = pt_luminance(chosen.F);
    }
    float W = chosenTarget > 0.0f && sum > 0.0f ? sum / chosenTarget : 0.0f;
    if (!(W > 0.0f) || !isfinite(W)) chosen = pt_empty();
    else chosen.W = W;
    chosen.M = cc + ct;
    return chosen;
}

// ReSTCV temporal control variates (RESTCV2026 Eq. 6 and 7 with alpha = 1, as in the authors'
// code for this step): the initial estimate, weighted by the canonical confidence (q_init = 1),
// and the "from-previous" estimator <F>_prev + <F_x1 - F_y1>, weighted by the capped temporal
// confidence. The previous estimate belongs to the history domain y1, which the difference
// estimate shifts into, so the combination stays unbiased; the weights depend on geometry only.
void pt_cv_temporal(device PTControl &control, float canonicalConfidence, float temporalConfidence, float3 previous,
                    float3 difference) {
    float total = canonicalConfidence + temporalConfidence;
    if (!(total > 0.0f) || !all(isfinite(previous))) return;
    float3 estimate = (canonicalConfidence * float3(control.estimate) + temporalConfidence * (previous + difference)) / total;
    if (all(isfinite(estimate))) control.estimate = estimate;
}

// ReSTIR PT pass B: temporal reuse. The temporal neighbour's domain is the previous frame's
// primary hit (history G-buffer and PrimarySurface); generalized Talbot MIS with confidences
// (RESTIRPT2022 Eq. 36, Sec. 8.3) weighs the canonical and the temporal sample, each shifted
// into the other domain. c_Cap = 20, optionally reduced by the duplication map (RESTIRPTE2026 Sec. 5).
// With ReSTCV the pixel's estimate becomes the temporal control-variate combination (pt_cv_temporal).
kernel void restir_pt_temporal_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::read> historyPosDepth [[texture(2)]],
    texture2d<float, access::read> historyNormalMat [[texture(3)]],
    texture2d<float, access::read> duplication [[texture(4)]],
    texture2d<float, access::read> ptIndirect [[texture(5)]],
    constant Uniforms &u [[buffer(0)]],
    constant SurfaceSettings *settings [[buffer(1)]],
    constant MaterialResources &images [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    const device PrimarySurface *historySurfaces [[buffer(4)]],
    device PTReservoir *reservoirs [[buffer(5)]],
    const device PTReservoir *history [[buffer(6)]],
    device PTControl *controls [[buffer(24)]]
    SPECTRAL_BUFFERS,
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;
    if (u.reservoirHistory <= 1 || u.reservoirHistoryReset != 0 || !restir_pt_temporal(u)) return;
    uint index = gid.y * u.width + gid.x;
    float4 position = gbufferPosDepth.read(gid);
    float4 normalMaterial = gbufferNormalMat.read(gid);
    if (!(position.w > 0.0f) || normalMaterial.w == float(EMISSIVE)) return;
    float4 prevClip = u.prevViewProj * float4(position.xyz, 1.0f);
    if (!(prevClip.w > 0.0f)) return;
    float2 prevUV = prevClip.xy / prevClip.w * float2(0.5f, -0.5f) + 0.5f;
    int2 prevCoord = int2(prevUV * float2(float(u.width), float(u.height)));
    if (!all(prevUV >= 0.0f) || !all(prevUV < 1.0f) || !pt_in_frame(prevCoord, u)) return;
    float4 oldPosition = historyPosDepth.read(uint2(prevCoord));
    float4 oldNormal = historyNormalMat.read(uint2(prevCoord));
    bool sameSurface = pt_same_surface(position, normalMaterial, float3(primarySurfaces[index].view), oldPosition, oldNormal, u);
    uint prevIndex = uint(prevCoord.y) * u.width + uint(prevCoord.x);
    PTReservoir t = history[prevIndex];
    if (!sameSurface || !(t.M > 0.0f)) return;
    PTReservoir c = reservoirs[index];
    HitRecord x1 = load_primary_surface(primarySurfaces[index], position);
    float3 view = float3(primarySurfaces[index].view);
    HitRecord y1 = load_primary_surface(historySurfaces[prevIndex], oldPosition);
    float3 oldView = float3(historySurfaces[prevIndex].view);
    float cap = PT_CONFIDENCE_CAP;
    if (restir_pt_decorrelates(u)) {
        float score = saturate(duplication.read(uint2(prevCoord)).x);
        cap = mix(PT_CONFIDENCE_CAP, PT_CONFIDENCE_MIN, pow(score, PT_DUPLICATION_EXPONENT));
    }
    uint selectSeed = pcg_hash(index ^ (u.sampleIndex * 1999999973u) ^ 0x1b873593u);
    float3 difference;
    reservoirs[index] = pt_temporal_merge(c, x1, view, position.w, t, y1, oldView, oldPosition.w, cap, selectSeed,
                                          u, settings, images, difference, SPECTRAL_CONTEXT(u, images));
    if (restir_pt_control_variates(u))
        pt_cv_temporal(controls[index], c.M, min(t.M, cap), ptIndirect.read(uint2(prevCoord)).xyz, difference);
}

// ReSTIR PT pass B: each pixel shifts its path to its PT_NEIGHBORS paired partners once.
// The partner's primary hit is its PrimarySurface and G-buffer position, seen along its own
// camera ray. Output: F(T x) |dT/du| and the shifted path's Jacobian denominator.
kernel void restir_pt_shift_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    constant Uniforms &u [[buffer(0)]],
    constant SurfaceSettings *settings [[buffer(1)]],
    constant MaterialResources &images [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    const device PTReservoir *reservoirs [[buffer(5)]],
    device float4 *shifts [[buffer(7)]],
    const device char2 *pairing [[buffer(8)]]
    SPECTRAL_BUFFERS,
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;
    uint index = gid.y * u.width + gid.x;
    float4 position = gbufferPosDepth.read(gid);
    float4 normalMaterial = gbufferNormalMat.read(gid);
    PTReservoir r = reservoirs[index];
    bool hasPath = pt_length(r) > 0u && pt_luminance(r.F) > 0.0f;
    float cone = pt_primary_cone(u);
    for (uint n = 0u; n < PT_NEIGHBORS; ++n) {
        float4 value = float4(0.0f);
        int2 q = pt_partner(int2(gid), n, u, pairing);
        if (hasPath && pt_in_frame(q, u)) {
            float4 qPosition = gbufferPosDepth.read(uint2(q));
            float4 qNormal = gbufferNormalMat.read(uint2(q));
            if (pt_pair_compatible(position, normalMaterial, qPosition, qNormal)) {
                uint qIndex = uint(q.y) * u.width + uint(q.x);
                HitRecord y1 = load_primary_surface(primarySurfaces[qIndex], qPosition);
                float3 view = float3(primarySurfaces[qIndex].view);
                PTShift s = pt_shift(r, y1, view, pt_footprint_threshold(qPosition.w, y1.geometricNormal, view),
                                     cone, u, settings, images, SPECTRAL_CONTEXT(u, images));
                value = float4(s.FJ, s.jacobian);
            }
        }
        shifts[index * PT_NEIGHBORS + n] = value;
    }
}

// ReSTIR PT pass C: spatial GRIS over the canonical reservoir and its paired partners with
// defensive pairwise MIS and confidence weights (RESTIRPT2022 Eq. 38, as its real-time
// prototype weighs it), shading with the vector-valued resampling weights (RESTIRPTE2026
// Sec. 6.3). The selected path becomes the next frame's temporal history. The current
// PrimarySurface is copied to the history buffer here, after pass A read the old one.
// With ReSTCV (RESTCV2026 Sec. 5.3) the pixel is shaded with its spatial control-variate estimate
// instead, which also becomes the next frame's history estimate; the reservoirs are unchanged.
kernel void restir_pt_spatial_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::read_write> ptIndirect [[texture(5)]],
    constant Uniforms &u [[buffer(0)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    device PrimarySurface *historySurfaces [[buffer(4)]],
    const device PTReservoir *reservoirs [[buffer(5)]],
    device PTReservoir *output [[buffer(6)]],
    const device float4 *shifts [[buffer(7)]],
    const device char2 *pairing [[buffer(8)]],
    const device PTControl *controls [[buffer(24)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;
    uint index = gid.y * u.width + gid.x;
    historySurfaces[index] = primarySurfaces[index];
    float4 position = gbufferPosDepth.read(gid);
    float4 normalMaterial = gbufferNormalMat.read(gid);
    float firstHit = ptIndirect.read(gid).w;
    PTReservoir c = reservoirs[index];
    if (!(position.w > 0.0f) || normalMaterial.w == float(EMISSIVE) || !(c.M > 0.0f)) {
        output[index] = pt_empty();
        ptIndirect.write(float4(0.0f, 0.0f, 0.0f, firstHit), gid);
        return;
    }
    uint partner[PT_NEIGHBORS];
    bool valid[PT_NEIGHBORS];
    float count = 0.0f;
    for (uint n = 0u; n < PT_NEIGHBORS; ++n) {
        int2 q = pt_partner(int2(gid), n, u, pairing);
        valid[n] = false; partner[n] = 0u;
        if (!pt_in_frame(q, u)) continue;
        partner[n] = uint(q.y) * u.width + uint(q.x);
        valid[n] = pt_pair_compatible(position, normalMaterial, gbufferPosDepth.read(uint2(q)), gbufferNormalMat.read(uint2(q)))
            && reservoirs[partner[n]].M > 0.0f;
        if (valid[n]) count += 1.0f;
    }
    uint seed = pcg_hash(index ^ (u.sampleIndex * 1999999973u) ^ 0x61c88647u);
    float pc = pt_luminance(c.F);
    float canonical = 1.0f, weightSum = 0.0f, confidence = c.M;
    float3 color = float3(0.0f);
    PTReservoir chosen = c;
    float chosenTarget = pc;
    // ReSTCV spatial control variates (Eq. 8): the pixel's own estimate, weighted PT_CV_CENTER_WEIGHT,
    // and one "from-q" estimator per valid partner, weighted one. The paper composites by confidence
    // M_q; equal weights, as in the authors' ReSTIR PT code, measured lower error here, mostly where
    // a disoccluded pixel's partners have long histories (REFERENCES.md: RESTCV2026).
    const bool controlVariates = restir_pt_control_variates(u);
    float3 cvSum = float3(0.0f), rhoC = float3(1.0f);
    float cvWeight = 0.0f;
    if (controlVariates) {
        PTControl own = controls[index];
        cvWeight = PT_CV_CENTER_WEIGHT;
        cvSum = cvWeight * float3(own.estimate);
        rhoC = pt_decode_reflectance(own.reflectance);
    }
    for (uint n = 0u; n < PT_NEIGHBORS; ++n) {
        if (!valid[n]) continue;
        PTReservoir q = reservoirs[partner[n]];
        confidence += q.M;
        // Canonical sample shifted to q: p-hat_q(T x_c) |dT/dx_c|.
        float3 toPartnerF = shifts[index * PT_NEIGHBORS + n].xyz;
        float toPartner = pt_luminance(toPartnerF);
        float canonicalShare = 1.0f - pt_pairwise(toPartner, q.M, pc, c.M, count);
        canonical += canonicalShare;
        // q's sample shifted here: F(T x_q) |dT/dx_q| and its own Jacobian denominator.
        float4 fromPartner = shifts[partner[n] * PT_NEIGHBORS + n];
        float pq = pt_luminance(q.F), pqc = pt_luminance(fromPartner.xyz);
        if (controlVariates) {
            // <F_c>_<-q = <F_c>_pair + alpha (<F_q> - <F_q>_pair) (Eqs. 7 and 10): the pair (c, q)'s
            // pairwise weights and shifts estimate both pixels from the same two samples.
            float mq = pq > 0.0f && q.W > 0.0f ? pt_pairwise(pq, q.M, pqc, c.M, count) : 0.0f;
            float3 ownPair = mq * q.W * fromPartner.xyz + canonicalShare * c.W * float3(c.F);
            float3 partnerPair = mq * q.W * float3(q.F) + canonicalShare * c.W * toPartnerF;
            PTControl other = controls[partner[n]];
            float3 fromQ = ownPair + pt_cv_alpha(rhoC, pt_decode_reflectance(other.reflectance)) *
                (float3(other.estimate) - partnerPair);
            if (all(isfinite(fromQ))) { cvSum += fromQ; cvWeight += 1.0f; }
        }
        if (pq > 0.0f && pqc > 0.0f && q.W > 0.0f) {
            float m = pt_pairwise(pq, q.M, pqc, c.M, count);
            float w = m * pqc * q.W;
            color += m * fromPartner.xyz * q.W;
            weightSum += w;
            if (rand_f(seed) * weightSum < w) {
                chosen = q;
                float jacobian = pt_rc_index(q) > 0u ? fromPartner.w / q.rcJacobian : 1.0f;
                chosen.F = fromPartner.xyz / jacobian;
                if (pt_rc_index(q) > 0u) chosen.rcJacobian = fromPartner.w;
                chosenTarget = pt_luminance(chosen.F);
            }
        }
    }
    if (pc > 0.0f && c.W > 0.0f) {
        float w = canonical * pc * c.W;
        color += canonical * float3(c.F) * c.W;
        weightSum += w;
        if (rand_f(seed) * weightSum < w) { chosen = c; chosenTarget = pc; }
    }
    float share = 1.0f / (count + 1.0f);
    color *= share;
    weightSum *= share;
    float W = chosenTarget > 0.0f && weightSum > 0.0f ? weightSum / chosenTarget : 0.0f;
    if (!(W > 0.0f) || !isfinite(W)) chosen = pt_empty();
    else chosen.W = W;
    chosen.M = confidence;
    output[index] = chosen;
    if (controlVariates) {
        // Unclamped: a control-variate estimate may be negative, and clamping would bias it.
        color = cvWeight > 0.0f ? cvSum / cvWeight : float3(0.0f);
        ptIndirect.write(float4(all(isfinite(color)) ? color : float3(0.0f), firstHit), gid);
        return;
    }
    if (!all(isfinite(color))) color = float3(0.0f);
    // Spectral transport keeps out-of-gamut (negative) colour: clamping it per frame would bias the
    // accumulation (shading_kernel accumulates it unclamped and clamps only the MetalFX input).
    ptIndirect.write(float4(SPECTRAL_KEEPS_NEGATIVE ? color : max(color, 0.0f), firstHit), gid);
}

// ============================================================================
// Stochastic pairwise MIS (REFERENCES.md: SPMIS2026; Uniforms.spatialNeighbors == 3)
// Spatial reuse of ReSTIR DI, GI and PT from one screen-space reuse cell of up to 64 pixels.
// Each pixel estimates the defensive pairwise MIS weights over every pixel of the cell (M
// candidates) from Ñ neighbours drawn in proportion to c_i p-hat(X_i) W_i (Eqs. 15-17) and Ñc
// uniform canonical shifts (Eqs. 18-19), with the non-canonical confidences scaled by Ñ / M
// (Sec. 4.3). The weights are unbiased estimates of the deterministic ones (Appendix B), so the
// reuse keeps GRIS unbiased whatever the neighbours' contributions.
// ============================================================================

// Cells: 8 x 8 tiles split by material type, material slot (the paper's object ID) and the
// normal quantized to floor(2n) per component (Sec. 5). Reservoir type 0 is ReSTIR DI, type 1
// ReSTIR GI (IndirectReuse.restirGI) or the ReSTIR PT path reservoir.
#define SPMIS_TILE 8u
#define SPMIS_CANDIDATES 3u      // Ñ for ReSTIR DI and GI (the paper's Ñ = 3)
#define SPMIS_PT_CANDIDATES 3u   // Ñ for ReSTIR PT
#define SPMIS_SEARCH 12u         // cell-search taps (Sec. 5.1)
#define SPMIS_RADIUS (1.0f / 120.0f) // first tap radius as a fraction of the image height (at least
                                  // one pixel), grown by SPMIS_GROWTH per tap
#define SPMIS_GROWTH 1.25f
constant uint SPMIS_START_MASK = (1u << 25) - 1u;

// Per pixel: its cell (first slot of the cell in `slots`, bits 0-24; pixel count, bits 25-31;
// 0 when the pixel has no reuse domain), its cell key and the cell's confidence sums per
// reservoir type (Algorithm 1, cellConfidenceSums).
struct SPMISPixel { uint cell; uint key; float confidence[2]; };
// Per slot (64 per tile, grouped by cell): the pixel index and, per reservoir type, the
// running sum of c_i p-hat(X_i) W_i within the cell (Eq. 17), for inverse-CDF selection.
struct SPMISSlot { uint pixel; float cdf[2]; };
// Per pixel: the reuse cell chosen for each reservoir type (spmis_select_kernel), as the cell
// word of its SPMISPixel and that type's confidence sum.
struct SPMISChoice { uint cell[2]; float confidence[2]; };
static_assert(sizeof(SPMISPixel) == 16 && sizeof(SPMISSlot) == 12 && sizeof(SPMISChoice) == 16,
              "Swift allocates 16 + 12 + 16 bytes per pixel");

uint spmis_count(SPMISPixel c) { return c.cell >> 25; }
uint spmis_start(SPMISPixel c) { return c.cell & SPMIS_START_MASK; }

// Key: material type (bits 0-3), quantized normal (2 bits per component, bits 4-9), slot (10-25).
uint spmis_key(float4 normalMaterial, uint slot) {
    int3 q = clamp(int3(floor(normalMaterial.xyz * 2.0f)), int3(-2), int3(1)) + 2;
    return (uint(normalMaterial.w) & 15u) | (uint(q.x) << 4) | (uint(q.y) << 6) | (uint(q.z) << 8) | ((slot & 65535u) << 10);
}
// A candidate cell of the search must have the centre's material type and slot and a normal
// within one quantization step per component (the paper's clamp of the attributes to +-1).
bool spmis_similar(uint a, uint b) {
    if ((a & ~0x3f0u) != (b & ~0x3f0u)) return false;
    for (uint c = 0u; c < 3u; ++c) {
        if (abs(int((a >> (4u + 2u * c)) & 3u) - int((b >> (4u + 2u * c)) & 3u)) > 1) return false;
    }
    return true;
}

// Algorithm 1 (CreateReuseCells), one threadgroup per 8 x 8 tile: every pixel with a reuse
// domain (a scattering primary hit) joins the cell of its key; the tile's slots list the cells'
// pixels contiguously, with in-cell prefix sums of c_i p-hat(X_i) W_i per reservoir type. The
// paper builds the same per-cell lists with GPU hash multimaps and sorting; a tile holds at most
// 64 pixels, so threadgroup memory replaces them.
kernel void spmis_cells_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::read> diWeights [[texture(2)]],
    texture2d<float, access::read> giWeights [[texture(3)]],
    constant Uniforms &u [[buffer(0)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    const device PTReservoir *ptReservoirs [[buffer(5)]],
    device SPMISPixel *cells [[buffer(9)]],
    device SPMISSlot *slots [[buffer(10)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tile [[threadgroup_position_in_grid]],
    uint2 tiles [[threadgroups_per_grid]],
    uint lane [[thread_index_in_threadgroup]])
{
    threadgroup uint keys[SPMIS_TILE * SPMIS_TILE];
    threadgroup uint leaders[SPMIS_TILE * SPMIS_TILE];
    threadgroup float2 confidences[SPMIS_TILE * SPMIS_TILE];
    threadgroup float2 importances[SPMIS_TILE * SPMIS_TILE];
    const uint none = 0xffffffffu;
    bool inside = gid.x < u.width && gid.y < u.height;
    uint index = gid.y * u.width + gid.x;
    uint key = none;
    float2 confidence = float2(0.0f), importance = float2(0.0f);
    if (inside) {
        float4 position = gbufferPosDepth.read(gid);
        float4 normalMaterial = gbufferNormalMat.read(gid);
        if (position.w > 0.0f && normalMaterial.w != float(EMISSIVE)) {
            key = spmis_key(normalMaterial, primarySurfaces[index].flags >> 16);
            // DI and GI weights hold (weight sum, M, W): c p-hat(X) W is the weight sum when W > 0.
            if (normalMaterial.w == float(DIFFUSE) && restir_di_active(u)) {
                float4 w = diWeights.read(gid);
                confidence.x = max(w.y, 0.0f);
                importance.x = w.z > 0.0f && w.y > 0.0f ? max(w.x, 0.0f) : 0.0f;
            }
            if (normalMaterial.w == float(DIFFUSE) && restir_gi_active(u)) {
                float4 w = giWeights.read(gid);
                confidence.y = max(w.y, 0.0f);
                importance.y = w.z > 0.0f && w.y > 0.0f ? max(w.x, 0.0f) : 0.0f;
            }
            if (restir_pt_active(u)) {
                PTReservoir r = ptReservoirs[index];
                confidence.y = max(r.M, 0.0f);
                float i = r.M * pt_luminance(r.F) * r.W;
                importance.y = i > 0.0f && isfinite(i) ? i : 0.0f;
            }
        }
    }
    keys[lane] = key;
    confidences[lane] = confidence;
    importances[lane] = importance;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint leader = lane, rank = 0u, count = 0u;
    float2 sum = float2(0.0f), prefix = float2(0.0f);
    if (key != none) {
        for (uint j = 0u; j < SPMIS_TILE * SPMIS_TILE; ++j) {
            if (keys[j] != key) continue;
            if (count == 0u) leader = j;
            ++count;
            sum += confidences[j];
            if (j < lane) ++rank;
            if (j <= lane) prefix += importances[j];
        }
    }
    leaders[lane] = leader;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (!inside) return;
    SPMISPixel cell;
    cell.cell = 0u; cell.key = key; cell.confidence[0] = sum.x; cell.confidence[1] = sum.y;
    if (key != none) {
        // Cells are ordered by their first pixel in the tile.
        uint start = 0u;
        for (uint j = 0u; j < SPMIS_TILE * SPMIS_TILE; ++j) {
            if (keys[j] != none && leaders[j] < leader) ++start;
        }
        uint first = (tile.y * tiles.x + tile.x) * SPMIS_TILE * SPMIS_TILE + start;
        cell.cell = first | (count << 25);
        SPMISSlot s;
        s.pixel = index; s.cdf[0] = prefix.x; s.cdf[1] = prefix.y;
        slots[first + rank] = s;
    }
    cells[index] = cell;
}

// Sec. 5.1: weighted reservoir sampling of one cell, by its confidence sum, among the centre's
// own cell and the cells of SPMIS_SEARCH uniform disk taps whose radius grows by 25% per tap.
// Only G-buffer keys and confidences decide, never the samples.
SPMISPixel spmis_find_cell(uint2 gid, SPMISPixel center, uint type, const device SPMISPixel *cells,
                           constant Uniforms &u, thread uint &seed) {
    SPMISPixel selected = center;
    float sum = center.confidence[type];
    float radius = max(1.0f, float(u.height) * SPMIS_RADIUS);
    for (uint i = 0u; i < SPMIS_SEARCH; ++i, radius *= SPMIS_GROWTH) {
        int2 q = int2(gid) + int2(floor(concentric_disk(rand_f2(seed)) * radius + 0.5f));
        q = clamp(q, int2(0), int2(int(u.width) - 1, int(u.height) - 1));
        SPMISPixel c = cells[uint(q.y) * u.width + uint(q.x)];
        if (spmis_count(c) == 0u || c.cell == center.cell || !spmis_similar(center.key, c.key)) continue;
        float w = c.confidence[type];
        if (!(w > 0.0f)) continue;
        sum += w;
        if (rand_f(seed) * sum < w) selected = c;
    }
    return selected;
}

// The cell search runs in its own light pass (its 12 dependent random reads per reservoir type
// cost 20-40% of the frame inside shading_kernel). Each pixel with a reuse domain chooses one
// cell per reservoir type it holds; the cell of a type without reservoirs is its own.
kernel void spmis_select_kernel(
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    constant Uniforms &u [[buffer(0)]],
    const device SPMISPixel *cells [[buffer(9)]],
    device SPMISChoice *choices [[buffer(11)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;
    uint index = gid.y * u.width + gid.x;
    SPMISPixel own = cells[index];
    SPMISChoice choice;
    choice.cell[0] = own.cell; choice.cell[1] = own.cell;
    choice.confidence[0] = own.confidence[0]; choice.confidence[1] = own.confidence[1];
    if (spmis_count(own) > 0u) {
        bool diffuse = gbufferNormalMat.read(gid).w == float(DIFFUSE);
        uint seed = pcg_hash(index ^ (u.sampleIndex * 1999999973u) ^ 0x7feb352du);
        for (uint type = 0u; type < 2u; ++type) {
            bool holds = type == 0u ? diffuse && restir_di_active(u) : restir_pt_active(u) || (diffuse && restir_gi_active(u));
            if (!holds) continue;
            SPMISPixel c = spmis_find_cell(gid, own, type, cells, u, seed);
            choice.cell[type] = c.cell;
            choice.confidence[type] = c.confidence[type];
        }
    }
    choices[index] = choice;
}
SPMISPixel spmis_chosen(SPMISChoice c, uint type) {
    SPMISPixel p;
    p.cell = c.cell[type]; p.key = 0u; p.confidence[0] = c.confidence[type]; p.confidence[1] = c.confidence[type];
    return p;
}

// Draws a pixel of the cell in proportion to c_i p-hat(X_i) W_i (Eq. 17) by inverse-CDF search
// of the in-cell prefix sums; probability is the exact selection probability. False when no
// pixel of the cell holds a contributing sample.
bool spmis_draw(const device SPMISSlot *slots, SPMISPixel cell, uint type, float xi,
                thread uint &pixel, thread float &probability) {
    uint start = spmis_start(cell), count = spmis_count(cell);
    if (count == 0u) return false;
    float total = slots[start + count - 1u].cdf[type];
    if (!(total > 0.0f) || !isfinite(total)) return false;
    float x = xi * total;
    uint lo = 0u, hi = count - 1u;
    while (lo < hi) {
        uint mid = (lo + hi) / 2u;
        if (slots[start + mid].cdf[type] > x) hi = mid; else lo = mid + 1u;
    }
    float below = lo > 0u ? slots[start + lo - 1u].cdf[type] : 0.0f;
    probability = (slots[start + lo].cdf[type] - below) / total;
    pixel = slots[start + lo].pixel;
    return probability > 0.0f;
}
// A uniformly chosen pixel of the cell (the canonical estimate's P_c = 1/M, Sec. 4.2).
uint spmis_uniform_pixel(const device SPMISSlot *slots, SPMISPixel cell, float xi) {
    uint count = spmis_count(cell);
    return slots[spmis_start(cell) + min(uint(xi * float(count)), count - 1u)].pixel;
}

// Defensive pairwise MIS (Eq. 11; WKL*23 Eq. 7.8) with confidence sum cS of the non-canonical
// candidates and canonical confidence cc. `from` is y's Jacobian-corrected target from domain i,
// `canonical` its target in the canonical domain. Neighbour weight, Eq. 11a / 16 (before the
// K / (Ñ P) factor):
float spmis_neighbor_weight(float ci, float cS, float cc, float from, float canonical) {
    float d = cS * from + cc * canonical;
    return d > 0.0f ? (cS / (cS + cc)) * (ci * from / d) : 0.0f;
}
// One term beta_i of the canonical weight's sum, Eq. 19.
float spmis_canonical_beta(float ci, float cS, float cc, float from, float canonical) {
    float d = cS * from + cc * canonical;
    return d > 0.0f ? (ci / (cS + cc)) * (cc * canonical / d) : 0.0f;
}
// The canonical weight's defensive term cc / (cS + cc), Eq. 18.
float spmis_canonical_share(float cS, float cc) { return cS + cc > 0.0f ? cc / (cS + cc) : 1.0f; }

// ReSTIR PT spatial reuse by stochastic pairwise MIS (Algorithm 2), replacing the paired shift
// and resampling passes (restir_pt_shift_kernel, restir_pt_spatial_kernel) when
// Uniforms.spatialNeighbors == 3. As there, the shifts run in their own pass, here one per
// thread (grid depth 1 + SPMIS_PT_CANDIDATES): shift 0 moves the canonical path into one
// uniform pixel of the chosen cell, for the canonical weight (Eq. 18, Ñc = 1); shifts 1..Ñ move
// importance-drawn neighbour paths into this pixel (Eq. 16). Shifts into or from this pixel
// itself are identities. Each record keeps F(T x) |dT/dx|, the shifted path's Jacobian
// denominator, the other pixel and its selection probability.
struct SPMISShift { packed_float3 FJ; float jacobian; uint pixel; float probability; };
static_assert(sizeof(SPMISShift) == 24, "Swift allocates 24-byte stochastic pairwise MIS shift records");
constant uint SPMIS_NO_PIXEL = 0xffffffffu;

kernel void restir_pt_spmis_shift_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    constant Uniforms &u [[buffer(0)]],
    constant SurfaceSettings *settings [[buffer(1)]],
    constant MaterialResources &images [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    const device PTReservoir *reservoirs [[buffer(5)]],
    device SPMISShift *shifts [[buffer(7)]],
    const device SPMISPixel *cells [[buffer(9)]],
    const device SPMISSlot *slots [[buffer(10)]],
    const device SPMISChoice *choices [[buffer(11)]]
    SPECTRAL_BUFFERS,
    uint3 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height || gid.z > SPMIS_PT_CANDIDATES) return;
    uint index = gid.y * u.width + gid.x, k = gid.z;
    SPMISShift record = { float3(0.0f), 0.0f, SPMIS_NO_PIXEL, 0.0f };
    float4 position = gbufferPosDepth.read(gid.xy);
    float4 normalMaterial = gbufferNormalMat.read(gid.xy);
    PTReservoir c = reservoirs[index];
    if (position.w > 0.0f && normalMaterial.w != float(EMISSIVE) && c.M > 0.0f && spmis_count(cells[index]) > 0u) {
        SPMISPixel cell = spmis_chosen(choices[index], 1u);
        uint seed = pcg_hash(index ^ (u.sampleIndex * 1999999973u) ^ pcg_hash(k * 0x9e3779b9u + 0x61c88647u));
        PTReservoir path = c;
        HitRecord y1 = load_primary_surface(primarySurfaces[index], position);
        float3 view = float3(primarySurfaces[index].view);
        float depth = position.w;
        uint z = SPMIS_NO_PIXEL;
        float probability = 1.0f;
        if (k == 0u) {
            if (pt_luminance(c.F) > 0.0f && c.W > 0.0f) {
                z = spmis_uniform_pixel(slots, cell, rand_f(seed));
                if (z != index) {
                    float4 zPosition = gbufferPosDepth.read(uint2(z % u.width, z / u.width));
                    y1 = load_primary_surface(primarySurfaces[z], zPosition);
                    view = float3(primarySurfaces[z].view);
                    depth = zPosition.w;
                }
            }
        } else if (spmis_draw(slots, cell, 1u, rand_f(seed), z, probability)) {
            path = reservoirs[z];
            if (!(pt_luminance(path.F) > 0.0f) || !(path.W > 0.0f)) z = SPMIS_NO_PIXEL;
        } else {
            z = SPMIS_NO_PIXEL;
        }
        if (z != SPMIS_NO_PIXEL) {
            PTShift s = { float3(path.F), path.rcJacobian };
            if (z != index) s = pt_shift(path, y1, view, pt_footprint_threshold(depth, y1.geometricNormal, view),
                                         pt_primary_cone(u), u, settings, images, SPECTRAL_CONTEXT(u, images));
            record.FJ = all(isfinite(s.FJ)) ? s.FJ : float3(0.0f);
            record.jacobian = s.jacobian;
            record.pixel = z;
            record.probability = probability;
        }
    }
    shifts[index * (SPMIS_PT_CANDIDATES + 1u) + k] = record;
}

// Resampling over the shift records with the stochastic pairwise MIS weights. Shading uses the
// vector-valued resampling weights (RESTIRPTE2026 Sec. 6.3), and the selected path becomes the
// next frame's temporal history with confidence c_c + c_Sigma (Ñ/M-scaled).
kernel void restir_pt_spmis_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::read_write> ptIndirect [[texture(5)]],
    constant Uniforms &u [[buffer(0)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    device PrimarySurface *historySurfaces [[buffer(4)]],
    const device PTReservoir *reservoirs [[buffer(5)]],
    device PTReservoir *output [[buffer(6)]],
    const device SPMISShift *shifts [[buffer(7)]],
    const device SPMISPixel *cells [[buffer(9)]],
    const device SPMISChoice *choices [[buffer(11)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;
    uint index = gid.y * u.width + gid.x;
    historySurfaces[index] = primarySurfaces[index];
    float4 position = gbufferPosDepth.read(gid);
    float4 normalMaterial = gbufferNormalMat.read(gid);
    float firstHit = ptIndirect.read(gid).w;
    PTReservoir c = reservoirs[index];
    if (!(position.w > 0.0f) || normalMaterial.w == float(EMISSIVE) || !(c.M > 0.0f) || spmis_count(cells[index]) == 0u) {
        output[index] = pt_empty();
        ptIndirect.write(float4(0.0f, 0.0f, 0.0f, firstHit), gid);
        return;
    }
    uint seed = pcg_hash(index ^ (u.sampleIndex * 1999999973u) ^ 0x2c1b3c6du);
    SPMISPixel cell = spmis_chosen(choices[index], 1u);
    float M = float(spmis_count(cell));
    float scale = float(SPMIS_PT_CANDIDATES) / M;       // Sec. 4.3
    float cS = cell.confidence[1] * scale, cc = c.M;
    float pc = pt_luminance(c.F);
    float weightSum = 0.0f;
    float3 color = float3(0.0f);
    PTReservoir chosen = c;
    float chosenTarget = pc;
    const device SPMISShift *records = shifts + index * (SPMIS_PT_CANDIDATES + 1u);
    SPMISShift canonical = records[0];
    if (canonical.pixel != SPMIS_NO_PIXEL) {
        float m = spmis_canonical_share(cS, cc)
            + M * spmis_canonical_beta(reservoirs[canonical.pixel].M * scale, cS, cc, pt_luminance(canonical.FJ), pc);
        color += m * float3(c.F) * c.W;
        weightSum += m * pc * c.W;
    }
    for (uint k = 1u; k <= SPMIS_PT_CANDIDATES; ++k) {
        SPMISShift s = records[k];
        if (s.pixel == SPMIS_NO_PIXEL) continue;
        float shifted = pt_luminance(s.FJ);
        if (!(shifted > 0.0f)) continue;
        PTReservoir q = reservoirs[s.pixel];
        float m = spmis_neighbor_weight(q.M * scale, cS, cc, pt_luminance(q.F), shifted)
            / (float(SPMIS_PT_CANDIDATES) * s.probability);
        float w = m * shifted * q.W;
        if (!(w > 0.0f) || !isfinite(w)) continue;
        color += m * float3(s.FJ) * q.W;
        weightSum += w;
        if (rand_f(seed) * weightSum < w) {
            chosen = q;
            float jacobian = pt_rc_index(q) > 0u ? s.jacobian / q.rcJacobian : 1.0f;
            chosen.F = float3(s.FJ) / jacobian;
            if (pt_rc_index(q) > 0u) chosen.rcJacobian = s.jacobian;
            chosenTarget = pt_luminance(chosen.F);
        }
    }
    float W = chosenTarget > 0.0f && weightSum > 0.0f ? weightSum / chosenTarget : 0.0f;
    if (!(W > 0.0f) || !isfinite(W)) chosen = pt_empty();
    else chosen.W = W;
    chosen.M = cc + cS;
    output[index] = chosen;
    if (!all(isfinite(color))) color = float3(0.0f);
    // Spectral transport keeps out-of-gamut (negative) colour: clamping it per frame would bias the
    // accumulation (shading_kernel accumulates it unclamped and clamps only the MetalFX input).
    ptIndirect.write(float4(SPECTRAL_KEEPS_NEGATIVE ? color : max(color, 0.0f), firstHit), gid);
}

// ReSTIR DI spatial reuse by stochastic pairwise MIS (Algorithm 2) at the diffuse primary hit
// `rec`, seen along `view`, whose reservoir holds `canonical` with weights (weight sum, M, W).
// The shift is the identity on light samples (Jacobian 1); a domain's target is
// eval_restir_target_pdf at its primary surface (unshadowed; shading tests visibility), and a
// neighbour's own target is its weight sum / (M W). Returns the selected sample and its W.
LightSample spmis_di_reuse(uint2 gid, HitRecord rec, float3 view, float4 canonicalPosDir, float4 canonicalEmitPdf,
                           float4 canonicalWeights, texture2d<float, access::read> gbufferPosDepth,
                           texture2d<float, access::read> samplePosDir, texture2d<float, access::read> sampleEmitPdf,
                           texture2d<float, access::read> reservoirWeights, const device PrimarySurface *primarySurfaces,
                           const device SPMISPixel *cells, const device SPMISSlot *slots,
                           const device SPMISChoice *choices, constant Uniforms &u,
                           constant MaterialResources &images, thread uint &seed, thread float &W,
                           thread const Wavelengths &wl) {
    uint index = gid.y * u.width + gid.x;
    LightSample selected = restir_di_stored_sample(canonicalPosDir, canonicalEmitPdf, rec.position, canonicalWeights.w);
    float pc = eval_restir_target_pdf(rec.position, rec.normal, view, rec.mat, selected, u.sceneIndex, u.light.w, images, wl);
    W = 0.0f;
    SPMISPixel own = cells[index];
    if (spmis_count(own) == 0u) {
        W = pc > 0.0f ? canonicalWeights.z : 0.0f;
        return selected;
    }
    SPMISPixel cell = spmis_chosen(choices[index], 0u);
    float M = float(spmis_count(cell));
    float scale = float(SPMIS_CANDIDATES) / M;
    float cS = cell.confidence[0] * scale, cc = canonicalWeights.y;
    float weightSum = 0.0f;
    if (pc > 0.0f && canonicalWeights.z > 0.0f) {
        uint z = spmis_uniform_pixel(slots, cell, rand_f(seed));
        uint2 zc = uint2(z % u.width, z / u.width);
        float from = pc;
        if (z != index) {
            HitRecord y1 = load_primary_surface(primarySurfaces[z], gbufferPosDepth.read(zc));
            LightSample y = restir_di_stored_sample(canonicalPosDir, canonicalEmitPdf, y1.position, canonicalWeights.w);
            from = eval_restir_target_pdf(y1.position, y1.normal, float3(primarySurfaces[z].view), y1.mat, y,
                                          u.sceneIndex, u.light.w, images, wl);
        }
        float m = spmis_canonical_share(cS, cc) + M * spmis_canonical_beta(reservoirWeights.read(zc).y * scale, cS, cc, from, pc);
        weightSum = m * pc * canonicalWeights.z;
    }
    for (uint k = 0u; k < SPMIS_CANDIDATES; ++k) {
        uint z;
        float probability;
        if (!spmis_draw(slots, cell, 0u, rand_f(seed), z, probability)) break;
        uint2 zc = uint2(z % u.width, z / u.width);
        float4 w = reservoirWeights.read(zc);
        if (!(w.y > 0.0f) || !(w.z > 0.0f) || !(w.x > 0.0f)) continue;
        LightSample y = restir_di_stored_sample(samplePosDir.read(zc), sampleEmitPdf.read(zc), rec.position, w.w);
        float here = eval_restir_target_pdf(rec.position, rec.normal, view, rec.mat, y, u.sceneIndex, u.light.w, images, wl);
        if (!(here > 0.0f)) continue;
        float source = w.x / (w.y * w.z);
        float m = spmis_neighbor_weight(w.y * scale, cS, cc, source, here) / (float(SPMIS_CANDIDATES) * probability);
        float wi = m * here * w.z;
        if (!(wi > 0.0f) || !isfinite(wi)) continue;
        weightSum += wi;
        if (rand_f(seed) * weightSum < wi) selected = y;
    }
    float target = eval_restir_target_pdf(rec.position, rec.normal, view, rec.mat, selected, u.sceneIndex, u.light.w, images, wl);
    W = target > 0.0f && weightSum > 0.0f && isfinite(weightSum) ? weightSum / target : 0.0f;
    return selected;
}

// ReSTIR GI spatial reuse by stochastic pairwise MIS at the diffuse primary hit `rec`. The
// reconnection shift keeps x2, so in the area-measure target (eval_restir_gi_target) its
// Jacobian is 1; restir_gi_accepts_shift restricts the domain of the shift from pixel i into
// this pixel to solid-angle Jacobians within [0.1, 10]. The canonical weight applies the same
// restriction to its terms (y's target from domain i is zero outside it), so the bound is a
// domain restriction of an unbiased estimator here, not a rejection. Pixel i's GI samples are
// traced from its primary hit, so they are always visible from it and above its geometric
// normal: y's target from domain i also needs both (one ray per pixel). Without that test the canonical weight
// counts domains that cannot produce y, which darkened Cornell by 0.08%. Shifts into this pixel
// need no test: shading applies visibility, and an occluded y contributes nothing.
// `radiance` and `sampleU` are the selected sample's secondary radiance and wavelength number.
void spmis_gi_reuse(uint2 gid, HitRecord rec, float3 view, thread float4 &posPdf, thread float4 &normal,
                    thread Spectrum &radiance, thread float &sampleU, float4 canonicalWeights, texture2d<float, access::read> gbufferPosDepth,
                    texture2d<float, access::read> giPosPdf, texture2d<float, access::read> giNormal,
                    texture2d<float, access::read> giRadiance, texture2d<float, access::read> giWeights,
                    const device PrimarySurface *primarySurfaces, const device SPMISPixel *cells,
                    const device SPMISSlot *slots, const device SPMISChoice *choices, constant Uniforms &u,
                    constant MaterialResources &images, thread uint &seed, thread float &W, thread const Wavelengths &wl) {
    uint index = gid.y * u.width + gid.x;
    float pc = normal.w > 0.0f ? eval_restir_gi_target(rec.position, rec.normal, view, rec.mat, posPdf.xyz, normal.xyz, radiance,
                                                       sample_wavelengths(sampleU, wl)) : 0.0f;
    W = 0.0f;
    SPMISPixel own = cells[index];
    if (spmis_count(own) == 0u) {
        W = pc > 0.0f ? canonicalWeights.z : 0.0f;
        return;
    }
    SPMISPixel cell = spmis_chosen(choices[index], 1u);
    float M = float(spmis_count(cell));
    float scale = float(SPMIS_CANDIDATES) / M;
    float cS = cell.confidence[1] * scale, cc = canonicalWeights.y;
    float weightSum = 0.0f;
    if (pc > 0.0f && canonicalWeights.z > 0.0f) {
        uint z = spmis_uniform_pixel(slots, cell, rand_f(seed));
        uint2 zc = uint2(z % u.width, z / u.width);
        float from = pc;
        if (z != index) {
            HitRecord y1 = load_primary_surface(primarySurfaces[z], gbufferPosDepth.read(zc));
            from = restir_gi_accepts_shift(rec.position, y1.position, posPdf.xyz, normal.xyz)
                ? eval_restir_gi_target(y1.position, y1.normal, float3(primarySurfaces[z].view), y1.mat,
                                        posPdf.xyz, normal.xyz, radiance, sample_wavelengths(sampleU, wl)) : 0.0f;
            // restir_gi_initial samples x2 by sample_bsdf, which rejects directions below the
            // geometric normal, and by tracing, so x2 must also be visible from x1_i.
            float3 g = y1.geometricNormal;
            if (from > 0.0f && dot(g, g) > 0.5f && !(dot(posPdf.xyz - y1.position, g) > 0.0f)) from = 0.0f;
            if (from > 0.0f && !gi_connection_visible(y1.position, y1.geometricNormal, posPdf.xyz, u, images, y1.error))
                from = 0.0f;
        }
        float m = spmis_canonical_share(cS, cc) + M * spmis_canonical_beta(giWeights.read(zc).y * scale, cS, cc, from, pc);
        weightSum = m * pc * canonicalWeights.z;
    }
    for (uint k = 0u; k < SPMIS_CANDIDATES; ++k) {
        uint z;
        float probability;
        if (!spmis_draw(slots, cell, 1u, rand_f(seed), z, probability)) break;
        uint2 zc = uint2(z % u.width, z / u.width);
        float4 w = giWeights.read(zc);
        float4 zPosPdf = giPosPdf.read(zc), zNormal = giNormal.read(zc);
        if (!(w.y > 0.0f) || !(w.z > 0.0f) || !(w.x > 0.0f) || zPosPdf.w <= 0.0f || zNormal.w <= 0.0f) continue;
        if (z != index && !restir_gi_accepts_shift(rec.position, gbufferPosDepth.read(zc).xyz, zPosPdf.xyz, zNormal.xyz)) continue;
        Spectrum zRadiance = gi_radiance(giRadiance.read(zc));
        float here = eval_restir_gi_target(rec.position, rec.normal, view, rec.mat, zPosPdf.xyz, zNormal.xyz, zRadiance,
                                           sample_wavelengths(w.w, wl));
        if (!(here > 0.0f)) continue;
        float source = w.x / (w.y * w.z);
        float m = spmis_neighbor_weight(w.y * scale, cS, cc, source, here) / (float(SPMIS_CANDIDATES) * probability);
        float wi = m * here * w.z;
        if (!(wi > 0.0f) || !isfinite(wi)) continue;
        weightSum += wi;
        if (rand_f(seed) * weightSum < wi) {
            posPdf = zPosPdf; normal = zNormal; radiance = zRadiance; sampleU = w.w;
        }
    }
    float target = normal.w > 0.0f ? eval_restir_gi_target(rec.position, rec.normal, view, rec.mat, posPdf.xyz, normal.xyz, radiance,
                                                           sample_wavelengths(sampleU, wl)) : 0.0f;
    W = target > 0.0f && weightSum > 0.0f && isfinite(weightSum) ? weightSum / target : 0.0f;
}

// RESTIRPTE2026 Sec. 5: the share of the 17 x 17 neighbourhood (288 other pixels) whose final
// reservoir holds a shifted copy of this pixel's path, detected by its replay seed.
kernel void restir_pt_duplication_kernel(
    texture2d<float, access::write> duplication [[texture(4)]],
    constant Uniforms &u [[buffer(0)]],
    const device PTReservoir *reservoirs [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;
    PTReservoir r = reservoirs[gid.y * u.width + gid.x];
    float count = 0.0f;
    if (pt_length(r) > 0u && r.W > 0.0f) {
        for (int dy = -8; dy <= 8; ++dy) for (int dx = -8; dx <= 8; ++dx) {
            int2 q = int2(gid) + int2(dx, dy);
            if ((dx == 0 && dy == 0) || !pt_in_frame(q, u)) continue;
            PTReservoir s = reservoirs[uint(q.y) * u.width + uint(q.x)];
            if (s.seed == r.seed && pt_length(s) > 0u && s.W > 0.0f) count += 1.0f;
        }
    }
    duplication.write(float4(count / 288.0f), gid);
}

// ============================================================================
// Multi-layer reservoir splatting for temporal reuse (REFERENCES.md HONG2026, LIU2025)
// ============================================================================
// While the view changes (splat_frame), temporal reuse maps previous-frame reuse domains
// forward instead of reprojecting current pixels backwards. A domain is a pixel-layer pair: the
// front layer is the pixel's primary hit; deep layer i (2 .. 1 + SPLAT_DEEP_LAYERS) is the i-th
// front-facing hit along the pixel's camera ray, kept only where a surface that was visible
// before is now occluded (active domains, Sec. 4.3), in a compacted pool. Each frame:
//   splat_activate_kernel   splats the previous domains' representative hits and marks the
//                           occluded ones' layers active (transitive activation, Sec. 5);
//   splat_layers_kernel     traces the active deep layers of each pixel (after hole filling),
//                           records its depth ranges (Sec. 4.2) and allocates their domains;
//   splat_deep_restir_kernel / restir_pt_deep_initial_kernel   canonical samples of deep domains;
//   splat_reservoirs_kernel splats every previous domain into the current domain whose depth
//                           range and surface it matches, keeping the nearest splat per domain;
//   splat_temporal_kernel / restir_pt_splat_temporal_kernel   merge that temporal candidate.
// Domains stay point sampled (the renderer's reservoirs are not area reservoirs), so the splat
// selects the temporal source domain from G-buffer geometry only and the existing DI, GI and PT
// temporal merges shift its sample into the destination domain.
#define SPLAT_DEEP_LAYERS 1u
#define SPLAT_FILL_RADIUS 1
constant float SPLAT_EPSILON = 0.01f;
constant uint SPLAT_NONE = 0xffffffffu;
constant uint SPLAT_PROPAGATES = 1u << 8;

// A deep domain: its representative hit (position, camera distance), pixel index and flags
// (layer in bits 0-7; SPLAT_PROPAGATES when splatted directly rather than by hole filling).
struct SplatDomain { packed_float3 position; float depth; uint pixel; uint flags; uint2 padding; };
// Per pixel: camera distances and depth-range half widths of deep layers 2.. (0 = not traced),
// and their pool slots (SPLAT_NONE = inactive).
struct SplatLayers { float4 depth; float4 halfWidth; uint4 slot; };
// Deep-domain reservoirs in the texture layouts of restir_temporal_kernel.
struct SplatDI { float4 posDir, emitPdf, weights; };
struct SplatGI { float4 posPdf, normal, radiance, weights; };
static_assert(sizeof(SplatDomain) == 32 && sizeof(SplatLayers) == 48 && sizeof(SplatDI) == 48 && sizeof(SplatGI) == 64,
              "Swift allocates these splat layouts");
static_assert(SPLAT_DEEP_LAYERS >= 1u && SPLAT_DEEP_LAYERS <= 4u, "SplatLayers holds up to four deep layers");

// Pool counters: [0] allocated domains (may exceed the capacity), [1] overflowed domains,
// [2] capacity (written by the host).
uint splat_count(const device uint *counters) { return min(counters[0], counters[2]); }

// Forward projection into the current frame's pixel grid (the camera math of restir_backproject).
bool splat_project(float3 c, constant Uniforms &u, thread int2 &q) {
    float4 clip = u.currentViewProj * float4(c, 1.0f);
    if (!(clip.w > 0.0f)) return false;
    float2 uv = clip.xy / clip.w * float2(0.5f, -0.5f) + 0.5f;
    if (!all(uv >= 0.0f) || !all(uv < 1.0f)) return false;
    q = int2(uv * float2(float(u.width), float(u.height)));
    return pt_in_frame(q, u);
}

// Depth-range half width at camera distance t: epsilon t (Sec. 5, epsilon = 0.01), widened to twice
// the pixel footprint's depth extent on slanted surfaces (cosine between normal and view ray).
float splat_half_width(float t, float cosine, float cone) {
    return t * max(SPLAT_EPSILON, 2.0f * cone / max(abs(cosine), 0.25f));
}

// The layer whose depth range holds camera distance d (Eq. 4): 0 for the front layer, i for deep
// layer i + 1, or SPLAT_NONE. Overlapping neighbouring ranges meet at their midpoint (Sec. 5).
uint splat_layer(float d, float front, float frontHalfWidth, SplatLayers layers) {
    float t[1 + SPLAT_DEEP_LAYERS], h[1 + SPLAT_DEEP_LAYERS];
    t[0] = front; h[0] = frontHalfWidth;
    uint count = 1u;
    for (uint i = 0u; i < SPLAT_DEEP_LAYERS && layers.depth[i] > 0.0f; ++i) {
        t[count] = layers.depth[i]; h[count] = layers.halfWidth[i]; ++count;
    }
    for (uint i = 0u; i < count; ++i) {
        float lo = t[i] - h[i], hi = t[i] + h[i];
        if (i > 0u && t[i - 1u] + h[i - 1u] > lo) lo = 0.5f * (t[i - 1u] + h[i - 1u] + lo);
        if (i + 1u < count && t[i + 1u] - h[i + 1u] < hi) hi = 0.5f * (hi + t[i + 1u] - h[i + 1u]);
        if (d >= lo && d <= hi) return i;
    }
    return SPLAT_NONE;
}

// Deep domains hold reservoirs of the active reuse: DI and GI need a diffuse hit, PT a scattering one.
bool splat_domain_useful(MaterialType type, constant Uniforms &u) {
    return restir_gi_active(u) ? type == DIFFUSE : type != EMISSIVE;
}

uint splat_seed(uint pixel, uint layer, uint stream, constant Uniforms &u) {
    return pcg_hash(pcg_hash(pixel * 8u + layer) ^ (u.sampleIndex * 1999999973u) ^ stream);
}

// Pass 1: splat the previous frame's representative hits (front layer: the history G-buffer;
// deep: the previous pool's propagating domains). A hit behind the current front layer is
// assigned the layer of its rank among front-facing hits along the camera ray towards it; that
// layer becomes active in the pixel it lands in. If the ray's first hit (the immediate occluder)
// is a different object than the pixel's front layer, the activation is dropped (Sec. 5, with
// material slots in place of instance IDs).
kernel void splat_activate_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::read> historyPosDepth [[texture(2)]],
    texture2d<float, access::read> historyNormalMat [[texture(3)]],
    constant Uniforms &u [[buffer(0)]],
    constant MaterialResources &images [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    const device SplatDomain *previous [[buffer(9)]],
    const device PrimarySurface *previousSurfaces [[buffer(10)]],
    const device uint *previousCounters [[buffer(11)]],
    device atomic_uint *mask [[buffer(15)]],
    uint tid [[thread_position_in_grid]])
{
    uint pixels = u.width * u.height;
    float3 c, n;
    if (tid < pixels) {
        uint2 p = uint2(tid % u.width, tid / u.width);
        float4 old = historyPosDepth.read(p);
        float4 oldNormal = historyNormalMat.read(p);
        if (!(old.w > 0.0f) || oldNormal.w == float(EMISSIVE)) return;
        c = old.xyz; n = oldNormal.xyz;
    } else {
        uint j = tid - pixels;
        if (j >= splat_count(previousCounters) || (previous[j].flags & SPLAT_PROPAGATES) == 0u) return;
        c = previous[j].position; n = previousSurfaces[j].normal;
    }
    int2 q;
    if (!splat_project(c, u, q)) return;
    uint qi = uint(q.y) * u.width + uint(q.x);
    float4 front = gbufferPosDepth.read(uint2(q));
    if (!(front.w > 0.0f)) return;
    float3 eye = u.cameraPos.xyz;
    float dist = distance(c, eye);
    if (!(dist > 0.0f)) return;
    float3 direction = (c - eye) / dist;
    float cone = pt_primary_cone(u);
    float frontHalfWidth = splat_half_width(front.w, dot(gbufferNormalMat.read(uint2(q)).xyz, float3(primarySurfaces[qi].view)), cone);
    // Visible (the front layer), or in front of the pixel's first hit (off the pixel's ray).
    if (dist <= front.w + frontHalfWidth) return;
    float reach = dist - splat_half_width(dist, dot(n, direction), cone);
    Ray ray;
    ray.origin = eye;
    ray.direction = direction;
    uint layer = 0u;
    for (uint k = 0u; k < 2u * (SPLAT_DEEP_LAYERS + 1u); ++k) {
        HitRecord hit;
        if (!trace_scene(ray, u.sceneIndex, hit, images, u)) return;
        if (distance(eye, hit.position) >= reach) {
            if (layer < 1u || layer > SPLAT_DEEP_LAYERS) return;
            atomic_fetch_or_explicit(&mask[qi], 1u << (layer - 1u), memory_order_relaxed);
            return;
        }
        if (k == 0u && hit.mat.slot != (primarySurfaces[qi].flags >> 16)) return;
        if (k == 0u || hit.front_face) ++layer;
        ray.origin = ray_origin(hit.position, hit.geometricNormal, direction, u, hit.error);
    }
}

// Pass 2: per pixel, the deep layers to maintain are those activated within SPLAT_FILL_RADIUS
// pixels (hole filling, Sec. 4.3; filled domains do not propagate). The pixel's camera ray is
// continued past its front layer; front-facing hits define deep layers 2.., their depth ranges,
// and, where active, a pool domain with its resolved surface.
kernel void splat_layers_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    constant Uniforms &u [[buffer(0)]],
    constant SurfaceSettings *settings [[buffer(1)]],
    constant MaterialResources &images [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    device SplatDomain *domains [[buffer(12)]],
    device PrimarySurface *surfaces [[buffer(13)]],
    device atomic_uint *counters [[buffer(14)]],
    const device uint *mask [[buffer(15)]],
    device SplatLayers *layers [[buffer(16)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;
    uint index = gid.y * u.width + gid.x;
    SplatLayers out;
    out.depth = float4(0.0f); out.halfWidth = float4(0.0f); out.slot = uint4(SPLAT_NONE);
    uint direct = mask[index], active = 0u;
    for (int dy = -SPLAT_FILL_RADIUS; dy <= SPLAT_FILL_RADIUS; ++dy) {
        for (int dx = -SPLAT_FILL_RADIUS; dx <= SPLAT_FILL_RADIUS; ++dx) {
            int2 q = int2(gid) + int2(dx, dy);
            if (dx * dx + dy * dy <= SPLAT_FILL_RADIUS * SPLAT_FILL_RADIUS && pt_in_frame(q, u))
                active |= mask[uint(q.y) * u.width + uint(q.x)];
        }
    }
    active &= (1u << SPLAT_DEEP_LAYERS) - 1u;
    float4 front = gbufferPosDepth.read(gid);
    if (active == 0u || !(front.w > 0.0f)) { layers[index] = out; return; }
    PrimarySurface s = primarySurfaces[index];
    float3 eye = u.cameraPos.xyz, direction = float3(s.view);
    uint needed = 32u - clz(active);  // deepest active layer is 1 + needed
    uint capacity = atomic_load_explicit(&counters[2], memory_order_relaxed);
    float cone = pt_primary_cone(u);
    Ray ray;
    ray.direction = direction;
    ray.origin = ray_origin(front.xyz, float3(s.geometricNormal), direction, u, s.error);
    uint layer = 1u;
    for (uint k = 0u; k < 2u * SPLAT_DEEP_LAYERS && layer < 1u + needed; ++k) {
        HitRecord hit;
        if (!trace_scene(ray, u.sceneIndex, hit, images, u)) break;
        ray.origin = ray_origin(hit.position, hit.geometricNormal, direction, u, hit.error);
        if (!hit.front_face) continue;
        uint i = layer - 1u;
        ++layer;
        float t = distance(eye, hit.position);
        out.depth[i] = t;
        out.halfWidth[i] = splat_half_width(t, dot(hit.geometricNormal, direction), cone);
        if (((active >> i) & 1u) == 0u) continue;
        Ray primary;
        primary.origin = eye;
        primary.direction = direction;
        hit.t = t;
        resolve_material(hit, primary, u, settings, images, t * cone);
        if (!splat_domain_useful(hit.mat.type, u)) continue;
        uint slot = atomic_fetch_add_explicit(&counters[0], 1u, memory_order_relaxed);
        if (slot >= capacity) { atomic_fetch_add_explicit(&counters[1], 1u, memory_order_relaxed); continue; }
        surfaces[slot] = store_primary_surface(hit, direction);
        SplatDomain d;
        d.position = hit.position; d.depth = t; d.pixel = index;
        d.flags = (i + 2u) | (((direct >> i) & 1u) != 0u ? SPLAT_PROPAGATES : 0u);
        d.padding = uint2(0u);
        domains[slot] = d;
        out.slot[i] = slot;
    }
    layers[index] = out;
}

// Pass 3 (ReSTIR DI / GI): canonical reservoirs of the deep domains, as restir_temporal_kernel
// builds them for the front layer.
kernel void splat_deep_restir_kernel(
    constant Uniforms &u [[buffer(0)]],
    constant SurfaceSettings *settings [[buffer(1)]],
    constant MaterialResources &images [[buffer(2)]],
    const device SplatDomain *domains [[buffer(12)]],
    const device PrimarySurface *surfaces [[buffer(13)]],
    const device uint *counters [[buffer(14)]],
    device SplatDI *di [[buffer(19)]],
    device SplatGI *gi [[buffer(21)]]
    SPECTRAL_BUFFERS,
    uint tid [[thread_position_in_grid]])
{
    if (tid >= splat_count(counters)) return;
    SplatDomain d = domains[tid];
    PrimarySurface s = surfaces[tid];
    bool diffuse = MaterialType(s.flags & 255u) == DIFFUSE;
    HitRecord rec = load_primary_surface(s, float4(float3(d.position), d.depth));
    float3 view = float3(s.view);
    uint seed = splat_seed(d.pixel, d.flags & 255u, 0x7f4a7c15u, u);
    // The deep domain's own wavelengths, from its seed.
    Wavelengths wl = SPECTRAL_WAVELENGTHS(float2(float(pcg_hash(seed ^ 0x5bd1e995u) >> 8u), float(pcg_hash(seed) >> 8u)) * (1.0f / 16777216.0f),
                                          u, images);
    if (restir_di_active(u)) {
        SplatDI r = { float4(0.0f), float4(0.0f), float4(0.0f) };
        if (diffuse) {
            DIReservoir c = restir_di_initial(rec, view, u, seed, images, wl);
            restir_di_encode(c, rec, view, u, images, r.posDir, r.emitPdf, r.weights, wl);
        }
        di[tid] = r;
    }
    if (restir_gi_active(u)) {
        SplatGI r = { float4(0.0f), float4(0.0f), float4(0.0f), float4(0.0f) };
        if (diffuse && restir_gi_enabled(u.cameraTarget.w)) {
            GIReservoir c = restir_gi_initial(rec, view, tan((u.cameraPos.w * 0.5f) * PI / 180.0f), u, settings, images, seed, wl);
            restir_gi_encode(c, rec, view, r.posPdf, r.normal, r.radiance, r.weights, wl);
        }
        gi[tid] = r;
    }
}

// Pass 3 (ReSTIR PT): initial path trees of the deep domains (pt_generate), and with ReSTCV
// their initial colour estimates (RESTCV2026), which temporal reuse carries across frames.
kernel void restir_pt_deep_initial_kernel(
    constant Uniforms &u [[buffer(0)]],
    constant SurfaceSettings *settings [[buffer(1)]],
    constant MaterialResources &images [[buffer(2)]],
    const device SplatDomain *domains [[buffer(12)]],
    const device PrimarySurface *surfaces [[buffer(13)]],
    const device uint *counters [[buffer(14)]],
    device PTReservoir *pt [[buffer(23)]],
    device PTControl *controls [[buffer(25)]]
    SPECTRAL_BUFFERS,
    uint tid [[thread_position_in_grid]])
{
    if (tid >= splat_count(counters)) return;
    SplatDomain d = domains[tid];
    PrimarySurface s = surfaces[tid];
    PTReservoir r = pt_empty();
    float3 estimate = float3(0.0f), reflectance = float3(0.0f);
    if (MaterialType(s.flags & 255u) != EMISSIVE) {
        HitRecord x1 = load_primary_surface(s, float4(float3(d.position), d.depth));
        float3 view = float3(s.view);
        float firstHit = 0.0f;
        uint2 pixel = uint2(d.pixel % u.width, d.pixel / u.width);
        r = pt_generate(x1, view, pt_initial_seed(pixel, d.flags & 255u, splat_seed(d.pixel, d.flags & 255u, 0x2545f491u, u), u),
                        pt_footprint_threshold(d.depth, x1.geometricNormal, view), pt_primary_cone(u), u, settings, images, firstHit,
                        estimate, SPECTRAL_CONTEXT(u, images));
        reflectance = pt_reflectance(x1.mat, x1.normal, -view);
    }
    pt[tid] = r;
    if (restir_pt_control_variates(u)) {
        PTControl control = { estimate, pt_encode_reflectance(reflectance) };
        controls[tid] = control;
    }
}

// Pass 4: every previous domain (front layer and deep pool) is splatted to the pixel its
// representative hit projects to, assigned the layer whose depth range holds its camera distance,
// and offered to that domain when it shows the same surface (the temporal test of the active reuse:
// restir_same_surface for ReSTIR GI, pt_same_surface for ReSTIR PT). Each destination
// keeps the splat nearest to its own representative hit (a 64-bit atomic minimum of distance and
// source index), so its temporal source depends on geometry only, never on samples.
kernel void splat_reservoirs_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::read> historyPosDepth [[texture(2)]],
    texture2d<float, access::read> historyNormalMat [[texture(3)]],
    constant Uniforms &u [[buffer(0)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    const device SplatDomain *previous [[buffer(9)]],
    const device PrimarySurface *previousSurfaces [[buffer(10)]],
    const device uint *previousCounters [[buffer(11)]],
    const device SplatDomain *domains [[buffer(12)]],
    const device PrimarySurface *surfaces [[buffer(13)]],
    const device SplatLayers *layers [[buffer(16)]],
    device atomic_ulong *sources [[buffer(17)]],
    uint tid [[thread_position_in_grid]])
{
    uint pixels = u.width * u.height;
    float3 c;
    float4 n;
    if (tid < pixels) {
        uint2 p = uint2(tid % u.width, tid / u.width);
        float4 old = historyPosDepth.read(p);
        n = historyNormalMat.read(p);
        if (!(old.w > 0.0f) || n.w == float(EMISSIVE)) return;
        c = old.xyz;
    } else {
        uint j = tid - pixels;
        if (j >= splat_count(previousCounters)) return;
        c = previous[j].position;
        n = float4(float3(previousSurfaces[j].normal), float(previousSurfaces[j].flags & 255u));
    }
    int2 q;
    if (!splat_project(c, u, q)) return;
    uint qi = uint(q.y) * u.width + uint(q.x);
    float4 front = gbufferPosDepth.read(uint2(q));
    if (!(front.w > 0.0f)) return;
    float4 frontNormal = gbufferNormalMat.read(uint2(q));
    float3 view = float3(primarySurfaces[qi].view);
    SplatLayers l = layers[qi];
    float dist = distance(c, u.cameraPos.xyz);
    uint layer = splat_layer(dist, front.w, splat_half_width(front.w, dot(frontNormal.xyz, view), pt_primary_cone(u)), l);
    if (layer == SPLAT_NONE) return;
    float4 destination = front, destinationNormal = frontNormal;
    uint target = qi;
    if (layer > 0u) {
        uint slot = l.slot[layer - 1u];
        if (slot == SPLAT_NONE) return;
        destination = float4(float3(domains[slot].position), domains[slot].depth);
        destinationNormal = float4(float3(surfaces[slot].normal), float(surfaces[slot].flags & 255u));
        view = float3(surfaces[slot].view);
        target = pixels + slot;
    }
    bool same = restir_gi_active(u) ? restir_same_surface(destination, destinationNormal, float4(c, dist), n)
                                    : pt_same_surface(destination, destinationNormal, view, float4(c, dist), n, u);
    if (!same) return;
    ulong key = (ulong(as_type<uint>(distance(c, destination.xyz))) << 32) | ulong(tid);
    atomic_min_explicit(&sources[target], key, memory_order_relaxed);
}

// The temporal source of destination domain tid: its nearest splat or, for a front-layer domain
// that no splat reached (a splatting hole), the reprojected pixel when it shows the same surface
// (the backup sample of LIU2025 Sec. 4.2). Sources below the pixel count are previous front-layer
// pixels; the others previous pool slots (offset by the pixel count).
uint splat_source(uint tid, bool deep, bool sameSurfaceBackup, const device ulong *sources,
                  constant Uniforms &u, thread int2 &prevCoord) {
    ulong key = sources[tid];
    if (key != 0xfffffffffffffffful) return uint(key & 0xffffffffu);
    if (deep || !sameSurfaceBackup) return SPLAT_NONE;
    return uint(prevCoord.y) * u.width + uint(prevCoord.x);
}

// Pass 5 (ReSTIR DI / GI): the temporal merge of restir_temporal_kernel, with the source domain
// chosen by the splat, for front-layer pixels (in place, in the current reservoir textures) and
// deep domains (in the pool).
kernel void splat_temporal_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> historyPosDepth [[texture(2)]],
    texture2d<float, access::read> historyNormalMat [[texture(3)]],
    texture2d<float, access::read_write> samplePosDir [[texture(5)]],
    texture2d<float, access::read_write> sampleEmitPdf [[texture(6)]],
    texture2d<float, access::read_write> reservoirWeights [[texture(7)]],
    texture2d<float, access::read> histSamplePosDir [[texture(8)]],
    texture2d<float, access::read> histSampleEmitPdf [[texture(9)]],
    texture2d<float, access::read> histReservoirWeights [[texture(10)]],
    texture2d<float, access::read_write> giPosPdf [[texture(11)]],
    texture2d<float, access::read_write> giNormal [[texture(12)]],
    texture2d<float, access::read_write> giRadiance [[texture(13)]],
    texture2d<float, access::read_write> giWeights [[texture(14)]],
    texture2d<float, access::read> histGIPosPdf [[texture(15)]],
    texture2d<float, access::read> histGINormal [[texture(16)]],
    texture2d<float, access::read> histGIRadiance [[texture(17)]],
    texture2d<float, access::read> histGIWeights [[texture(18)]],
    constant Uniforms &u [[buffer(0)]],
    constant MaterialResources &images [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    const device SplatDomain *previous [[buffer(9)]],
    const device SplatDomain *domains [[buffer(12)]],
    const device PrimarySurface *surfaces [[buffer(13)]],
    const device uint *counters [[buffer(14)]],
    const device ulong *sources [[buffer(17)]],
    const device SplatDI *previousDI [[buffer(18)]],
    device SplatDI *di [[buffer(19)]],
    const device SplatGI *previousGI [[buffer(20)]],
    device SplatGI *gi [[buffer(21)]]
    SPECTRAL_BUFFERS,
    uint tid [[thread_position_in_grid]])
{
    Wavelengths context = SPECTRAL_CONTEXT(u, images);
    uint pixels = u.width * u.height;
    bool deep = tid >= pixels;
    uint j = tid - pixels;
    uint2 p = uint2(tid % u.width, tid / u.width);
    PrimarySurface s;
    float4 position;
    if (!deep) {
        position = gbufferPosDepth.read(p);
        if (!(position.w > 0.0f)) return;
        s = primarySurfaces[tid];
    } else {
        if (j >= splat_count(counters)) return;
        s = surfaces[j];
        position = float4(float3(domains[j].position), domains[j].depth);
    }
    if (MaterialType(s.flags & 255u) != DIFFUSE) return;
    HitRecord rec = load_primary_surface(s, position);
    float3 view = float3(s.view);
    int2 prevCoord = int2(0);
    bool backup = !deep && sources[tid] == 0xfffffffffffffffful && restir_backproject(rec.position, u, prevCoord) &&
        restir_same_surface(historyPosDepth.read(uint2(prevCoord)), historyNormalMat.read(uint2(prevCoord)), rec);
    uint source = splat_source(tid, deep, backup, sources, u, prevCoord);
    if (source == SPLAT_NONE) return;
    float3 sourceX1;
    SplatDI h;
    SplatGI hg = { float4(0.0f), float4(0.0f), float4(0.0f), float4(0.0f) };
    if (source < pixels) {
        uint2 sp = uint2(source % u.width, source / u.width);
        sourceX1 = historyPosDepth.read(sp).xyz;
        h.posDir = histSamplePosDir.read(sp); h.emitPdf = histSampleEmitPdf.read(sp); h.weights = histReservoirWeights.read(sp);
        if (restir_gi_active(u)) {
            hg.posPdf = histGIPosPdf.read(sp); hg.normal = histGINormal.read(sp);
            hg.radiance = histGIRadiance.read(sp); hg.weights = histGIWeights.read(sp);
        }
    } else {
        uint k = source - pixels;
        sourceX1 = previous[k].position;
        h = previousDI[k];
        if (restir_gi_active(u)) hg = previousGI[k];
    }
    uint seed = pcg_hash(tid ^ (u.sampleIndex * 1999999973u) ^ 0x3c6ef372u);
    SplatDI c = deep ? di[j] : SplatDI{ samplePosDir.read(p), sampleEmitPdf.read(p), reservoirWeights.read(p) };
    DIReservoir r;
    r.sample = restir_di_stored_sample(c.posDir, c.emitPdf, rec.position, c.weights.w);
    r.weightSum = c.weights.x; r.M = c.weights.y;
    if (h.weights.y > 0.0f && h.weights.z > 0.0f)
        restir_di_merge(r, rec, view, h.posDir, h.emitPdf, h.weights.y, h.weights.z, h.weights.w, u, seed, images, context);
    restir_di_encode(r, rec, view, u, images, c.posDir, c.emitPdf, c.weights, context);
    if (deep) di[j] = c;
    else { samplePosDir.write(c.posDir, p); sampleEmitPdf.write(c.emitPdf, p); reservoirWeights.write(c.weights, p); }
    if (!restir_gi_active(u) || !restir_gi_enabled(u.cameraTarget.w)) return;
    SplatGI g = deep ? gi[j] : SplatGI{ giPosPdf.read(p), giNormal.read(p), giRadiance.read(p), giWeights.read(p) };
    GIReservoir e;
    e.position = g.posPdf.xyz; e.sourcePdf = g.posPdf.w; e.normal = g.normal.xyz; e.radiance = gi_radiance(g.radiance);
    e.weightSum = g.weights.x; e.M = g.weights.y; e.u = g.weights.w;
    if (hg.weights.y > 0.0f && hg.weights.z > 0.0f && hg.posPdf.w > 0.0f && hg.normal.w > 0.0f)
        restir_gi_merge(e, rec, view, sourceX1, hg.posPdf, hg.normal, gi_radiance(hg.radiance), hg.weights.w, hg.weights.y, hg.weights.z,
                        seed, context);
    restir_gi_encode(e, rec, view, g.posPdf, g.normal, g.radiance, g.weights, context);
    if (deep) gi[j] = g;
    else { giPosPdf.write(g.posPdf, p); giNormal.write(g.normal, p); giRadiance.write(g.radiance, p); giWeights.write(g.weights, p); }
}

// Pass 5 (ReSTIR PT): the generalized Talbot temporal merge (pt_temporal_merge) with the source
// domain chosen by the splat, for front-layer pixels and deep domains; it replaces
// restir_pt_temporal_kernel on splat frames. Deep domains skip spatial reuse (Sec. 5). With ReSTCV
// every domain's estimate takes the temporal control variates from its source: a front-layer
// source's final estimate (ptIndirect) or a deep source's estimate (previousControls), so deep
// domains carry their colour history to the pixels they reappear in.
kernel void restir_pt_splat_temporal_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::read> historyPosDepth [[texture(2)]],
    texture2d<float, access::read> historyNormalMat [[texture(3)]],
    texture2d<float, access::read> duplication [[texture(4)]],
    texture2d<float, access::read> ptIndirect [[texture(5)]],
    constant Uniforms &u [[buffer(0)]],
    constant SurfaceSettings *settings [[buffer(1)]],
    constant MaterialResources &images [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    const device PrimarySurface *historySurfaces [[buffer(4)]],
    device PTReservoir *reservoirs [[buffer(5)]],
    const device PTReservoir *history [[buffer(6)]],
    const device SplatDomain *previous [[buffer(9)]],
    const device PrimarySurface *previousSurfaces [[buffer(10)]],
    const device SplatDomain *domains [[buffer(12)]],
    const device PrimarySurface *surfaces [[buffer(13)]],
    const device uint *counters [[buffer(14)]],
    const device ulong *sources [[buffer(17)]],
    const device PTReservoir *previousPT [[buffer(22)]],
    device PTReservoir *pt [[buffer(23)]],
    device PTControl *controls [[buffer(24)]],
    device PTControl *deepControls [[buffer(25)]],
    const device PTControl *previousControls [[buffer(26)]]
    SPECTRAL_BUFFERS,
    uint tid [[thread_position_in_grid]])
{
    uint pixels = u.width * u.height;
    bool deep = tid >= pixels;
    uint j = tid - pixels;
    PrimarySurface s;
    float4 position, normalMaterial;
    PTReservoir c;
    if (!deep) {
        uint2 p = uint2(tid % u.width, tid / u.width);
        position = gbufferPosDepth.read(p);
        normalMaterial = gbufferNormalMat.read(p);
        if (!(position.w > 0.0f) || normalMaterial.w == float(EMISSIVE)) return;
        s = primarySurfaces[tid];
        c = reservoirs[tid];
    } else {
        if (j >= splat_count(counters)) return;
        s = surfaces[j];
        position = float4(float3(domains[j].position), domains[j].depth);
        normalMaterial = float4(float3(s.normal), float(s.flags & 255u));
        if (normalMaterial.w == float(EMISSIVE)) return;
        c = pt[j];
    }
    float3 view = float3(s.view);
    int2 prevCoord = int2(0);
    bool backup = !deep && sources[tid] == 0xfffffffffffffffful && restir_backproject(position.xyz, u, prevCoord) &&
        pt_same_surface(position, normalMaterial, view, historyPosDepth.read(uint2(prevCoord)), historyNormalMat.read(uint2(prevCoord)), u);
    uint source = splat_source(tid, deep, backup, sources, u, prevCoord);
    if (source == SPLAT_NONE) return;
    PTReservoir t;
    HitRecord y1;
    float3 oldView;
    float oldDepth;
    float cap = PT_CONFIDENCE_CAP;
    if (source < pixels) {
        uint2 sp = uint2(source % u.width, source / u.width);
        float4 oldPosition = historyPosDepth.read(sp);
        t = history[source];
        y1 = load_primary_surface(historySurfaces[source], oldPosition);
        oldView = float3(historySurfaces[source].view);
        oldDepth = oldPosition.w;
        if (restir_pt_decorrelates(u))
            cap = mix(PT_CONFIDENCE_CAP, PT_CONFIDENCE_MIN, pow(saturate(duplication.read(sp).x), PT_DUPLICATION_EXPONENT));
    } else {
        uint k = source - pixels;
        t = previousPT[k];
        y1 = load_primary_surface(previousSurfaces[k], float4(float3(previous[k].position), previous[k].depth));
        oldView = float3(previousSurfaces[k].view);
        oldDepth = previous[k].depth;
    }
    if (!(t.M > 0.0f)) return;
    HitRecord x1 = load_primary_surface(s, position);
    uint selectSeed = pcg_hash(tid ^ (u.sampleIndex * 1999999973u) ^ 0x1b873593u);
    float3 difference;
    PTReservoir chosen = pt_temporal_merge(c, x1, view, position.w, t, y1, oldView, oldDepth, cap, selectSeed, u, settings, images,
                                           difference, SPECTRAL_CONTEXT(u, images));
    if (deep) pt[j] = chosen;
    else reservoirs[tid] = chosen;
    if (restir_pt_control_variates(u)) {
        float3 previousEstimate = source < pixels ? ptIndirect.read(uint2(source % u.width, source / u.width)).xyz
                                                  : float3(previousControls[source - pixels].estimate);
        pt_cv_temporal(deep ? deepControls[j] : controls[tid], c.M, min(t.M, cap), previousEstimate, difference);
    }
}

// ============================================================================
// PASS 2: Spatial Resampling & Full Path Tracing
// ============================================================================

kernel void shading_kernel(
    texture2d<float, access::read> gbufferPosDepth [[texture(0)]],
    texture2d<float, access::read> gbufferNormalMat [[texture(1)]],
    texture2d<float, access::read> gbufferAlbedoRough [[texture(2)]],
    texture2d<float, access::read> inSamplePosDir [[texture(3)]],
    texture2d<float, access::read> inSampleEmitPdf [[texture(4)]],
    texture2d<float, access::read> inReservoirWeights [[texture(5)]],
    texture2d<float, access::read_write> accumTexture [[texture(6)]],
    texture2d<float, access::write> sampleTexture [[texture(7)]],
    texture2d<float, access::read> inGIPosPdf [[texture(8)]],
    texture2d<float, access::read> inGINormal [[texture(9)]],
    texture2d<float, access::read> inGIRadiance [[texture(10)]],
    texture2d<float, access::read> inGIWeights [[texture(11)]],
    texture2d<float, access::read_write> oidnAlbedoAccum [[texture(12)]],
    texture2d<float, access::read_write> oidnNormalAccum [[texture(13)]],
    texture2d<float, access::read> ptIndirect [[texture(14)]],
    constant Uniforms &uniforms [[buffer(0)]],
    constant SurfaceSettings *surfaceSettings [[buffer(1)]],
    constant MaterialResources &materialImages [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    const device SPMISPixel *spmisCells [[buffer(4)]],
    const device SPMISSlot *spmisSlots [[buffer(5)]],
    const device SPMISChoice *spmisChoices [[buffer(6)]]
    SPECTRAL_BUFFERS,
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) return;
    Sampler seed = pixel_sampler(gid, uniforms);
    // The pixel's wavelengths (pass 1 derived the same ones). Reused DI and GI samples bring theirs.
    Wavelengths wl = SPECTRAL_WAVELENGTHS(wavelength_numbers(seed), uniforms, materialImages);

    float4 posDepth = gbufferPosDepth.read(gid);
    float3 radiance = float3(0.0f);
    float specularHitDistance = 0.0f;

    // Inspection views only need the G-buffer. Keep guide accumulation alive,
    // but skip all direct, indirect, and BSDF path work while they are shown.
    if (uniforms.viewportMode > 0) {
        if (uniforms.frameIndex <= 1) {
            float4 albedoGuide = gbufferAlbedoRough.read(gid);
            float4 normalGuide = gbufferNormalMat.read(gid);
            oidnAlbedoAccum.write(albedoGuide, gid);
            oidnNormalAccum.write(normalGuide, gid);
        }
        sampleTexture.write(float4(0), gid);
        return;
    }

    float aspect = float(uniforms.width) / float(uniforms.height);
    float fov_scale = tan((uniforms.cameraPos.w * 0.5f) * PI / 180.0f);
    float2 jitter = uniforms.jitter + 0.5f;
    float u = ((float(gid.x) + jitter.x) / float(uniforms.width)) * 2.0f - 1.0f;
    float v = ((float(gid.y) + jitter.y) / float(uniforms.height)) * 2.0f - 1.0f;
    v = -v;
    u *= aspect * fov_scale;
    v *= fov_scale;

    float3 camPos = uniforms.cameraPos.xyz;
    float3 forward = normalize(uniforms.cameraTarget.xyz - camPos);
    float3 right = normalize(cross(forward, uniforms.cameraUp.xyz));
    float3 up = cross(right, forward);
    Ray primaryRay;
    primaryRay.origin = camPos;
    primaryRay.direction = normalize(forward + u * right + v * up);
    lens_ray(primaryRay,forward,right,up,uniforms,seed);
    // Pass 1 continued this same stream into its candidates; spatial offsets
    // must not replay them. (Z-mode sampling events of the two passes are distinct.)
    decorrelate_shading_seed(seed.state);

    if (posDepth.w <= 0.0f) {
        if ((uniforms.sceneIndex == 0 || uniforms.sceneIndex == 6)) {
            radiance = environment_rgb(primaryRay.direction, uniforms, materialImages, wl);
        }
    } else {
        // Pass 1 traced and resolved this exact ray; reuse its hit.
        HitRecord primaryHit = load_primary_surface(primarySurfaces[gid.y * uniforms.width + gid.x], posDepth);
        float coneSpread = 2.0f * fov_scale / float(uniforms.height);
        float pathDistance = primaryHit.t;
        float3 pos = primaryHit.position;
        float3 norm = primaryHit.normal;
        Material mat = primaryHit.mat;
        // The path's throughput after the primary hit (spectral: four lanes, then the hero lane alone
        // past a dispersive vertex).
        Spectrum throughput = Spectrum(1.0f);
        if (mat.type == EMISSIVE) {
            radiance = emitter_rgb(mat.emission, wl);
        } else {
            // Camera rays see MaterialX emission directly; no light strategy samples them.
            radiance = emitter_rgb(openpbr_emission(mat, norm, -primaryRay.direction), wl);
            spectral_arrive(mat, throughput, wl);
            // ReSTIR PT (restir_pt_spatial_kernel) estimates paths of three or more vertices,
            // or, unified, every path of two or more (RESTIRPTE2026 Sec. 6.1).
            bool restirPT = uniforms.samplingMode == 0 && restir_pt_active(uniforms);
            bool unifiedPT = restirPT && restir_pt_unified(uniforms);
            if (unifiedPT) {
                // Direct light is a two-vertex path of the PT reservoir; no NEE or DI here.
            } else if (uniforms.samplingMode == 0 && mat.type == DIFFUSE) {
                // ReSTIR Spatial Reuse on Primary Surface
                float4 cPosDir = inSamplePosDir.read(gid);
                float4 cEmitPdf = inSampleEmitPdf.read(gid);
                float4 cWeights = inReservoirWeights.read(gid);

                LightSample selectedSample = {};
                selectedSample.position = cPosDir.xyz;
                selectedSample.isDirectional = uint(cPosDir.w);
                selectedSample.wi = (selectedSample.isDirectional == 1) ? selectedSample.position : normalize(selectedSample.position - pos);
                selectedSample.emission = cEmitPdf.xyz;
                selectedSample.pdf = cEmitPdf.w;
                selectedSample.u = cWeights.w;

                float p_hat_c = eval_restir_target_pdf(pos, norm, primaryRay.direction, mat, selectedSample, uniforms.sceneIndex, uniforms.light.w,materialImages, wl);
                float weightSum = p_hat_c * cWeights.z * cWeights.y;
                float M = cWeights.y;

                // Uniform mode draws fresh taps in each loop below; compatibility mode
                // selects independent neighbour sets for DI and for GI reuse. Stochastic
                // pairwise MIS (SPMIS2026) replaces both loops and their normalization.
                bool stochasticPairwise = uniforms.spatialNeighbors == 3;
                bool compatibilityGuided = uniforms.spatialNeighbors == 1;
                SpatialNeighbors neighbors;
                neighbors.count = 0;
                if (compatibilityGuided) {
                    neighbors = select_compatible_neighbors(gid, pos, norm, posDepth.w,
                        gbufferPosDepth, gbufferNormalMat, uniforms, seed.state);
                }
                int taps = stochasticPairwise ? 0 : compatibilityGuided ? int(neighbors.count) : UNIFORM_TAPS;
                for (int i = 0; i < taps; ++i) {
                    int2 nCoord = compatibilityGuided ? neighbors.coord[i] : uniform_neighbor(gid, seed.state);

                    if (nCoord.x >= 0 && nCoord.x < int(uniforms.width) &&
                        nCoord.y >= 0 && nCoord.y < int(uniforms.height)) {

                        float4 nPosDepth = gbufferPosDepth.read(uint2(nCoord));
                        float4 nNormMat = gbufferNormalMat.read(uint2(nCoord));

                        // The selection's score replaces the binary test.
                        if (compatibilityGuided || restir2020_compatible(posDepth, norm, mat.type, nPosDepth, nNormMat)) {
                            float4 nWeights = inReservoirWeights.read(uint2(nCoord));
                            if (nWeights.y > 0.0f && nWeights.z > 0.0f) {
                                float4 nPosDir = inSamplePosDir.read(uint2(nCoord));
                                float4 nEmitPdf = inSampleEmitPdf.read(uint2(nCoord));

                                LightSample nSample = {};
                                nSample.position = nPosDir.xyz;
                                nSample.isDirectional = uint(nPosDir.w);
                                nSample.wi = (nSample.isDirectional == 1) ? nSample.position : normalize(nSample.position - pos);
                                nSample.emission = nEmitPdf.xyz;
                                nSample.pdf = nEmitPdf.w;
                                nSample.u = nWeights.w;

                                float p_hat_n = eval_restir_target_pdf(pos, norm, primaryRay.direction, mat, nSample, uniforms.sceneIndex, uniforms.light.w,materialImages, wl);
                                float w_neighbor = p_hat_n * nWeights.z * nWeights.y;

                                weightSum += w_neighbor;
                                M += nWeights.y;
                                if (rand_decision(seed) * weightSum < w_neighbor) {
                                    selectedSample = nSample;
                                }
                            }
                        }
                    }
                }

                float final_p_hat = eval_restir_target_pdf(pos, norm, primaryRay.direction, mat, selectedSample, uniforms.sceneIndex, uniforms.light.w,materialImages, wl);
                if (compatibilityGuided && final_p_hat > 0.0f) {
                    // RESTIR2020 Alg. 6: Z counts every reused reservoir, empty ones
                    // included, whose pixel could have produced the selected sample.
                    M = cWeights.y;
                    for (uint i = 0; i < neighbors.count; ++i) {
                        uint2 q = uint2(neighbors.coord[i]);
                        float qM = inReservoirWeights.read(q).y;
                        if (qM > 0.0f && restir_di_in_support(gbufferPosDepth.read(q).xyz,
                                gbufferNormalMat.read(q).xyz, selectedSample)) M += qM;
                    }
                }
                float W = (M > 0.0f && final_p_hat > 0.0f) ? (weightSum / (M * final_p_hat)) : 0.0f;
                if (stochasticPairwise) {
                    selectedSample = spmis_di_reuse(gid, primaryHit, primaryRay.direction, cPosDir, cEmitPdf, cWeights,
                        gbufferPosDepth, inSamplePosDir, inSampleEmitPdf, inReservoirWeights, primarySurfaces,
                        spmisCells, spmisSlots, spmisChoices, uniforms, materialImages, seed.state, W, wl);
                }

                // Direct Lighting: ReSTIR DI vs. Standard MIS
                if (W > 0.0f) {
                    float3 dir = (selectedSample.isDirectional == 1) ? selectedSample.position : normalize(selectedSample.position - pos);

                    if (light_visible(pos, primaryHit.geometricNormal, selectedSample, uniforms.sceneIndex, materialImages, uniforms, primaryHit.error)) {
                        float cos_th = max(0.0f, dot(norm, dir));
                        Wavelengths sampleWavelengths = sample_wavelengths(selectedSample.u, wl);
                        Spectrum bsdf = eval_bsdf(mat, norm, -primaryRay.direction, dir, sampleWavelengths);
                        radiance += spectrum_rgb(bsdf * cos_th * light_spectrum(selectedSample, sampleWavelengths) * W * light_geometry(pos, selectedSample, uniforms.sceneIndex, uniforms.light.w,materialImages), sampleWavelengths);
                    }
                }

                // Spatial ReSTIR GI reuse for the first indirect diffuse vertex.
                // Pass 1 writes empty GI reservoirs when the depth excludes it; ReSTIR PT
                // binds placeholders instead.
                bool giEnabled = restir_gi_enabled(uniforms.cameraTarget.w) && !restirPT;
                float4 selectedGIPosPdf = giEnabled ? inGIPosPdf.read(gid) : float4(0.0f);
                float4 selectedGINormal = giEnabled ? inGINormal.read(gid) : float4(0.0f);
                Spectrum selectedGIRadiance = giEnabled ? gi_radiance(inGIRadiance.read(gid)) : Spectrum(0.0f);
                float4 currentGIWeights = giEnabled ? inGIWeights.read(gid) : float4(0.0f);
                float selectedGIU = currentGIWeights.w;
                float giTarget = selectedGINormal.w > 0.0f
                    ? eval_restir_gi_target(pos, norm, primaryRay.direction, mat,
                        selectedGIPosPdf.xyz, selectedGINormal.xyz, selectedGIRadiance, sample_wavelengths(selectedGIU, wl)) : 0.0f;
                float giWeightSum = giTarget * currentGIWeights.z * currentGIWeights.y;
                float giM = currentGIWeights.y;
                if (compatibilityGuided && giEnabled) {
                    neighbors = select_compatible_neighbors(gid, pos, norm, posDepth.w,
                        gbufferPosDepth, gbufferNormalMat, uniforms, seed.state);
                    taps = int(neighbors.count);
                }
                if (stochasticPairwise) taps = 0;
                for (int i = 0; i < taps && giEnabled; ++i) {
                    int2 nCoord = compatibilityGuided ? neighbors.coord[i] : uniform_neighbor(gid, seed.state);
                    if (nCoord.x < 0 || nCoord.x >= int(uniforms.width) ||
                        nCoord.y < 0 || nCoord.y >= int(uniforms.height)) continue;
                    float4 neighborPrimary = gbufferPosDepth.read(uint2(nCoord));
                    float4 neighborPrimaryNormal = gbufferNormalMat.read(uint2(nCoord));
                    if (!compatibilityGuided &&
                        !restir2020_compatible(posDepth, norm, mat.type, neighborPrimary, neighborPrimaryNormal)) continue;
                    float4 neighborWeights = inGIWeights.read(uint2(nCoord));
                    float4 neighborPosPdf = inGIPosPdf.read(uint2(nCoord));
                    float4 neighborNormal = inGINormal.read(uint2(nCoord));
                    if (neighborWeights.y <= 0.0f || neighborWeights.z <= 0.0f ||
                        neighborPosPdf.w <= 0.0f || neighborNormal.w <= 0.0f) continue;
                    if (!restir_gi_accepts_shift(pos, neighborPrimary.xyz,
                        neighborPosPdf.xyz, neighborNormal.xyz)) continue;
                    Spectrum neighborRadiance = gi_radiance(inGIRadiance.read(uint2(nCoord)));
                    float neighborTarget = eval_restir_gi_target(pos, norm, primaryRay.direction,
                        mat, neighborPosPdf.xyz, neighborNormal.xyz, neighborRadiance, sample_wavelengths(neighborWeights.w, wl));
                    float neighborWeight = neighborTarget * neighborWeights.z * neighborWeights.y;
                    giWeightSum += neighborWeight;
                    giM += neighborWeights.y;
                    if (rand_decision(seed) * giWeightSum < neighborWeight) {
                        selectedGIPosPdf = neighborPosPdf;
                        selectedGINormal = neighborNormal;
                        selectedGIRadiance = neighborRadiance;
                        selectedGIU = neighborWeights.w;
                    }
                }
                float finalGITarget = selectedGINormal.w > 0.0f
                    ? eval_restir_gi_target(pos, norm, primaryRay.direction, mat,
                        selectedGIPosPdf.xyz, selectedGINormal.xyz, selectedGIRadiance, sample_wavelengths(selectedGIU, wl)) : 0.0f;
                if (compatibilityGuided && giEnabled && finalGITarget > 0.0f) {
                    giM = currentGIWeights.y;
                    for (int i = 0; i < taps; ++i) {
                        uint2 q = uint2(neighbors.coord[i]);
                        float qM = inGIWeights.read(q).y;
                        if (qM > 0.0f && restir_gi_in_support(pos, gbufferPosDepth.read(q).xyz, gbufferNormalMat.read(q).xyz,
                                selectedGIPosPdf.xyz, selectedGINormal.xyz)) giM += qM;
                    }
                }
                float giW = giM > 0.0f && finalGITarget > 0.0f
                    ? giWeightSum / (giM * finalGITarget) : 0.0f;
                if (stochasticPairwise && giEnabled) {
                    spmis_gi_reuse(gid, primaryHit, primaryRay.direction, selectedGIPosPdf, selectedGINormal,
                        selectedGIRadiance, selectedGIU, currentGIWeights, gbufferPosDepth, inGIPosPdf, inGINormal, inGIRadiance,
                        inGIWeights, primarySurfaces, spmisCells, spmisSlots, spmisChoices, uniforms, materialImages, seed.state, giW, wl);
                }
                if (giEnabled && giW > 0.0f && gi_connection_visible(pos, primaryHit.geometricNormal,
                    selectedGIPosPdf.xyz, uniforms, materialImages, primaryHit.error)) {
                    float3 direction = normalize(selectedGIPosPdf.xyz - pos);
                    Wavelengths sampleWavelengths = sample_wavelengths(selectedGIU, wl);
                    Spectrum primaryBSDF = eval_bsdf(mat, norm, -primaryRay.direction, direction, sampleWavelengths);
                    float geometry = gi_geometry(pos, norm, selectedGIPosPdf.xyz, selectedGINormal.xyz);
                    radiance += spectrum_rgb(primaryBSDF * selectedGIRadiance * geometry * giW, sampleWavelengths);
                }
            } else if (mat.type != DIELECTRIC && !(mat.type == GLOSSY && mat.roughness < 0.02f) && uniforms.samplingMode != 3) {
                sampler_event(seed, 1u, Z_NEE);
                LightSample ls = sample_direct_light(pos, norm, uniforms, seed, materialImages);
                if (ls.pdf > 0.0f) {
                    if (light_visible(pos, primaryHit.geometricNormal, ls, uniforms.sceneIndex, materialImages, uniforms, primaryHit.error)) {
                        float cos_th = abs(dot(norm, ls.wi));
                        float bsdf_pdf;
                        Spectrum bsdf = eval_bsdf_with_pdf(mat, norm, -primaryRay.direction, ls.wi, bsdf_pdf, wl);
                        // Depth 1 has no BSDF continuation to share the direct integral.
                        bool useMIS = uniforms.samplingMode <= 1 && scattering_limit(uniforms.cameraTarget.w) > 0;
                        float weight = useMIS ? power_heuristic(ls.pdf, bsdf_pdf) : 1.0f;
                        radiance += spectrum_rgb(throughput * bsdf * cos_th * light_spectrum(ls, wl) * (weight / ls.pdf), wl);
                    }
                }
            }

            // Optional artistic ring-caustic boost
            if (uniforms.enableSMS == 1 && mat.type == DIFFUSE) {
                sampler_event(seed, 1u, Z_CAUSTIC);
                float3 caustic = sample_specular_manifold_caustic(pos, norm, uniforms, seed, materialImages);
                radiance += caustic * mat.albedo;
            }

            Ray currentRay = primaryRay;
            HitRecord currentHit = primaryHit;

            // Budget scattering events, not ideal reflections/refractions. Near
            // horizontal rays can cross the open ring dozens of times before
            // reaching the floor. Cutting that chain at 16 made its opening black.
            // Russian roulette terminates long specular chains without assigning
            // zero radiance at an arbitrary geometric depth (including closed loops).
            int scatteringDepth = 0;
            const int scatteringLimit = scattering_limit(uniforms.cameraTarget.w);
            bool emissionOnly = false;
            if (unifiedPT) {
                float4 indirect = ptIndirect.read(gid);
                radiance += indirect.rgb;
                if (mat.type == GLOSSY || mat.type == DIELECTRIC || mat.type == OPENPBR) specularHitDistance = indirect.w;
            } else if (restirPT) {
                radiance += ptIndirect.read(gid).rgb;
            }
            for (int bounce = 1; !unifiedPT; ++bounce) {
                float3 nextDirection;
                Spectrum bsdfWeight;
                float bsdfPDF;
                bool previousDelta = is_delta(currentHit.mat);
                if (!previousDelta && scatteringDepth >= scatteringLimit) {
                    // Other strategies light the last vertex with NEE. BSDF-only
                    // paths take one final continuation that may only reach emission.
                    if (uniforms.samplingMode != 3 || emissionOnly) break;
                    emissionOnly = true;
                }
                if (!previousDelta) ++scatteringDepth;
                bool previousNEE = !previousDelta && uniforms.samplingMode != 3;
                // Primary diffuse DI reservoirs estimate the full direct integral.
                // Only conventional NEE vertices have complementary power weights.
                bool previousMIS = uniforms.samplingMode == 1 ||
                    (uniforms.samplingMode == 0 && (bounce > 1 || currentHit.mat.type != DIFFUSE));
                // Z mode: vertex `bounce` scatters (its BSDF event); rec below is vertex bounce + 1.
                sampler_event(seed, uint(bounce), Z_BSDF);
                if (!sample_bsdf(currentHit.mat, currentHit.normal, currentRay.direction,
                                 currentHit.front_face, seed, nextDirection, bsdfWeight, bsdfPDF, wl)) break;
                throughput *= bsdfWeight;
                if (!all(isfinite(throughput)) || spectrum_max(throughput) <= 0.0f) break;
                float3 previousPosition = currentHit.position;
                float3 previousNormal = currentHit.normal;
                float3 offsetNormal = currentHit.geometricNormal;
                currentRay.origin = ray_origin(previousPosition,offsetNormal,nextDirection,uniforms,currentHit.error);
                currentRay.direction = nextDirection;

                HitRecord rec;
                bool hit = trace_scene(currentRay, uniforms.sceneIndex, rec, materialImages, uniforms);
                if (hit) {
                    pathDistance += rec.t;
                    if (!previousDelta) coneSpread = max(coneSpread, currentHit.mat.type == DIFFUSE ? 0.25f : currentHit.mat.roughness * 0.15f);
                    resolve_material(rec, currentRay, uniforms, surfaceSettings, materialImages, pathDistance * coneSpread);
                }
                if (bounce == 1 && (mat.type == GLOSSY || mat.type == DIELECTRIC || mat.type == OPENPBR)) {
                    specularHitDistance = hit ? rec.t : 10000.0f;
                }
                if (!hit) {
                    if ((uniforms.sceneIndex == 0 || uniforms.sceneIndex == 6)) {
                        float lightPDF = eval_environment_pdf(nextDirection, previousNormal, uniforms,materialImages);
                        float weight = emission_weight(previousDelta, previousNEE, previousMIS, bsdfPDF, lightPDF);
                        radiance += spectrum_rgb(throughput * weight * environment_spectrum(nextDirection, uniforms, materialImages, wl), wl);
                    }
                    break;
                }
                if (rec.mat.type == EMISSIVE) {
                    float lightPDF = eval_light_pdf(previousPosition, rec.position, rec.mat, uniforms,materialImages,rec.triangle);
                    float weight = emission_weight(previousDelta, previousNEE, previousMIS, bsdfPDF, lightPDF);
                    radiance += spectrum_rgb(throughput * weight * emitter_spectrum(rec.mat.emission, wl), wl);
                    break;
                }
                // A MaterialX emitter also scatters: add its emission with the same MIS
                // weight as a light hit, then continue the path. Only the imported emitter
                // list (scene 6) proposes such surfaces to NEE; elsewhere lightPDF is zero.
                float3 surfaceEmission = openpbr_emission(rec.mat, rec.normal, -currentRay.direction);
                if (any(surfaceEmission > 0.0f)) {
                    float lightPDF = uniforms.sceneIndex == 6
                        ? eval_light_pdf(previousPosition, rec.position, rec.mat, uniforms, materialImages, rec.triangle) : 0.0f;
                    float weight = emission_weight(previousDelta, previousNEE, previousMIS, bsdfPDF, lightPDF);
                    radiance += spectrum_rgb(throughput * weight * emitter_spectrum(surfaceEmission, wl), wl);
                }
                if (emissionOnly) break;
                // The x2 emission above is a two-vertex path; ReSTIR PT holds the longer ones.
                if (restirPT) break;
                spectral_arrive(rec.mat, throughput, wl);

                bool restirGISecondary = uniforms.samplingMode == 0 && mat.type == DIFFUSE &&
                    bounce == 1 && rec.mat.type == DIFFUSE;
                if (!is_delta(rec.mat) && uniforms.samplingMode != 3 && !restirGISecondary) {
                    sampler_event(seed, uint(bounce) + 1u, Z_NEE);
                    LightSample ls = sample_direct_light(rec.position, rec.normal, uniforms, seed, materialImages);
                    if (light_visible(rec.position, rec.geometricNormal, ls, uniforms.sceneIndex, materialImages, uniforms, rec.error)) {
                        float cosine = abs(dot(rec.normal, ls.wi));
                        float pdf;
                        Spectrum bsdf = eval_bsdf_with_pdf(rec.mat, rec.normal, -currentRay.direction, ls.wi, pdf, wl);
                        // At the last vertex there will be no BSDF light sample.
                        bool useMIS = uniforms.samplingMode <= 1 && scatteringDepth < scatteringLimit;
                        float weight = useMIS ? power_heuristic(ls.pdf, pdf) : 1.0f;
                        radiance += spectrum_rgb(throughput * bsdf * cosine * light_spectrum(ls, wl) * weight / ls.pdf, wl);
                    }
                }
                currentHit = rec;
                if (bounce > 3) {
                    // A higher survival ceiling reduces variance in long mirror
                    // chains. Division by survival preserves their expected energy.
                    float survival = clamp(spectrum_max(throughput),
                                           0.05f, is_delta(currentHit.mat) ? 0.99f : 0.95f);
                    sampler_event(seed, uint(bounce) + 1u, Z_ROULETTE);
                    if (rand_f(seed) >= survival) break;
                    throughput /= survival;
                }
            }
        }
    }

    if (uniforms.enableFog == 1) {
        radiance = apply_camera_fog(radiance, primaryRay, posDepth.w > 0.0f ? posDepth.w : 100.0f, uniforms, seed, materialImages, wl);
    }

    if (isnan(radiance.r) || isnan(radiance.g) || isnan(radiance.b) ||
        isinf(radiance.r) || isinf(radiance.g) || isinf(radiance.b)) {
        radiance = float3(0.0f);
    }
    // ReSTCV estimates can be negative in single frames; the progressive average keeps them so
    // that it converges without the clamp's upward bias. MetalFX receives the clamped frame.
#if VIBE_SPECTRAL
    // Spectral samples are often outside the sRGB gamut (colour noise of four wavelengths, narrow-band
    // light): negative channels stay in the progressive average, which then converges to the
    // integral's colour. Presentation, exports and OIDN clamp, and MetalFX receives the clamped frame.
    float3 accumulated = radiance;
#else
    float3 accumulated = restir_pt_control_variates(uniforms) && uniforms.samplingMode == 0 ? radiance : max(radiance, float3(0.0f));
#endif
    radiance = max(radiance, float3(0.0f));

    // OIDN auxiliary inputs must use the same jitter/reconstruction filter as
    // beauty. Accumulate them with the identical running box filter instead of
    // passing the final stochastic G-buffer sample.
    float4 albedoGuide = gbufferAlbedoRough.read(gid);
    float4 normalGuide = gbufferNormalMat.read(gid);
    if (uniforms.frameIndex > 1) {
        float3 previousAlbedo = oidnAlbedoAccum.read(gid).xyz;
        float3 previousNormal = oidnNormalAccum.read(gid).xyz;
        if (all(isfinite(previousAlbedo))) {
            albedoGuide.xyz = previousAlbedo +
                (albedoGuide.xyz - previousAlbedo) / float(uniforms.frameIndex);
        }
        if (all(isfinite(previousNormal))) {
            normalGuide.xyz = previousNormal +
                (normalGuide.xyz - previousNormal) / float(uniforms.frameIndex);
        }
    }
    oidnAlbedoAccum.write(albedoGuide, gid);
    oidnNormalAccum.write(normalGuide, gid);

    // MetalFX consumes the current noisy frame, never the progressively averaged image.
    sampleTexture.write(float4(radiance, specularHitDistance), gid);
    float3 average = accumulated;
    if (uniforms.frameIndex > 1) {
        float3 previous = accumTexture.read(gid).rgb;
        if (all(isfinite(previous))) average = previous + (accumulated - previous) / float(uniforms.frameIndex);
    }
    accumTexture.write(float4(average, 1.0f), gid);
}


// REFERENCES.md: SRGB1999. Exact piecewise sRGB OETF (IEC 61966-2-1) for
// display-referred outputs tagged sRGB (viewport layer and PNG); input is clamped to [0, 1].
float3 srgb_encode(float3 c) {
    c = clamp(c, 0.0f, 1.0f);
    return select(1.055f * pow(c, float3(1.0f / 2.4f)) - 0.055f, 12.92f * c, c <= 0.0031308f);
}

// REFERENCES.md: HILLFIT. Uses Hill's rational fit coefficients without the
// upstream ACES color matrices; this is not a complete ACES transform.
float3 tonemap(float3 color) {
    float3 a = color * (color + 0.0245786f) - 0.000090537f;
    float3 b = color * (0.983729f * color + 0.4329510f) + 0.238081f;
    return srgb_encode(a / b);
}

// Noise-free material features along an ideal specular path. These auxiliary
// rays never add radiance; they describe the geometry visible in a reflection.
struct DenoiserMaterialGuide { float3 diffuse; float3 specular; };

DenoiserMaterialGuide trace_denoiser_material(Ray ray, constant Uniforms &u,
    constant SurfaceSettings *surfaceSettings, constant MaterialResources &materialImages) {
    float3 tint = float3(1.0f);
    DenoiserMaterialGuide guide = {};
    // Features need to see through the same long ring reflections as radiance.
    // This finite feature-only budget falls back to specular tint; it never
    // terminates or darkens the actual light path.
    for (int bounce = 0; bounce < 256; ++bounce) {
        HitRecord hit;
        if (!trace_scene(ray, u.sceneIndex, hit, materialImages, u)) {
            float3 sky = (u.sceneIndex == 0 || u.sceneIndex == 6) ? eval_environment(ray.direction, u, materialImages) : float3(0);
            guide.diffuse = tint * sky / max(1.0f, max(sky.x, max(sky.y, sky.z)));
            return guide;
        }
        resolve_material(hit, ray, u, surfaceSettings, materialImages, hit.t * 2.0f * tan(u.cameraPos.w * PI / 360.0f) / float(u.height));
        if (hit.mat.type == OPENPBR) {
            guide.diffuse = tint * hit.mat.albedo * (1.0f - hit.mat.metalness) * (1.0f - hit.mat.transmission);
            guide.specular = tint * mix(float3(0.04f), hit.mat.albedo, hit.mat.metalness);
            return guide;
        }
        if (hit.mat.type == DIFFUSE) { guide.diffuse = tint * hit.mat.albedo; return guide; }
        if (hit.mat.type == EMISSIVE) { guide.diffuse = tint; return guide; }
        if (hit.mat.type == GLOSSY && hit.mat.roughness >= 0.15f) {
            guide.specular = tint * conductor_fresnel(hit.mat.albedo, max(0.0f, dot(-ray.direction, hit.normal)));
            return guide;
        }
        float3 next;
        if (hit.mat.type == DIELECTRIC) {
            float eta = hit.front_face ? 1.0f / hit.mat.ior : hit.mat.ior;
            next = refract(ray.direction, hit.normal, eta);
            if (dot(next, next) < 1e-8f) next = reflect(ray.direction, hit.normal);
            tint *= hit.mat.albedo;
        } else {
            tint *= conductor_fresnel(hit.mat.albedo, max(0.0f, dot(-ray.direction, hit.normal)));
            next = reflect(ray.direction, hit.normal);
        }
        ray.origin = ray_origin(hit.position,hit.geometricNormal,next,u,hit.error);
        ray.direction = normalize(next);
    }
    guide.specular = tint;
    return guide;
}

// Pack the renderer's primary-surface G-buffer into MetalFX's required formats.
// Motion is previous-minus-current in pixels, excluding projection jitter.
kernel void metalfx_guides_kernel(
    texture2d<float, access::read> samples [[texture(0)]],
    texture2d<float, access::read> positions [[texture(1)]],
    texture2d<float, access::read> normals [[texture(2)]],
    texture2d<float, access::read> materials [[texture(3)]],
    texture2d<float, access::write> color [[texture(4)]],
    texture2d<float, access::write> depth [[texture(5)]],
    texture2d<float, access::write> motion [[texture(6)]],
    texture2d<float, access::write> diffuse [[texture(7)]],
    texture2d<float, access::write> specular [[texture(8)]],
    texture2d<float, access::write> worldNormal [[texture(9)]],
    texture2d<float, access::write> roughness [[texture(10)]],
    texture2d<float, access::write> hitDistance [[texture(11)]],
    texture2d<float, access::write> denoiseMask [[texture(12)]],
    constant Uniforms &u [[buffer(0)]],
    constant SurfaceSettings *surfaceSettings [[buffer(1)]],
    constant MaterialResources &materialImages [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.width || gid.y >= u.height) return;
    float4 sample = samples.read(gid), p = positions.read(gid);
    float4 n = normals.read(gid), material = materials.read(gid);
    float3 normal = float3(0, 0, 1), diffuseAlbedo = float3(0), specularAlbedo = float3(0);
    // Reversed Z: the sky and misses sit at the far plane, depth 0.
    float rough = 1.0f, z = 0.0f;
    float4 currentClip, previousClip;
    if (p.w > 0.0f) {
        normal = normalize(n.xyz);
        float3 guideCamera=u.cameraPos.xyz;
        if(u.lens.x>0) {
            // The lens sample of pass 1 (lens_ray): the same sampler and event.
            Sampler guideSeed=pixel_sampler(gid,u);sampler_event(guideSeed,0u,Z_LENS);
            float2 q=rand_f2(guideSeed);float radius=sqrt(q.x)*u.lens.x,angle=TWO_PI*q.y;
            float3 f=normalize(u.cameraTarget.xyz-u.cameraPos.xyz),right=normalize(cross(f,u.cameraUp.xyz)),up=cross(right,f);
            guideCamera+=radius*(cos(angle)*right+sin(angle)*up);
        }
        float3 wo = normalize(guideCamera - p.xyz);
        // The G-buffer holds the shading normal. Specular guide rays offset along the
        // primary hit's geometric normal and rounding bound, which pass 1 cached beside
        // the full-precision position (as the shading pass uses them): no re-trace, and
        // only those two cache fields are read, only for the pixels that need them.
        float3 offsetPosition = p.xyz, offsetNormal = normal; float offsetError = 0.0f;
        if ((int(n.w) == GLOSSY && material.w < 0.15f) || int(n.w) == DIELECTRIC) {
            const device PrimarySurface &surface = primarySurfaces[gid.y * u.width + gid.x];
            offsetNormal = surface.geometricNormal; offsetError = surface.error;
        }
        if (int(n.w) == DIFFUSE) diffuseAlbedo = material.xyz;
        if (int(n.w) == GLOSSY) {
            rough = clamp(material.w, 0.0f, 1.0f);
            specularAlbedo = conductor_fresnel(material.xyz, max(0.0f, dot(normal, wo)));
            if (rough < 0.15f) {
                float3 mirror = reflect(-wo, normal);
                Ray reflected = { ray_origin(offsetPosition,offsetNormal,mirror,u,offsetError), mirror };
                DenoiserMaterialGuide guide = trace_denoiser_material(reflected, u, surfaceSettings, materialImages);
                diffuseAlbedo = specularAlbedo * guide.diffuse;
                specularAlbedo *= guide.specular;
            }
        }
        if (int(n.w) == OPENPBR) {
            Material resolved = load_primary_surface(primarySurfaces[gid.y * u.width + gid.x], p).mat;
            rough = resolved.roughness;
            diffuseAlbedo = resolved.albedo * (1.0f - resolved.metalness) * (1.0f - resolved.transmission);
            float f0 = pow((resolved.ior - 1.0f) / (resolved.ior + 1.0f), 2.0f);
            specularAlbedo = conductor_fresnel(mix(float3(f0), resolved.albedo, resolved.metalness), max(0.0f, dot(normal, wo)));
        }
        if (int(n.w) == DIELECTRIC) {
            rough = 0.0f;
            float ior = abs(material.w);
            float eta = material.w > 0 ? 1.0f / ior : ior;
            float cosI = max(0.0f, dot(normal, wo));
            float f0 = (1.0f - ior) / (1.0f + ior);
            float fresnel = f0 * f0 + (1.0f - f0 * f0) * pow(1.0f - cosI, 5.0f);
            float3 mirror = reflect(-wo, normal);
            Ray reflected = { ray_origin(offsetPosition,offsetNormal,mirror,u,offsetError), mirror };
            DenoiserMaterialGuide r = trace_denoiser_material(reflected, u, surfaceSettings, materialImages);
            float3 transmitted = refract(-wo, normal, eta);
            DenoiserMaterialGuide t = r;
            if (dot(transmitted, transmitted) > 1e-8f) {
                Ray refracted = { ray_origin(offsetPosition,offsetNormal,transmitted,u,offsetError), normalize(transmitted) };
                t = trace_denoiser_material(refracted, u, surfaceSettings, materialImages);
            } else fresnel = 1.0f;
            diffuseAlbedo = material.xyz * mix(t.diffuse, r.diffuse, fresnel);
            specularAlbedo = material.xyz * mix(t.specular, r.specular, fresnel);
        }
        currentClip = u.currentViewProj * float4(p.xyz, 1.0f);
        previousClip = u.prevViewProj * float4(p.xyz, 1.0f);
        z = clamp(currentClip.z / max(1e-6f, currentClip.w), 0.0f, 1.0f);
    } else {
        float2 uv = (float2(gid) + 0.5f + u.jitter) / float2(u.width, u.height) * 2.0f - 1.0f;
        float3 forward = normalize(u.cameraTarget.xyz - u.cameraPos.xyz);
        float3 right = normalize(cross(forward, u.cameraUp.xyz));
        float3 up = cross(right, forward);
        float scale = tan(u.cameraPos.w * PI / 360.0f);
        float3 direction = normalize(forward + right * uv.x * (float(u.width) / float(u.height)) * scale - up * uv.y * scale);
        // Homogeneous directions remove camera translation from sky motion.
        currentClip = u.currentViewProj * float4(direction, 0.0f);
        previousClip = u.prevViewProj * float4(direction, 0.0f);
        normal = -direction;
    }
    float2 velocity = float2(0.0f);
    if (currentClip.w > 1e-6f && previousClip.w > 1e-6f) {
        velocity = (previousClip.xy / previousClip.w - currentClip.xy / currentClip.w) *
            float2(0.5f, -0.5f) * float2(u.width, u.height);
    }
    // Half-float packing affects only presentation, never the raw HDR accumulation.
    color.write(float4(clamp(sample.rgb, 0.0f, 65504.0f), 1.0f), gid);
    depth.write(float4(z), gid);
    motion.write(float4(clamp(velocity, -65504.0f, 65504.0f), 0, 0), gid);
    diffuse.write(float4(diffuseAlbedo, 1), gid);
    specular.write(float4(specularAlbedo, 1), gid);
    worldNormal.write(float4(normal, 0), gid);
    roughness.write(float4(rough), gid);
    hitDistance.write(float4(sample.a), gid);
    // Directly visible emitters and the analytic sky have no path-sampling noise.
    // Preserve them instead of asking the radiance denoiser to reconstruct them.
    denoiseMask.write(float4(u.lens.x<=0 && (p.w <= 0.0f || int(n.w) == EMISSIVE) ? 1.0f : 0.0f), gid);
}

kernel void pick_kernel(constant Uniforms &u [[buffer(0)]],
    constant MaterialResources &images [[buffer(2)]], device uint *result [[buffer(3)]],
    constant float2 &pixel [[buffer(4)]]) {
    float2 uv=pixel*2.0f-1.0f;
    float3 f=normalize(u.cameraTarget.xyz-u.cameraPos.xyz), right=normalize(cross(f,u.cameraUp.xyz)), up=cross(right,f);
    float scale=tan(u.cameraPos.w*PI/360.0f);
    Ray ray={u.cameraPos.xyz,normalize(f+right*uv.x*(float(u.width)/u.height)*scale-up*uv.y*scale)};
    HitRecord hit;
    result[0]=trace_scene(ray,u.sceneIndex,hit,images,u) && (hit.mat.type!=EMISSIVE || hit.objectID>=64) ? hit.objectID : 0xffffffffu;
}

#if VIBE_SPECTRAL
// The scene's wavelength-sampling inverse CDF (buffer 29), one thread, run when
// the scene's illuminants change: a preset's generated table when one weight is set, else the
// weighted mixture of the presets' sampling densities, (1 - 0.1) S s / int(S s) + 0.1 s / int(s) with
// s = |r| + |g| + |b| of the linear-sRGB CMFs, inverted exactly for its 1 nm piecewise-linear form
// (scripts/generate_spectral_tables.py: sampling_density, mixture_density, inverse_cdf). Scratch
// space for the density and its CDF follows the table.
kernel void spectral_icdf_kernel(device float *table [[buffer(29)]], constant float4 *weights [[buffer(0)]],
                                 uint tid [[thread_position_in_grid]]) {
    if (tid != 0u) return;
    device float4 *cmf = (device float4 *)table + SPECTRAL_CMF_TABLE;
    device float4 *basis = (device float4 *)table + SPECTRAL_BASIS;
    for (uint i = 0u; i < VIBE_SPECTRAL_SAMPLES; ++i) {
        float phase = vibe_fourier_phase(VIBE_LAMBDA_MIN + float(i));
        cmf[i] = float4(VIBE_XYZ_TO_LINEAR_SRGB * float3(vibe_cmf_x[i], vibe_cmf_y[i], vibe_cmf_z[i]), cos(phase));
        // The emission basis (spectral_emission): the six saturated corners R, G, B and C, M, Y, whose
        // Lagrange multipliers the host solved (weights[2 ..]).
        float corner[6];
        for (uint k = 0u; k < 6u; ++k) corner[k] = vibe_fourier_reflectance(weights[2u + k].xyz, phase);
        basis[2u * i] = float4(corner[0], corner[1], corner[2], 0.0f);
        basis[2u * i + 1u] = float4(corner[3], corner[4], corner[5], 0.0f);
    }
    device float *density = table + SPECTRAL_SCRATCH;
    device float *cdf = density + VIBE_SPECTRAL_SAMPLES;
    float w[6] = { weights[0].x, weights[0].y, weights[0].z, weights[0].w, weights[1].x, weights[1].y };
    uint used = 0u, last = 1u;
    float total = 0.0f;
    for (uint k = 0u; k < VIBE_ILLUMINANT_COUNT; ++k) if (w[k] > 0.0f) { ++used; last = k; total += w[k]; }
    if (used <= 1u) {
        for (uint i = 0u; i <= VIBE_ICDF_SEGMENTS; ++i) table[i] = vibe_wavelength_icdf[last][i];
        return;
    }
    float plain = 0.0f, weighted[6] = { 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };
    for (uint i = 0u; i < VIBE_SPECTRAL_SAMPLES; ++i) {
        float3 c = VIBE_XYZ_TO_LINEAR_SRGB * float3(vibe_cmf_x[i], vibe_cmf_y[i], vibe_cmf_z[i]);
        float s = abs(c.x) + abs(c.y) + abs(c.z);
        density[i] = s;
        float edge = i == 0u || i + 1u == VIBE_SPECTRAL_SAMPLES ? 0.5f : 1.0f;   // trapezoid weights
        plain += edge * s;
        for (uint k = 0u; k < VIBE_ILLUMINANT_COUNT; ++k) weighted[k] += edge * s * vibe_illuminant_spd[k][i];
    }
    for (uint i = 0u; i < VIBE_SPECTRAL_SAMPLES; ++i) {
        float s = density[i], p = 0.0f;
        for (uint k = 0u; k < VIBE_ILLUMINANT_COUNT; ++k)
            if (w[k] > 0.0f) p += w[k] / total * (0.9f * vibe_illuminant_spd[k][i] * s / weighted[k] + 0.1f * s / plain);
        density[i] = p;
    }
    cdf[0] = 0.0f;
    for (uint i = 1u; i < VIBE_SPECTRAL_SAMPLES; ++i) cdf[i] = cdf[i - 1u] + 0.5f * (density[i - 1u] + density[i]);
    float sum = cdf[VIBE_SPECTRAL_SAMPLES - 1u];
    table[0] = VIBE_LAMBDA_MIN;
    uint j = 0u;
    for (uint n = 1u; n < VIBE_ICDF_SEGMENTS; ++n) {
        float y = sum * float(n) / float(VIBE_ICDF_SEGMENTS);
        while (j + 2u < VIBE_SPECTRAL_SAMPLES && cdf[j + 1u] < y) ++j;
        float p0 = density[j], dp = density[j + 1u] - p0, rest = y - cdf[j];
        float t = abs(dp) < 1e-6f * max(p0, 1e-30f) ? rest / max(p0, 1e-30f)
                                                    : (-p0 + sqrt(max(p0 * p0 + 2.0f * dp * rest, 0.0f))) / dp;
        table[n] = max(VIBE_LAMBDA_MIN + float(j) + clamp(t, 0.0f, 1.0f), nextafter(table[n - 1u], INFINITY));
    }
    table[VIBE_ICDF_SEGMENTS] = max(VIBE_LAMBDA_MAX, nextafter(table[VIBE_ICDF_SEGMENTS - 1u], INFINITY));
}

// Grid refinement, run once when the grid is loaded (PathTracerRenderer.refineSpectralGrid).
// The linear sRGB of a reflectance under D65 at 1 nm (the generator's rgb_of_lagrange), and with
// Jacobian rows (r, g, b) x (L0, L1, L2) for Levenberg-Marquardt (solve_lagrange).
float3 spectral_rgb_of_lagrange(float3 L, thread float3x3 *jacobian) {
    float3 rgb = float3(0.0f);
    float3 j0 = float3(0.0f), j1 = float3(0.0f), j2 = float3(0.0f);
    for (uint i = 0u; i < VIBE_SPECTRAL_SAMPLES; ++i) {
        float3 w = VIBE_XYZ_TO_LINEAR_SRGB * float3(vibe_cmf_x[i], vibe_cmf_y[i], vibe_cmf_z[i])
            * vibe_illuminant_spd[VIBE_ILLUMINANT_D65][i];
        float x = cos(vibe_fourier_phase(VIBE_LAMBDA_MIN + float(i)));
        float c1 = 2.0f * x, c2 = 2.0f * (2.0f * x * x - 1.0f);
        float s = L.x + L.y * c1 + L.z * c2;
        rgb += w * (atan(s) * 0.318309886f + 0.5f);
        if (jacobian) {
            float3 d = w * (0.318309886f / (1.0f + s * s));
            j0 += d; j1 += d * c1; j2 += d * c2;
        }
    }
    if (jacobian) *jacobian = float3x3(j0, j1, j2);   // columns: d rgb / d L0, L1, L2
    return rgb;
}
float3x3 spectral_inverse3(float3x3 m) {
    float3 a = m[0], b = m[1], c = m[2];
    float3 r0 = cross(b, c), r1 = cross(c, a), r2 = cross(a, b);
    return transpose(float3x3(r0, r1, r2)) / dot(a, r0);
}
// The round trip of one 8-bit code through the unrefined conversion, in 8-bit steps.
float spectral_code_error(uint3 code, thread const Wavelengths &wl) {
    float3 c = spectral_eotf(float3(code) / 255.0f);
    if (c.x == c.y && c.y == c.z) return 0.0f;
    float3 code85 = spectral_code85(c);
    float3 L = vibe_fourier_lagrange(spectral_moments_coarse(c, code85, spectral_cell(code85), wl));
    float3 rgb = saturate(spectral_rgb_of_lagrange(L, nullptr));
    float3 back = select(1.055f * pow(rgb, float3(1.0f / 2.4f)) - 0.055f, 12.92f * rgb, rgb <= 0.0031308f) * 255.0f;
    float3 d = abs(back - float3(code));
    return max(d.x, max(d.y, d.z));
}
kernel void spectral_refine_flags_kernel(constant SpectralScene &scene [[buffer(27)]], const device float4 *grid [[buffer(28)]],
                                         device atomic_uint *flags [[buffer(0)]], uint tid [[thread_position_in_grid]]) {
    if (tid >= 16777216u) return;
    uint3 code = uint3(tid >> 16, (tid >> 8) & 255u, tid & 255u);
    Wavelengths wl;
    wl.scene = &scene; wl.grid = grid;
    if (spectral_code_error(code, wl) <= 0.35f) return;
    uint3 i = spectral_cell(spectral_code85(spectral_eotf(float3(code) / 255.0f)));
    atomic_store_explicit(&flags[(i.x * 85u + i.y) * 85u + i.z], 1u, memory_order_relaxed);
}
// Exact moments of a refined cell's 64 codes: Levenberg-Marquardt in Lagrange space from the
// interpolated start (the generator's solve_lagrange, in float32), then the moments by the
// generator's 1024-node midpoint rule (moments_of_lagrange).
kernel void spectral_refine_solve_kernel(constant SpectralScene &scene [[buffer(27)]], device float4 *grid [[buffer(28)]],
                                         const device uint *cells [[buffer(0)]], constant uint &count [[buffer(1)]],
                                         uint tid [[thread_position_in_grid]]) {
    if (tid >= 64u * count) return;
    uint slot = tid / 64u, entry = tid % 64u, cell = cells[slot];
    uint3 i = uint3(cell / (85u * 85u), (cell / 85u) % 85u, cell % 85u);
    uint3 code = min(3u * i + uint3(entry / 16u, (entry / 4u) % 4u, entry % 4u), uint3(255u));
    float3 c = spectral_eotf(float3(code) / 255.0f);
    float3 target = clamp(c, VIBE_MOMENT_EPSILON, 1.0f - VIBE_MOMENT_EPSILON);
    Wavelengths wl;
    wl.scene = &scene; wl.grid = grid;
    float3 L = vibe_fourier_lagrange(spectral_moments_coarse(c, spectral_code85(c), i, wl));
    float3x3 J;
    float3 f = target - spectral_rgb_of_lagrange(L, &J);
    float error = max(abs(f.x), max(abs(f.y), abs(f.z))), mu = 0.0f;
    for (uint n = 0u; n < 40u && error > 2e-7f; ++n) {
        float3x3 normal = transpose(J) * J;
        float3 gradient = transpose(J) * f;
        bool improved = false;
        for (uint k = 0u; k < 24u && !improved; ++k) {
            float3x3 damped = normal;
            damped[0][0] *= 1.0f + mu; damped[1][1] *= 1.0f + mu; damped[2][2] *= 1.0f + mu;
            if (!(abs(determinant(damped)) > 0.0f)) break;
            float3 trial = L + spectral_inverse3(damped) * gradient;
            float3x3 Jt;
            float3 ft = target - spectral_rgb_of_lagrange(trial, &Jt);
            float et = max(abs(ft.x), max(abs(ft.y), abs(ft.z)));
            if (et < error) { L = trial; J = Jt; f = ft; error = et; mu = mu > 1e-12f ? mu * 0.1f : 0.0f; improved = true; }
            else mu = max(mu * 10.0f, 1e-6f);
        }
        if (!improved) break;
    }
    float3 m = float3(0.0f);
    for (uint k = 0u; k < 1024u; ++k) {
        float x = cos(-PI + (float(k) + 0.5f) * (PI / 1024.0f));
        float g = atan(L.x + 2.0f * L.y * x + 2.0f * L.z * (2.0f * x * x - 1.0f)) * 0.318309886f + 0.5f;
        m += g * float3(1.0f, x, 2.0f * x * x - 1.0f);
    }
    grid[SPECTRAL_REFINED + 64u * slot + entry] = float4(m / 1024.0f, 0.0f);
}
#endif

kernel void present_kernel(
    texture2d<float, access::read> hdr [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    texture2d<float, access::read> raw [[texture(2)]],
    texture2d<float, access::read> albedo [[texture(3)]],
    texture2d<float, access::read> normalMaterial [[texture(4)]],
    texture2d<float, access::read> positionDepth [[texture(5)]],
    constant float4 *display [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    uint2 source=min(uint2(float2(gid)*float2(hdr.get_width(),hdr.get_height())/float2(output.get_width(),output.get_height())),uint2(hdr.get_width()-1,hdr.get_height()-1));
    uint viewportMode=uint(display[0].z+0.5f);
    if(viewportMode==1) {
        float3 c=clamp(albedo.read(source).rgb,0.0f,1.0f);
        output.write(float4(srgb_encode(c),1),gid); return;
    }
    if(viewportMode==2) {
        float4 n=normalMaterial.read(source);
        float3 c=n.w<0.0f ? float3(0) : normalize(n.xyz)*0.5f+0.5f;
        output.write(float4(c,1),gid); return;
    }
    if(viewportMode==3) {
        float d=positionDepth.read(source).w;
        float c=d>0.0f ? clamp(log2(1.0f+d)/8.0f,0.0f,1.0f) : 0.0f;
        output.write(float4(c,c,c,1),gid); return;
    }
    if(viewportMode==4) {
        float4 n=normalMaterial.read(source);
        float rough=clamp(albedo.read(source).w,0.0f,1.0f);
        float type=n.w;
        float3 palette=type<0.0f?float3(0):type<0.5f?float3(0.25f,0.65f,1):type<1.5f?float3(1,0.65f,0.15f):type<2.5f?float3(0.35f,0.9f,0.55f):type<3.5f?float3(1,0.25f,0.25f):float3(0.75f,0.35f,1);
        output.write(float4(mix(palette,float3(rough),0.3f),1),gid); return;
    }
    bool useRaw=display[0].w>0 && float(gid.x)/output.get_width()<display[0].w;
    float3 c=(useRaw?raw.read(source).rgb:hdr.read(source).rgb)*exp2(display[0].x)*display[1].rgb;
    // Radiance is nonnegative: negative or NaN denoiser output must not reach
    // the rational curves, which map negative input to bright values. Every
    // curve saturates below the half-float limit, which also keeps +inf finite.
    c=select(float3(0.0f),min(c,65504.0f),c>0.0f);
    if(display[0].y<0.5f) c=tonemap(c);
    // REFERENCES.md: REINHARD2002; per-channel global curve, without automatic key.
    else if(display[0].y<1.5f) c=srgb_encode(c/(1+c));
    else c=srgb_encode(c);
    output.write(float4(c,1),gid);
}

"""

// ============================================================================
// 2. Swift Uniforms & Multi-Pass Renderer Bridge
// ============================================================================

struct Uniforms {
    var cameraPos: SIMD4<Float>
    var cameraTarget: SIMD4<Float>
    var cameraUp: SIMD4<Float>
    var sunParams: SIMD4<Float>
    var currentViewProj: simd_float4x4
    var prevViewProj: simd_float4x4
    var frameIndex: UInt32
    var sceneIndex: UInt32
    var samplingMode: UInt32
    var enableSMS: UInt32
    var skyMode: UInt32
    var enableFog: UInt32
    var viewportMode: UInt32
    var width: UInt32
    var height: UInt32
    // IndirectReuse raw value (bits 0-1), ReSTIR PT options (bits 2-5) and the sampler (bits 6-8; MSL
    // sampler_z); occupies former padding (offset 228).
    var indirectReuse: UInt32 = IndirectReuse.restirGI.rawValue
    var jitter: SIMD2<Float> = .zero
    var sampleIndex: UInt32 = 1
    var reservoirHistoryReset: UInt32 = 0
    // Consecutive frames with written ReSTIR reservoirs; gates temporal reuse.
    var reservoirHistory: UInt32 = 0
    // SpatialNeighborSelection raw value; occupies former padding (offset 252).
    var spatialNeighbors: UInt32 = SpatialNeighborSelection.compatibility.rawValue
    var environment = SIMD4<Float>(1, 0, 0, 0)
    // Aperture radius, focus distance, scene-graph mode (sceneGraphMode), independent sun 1 - cos(half angle).
    var lens = SIMD4<Float>(0, 4, 0, 0)
    var light = SIMD4<Float>(1, 1, 1, 1)

    // Mirrors MSL uses_scene_graph: scene 6 renders the imported scene graph.
    var sceneGraphMode: Bool {
        get { lens.z > 0 }
        set { lens.z = newValue ? 1 : 0 }
    }
}

// ReSTIR spatial reuse neighbours (shading_kernel for DI/GI; ReSTIR PT pairs its neighbours
// unless stochastic pairwise MIS is selected). REFERENCES.md: COMPATRESTIR2026, SPMIS2026.
enum SpatialNeighborSelection: UInt32, Sendable {
    // RESTIR2020: uniform taps in a 16-pixel box, binary normal/depth/material test.
    case uniform = 0
    // COMPATRESTIR2026: neighbours drawn from 32 taps in proportion to a G-buffer score.
    case compatibility = 1
    // Host-side default: compatibility for imported scene graphs, where it measured
    // 28-51% lower equal-time MSE, and uniform for the procedural scenes, where the
    // extra taps cost 2-12% at equal time (see tests/PERFORMANCE.md).
    case automatic = 2
    // SPMIS2026: stochastic pairwise MIS over a screen-space reuse cell of up to 64 pixels, with
    // neighbours drawn by contribution, for ReSTIR DI, GI and PT (replacing PT's paired reuse).
    case stochasticPairwise = 3
    func resolved(importedSceneGraph: Bool) -> SpatialNeighborSelection {
        self == .automatic ? (importedSceneGraph ? .compatibility : .uniform) : self
    }
}

// Indirect-light reuse of the ReSTIR strategy (Uniforms.indirectReuse bits 0-1).
// REFERENCES.md: RESTIRGI2021, RESTIRPT2022, RESTIRPTE2026.
enum IndirectReuse: UInt32, Sendable {
    // Bounded first-bounce diffuse ReSTIR GI; the ordinary path loop supplies deeper transport.
    case restirGI = 0
    // ReSTIR PT for every path of three or more vertices (all primary materials); ReSTIR DI
    // (diffuse primaries) or MIS next-event estimation lights the primary hit.
    case restirPT = 1
    // ReSTIR PT for every path of two or more vertices: direct and indirect light share one
    // reservoir and no ReSTIR DI pass runs (RESTIRPTE2026 Sec. 6.1).
    case restirPTUnified = 2
    // Host-side default: unified ReSTIR PT for imported meshes and scene graphs (scene 6), where it
    // measured 8-25% lower equal-time MSE than ReSTIR GI, and ReSTIR GI for the procedural scenes,
    // where its extra shifts cost 22-105% more error at equal time (see tests/PERFORMANCE.md).
    case automatic = 3
    func resolved(importedScene: Bool) -> IndirectReuse {
        self == .automatic ? (importedScene ? .restirPTUnified : .restirGI) : self
    }
}

// Temporal reuse of ReSTIR DI, GI and PT while the view changes (Uniforms.indirectReuse bit 4 on
// those frames). REFERENCES.md: HONG2026, LIU2025.
enum TemporalReuse: UInt32, Sendable {
    // Backprojection of each pixel's primary hit into the previous frame (RESTIR2020, RESTIRPT2022).
    case reprojection = 0
    // Multi-layer reservoir splatting: previous front-layer and occluded deep-layer domains are
    // splatted forward, so disoccluded pixels receive temporal candidates (HONG2026).
    case splatting = 1
    // Host-side default: reprojection in every mode. Splatting lowered the per-frame error of newly
    // disoccluded pixels by up to 9-39% per scene with unified ReSTIR PT (little with ReSTIR GI), but
    // left whole-image and MetalFX errors within a few percent at 5-26% more frame time, so it loses
    // at equal time (tests/PERFORMANCE.md).
    case automatic = 2
    func resolved(indirectReuse: IndirectReuse) -> TemporalReuse {
        self == .automatic ? .reprojection : self
    }
}

// Shading of ReSTIR PT pixels (Uniforms.indirectReuse bit 5). REFERENCES.md: RESTCV2026.
enum ControlVariates: UInt32, Sendable {
    // The reservoirs' resampled contribution with vector-valued weights (RESTIRPTE2026 Sec. 6.3).
    case off = 0
    // ReSTCV: an accumulated colour estimate per reservoir, reused across pixels and frames as
    // control variates with reservoir-based difference estimates (RESTCV2026).
    case restcv = 1
    // Host-side default: ReSTCV wherever it applies. With unified ReSTIR PT it lowered the per-frame
    // error of a moving camera by 5-47% and the MetalFX display error by 5-21%, and static
    // equal-sample MSE by 1-14%, for 0-3% more frame time (tests/PERFORMANCE.md).
    case automatic = 2
    // ReSTCV needs ReSTIR PT with its paired (deterministic pairwise MIS) spatial reuse; ReSTIR GI
    // and stochastic pairwise MIS run without it.
    func resolved(indirectReuse: IndirectReuse, spatialNeighbors: SpatialNeighborSelection) -> ControlVariates {
        guard indirectReuse != .restirGI && indirectReuse != .automatic && spatialNeighbors != .stochasticPairwise else { return .off }
        return self == .automatic ? .restcv : self
    }
}

// Random numbers of the sampling decisions (Uniforms.indirectReuse bit 6). REFERENCES.md: ZPP2026.
enum SamplerMode: UInt32, Sendable {
    // Per-pixel PCG hash streams (HASH2020), seeded per pixel and frame.
    case pcg = 0
    // Z++: Owen-scrambled 1D / 2D Sobol' and 3D O2m3 constituents indexed along a recursively
    // shuffled Morton curve, with Z++ temporal indexing (MSL z_pixel_key, Sampler).
    case zSampling = 1
    // Host-side default: Z++ for every strategy and scene. It lowered static equal-sample MSE by
    // 2-87% (Cornell glass within noise) for 1-4% more frame time, and kept the moving camera's
    // per-frame and MetalFX error within +1% (mostly lower); see tests/PERFORMANCE.md.
    case automatic = 2
    func resolved() -> SamplerMode {
        self == .automatic ? .zSampling : self
    }
}

// Light transport: RGB, or four wavelengths per path through the spectral shader libraries
// (VIBE_SPECTRAL; docs/SPECTRAL_DESIGN.md). REFERENCES.md: PETERSBLOG2025, PETERS2019,
// FOURIERSRGB2019, HERO2014, CIEDATA.
enum LightTransport: UInt32, Sendable {
    case rgb = 0
    case spectral = 1
    // Host-side default: spectral only where the scene needs wavelengths (an illuminant preset other
    // than D65, dispersion or thin film), RGB elsewhere: spectral transport cost 6-71% more frame
    // time (1.15-1.71x the time to equal error) for RGB scenes (tests/PERFORMANCE.md).
    case automatic = 2
    func resolved(sceneNeedsSpectral: Bool) -> LightTransport {
        self == .automatic ? (sceneNeedsSpectral ? .spectral : .rgb) : self
    }
}

// Emitter spectra of spectral transport (MSL VibeIlluminant, normalized to luminance one). An
// emitter's RGB colour tints the preset like a reflectance; D65 renders the RGB colour itself.
enum Illuminant: UInt32, CaseIterable, Sendable {
    case e = 0, d65 = 1, a = 2, fl11 = 3, hp1 = 4, ledB3 = 5
    // An optional stored preset (StudioOptions.lightSpectrum / sunSpectrum): nil is the RGB colour.
    static func resolved(_ raw: UInt32?) -> Illuminant { raw.flatMap(Illuminant.init(rawValue:)) ?? .d65 }
}

// Bundled spectral tables (build.sh copies them; test builds read build/SpectralTables).
func spectralResourceURL(_ name: String) -> URL? {
    runtimeResourceURL(bundled: Bundle.main.resourceURL?.appendingPathComponent(name),
                       repositoryPath: "build/SpectralTables/" + name)
}
func loadSpectralTablesSource() throws -> String {
    guard let url = spectralResourceURL("SpectralTables.metal"),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw NSError(domain: "PathTracer", code: 4, userInfo: [NSLocalizedDescriptionKey:
            "Missing SpectralTables.metal. Build with build.sh before using spectral transport."])
    }
    return text
}
// FourierSRGB86.bin: 64-byte header (magic VTFSRGBC, format 1, 86 nodes, 3 channels, 32 bits), then
// 86^3 x 3 little-endian float32 moments indexed (r * 86 + g) * 86 + b.
func loadSpectralGrid() throws -> [SIMD4<Float>] {
    func fail(_ message: String) -> NSError {
        NSError(domain: "PathTracer", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
    }
    guard let url = spectralResourceURL("FourierSRGB86.bin"), let data = try? Data(contentsOf: url) else {
        throw fail("Missing FourierSRGB86.bin. Build with build.sh before using spectral transport.")
    }
    let n = 86, count = n * n * n
    guard data.count == 64 + count * 12, data.prefix(8) == Data("VTFSRGBC".utf8),
          data.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 8, as: SIMD4<UInt32>.self) }) == SIMD4(1, 86, 3, 32)
    else { throw fail("FourierSRGB86.bin has an unexpected layout.") }
    return data.withUnsafeBytes { raw in
        (0..<count).map { i in
            let o = 64 + i * 12
            return SIMD4(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))),
                         Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self))),
                         Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self))), 0)
        }
    }
}

// Host copy of the shader's colour conversion (MSL spectral_lagrange), in double precision: moments
// interpolated trilinearly in linear light from the grid, then the bounded MESE's Lagrange multipliers
// (MSL vibe_fourier_lagrange; PETERS2019 Eqs. 6, 7, 10, FOURIERSRGB2019 Alg. 1 and 2). It solves the
// six saturated corners of the emission basis (MSL spectral_emission) once per device.
enum SpectralColour {
    static func lagrange(_ rgb: SIMD3<Double>, grid: MTLBuffer, nodes: [Float]) -> SIMD4<Float> {
        let c = simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1))
        if c.max() - c.min() <= 1e-4 { return SIMD4(Float((c.x + c.y + c.z) / 3), 0, 0, 2) }  // as MSL spectral_lagrange
        let g = grid.contents().bindMemory(to: SIMD4<Float>.self, capacity: 86 * 86 * 86 + 8192 * 64)
        func eotf(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        var i = SIMD3<Int>(0, 0, 0), code85 = SIMD3<Double>(0, 0, 0)
        for k in 0..<3 {
            let v = c[k]
            code85[k] = (v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) * 85
            i[k] = min(max(Int(code85[k]), 0), 84)
        }
        // A refined cell (MSL spectral_moments): its block of exact moments at one-code spacing.
        let slot = Int(g[(i.x * 86 + i.y) * 86 + i.z].w)
        var base = 0, stride = (86, 86), cell = i, t = SIMD3<Double>(0, 0, 0)
        if slot > 0 {
            base = 86 * 86 * 86 + 64 * (slot - 1); stride = (4, 4)
            for k in 0..<3 {
                let s = min(max(Int(code85[k] * 3 - Double(3 * i[k])), 0), 2), n0 = Double(3 * i[k] + s)
                let low = eotf(n0 / 255), high = eotf((n0 + 1) / 255)
                cell[k] = s
                t[k] = min(max((c[k] - low) / (high - low), 0), 1)
            }
        } else {
            for k in 0..<3 {
                let low = Double(nodes[i[k]]), high = Double(nodes[i[k] + 1])
                t[k] = min(max((c[k] - low) / (high - low), 0), 1)
            }
        }
        var m = SIMD3<Double>(0, 0, 0)
        for a in 0..<2 { for b in 0..<2 { for d in 0..<2 {
            let w = (a == 0 ? 1 - t.x : t.x) * (b == 0 ? 1 - t.y : t.y) * (d == 0 ? 1 - t.z : t.z)
            let e = g[base + ((cell.x + a) * stride.0 + cell.y + b) * stride.1 + cell.z + d]
            m += w * SIMD3(Double(e.x), Double(e.y), Double(e.z))
        }}}
        return SIMD4(SIMD3<Float>(fourierLagrange(m)), 1)
    }
    static func fourierLagrange(_ c: SIMD3<Double>) -> SIMD3<Double> {
        typealias C = SIMD2<Double>
        func mul(_ a: C, _ b: C) -> C { C(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x) }
        func conj(_ a: C) -> C { C(a.x, -a.y) }
        let pi = Double.pi
        let c0 = min(max(c.x, 1e-4), 1 - 1e-4)
        let g0p = C(sin(pi * c0), -cos(pi * c0)) / (4 * pi)
        let g0 = 2 * g0p.x
        var g1 = (2 * pi * c.y) * C(-g0p.y, g0p.x)
        var g2 = pi * C(-(2 * c.z * g0p.y + c.y * g1.y), 2 * c.z * g0p.x + c.y * g1.x)
        let q0 = 1 / g0
        var u1 = q0 * g1
        var n1 = simd_dot(u1, u1)
        var keep = 0.9999
        if n1 >= 1 { u1 *= keep / n1.squareRoot(); g1 = u1 / q0; n1 = keep * keep; keep = 0 }
        let d1 = 1 / (1 - n1)
        let a0 = q0 * d1
        let a1 = -u1 * (q0 * d1)
        var u2 = a0 * g2 + mul(a1, g1)
        var n2 = simd_dot(u2, u2)
        if n2 >= 1 { u2 *= keep / n2.squareRoot(); g2 = (u2 - mul(a1, g1)) / a0; n2 = keep * keep }
        let d2 = 1 / (1 - n2)
        let b0 = a0 * d2
        let b1 = (a1 - mul(u2, conj(a1))) * d2
        let b2 = -u2 * (a0 * d2)
        let r0 = C(b0 * b0 + simd_dot(b1, b1) + simd_dot(b2, b2), 0)
        let r1 = mul(conj(b1), C(b0, 0)) + mul(conj(b2), b1)
        let r2 = mul(conj(b2), C(b0, 0))
        let s0 = mul(g0p, r0) + mul(g1, r1) + mul(g2, r2)
        let s1 = mul(g0p, r1) + mul(g1, r2)
        let s2 = mul(g0p, r2)
        return SIMD3(s0.y, s1.y, s2.y) * (2 / b0)
    }
}

// How the Z++ sampler's successive frames relate while the camera moves (Uniforms.indirectReuse
// bits 7-8; MSL z_pixel_key). A static accumulation gives every pixel aligned blocks of its
// sequences in all four models. REFERENCES.md: ZPP2026 Sec. 4.1.
enum ZTemporal: UInt32, Sendable {
    case perPixel = 0          // t = s0 (Eq. 3)
    case interlaced = 1        // TZ: Eq. 5 interlacing of the frame index
    case spatiotemporal = 2    // STZ: TZ and Eq. 6 on the pixel index
    case reshuffled = 3        // a hashed block per frame (independent frames, as ReShuffle)
}

// RESTIRPTE2026 Sec. 3.1: a tileable, self-inverse pairing of an even side x side torus. Link
// indices start as consecutive pairs; n_sigma tiled 2 x 2 shuffles (every other one offset
// diagonally by one, wrapping) random-walk them, so linked texels end up about sigma apart.
// Each texel stores the wrapped offset (-side/2, side/2] to the texel sharing its link index.
func makePairingTexture(side: Int, sigma: Double, seed: UInt64) -> [SIMD2<Int8>] {
    precondition(side % 2 == 0 && side <= 254 && sigma >= 0.8)
    var state = seed
    func next() -> UInt64 {  // SplitMix64
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    var link = (0..<(side * side)).map { $0 / 2 }, block = [0, 0, 0, 0]
    // Eq. 3; the negative powers are the paper's small-sigma correction.
    let shuffles = Int(sigma * sigma / 2 + 1.46 / sigma + 1.76 / (sigma * sigma) + 0.656 / (sigma * sigma * sigma) + 0.5)
    for iteration in 0..<max(1, shuffles) {
        let shift = iteration % 2
        for by in stride(from: shift, to: side + shift, by: 2) {
            let row0 = (by % side) * side, row1 = ((by + 1) % side) * side
            for bx in stride(from: shift, to: side + shift, by: 2) {
                let c0 = row0 + bx % side, c1 = row0 + (bx + 1) % side, c2 = row1 + bx % side, c3 = row1 + (bx + 1) % side
                block[0] = link[c0]; block[1] = link[c1]; block[2] = link[c2]; block[3] = link[c3]
                // Fisher-Yates permutation of the block's four link indices.
                for i in stride(from: 3, to: 0, by: -1) { block.swapAt(i, Int(next() % UInt64(i + 1))) }
                link[c0] = block[0]; link[c1] = block[1]; link[c2] = block[2]; link[c3] = block[3]
            }
        }
    }
    var first = [Int](repeating: -1, count: side * side / 2), partner = [Int](repeating: -1, count: side * side)
    for (texel, index) in link.enumerated() {
        if first[index] < 0 { first[index] = texel } else { partner[texel] = first[index]; partner[first[index]] = texel }
    }
    func wrapped(_ d: Int) -> Int { d > side / 2 ? d - side : (d < -side / 2 ? d + side : d) }
    return (0..<(side * side)).map { texel in
        let other = partner[texel]
        return SIMD2(Int8(wrapped(other % side - texel % side)), Int8(wrapped(other / side - texel / side)))
    }
}

// Spectral shader state of one device, shared by its renderers (an export renderer shares its
// preview's): the pipelines (PathTracerRenderer.buildSpectralKernels) and the coarse moment grid.
@MainActor final class SpectralShaderCache {
    var kernels: PathTracerRenderer.SpectralKernels?
    var grid: MTLBuffer?
    var compiling = false
    var failure: String?
    // Whether refineSpectralGrid ran, and how many cells it refined.
    var refined = false
    var refinedCells = 0
}

// The three pairing textures ReSTIR PT's spatial reuse reads (MSL PT_PAIRING_SIDES: 254, 230 and
// 210, as in the paper's example, so their repeats do not align), built once on first use.
// sigma = sqrt(8 / (9 pi)) R matches the mean neighbour distance of a radius-R disk (Sec. 7);
// R = 20 pixels follows RESTIRPT2022's real-time setting.
enum ReSTIRPTPairing {
    static let sides = [254, 230, 210]
    static let sigma = (8.0 / (9.0 * Double.pi)).squareRoot() * 20.0
    static let deltas: [SIMD2<Int8>] = sides.enumerated().flatMap { index, side in
        makePairingTexture(side: side, sigma: sigma, seed: 0x5eed_0000 + UInt64(index))
    }
}

// REFERENCES.md: PBRT2023; local base-2/base-3 Halton jitter with a 1,024-frame period.
func frameJitter(_ index: UInt32) -> SIMD2<Float> {
    func halton(_ index: UInt32, base: UInt32) -> Float {
        var n = index, fraction: Float = 1, result: Float = 0
        while n > 0 {
            fraction /= Float(base)
            result += fraction * Float(n % base)
            n /= base
        }
        return result
    }
    let n = (max(1, index) - 1) % 1024 + 1
    return SIMD2<Float>(halton(n, base: 2) - 0.5, halton(n, base: 3) - 0.5)
}

enum CameraPreset: Int {
    case perspective = 0
    case front = 1
    case closeUp = 2
    case overhead = 3
}

// Reversed-Z projection (near -> 1, far -> 0). Floating-point depth keeps
// near-uniform relative precision across the range, which MetalFX needs for
// distant history rejection; x/y and w are unchanged by the reversal.
func makePerspective(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1.0 / tan(fovyRadians * 0.5)
    let x = y / aspect
    let z = near / (far - near)
    return simd_float4x4(
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * far, 0)
    )
}

func makeLookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = normalize(eye - target)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    return simd_float4x4(
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    )
}

// Native MetalFX resources. Recreated atomically on resize; private textures honor
// the usage flags returned by the scaler rather than assuming shader-read only.
// References: METALFXAPI, METALFX2026 in REFERENCES.md.
final class MetalFXDenoiser {
    let scaler: MTLFXTemporalDenoisedScaler
    let color: MTLTexture
    let depth: MTLTexture
    let motion: MTLTexture
    let diffuse: MTLTexture
    let specular: MTLTexture
    let normal: MTLTexture
    let roughness: MTLTexture
    let hitDistance: MTLTexture
    let denoiseMask: MTLTexture
    let output: MTLTexture
    let exposure: MTLTexture

    static func descriptor(width: Int, height: Int) -> MTLFXTemporalDenoisedScalerDescriptor {
        let descriptor = MTLFXTemporalDenoisedScalerDescriptor()
        descriptor.inputWidth = width; descriptor.inputHeight = height
        descriptor.outputWidth = width; descriptor.outputHeight = height
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.depthTextureFormat = .r32Float
        descriptor.motionTextureFormat = .rg16Float
        descriptor.diffuseAlbedoTextureFormat = .rgba16Float
        descriptor.specularAlbedoTextureFormat = .rgba16Float
        descriptor.normalTextureFormat = .rgba16Float
        descriptor.roughnessTextureFormat = .r16Float
        descriptor.specularHitDistanceTextureFormat = .r32Float
        descriptor.denoiseStrengthMaskTextureFormat = .r8Unorm
        descriptor.isDenoiseStrengthMaskTextureEnabled = true
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.isSpecularHitDistanceTextureEnabled = true
        descriptor.isAutoExposureEnabled = false
        descriptor.requiresSynchronousInitialization = false
        return descriptor
    }

    // The scaler's opaque history/feature allocations are not exposed by MetalFX.
    // Measure them once with the production descriptor at a small size, where
    // fixed overhead makes the per-pixel figure conservative for larger renders
    // (about 347 B/pixel at 192x192 versus 279-314 from 320x240 to 2560x1440 on M4).
    // currentAllocatedSize is device-wide, so a concurrent allocation or release
    // elsewhere can disturb one probe; implausible results are retried once and
    // otherwise replaced by a conservative fallback.
    static func scalerBytesPerPixel(device: MTLDevice) -> UInt64 {
        let side = 192, pixels = UInt64(side * side), fallback: UInt64 = 384
        for _ in 0..<2 {
            let before = device.currentAllocatedSize
            guard let probe = descriptor(width: side, height: side).makeTemporalDenoisedScaler(device: device) else { break }
            let measured = device.currentAllocatedSize - before
            withExtendedLifetime(probe) {}
            let perPixel = measured > 0 ? (UInt64(measured) + pixels - 1) / pixels : 0
            if (64...1024).contains(perPixel) { return perPixel }
        }
        return fallback
    }

    init(device: MTLDevice, width: Int, height: Int) throws {
        let descriptor = Self.descriptor(width: width, height: height)
        guard let effect = descriptor.makeTemporalDenoisedScaler(device: device) else {
            throw NSError(domain: "MetalFX", code: 1, userInfo: [NSLocalizedDescriptionKey: "MetalFX could not create a denoiser for this render size."])
        }
        scaler = effect
        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.storageMode = .private
            d.usage = usage.union([.shaderRead, .shaderWrite])
            guard let result = device.makeTexture(descriptor: d) else {
                throw NSError(domain: "MetalFX", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not allocate MetalFX \(label). Try a smaller window."])
            }
            result.label = "MetalFX \(label)"
            return result
        }
        color = try texture(.rgba16Float, effect.colorTextureUsage, "noisy HDR")
        depth = try texture(.r32Float, effect.depthTextureUsage, "device depth")
        motion = try texture(.rg16Float, effect.motionTextureUsage, "pixel motion")
        diffuse = try texture(.rgba16Float, effect.diffuseAlbedoTextureUsage, "diffuse albedo")
        specular = try texture(.rgba16Float, effect.specularAlbedoTextureUsage, "specular albedo")
        normal = try texture(.rgba16Float, effect.normalTextureUsage, "world normals")
        roughness = try texture(.r16Float, effect.roughnessTextureUsage, "roughness")
        hitDistance = try texture(.r32Float, effect.specularHitDistanceTextureUsage, "specular hit distance")
        denoiseMask = try texture(.r8Unorm, effect.denoiseStrengthMaskTextureUsage, "noiseless pixel mask")
        output = try texture(.rgba16Float, effect.outputTextureUsage, "denoised HDR")
        let exposureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        exposureDescriptor.storageMode = .shared
        exposureDescriptor.usage = .shaderRead
        guard let exposureTexture = device.makeTexture(descriptor: exposureDescriptor) else {
            throw NSError(domain: "MetalFX", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not allocate MetalFX exposure."])
        }
        exposure = exposureTexture
        var one = Float16(1).bitPattern
        exposure.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &one, bytesPerRow: 2)
    }
}

// Host representation of SurfaceSettings. Textures retain independent sizes and mip chains.
struct SurfaceSettings: Codable {
    var color = SIMD4<Float>(1, 1, 1, 1)
    var surface = SIMD4<Float>(0.3, 0, 0, 0)
    var detail = SIMD4<Float>(0, 1.5, 0, 1)
    var enabled: UInt32 = 0
    var mapMask: UInt32 = 0
    var normalStrength: Float = 1
    var padding: UInt32 = 0
}

final class MaterialLibrary {
    static let names = ["Unassigned", "Floor", "Copper sphere", "Gold ring", "Chrome sphere", "Glass sphere", "Plinth", "Imported mesh"]
    static let mapNames = ["Base color (sRGB)", "Roughness (linear R)", "Metalness (linear R)", "Normal (+Y, linear)"]
    var settings = Array(repeating: SurfaceSettings(), count: SceneLimits.materials)
    var images: [MTLTexture] = []
    private var defaultTextures: [MTLTexture] = []
    var fileNames = Array(repeating: "None", count: SceneLimits.materials * 4)
    var argumentBuffer: MTLBuffer!
    let device: MTLDevice
    let argumentEncoder: MTLArgumentEncoder
    var payloads = Array<Data?>(repeating: nil, count: SceneLimits.materials * 4)
    var objects = Array(repeating: ObjectSettings(), count: SceneLimits.materials) { didSet { bindingsDirty = true } }
    var bindingsDirty = false
    var environmentData: Data?
    var environmentTexture: MTLTexture!
    var environmentRows: MTLTexture!
    var environmentColumns: MTLTexture!
    var defaultEnvironmentSampling: MTLTexture!
    // BVH-ordered triangles live only in the shared triangleBuffer (read through
    // orderedTriangles). meshTriangles is the document's own array of a graph-less
    // (legacy) mesh, shared rather than copied, for snapshots; it is empty for a
    // scene-graph mesh, whose assets remain the only other host copy.
    // Two-level (MeshSceneLayout): triangleBuffer holds every asset's triangles in object
    // space, then their BLAS nodes; nodeBuffer the instances and TLAS. Flat (the reference
    // path): flattened world-space triangles and the median-split nodes.
    var triangleBuffer: MTLBuffer! { didSet { emittersDirty = true } }
    var nodeBuffer: MTLBuffer! { didSet { emittersDirty = true } }
    var meshTriangles: [MeshTriangle] = []
    var triangleCount = 0
    var hasSceneGraph = false
    var nodeCount = 0
    var acceleration = MaterialLibrary.defaultAcceleration
    // The published two-level structure; nil for a flat BVH.
    var meshLayout: MeshSceneLayout?
    // Asset hierarchies built and top levels built (edit-path accounting).
    var assetBuildCount = 0, sceneBuildCount = 0
    // Builds hardware acceleration structures (created on first use).
    var accelerationQueue: MTLCommandQueue?
    static var defaultAcceleration: MeshAcceleration {
#if VIBE_TESTING
        // Test builds can run the whole suite on the reference or the hardware path.
        switch ProcessInfo.processInfo.environment["VIBE_ACCELERATION"] {
        case "flat": return .flat
        case "hardware": return .hardware
        case "twoLevel": return .twoLevel
        default: break
        }
#endif
        // Metal's intersector where it traces the unwelded layout watertight on this device
        // (MaterialLibrary.hardwareWatertight); the exact software traversal elsewhere.
        return MaterialLibrary.hardwareWatertight ? .hardware : .twoLevel
    }
    var objectBuffer: MTLBuffer!
    var materialX: [Int:MaterialXProgram] = [:] { didSet { emittersDirty = true } }
    var graphInstructionBuffer: MTLBuffer!, graphHeaderBuffer: MTLBuffer!
    var graphTextures: [MTLTexture] = []
    private var emittersDirty = true
    var emissions:[Int:SIMD3<Float>]=[:] {didSet{bindingsDirty=true;emittersDirty=true}}
    var emissionBuffer:MTLBuffer!,emitterBuffer:MTLBuffer!
    // Whether imported emitters exist (constant or MaterialX emission).
    var hasEmitters: Bool {
        emissions.values.contains { $0.max() > 0 } || materialX.values.contains { $0.emission != nil }
    }
    // Spectral transport's per-slot OpenPBR parameters (MSL SpectralMaterial: dispersion 20 / V_d, thin
    // film weight, thickness in micrometres and IOR), from the slots' MaterialX constants;
    // spectralOverrides replaces a slot's (test scenes).
    var spectralOverrides: [Int: SIMD4<Float>] = [:]
    var spectralMaterials: [SIMD4<Float>] {
        (0..<SceneLimits.materials).map { spectralOverrides[$0] ?? materialX[$0]?.spectral ?? MaterialXProgram.noSpectral }
    }
    var orderedTriangles: UnsafeBufferPointer<MeshTriangle> {
        UnsafeBufferPointer(start: triangleCount == 0 ? nil
            : triangleBuffer.contents().bindMemory(to: MeshTriangle.self, capacity: triangleCount),
            count: triangleCount)
    }
    // Every resource referenced by the argument buffer. bind() declares exactly
    // this list with useResources, which is what keeps indirectly referenced
    // resources alive for command buffers encoded before a later swap.
    private(set) var boundResources: [MTLResource] = []
    // Textures of the published library that stay resident while this candidate
    // is prepared (open, undo, scene switch, export). They count toward the
    // replacement peak, and identical payloads are shared instead of decoded again.
    struct ResidentTextures {
        var images: [MTLTexture] = [], payloads: [Data?] = []
        var graphTextures: [MTLTexture] = [], materialX: [Int: MaterialXProgram] = [:]
        var environment: [MTLTexture] = [], environmentData: Data?
        var textures: [MTLTexture] { images + graphTextures + environment }
    }
    var external = ResidentTextures()
    var meshBuildCount = 0
    let loader: MTKTextureLoader
    // Internal fault-injection point used by the native regression suite. Nil in production.
    var bindingAllocationFailureCountdown: Int?
    // Internal seam for bounded memory-accounting tests. Production uses the device budget.
    var textureBudgetOverride: UInt64?
    var meshBudgetOverride: UInt64?

    private func bindingBuffer(bytes: UnsafeRawPointer? = nil, length: Int) -> MTLBuffer? {
        if let count = bindingAllocationFailureCountdown {
            if count == 0 { bindingAllocationFailureCountdown = nil; return nil }
            bindingAllocationFailureCountdown = count - 1
        }
        if let bytes { return device.makeBuffer(bytes: bytes, length: length, options: .storageModeShared) }
        return device.makeBuffer(length: length, options: .storageModeShared)
    }

    init(device: MTLDevice, function: MTLFunction) throws {
        self.device = device
        argumentEncoder = function.makeArgumentEncoder(bufferIndex: 2)
        loader = MTKTextureLoader(device: device)
        var defaults: [MTLTexture] = []
        for i in 0..<3 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: i == 0 ? .rgba8Unorm_srgb : .rgba8Unorm,
                width: 1, height: 1, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Self.error("Could not allocate material textures.") }
            var bytes: [UInt8] = i == 2 ? [128, 128, 255, 255] : [255, 255, 255, 255]
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
            defaults.append(texture)
        }
        defaultTextures = defaults
        images = (0..<(SceneLimits.materials * 4)).map { defaults[$0 % 4 == 0 ? 0 : ($0 % 4 == 3 ? 2 : 1)] }
        environmentTexture = defaults[0]
        let importanceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        importanceDescriptor.storageMode = .shared
        importanceDescriptor.usage = .shaderRead
        guard let importance = device.makeTexture(descriptor: importanceDescriptor) else {
            throw Self.error("Could not allocate environment sampling data.")
        }
        var one = [Float(1)]
        importance.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                           withBytes: &one, bytesPerRow: MemoryLayout<Float>.stride)
        environmentRows = importance
        environmentColumns = importance
        defaultEnvironmentSampling = importance
        guard let triangles = device.makeBuffer(length:128,options:.storageModeShared),
              let nodes = device.makeBuffer(length:48,options:.storageModeShared) else {
            throw Self.error("Could not allocate imported-scene buffers.")
        }
        triangleBuffer=triangles
        nodeBuffer=nodes
        try prepareMaterialX([:])
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "Materials", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func defaultTexture(channel: Int) -> MTLTexture {
        defaultTextures[channel == 0 ? 0 : (channel == 3 ? 2 : 1)]
    }

    var textureBudget: UInt64 {
        textureBudgetOverride ?? max(UInt64(256 * 1024 * 1024), device.recommendedMaxWorkingSetSize / 4)
    }

    // Every published texture, including the environment sampling CDFs.
    var residentTextures: [MTLTexture] {
        images + graphTextures + [environmentTexture, environmentRows, environmentColumns]
    }

    func residentSnapshot() -> ResidentTextures {
        ResidentTextures(images: images, payloads: payloads, graphTextures: graphTextures, materialX: materialX,
                         environment: [environmentTexture, environmentRows, environmentColumns],
                         environmentData: environmentData)
    }

    func uniqueTextureBytes(_ textures: [MTLTexture]) -> UInt64 {
        var seen = Set<ObjectIdentifier>()
        return textures.reduce(0) { total, view in
            // Swizzled grayscale views share their parent's storage.
            let texture = view.parent ?? view
            let id = ObjectIdentifier(texture as AnyObject)
            guard seen.insert(id).inserted else { return total }
            return total + UInt64(texture.allocatedSize)
        }
    }

    // `pending` holds candidates decoded earlier in the same batch.
    func validateEncodedImage(_ data: Data, maximumWidth: Int = 16384,
                              maximumHeight: Int = 16384,
                              maximumPixels: UInt64 = 67_108_864,
                              pending: [MTLTexture] = []) throws {
        guard data.count <= 128 * 1024 * 1024 else {
            throw Self.error("Texture file exceeds the 128 MiB import limit.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw Self.error("Could not read texture dimensions.")
        }
        let pixels = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !pixels.overflow, width <= maximumWidth, height <= maximumHeight,
              pixels.partialValue <= maximumPixels else {
            throw Self.error("Decoded texture exceeds the supported dimensions or pixel count.")
        }
        // Conservative predecode estimates with a complete mip chain. Up to 16
        // bits per channel MTKTextureLoader yields at most RGBA16 (10.75 B/pixel
        // measured for half-float EXR); 32-bit float EXR/TIFF yields RGBA32F
        // (21.5 B/pixel measured).
        let isFloat = properties[kCGImagePropertyIsFloat] as? Bool ?? false
        let depth = properties[kCGImagePropertyDepth] as? Int ?? (isFloat ? 32 : 8)
        let estimate = pixels.partialValue.multipliedReportingOverflow(by: depth > 16 ? 22 : 11)
        guard !estimate.overflow,
              uniqueTextureBytes(residentTextures + external.textures + pending) + estimate.partialValue <= textureBudget else {
            throw Self.error("Scene textures exceed the safe GPU memory budget.")
        }
    }

    func validateDecodedTexture(_ texture: MTLTexture, encodedBytes: Int, pending: [MTLTexture] = []) throws {
        guard encodedBytes <= 128 * 1024 * 1024 else {
            throw Self.error("Texture file exceeds the 128 MiB import limit.")
        }
        let pixels = UInt64(texture.width) * UInt64(texture.height) * UInt64(max(1, texture.arrayLength))
        guard texture.width <= 16384, texture.height <= 16384, pixels <= 67_108_864 else {
            throw Self.error("Decoded texture exceeds the 16,384 pixel side or 64 megapixel limit.")
        }
        guard uniqueTextureBytes(residentTextures + external.textures + pending + [texture]) <= textureBudget else {
            throw Self.error("Scene textures exceed the safe GPU memory budget.")
        }
    }

    // `environment` is the image followed by its row and column sampling CDFs.
    func validateCandidateTextures(images candidateImages: [MTLTexture],
                                   graph candidateGraph: [MTLTexture]? = nil,
                                   environment candidateEnvironment: [MTLTexture]? = nil) throws {
        let graph = candidateGraph ?? graphTextures
        let environment = candidateEnvironment ?? [environmentTexture, environmentRows, environmentColumns]
        let candidate = candidateImages + graph + environment
        let steady = uniqueTextureBytes(candidate + external.textures)
        // Old resources may remain live for already-encoded command buffers while
        // a complete replacement is prepared and published, as does another
        // published library this candidate will replace (`external`).
        let peak = uniqueTextureBytes(residentTextures + external.textures + candidate)
        guard steady <= textureBudget, peak <= textureBudget else {
            throw Self.error("Scene textures exceed the safe GPU memory budget during replacement.")
        }
    }

    func rebuildArguments(_ replacement: [MTLTexture]) throws {
        guard let buffer = bindingBuffer(length: argumentEncoder.encodedLength) else {
            throw Self.error("Could not allocate material bindings.")
        }
        // The encoder is re-targeted here on every rebuild, so a failed rebuild
        // cannot leave stale encoder state for the next one.
        argumentEncoder.setArgumentBuffer(buffer, offset: 0)
        var bound: [MTLResource] = []
        func setTexture(_ texture: MTLTexture, _ index: Int) { argumentEncoder.setTexture(texture, index: index); bound.append(texture) }
        func setBuffer(_ buffer: MTLBuffer, _ index: Int) { argumentEncoder.setBuffer(buffer, offset: 0, index: index); bound.append(buffer) }
        for (i, texture) in replacement.enumerated() { setTexture(texture, i) }
        setTexture(environmentTexture,256)
        setTexture(environmentRows,392)
        setTexture(environmentColumns,393)
        setBuffer(triangleBuffer,257)
        setBuffer(nodeBuffer,258)
        // Hardware traversal reaches these through the node buffer's resource ID.
        bound += meshLayout?.structures ?? []
        guard let objectBuffer=objects.withUnsafeBytes({ bindingBuffer(bytes:$0.baseAddress!,length:$0.count) }) else { throw Self.error("Could not allocate object settings.") }
        setBuffer(objectBuffer,259)
        for i in 0..<SceneLimits.graphImages { setTexture(i < graphTextures.count ? graphTextures[i] : replacement[0],260+i) }
        setBuffer(graphInstructionBuffer,388)
        setBuffer(graphHeaderBuffer,389)
        var emissionValues=Array(repeating:SIMD4<Float>(repeating:0),count:SceneLimits.materials)
        for (slot,value) in emissions {if emissionValues.indices.contains(slot){emissionValues[slot]=SIMD4(value,0)}}
        // .w is each emitting slot's light-selection weight (imported_emitter_area_pdf):
        // a constant emitter's luminance, else a MaterialX emitter's host estimate. The GPU
        // evaluates graph radiance per sample and per hit; the weight only shapes the PDF.
        var weights=[Int:Double]()
        for slot in 8..<SceneLimits.materials {
            if let e=emissions[slot], simd_length_squared(e)>0 { weights[slot]=Double(max(1e-8,0.2126*e.x+0.7152*e.y+0.0722*e.z)) }
            else if let program=materialX[slot] { let w=program.emissionWeight; if w>0 { weights[slot]=max(1e-8,w) } }
            emissionValues[slot].w=Float(weights[slot] ?? 0)
        }
        // Unchanged emitter lists keep their immutable buffer.
        let rebuildEmitters = emittersDirty || emitterBuffer == nil
        let emitterValues: [UInt32]
        if rebuildEmitters {
            // REFERENCES.md: PBRT2023 power light sampling. Emitters are chosen by area x
            // weight; the shader's imported_emitter_area_pdf uses the same (Float) weights.
            // IDs are rendered-triangle IDs (HitRecord.triangle); areas are world areas.
            var indices=[UInt32](),total=0.0,cumulative=[Double]()
            forEachRenderedTriangle(emitting: { weights[$0] != nil }) { id, t in
                let slot=Int(exactly:t.uvc.z) ?? 0
                guard slot>=8, weights[slot] != nil else { return }
                let edge1=SIMD3<Double>(Double(t.b.x-t.a.x),Double(t.b.y-t.a.y),Double(t.b.z-t.a.z))
                let edge2=SIMD3<Double>(Double(t.c.x-t.a.x),Double(t.c.y-t.a.y),Double(t.c.z-t.a.z))
                indices.append(UInt32(id))
                total+=0.5*simd_length(simd_cross(edge1,edge2))*Double(emissionValues[slot].w);cumulative.append(total)
            }
            if total>0 && total.isFinite {
                let cdf=cumulative.indices.map { $0==cumulative.count-1 ? Float(1).bitPattern : Float(cumulative[$0]/total).bitPattern }
                emitterValues=[UInt32(indices.count)]+indices+cdf+[Float(total).bitPattern]
            } else { emitterValues=[0,0] }
        } else { emitterValues = [] }
        guard let eb=emissionValues.withUnsafeBytes({bindingBuffer(bytes:$0.baseAddress!,length:$0.count)}) else{throw Self.error("Could not allocate scene emitters.")}
        let ib: MTLBuffer
        if !rebuildEmitters, let existing = emitterBuffer { ib = existing } else {
            guard let buffer=emitterValues.withUnsafeBytes({bindingBuffer(bytes:$0.baseAddress!,length:$0.count)}) else{throw Self.error("Could not allocate scene emitters.")}
            ib = buffer
        }
        setBuffer(eb,390);setBuffer(ib,391)
        var seen = Set<ObjectIdentifier>()
        bound = bound.filter { seen.insert(ObjectIdentifier($0)).inserted }
        // Replace atomically; previously encoded frames retain their original
        // argument buffer (setBuffer) and its resources (useResources).
        boundResources = bound
        self.objectBuffer = objectBuffer
        emissionBuffer = eb
        emitterBuffer = ib
        emittersDirty = false
        argumentBuffer = buffer
        images = replacement
        bindingsDirty = false
    }

    func load(url: URL, slot: Int, channel: Int) throws {
        guard (0..<SceneLimits.materials).contains(slot), (0..<4).contains(channel) else { throw Self.error("Invalid material slot.") }
        let resource = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = resource.fileSize, size > 128 * 1024 * 1024 {
            throw Self.error("Texture file exceeds the 128 MiB import limit.")
        }
        let bytes = try Data(contentsOf:url, options: .mappedIfSafe)
        try validateEncodedImage(bytes)
        let texture = try decodeTexture(bytes, srgb: channel == 0)
        texture.label = "\((slot < Self.names.count ? Self.names[slot] : "Material \(slot)")): \(Self.mapNames[channel]) — \(url.lastPathComponent)"
        var replacement = images
        replacement[slot * 4 + channel] = texture
        try validateCandidateTextures(images: replacement)
        try rebuildArguments(replacement)
        payloads[slot * 4 + channel] = bytes
        fileNames[slot * 4 + channel] = url.lastPathComponent
        settings[slot].mapMask |= 1 << channel
    }

    func clear(slot: Int, channel: Int) throws {
        guard (0..<SceneLimits.materials).contains(slot), (0..<4).contains(channel) else { throw Self.error("Invalid material slot.") }
        var replacement = images
        replacement[slot * 4 + channel] = defaultTexture(channel: channel)
        try rebuildArguments(replacement)
        payloads[slot * 4 + channel] = nil
        settings[slot].mapMask &= ~(1 << channel)
        fileNames[slot * 4 + channel] = "None"
    }

    @discardableResult func bind(_ encoder: MTLComputeCommandEncoder) -> Bool {
        // Object snapshots are immutable once encoded, like texture bindings.
        if bindingsDirty {
            do { try rebuildArguments(images) }
            catch { return false }
        }
        // Command buffers use retained references: setBuffer retains the argument
        // buffer and useResources retains every resource it points to, so
        // later swaps cannot free resources that encoded frames still read.
        encoder.useResources(boundResources, usage: .read)
        settings.withUnsafeBytes { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.setBuffer(argumentBuffer, offset: 0, index: 2)
        return true
    }
}

@MainActor
class PathTracerRenderer: NSObject, MTKViewDelegate {
    struct FrameResourcePlan {
        let width: Int
        let height: Int
        let usesReSTIR: Bool
        let usesMetalFX: Bool
        // Measured opaque MetalFX scaler allocations (see MetalFXDenoiser.scalerBytesPerPixel).
        var metalFXScalerBytesPerPixel: UInt64 = 0
        // Indirect reuse of the ReSTIR strategy; it decides which reservoirs are full size.
        var indirectReuse: IndirectReuse = PathTracerRenderer.defaultIndirectReuse
        // Whether the reservoir-splatting resources are allocated (temporal reuse by splatting).
        var splatting: Bool? = nil
        var usesSplatting: Bool {
            splatting ?? (PathTracerRenderer.defaultTemporalReuse.resolved(indirectReuse: indirectReuse) == .splatting)
        }
        // Whether the stochastic pairwise MIS reuse cells are allocated (SPMIS2026).
        var stochasticPairwise: Bool? = nil
        var usesStochasticPairwise: Bool {
            stochasticPairwise ?? (PathTracerRenderer.defaultSpatialNeighbors.resolved(importedSceneGraph: true) == .stochasticPairwise)
        }

        // DI: 6 RGBA32F. GI: 6 RGBA32F + 2 RGBA16F. ReSTIR PT: two 64 B path reservoirs,
        // three 16 B paired shifts, the RGBA32F indirect estimate, a history PrimarySurface,
        // the R16F duplication map and the 16 B ReSTCV estimate (RESTCV2026).
        static let diReservoirBytesPerPixel: UInt64 = 96
        static let giReservoirBytesPerPixel: UInt64 = 112
        static let ptReservoirBytesPerPixel: UInt64 = 2 * 64 + 3 * 16 + 16 + PathTracerRenderer.primarySurfaceStride + 2
            + UInt64(PathTracerRenderer.ptControlStride)
        static func reservoirBytesPerPixel(_ mode: IndirectReuse) -> UInt64 {
            switch mode {
            case .restirGI: return diReservoirBytesPerPixel + giReservoirBytesPerPixel
            case .restirPT: return diReservoirBytesPerPixel + ptReservoirBytesPerPixel
            case .restirPTUnified: return ptReservoirBytesPerPixel
            // Unresolved: the larger of the two sets it can resolve to.
            case .automatic: return max(reservoirBytesPerPixel(.restirGI), reservoirBytesPerPixel(.restirPTUnified))
            }
        }
        // Reservoir splatting (HONG2026): per pixel an activation mask (4 B), SplatLayers (48 B) and a
        // splat source (8 B); per deep-domain slot a splat source (8 B) and, in each of two pools,
        // a SplatDomain (32 B), a PrimarySurface (128 B) and the active reuse's reservoirs (DI 48 B,
        // GI 64 B, PT 64 B and its 16 B ReSTCV estimate), with PathTracerRenderer.splatSlotsPerPixel
        // slots per pixel.
        static func splatBytesPerPixel(_ mode: IndirectReuse) -> UInt64 {
            let reservoirs: UInt64
            let pt = 64 + UInt64(PathTracerRenderer.ptControlStride)
            switch mode {
            case .restirGI: reservoirs = 48 + 64
            case .restirPT: reservoirs = 48 + pt
            case .restirPTUnified: reservoirs = pt
            case .automatic: return max(splatBytesPerPixel(.restirGI), splatBytesPerPixel(.restirPTUnified))
            }
            return 60 + (8 + 2 * (32 + PathTracerRenderer.primarySurfaceStride + reservoirs)) / PathTracerRenderer.splatSlotDivisor
        }
        // Stochastic pairwise MIS (SPMIS2026): a 16 B SPMISPixel and a 16 B SPMISChoice per pixel and
        // a 12 B SPMISSlot per tile slot (the tiles cover the frame, so borders round the slot count up);
        // with ReSTIR PT, ptShifts grows from three 16 B paired shifts to 1 + Ñ 24 B shift records.
        static func spmisBytesPerPixel(_ mode: IndirectReuse) -> UInt64 {
            let cells: UInt64 = 16 + 16 + 12
            let shifts = UInt64(max(0, PathTracerRenderer.spmisShiftBytesPerPixel - PathTracerRenderer.ptShiftBytesPerPixel))
            switch mode {
            case .restirGI: return cells
            case .restirPT, .restirPTUnified: return cells + shifts
            case .automatic: return max(spmisBytesPerPixel(.restirGI), spmisBytesPerPixel(.restirPTUnified))
            }
        }
        // Everything a mode switch reallocates: the reservoirs and, when splatting or using stochastic
        // pairwise MIS, their resources.
        static func reservoirSetBytesPerPixel(_ mode: IndirectReuse, splatting: Bool, stochasticPairwise: Bool = false) -> UInt64 {
            reservoirBytesPerPixel(mode) + (splatting ? splatBytesPerPixel(mode) : 0) + (stochasticPairwise ? spmisBytesPerPixel(mode) : 0)
        }
        static let metalFXTextureBytesPerPixel: UInt64 = 55
        var bytesPerPixel: UInt64 {
            // Beauty/sample/position/OIDN accumulations: 6 RGBA32F; three
            // normal/material guides: 3 RGBA16F; resolved primary surfaces:
            // 128 B. ReSTIR adds the reservoirs of its indirect-reuse mode and,
            // when temporal reuse splats, the reservoir-splatting resources.
            // MetalFX formats total 55 B/pixel plus the scaler's own history and
            // feature allocations.
            120 + PathTracerRenderer.primarySurfaceStride
                + (usesReSTIR ? Self.reservoirSetBytesPerPixel(indirectReuse, splatting: usesSplatting,
                                                               stochasticPairwise: usesStochasticPairwise) : 0)
                + (usesMetalFX ? Self.metalFXTextureBytesPerPixel + metalFXScalerBytesPerPixel : 0)
        }
        var bytes: UInt64? {
            guard width > 0, height > 0 else { return nil }
            let pixels = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
            guard !pixels.overflow else { return nil }
            let result = pixels.partialValue.multipliedReportingOverflow(by: bytesPerPixel)
            return result.overflow ? nil : result.partialValue
        }
    }
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    let shaderLibrary: MTLLibrary
    let materialFunction: MTLFunction
    let pickPipeline: MTLComputePipelineState
    let restirTemporalPipeline: MTLComputePipelineState
    let shadingPipeline: MTLComputePipelineState
    let metalFXGuidePipeline: MTLComputePipelineState
    let presentPipeline: MTLComputePipelineState
    // The scene kernels. Scenes 0-5 use a library compiled with VIBE_MESHES=0: the imported-mesh
    // traversal is dead code there, but its registers slowed them by 13-17% (tests/PERFORMANCE.md).
    struct SceneKernels {
        let temporal, shading, guides, pick: MTLComputePipelineState
        // Nil for a library without them (tests/benchmark.py baselines), which then renders ReSTIR GI.
        let pt: ReSTIRPTKernels?
        // Nil for a library without them, which then reuses temporally by reprojection.
        let splat: SplatKernels?
        // Nil for a library without them, which then selects spatial neighbours as .automatic does.
        let spmis: SPMISKernels?
    }
    // ReSTIR PT passes: initial paths, temporal reuse, paired shifts, spatial reuse, duplication map.
    struct ReSTIRPTKernels { let initial, temporal, shift, spatial, duplication: MTLComputePipelineState }
    // Multi-layer reservoir splatting (HONG2026): domain activation, deep layers, deep-domain canonical
    // samples (DI/GI and PT), reservoir splats, and the DI/GI and PT temporal merges.
    struct SplatKernels { let activate, layers, deepReSTIR, deepPT, reservoirs, temporal, ptTemporal: MTLComputePipelineState }
    // Stochastic pairwise MIS (SPMIS2026): reuse-cell construction and ReSTIR PT spatial reuse.
    struct SPMISKernels { let cells, select, ptShift, pt: MTLComputePipelineState }
    nonisolated static func pipeline(_ device: MTLDevice, _ library: MTLLibrary, _ name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw NSError(domain: "PathTracer", code: 2, userInfo: [NSLocalizedDescriptionKey: "A required Metal shader is missing."])
        }
        return try device.makeComputePipelineState(function: function)
    }
    nonisolated static func ptKernels(_ device: MTLDevice, _ library: MTLLibrary) throws -> ReSTIRPTKernels? {
        let names = ["restir_pt_initial_kernel", "restir_pt_temporal_kernel", "restir_pt_shift_kernel",
                     "restir_pt_spatial_kernel", "restir_pt_duplication_kernel"]
        guard names.allSatisfy({ library.functionNames.contains($0) }) else { return nil }
        let p = try names.map { try pipeline(device, library, $0) }
        return ReSTIRPTKernels(initial: p[0], temporal: p[1], shift: p[2], spatial: p[3], duplication: p[4])
    }
    nonisolated static func splatKernels(_ device: MTLDevice, _ library: MTLLibrary) throws -> SplatKernels? {
        let names = ["splat_activate_kernel", "splat_layers_kernel", "splat_deep_restir_kernel", "restir_pt_deep_initial_kernel",
                     "splat_reservoirs_kernel", "splat_temporal_kernel", "restir_pt_splat_temporal_kernel"]
        guard names.allSatisfy({ library.functionNames.contains($0) }) else { return nil }
        let p = try names.map { try pipeline(device, library, $0) }
        return SplatKernels(activate: p[0], layers: p[1], deepReSTIR: p[2], deepPT: p[3], reservoirs: p[4],
                            temporal: p[5], ptTemporal: p[6])
    }
    nonisolated static func spmisKernels(_ device: MTLDevice, _ library: MTLLibrary) throws -> SPMISKernels? {
        let names = ["spmis_cells_kernel", "spmis_select_kernel", "restir_pt_spmis_shift_kernel", "restir_pt_spmis_kernel"]
        guard names.allSatisfy({ library.functionNames.contains($0) }) else { return nil }
        let p = try names.map { try pipeline(device, library, $0) }
        return SPMISKernels(cells: p[0], select: p[1], ptShift: p[2], pt: p[3])
    }
    // Spectral transport's scene kernels (VIBE_SPECTRAL=1 libraries, after the generated tables), and
    // the inverse-CDF kernel. The MetalFX guide and picking kernels have no colour transport and are
    // the RGB libraries'. The pipelines compile concurrently (the compiler service runs them in parallel).
    struct SpectralKernels: Sendable { let procedural, mesh: SceneKernels; let icdf, refineFlags, refineSolve: MTLComputePipelineState }
    nonisolated static func buildSpectralKernels(device: MTLDevice, source: String, relaxedMath: Bool,
                                                 procedural rgbProcedural: SceneKernels, mesh rgbMesh: SceneKernels) throws -> SpectralKernels {
        let source = try loadSpectralTablesSource() + source
        func library(meshes: Bool) throws -> MTLLibrary {
            let options = MTLCompileOptions()
            options.mathMode = relaxedMath ? .relaxed : .safe
            options.preprocessorMacros = meshes ? ["VIBE_SPECTRAL": NSNumber(value: 1)]
                : ["VIBE_SPECTRAL": NSNumber(value: 1), "VIBE_MESHES": NSNumber(value: 0)]
            return try device.makeLibrary(source: source, options: options)
        }
        let libraries = [try library(meshes: true), try library(meshes: false)]
        let names = ["restir_temporal_kernel", "shading_kernel", "restir_pt_initial_kernel", "restir_pt_temporal_kernel",
                     "restir_pt_shift_kernel", "restir_pt_spatial_kernel", "restir_pt_duplication_kernel", "splat_activate_kernel",
                     "splat_layers_kernel", "splat_deep_restir_kernel", "restir_pt_deep_initial_kernel", "splat_reservoirs_kernel",
                     "splat_temporal_kernel", "restir_pt_splat_temporal_kernel", "spmis_cells_kernel", "spmis_select_kernel",
                     "restir_pt_spmis_shift_kernel", "restir_pt_spmis_kernel"]
        let jobs = libraries.flatMap { library in names.map { (library, $0) } }
            + ["spectral_icdf_kernel", "spectral_refine_flags_kernel", "spectral_refine_solve_kernel"].map { (libraries[0], $0) }
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var states: [MTLComputePipelineState?]
            var failure: Error?
            init(_ count: Int) { states = Array(repeating: nil, count: count) }
        }
        let results = Results(jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            do {
                let state = try pipeline(device, jobs[i].0, jobs[i].1)
                results.lock.lock(); results.states[i] = state; results.lock.unlock()
            } catch {
                results.lock.lock(); results.failure = error; results.lock.unlock()
            }
        }
        if let failure = results.failure { throw failure }
        let states = results.states.map { $0! }
        func kernels(_ k: Int, rgb: SceneKernels) -> SceneKernels {
            let p = Array(states[(k * names.count)..<((k + 1) * names.count)])
            return SceneKernels(temporal: p[0], shading: p[1], guides: rgb.guides, pick: rgb.pick,
                                pt: ReSTIRPTKernels(initial: p[2], temporal: p[3], shift: p[4], spatial: p[5], duplication: p[6]),
                                splat: SplatKernels(activate: p[7], layers: p[8], deepReSTIR: p[9], deepPT: p[10], reservoirs: p[11],
                                                    temporal: p[12], ptTemporal: p[13]),
                                spmis: SPMISKernels(cells: p[14], select: p[15], ptShift: p[16], pt: p[17]))
        }
        let extra = states.suffix(3).map { $0 }
        return SpectralKernels(procedural: kernels(1, rgb: rgbProcedural), mesh: kernels(0, rgb: rgbMesh), icdf: extra[0],
                               refineFlags: extra[1], refineSolve: extra[2])
    }
    let proceduralKernels: SceneKernels
    let meshKernels: SceneKernels
    var sceneKernels: SceneKernels {
        if spectralFrame, let spectral = spectralShaders.kernels { return sceneIndex == 6 ? spectral.mesh : spectral.procedural }
        return sceneIndex == 6 ? meshKernels : proceduralKernels
    }
    // Spectral pipelines and the moment grid, shared with renderers created with `sharing:`.
    let spectralShaders: SpectralShaderCache
    // Whether the frame being encoded (or the last one) traced spectrally: the light transport
    // resolves to spectral and its pipelines are ready.
    private(set) var spectralFrame = false
    // The scene's wavelength inverse CDF (MSL buffer 29) and the illuminant weights it was built for.
    var spectralSampling: MTLBuffer?
    var spectralSamplingWeights: [Float]?
    // Called on the main queue when background-compiled spectral pipelines become ready.
    var onSpectralShadersReady: (() -> Void)?
    let supportsMetalFX: Bool
    var materials: MaterialLibrary
    private(set) var metalFX: MetalFXDenoiser?
    private(set) var metalFXHistoryNeedsReset = true
    private(set) var lastPresentationUsedMetalFX = false
    private(set) var lastMetalFXReset = false
    // Display-only: toggling leaves progressive samples intact, but resets MetalFX history.
    var denoiserEnabled = true {
        didSet { if oldValue != denoiserEnabled { metalFXHistoryNeedsReset = true; presentationNeedsRefresh = true } }
    }

    var historyPosDepth: MTLTexture?
    var historyNormalMat: MTLTexture?
    var gbufferPosDepth: MTLTexture?
    var gbufferNormalMat: MTLTexture?
    var gbufferAlbedoRough: MTLTexture?
    // MSL PrimarySurface per pixel: pass 1 writes it; shading and MetalFX guides read it.
    nonisolated static let primarySurfaceStride: UInt64 = 128
    private(set) var primarySurfaces: MTLBuffer?
    var accumTexture: MTLTexture?
    var sampleTexture: MTLTexture?
    var oidnAlbedoAccum: MTLTexture?
    var oidnNormalAccum: MTLTexture?

    var resPosDirA: MTLTexture?
    var resEmitPdfA: MTLTexture?
    var resWeightsA: MTLTexture?

    var resPosDirB: MTLTexture?
    var resEmitPdfB: MTLTexture?
    var resWeightsB: MTLTexture?

    var giPosPdfA: MTLTexture?
    var giNormalA: MTLTexture?
    var giRadianceA: MTLTexture?
    var giWeightsA: MTLTexture?
    var giPosPdfB: MTLTexture?
    var giNormalB: MTLTexture?
    var giRadianceB: MTLTexture?
    var giWeightsB: MTLTexture?
    // ReSTIR PT (IndirectReuse.restirPT*): the temporal pass writes ptReservoirs, the spatial
    // pass writes ptHistory (the next frame's temporal input); ptShifts holds each pixel's paths
    // shifted to its three paired partners. Placeholders (1 x 1, nil buffers) in other modes.
    var ptReservoirs: MTLBuffer?
    var ptHistory: MTLBuffer?
    var ptShifts: MTLBuffer?
    // ReSTCV (RESTCV2026): each pixel's current colour estimate and primary reflectance (MSL
    // PTControl); the previous frame's final estimate stays in ptIndirect until spatial reuse.
    var ptControls: MTLBuffer?
    nonisolated static let ptControlStride = 16
    var historyPrimarySurfaces: MTLBuffer?
    var ptIndirect: MTLTexture?
    var ptDuplication: MTLTexture?
    private var ptPairing: MTLBuffer?
    nonisolated static let ptReservoirStride = 64
    // Stochastic pairwise MIS reuse cells (SpatialNeighborSelection.stochasticPairwise; REFERENCES.md
    // SPMIS2026): an SPMISPixel and an SPMISChoice per pixel and an SPMISSlot per tile slot. Nil in
    // other modes.
    private(set) var spmisCells: MTLBuffer?
    private(set) var spmisSlots: MTLBuffer?
    private(set) var spmisChoices: MTLBuffer?
    nonisolated static let spmisTile = 8
    // MSL SPMIS_PT_CANDIDATES (Ñ of ReSTIR PT); ptShifts then holds 1 + Ñ 24-byte SPMISShift records.
    nonisolated static let spmisPTCandidates = 3
    nonisolated static var ptShiftBytesPerPixel: Int { 3 * 16 }
    nonisolated static var spmisShiftBytesPerPixel: Int { (spmisPTCandidates + 1) * 24 }
    // Multi-layer reservoir splatting (TemporalReuse.splatting; REFERENCES.md HONG2026): two pools of
    // deep-layer domains, `splatCurrent` written this frame and `splatPrevious` read from the last,
    // swapped after every frame; per-pixel activation masks, SplatLayers and the splat sources of
    // every destination domain. Nil unless temporal reuse splats.
    struct SplatPool {
        let domains, surfaces, counters: MTLBuffer   // SplatDomain, PrimarySurface; counters are shared
        let di, gi, pt: MTLBuffer?                   // SplatDI, SplatGI, PTReservoir of the active reuse
        let controls: MTLBuffer?                     // ReSTCV PTControl estimates beside `pt` (RESTCV2026)
        let capacity: Int
        var buffers: [MTLBuffer] { [domains, surfaces, counters] + [di, gi, pt, controls].compactMap { $0 } }
    }
    private(set) var splatCurrent: SplatPool?
    private(set) var splatPrevious: SplatPool?
    private(set) var splatMask: MTLBuffer?
    private(set) var splatLayers: MTLBuffer?
    private(set) var splatSources: MTLBuffer?
    private var splatPlaceholder: MTLBuffer?
    // Deep-domain slots per pool: one per splatSlotDivisor pixels. Domains beyond it are dropped
    // (counted in the pool counters) and lose only their history.
    nonisolated static let splatSlotDivisor: UInt64 = 4
    nonisolated static func splatCapacity(width: Int, height: Int) -> Int { max(64, width * height / Int(splatSlotDivisor)) }
    // Whether the last submitted frame reused temporally by splatting.
    private(set) var lastFrameSplatted = false

    var prevViewProj = matrix_identity_float4x4
    var frameIndex: UInt32 = 0
    private var sampleIndex: UInt32 = 0
    // Unlike frameIndex, camera moves keep ReSTIR history; reprojection
    // rejects disocclusions. Cuts and inspection/non-ReSTIR frames clear it.
    private(set) var reservoirHistory: UInt32 = 0
#if VIBE_TESTING
    // GPU checks replay one jitter/seed sequence to compare renders of a view (or start
    // another at `index` for independent trials), and exercise the unsupported-device
    // presentation path on MetalFX-capable GPUs.
    func restartSampleSequence(at index: UInt32 = 0) { sampleIndex = index }
    static var simulateUnsupportedMetalFX = false
#endif

    var sceneIndex: UInt32 = 0 { didSet { if oldValue != sceneIndex { applyPreset(.perspective) } } }
    var samplingMode: UInt32 = 0 { didSet { if oldValue != samplingMode { resetAccumulation() } } } // 0 ReSTIR DI+GI, 1 MIS, 2 light, 3 BSDF
    var enableSMS: UInt32 = 0 { didSet { if oldValue != enableSMS { resetAccumulation() } } }
    var skyMode: UInt32 = 0 { didSet { if oldValue != skyMode { resetAccumulation() } } }
    var enableFog: UInt32 = 0 { didSet { if oldValue != enableFog { resetAccumulation() } } }
    var spatialNeighbors = PathTracerRenderer.defaultSpatialNeighbors {
        didSet { if oldValue != spatialNeighbors { resetAccumulation() } }
    }
    // Indirect reuse of the ReSTIR strategy. REFERENCES.md: RESTIRPT2022, RESTIRPTE2026.
    var indirectReuse = PathTracerRenderer.defaultIndirectReuse {
        didSet { if oldValue != indirectReuse { resetAccumulation() } }
    }
    // Temporal reuse while the view changes: reprojection or multi-layer reservoir splatting (HONG2026).
    var temporalReuse = PathTracerRenderer.defaultTemporalReuse {
        didSet { if oldValue != temporalReuse { resetAccumulation() } }
    }
    // Shading of ReSTIR PT pixels: resampled contributions or ReSTCV control variates (RESTCV2026).
    var controlVariates = PathTracerRenderer.defaultControlVariates {
        didSet { if oldValue != controlVariates { resetAccumulation() } }
    }
    // RGB or spectral light transport (docs/SPECTRAL_DESIGN.md). Spectral pipelines compile on first
    // use; until they are ready (in the background, outside test builds) frames trace in RGB.
    var lightTransport = PathTracerRenderer.defaultLightTransport {
        didSet { if oldValue != lightTransport { resetAccumulation() } }
    }
    var activeLightTransport: LightTransport { resolvedLightTransport(lightTransport) }
    func resolvedLightTransport(_ mode: LightTransport) -> LightTransport { mode.resolved(sceneNeedsSpectral: sceneNeedsSpectral) }
    // Lights with an illuminant preset, and materials with dispersion or thin film, need wavelengths.
    var sceneNeedsSpectral: Bool {
        let weights = spectralIlluminantWeights()
        return weights.enumerated().contains { $0.offset != Int(Illuminant.d65.rawValue) && $0.element > 0 }
            || materials.spectralMaterials.contains { $0.x > 0 || $0.y > 0 }
    }
    // Whether the scene has area or sphere lights or imported emitters (StudioOptions.lightSpectrum),
    // and a sun (StudioOptions.sunSpectrum).
    var sceneHasLights: Bool { (1...5).contains(sceneIndex) || (sceneIndex == 6 && materials.hasEmitters) }
    var sceneHasSun: Bool { (sceneIndex == 0 || sceneIndex == 6) && options.sunIntensity > 0 }
    // Wavelength sampling (spectral_icdf_kernel): an equal mixture of the illuminants the scene's
    // emitters use; the sky, environment maps and RGB-coloured lights count as D65.
    func spectralIlluminantWeights() -> [Float] {
        var weights = [Float](repeating: 0, count: Illuminant.allCases.count)
        if sceneIndex == 0 || sceneIndex == 6 { weights[Int(Illuminant.d65.rawValue)] = 1 }
        if sceneHasLights { weights[Int(Illuminant.resolved(options.lightSpectrum).rawValue)] = 1 }
        if sceneHasSun { weights[Int(Illuminant.resolved(options.sunSpectrum).rawValue)] = 1 }
        if !weights.contains(where: { $0 > 0 }) { weights[Int(Illuminant.d65.rawValue)] = 1 }
        return weights
    }
    // Test builds compile the spectral pipelines synchronously, so every spectral frame is spectral.
    nonisolated static var compilesSpectralShadersInBackground: Bool {
#if VIBE_TESTING
        return false
#else
        return true
#endif
    }
    // Random numbers of sampling decisions: PCG streams or the Z++ sampler (ZPP2026).
    var sampler = PathTracerRenderer.defaultSampler {
        didSet { if oldValue != sampler { resetAccumulation() } }
    }
    var activeSampler: SamplerMode { resolvedSampler(sampler) }
    // What a sampler choice runs as with the current strategy and scene (the inspector's
    // "Automatic (currently: …)").
    func resolvedSampler(_ mode: SamplerMode) -> SamplerMode { mode.resolved() }
    // Temporal model of the Z++ sampler.
    var zTemporal = PathTracerRenderer.defaultZTemporal {
        didSet { if oldValue != zTemporal { resetAccumulation() } }
    }
    // RESTIRPTE2026 Sec. 5 duplication-map confidence reduction for ReSTIR PT. It trades
    // correlation for bias, so the progressive renderer leaves it off by default.
    var ptDecorrelation = PathTracerRenderer.defaultPTDecorrelation {
        didSet { if oldValue != ptDecorrelation { resetAccumulation() } }
    }
    // ReSTIR PT temporal reuse normally runs only while the view changes (restir_pt_temporal);
    // true keeps it on every accumulated frame, as the papers' real-time renderers do.
    var ptTemporalWhileAccumulating = false {
        didSet { if oldValue != ptTemporalWhileAccumulating { resetAccumulation() } }
    }
    nonisolated static var defaultIndirectReuse: IndirectReuse {
#if VIBE_TESTING
        // Test builds can run the whole suite with another indirect reuse.
        switch ProcessInfo.processInfo.environment["VIBE_INDIRECT_REUSE"] {
        case "gi": return .restirGI
        case "pt": return .restirPT
        case "unified": return .restirPTUnified
        default: break
        }
#endif
        return .automatic
    }
    nonisolated static var defaultTemporalReuse: TemporalReuse {
#if VIBE_TESTING
        // Test builds can run the whole suite with either temporal reuse.
        switch ProcessInfo.processInfo.environment["VIBE_TEMPORAL_REUSE"] {
        case "reprojection": return .reprojection
        case "splatting": return .splatting
        default: break
        }
#endif
        return .automatic
    }
    nonisolated static var defaultControlVariates: ControlVariates {
#if VIBE_TESTING
        // Test builds can run the whole suite with or without ReSTCV.
        switch ProcessInfo.processInfo.environment["VIBE_CONTROL_VARIATES"] {
        case "off": return .off
        case "restcv": return .restcv
        default: break
        }
#endif
        return .automatic
    }
    nonisolated static var defaultLightTransport: LightTransport {
#if VIBE_TESTING
        // Test builds can run the whole suite with either light transport.
        switch ProcessInfo.processInfo.environment["VIBE_LIGHT_TRANSPORT"] {
        case "rgb": return .rgb
        case "spectral": return .spectral
        default: break
        }
#endif
        return .automatic
    }
    nonisolated static var defaultSampler: SamplerMode {
#if VIBE_TESTING
        // Test builds can run the whole suite with either sampler.
        switch ProcessInfo.processInfo.environment["VIBE_SAMPLER"] {
        case "pcg": return .pcg
        case "z": return .zSampling
        default: break
        }
#endif
        return .automatic
    }
    nonisolated static var defaultZTemporal: ZTemporal {
#if VIBE_TESTING
        switch ProcessInfo.processInfo.environment["VIBE_Z_TEMPORAL"] {
        case "perpixel": return .perPixel
        case "tz": return .interlaced
        case "stz": return .spatiotemporal
        case "reshuffle": return .reshuffled
        default: break
        }
#endif
        // ReShuffle-like frames: the lowest MetalFX error of the four models while the camera
        // moves (tests/PERFORMANCE.md); still views accumulate aligned nets in every model.
        return .reshuffled
    }
    nonisolated static var defaultPTDecorrelation: Bool {
#if VIBE_TESTING
        if ProcessInfo.processInfo.environment["VIBE_PT_DECORRELATION"] == "1" { return true }
#endif
        return false
    }
    nonisolated static var defaultSpatialNeighbors: SpatialNeighborSelection {
#if VIBE_TESTING
        // Test builds can run the whole suite with the earlier uniform selection or with
        // stochastic pairwise MIS.
        switch ProcessInfo.processInfo.environment["VIBE_SPATIAL_NEIGHBORS"] {
        case "uniform": return .uniform
        case "stochastic": return .stochasticPairwise
        default: break
        }
#endif
        return .automatic
    }

    var yaw: Float = 0.42 { didSet { if oldValue != yaw { resetAccumulation(resetDenoiser: false) } } }
    var pitch: Float = 0.22 { didSet { if oldValue != pitch { resetAccumulation(resetDenoiser: false) } } }
    var distance: Float = 4.6 { didSet { if oldValue != distance { resetAccumulation(resetDenoiser: false) } } }
    var target = SIMD3<Float>(0.15, -0.25, 0.70) { didSet { if oldValue != target { resetAccumulation(resetDenoiser: false) } } }
    var fov: Float = 38.0 { didSet { if oldValue != fov { resetAccumulation(resetDenoiser: false) } } }

    // Display-only edits (exposure, white balance, tone map, divider) must repaint
    // even while paused or complete, when draw(in:) otherwise idles.
    var options = StudioOptions() { didSet { presentationNeedsRefresh = true } }
    var oidnOptions = OIDNOptions()
    var viewportMode: UInt32 = 0 {
        didSet {
            if oldValue == 0 && viewportMode > 0 { debugFrames = 0 }
            if oldValue > 0 && viewportMode == 0 {
                frameIndex = frameIndex >= debugFrames ? frameIndex - debugFrames : 0
                sampleIndex = sampleIndex >= debugFrames ? sampleIndex - debugFrames : 0
                completedSamples = frameIndex
                debugFrames = 0
            }
            if oldValue != viewportMode { presentationNeedsRefresh = true }
        }
    }
    // The studio toolbar mirrors pause state changes made by exports, previews and imports.
    var paused = false { didSet { if oldValue != paused { onPausedChange?() } } }
    var onPausedChange: (() -> Void)?
    var renderElapsed: TimeInterval = 0
    var gpuMilliseconds: Double = 0
    var framesPerSecond: Double = 0
    var completedSamples: UInt32 = 0
    // Awake seconds (awakeSeconds): the render time limit does not count system sleep.
    var lastTick = awakeSeconds()
    var lastCompletion = Date()
    var presentationNeedsRefresh = true
    var lastDisplay: MTLTexture?
    var offlineDenoisedPreview: MTLTexture?
    var lastUniforms: Uniforms?
    var onFrameUpdate: ((UInt32) -> Void)?
    var onError: ((String) -> Void)?
    let inFlightFrames = DispatchSemaphore(value: 3)
    private var generation: UInt64 = 0
    private var debugFrames: UInt32 = 0
    var interactionGeneration: UInt64 { generation }

    func cameraClipPlanes() -> (near: Float, far: Float) {
        let near = max(0.00001, min(0.05, distance * 0.0001))
        return (near, max(100, min(1_000_000, distance * 2_000)))
    }
    private var rejectedRenderSize: SIMD2<Int>?
    // The reservoir set of the frame resources (reservoirSet): nil before the first frame.
    private var frameReservoirs: UInt32?
    // 0 for non-ReSTIR and inspection frames (1 x 1 placeholders), else 1 + IndirectReuse,
    // plus 16 with the reservoir-splatting resources and 32 with the stochastic pairwise MIS cells.
    func reservoirSet(usesReSTIR: Bool) -> UInt32 {
        usesReSTIR ? (activeIndirectReuse.rawValue + 1) | (activeTemporalReuse == .splatting ? 16 : 0)
            | (activeSpatialNeighbors == .stochasticPairwise ? 32 : 0) : 0
    }
    // indirectReuse with .automatic resolved for the current scene.
    var activeIndirectReuse: IndirectReuse { resolvedIndirectReuse(indirectReuse) }
    // temporalReuse with .automatic resolved; reprojection for a library without the splat kernels.
    var activeTemporalReuse: TemporalReuse {
        resolvedTemporalReuse(temporalReuse, indirectReuse: indirectReuse)
    }
    // spatialNeighbors with .automatic resolved for the current scene.
    var activeSpatialNeighbors: SpatialNeighborSelection { resolvedSpatialNeighbors(spatialNeighbors) }
    // controlVariates resolved for the current scene and reuse modes.
    var activeControlVariates: ControlVariates { resolvedControlVariates(controlVariates) }
    // What a mode would run as in the current scene (the inspector's "Automatic (currently: …)").
    func resolvedIndirectReuse(_ mode: IndirectReuse) -> IndirectReuse {
        sceneKernels.pt == nil ? .restirGI : mode.resolved(importedScene: sceneIndex == 6)
    }
    func resolvedTemporalReuse(_ mode: TemporalReuse, indirectReuse: IndirectReuse) -> TemporalReuse {
        sceneKernels.splat == nil ? .reprojection : mode.resolved(indirectReuse: resolvedIndirectReuse(indirectReuse))
    }
    func resolvedControlVariates(_ mode: ControlVariates, indirectReuse candidateIndirect: IndirectReuse? = nil,
                                 spatialNeighbors candidateSpatial: SpatialNeighborSelection? = nil) -> ControlVariates {
        mode.resolved(indirectReuse: resolvedIndirectReuse(candidateIndirect ?? indirectReuse),
                      spatialNeighbors: resolvedSpatialNeighbors(candidateSpatial ?? spatialNeighbors))
    }
    func resolvedSpatialNeighbors(_ mode: SpatialNeighborSelection) -> SpatialNeighborSelection {
        let imported = sceneIndex == 6 && materials.hasSceneGraph
        let resolved = mode.resolved(importedSceneGraph: imported)
        return resolved == .stochasticPairwise && sceneKernels.spmis == nil
            ? SpatialNeighborSelection.automatic.resolved(importedSceneGraph: imported) : resolved
    }
    // Set when only the reservoirs were reallocated; the next frame skips temporal reuse.
    private(set) var reservoirHistoryNeedsReset = false
    var concurrentRenderBytes: UInt64 = 0
    private var measuredMetalFXScalerBytesPerPixel: UInt64?
    var metalFXScalerBytesPerPixel: UInt64 {
        guard supportsMetalFX else { return 0 }
        if let measured = measuredMetalFXScalerBytesPerPixel { return measured }
        let measured = MetalFXDenoiser.scalerBytesPerPixel(device: device)
        measuredMetalFXScalerBytesPerPixel = measured
        return measured
    }

    var residentFrameBytes: UInt64 {
        let textures: [MTLTexture?] = [
            historyPosDepth, historyNormalMat, gbufferPosDepth, gbufferNormalMat,
            gbufferAlbedoRough, accumTexture, sampleTexture, oidnAlbedoAccum,
            oidnNormalAccum, resPosDirA, resEmitPdfA, resWeightsA, resPosDirB,
            resEmitPdfB, resWeightsB, giPosPdfA, giNormalA, giRadianceA,
            giWeightsA, giPosPdfB, giNormalB, giRadianceB, giWeightsB, ptIndirect, ptDuplication,
        ]
        var seen = Set<ObjectIdentifier>()
        let metalFXTextures: [MTLTexture?] = metalFX.map { fx in
            [fx.color, fx.depth, fx.motion, fx.diffuse, fx.specular, fx.normal,
             fx.roughness, fx.hitDistance, fx.denoiseMask, fx.output, fx.exposure]
        } ?? []
        let scalerBytes = metalFX.map { fx in
            UInt64(fx.output.width) * UInt64(fx.output.height) * metalFXScalerBytesPerPixel
        } ?? 0
        return (textures + metalFXTextures).compactMap { $0 }.reduce(scalerBytes) { total, texture in
            let id = ObjectIdentifier(texture as AnyObject)
            return seen.insert(id).inserted ? total + UInt64(texture.allocatedSize) : total
        } + ([primarySurfaces, historyPrimarySurfaces, ptReservoirs, ptHistory, ptShifts, ptPairing, ptControls,
              splatMask, splatLayers, splatSources, spmisCells, spmisSlots, spmisChoices] + (splatCurrent?.buffers ?? []) + (splatPrevious?.buffers ?? []))
            .reduce(UInt64(0)) { $0 + UInt64($1?.allocatedSize ?? 0) }
    }

    // `indirectReuse`, `temporalReuse` and `spatialNeighbors` preflight a mode switch before it is
    // applied (the Render inspector); nil uses the current setting.
    func renderMemoryError(width: Int, height: Int, indirectReuse candidateIndirect: IndirectReuse? = nil,
                           temporalReuse candidateTemporal: TemporalReuse? = nil,
                           spatialNeighbors candidateSpatial: SpatialNeighborSelection? = nil) -> String? {
        let usesReSTIR = samplingMode == 0 && viewportMode == 0
        let usesMetalFX = denoiserEnabled && supportsMetalFX && usesReSTIR
        let indirectMode = candidateIndirect ?? indirectReuse
        let activeIndirect = resolvedIndirectReuse(indirectMode)
        let splatting = resolvedTemporalReuse(candidateTemporal ?? temporalReuse, indirectReuse: indirectMode) == .splatting
        let stochasticPairwise = resolvedSpatialNeighbors(candidateSpatial ?? spatialNeighbors) == .stochasticPairwise
        let plan = FrameResourcePlan(width: width, height: height, usesReSTIR: usesReSTIR, usesMetalFX: usesMetalFX,
            metalFXScalerBytesPerPixel: usesMetalFX ? metalFXScalerBytesPerPixel : 0, indirectReuse: activeIndirect,
            splatting: splatting, stochasticPairwise: stochasticPairwise)
        guard let frameBytes = plan.bytes else { return "Render dimensions are too large." }
        // Include the live frame set during resize/export, scene textures, the
        // measured MetalFX scaler internals, and modest command/display headroom
        // (drawable and capture staging) in the final 32 B/pixel.
        let pixels = UInt64(width) * UInt64(height)
        let headroom = pixels.multipliedReportingOverflow(by: 32)
        guard !headroom.overflow else { return "Render dimensions are too large." }
        let resizes = accumTexture == nil || accumTexture?.width != width || accumTexture?.height != height
        let resident = resizes ? residentFrameBytes : 0
        let baseRequired = resizes ? frameBytes : residentFrameBytes
        // A strategy, indirect-reuse, temporal-reuse or inspection change replaces only the reservoirs
        // (and splat resources); the old ones stay live (in residentFrameBytes) for in-flight frames.
        let reservoirs = pixels.multipliedReportingOverflow(
            by: FrameResourcePlan.reservoirSetBytesPerPixel(activeIndirect, splatting: splatting, stochasticPairwise: stochasticPairwise))
        // reservoirSet(usesReSTIR: true)
        let candidateSet = (activeIndirect.rawValue + 1) | (splatting ? 16 : 0) | (stochasticPairwise ? 32 : 0)
        let additionalReservoirs = !resizes && plan.usesReSTIR && frameReservoirs != candidateSet
            ? reservoirs.partialValue : 0
        let withResident = baseRequired.addingReportingOverflow(resident)
        let required = withResident.partialValue.addingReportingOverflow(additionalReservoirs)
        let needsMetalFX = plan.usesMetalFX &&
            (metalFX == nil || metalFX?.output.width != width || metalFX?.output.height != height)
        let fx = pixels.multipliedReportingOverflow(by: FrameResourcePlan.metalFXTextureBytesPerPixel + plan.metalFXScalerBytesPerPixel)
        let additionalFX = !resizes && needsMetalFX ? fx.partialValue : 0
        let withFX = required.partialValue.addingReportingOverflow(additionalFX)
        let withConcurrent = withFX.partialValue.addingReportingOverflow(concurrentRenderBytes)
        // Scene textures and the imported mesh (triangles, hierarchies, emitter list).
        let withTextures = withConcurrent.partialValue.addingReportingOverflow(
            materials.uniqueTextureBytes(materials.residentTextures + materials.external.textures) + materials.meshBytes
                + (activeLightTransport == .spectral ? Self.spectralBytes : 0))
        let total = withTextures.partialValue.addingReportingOverflow(headroom.partialValue)
        if reservoirs.overflow || fx.overflow || withResident.overflow || required.overflow || withFX.overflow
            || withConcurrent.overflow || withTextures.overflow || total.overflow {
            return "Render dimensions are too large."
        }
        let recommended = device.recommendedMaxWorkingSetSize
        let budget = max(UInt64(512 * 1024 * 1024), recommended * 7 / 10)
        guard total.partialValue <= budget else {
            let mib = total.partialValue / (1024 * 1024)
            let allowed = budget / (1024 * 1024)
            return "This render needs about \(mib) MiB of GPU memory; the safe budget is \(allowed) MiB. Reduce the output dimensions or preview scale."
        }
        return nil
    }

    init(device: MTLDevice, sharing other: PathTracerRenderer? = nil) throws {
        self.device = device
        var metalFXSupported = MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
#if VIBE_TESTING
        if Self.simulateUnsupportedMetalFX { metalFXSupported = false }
#endif
        self.supportsMetalFX = metalFXSupported
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "PathTracer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create a Metal command queue."])
        }
        self.commandQueue = queue
        self.spectralShaders = other.flatMap { $0.device.registryID == device.registryID ? $0.spectralShaders : nil }
            ?? SpectralShaderCache()

        do {
            let shared = other.flatMap { $0.device.registryID == device.registryID ? $0 : nil }
            let lib = try shared?.shaderLibrary ?? device.makeLibrary(source: metalSource, options: shaderCompileOptions())
            self.shaderLibrary = lib
            guard let fnPick = lib.makeFunction(name: "pick_kernel"),
                  let fnTemporal = lib.makeFunction(name: "restir_temporal_kernel"),
                  let fnShading = lib.makeFunction(name: "shading_kernel"),
                  let fnGuides = lib.makeFunction(name: "metalfx_guides_kernel"),
                  let fnPresent = lib.makeFunction(name: "present_kernel") else {
                throw NSError(domain: "PathTracer", code: 2, userInfo: [NSLocalizedDescriptionKey: "A required Metal shader is missing."])
            }

            self.materialFunction = fnTemporal
            self.pickPipeline = try shared?.pickPipeline ?? device.makeComputePipelineState(function: fnPick)
            self.materials = try MaterialLibrary(device: device, function: fnTemporal)
            self.restirTemporalPipeline = try shared?.restirTemporalPipeline ?? device.makeComputePipelineState(function: fnTemporal)
            self.shadingPipeline = try shared?.shadingPipeline ?? device.makeComputePipelineState(function: fnShading)
            self.metalFXGuidePipeline = try shared?.metalFXGuidePipeline ?? device.makeComputePipelineState(function: fnGuides)
            self.presentPipeline = try shared?.presentPipeline ?? device.makeComputePipelineState(function: fnPresent)
            func pipeline(_ library: MTLLibrary, _ name: String) throws -> MTLComputePipelineState {
                try Self.pipeline(device, library, name)
            }
            func ptKernels(_ library: MTLLibrary) throws -> ReSTIRPTKernels? { try Self.ptKernels(device, library) }
            func splatKernels(_ library: MTLLibrary) throws -> SplatKernels? { try Self.splatKernels(device, library) }
            func spmisKernels(_ library: MTLLibrary) throws -> SPMISKernels? { try Self.spmisKernels(device, library) }
            if let shared {
                self.proceduralKernels = shared.proceduralKernels
                self.meshKernels = shared.meshKernels
            } else {
                let options = shaderCompileOptions()
                options.preprocessorMacros = ["VIBE_MESHES": NSNumber(value: 0)]
                let procedural = try device.makeLibrary(source: metalSource, options: options)
                self.proceduralKernels = SceneKernels(temporal: try pipeline(procedural, "restir_temporal_kernel"),
                    shading: try pipeline(procedural, "shading_kernel"), guides: try pipeline(procedural, "metalfx_guides_kernel"),
                    pick: try pipeline(procedural, "pick_kernel"), pt: try ptKernels(procedural), splat: try splatKernels(procedural),
                    spmis: try spmisKernels(procedural))
                self.meshKernels = SceneKernels(temporal: restirTemporalPipeline, shading: shadingPipeline,
                    guides: metalFXGuidePipeline, pick: pickPipeline, pt: try ptKernels(lib), splat: try splatKernels(lib),
                    spmis: try spmisKernels(lib))
            }
        } catch {
            throw error
        }
        super.init()
        measuredMetalFXScalerBytesPerPixel = other.flatMap {
            $0.device.registryID == device.registryID ? $0.measuredMetalFXScalerBytesPerPixel : nil
        }
        denoiserEnabled = supportsMetalFX
        applyPreset(.perspective)
    }

    // Spectral pipelines and moment grid for this frame: ready, compiling in the background (the frame
    // then traces in RGB; accumulation restarts when they are ready), or, in test builds and after a
    // failure has been reported once, decided synchronously.
    func prepareSpectralShaders() -> Bool {
        let cache = spectralShaders
        if cache.kernels != nil && cache.grid != nil { return true }
        if cache.failure != nil || cache.compiling { return false }
        if cache.grid == nil {
            do {
                let grid = try loadSpectralGrid()
                guard let buffer = device.makeBuffer(length: Int(Self.spectralGridBytes), options: .storageModeShared)
                else { throw MaterialLibrary.error("Could not allocate the spectral moment grid.") }
                grid.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                buffer.label = "Spectral: FourierSRGB86 moments"
                cache.grid = buffer
            } catch {
                cache.failure = error.localizedDescription
                onError?(error.localizedDescription)
                return false
            }
        }
        if cache.kernels != nil { refineSpectralGrid(); return true }
        let device = self.device, source = metalSource, procedural = proceduralKernels, mesh = meshKernels
        if !Self.compilesSpectralShadersInBackground {
            do {
                cache.kernels = try Self.buildSpectralKernels(device: device, source: source, relaxedMath: true,
                                                              procedural: procedural, mesh: mesh)
                refineSpectralGrid()
                return true
            } catch {
                cache.failure = "Spectral shaders failed to compile: \(error.localizedDescription)"
                onError?(cache.failure!)
                return false
            }
        }
        cache.compiling = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PathTracerRenderer.buildSpectralKernels(device: device, source: source, relaxedMath: true,
                                                                     procedural: procedural, mesh: mesh) }
            }.value
            cache.compiling = false
            switch result {
            case .success(let kernels): cache.kernels = kernels
            case .failure(let error): cache.failure = "Spectral shaders failed to compile: \(error.localizedDescription)"
            }
            guard let self else { return }
            if cache.kernels != nil { self.refineSpectralGrid() }
            if let failure = cache.failure { self.onError?(failure) }
            else if self.activeLightTransport == .spectral { self.resetAccumulation() }
            self.onSpectralShadersReady?()
        }
        return false
    }
    // Refines the grid's cells whose codes the trilinear interpolation reproduces worse than 0.35 8-bit
    // steps (MSL spectral_moments): flags them on the GPU over every 8-bit code, assigns their blocks and
    // solves their 64 codes exactly. Once per device, when the grid and the pipelines are ready (~0.5 s).
    func refineSpectralGrid() {
        let cache = spectralShaders
        guard !cache.refined, let kernels = cache.kernels, let grid = cache.grid,
              let flags = device.makeBuffer(length: 85 * 85 * 85 * 4, options: .storageModeShared),
              let command = commandQueue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return }
        cache.refined = true
        memset(flags.contents(), 0, flags.length)
        var words = spectralSceneWords()
        encoder.setComputePipelineState(kernels.refineFlags)
        encoder.setBytes(&words, length: words.count * 4, index: 27)
        encoder.setBuffer(grid, offset: 0, index: 28)
        encoder.setBuffer(flags, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1 << 24, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        let flagged = flags.contents().bindMemory(to: UInt32.self, capacity: 85 * 85 * 85)
        var cells = [UInt32]()
        for i in 0..<(85 * 85 * 85) where flagged[i] != 0 && cells.count < Self.spectralRefinedCapacity { cells.append(UInt32(i)) }
        cache.refinedCells = cells.count
        guard !cells.isEmpty, let cellBuffer = cells.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let solve = commandQueue.makeCommandBuffer(), let solver = solve.makeComputeCommandEncoder() else { return }
        let nodes = grid.contents().bindMemory(to: SIMD4<Float>.self, capacity: 86 * 86 * 86)
        for (slot, cell) in cells.enumerated() {
            let c = Int(cell), i = c / (85 * 85), j = (c / 85) % 85, k = c % 85
            nodes[(i * 86 + j) * 86 + k].w = Float(slot + 1)
        }
        var count = UInt32(cells.count)
        solver.setComputePipelineState(kernels.refineSolve)
        solver.setBytes(&words, length: words.count * 4, index: 27)
        solver.setBuffer(grid, offset: 0, index: 28)
        solver.setBuffer(cellBuffer, offset: 0, index: 0)
        solver.setBytes(&count, length: 4, index: 1)
        solver.dispatchThreads(MTLSize(width: 64 * cells.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        solver.endEncoding(); solve.commit(); solve.waitUntilCompleted()
        if solve.status != .completed { onError?("The spectral grid refinement failed: \(String(describing: solve.error))") }
    }
    // SpectralScene (MSL, 1392 bytes): light and sun illuminants, the coarse grid's node values and
    // the slots' spectral material parameters.
    static let spectralGridNodes: [Float] = (0..<86).map { i in
        let v = Double(3 * i) / 255
        return Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
    }
    func spectralSceneWords() -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 348)
        words[0] = Illuminant.resolved(options.lightSpectrum).rawValue
        words[1] = Illuminant.resolved(options.sunSpectrum).rawValue
        for (i, v) in Self.spectralGridNodes.enumerated() { words[4 + i] = v.bitPattern }
        for (slot, m) in materials.spectralMaterials.enumerated() {
            for c in 0..<4 { words[92 + slot * 4 + c] = m[c].bitPattern }
        }
        return words
    }
    // Spectral transport's device memory: the 86^3 float4 moment grid (shared by renderers of one device)
    // and the sampling buffer.
    nonisolated static let spectralRefinedCapacity = 8192
    nonisolated static let spectralGridBytes: UInt64 = (86 * 86 * 86 + 8192 * 64) * 16
    nonisolated static let spectralSamplingFloats = 4 * (257 + 3 * 471) + 2 * 471
    nonisolated static let spectralBytes: UInt64 = spectralGridBytes + 4 * UInt64(spectralSamplingFloats)
    // Encodes spectral_icdf_kernel when the scene's illuminant weights changed; returns the weights the
    // buffer will hold once the command buffer completes.
    func encodeSpectralSampling(_ command: MTLCommandBuffer) -> [Float]? {
        let weights = spectralIlluminantWeights()
        if spectralSampling == nil {
            spectralSampling = device.makeBuffer(length: Self.spectralSamplingFloats * 4, options: .storageModePrivate)
            spectralSampling?.label = "Spectral: wavelength inverse CDF"
            spectralSamplingWeights = nil
        }
        guard let buffer = spectralSampling, let kernels = spectralShaders.kernels else { return nil }
        if spectralSamplingWeights == weights { return weights }
        guard let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.label = "Spectral: wavelength sampling"
        encoder.setComputePipelineState(kernels.icdf)
        var packed = weights + [Float](repeating: 0, count: 8 - weights.count)
        // The Lagrange multipliers of the emission basis: the saturated corners R, G, B, C, M, Y.
        guard let grid = spectralShaders.grid else { return nil }
        for corner in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 0)] {
            let L = SpectralColour.lagrange(corner, grid: grid, nodes: Self.spectralGridNodes)
            packed += [L.x, L.y, L.z, 0]
        }
        encoder.setBytes(&packed, length: packed.count * 4, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 29)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        return weights
    }

    func applyPreset(_ preset: CameraPreset) {
        if sceneIndex == 0 {
            switch preset {
            case .perspective: yaw = 0.42;  pitch = 0.22; distance = 4.6; target = SIMD3<Float>(0.15, -0.25, 0.70); fov = 38.0
            case .front:       yaw = 0.00;  pitch = 0.12; distance = 4.4; target = SIMD3<Float>(0.10, -0.20, 0.70); fov = 38.0
            case .closeUp:     yaw = 0.58;  pitch = 0.28; distance = 2.3; target = SIMD3<Float>(0.65, -0.55, 0.35); fov = 34.0
            case .overhead:    yaw = 0.00;  pitch = 1.15; distance = 4.8; target = SIMD3<Float>(0.00, -0.30, 0.50); fov = 45.0
            }
        } else if sceneIndex == 2 {
            switch preset {
            case .perspective: yaw = 0.52;  pitch = 0.28; distance = 5.3; target = SIMD3<Float>(0, 0.1, 0.1); fov = 40.0
            case .front:       yaw = 0.00;  pitch = 0.38; distance = 5.6; target = SIMD3<Float>(0, 0.3, 0.3); fov = 38.0
            case .closeUp:     yaw = -0.32; pitch = 0.18; distance = 3.2; target = SIMD3<Float>(-0.8, -0.2, 0); fov = 34.0
            case .overhead:    yaw = 0.00;  pitch = 1.05; distance = 6.2; target = SIMD3<Float>(0, 0.4, 0.2); fov = 42.0
            }
        } else if sceneIndex == 5 {
            switch preset {
            case .perspective: yaw = 0.65;  pitch = 0.60; distance = 2.9; target = SIMD3<Float>(0.3, -0.6, -0.1); fov = 42.0
            case .front:       yaw = 0.00;  pitch = 0.55; distance = 3.3; target = SIMD3<Float>(0.1, -0.6, 0.0); fov = 45.0
            case .closeUp:     yaw = 0.35;  pitch = 0.45; distance = 1.7; target = SIMD3<Float>(0.45, -0.75, -0.15); fov = 36.0
            case .overhead:    yaw = 0.00;  pitch = 1.25; distance = 2.8; target = SIMD3<Float>(0.3, -0.7, -0.1); fov = 46.0
            }
        } else {
            switch preset {
            case .perspective: yaw = 0.45;  pitch = 0.25; distance = 3.4; target = SIMD3<Float>(0, -0.1, 0); fov = 42.0
            case .front:       yaw = 0.00;  pitch = 0.00; distance = 3.3; target = SIMD3<Float>(0, 0, 0); fov = 40.0
            case .closeUp:     yaw = -0.25; pitch = 0.10; distance = 2.2; target = SIMD3<Float>(0.15, -0.45, -0.1); fov = 36.0
            case .overhead:    yaw = 0.00;  pitch = 1.15; distance = 3.2; target = SIMD3<Float>(0, -0.2, 0); fov = 45.0
            }
        }
        resetAccumulation()
    }

    func resetAccumulation(resetDenoiser: Bool = true) {
        renderElapsed = 0; lastTick = awakeSeconds(); completedSamples = 0
        generation &+= 1
        frameIndex = 0
        debugFrames = 0
        // The last display and its uniforms describe the pre-reset scene: capture
        // and picking wait for a newly traced frame instead of using them.
        lastDisplay = nil
        lastUniforms = nil
        if offlineDenoisedPreview != nil {
            offlineDenoisedPreview = nil
            paused = false
        }
        if resetDenoiser { metalFXHistoryNeedsReset = true; reservoirHistory = 0 }
    }

    // Grows only, so encoders sized for a smaller frame can share it.
    func primarySurfaceBuffer(width: Int, height: Int) -> MTLBuffer? {
        let length = max(1, width * height) * Int(Self.primarySurfaceStride)
        if let buffer = primarySurfaces, buffer.length >= length { return buffer }
        primarySurfaces = device.makeBuffer(length: length, options: .storageModePrivate)
        return primarySurfaces
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // A paused or finished render keeps its accumulation and is presented
        // scaled to the new drawable; renderFrame reallocates once tracing resumes.
        if (paused || reachedLimit) && accumTexture != nil {
            presentationNeedsRefresh = true
            return
        }
        resetAccumulation()
        accumTexture = nil
    }

    // Shared by the window renderer and GPU tests. Native-resolution MetalFX
    // receives one noisy frame per call and owns temporal reconstruction itself.
    func encodePresentation(commandBuffer: MTLCommandBuffer, accumulation: MTLTexture,
                            samples: MTLTexture, positions: MTLTexture, normals: MTLTexture, materials: MTLTexture,
                            output: MTLTexture, uniforms: Uniforms) -> MTLTexture? {
        var uniforms = uniforms
        let group = MTLSize(width: 8, height: 8, depth: 1)
        var display = accumulation
        lastPresentationUsedMetalFX = false
        if denoiserEnabled && supportsMetalFX && uniforms.samplingMode == 0 && viewportMode == 0 {
            if metalFX?.output.width != accumulation.width || metalFX?.output.height != accumulation.height {
                do {
                    metalFX = try MetalFXDenoiser(device: device, width: accumulation.width, height: accumulation.height)
                    metalFXHistoryNeedsReset = true
                } catch {
                    // Report a real failure, never silently substitute a custom filter.
                    onError?(error.localizedDescription)
                    return nil
                }
            }
            guard let fx = metalFX,
                  let surfaces = primarySurfaceBuffer(width: accumulation.width, height: accumulation.height),
                  let prepare = commandBuffer.makeComputeCommandEncoder() else { return nil }
            prepare.label = "MetalFX surface and motion guides"
            prepare.setComputePipelineState(sceneKernels.guides)
            let inputs = [samples, positions, normals, materials, fx.color, fx.depth, fx.motion,
                          fx.diffuse, fx.specular, fx.normal, fx.roughness, fx.hitDistance, fx.denoiseMask]
            for (index, texture) in inputs.enumerated() { prepare.setTexture(texture, index: index) }
            guard self.materials.bind(prepare) else {
                prepare.endEncoding()
                onError?("Could not update material bindings.")
                return nil
            }
            prepare.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            prepare.setBuffer(surfaces, offset: 0, index: 3)
            prepare.dispatchThreads(MTLSize(width: accumulation.width, height: accumulation.height, depth: 1), threadsPerThreadgroup: group)
            prepare.endEncoding()

            let effect = fx.scaler
            effect.colorTexture = fx.color; effect.depthTexture = fx.depth; effect.motionTexture = fx.motion
            effect.diffuseAlbedoTexture = fx.diffuse; effect.specularAlbedoTexture = fx.specular
            effect.normalTexture = fx.normal; effect.roughnessTexture = fx.roughness
            effect.specularHitDistanceTexture = fx.hitDistance
            effect.denoiseStrengthMaskTexture = fx.denoiseMask
            effect.outputTexture = fx.output; effect.exposureTexture = fx.exposure
            effect.preExposure = 1
            effect.isDepthReversed = true
            effect.motionVectorScaleX = 1; effect.motionVectorScaleY = 1
            effect.jitterOffsetX = uniforms.jitter.x; effect.jitterOffsetY = uniforms.jitter.y
            effect.worldToViewMatrix = makeLookAt(eye: SIMD3<Float>(uniforms.cameraPos.x, uniforms.cameraPos.y, uniforms.cameraPos.z),
                target: SIMD3<Float>(uniforms.cameraTarget.x, uniforms.cameraTarget.y, uniforms.cameraTarget.z),
                up: SIMD3<Float>(uniforms.cameraUp.x, uniforms.cameraUp.y, uniforms.cameraUp.z))
            let clip = cameraClipPlanes()
            effect.viewToClipMatrix = makePerspective(fovyRadians: uniforms.cameraPos.w * .pi / 180,
                aspect: Float(uniforms.width) / Float(uniforms.height), near: clip.near, far: clip.far)
            effect.shouldResetHistory = metalFXHistoryNeedsReset
            lastMetalFXReset = metalFXHistoryNeedsReset
            effect.encode(commandBuffer: commandBuffer)
            metalFXHistoryNeedsReset = false
            lastPresentationUsedMetalFX = true
            display = fx.output
        } else {
            // Release the scaler and its opaque history while MetalFX is unused;
            // in-flight command buffers retain what they encoded.
            metalFX = nil
            metalFXHistoryNeedsReset = true
        }
        // Inspection views use the progressively accumulated guides so camera
        // jitter cannot make albedo or normals shimmer. MetalFX above still
        // receives the current noisy frame and its matching per-frame guides.
        guard encodeDisplay(commandBuffer, display: display, raw: accumulation, output: output,
                            albedo: oidnAlbedoAccum ?? materials,
                            normals: oidnNormalAccum ?? normals,
                            positions: positions) else { return nil }
        lastDisplay = display
        presentationNeedsRefresh = false
        return display
    }

    func encodeDisplay(_ commandBuffer: MTLCommandBuffer, display: MTLTexture, raw: MTLTexture,
                       output: MTLTexture, albedo: MTLTexture? = nil,
                       normals: MTLTexture? = nil, positions: MTLTexture? = nil) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "Display tone mapping"
        encoder.setComputePipelineState(presentPipeline)
        encoder.setTexture(display,index:0); encoder.setTexture(output,index:1); encoder.setTexture(raw,index:2)
        encoder.setTexture(albedo ?? oidnAlbedoAccum ?? gbufferAlbedoRough ?? raw,index:3)
        encoder.setTexture(normals ?? oidnNormalAccum ?? historyNormalMat ?? raw,index:4)
        encoder.setTexture(positions ?? historyPosDepth ?? raw,index:5)
        let warmth = options.whiteBalance
        var controls = [SIMD4<Float>(options.exposure, options.toneMap, Float(viewportMode), lastPresentationUsedMetalFX ? options.compare : 0),
                        SIMD4<Float>(exp2(warmth*0.5),1,exp2(-warmth*0.5),1)]
        encoder.setBytes(&controls,length:32,index:0)
        encoder.dispatchThreads(MTLSize(width:output.width,height:output.height,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
        encoder.endEncoding(); return true
    }

    // Refresh only the display while paused/stopped; never trace another sample.
    func presentCurrentFrame(_ command: MTLCommandBuffer, output: MTLTexture) -> Bool {
        guard let raw=accumTexture else { return false }
        if let oidn = offlineDenoisedPreview {
            lastPresentationUsedMetalFX = false
            return encodeDisplay(command,display:oidn,raw:raw,output:output)
        }
        guard let display=lastDisplay else { return false }
        // MetalFX is temporal and only ever receives newly traced frames: a
        // refresh re-displays its cached output (or the raw accumulation), so it
        // neither degrades a converged image nor consumes a pending history reset.
        let denoised = display !== raw && denoiserEnabled && viewportMode == 0
        lastPresentationUsedMetalFX = denoised
        return encodeDisplay(command,display:denoised ? display : raw,raw:raw,output:output)
    }

    var reachedLimit: Bool {
        (options.maxSamples > 0 && frameIndex >= options.maxSamples) ||
        (options.timeLimit > 0 && renderElapsed >= options.timeLimit)
    }
    func draw(in view: MTKView) {
        let now=awakeSeconds(); defer { lastTick=now }
        guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        if paused || reachedLimit {
            // Refresh only the display while stopped; never trace another sample.
            guard presentationNeedsRefresh, accumTexture != nil,
                  lastDisplay != nil || offlineDenoisedPreview != nil,
                  let drawable=view.currentDrawable else { return }
            if let command=commandQueue.makeCommandBuffer(), presentCurrentFrame(command,output:drawable.texture) {
                presentationNeedsRefresh = false
                command.present(drawable);command.commit()
            }
            return
        }
        renderElapsed += max(0,now-lastTick)
        // Reserve an in-flight slot before currentDrawable: nextDrawable blocks
        // the main thread while in-flight frames hold every drawable.
        guard inFlightFrames.wait(timeout: .now()) == .success else { return }
        guard let drawable=view.currentDrawable else { inFlightFrames.signal(); return }
        renderFrame(output:drawable.texture,drawable:drawable,reservedFrameSlot:true)
    }
    func renderFrame(output: MTLTexture, drawable: CAMetalDrawable? = nil, reservedFrameSlot: Bool = false) {
        guard reservedFrameSlot || inFlightFrames.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlightFrames.signal() } }
        let w=max(1,Int(Float(output.width)*options.previewScale))
        let h=max(1,Int(Float(output.height)*options.previewScale))
        if let message = renderMemoryError(width: w, height: h) {
            let size = SIMD2(w, h)
            if rejectedRenderSize != size { rejectedRenderSize = size; onError?(message) }
            return
        }
        rejectedRenderSize = nil
        // Float32 running means lose unit sample precision after 2^24 samples.
        if frameIndex >= 16_777_215 { resetAccumulation() }
        // Light transport of this frame; accumulation restarts when it changes (spectral pipelines
        // becoming ready, or a failure falling back to RGB).
        let spectral = activeLightTransport == .spectral && prepareSpectralShaders()
        if spectral != spectralFrame && frameIndex > 0 { resetAccumulation() }
        spectralFrame = spectral

        let needsReSTIR = samplingMode == 0 && viewportMode == 0
        let indirectReuse = activeIndirectReuse
        let usesPT = needsReSTIR && indirectReuse != .restirGI
        let reservoirs = reservoirSet(usesReSTIR: needsReSTIR)
        let resized = accumTexture == nil || accumTexture?.width != w || accumTexture?.height != h
        if resized || frameReservoirs != reservoirs {
            let desc32 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
            desc32.usage = [.shaderRead, .shaderWrite]
            desc32.storageMode = .private
            let desc16 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            desc16.usage = [.shaderRead, .shaderWrite]
            desc16.storageMode = .private

            func placeholder(_ format: MTLPixelFormat) -> MTLTextureDescriptor {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private; return d
            }
            // Each reservoir set is full size only in the modes that read it.
            let usesDI = needsReSTIR && indirectReuse != .restirPTUnified
            let usesGI = needsReSTIR && indirectReuse == .restirGI
            let reservoir32 = usesDI ? desc32 : placeholder(.rgba32Float)
            let gi32 = usesGI ? desc32 : placeholder(.rgba32Float)
            let gi16 = usesGI ? desc16 : placeholder(.rgba16Float)
            let indirect32 = usesPT ? desc32 : placeholder(.rgba32Float)
            let duplicationFormat = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
            duplicationFormat.usage = [.shaderRead, .shaderWrite]; duplicationFormat.storageMode = .private
            let duplication16 = usesPT ? duplicationFormat : placeholder(.r16Float)
            func ptBuffer(_ bytesPerPixel: Int) -> MTLBuffer? {
                usesPT ? device.makeBuffer(length: w * h * bytesPerPixel, options: .storageModePrivate) : nil
            }
            let newPTReservoirs = ptBuffer(Self.ptReservoirStride), newPTHistory = ptBuffer(Self.ptReservoirStride)
            let newPTControls = ptBuffer(Self.ptControlStride)
            // Stochastic pairwise MIS stores its shift records in the paired shifts' buffer.
            let usesSPMISShifts = needsReSTIR && activeSpatialNeighbors == .stochasticPairwise
            let newPTShifts = ptBuffer(usesSPMISShifts ? max(Self.ptShiftBytesPerPixel, Self.spmisShiftBytesPerPixel) : Self.ptShiftBytesPerPixel)
            let newHistorySurfaces = ptBuffer(Int(Self.primarySurfaceStride))
            if usesPT && ptPairing == nil {
                ptPairing = ReSTIRPTPairing.deltas.withUnsafeBytes {
                    device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                }
            }
            // Reservoir splatting (HONG2026): two deep-domain pools and the per-pixel splat state.
            var newSplat: (current: SplatPool, previous: SplatPool, mask: MTLBuffer, layers: MTLBuffer, sources: MTLBuffer)?
            if needsReSTIR && activeTemporalReuse == .splatting {
                let capacity = Self.splatCapacity(width: w, height: h)
                func buffer(_ length: Int) -> MTLBuffer? { device.makeBuffer(length: max(16, length), options: .storageModePrivate) }
                func pool() -> SplatPool? {
                    guard let domains = buffer(capacity * 32), let surfaces = buffer(capacity * Int(Self.primarySurfaceStride)),
                          let counters = device.makeBuffer(length: 16, options: .storageModeShared) else { return nil }
                    let words = counters.contents().bindMemory(to: UInt32.self, capacity: 4)
                    words[0] = 0; words[1] = 0; words[2] = UInt32(capacity); words[3] = 0
                    let di = usesDI ? buffer(capacity * 48) : nil, gi = usesGI ? buffer(capacity * 64) : nil
                    let pt = usesPT ? buffer(capacity * Self.ptReservoirStride) : nil
                    let controls = usesPT ? buffer(capacity * Self.ptControlStride) : nil
                    guard di != nil || !usesDI, gi != nil || !usesGI, pt != nil && controls != nil || !usesPT else { return nil }
                    return SplatPool(domains: domains, surfaces: surfaces, counters: counters, di: di, gi: gi, pt: pt,
                                     controls: controls, capacity: capacity)
                }
                guard let a = pool(), let b = pool(), let mask = buffer(w * h * 4), let layers = buffer(w * h * 48),
                      let sources = buffer((w * h + capacity) * 8) else {
                    onError?("Could not allocate render textures. Try a smaller window.")
                    return
                }
                newSplat = (a, b, mask, layers, sources)
            }
            if splatPlaceholder == nil { splatPlaceholder = device.makeBuffer(length: 64, options: .storageModePrivate) }
            // Stochastic pairwise MIS reuse cells (SPMIS2026).
            let usesSPMIS = needsReSTIR && activeSpatialNeighbors == .stochasticPairwise
            let tileSlots = ((w + Self.spmisTile - 1) / Self.spmisTile) * ((h + Self.spmisTile - 1) / Self.spmisTile)
                * Self.spmisTile * Self.spmisTile
            let newSPMISCells = usesSPMIS ? device.makeBuffer(length: w * h * 16, options: .storageModePrivate) : nil
            let newSPMISSlots = usesSPMIS ? device.makeBuffer(length: tileSlots * 12, options: .storageModePrivate) : nil
            let newSPMISChoices = usesSPMIS ? device.makeBuffer(length: w * h * 16, options: .storageModePrivate) : nil
            if usesSPMIS && (newSPMISCells == nil || newSPMISSlots == nil || newSPMISChoices == nil) {
                onError?("Could not allocate render textures. Try a smaller window.")
                return
            }

            // Only the DI/GI reservoirs depend on the strategy and inspection view;
            // keep the accumulation, G-buffer, guides and sample count when just
            // those change. Publish a complete set only after every allocation succeeds.
            let frameDescriptors = resized ? [desc32, desc32, desc32, desc32, desc16, desc16, desc16, desc32, desc32] : []
            let frame = frameDescriptors.compactMap { device.makeTexture(descriptor: $0) }
            guard frame.count == frameDescriptors.count,
                  let newPosA = device.makeTexture(descriptor: reservoir32),
                  let newEmitA = device.makeTexture(descriptor: reservoir32),
                  let newWeightA = device.makeTexture(descriptor: reservoir32),
                  let newPosB = device.makeTexture(descriptor: reservoir32),
                  let newEmitB = device.makeTexture(descriptor: reservoir32),
                  let newWeightB = device.makeTexture(descriptor: reservoir32),
                  let newGIPosA = device.makeTexture(descriptor: gi32),
                  let newGINormalA = device.makeTexture(descriptor: gi16),
                  let newGIRadianceA = device.makeTexture(descriptor: gi32),
                  let newGIWeightsA = device.makeTexture(descriptor: gi32),
                  let newGIPosB = device.makeTexture(descriptor: gi32),
                  let newGINormalB = device.makeTexture(descriptor: gi16),
                  let newGIRadianceB = device.makeTexture(descriptor: gi32),
                  let newGIWeightsB = device.makeTexture(descriptor: gi32),
                  let newPTIndirect = device.makeTexture(descriptor: indirect32),
                  let newDuplication = device.makeTexture(descriptor: duplication16),
                  !usesPT || (newPTReservoirs != nil && newPTHistory != nil && newPTShifts != nil
                              && newHistorySurfaces != nil && ptPairing != nil && newPTControls != nil),
                  // Primary surfaces depend only on the frame size.
                  let newSurfaces = resized
                    ? device.makeBuffer(length: w * h * Int(Self.primarySurfaceStride), options: .storageModePrivate)
                    : primarySurfaceBuffer(width: w, height: h) else {
                onError?("Could not allocate render textures. Try a smaller window.")
                return
            }
            primarySurfaces = newSurfaces
            if resized {
                accumTexture = frame[0]
                sampleTexture = frame[1]
                gbufferPosDepth = frame[2]
                historyPosDepth = frame[3]
                gbufferNormalMat = frame[4]
                historyNormalMat = frame[5]
                gbufferAlbedoRough = frame[6]
                oidnAlbedoAccum = frame[7]
                oidnNormalAccum = frame[8]
            }
            resPosDirA = newPosA; resEmitPdfA = newEmitA; resWeightsA = newWeightA
            resPosDirB = newPosB; resEmitPdfB = newEmitB; resWeightsB = newWeightB
            giPosPdfA = newGIPosA; giNormalA = newGINormalA
            giRadianceA = newGIRadianceA; giWeightsA = newGIWeightsA
            giPosPdfB = newGIPosB; giNormalB = newGINormalB
            giRadianceB = newGIRadianceB; giWeightsB = newGIWeightsB
            ptIndirect = newPTIndirect; ptDuplication = newDuplication
            ptReservoirs = newPTReservoirs; ptHistory = newPTHistory; ptShifts = newPTShifts; ptControls = newPTControls
            historyPrimarySurfaces = newHistorySurfaces
            splatCurrent = newSplat?.current; splatPrevious = newSplat?.previous
            splatMask = newSplat?.mask; splatLayers = newSplat?.layers; splatSources = newSplat?.sources
            spmisCells = newSPMISCells; spmisSlots = newSPMISSlots; spmisChoices = newSPMISChoices
            frameReservoirs = reservoirs

            if resized {
                reservoirHistoryNeedsReset = false
                resetAccumulation()
            } else {
                // New reservoirs hold no history: disable temporal reuse for one frame.
                reservoirHistoryNeedsReset = true
            }
        }

        guard let accum = accumTexture, let samples = sampleTexture,
              let gPos = gbufferPosDepth,
              let gNorm = gbufferNormalMat,
              let gAlb = gbufferAlbedoRough,
              let hPos = historyPosDepth, let hNorm = historyNormalMat,
              let rPosA = resPosDirA, let rEmitA = resEmitPdfA, let rWeightA = resWeightsA,
              let rPosB = resPosDirB, let rEmitB = resEmitPdfB, let rWeightB = resWeightsB,
              let giPosA = giPosPdfA, let giNormA = giNormalA,
              let giRadA = giRadianceA, let giWeightA = giWeightsA,
              let giPosB = giPosPdfB, let giNormB = giNormalB,
              let giRadB = giRadianceB, let giWeightB = giWeightsB,
              let ptOut = ptIndirect, let duplication = ptDuplication,
              let oidnAlbedo = oidnAlbedoAccum, let oidnNormal = oidnNormalAccum,
              let surfaces = primarySurfaceBuffer(width: w, height: h), let placeholder = splatPlaceholder,
              let cmdBuffer = commandQueue.makeCommandBuffer() else { return }

        let nextFrame = frameIndex + 1
        let nextSample = sampleIndex == UInt32.max ? 1 : sampleIndex + 1
        // Inspection and non-ReSTIR frames leave reservoirs unwritten.
        let nextHistory = needsReSTIR ? min(reservoirHistory, 1 << 24) + 1 : 0
        // Reservoir splatting replaces reprojection on frames where the view changed and history is
        // valid (as ReSTIR PT reuses temporally only then); a thin lens is not splatted (HONG2026 Sec. 7).
        let splatState = splatCurrent.flatMap { current in splatPrevious.map { (current, $0) } }
        let splatFrame = splatState != nil && needsReSTIR && nextFrame <= 1 && nextHistory > 1
            && !reservoirHistoryNeedsReset && options.aperture <= 0 && sceneKernels.splat != nil

        let camX = target.x + distance * cos(pitch) * sin(yaw)
        let camY = target.y + distance * sin(pitch)
        let camZ = target.z - distance * cos(pitch) * cos(yaw)
        let eye = SIMD3<Float>(camX, camY, camZ)

        let az=options.sunAzimuth * .pi / 180, el=options.sunElevation * .pi / 180
        let sunDir=SIMD3<Float>(sin(az)*cos(el),sin(el),cos(az)*cos(el))
        let sunIntensity=options.sunIntensity

        let aspect = Float(w) / Float(h)
        let fovRad = fov * .pi / 180.0
        let clip = cameraClipPlanes()
        let proj = makePerspective(fovyRadians: fovRad, aspect: aspect, near: clip.near, far: clip.far)
        let viewMat = makeLookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
        let currViewProj = proj * viewMat

        var uniforms = Uniforms(
            cameraPos: SIMD4<Float>(camX, camY, camZ, fov),
            cameraTarget: SIMD4<Float>(target.x, target.y, target.z, options.depth),
            cameraUp: SIMD4<Float>(0, 1, 0, 0),
            sunParams: SIMD4<Float>(sunDir.x, sunDir.y, sunDir.z, sunIntensity),
            currentViewProj: currViewProj,
            prevViewProj: prevViewProj,
            frameIndex: nextFrame,
            sceneIndex: sceneIndex,
            samplingMode: samplingMode,
            enableSMS: enableSMS,
            skyMode: skyMode,
            enableFog: enableFog,
            viewportMode: viewportMode,
            width: UInt32(w),
            height: UInt32(h),
            indirectReuse: indirectReuse.rawValue | (ptDecorrelation ? 4 : 0) | (ptTemporalWhileAccumulating ? 8 : 0)
                | (splatFrame ? 16 : 0) | (usesPT && activeControlVariates == .restcv ? 32 : 0)
                | (activeSampler == .zSampling ? 64 | (zTemporal.rawValue << 7) : 0),
            jitter: frameJitter(nextSample), sampleIndex: nextSample,
            reservoirHistoryReset: reservoirHistoryNeedsReset ? 1 : 0, reservoirHistory: nextHistory,
            spatialNeighbors: activeSpatialNeighbors.rawValue,
            environment: SIMD4(options.environmentIntensity, options.environmentRotation * .pi / 180, materials.environmentData == nil ? 0 : 1, Float(materials.nodeCount)),
            lens: SIMD4(options.aperture,options.focusDistance,materials.hasSceneGraph ? 1 : 0,sceneIndex == 6 ? options.independentSunCone : 0),
            light: SIMD4(options.lightColor*options.lightIntensity,options.lightSize)
        )
        uniforms.sceneGraphMode = materials.hasSceneGraph
        lastUniforms=uniforms

        // Spectral transport: the scene's wavelength sampling (rebuilt when its illuminants change) and
        // its spectral state, bound to every pass at buffers 27-29.
        var spectralWords = [UInt32]()
        var spectralWeights: [Float]?
        if spectralFrame {
            guard let weights = encodeSpectralSampling(cmdBuffer) else { return }
            spectralWeights = weights
            spectralWords = spectralSceneWords()
        }
        func bindSpectral(_ encoder: MTLComputeCommandEncoder) {
            guard spectralFrame, let grid = spectralShaders.grid, let sampling = spectralSampling else { return }
            spectralWords.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 27) }
            encoder.setBuffer(grid, offset: 0, index: 28)
            encoder.setBuffer(sampling, offset: 0, index: 29)
        }

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let gridSize = MTLSize(width: w, height: h, depth: 1)

        // Splat state: this frame's pool starts empty (so a frame that does not splat leaves the next
        // one no deep domains); a splat frame also clears the activation masks and splat sources.
        if let (current, _) = splatState, let mask = splatMask, let sources = splatSources {
            guard let blit = cmdBuffer.makeBlitCommandEncoder() else { return }
            blit.label = "Splat: clear"
            blit.fill(buffer: current.counters, range: 0..<8, value: 0)
            if splatFrame {
                blit.fill(buffer: mask, range: 0..<mask.length, value: 0)
                blit.fill(buffer: sources, range: 0..<sources.length, value: 0xff)
            }
            blit.endEncoding()
        }
        // Buffers 9-23 of the splat kernels (MSL "Multi-layer reservoir splatting").
        func bindSplatBuffers(_ encoder: MTLComputeCommandEncoder) {
            guard let (current, previous) = splatState else { return }
            let buffers: [(Int, MTLBuffer?)] = [
                (9, previous.domains), (10, previous.surfaces), (11, previous.counters),
                (12, current.domains), (13, current.surfaces), (14, current.counters),
                (15, splatMask), (16, splatLayers), (17, splatSources),
                (18, previous.di), (19, current.di), (20, previous.gi), (21, current.gi), (22, previous.pt), (23, current.pt),
                (25, current.controls), (26, previous.controls)]
            for (index, buffer) in buffers { encoder.setBuffer(buffer ?? placeholder, offset: 0, index: index) }
        }

        // PASS 1: G-Buffer & ReSTIR Temporal Reuse
        guard let enc1 = cmdBuffer.makeComputeCommandEncoder() else { return }
        do {
            enc1.label = "Pass 1: G-Buffer & ReSTIR Temporal"
            enc1.setComputePipelineState(sceneKernels.temporal)
            enc1.setTexture(gPos, index: 0)
            enc1.setTexture(gNorm, index: 1)
            enc1.setTexture(gAlb, index: 2)
            enc1.setTexture(rPosA, index: 3)
            enc1.setTexture(rEmitA, index: 4)
            enc1.setTexture(rWeightA, index: 5)
            enc1.setTexture(rPosB, index: 6)
            enc1.setTexture(rEmitB, index: 7)
            enc1.setTexture(rWeightB, index: 8)
            enc1.setTexture(hPos, index: 9)
            enc1.setTexture(hNorm, index: 10)
            enc1.setTexture(giPosA, index: 11)
            enc1.setTexture(giNormA, index: 12)
            enc1.setTexture(giRadA, index: 13)
            enc1.setTexture(giWeightA, index: 14)
            enc1.setTexture(giPosB, index: 15)
            enc1.setTexture(giNormB, index: 16)
            enc1.setTexture(giRadB, index: 17)
            enc1.setTexture(giWeightB, index: 18)
            guard materials.bind(enc1) else {
                enc1.endEncoding()
                onError?("Could not update material bindings.")
                return
            }
            enc1.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc1.setBuffer(surfaces, offset: 0, index: 3)
            bindSpectral(enc1)
            enc1.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            enc1.endEncoding()
        }

        // Multi-layer reservoir splatting (REFERENCES.md: HONG2026): domain activation, deep layers,
        // deep-domain canonical samples, reservoir splats and the DI/GI temporal merge. ReSTIR PT's
        // temporal merge runs with its passes below.
        let usesDIReservoirs = needsReSTIR && indirectReuse != .restirPTUnified
        if splatFrame, let kernels = sceneKernels.splat, let (current, _) = splatState {
            let pixels = w * h, slots = current.capacity
            // Grid: nil for one thread per pixel (2D), else a 1D thread count.
            var passes: [(String, MTLComputePipelineState, Int?)] = [
                ("Splat: domain activation", kernels.activate, pixels + slots), ("Splat: deep layers", kernels.layers, nil)]
            if usesDIReservoirs { passes.append(("Splat: deep DI/GI samples", kernels.deepReSTIR, slots)) }
            if usesPT { passes.append(("Splat: deep ReSTIR PT paths", kernels.deepPT, slots)) }
            passes.append(("Splat: reservoir splats", kernels.reservoirs, pixels + slots))
            if usesDIReservoirs { passes.append(("Splat: DI/GI temporal reuse", kernels.temporal, pixels + slots)) }
            for (label, pipeline, count) in passes {
                guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { return }
                encoder.label = label
                encoder.setComputePipelineState(pipeline)
                let textures: [MTLTexture] = [gPos, gNorm, hPos, hNorm, duplication, rPosA, rEmitA, rWeightA, rPosB, rEmitB, rWeightB,
                                              giPosA, giNormA, giRadA, giWeightA, giPosB, giNormB, giRadB, giWeightB]
                for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
                guard materials.bind(encoder) else {
                    encoder.endEncoding()
                    onError?("Could not update material bindings.")
                    return
                }
                encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                for (index, buffer) in [surfaces, historyPrimarySurfaces, ptReservoirs, ptHistory].enumerated() {
                    encoder.setBuffer(buffer ?? placeholder, offset: 0, index: index + 3)
                }
                bindSplatBuffers(encoder)
                bindSpectral(encoder)
                if let count {
                    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                } else {
                    encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
                }
                encoder.endEncoding()
            }
        }

        // Stochastic pairwise MIS (REFERENCES.md: SPMIS2026): the reuse cells, built from the final
        // temporal reservoirs just before spatial reuse (ReSTIR PT's below, DI/GI's in pass 2).
        let spmis = spmisCells.flatMap { cells in spmisSlots.flatMap { slots in spmisChoices.map { (cells, slots, $0) } } }
        func bindSPMIS(_ encoder: MTLComputeCommandEncoder) {
            guard let (cells, slots, choices) = spmis else { return }
            encoder.setBuffer(cells, offset: 0, index: 9)
            encoder.setBuffer(slots, offset: 0, index: 10)
            encoder.setBuffer(choices, offset: 0, index: 11)
        }
        // Reuse cells (spmis_cells_kernel, one threadgroup per tile), then each pixel's cell choice.
        func encodeSPMISCells(ptReservoirs: MTLBuffer?) -> Bool {
            guard spmis != nil, let kernels = sceneKernels.spmis else { return true }
            for (label, pipeline) in [("Stochastic pairwise MIS: reuse cells", kernels.cells),
                                      ("Stochastic pairwise MIS: cell choice", kernels.select)] {
                guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { return false }
                encoder.label = label
                encoder.setComputePipelineState(pipeline)
                for (index, texture) in [gPos, gNorm, rWeightA, giWeightA].enumerated() { encoder.setTexture(texture, index: index) }
                encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setBuffer(surfaces, offset: 0, index: 3)
                encoder.setBuffer(ptReservoirs ?? placeholder, offset: 0, index: 5)
                bindSPMIS(encoder)
                if pipeline === kernels.cells {
                    let tile = Self.spmisTile
                    encoder.dispatchThreadgroups(MTLSize(width: (w + tile - 1) / tile, height: (h + tile - 1) / tile, depth: 1),
                                                 threadsPerThreadgroup: MTLSize(width: tile, height: tile, depth: 1))
                } else {
                    encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
                }
                encoder.endEncoding()
            }
            return true
        }

        // ReSTIR PT (REFERENCES.md: RESTIRPT2022, RESTIRPTE2026): initial paths and temporal
        // reuse, paired shifts, spatial reuse, then (optionally) the duplication map. With stochastic
        // pairwise MIS, the reuse cells and restir_pt_spmis_kernel replace the paired passes.
        if usesPT {
            guard let current = ptReservoirs, let history = ptHistory, let shifts = ptShifts,
                  let historySurfaces = historyPrimarySurfaces, let pairing = ptPairing, let controls = ptControls,
                  let kernels = sceneKernels.pt else { return }
            // A nil pipeline is the reuse-cell pass of stochastic pairwise MIS (encodeSPMISCells).
            var passes: [(String, MTLComputePipelineState?, Bool)] = [("ReSTIR PT: initial paths", kernels.initial, true)]
            // Temporal reuse only while the view changes (MSL restir_pt_temporal); by splatting on splat frames.
            let splatTemporal = splatFrame ? sceneKernels.splat?.ptTemporal : nil
            if let splatTemporal {
                passes.append(("ReSTIR PT: splat temporal reuse", splatTemporal, true))
            } else if nextFrame <= 1 || ptTemporalWhileAccumulating {
                passes.append(("ReSTIR PT: temporal reuse", kernels.temporal, true))
            }
            let spmisShift = spmis != nil ? sceneKernels.spmis?.ptShift : nil
            if let spmisShift, let spmisPT = sceneKernels.spmis?.pt {
                passes += [
                    ("Stochastic pairwise MIS: reuse cells", nil, false),
                    ("ReSTIR PT: stochastic pairwise MIS shifts", spmisShift, true),
                    ("ReSTIR PT: stochastic pairwise MIS spatial reuse", spmisPT, false)]
            } else {
                passes += [
                    ("ReSTIR PT: paired shifts", kernels.shift, true),
                    ("ReSTIR PT: spatial reuse", kernels.spatial, false)]
            }
            if ptDecorrelation { passes.append(("ReSTIR PT: duplication map", kernels.duplication, false)) }
            for (label, step, bindsMaterials) in passes {
                guard let pipeline = step else {
                    guard encodeSPMISCells(ptReservoirs: current) else { return }
                    continue
                }
                guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { return }
                encoder.label = label
                encoder.setComputePipelineState(pipeline)
                for (index, texture) in [gPos, gNorm, hPos, hNorm, duplication, ptOut].enumerated() { encoder.setTexture(texture, index: index) }
                if bindsMaterials {
                    guard materials.bind(encoder) else {
                        encoder.endEncoding()
                        onError?("Could not update material bindings.")
                        return
                    }
                }
                encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                for (index, buffer) in [surfaces, historySurfaces, current, history, shifts, pairing].enumerated() {
                    encoder.setBuffer(buffer, offset: 0, index: index + 3)
                }
                encoder.setBuffer(controls, offset: 0, index: 24)
                bindSPMIS(encoder)
                bindSpectral(encoder)
                if pipeline === splatTemporal, let slots = splatState?.0.capacity {
                    bindSplatBuffers(encoder)
                    encoder.dispatchThreads(MTLSize(width: w * h + slots, height: 1, depth: 1),
                                            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                } else if pipeline === spmisShift {
                    encoder.dispatchThreads(MTLSize(width: w, height: h, depth: Self.spmisPTCandidates + 1),
                                            threadsPerThreadgroup: threadsPerGroup)
                } else {
                    encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
                }
                encoder.endEncoding()
            }
        }

        // ReSTIR GI: the reuse cells of the DI and GI reservoirs.
        if !usesPT && needsReSTIR { guard encodeSPMISCells(ptReservoirs: nil) else { return } }

        // PASS 2: Spatial Resampling & Full Path Tracing
        guard let enc2 = cmdBuffer.makeComputeCommandEncoder() else { return }
        do {
            enc2.label = "Pass 2: Spatial Resampling & Shading"
            enc2.setComputePipelineState(sceneKernels.shading)
            enc2.setTexture(gPos, index: 0)
            enc2.setTexture(gNorm, index: 1)
            enc2.setTexture(gAlb, index: 2)
            enc2.setTexture(rPosA, index: 3)
            enc2.setTexture(rEmitA, index: 4)
            enc2.setTexture(rWeightA, index: 5)
            enc2.setTexture(accum, index: 6)
            enc2.setTexture(samples, index: 7)
            enc2.setTexture(giPosA, index: 8)
            enc2.setTexture(giNormA, index: 9)
            enc2.setTexture(giRadA, index: 10)
            enc2.setTexture(giWeightA, index: 11)
            enc2.setTexture(oidnAlbedo, index: 12)
            enc2.setTexture(oidnNormal, index: 13)
            enc2.setTexture(ptOut, index: 14)
            guard materials.bind(enc2) else {
                enc2.endEncoding()
                onError?("Could not update material bindings.")
                return
            }
            enc2.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc2.setBuffer(surfaces, offset: 0, index: 3)
            enc2.setBuffer(spmis?.0 ?? placeholder, offset: 0, index: 4)
            enc2.setBuffer(spmis?.1 ?? placeholder, offset: 0, index: 5)
            enc2.setBuffer(spmis?.2 ?? placeholder, offset: 0, index: 6)
            bindSpectral(enc2)
            enc2.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            enc2.endEncoding()
        }

        guard encodePresentation(commandBuffer: cmdBuffer, accumulation: accum, samples: samples,
            positions: gPos, normals: gNorm, materials: gAlb, output: output,
            uniforms: uniforms) != nil else { return }

        let tmpPos = resPosDirA; resPosDirA = resPosDirB; resPosDirB = tmpPos
        let tmpEmit = resEmitPdfA; resEmitPdfA = resEmitPdfB; resEmitPdfB = tmpEmit
        let tmpWeight = resWeightsA; resWeightsA = resWeightsB; resWeightsB = tmpWeight
        swap(&giPosPdfA, &giPosPdfB)
        swap(&giNormalA, &giNormalB)
        swap(&giRadianceA, &giRadianceB)
        swap(&giWeightsA, &giWeightsB)

        swap(&gbufferPosDepth, &historyPosDepth)
        swap(&gbufferNormalMat, &historyNormalMat)
        swap(&splatCurrent, &splatPrevious)
        lastFrameSplatted = splatFrame
        self.prevViewProj = currViewProj
        frameIndex = nextFrame
        sampleIndex = nextSample
        reservoirHistory = nextHistory
        // Count inspection frames by the mode they were submitted in, matching
        // frameIndex, so frames still in flight across a switch are not misattributed.
        if viewportMode > 0 { debugFrames &+= 1 }
        reservoirHistoryNeedsReset = false
        let submittedGeneration = generation
        let semaphore = inFlightFrames
        cmdBuffer.addCompletedHandler { [weak self] completedBuffer in
            semaphore.signal()
            let errorMessage = completedBuffer.error?.localizedDescription
            let succeeded = completedBuffer.status == .completed
            let gpuMilliseconds = (completedBuffer.gpuEndTime - completedBuffer.gpuStartTime) * 1000
            DispatchQueue.main.async {
                guard let self = self else { return }
                if succeeded {
                    guard self.generation == submittedGeneration else { return }
                    self.completedSamples=nextFrame
                    self.gpuMilliseconds=gpuMilliseconds
                    let now=Date(), interval=now.timeIntervalSince(self.lastCompletion)
                    self.framesPerSecond=interval>0 ? 1/interval : 0; self.lastCompletion=now
                    self.onFrameUpdate?(nextFrame)
                } else {
                    self.resetAccumulation()
                    self.onError?(errorMessage ?? "Metal could not render this frame.")
                }
            }
        }
        if let drawable { cmdBuffer.present(drawable) }
        if let spectralWeights { spectralSamplingWeights = spectralWeights }
        cmdBuffer.commit()
        committed = true
    }
}

// ============================================================================
// 3. Mouse & Orbit Camera Controls
// ============================================================================

class InteractiveMTKView: MTKView {
    weak var renderer: PathTracerRenderer?
    var onUserOrbit: (() -> Void)?
    var onBeginEdit: (() -> Void)?
    var onPick: ((SIMD2<Float>) -> Void)?
    // Camera gestures are ignored while this returns false (busy project I/O, export).
    var canEdit: (() -> Bool)?
    private var dragged=false
    private var beganEdit=false
    private var lastPos: NSPoint = .zero
    private var downPos: NSPoint = .zero
    // Cumulative pointer travel (points) before a press becomes a camera drag.
    static let dragThreshold: CGFloat = 3

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragged=false; beganEdit=false
        lastPos = convert(event.locationInWindow, from: nil)
        downPos = lastPos
    }

    override func mouseDragged(with event: NSEvent) {
        guard canEdit?() ?? true else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Slow drags accumulate from the press location; nothing moves until the threshold.
        if !dragged {
            guard hypot(p.x - downPos.x, p.y - downPos.y) > Self.dragThreshold else { return }
            dragged = true
        }
        let dx = Float(p.x - lastPos.x)
        let dy = Float(p.y - lastPos.y)
        lastPos = p

        if !beganEdit { beganEdit = true; onBeginEdit?() }
        if event.modifierFlags.contains(.shift), let renderer {
            let forward=simd_normalize(renderer.target-renderer.eyePosition)
            let right=simd_normalize(simd_cross(forward,SIMD3<Float>(0,1,0))), up=simd_cross(right,forward)
            renderer.target += (-right*dx-up*dy)*(renderer.distance*0.0015)
            onUserOrbit?();return
        }
        renderer?.yaw += dx * 0.007
        renderer?.pitch = max(-1.45, min(1.45, (renderer?.pitch ?? 0.0) - dy * 0.007))
        onUserOrbit?()
    }

    override func mouseUp(with event: NSEvent) {
        guard canEdit?() ?? true else { return }
        if !dragged {
            let p=convert(event.locationInWindow,from:nil)
            onPick?(SIMD2(Float(p.x/bounds.width),Float(1-p.y/bounds.height)))
            return  // A click selects; it does not edit the camera or mark the document edited.
        }
        onUserOrbit?()
    }
    override func scrollWheel(with event: NSEvent) {
        guard canEdit?() ?? true, let renderer else { return }
        // Notched wheels report line deltas; trackpads report precise point deltas.
        let delta = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 10)
        guard delta != 0 else { return }
        onBeginEdit?()
        renderer.distance = max(0.0001, min(1_000_000, renderer.distance * exp(-delta * 0.015)))
        onUserOrbit?()
    }
}

// ============================================================================
// 5. App Entry Point
// ============================================================================

// Top-level code runs on the main thread; stating it keeps a Swift 5 mode typecheck valid.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
