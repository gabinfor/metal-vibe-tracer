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
    float2 jitter;         // Shared subpixel offset, in pixels, excluding the 0.5 pixel center.
    uint sampleIndex;      // Continues across orbit changes, independently of accumulation.
    uint reservoirHistoryReset; // 1 = DI/GI history reservoirs were just allocated; skip temporal reuse
    uint reservoirHistory; // Consecutive ReSTIR frames; camera moves keep it, cuts reset it.
    uint spatialNeighbors; // ReSTIR spatial neighbour selection: 0 = uniform, 1 = compatibility-guided
    float4 environment; // intensity, rotation, image enabled, BVH node count
    float4 lens; // aperture radius, focus distance, scene-graph mode (see uses_scene_graph), independent sun 1 - cos(half angle)
    float4 light; // RGB multiplier, size multiplier
};

// lens.z = 1 renders scene 6 from the imported scene graph: per-triangle material
// slots and emission, an identity root transform, and float-scaled ray offsets.
bool uses_scene_graph(constant Uniforms &u) { return u.lens.z > 0; }

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
// REFERENCES.md: PBRT2023. Thin-lens focus-plane construction; uniform disk sampling.
void lens_ray(thread Ray &ray, float3 forward, float3 right, float3 up, constant Uniforms &u, thread uint &seed) {
    if(u.lens.x<=0) return;
    float2 random=rand_f2(seed); float radius=sqrt(random.x)*u.lens.x, angle=TWO_PI*random.y;
    float3 focus=ray.origin+ray.direction*(u.lens.y/max(1e-5f,dot(ray.direction,forward)));
    ray.origin+=radius*(cos(angle)*right+sin(angle)*up); ray.direction=normalize(focus-ray.origin);
}
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

float3 sample_cosine_hemisphere(float3 n, thread uint &seed) {
    float2 r = rand_f2(seed);
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

float3 eval_bsdf(Material mat, float3 n, float3 wo, float3 wi) {
    if (mat.transmission == 0.0f && dot(mat.geometricNormal, mat.geometricNormal) > 0.5f && dot(wi, mat.geometricNormal) <= 0.0f) return float3(0);
    float cosine = abs(dot(n, wi));
    if (cosine < 1e-7f || dot(n, wo) <= 0.0f) return float3(0);
    // Uncoated legacy diffuse is the Lambert limit of the OpenPBR inputs.
    // Avoid preparing all layered lobes for every ReSTIR candidate.
    if (mat.type == DIFFUSE) return dot(n, wi) > 0.0f ? clamp(mat.albedo, 0.0f, 1.0f) / PI : float3(0);
    OpenPBR_PreparedBsdf prepared = prepare_openpbr(mat, n, wo);
    OpenPBR_DiffuseSpecular value = openpbr_eval(prepared, wi);
    // Upstream already includes cosine; this adapter returns f for existing callers.
    return openpbr_get_sum_of_diffuse_specular(value) / cosine;
}

float eval_bsdf_pdf(Material mat, float3 n, float3 wo, float3 wi) {
    if (dot(n, wo) <= 0.0f) return 0.0f;
    if (mat.type == DIFFUSE) return max(0.0f, dot(n, wi)) / PI;
    OpenPBR_PreparedBsdf prepared = prepare_openpbr(mat, n, wo);
    return openpbr_pdf(prepared, wi);
}

// Direct lighting needs both values; prepare the layered BSDF only once.
float3 eval_bsdf_with_pdf(Material mat, float3 n, float3 wo, float3 wi, thread float &pdf) {
    if (mat.type == DIFFUSE) {
        pdf = eval_bsdf_pdf(mat, n, wo, wi);
        return eval_bsdf(mat, n, wo, wi);
    }
    pdf = 0.0f;
    float cosine = abs(dot(n, wi));
    if (cosine < 1e-7f || dot(n, wo) <= 0.0f) return float3(0);
    OpenPBR_PreparedBsdf prepared = prepare_openpbr(mat, n, wo);
    pdf = openpbr_pdf(prepared, wi);
    if (mat.transmission == 0.0f && dot(mat.geometricNormal, mat.geometricNormal) > 0.5f && dot(wi, mat.geometricNormal) <= 0.0f) return float3(0);
    return openpbr_get_sum_of_diffuse_specular(openpbr_eval(prepared, wi)) / cosine;
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
LightSample sample_direct_light(float3 p, float3 n, constant Uniforms &u, thread uint &seed, constant MaterialResources &materialImages) {
    LightSample ls = {};
    float importedProbability=imported_light_probability(u,materialImages);
    if(importedProbability>0 && rand_f(seed)<importedProbability) {
        uint count=materialImages.emitters[0],low=0,high=count-1;float value=rand_f(seed);
        while(low<high) {uint middle=(low+high)/2;if(as_type<float>(materialImages.emitters[1+count+middle])>=value) high=middle; else low=middle+1;}
        uint index=materialImages.emitters[1+low];
        MeshTriangle t=scene_triangle(index,materialImages);float2 r=rand_f2(seed);float root=sqrt(r.x);
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
        if (sunProbability > 0.0f && rand_f(seed) < sunProbability) {
            // Sun cone sampling; sin^2 is formed from 1 - cos for sub-degree suns.
            float3 sun_d = normalize(u.sunParams.xyz);
            float2 r = rand_f2(seed);
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
            uint y = environment_cdf_index(materialImages.environmentRows, height, 0, rand_f(seed), true);
            uint x = environment_cdf_index(materialImages.environmentColumns, width, y, rand_f(seed), false);
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
            ls.wi = sample_cosine_hemisphere(n, seed);
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
        float3 emit = (u.sceneIndex == 4) ? float3(32.0f, 28.0f, 22.0f) :
                      (u.sceneIndex == 3) ? float3(24.0f, 20.0f, 15.0f) : float3(18.0f, 15.0f, 10.0f);

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
            ls.emission = float3(45.0f, 42.0f, 38.0f);
            ls.pdf = (dist * dist) / (0.09f * u.light.w * u.light.w * cos_l);
        }
    } else if (u.sceneIndex == 2) {
        int pick = clamp(int(rand_f(seed) * 4.0f), 0, 3);
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
            float2 r = rand_f2(seed);
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
float3 sample_specular_manifold_caustic(float3 x, float3 n_x, constant Uniforms &u, thread uint &seed, constant MaterialResources &materialImages) {
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

float eval_restir_target_pdf(float3 p, float3 n, float3 rayDir, Material mat, LightSample candidate, uint sceneIndex, float lightSize,constant MaterialResources &images) {
    if (candidate.pdf <= 0.0f) return 0.0f;
    float3 dir = (candidate.isDirectional == 1) ? candidate.wi : normalize(candidate.position - p);
    float cos_th = max(0.0f, dot(n, dir));
    if (cos_th <= 0.0f) return 0.0f;
    float3 bsdf = eval_bsdf(mat, n, -rayDir, dir);
    return length(bsdf * candidate.emission * cos_th) * light_geometry(p, candidate, sceneIndex, lightSize,images);
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

float eval_restir_gi_target(float3 x1, float3 n1, float3 rayDir, Material mat,
                            float3 x2, float3 n2, float3 secondaryRadiance) {
    float geometry = gi_geometry(x1, n1, x2, n2);
    if (geometry <= 0.0f || !all(isfinite(secondaryRadiance))) return 0.0f;
    float3 direction = normalize(x2 - x1);
    return length(eval_bsdf(mat, n1, -rayDir, direction) * secondaryRadiance * geometry);
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

// Returns f * abs(cos(theta)) / PDF, using the same glossy model as NEE.
bool sample_bsdf(Material mat, float3 normal, float3 incoming, bool frontFace,
                 thread uint &seed, thread float3 &direction,
                 thread float3 &weight, thread float &pdf) {
    pdf = 0.0f;
    // A perturbed shading normal can send a delta event across the geometric
    // surface; repeat such an event about the geometric normal instead.
    float3 geometric = dot(mat.geometricNormal, mat.geometricNormal) > 0.5f ? mat.geometricNormal : normal;
    if (mat.type == DIELECTRIC) {
        float eta = frontFace ? 1.0f / mat.ior : mat.ior;
        float r0 = (1.0f - mat.ior) / (1.0f + mat.ior);
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
                weight = mat.albedo;
            } else {
                direction = normalize(eta * incoming + (eta * cosI - sqrt(1.0f - sin2T)) * m);
                weight = mat.albedo * (eta * eta);
            }
            if ((dot(direction, geometric) > 0.0f) == reflected) return true;
        }
        return false;
    }
    if (is_delta(mat)) {
        float3 m = dot(reflect(incoming, normal), geometric) > 0.0f ? normal : geometric;
        direction = normalize(reflect(incoming, m));
        float cosI = clamp(dot(-incoming, m), 0.0f, 1.0f);
        weight = mat.albedo + (1.0f - mat.albedo) * pow(1.0f - cosI, 5.0f);
        return dot(direction, geometric) > 0.0f;
    }
    if (mat.type == DIFFUSE) {
        // Keep three draws like the generic sampler, including its lobe choice.
        rand_f(seed);
        direction = sample_cosine_hemisphere(normal, seed);
        pdf = max(0.0f, dot(normal, direction)) / PI;
        weight = clamp(mat.albedo, 0.0f, 1.0f);
        return pdf > 0.0f && (dot(mat.geometricNormal, mat.geometricNormal) <= 0.5f || dot(direction, mat.geometricNormal) > 0.0f);
    }
    mat.inside = !frontFace;
    OpenPBR_PreparedBsdf prepared = prepare_openpbr(mat, normal, -incoming);
    OpenPBR_DiffuseSpecular result;
    uint lobe;
    float3 random = float3(rand_f(seed), rand_f(seed), rand_f(seed));
    openpbr_sample(prepared, random, direction, result, pdf, lobe);
    if (pdf <= 0.0f) return false;
    if (mat.transmission == 0.0f && dot(mat.geometricNormal, mat.geometricNormal) > 0.5f && dot(direction, mat.geometricNormal) <= 0.0f) return false;
    weight = openpbr_get_sum_of_diffuse_specular(result);
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
float3 apply_camera_fog(float3 color, Ray ray, float surfaceDistance,
                        constant Uniforms &u, thread uint &seed, constant MaterialResources &materialImages) {
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
        float t = entry + (float(i) + rand_f(seed)) * step;
        float3 point = ray.origin + ray.direction * t;
        LightSample ls = sample_direct_light(point, float3(0, 1, 0), u, seed, materialImages);
        if (light_visible(point, float3(0), ls, u.sceneIndex, materialImages, u)) {
            float lightDistance = ls.isDirectional == 1 ? 3.0f : ls.dist;
            float transmittance = exp(-sigmaT * (t - entry + lightDistance));
            scattered += transmittance * (0.85f * sigmaT) * ls.emission * step / (4.0f * PI * ls.pdf);
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
    packed_float3 emission; float reserved;       // Material.emission (MaterialX emission for OPENPBR)
};
static_assert(sizeof(PrimarySurface) == 120, "Swift allocates 120-byte primary surfaces");

PrimarySurface store_primary_surface(HitRecord hit) {
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
    s.emission = m.emission; s.reserved = 0.0f;
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
    device PrimarySurface *primarySurfaces [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) return;

    uint seed = (gid.y * uniforms.width + gid.x) ^ (uniforms.sampleIndex * 1999999973u);
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
    bool reservoirsBound = uniforms.viewportMode == 0 && uniforms.samplingMode == 0;
    if (!hit) {
        gbufferPosDepth.write(float4(0.0f, 0.0f, 0.0f, -1.0f), gid);
        gbufferNormalMat.write(float4(0.0f, 0.0f, 0.0f, -1.0f), gid);
        gbufferAlbedoRough.write(float4(0.0f), gid);
        if (!reservoirsBound) return;
        outSamplePosDir.write(float4(0.0f), gid);
        outSampleEmitPdf.write(float4(0.0f), gid);
        outReservoirWeights.write(float4(0.0f), gid);
        outGIPosPdf.write(float4(0.0f), gid);
        outGINormal.write(float4(0.0f), gid);
        outGIRadiance.write(float4(0.0f), gid);
        outGIWeights.write(float4(0.0f), gid);
        return;
    }

    resolve_material(rec, ray, uniforms, surfaceSettings, materialImages, rec.t * 2.0f * fov_scale / float(uniforms.height));
    primarySurfaces[gid.y * uniforms.width + gid.x] = store_primary_surface(rec);
    gbufferPosDepth.write(float4(rec.position, rec.t), gid);
    gbufferNormalMat.write(float4(rec.normal, float(rec.mat.type)), gid);
    float3 surfaceColor = rec.mat.type == EMISSIVE ? rec.mat.emission : rec.mat.albedo;
    float surfaceParameter = rec.mat.type == DIELECTRIC
        ? (rec.front_face ? rec.mat.ior : -rec.mat.ior) : rec.mat.roughness;
    gbufferAlbedoRough.write(float4(surfaceColor, surfaceParameter), gid);

    if (!reservoirsBound) return;
    if (rec.mat.type != DIFFUSE) {
        outSamplePosDir.write(float4(0.0f), gid);
        outSampleEmitPdf.write(float4(0.0f), gid);
        outReservoirWeights.write(float4(0.0f), gid);
        outGIPosPdf.write(float4(0.0f), gid);
        outGINormal.write(float4(0.0f), gid);
        outGIRadiance.write(float4(0.0f), gid);
        outGIWeights.write(float4(0.0f), gid);
        return;
    }

    // Initial Candidate Generation (RIS M = 4)
    LightSample selectedSample = {};
    selectedSample.pdf = 0.0f;
    selectedSample.position = float3(0.0f);
    selectedSample.wi = float3(0.0f);
    selectedSample.emission = float3(0.0f);
    selectedSample.isDirectional = 0;

    float weightSum = 0.0f;
    float M = 0.0f;

    for (int i = 0; i < 4; ++i) {
        LightSample cand = sample_direct_light(rec.position, rec.normal, uniforms, seed, materialImages);
        M += 1.0f; // Zero-weight candidates still count in the estimator.
        if (cand.pdf > 0.0f) {
            float p_hat = eval_restir_target_pdf(rec.position, rec.normal, ray.direction, rec.mat, cand, uniforms.sceneIndex, uniforms.light.w,materialImages);
            float proposalPDF = cand.pdf * light_geometry(rec.position, cand, uniforms.sceneIndex, uniforms.light.w,materialImages);
            float w_i = proposalPDF > 0.0f ? p_hat / proposalPDF : 0.0f;
            weightSum += w_i;
            if (rand_f(seed) * weightSum < w_i) {
                selectedSample = cand;
            }
        }
    }

    // Temporal Reprojection. Reservoir history survives camera motion; the
    // reprojected surface test below rejects disocclusions.
    float4 prevClip = uniforms.prevViewProj * float4(rec.position, 1.0f);
    if (prevClip.w > 0.0f && uniforms.reservoirHistory > 1 && uniforms.reservoirHistoryReset == 0) {
        float2 prevNDC = prevClip.xy / prevClip.w;
        float2 prevUV = prevNDC * float2(0.5f, -0.5f) + 0.5f;
        int2 prevCoord = int2(prevUV * float2(float(uniforms.width), float(uniforms.height)));

        if (all(prevUV >= 0.0f) && all(prevUV < 1.0f) &&
            prevCoord.x >= 0 && prevCoord.x < int(uniforms.width) &&
            prevCoord.y >= 0 && prevCoord.y < int(uniforms.height)) {

            float4 histWeights = histReservoirWeights.read(uint2(prevCoord));
            float histM = histWeights.y;
            float histW = histWeights.z;

            float4 oldPos = histPosDepth.read(uint2(prevCoord));
            float4 oldNormal = histNormalMat.read(uint2(prevCoord));
            bool sameSurface = oldPos.w > 0.0f && oldNormal.w == float(rec.mat.type) &&
                dot(oldNormal.xyz, rec.normal) > 0.95f &&
                distance(oldPos.xyz, rec.position) < max(0.01f, rec.t * 0.01f);
            if (sameSurface && histM > 0.0f && histW > 0.0f) {
                float4 histPosDir = histSamplePosDir.read(uint2(prevCoord));
                float4 histEmitPdf = histSampleEmitPdf.read(uint2(prevCoord));

                LightSample histSample = {};
                histSample.position = histPosDir.xyz;
                histSample.isDirectional = uint(histPosDir.w);
                histSample.wi = (histSample.isDirectional == 1) ? histSample.position : normalize(histSample.position - rec.position);
                histSample.emission = histEmitPdf.xyz;
                histSample.pdf = histEmitPdf.w;

                float prev_p_hat = eval_restir_target_pdf(rec.position, rec.normal, ray.direction, rec.mat, histSample, uniforms.sceneIndex, uniforms.light.w,materialImages);
                float clampedM = min(histM, 20.0f);
                float w_temporal = prev_p_hat * histW * clampedM;

                M += clampedM;
                weightSum += w_temporal;
                if (rand_f(seed) * weightSum < w_temporal) {
                    selectedSample = histSample;
                }
            }
        }
    }

    float current_p_hat = eval_restir_target_pdf(rec.position, rec.normal, ray.direction, rec.mat, selectedSample, uniforms.sceneIndex, uniforms.light.w,materialImages);
    float W = (M > 0.0f && current_p_hat > 0.0f) ? (weightSum / (M * current_p_hat)) : 0.0f;

    float3 storeDirPos = (selectedSample.isDirectional == 1) ? selectedSample.wi : selectedSample.position;
    outSamplePosDir.write(float4(storeDirPos, float(selectedSample.isDirectional)), gid);
    outSampleEmitPdf.write(float4(selectedSample.emission, selectedSample.pdf), gid);
    outReservoirWeights.write(float4(weightSum, M, W, 0.0f), gid);

    // Depth 1 has no indirect bounce for GI reservoirs to estimate.
    if (!restir_gi_enabled(uniforms.cameraTarget.w)) {
        outGIPosPdf.write(float4(0.0f), gid);
        outGINormal.write(float4(0.0f), gid);
        outGIRadiance.write(float4(0.0f), gid);
        outGIWeights.write(float4(0.0f), gid);
        return;
    }

    // ReSTIR GI initial path: x0(camera) -> x1(primary diffuse) -> x2(diffuse)
    // -> sampled light. Store x2 and its one-sample outgoing direct radiance;
    // deeper transport remains in the ordinary path continuation.
    float3 selectedGIPos = float3(0.0f);
    float3 selectedGINormal = float3(0.0f);
    float3 selectedGIRadiance = float3(0.0f);
    float selectedGISourcePdf = 0.0f;
    float giWeightSum = 0.0f;
    float giM = 1.0f;
    float3 giDirection, giBSDFWeight;
    float giBSDFPdf;
    if (sample_bsdf(rec.mat, rec.normal, ray.direction, rec.front_face, seed,
                    giDirection, giBSDFWeight, giBSDFPdf) && giBSDFPdf > 0.0f) {
        Ray giRay;
        giRay.origin = ray_origin(rec.position, rec.geometricNormal, giDirection, uniforms, rec.error);
        giRay.direction = giDirection;
        HitRecord secondary;
        if (trace_scene(giRay, uniforms.sceneIndex, secondary, materialImages, uniforms)) {
            resolve_material(secondary, giRay, uniforms, surfaceSettings, materialImages,
                (rec.t + secondary.t) * 2.0f * fov_scale / float(uniforms.height));
            if (secondary.mat.type == DIFFUSE) {
                float3 secondaryRadiance = float3(0.0f);
                LightSample giLight = sample_direct_light(secondary.position, secondary.normal,
                    uniforms, seed, materialImages);
                if (giLight.pdf > 0.0f && light_visible(secondary.position,
                    secondary.geometricNormal, giLight, uniforms.sceneIndex, materialImages, uniforms, secondary.error)) {
                    float secondaryCosine = max(0.0f, dot(secondary.normal, giLight.wi));
                    float secondaryBSDFPdf;
                    float3 secondaryBSDF = eval_bsdf_with_pdf(secondary.mat, secondary.normal,
                        -giRay.direction, giLight.wi, secondaryBSDFPdf);
                    float mis = restir_gi_has_complementary_bsdf(uniforms.cameraTarget.w)
                        ? power_heuristic(giLight.pdf, secondaryBSDFPdf) : 1.0f;
                    secondaryRadiance = secondaryBSDF * secondaryCosine * giLight.emission *
                        (mis / giLight.pdf);
                }
                float3 giDelta = secondary.position - rec.position;
                float d2 = dot(giDelta, giDelta);
                float cosSecondary = max(0.0f, dot(secondary.normal, -giDirection));
                float sourcePdfArea = d2 > 1e-10f ? giBSDFPdf * cosSecondary / d2 : 0.0f;
                float pHat = eval_restir_gi_target(rec.position, rec.normal, ray.direction,
                    rec.mat, secondary.position, secondary.normal, secondaryRadiance);
                if (sourcePdfArea > 0.0f && pHat > 0.0f) {
                    selectedGIPos = secondary.position;
                    selectedGINormal = secondary.normal;
                    selectedGIRadiance = secondaryRadiance;
                    selectedGISourcePdf = sourcePdfArea;
                    giWeightSum = pHat / sourcePdfArea;
                }
            }
        }
    }

    // Temporal GI reservoir merge. Primary-surface reprojection defines the
    // reuse domain; the secondary point is reconnected and reweighted at x1.
    float4 giPrevClip = uniforms.prevViewProj * float4(rec.position, 1.0f);
    if (giPrevClip.w > 0.0f && uniforms.reservoirHistory > 1 && uniforms.reservoirHistoryReset == 0) {
        float2 prevUV = (giPrevClip.xy / giPrevClip.w) * float2(0.5f, -0.5f) + 0.5f;
        int2 prevCoord = int2(prevUV * float2(float(uniforms.width), float(uniforms.height)));
        if (all(prevUV >= 0.0f) && all(prevUV < 1.0f) && prevCoord.x >= 0 &&
            prevCoord.x < int(uniforms.width) && prevCoord.y >= 0 && prevCoord.y < int(uniforms.height)) {
            float4 oldPos = histPosDepth.read(uint2(prevCoord));
            float4 oldNormal = histNormalMat.read(uint2(prevCoord));
            bool sameSurface = oldPos.w > 0.0f && oldNormal.w == float(rec.mat.type) &&
                dot(oldNormal.xyz, rec.normal) > 0.95f &&
                distance(oldPos.xyz, rec.position) < max(0.01f, rec.t * 0.01f);
            float4 oldGIWeights = histGIWeights.read(uint2(prevCoord));
            float4 oldGIPosPdf = histGIPosPdf.read(uint2(prevCoord));
            float4 oldGINormal = histGINormal.read(uint2(prevCoord));
            if (sameSurface && oldGIWeights.y > 0.0f && oldGIWeights.z > 0.0f &&
                oldGIPosPdf.w > 0.0f && oldGINormal.w > 0.0f &&
                restir_gi_accepts_shift(rec.position, oldPos.xyz, oldGIPosPdf.xyz, oldGINormal.xyz)) {
                float3 oldGIRadiance = histGIRadiance.read(uint2(prevCoord)).xyz;
                float pHat = eval_restir_gi_target(rec.position, rec.normal, ray.direction, rec.mat,
                    oldGIPosPdf.xyz, oldGINormal.xyz, oldGIRadiance);
                float clampedM = min(oldGIWeights.y, 20.0f);
                float temporalWeight = pHat * oldGIWeights.z * clampedM;
                giM += clampedM;
                giWeightSum += temporalWeight;
                if (rand_f(seed) * giWeightSum < temporalWeight) {
                    selectedGIPos = oldGIPosPdf.xyz;
                    selectedGINormal = oldGINormal.xyz;
                    selectedGIRadiance = oldGIRadiance;
                    selectedGISourcePdf = oldGIPosPdf.w;
                }
            }
        }
    }
    float selectedGITarget = eval_restir_gi_target(rec.position, rec.normal, ray.direction,
        rec.mat, selectedGIPos, selectedGINormal, selectedGIRadiance);
    float giW = giM > 0.0f && selectedGITarget > 0.0f
        ? giWeightSum / (giM * selectedGITarget) : 0.0f;
    outGIPosPdf.write(float4(selectedGIPos, selectedGISourcePdf), gid);
    outGINormal.write(float4(selectedGINormal, selectedGISourcePdf > 0.0f ? 1.0f : 0.0f), gid);
    outGIRadiance.write(float4(selectedGIRadiance, 0.0f), gid);
    outGIWeights.write(float4(giWeightSum, giM, giW, 0.0f), gid);
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
    constant Uniforms &uniforms [[buffer(0)]],
    constant SurfaceSettings *surfaceSettings [[buffer(1)]],
    constant MaterialResources &materialImages [[buffer(2)]],
    const device PrimarySurface *primarySurfaces [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) return;
    uint seed = (gid.y * uniforms.width + gid.x) ^ (uniforms.sampleIndex * 1999999973u);

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
    // must not replay them.
    decorrelate_shading_seed(seed);

    if (posDepth.w <= 0.0f) {
        if ((uniforms.sceneIndex == 0 || uniforms.sceneIndex == 6)) {
            radiance = eval_environment(primaryRay.direction, uniforms, materialImages);
        }
    } else {
        // Pass 1 traced and resolved this exact ray; reuse its hit.
        HitRecord primaryHit = load_primary_surface(primarySurfaces[gid.y * uniforms.width + gid.x], posDepth);
        float coneSpread = 2.0f * fov_scale / float(uniforms.height);
        float pathDistance = primaryHit.t;
        float3 pos = primaryHit.position;
        float3 norm = primaryHit.normal;
        Material mat = primaryHit.mat;
        if (mat.type == EMISSIVE) {
            radiance = mat.emission;
        } else {
            // Camera rays see MaterialX emission directly; no light strategy samples them.
            radiance = openpbr_emission(mat, norm, -primaryRay.direction);
            if (uniforms.samplingMode == 0 && mat.type == DIFFUSE) {
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

                float p_hat_c = eval_restir_target_pdf(pos, norm, primaryRay.direction, mat, selectedSample, uniforms.sceneIndex, uniforms.light.w,materialImages);
                float weightSum = p_hat_c * cWeights.z * cWeights.y;
                float M = cWeights.y;

                // Uniform mode draws fresh taps in each loop below; compatibility mode
                // selects independent neighbour sets for DI and for GI reuse.
                bool compatibilityGuided = uniforms.spatialNeighbors == 1;
                SpatialNeighbors neighbors;
                neighbors.count = 0;
                if (compatibilityGuided) {
                    neighbors = select_compatible_neighbors(gid, pos, norm, posDepth.w,
                        gbufferPosDepth, gbufferNormalMat, uniforms, seed);
                }
                int taps = compatibilityGuided ? int(neighbors.count) : UNIFORM_TAPS;
                for (int i = 0; i < taps; ++i) {
                    int2 nCoord = compatibilityGuided ? neighbors.coord[i] : uniform_neighbor(gid, seed);

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

                                float p_hat_n = eval_restir_target_pdf(pos, norm, primaryRay.direction, mat, nSample, uniforms.sceneIndex, uniforms.light.w,materialImages);
                                float w_neighbor = p_hat_n * nWeights.z * nWeights.y;

                                weightSum += w_neighbor;
                                M += nWeights.y;
                                if (rand_f(seed) * weightSum < w_neighbor) {
                                    selectedSample = nSample;
                                }
                            }
                        }
                    }
                }

                float final_p_hat = eval_restir_target_pdf(pos, norm, primaryRay.direction, mat, selectedSample, uniforms.sceneIndex, uniforms.light.w,materialImages);
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

                // Direct Lighting: ReSTIR DI vs. Standard MIS
                if (W > 0.0f) {
                    float3 dir = (selectedSample.isDirectional == 1) ? selectedSample.position : normalize(selectedSample.position - pos);

                    if (light_visible(pos, primaryHit.geometricNormal, selectedSample, uniforms.sceneIndex, materialImages, uniforms, primaryHit.error)) {
                        float cos_th = max(0.0f, dot(norm, dir));
                        float3 bsdf = eval_bsdf(mat, norm, -primaryRay.direction, dir);
                        radiance += bsdf * cos_th * selectedSample.emission * W * light_geometry(pos, selectedSample, uniforms.sceneIndex, uniforms.light.w,materialImages);
                    }
                }

                // Spatial ReSTIR GI reuse for the first indirect diffuse vertex.
                // Pass 1 writes empty GI reservoirs when the depth excludes it.
                bool giEnabled = restir_gi_enabled(uniforms.cameraTarget.w);
                float4 selectedGIPosPdf = inGIPosPdf.read(gid);
                float4 selectedGINormal = inGINormal.read(gid);
                float3 selectedGIRadiance = inGIRadiance.read(gid).xyz;
                float4 currentGIWeights = inGIWeights.read(gid);
                float giTarget = selectedGINormal.w > 0.0f
                    ? eval_restir_gi_target(pos, norm, primaryRay.direction, mat,
                        selectedGIPosPdf.xyz, selectedGINormal.xyz, selectedGIRadiance) : 0.0f;
                float giWeightSum = giTarget * currentGIWeights.z * currentGIWeights.y;
                float giM = currentGIWeights.y;
                if (compatibilityGuided && giEnabled) {
                    neighbors = select_compatible_neighbors(gid, pos, norm, posDepth.w,
                        gbufferPosDepth, gbufferNormalMat, uniforms, seed);
                    taps = int(neighbors.count);
                }
                for (int i = 0; i < taps && giEnabled; ++i) {
                    int2 nCoord = compatibilityGuided ? neighbors.coord[i] : uniform_neighbor(gid, seed);
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
                    float3 neighborRadiance = inGIRadiance.read(uint2(nCoord)).xyz;
                    float neighborTarget = eval_restir_gi_target(pos, norm, primaryRay.direction,
                        mat, neighborPosPdf.xyz, neighborNormal.xyz, neighborRadiance);
                    float neighborWeight = neighborTarget * neighborWeights.z * neighborWeights.y;
                    giWeightSum += neighborWeight;
                    giM += neighborWeights.y;
                    if (rand_f(seed) * giWeightSum < neighborWeight) {
                        selectedGIPosPdf = neighborPosPdf;
                        selectedGINormal = neighborNormal;
                        selectedGIRadiance = neighborRadiance;
                    }
                }
                float finalGITarget = selectedGINormal.w > 0.0f
                    ? eval_restir_gi_target(pos, norm, primaryRay.direction, mat,
                        selectedGIPosPdf.xyz, selectedGINormal.xyz, selectedGIRadiance) : 0.0f;
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
                if (giEnabled && giW > 0.0f && gi_connection_visible(pos, primaryHit.geometricNormal,
                    selectedGIPosPdf.xyz, uniforms, materialImages, primaryHit.error)) {
                    float3 direction = normalize(selectedGIPosPdf.xyz - pos);
                    float3 primaryBSDF = eval_bsdf(mat, norm, -primaryRay.direction, direction);
                    float geometry = gi_geometry(pos, norm, selectedGIPosPdf.xyz, selectedGINormal.xyz);
                    radiance += primaryBSDF * selectedGIRadiance * geometry * giW;
                }
            } else if (mat.type != DIELECTRIC && !(mat.type == GLOSSY && mat.roughness < 0.02f) && uniforms.samplingMode != 3) {
                LightSample ls = sample_direct_light(pos, norm, uniforms, seed, materialImages);
                if (ls.pdf > 0.0f) {
                    if (light_visible(pos, primaryHit.geometricNormal, ls, uniforms.sceneIndex, materialImages, uniforms, primaryHit.error)) {
                        float cos_th = abs(dot(norm, ls.wi));
                        float bsdf_pdf;
                        float3 bsdf = eval_bsdf_with_pdf(mat, norm, -primaryRay.direction, ls.wi, bsdf_pdf);
                        // Depth 1 has no BSDF continuation to share the direct integral.
                        bool useMIS = uniforms.samplingMode <= 1 && scattering_limit(uniforms.cameraTarget.w) > 0;
                        float weight = useMIS ? power_heuristic(ls.pdf, bsdf_pdf) : 1.0f;
                        radiance += bsdf * cos_th * ls.emission * (weight / ls.pdf);
                    }
                }
            }

            // Optional artistic ring-caustic boost
            if (uniforms.enableSMS == 1 && mat.type == DIFFUSE) {
                float3 caustic = sample_specular_manifold_caustic(pos, norm, uniforms, seed, materialImages);
                radiance += caustic * mat.albedo;
            }

            Ray currentRay = primaryRay;
            HitRecord currentHit = primaryHit;
            float3 throughput = float3(1.0f);

            // Budget scattering events, not ideal reflections/refractions. Near
            // horizontal rays can cross the open ring dozens of times before
            // reaching the floor. Cutting that chain at 16 made its opening black.
            // Russian roulette terminates long specular chains without assigning
            // zero radiance at an arbitrary geometric depth (including closed loops).
            int scatteringDepth = 0;
            const int scatteringLimit = scattering_limit(uniforms.cameraTarget.w);
            bool emissionOnly = false;
            for (int bounce = 1; ; ++bounce) {
                float3 nextDirection, bsdfWeight;
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
                if (!sample_bsdf(currentHit.mat, currentHit.normal, currentRay.direction,
                                 currentHit.front_face, seed, nextDirection, bsdfWeight, bsdfPDF)) break;
                throughput *= bsdfWeight;
                if (!all(isfinite(throughput)) || max(throughput.x, max(throughput.y, throughput.z)) <= 0.0f) break;
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
                        radiance += throughput * weight * eval_environment(nextDirection, uniforms, materialImages);
                    }
                    break;
                }
                if (rec.mat.type == EMISSIVE) {
                    float lightPDF = eval_light_pdf(previousPosition, rec.position, rec.mat, uniforms,materialImages,rec.triangle);
                    float weight = emission_weight(previousDelta, previousNEE, previousMIS, bsdfPDF, lightPDF);
                    radiance += throughput * weight * rec.mat.emission;
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
                    radiance += throughput * weight * surfaceEmission;
                }
                if (emissionOnly) break;

                bool restirGISecondary = uniforms.samplingMode == 0 && mat.type == DIFFUSE &&
                    bounce == 1 && rec.mat.type == DIFFUSE;
                if (!is_delta(rec.mat) && uniforms.samplingMode != 3 && !restirGISecondary) {
                    LightSample ls = sample_direct_light(rec.position, rec.normal, uniforms, seed, materialImages);
                    if (light_visible(rec.position, rec.geometricNormal, ls, uniforms.sceneIndex, materialImages, uniforms, rec.error)) {
                        float cosine = abs(dot(rec.normal, ls.wi));
                        float pdf;
                        float3 bsdf = eval_bsdf_with_pdf(rec.mat, rec.normal, -currentRay.direction, ls.wi, pdf);
                        // At the last vertex there will be no BSDF light sample.
                        bool useMIS = uniforms.samplingMode <= 1 && scatteringDepth < scatteringLimit;
                        float weight = useMIS ? power_heuristic(ls.pdf, pdf) : 1.0f;
                        radiance += throughput * bsdf * cosine * ls.emission * weight / ls.pdf;
                    }
                }
                currentHit = rec;
                if (bounce > 3) {
                    // A higher survival ceiling reduces variance in long mirror
                    // chains. Division by survival preserves their expected energy.
                    float survival = clamp(max(throughput.x, max(throughput.y, throughput.z)),
                                           0.05f, is_delta(currentHit.mat) ? 0.99f : 0.95f);
                    if (rand_f(seed) >= survival) break;
                    throughput /= survival;
                }
            }
        }
    }

    if (uniforms.enableFog == 1) {
        radiance = apply_camera_fog(radiance, primaryRay, posDepth.w > 0.0f ? posDepth.w : 100.0f, uniforms, seed, materialImages);
    }

    if (isnan(radiance.r) || isnan(radiance.g) || isnan(radiance.b) ||
        isinf(radiance.r) || isinf(radiance.g) || isinf(radiance.b)) {
        radiance = float3(0.0f);
    }
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
    float3 average = radiance;
    if (uniforms.frameIndex > 1) {
        float3 previous = accumTexture.read(gid).rgb;
        if (all(isfinite(previous))) average = previous + (radiance - previous) / float(uniforms.frameIndex);
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
            uint guideSeed=(gid.y*u.width+gid.x)^(u.sampleIndex*1999999973u);
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

// ReSTIR DI/GI spatial reuse neighbours (shading_kernel). REFERENCES.md: COMPATRESTIR2026.
enum SpatialNeighborSelection: UInt32 {
    // RESTIR2020: uniform taps in a 16-pixel box, binary normal/depth/material test.
    case uniform = 0
    // COMPATRESTIR2026: neighbours drawn from 32 taps in proportion to a G-buffer score.
    case compatibility = 1
    // Host-side default: compatibility for imported scene graphs, where it measured
    // 28-51% lower equal-time MSE, and uniform for the procedural scenes, where the
    // extra taps cost 2-12% at equal time (see tests/PERFORMANCE.md).
    case automatic = 2
    func resolved(importedSceneGraph: Bool) -> SpatialNeighborSelection {
        self == .automatic ? (importedSceneGraph ? .compatibility : .uniform) : self
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

        static let reservoirBytesPerPixel: UInt64 = 208
        static let metalFXTextureBytesPerPixel: UInt64 = 55
        var bytesPerPixel: UInt64 {
            // Beauty/sample/position/OIDN accumulations: 6 RGBA32F; three
            // normal/material guides: 3 RGBA16F; resolved primary surfaces:
            // 120 B. ReSTIR adds DI (6 RGBA32F) and GI (6 RGBA32F + 2 RGBA16F).
            // MetalFX formats total 55 B/pixel plus the scaler's own history and
            // feature allocations.
            120 + PathTracerRenderer.primarySurfaceStride + (usesReSTIR ? Self.reservoirBytesPerPixel : 0)
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
    struct SceneKernels { let temporal, shading, guides, pick: MTLComputePipelineState }
    let proceduralKernels: SceneKernels
    var sceneKernels: SceneKernels {
        sceneIndex == 6 ? SceneKernels(temporal: restirTemporalPipeline, shading: shadingPipeline,
                                       guides: metalFXGuidePipeline, pick: pickPipeline) : proceduralKernels
    }
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
    nonisolated static let primarySurfaceStride: UInt64 = 120
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

    var prevViewProj = matrix_identity_float4x4
    var frameIndex: UInt32 = 0
    private var sampleIndex: UInt32 = 0
    // Unlike frameIndex, camera moves keep ReSTIR history; reprojection
    // rejects disocclusions. Cuts and inspection/non-ReSTIR frames clear it.
    private(set) var reservoirHistory: UInt32 = 0
#if VIBE_TESTING
    // GPU checks replay one jitter/seed sequence to compare renders of a view, and
    // exercise the unsupported-device presentation path on MetalFX-capable GPUs.
    func restartSampleSequence() { sampleIndex = 0 }
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
    static var defaultSpatialNeighbors: SpatialNeighborSelection {
#if VIBE_TESTING
        // Test builds can run the whole suite with the earlier uniform selection.
        if ProcessInfo.processInfo.environment["VIBE_SPATIAL_NEIGHBORS"] == "uniform" { return .uniform }
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
    private var frameResourcesUseReSTIR: Bool?
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
            giWeightsA, giPosPdfB, giNormalB, giRadianceB, giWeightsB,
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
        } + UInt64(primarySurfaces?.allocatedSize ?? 0)
    }

    func renderMemoryError(width: Int, height: Int) -> String? {
        let usesReSTIR = samplingMode == 0 && viewportMode == 0
        let usesMetalFX = denoiserEnabled && supportsMetalFX && usesReSTIR
        let plan = FrameResourcePlan(width: width, height: height, usesReSTIR: usesReSTIR, usesMetalFX: usesMetalFX,
            metalFXScalerBytesPerPixel: usesMetalFX ? metalFXScalerBytesPerPixel : 0)
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
        // A strategy or inspection change replaces only the reservoirs; the old
        // ones stay live (in residentFrameBytes) for in-flight frames.
        let reservoirs = pixels.multipliedReportingOverflow(by: FrameResourcePlan.reservoirBytesPerPixel)
        let additionalReservoirs = !resizes && plan.usesReSTIR && frameResourcesUseReSTIR != true
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
            materials.uniqueTextureBytes(materials.residentTextures + materials.external.textures) + materials.meshBytes)
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
            if let shared {
                self.proceduralKernels = shared.proceduralKernels
            } else {
                let options = shaderCompileOptions()
                options.preprocessorMacros = ["VIBE_MESHES": NSNumber(value: 0)]
                let procedural = try device.makeLibrary(source: metalSource, options: options)
                func pipeline(_ name: String) throws -> MTLComputePipelineState {
                    guard let function = procedural.makeFunction(name: name) else {
                        throw NSError(domain: "PathTracer", code: 2, userInfo: [NSLocalizedDescriptionKey: "A required Metal shader is missing."])
                    }
                    return try device.makeComputePipelineState(function: function)
                }
                self.proceduralKernels = SceneKernels(temporal: try pipeline("restir_temporal_kernel"), shading: try pipeline("shading_kernel"),
                                                      guides: try pipeline("metalfx_guides_kernel"), pick: try pipeline("pick_kernel"))
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

        let needsReSTIR = samplingMode == 0 && viewportMode == 0
        let resized = accumTexture == nil || accumTexture?.width != w || accumTexture?.height != h
        if resized || frameResourcesUseReSTIR != needsReSTIR {
            let desc32 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
            desc32.usage = [.shaderRead, .shaderWrite]
            desc32.storageMode = .private
            let desc16 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            desc16.usage = [.shaderRead, .shaderWrite]
            desc16.storageMode = .private

            let reservoir32 = needsReSTIR ? desc32 : {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private; return d
            }()
            let reservoir16 = needsReSTIR ? desc16 : {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private; return d
            }()

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
                  let newGIPosA = device.makeTexture(descriptor: reservoir32),
                  let newGINormalA = device.makeTexture(descriptor: reservoir16),
                  let newGIRadianceA = device.makeTexture(descriptor: reservoir32),
                  let newGIWeightsA = device.makeTexture(descriptor: reservoir32),
                  let newGIPosB = device.makeTexture(descriptor: reservoir32),
                  let newGINormalB = device.makeTexture(descriptor: reservoir16),
                  let newGIRadianceB = device.makeTexture(descriptor: reservoir32),
                  let newGIWeightsB = device.makeTexture(descriptor: reservoir32),
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
            frameResourcesUseReSTIR = needsReSTIR

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
              let oidnAlbedo = oidnAlbedoAccum, let oidnNormal = oidnNormalAccum,
              let surfaces = primarySurfaceBuffer(width: w, height: h),
              let cmdBuffer = commandQueue.makeCommandBuffer() else { return }

        let nextFrame = frameIndex + 1
        let nextSample = sampleIndex == UInt32.max ? 1 : sampleIndex + 1
        // Inspection and non-ReSTIR frames leave reservoirs unwritten.
        let nextHistory = needsReSTIR ? min(reservoirHistory, 1 << 24) + 1 : 0

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
            jitter: frameJitter(nextSample), sampleIndex: nextSample,
            reservoirHistoryReset: reservoirHistoryNeedsReset ? 1 : 0, reservoirHistory: nextHistory,
            spatialNeighbors: spatialNeighbors.resolved(importedSceneGraph: sceneIndex == 6 && materials.hasSceneGraph).rawValue,
            environment: SIMD4(options.environmentIntensity, options.environmentRotation * .pi / 180, materials.environmentData == nil ? 0 : 1, Float(materials.nodeCount)),
            lens: SIMD4(options.aperture,options.focusDistance,materials.hasSceneGraph ? 1 : 0,sceneIndex == 6 ? options.independentSunCone : 0),
            light: SIMD4(options.lightColor*options.lightIntensity,options.lightSize)
        )
        uniforms.sceneGraphMode = materials.hasSceneGraph
        lastUniforms=uniforms

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let gridSize = MTLSize(width: w, height: h, depth: 1)

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
            enc1.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            enc1.endEncoding()
        }

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
            guard materials.bind(enc2) else {
                enc2.endEncoding()
                onError?("Could not update material bindings.")
                return
            }
            enc2.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc2.setBuffer(surfaces, offset: 0, index: 3)
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
