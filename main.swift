import Cocoa
import Metal
import MetalKit
import MetalFX
import simd
import UniformTypeIdentifiers
import CoreImage

// Algorithm/API citations and adaptation notes: REFERENCES.md (stable keys below).
// ============================================================================
// 1. Metal Shading Language: Multi-Bounce ReSTIR DI & Path Tracing
// ============================================================================

func loadOpenPBRSource() -> String {
    let candidates = [Bundle.main.resourceURL?.appendingPathComponent("OpenPBR.metal"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/ShaderResources/OpenPBR.metal")]
    for url in candidates.compactMap({ $0 }) {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    }
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
using namespace metal;

#define PI 3.14159265358979323846f
#define TWO_PI 6.28318530717958647692f

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
    float4 cameraTarget;   // xyz = target, w = scattering depth + 1 (delta chains excluded)
    float4 cameraUp;       // xyz = up, w = 0
    float4 sunParams;      // xyz = sun direction, w = sun intensity
    float4x4 currentViewProj;
    float4x4 prevViewProj;
    uint frameIndex;
    uint sceneIndex;
    uint samplingMode;     // 0 = ReSTIR DI, 1 = MIS, 2 = Light Only, 3 = BSDF Only
    uint enableSMS;        // Legacy field name: 1 = artistic ring boost, 0 = off
    uint skyMode;          // 0 = Golden Hour, 1 = High Noon, 2 = Twilight/Studio
    uint enableFog;        // 1 = single-scatter camera fog, 0 = off
    uint width;
    uint height;
    float2 jitter;         // Shared subpixel offset, in pixels, excluding the 0.5 pixel center.
    uint sampleIndex;      // Continues across orbit changes, independently of accumulation.
    uint padding;
    float4 environment; // intensity, rotation, image enabled, BVH node count
    float4 lens; // aperture radius, focus distance, reserved
    float4 light; // RGB multiplier, size multiplier
};

// ============================================================================
// Procedural Physical Sky
// ============================================================================

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
            if (sunCos > 0.9992f) {
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
            if (sunCos > 0.9993f) {
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
            if (sunCos > 0.9991f) {
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
            rec.bitangent = cross(rec.normal, rec.tangent);
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
            rec.bitangent = cross(rec.normal, rec.tangent);
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
    float3 localT, localB;
    if (abs(loc_norm.x) > 0.5f) { localT = float3(0,0,1); localB = float3(0,1,0); rec.uv = loc_hit.zy / (2.0f * half_size.zy) + 0.5f; rec.uvDensity = 1.0f / (2.0f * half_size.zy); }
    else if (abs(loc_norm.y) > 0.5f) { localT = float3(1,0,0); localB = float3(0,0,1); rec.uv = loc_hit.xz / (2.0f * half_size.xz) + 0.5f; rec.uvDensity = 1.0f / (2.0f * half_size.xz); }
    else { localT = float3(1,0,0); localB = float3(0,1,0); rec.uv = loc_hit.xy / (2.0f * half_size.xy) + 0.5f; rec.uvDensity = 1.0f / (2.0f * half_size.xy); }
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
                rec.uv = float2(atan2(outward.z, outward.x) / TWO_PI + 0.5f, (y - center.y) / height + 0.5f);
                rec.tangent = float3(-outward.z, 0, outward.x);
                rec.bitangent = float3(0,1,0);
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
    return u.sceneIndex==6 && u.lens.z>0 ? max(1e-7f, 9.536743e-7f * max(abs(p.x),max(abs(p.y),abs(p.z)))) : 0.001f;
}
float3 ray_origin(float3 p,float3 geometricNormal,float3 direction,constant Uniforms &u) {
    return p+geometricNormal*(dot(direction,geometricNormal)>=0 ? ray_epsilon(p,u) : -ray_epsilon(p,u));
}

bool trace_scene(Ray r, uint sceneIndex, thread HitRecord &rec, device ObjectSettings *objects = nullptr, float lightSize = 1.0f, float3 lightTint = float3(1)) {
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
        if (intersect_quad(r, float3(-3.8f, -1.0f, 2.8f), float3(7.6f, 0, 0), float3(0, 4.0f, 0), float3(0, 0, -1), false, back_wall, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-3.8f, -1.0f, -2.0f), float3(0, 0, 4.8f), float3(0, 4.0f, 0), float3(1, 0, 0), false, terracotta, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

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
        if (intersect_quad(r,float3(-10,-1,-10),float3(20,0,0),float3(0,0,20),float3(0,1,0),false,floor,0.001f,closest,t_rec,objects)) { hit=true; closest=t_rec.t; rec=t_rec; }
    } else if (sceneIndex == 1 || sceneIndex == 4) {
        Material white = { DIFFUSE, float3(0.73f), float3(0.0f), 0, 1 };
        Material red   = { DIFFUSE, float3(0.65f, 0.05f, 0.05f), float3(0.0f), 0, 1 };
        Material green = { DIFFUSE, float3(0.12f, 0.45f, 0.15f), float3(0.0f), 0, 1 };
        float3 emit = (sceneIndex == 4) ? float3(32.0f, 28.0f, 22.0f) : float3(18.0f, 15.0f, 10.0f);
        Material light = { EMISSIVE, float3(0.0f), emit, 0, 1 };

        if (intersect_quad(r, float3(-1, -1, -1), float3(2, 0, 0), float3(0, 0, 2), float3(0, 1, 0), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-1,  1, -1), float3(2, 0, 0), float3(0, 0, 2), float3(0, -1, 0), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-1, -1,  1), float3(2, 0, 0), float3(0, 2, 0), float3(0, 0, -1), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-1, -1, -1), float3(0, 0, 2), float3(0, 2, 0), float3(1, 0, 0), true, red, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3( 1, -1, -1), float3(0, 0, 2), float3(0, 2, 0), float3(-1, 0, 0), true, green, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

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
            float3 c = float3(xs[i] - 0.6f, -0.85f, -0.5f);
            float3 u = float3(1.2f, 0.0f, 0.0f);
            float3 v = float3(0.0f, 1.4f * sin(0.6f), 1.4f * cos(0.6f));
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
        if (intersect_quad(r, float3(-1, -1,  1), float3(2, 0, 0), float3(0, 2, 0), float3(0, 0, -1), true, white, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3(-1, -1, -1), float3(0, 0, 2), float3(0, 2, 0), float3(1, 0, 0), true, red, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
        if (intersect_quad(r, float3( 1, -1, -1), float3(0, 0, 2), float3(0, 2, 0), float3(-1, 0, 0), true, green, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

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
        if (intersect_quad(r, float3(-5, -1,  2), float3(10, 0, 0), float3(0, 5, 0), float3(0, 0, -1), false, back_wall, 0.001f, closest, t_rec, objects))  { hit = true; closest = t_rec.t; rec = t_rec; }

        if (intersect_quad(r, float3(0,1.9f,-0.5f)+(float3(-0.15f, 1.9f, -0.65f)-float3(0,1.9f,-0.5f))*lightSize, float3(0.3f, 0, 0)*lightSize, float3(0, 0, 0.3f)*lightSize, float3(0, -1, 0), true, light_mat, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material gold_ring = { GLOSSY, float3(1.0f, 0.85f, 0.55f), float3(0.0f), 0.18f, 1 }; gold_ring.slot=3;
        if (intersect_cylinder_ring(r, float3(0.45f, -0.75f, -0.15f), 0.42f, 0.5f, gold_ring, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }

        Material chrome = { GLOSSY, float3(0.95f), float3(0.0f), 0.001f, 1 }; chrome.slot=4;
        if (intersect_sphere(r, float3(-0.65f, -0.55f, 0.15f), 0.45f, chrome, 0.001f, closest, t_rec, objects)) { hit = true; closest = t_rec.t; rec = t_rec; }
    }
    if (hit && rec.mat.type == EMISSIVE) rec.mat.emission *= lightTint;
    return hit;
}


// REFERENCES.md: PBRT2023, OBJ2026. Local determinant triangle test and median BVH.
bool trace_scene(Ray r, uint sceneIndex, thread HitRecord &rec, constant MaterialResources &images, constant Uniforms &u) {
    bool hit=trace_scene(r,sceneIndex,rec,images.objects,u.light.w,u.light.xyz);
    if(hit) rec.objectID=rec.mat.slot;
    if (sceneIndex != 6 || u.environment.w < 1 || (u.lens.z==0 && images.objects[7].rotationHidden.w > 0.5f)) return hit;
    ObjectSettings o=images.objects[7];
    if(u.lens.z>0) { o.positionScale=float4(0,0,0,1);o.rotationHidden=float4(0); }
    Ray local=object_ray(r,o);
    float closest=hit ? rec.t/o.positionScale.w : 1e20f;
    int stack[64]; int top=0; stack[top++]=0;
    while(top>0) {
        MeshNode node=images.nodes[stack[--top]];
        float nearT=(u.lens.z>0 ? ray_epsilon(r.origin,u)*0.25f : 0.001f)/o.positionScale.w, farT=closest;
        for(int axis=0;axis<3;++axis) {
            if(abs(local.direction[axis])<1e-8f) { if(local.origin[axis]<node.lo[axis] || local.origin[axis]>node.hi[axis]) farT=-1; }
            else { float a=(node.lo[axis]-local.origin[axis])/local.direction[axis], b=(node.hi[axis]-local.origin[axis])/local.direction[axis]; nearT=max(nearT,min(a,b)); farT=min(farT,max(a,b)); }
        }
        if(nearT>farT) continue;
        if(node.links.w==0) { if(top<62) {stack[top++]=node.links.x;stack[top++]=node.links.y;} continue; }
        for(int k=0;k<node.links.w;++k) {
            MeshTriangle tri=images.triangles[node.links.z+k];
            float3 e1=tri.b.xyz-tri.a.xyz, e2=tri.c.xyz-tri.a.xyz;
            float3 q=cross(local.direction,e2); float det=dot(e1,q);
            if(abs(det)<=1e-7f*length(e1)*length(e2)) continue;
            float3 d=local.origin-tri.a.xyz; float b1=dot(d,q)/det;
            float3 v=cross(d,e1); float b2=dot(local.direction,v)/det;
            float t=dot(e2,v)/det;
            if(b1<0 || b2<0 || b1+b2>1 || t<(u.lens.z>0 ? ray_epsilon(r.origin,u)*0.25f : 0.001f)/o.positionScale.w || t>=closest) continue;
            closest=t; hit=true; float b0=1-b1-b2;
            rec.t=t; rec.position=local.origin+t*local.direction;
            float3 ng=normalize(cross(e1,e2)); rec.front_face=dot(ng,local.direction)<0;
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
            rec.bitangent=cross(rec.normal,rec.tangent)*(uvDet<0?-1.0f:1.0f);
            rec.uvDensity=float2(max(length(d1)/max(length(e1),1e-6f),length(d2)/max(length(e2),1e-6f)));
            rec.mat={DIFFUSE,float3(0.7f),float3(0),0,1}; rec.mat.slot=u.lens.z>0 ? uint(tri.uvc.z) : 7;
            if(u.lens.z>0 && any(images.emissions[rec.mat.slot].rgb>0)) {rec.mat.type=EMISSIVE;rec.mat.emission=rec.front_face?images.emissions[rec.mat.slot].rgb:float3(0);}
            rec.objectID=u.lens.z>0 ? 64+uint(tri.uvc.w)-1 : 7;
            world_hit(rec,o);
        }
    }
    return hit;
}
// REFERENCES.md: PBRT2023. Lat-long lookup with the existing sun/cosine proposal mixture.
float3 eval_environment(float3 d, constant Uniforms &u, constant MaterialResources &images) {
    float3 result;
    if(u.environment.z>0.5f) {
        constexpr sampler env(coord::normalized,address::repeat,filter::linear);
        float2 uv=float2(atan2(d.z,d.x)/TWO_PI+0.5f+u.environment.y/TWO_PI,acos(clamp(d.y,-1.0f,1.0f))/PI);
        uv.y=clamp(uv.y,0.5f/images.environmentMap.get_height(),1.0f-0.5f/images.environmentMap.get_height());
        result=images.environmentMap.sample(env,uv).rgb;
    } else result=eval_procedural_sky(d,u.sunParams,u.skyMode);
    return result*u.environment.x;
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


float4 sample_material_map(constant MaterialResources &images, uint slot, uint channel,
                          float2 uv, float2 density, float footprint) {
    constexpr sampler filter(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    uint index = slot * 4 + channel;
    float2 size = float2(images.maps[index].get_width(), images.maps[index].get_height());
    float lod = max(0.0f, log2(max(1e-6f, max(size.x * density.x, size.y * density.y) * footprint)));
    return images.maps[index].sample(filter, uv, level(lod));
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
            constexpr sampler filter(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
            uint index=uint(n.value.x);float2 size=float2(images.graphImages[index].get_width(),images.graphImages[index].get_height());
            float lod=max(0.0f,log2(max(1e-6f,max(size.x*da.x,size.y*da.y)*footprint)));
            v=images.graphImages[index].sample(filter,float2(a.x,1.0f-a.y),level(lod));
            if(n.value.y>0) v=float4(v.x); break;
        }
        case 3:v=a*b;d=abs(a.xy)*db+abs(b.xy)*da;break;
        case 4:v=a+b;d=da+db;break;
        case 5:v=mix(a,b,c);d=abs(1-c.xy)*da+abs(c.xy)*db+abs(b.xy-a.xy)*dc;break;
        case 6:v=float4(a[uint(n.value.x)]);d=float2(max(da.x,da.y));break;
        case 7:v=clamp(a,b,c);d=da+db+dc;break;
        case 8:{float3 normal=dot(a.xyz,a.xyz)==0?float3(0,0,1):a.xyz*2.0f-1.0f;normal.xy*=n.value.xy;
            v=float4(normalize(hit.tangent*normal.x-hit.bitangent*normal.y+hit.normal*normal.z),0);break;}
        case 9:v=a-b;d=da+db;break;
        case 10:{float angle=n.value.x;v=float4(cos(angle)*a.x-sin(angle)*a.y,sin(angle)*a.x+cos(angle)*a.y,0,0);d=float2(max(da.x,da.y)*1.414214f);break;}
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
    if (config.mapMask & 1) hit.mat.albedo *= sample_material_map(images, slot, 0, uv, density, footprint).rgb;
    if (config.mapMask & 2) hit.mat.roughness = clamp(sample_material_map(images, slot, 1, uv, density, footprint)[min(object.channels.x,3u)], 0.03f, 1.0f);
    if (config.mapMask & 4) {
        if (hit.mat.type != OPENPBR) { hit.mat.type = OPENPBR; hit.mat.ior = 1.5f; }
        hit.mat.metalness = clamp(sample_material_map(images, slot, 2, uv, density, footprint)[min(object.channels.y,3u)], 0.0f, 1.0f);
    }
    if (config.mapMask & 8) {
        float3 map = sample_material_map(images, slot, 3, uv, density, footprint).xyz * 2.0f - 1.0f;
        map.xy *= config.normalStrength;
        float3 mapped = normalize(hit.tangent * map.x + hit.bitangent * map.y + hit.geometricNormal * max(0.05f, map.z));
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
    float cos_th = sqrt(r.y);
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

float eval_environment_pdf(float3 wi, float3 n, constant Uniforms &u) {
    float sunProbability=(u.environment.x>0 && u.environment.z<0.5f && u.sunParams.w>0) ? 0.60f:0.0f;
    float sunPDF = dot(wi, normalize(u.sunParams.xyz)) >= 0.9993f
        ? 1.0f / (TWO_PI * (1.0f - 0.9993f)) : 0.0f;
    return sunProbability * sunPDF + (1.0f-sunProbability) * max(0.0f, dot(n, wi)) / PI;
}

// OPENUSD/PBRT2023: uniform triangle-area emitter proposal, mixed with the environment.
float imported_light_probability(constant Uniforms &u,constant MaterialResources &images) {
    if(u.sceneIndex!=6 || images.emitters[0]==0) return 0.0f;
    return u.environment.x>0 ? 0.5f:1.0f;
}
float imported_geometry(float3 p,float3 position,uint index,constant MaterialResources &images) {
    MeshTriangle t=images.triangles[index];float3 d=position-p;float d2=dot(d,d);
    float3 n=cross(t.b.xyz-t.a.xyz,t.c.xyz-t.a.xyz);
    return d2>1e-12f && dot(n,n)>1e-20f ? max(0.0f,dot(normalize(n),-d*rsqrt(d2)))/d2:0;
}
float eval_environment_pdf(float3 wi,float3 n,constant Uniforms &u,constant MaterialResources &images) {
    return (1.0f-imported_light_probability(u,images))*eval_environment_pdf(wi,n,u);
}
// Both proposals sample the same environment, with their full mixture PDF.
LightSample sample_direct_light(float3 p, float3 n, constant Uniforms &u, thread uint &seed, constant MaterialResources &materialImages) {
    LightSample ls = {};
    float importedProbability=imported_light_probability(u,materialImages);
    if(importedProbability>0 && rand_f(seed)<importedProbability) {
        uint count=materialImages.emitters[0];uint index=materialImages.emitters[1+min(uint(rand_f(seed)*count),count-1)];
        MeshTriangle t=materialImages.triangles[index];float2 r=rand_f2(seed);float root=sqrt(r.x);
        ls.position=(1-root)*t.a.xyz+root*(1-r.y)*t.b.xyz+root*r.y*t.c.xyz;
        float3 delta=ls.position-p;ls.dist=length(delta);ls.wi=delta/max(ls.dist,1e-8f);
        float area=0.5f*length(cross(t.b.xyz-t.a.xyz,t.c.xyz-t.a.xyz));float geometry=imported_geometry(p,ls.position,index,materialImages);
        ls.emission=materialImages.emissions[uint(t.uvc.z)].rgb;ls.isDirectional=index+2;
        ls.pdf=geometry>1e-12f ? importedProbability/(float(count)*area*geometry):0;
        return ls;
    }
    if ((u.sceneIndex == 0 || u.sceneIndex == 6)) {
        float sunProbability=(u.environment.x>0 && u.environment.z<0.5f && u.sunParams.w>0) ? 0.60f:0.0f;
        if (rand_f(seed) < sunProbability) {
            // Direct Sun Disc Cone Sampling (60%)
            float3 sun_d = normalize(u.sunParams.xyz);
            float cos_max = 0.9993f;
            float2 r = rand_f2(seed);
            float cos_th = 1.0f - r.x + r.x * cos_max;
            float sin_th = sqrt(max(0.0f, 1.0f - cos_th * cos_th));
            float phi = TWO_PI * r.y;
            float3 su, sv;
            make_basis(sun_d, su, sv);
            ls.wi = normalize(su * (cos(phi) * sin_th) + sv * (sin(phi) * sin_th) + sun_d * cos_th);
            ls.position = p + ls.wi * 1e6f;
            ls.dist = 1e6f;
            ls.pdf = (1.0f / (TWO_PI * (1.0f - cos_max))) * sunProbability;
            ls.isDirectional = 1;


        } else {
            // Ambient Sky Hemisphere Sampling (40%) -> Illuminates shadows & cylinder interior
            float3 sky_d = sample_cosine_hemisphere(n, seed);
            ls.wi = sky_d;
            ls.position = p + ls.wi * 1e6f;
            ls.dist = 1e6f;
            ls.pdf = (max(0.0f, dot(n, sky_d)) / PI) * (1.0f-sunProbability);
            ls.isDirectional = 1;

        }

        ls.pdf = eval_environment_pdf(ls.wi, n, u,materialImages);
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
            float cos_th_max = sqrt(max(0.0f, 1.0f - (radius * radius) / d2));
            float2 r = rand_f2(seed);
            float cos_th = 1.0f - r.x + r.x * cos_th_max;
            float sin_th = sqrt(max(0.0f, 1.0f - cos_th * cos_th));
            float phi = TWO_PI * r.y;
            float3 su, sv;
            make_basis(d_c, su, sv);
            ls.wi = normalize(su * (cos(phi) * sin_th) + sv * (sin(phi) * sin_th) + d_c * cos_th);
            // Store an actual point on the emitter, also valid during reuse.
            float b = dot(p - center, ls.wi);
            float c = d2 - radius * radius;
            ls.dist = -b - sqrt(max(0.0f, b * b - c));
            ls.position = p + ls.wi * ls.dist;
            ls.emission = emits[pick];
            ls.pdf = 0.25f / (TWO_PI * (1.0f - cos_th_max));
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
                float d_vec2 = dot(c - p, c - p);
                float cos_th_max = sqrt(max(0.0f, 1.0f - (radii[i] * radii[i] * u.light.w * u.light.w) / d_vec2));
                return 0.25f / (TWO_PI * (1.0f - cos_th_max));
            }
        }
    }
    return 0.0f;
}

float eval_light_pdf(float3 p,float3 hit_pos,Material mat,constant Uniforms &u,constant MaterialResources &images) {
    if(u.sceneIndex!=6) return eval_light_pdf(p,hit_pos,mat,u);
    uint count=images.emitters[0];float pdf=0;
    for(uint i=0;i<count;++i) {
        uint index=images.emitters[i+1];MeshTriangle t=images.triangles[index];if(uint(t.uvc.z)!=mat.slot) continue;
        float3 e1=t.b.xyz-t.a.xyz,e2=t.c.xyz-t.a.xyz,d=hit_pos-t.a.xyz,n=cross(e1,e2);
        float nn=dot(n,n);if(nn<1e-20f || abs(dot(d,n))>sqrt(nn)*1e-5f) continue;
        float b=dot(cross(d,e2),n)/nn,c=dot(cross(e1,d),n)/nn;
        if(b<0 || c<0 || b+c>1) continue;
        float g=imported_geometry(p,hit_pos,index,images);
        if(g>1e-12f) pdf+=imported_light_probability(u,images)/(float(count)*0.5f*sqrt(nn)*g);
    }
    return pdf;
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

                HitRecord rec1, rec2;
                bool occ1 = trace_scene(r_xz, u.sceneIndex, rec1, materialImages, u) && (rec1.t < dist_xz - 0.01f);
                bool occ2 = trace_scene(r_zy, u.sceneIndex, rec2, materialImages, u) && (rec2.t < length(y_light - z) - 0.01f);

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
    if(sceneIndex==6 && ls.isDirectional>=2) return imported_geometry(p,ls.position,ls.isDirectional-2,images);
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

// Shadow endpoints are measured from the offset origin to avoid self-occlusion.
bool light_visible(float3 p, float3 n, LightSample ls, uint sceneIndex, constant MaterialResources &materialImages, constant Uniforms &u) {
    if (ls.pdf <= 0.0f) return false;
    Ray shadow;
    shadow.origin = ray_origin(p,n,ls.wi,u);
    float3 delta = ls.isDirectional == 1 ? ls.wi : ls.position - shadow.origin;
    float d = ls.isDirectional == 1 ? 1e6f : length(delta);
    float endpointTolerance=2*ray_epsilon(ls.isDirectional==1 ? p : ls.position,u);
    if (d <= endpointTolerance) return false;
    shadow.direction = normalize(delta);
    HitRecord blocker;
    return !trace_scene(shadow, sceneIndex, blocker, materialImages, u) || blocker.t >= d - endpointTolerance;
}

bool is_delta(Material mat) {
    return mat.type == DIELECTRIC || (mat.type == GLOSSY && mat.roughness < 0.02f);
}

// Returns f * abs(cos(theta)) / PDF, using the same glossy model as NEE.
bool sample_bsdf(Material mat, float3 normal, float3 incoming, bool frontFace,
                 thread uint &seed, thread float3 &direction,
                 thread float3 &weight, thread float &pdf) {
    pdf = 0.0f;
    if (mat.type == DIELECTRIC) {
        float eta = frontFace ? 1.0f / mat.ior : mat.ior;
        float cosI = clamp(dot(-incoming, normal), 0.0f, 1.0f);
        float sin2T = eta * eta * (1.0f - cosI * cosI);
        float r0 = (1.0f - mat.ior) / (1.0f + mat.ior);
        float fresnel = r0 * r0 + (1.0f - r0 * r0) * pow(1.0f - cosI, 5.0f);
        if (sin2T >= 1.0f || rand_f(seed) < fresnel) {
            direction = reflect(incoming, normal);
            weight = mat.albedo;
        } else {
            direction = normalize(eta * incoming + (eta * cosI - sqrt(1.0f - sin2T)) * normal);
            weight = mat.albedo * (eta * eta);
        }
        return true;
    }
    if (is_delta(mat)) {
        direction = reflect(incoming, normal);
        float cosI = clamp(dot(-incoming, normal), 0.0f, 1.0f);
        weight = mat.albedo + (1.0f - mat.albedo) * pow(1.0f - cosI, 5.0f);
        return true;
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
    constant Uniforms &uniforms [[buffer(0)]],
    constant SurfaceSettings *surfaceSettings [[buffer(1)]],
    constant MaterialResources &materialImages [[buffer(2)]],
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

    if (!hit) {
        gbufferPosDepth.write(float4(0.0f, 0.0f, 0.0f, -1.0f), gid);
        gbufferNormalMat.write(float4(0.0f, 0.0f, 0.0f, -1.0f), gid);
        gbufferAlbedoRough.write(float4(0.0f), gid);
        outSamplePosDir.write(float4(0.0f), gid);
        outSampleEmitPdf.write(float4(0.0f), gid);
        outReservoirWeights.write(float4(0.0f), gid);
        return;
    }

    resolve_material(rec, ray, uniforms, surfaceSettings, materialImages, rec.t * 2.0f * fov_scale / float(uniforms.height));
    gbufferPosDepth.write(float4(rec.position, rec.t), gid);
    gbufferNormalMat.write(float4(rec.normal, float(rec.mat.type)), gid);
    float3 surfaceColor = rec.mat.type == EMISSIVE ? rec.mat.emission : rec.mat.albedo;
    float surfaceParameter = rec.mat.type == DIELECTRIC
        ? (rec.front_face ? rec.mat.ior : -rec.mat.ior) : rec.mat.roughness;
    gbufferAlbedoRough.write(float4(surfaceColor, surfaceParameter), gid);

    if (uniforms.samplingMode != 0 || rec.mat.type != DIFFUSE) {
        outSamplePosDir.write(float4(0.0f), gid);
        outSampleEmitPdf.write(float4(0.0f), gid);
        outReservoirWeights.write(float4(0.0f), gid);
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

    // Temporal Reprojection
    float4 prevClip = uniforms.prevViewProj * float4(rec.position, 1.0f);
    if (prevClip.w > 0.0f && uniforms.frameIndex > 1) {
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
    constant Uniforms &uniforms [[buffer(0)]],
    constant SurfaceSettings *surfaceSettings [[buffer(1)]],
    constant MaterialResources &materialImages [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) return;
    uint seed = (gid.y * uniforms.width + gid.x) ^ (uniforms.sampleIndex * 1999999973u);

    float4 posDepth = gbufferPosDepth.read(gid);
    float3 radiance = float3(0.0f);
    float specularHitDistance = 0.0f;

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

    if (posDepth.w <= 0.0f) {
        if ((uniforms.sceneIndex == 0 || uniforms.sceneIndex == 6)) {
            radiance = eval_environment(primaryRay.direction, uniforms, materialImages);
        }
    } else {
        HitRecord primaryHit;
        if (!trace_scene(primaryRay, uniforms.sceneIndex, primaryHit, materialImages, uniforms)) return;
        float coneSpread = 2.0f * fov_scale / float(uniforms.height);
        float pathDistance = primaryHit.t;
        resolve_material(primaryHit, primaryRay, uniforms, surfaceSettings, materialImages, pathDistance * coneSpread);
        float3 pos = primaryHit.position;
        float3 norm = primaryHit.normal;
        Material mat = primaryHit.mat;
        if (mat.type == EMISSIVE) {
            radiance = mat.emission;
        } else {
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

                const float spatialRadius = 16.0f;
                for (int i = 0; i < 4; ++i) {
                    float2 offset = (rand_f2(seed) * 2.0f - 1.0f) * spatialRadius;
                    int2 nCoord = int2(gid) + int2(offset);

                    if (nCoord.x >= 0 && nCoord.x < int(uniforms.width) &&
                        nCoord.y >= 0 && nCoord.y < int(uniforms.height)) {

                        float4 nPosDepth = gbufferPosDepth.read(uint2(nCoord));
                        float4 nNormMat = gbufferNormalMat.read(uint2(nCoord));

                        if (nPosDepth.w > 0.0f && nNormMat.w == float(mat.type) && dot(norm, nNormMat.xyz) > 0.95f && abs(posDepth.w - nPosDepth.w) < 0.05f * posDepth.w) {
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
                float W = (M > 0.0f && final_p_hat > 0.0f) ? (weightSum / (M * final_p_hat)) : 0.0f;

                // Direct Lighting: ReSTIR DI vs. Standard MIS
                if (W > 0.0f) {
                    float3 dir = (selectedSample.isDirectional == 1) ? selectedSample.position : normalize(selectedSample.position - pos);

                    if (light_visible(pos, primaryHit.geometricNormal, selectedSample, uniforms.sceneIndex, materialImages, uniforms)) {
                        float cos_th = max(0.0f, dot(norm, dir));
                        float3 bsdf = eval_bsdf(mat, norm, -primaryRay.direction, dir);
                        radiance += bsdf * cos_th * selectedSample.emission * W * light_geometry(pos, selectedSample, uniforms.sceneIndex, uniforms.light.w,materialImages);
                    }
                }
            } else if (mat.type != DIELECTRIC && !(mat.type == GLOSSY && mat.roughness < 0.02f) && uniforms.samplingMode != 3) {
                LightSample ls = sample_direct_light(pos, norm, uniforms, seed, materialImages);
                if (ls.pdf > 0.0f) {
                    if (light_visible(pos, primaryHit.geometricNormal, ls, uniforms.sceneIndex, materialImages, uniforms)) {
                        float cos_th = abs(dot(norm, ls.wi));
                        float bsdf_pdf;
                        float3 bsdf = eval_bsdf_with_pdf(mat, norm, -primaryRay.direction, ls.wi, bsdf_pdf);
                        float weight = (uniforms.samplingMode <= 1) ? power_heuristic(ls.pdf, bsdf_pdf) : 1.0f;
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
            const int scatteringLimit = max(1, int(uniforms.cameraTarget.w) - 1);
            for (int bounce = 1; ; ++bounce) {
                float3 nextDirection, bsdfWeight;
                float bsdfPDF;
                bool previousDelta = is_delta(currentHit.mat);
                if (!previousDelta && scatteringDepth >= scatteringLimit) break;
                if (!previousDelta) ++scatteringDepth;
                bool previousNEE = !previousDelta && uniforms.samplingMode != 3;
                // ReSTIR covers primary diffuse hits; glossy and later bounces use MIS.
                bool previousMIS = uniforms.samplingMode == 1 ||
                    (uniforms.samplingMode == 0 && (bounce > 1 || currentHit.mat.type != DIFFUSE));
                if (!sample_bsdf(currentHit.mat, currentHit.normal, currentRay.direction,
                                 currentHit.front_face, seed, nextDirection, bsdfWeight, bsdfPDF)) break;
                throughput *= bsdfWeight;
                if (!all(isfinite(throughput)) || max(throughput.x, max(throughput.y, throughput.z)) <= 0.0f) break;
                float3 previousPosition = currentHit.position;
                float3 previousNormal = currentHit.normal;
                float3 offsetNormal = currentHit.geometricNormal;
                currentRay.origin = ray_origin(previousPosition,offsetNormal,nextDirection,uniforms);
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
                    float lightPDF = eval_light_pdf(previousPosition, rec.position, rec.mat, uniforms,materialImages);
                    float weight = emission_weight(previousDelta, previousNEE, previousMIS, bsdfPDF, lightPDF);
                    radiance += throughput * weight * rec.mat.emission;
                    break;
                }

                if (!is_delta(rec.mat) && uniforms.samplingMode != 3) {
                    LightSample ls = sample_direct_light(rec.position, rec.normal, uniforms, seed, materialImages);
                    if (light_visible(rec.position, rec.geometricNormal, ls, uniforms.sceneIndex, materialImages, uniforms)) {
                        float cosine = abs(dot(rec.normal, ls.wi));
                        float pdf;
                        float3 bsdf = eval_bsdf_with_pdf(rec.mat, rec.normal, -currentRay.direction, ls.wi, pdf);
                        // At the last vertex there will be no BSDF light sample.
                        bool useMIS = uniforms.samplingMode != 2 && scatteringDepth < scatteringLimit;
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

    // MetalFX consumes the current noisy frame, never the progressively averaged image.
    sampleTexture.write(float4(radiance, specularHitDistance), gid);
    float3 average = radiance;
    if (uniforms.frameIndex > 1) {
        float3 previous = accumTexture.read(gid).rgb;
        if (all(isfinite(previous))) average = previous + (radiance - previous) / float(uniforms.frameIndex);
    }
    accumTexture.write(float4(average, 1.0f), gid);
}


// REFERENCES.md: HILLFIT. Uses Hill's rational fit coefficients without the
// upstream ACES color matrices; this is not a complete ACES transform.
float3 tonemap(float3 color) {
    float3 a = color * (color + 0.0245786f) - 0.000090537f;
    float3 b = color * (0.983729f * color + 0.4329510f) + 0.238081f;
    return pow(clamp(a / b, 0.0f, 1.0f), float3(1.0f / 2.2f));
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
        ray.origin = ray_origin(hit.position,hit.geometricNormal,next,u);
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
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.width || gid.y >= u.height) return;
    float4 sample = samples.read(gid), p = positions.read(gid);
    float4 n = normals.read(gid), material = materials.read(gid);
    float3 normal = float3(0, 0, 1), diffuseAlbedo = float3(0), specularAlbedo = float3(0);
    float rough = 1.0f, z = 1.0f;
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
        if (int(n.w) == DIFFUSE) diffuseAlbedo = material.xyz;
        if (int(n.w) == GLOSSY) {
            rough = clamp(material.w, 0.0f, 1.0f);
            specularAlbedo = conductor_fresnel(material.xyz, max(0.0f, dot(normal, wo)));
            if (rough < 0.15f) {
                Ray reflected = { ray_origin(p.xyz,normal,normal,u), reflect(-wo, normal) };
                DenoiserMaterialGuide guide = trace_denoiser_material(reflected, u, surfaceSettings, materialImages);
                diffuseAlbedo = specularAlbedo * guide.diffuse;
                specularAlbedo *= guide.specular;
            }
        }
        if (int(n.w) == OPENPBR) {
            Ray primary = { guideCamera, -wo };
            HitRecord hit;
            if (trace_scene(primary, u.sceneIndex, hit, materialImages, u)) {
                resolve_material(hit, primary, u, surfaceSettings, materialImages, hit.t * 2.0f * tan(u.cameraPos.w * PI / 360.0f) / float(u.height));
                rough = hit.mat.roughness;
                diffuseAlbedo = hit.mat.albedo * (1.0f - hit.mat.metalness) * (1.0f - hit.mat.transmission);
                float f0 = pow((hit.mat.ior - 1.0f) / (hit.mat.ior + 1.0f), 2.0f);
                specularAlbedo = conductor_fresnel(mix(float3(f0), hit.mat.albedo, hit.mat.metalness), max(0.0f, dot(normal, wo)));
            }
        }
        if (int(n.w) == DIELECTRIC) {
            rough = 0.0f;
            float ior = abs(material.w);
            float eta = material.w > 0 ? 1.0f / ior : ior;
            float cosI = max(0.0f, dot(normal, wo));
            float f0 = (1.0f - ior) / (1.0f + ior);
            float fresnel = f0 * f0 + (1.0f - f0 * f0) * pow(1.0f - cosI, 5.0f);
            Ray reflected = { ray_origin(p.xyz,normal,normal,u), reflect(-wo, normal) };
            DenoiserMaterialGuide r = trace_denoiser_material(reflected, u, surfaceSettings, materialImages);
            float3 transmitted = refract(-wo, normal, eta);
            DenoiserMaterialGuide t = r;
            if (dot(transmitted, transmitted) > 1e-8f) {
                Ray refracted = { ray_origin(p.xyz,normal,-normal,u), normalize(transmitted) };
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
    constant float4 *display [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    uint2 source=min(uint2(float2(gid)*float2(hdr.get_width(),hdr.get_height())/float2(output.get_width(),output.get_height())),uint2(hdr.get_width()-1,hdr.get_height()-1));
    bool useRaw=display[0].w>0 && float(gid.x)/output.get_width()<display[0].w;
    float3 c=(useRaw?raw.read(source).rgb:hdr.read(source).rgb)*exp2(display[0].x)*display[1].rgb;
    if(display[0].y<0.5f) c=tonemap(c);
    // REFERENCES.md: REINHARD2002; per-channel global curve, without automatic key.
    else if(display[0].y<1.5f) c=pow(max(c/(1+c),0.0f),float3(1.0f/2.2f));
    else c=pow(clamp(c,0.0f,1.0f),float3(1.0f/2.2f));
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
    var width: UInt32
    var height: UInt32
    var jitter: SIMD2<Float> = .zero
    var sampleIndex: UInt32 = 1
    var padding: UInt32 = 0
    var environment = SIMD4<Float>(1, 0, 0, 0)
    var lens = SIMD4<Float>(0, 4, 0, 0)
    var light = SIMD4<Float>(1, 1, 1, 1)
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

func makePerspective(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1.0 / tan(fovyRadians * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * near, 0)
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

    init(device: MTLDevice, width: Int, height: Int) throws {
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
    var triangleBuffer: MTLBuffer!, nodeBuffer: MTLBuffer!
    var meshTriangles: [MeshTriangle] = []
    var hasSceneGraph = false
    var nodeCount = 0
    var objectBuffer: MTLBuffer!
    var materialX: [Int:MaterialXProgram] = [:]
    var graphInstructionBuffer: MTLBuffer!, graphHeaderBuffer: MTLBuffer!
    var graphTextures: [MTLTexture] = []
    private var emittersDirty = true
    private var cachedEmitterIndices: [UInt32] = []
    var emissions:[Int:SIMD3<Float>]=[:] {didSet{bindingsDirty=true;emittersDirty=true}}
    var emissionBuffer:MTLBuffer!,emitterBuffer:MTLBuffer!
    var orderedTriangles:[MeshTriangle]=[] { didSet { emittersDirty = true } }
    let loader: MTKTextureLoader
    // Internal fault-injection point used by the native regression suite. Nil in production.
    var bindingAllocationFailureCountdown: Int?

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
        environmentTexture=images[0]
        triangleBuffer=device.makeBuffer(length:128,options:.storageModeShared)!
        nodeBuffer=device.makeBuffer(length:48,options:.storageModeShared)!
        try prepareMaterialX([:])
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "Materials", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func validateDecodedTexture(_ texture: MTLTexture, encodedBytes: Int) throws {
        guard encodedBytes <= 128 * 1024 * 1024 else {
            throw Self.error("Texture file exceeds the 128 MiB import limit.")
        }
        let pixels = UInt64(texture.width) * UInt64(texture.height) * UInt64(max(1, texture.arrayLength))
        guard texture.width <= 16384, texture.height <= 16384, pixels <= 67_108_864 else {
            throw Self.error("Decoded texture exceeds the 16,384 pixel side or 64 megapixel limit.")
        }
        let existing = (images + graphTextures).reduce(UInt64(0)) { $0 + UInt64($1.allocatedSize) }
        let budget = max(UInt64(256 * 1024 * 1024), device.recommendedMaxWorkingSetSize / 4)
        guard existing + UInt64(texture.allocatedSize) <= budget else {
            throw Self.error("Scene textures exceed the safe GPU memory budget.")
        }
    }

    func rebuildArguments(_ replacement: [MTLTexture]) throws {
        guard let buffer = bindingBuffer(length: argumentEncoder.encodedLength) else {
            throw Self.error("Could not allocate material bindings.")
        }
        argumentEncoder.setArgumentBuffer(buffer, offset: 0)
        for (i, texture) in replacement.enumerated() { argumentEncoder.setTexture(texture, index: i) }
        argumentEncoder.setTexture(environmentTexture,index:256)
        argumentEncoder.setBuffer(triangleBuffer,offset:0,index:257)
        argumentEncoder.setBuffer(nodeBuffer,offset:0,index:258)
        guard let objectBuffer=objects.withUnsafeBytes({ bindingBuffer(bytes:$0.baseAddress!,length:$0.count) }) else { throw Self.error("Could not allocate object settings.") }
        argumentEncoder.setBuffer(objectBuffer,offset:0,index:259)
        for i in 0..<SceneLimits.graphImages { argumentEncoder.setTexture(i < graphTextures.count ? graphTextures[i] : replacement[0],index:260+i) }
        argumentEncoder.setBuffer(graphInstructionBuffer,offset:0,index:388)
        argumentEncoder.setBuffer(graphHeaderBuffer,offset:0,index:389)
        var emissionValues=Array(repeating:SIMD4<Float>(repeating:0),count:SceneLimits.materials)
        for (slot,value) in emissions {if emissionValues.indices.contains(slot){emissionValues[slot]=SIMD4(value,0)}}
        let indices: [UInt32]
        if emittersDirty {
            indices=orderedTriangles.indices.filter { i in let slot=Int(orderedTriangles[i].uvc.z);return slot>=8 && emissions[slot].map{simd_length_squared($0)>0} == true }.map{UInt32($0)}
        } else { indices = cachedEmitterIndices }
        let emitterValues=[UInt32(indices.count)]+indices
        guard let eb=emissionValues.withUnsafeBytes({bindingBuffer(bytes:$0.baseAddress!,length:$0.count)}),let ib=emitterValues.withUnsafeBytes({bindingBuffer(bytes:$0.baseAddress!,length:$0.count)}) else{throw Self.error("Could not allocate scene emitters.")}
        argumentEncoder.setBuffer(eb,offset:0,index:390);argumentEncoder.setBuffer(ib,offset:0,index:391)
        // Replace atomically; previously encoded frames retain their original buffers.
        self.objectBuffer = objectBuffer
        emissionBuffer = eb
        emitterBuffer = ib
        cachedEmitterIndices = indices
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
        let texture = try loader.newTexture(data: bytes, options: [
            .SRGB: channel == 0, .generateMipmaps: true,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ])
        try validateDecodedTexture(texture, encodedBytes: bytes.count)
        texture.label = "\((slot < Self.names.count ? Self.names[slot] : "Material \(slot)")): \(Self.mapNames[channel]) — \(url.lastPathComponent)"
        var replacement = images
        replacement[slot * 4 + channel] = texture
        try rebuildArguments(replacement)
        payloads[slot * 4 + channel] = bytes
        fileNames[slot * 4 + channel] = url.lastPathComponent
        settings[slot].mapMask |= 1 << channel
    }

    func clear(slot: Int, channel: Int) throws {
        guard (0..<SceneLimits.materials).contains(slot), (0..<4).contains(channel) else { throw Self.error("Invalid material slot.") }
        var replacement = images
        replacement[slot * 4 + channel] = defaultTextures[channel == 0 ? 0 : (channel == 3 ? 2 : 1)]
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
        encoder.useResources([environmentTexture!, triangleBuffer!, nodeBuffer!, objectBuffer!, graphInstructionBuffer!, graphHeaderBuffer!, emissionBuffer!, emitterBuffer!],usage:.read)
        encoder.useResources(graphTextures.map { $0 as MTLResource },usage:.read)
        settings.withUnsafeBytes { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.setBuffer(argumentBuffer, offset: 0, index: 2)
        encoder.useResources(images.map { $0 as MTLResource }, usage: .read)
        return true
    }
}

class PathTracerRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    let shaderLibrary: MTLLibrary
    let materialFunction: MTLFunction
    let pickPipeline: MTLComputePipelineState
    let restirTemporalPipeline: MTLComputePipelineState
    let shadingPipeline: MTLComputePipelineState
    let metalFXGuidePipeline: MTLComputePipelineState
    let presentPipeline: MTLComputePipelineState
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
    var accumTexture: MTLTexture?
    var sampleTexture: MTLTexture?

    var resPosDirA: MTLTexture?
    var resEmitPdfA: MTLTexture?
    var resWeightsA: MTLTexture?

    var resPosDirB: MTLTexture?
    var resEmitPdfB: MTLTexture?
    var resWeightsB: MTLTexture?

    var prevViewProj = matrix_identity_float4x4
    var frameIndex: UInt32 = 0
    private var sampleIndex: UInt32 = 0

    var sceneIndex: UInt32 = 0 { didSet { if oldValue != sceneIndex { applyPreset(.perspective) } } }
    var samplingMode: UInt32 = 0 { didSet { resetAccumulation() } } // 0 = ReSTIR DI, 1 = MIS, 2 = Light Only, 3 = BSDF Only
    var enableSMS: UInt32 = 0 { didSet { resetAccumulation() } }
    var skyMode: UInt32 = 0 { didSet { resetAccumulation() } }
    var enableFog: UInt32 = 0 { didSet { resetAccumulation() } }

    var yaw: Float = 0.42 { didSet { resetAccumulation(resetDenoiser: false) } }
    var pitch: Float = 0.22 { didSet { resetAccumulation(resetDenoiser: false) } }
    var distance: Float = 4.6 { didSet { resetAccumulation(resetDenoiser: false) } }
    var target = SIMD3<Float>(0.15, -0.25, 0.70) { didSet { resetAccumulation(resetDenoiser: false) } }
    var fov: Float = 38.0 { didSet { resetAccumulation(resetDenoiser: false) } }

    var options = StudioOptions()
    var paused = false
    var renderElapsed: TimeInterval = 0
    var gpuMilliseconds: Double = 0
    var framesPerSecond: Double = 0
    var completedSamples: UInt32 = 0
    var lastTick = Date()
    var lastCompletion = Date()
    var presentationNeedsRefresh = true
    var lastDisplay: MTLTexture?
    var offlineDenoisedPreview: MTLTexture?
    var lastUniforms: Uniforms?
    var onFrameUpdate: ((UInt32) -> Void)?
    var onError: ((String) -> Void)?
    private let inFlightFrames = DispatchSemaphore(value: 3)
    private var generation: UInt64 = 0
    var interactionGeneration: UInt64 { generation }

    func cameraClipPlanes() -> (near: Float, far: Float) {
        let near = max(0.00001, min(0.05, distance * 0.0001))
        return (near, max(100, min(1_000_000, distance * 2_000)))
    }
    private var rejectedRenderSize: SIMD2<Int>?

    func renderMemoryError(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return "Render dimensions must be positive." }
        let pixels = UInt64(width) * UInt64(height)
        // Accumulation, G-buffer, reservoirs, display output, and optional MetalFX
        // working textures. The estimate deliberately includes allocation overlap.
        let bytesPerPixel: UInt64 = denoiserEnabled ? 256 : 192
        let required = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        if required.overflow { return "Render dimensions are too large." }
        let recommended = device.recommendedMaxWorkingSetSize
        let budget = max(UInt64(512 * 1024 * 1024), recommended * 7 / 10)
        guard required.partialValue <= budget else {
            let mib = required.partialValue / (1024 * 1024)
            let allowed = budget / (1024 * 1024)
            return "This render needs about \(mib) MiB of GPU memory; the safe budget is \(allowed) MiB. Reduce the output dimensions or preview scale."
        }
        return nil
    }
    private var captureCallback: ((Data?) -> Void)?

    init(device: MTLDevice, sharing other: PathTracerRenderer? = nil) throws {
        self.device = device
        self.supportsMetalFX = MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
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
        } catch {
            throw error
        }
        super.init()
        denoiserEnabled = supportsMetalFX
        applyPreset(.perspective)
    }

    func captureNextFrame(_ completion: @escaping (Data?) -> Void) {
        guard captureCallback == nil else { completion(nil); return }
        self.captureCallback = completion
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
        renderElapsed = 0; lastTick = Date(); completedSamples = 0
        generation &+= 1
        frameIndex = 0
        if offlineDenoisedPreview != nil {
            offlineDenoisedPreview = nil
            paused = false
        }
        if resetDenoiser { metalFXHistoryNeedsReset = true }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
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
        if denoiserEnabled && supportsMetalFX && uniforms.samplingMode == 0 {
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
            guard let fx = metalFX, let prepare = commandBuffer.makeComputeCommandEncoder() else { return nil }
            prepare.label = "MetalFX surface and motion guides"
            prepare.setComputePipelineState(metalFXGuidePipeline)
            let inputs = [samples, positions, normals, materials, fx.color, fx.depth, fx.motion,
                          fx.diffuse, fx.specular, fx.normal, fx.roughness, fx.hitDistance, fx.denoiseMask]
            for (index, texture) in inputs.enumerated() { prepare.setTexture(texture, index: index) }
            guard self.materials.bind(prepare) else {
                prepare.endEncoding()
                onError?("Could not update material bindings.")
                return nil
            }
            prepare.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
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
            effect.isDepthReversed = false
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
            metalFXHistoryNeedsReset = true
        }
        guard encodeDisplay(commandBuffer, display: display, raw: accumulation, output: output) else { return nil }
        lastDisplay = display
        presentationNeedsRefresh = false
        return display
    }

    func encodeDisplay(_ commandBuffer: MTLCommandBuffer, display: MTLTexture, raw: MTLTexture, output: MTLTexture) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "Display tone mapping"
        encoder.setComputePipelineState(presentPipeline)
        encoder.setTexture(display,index:0); encoder.setTexture(output,index:1); encoder.setTexture(raw,index:2)
        let warmth = options.whiteBalance
        var controls = [SIMD4<Float>(options.exposure, options.toneMap, 0, lastPresentationUsedMetalFX ? options.compare : 0),
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
        if presentationNeedsRefresh, let samples=sampleTexture, let positions=historyPosDepth,
           let normals=historyNormalMat, let albedo=gbufferAlbedoRough, let uniforms=lastUniforms {
            return encodePresentation(commandBuffer:command,accumulation:raw,samples:samples,
                positions:positions,normals:normals,materials:albedo,output:output,uniforms:uniforms) != nil
        }
        return encodeDisplay(command,display:display,raw:raw,output:output)
    }

    var reachedLimit: Bool {
        (options.maxSamples > 0 && frameIndex >= options.maxSamples) ||
        (options.timeLimit > 0 && renderElapsed >= options.timeLimit)
    }
    func draw(in view: MTKView) {
        let now=Date(); defer { lastTick=now }
        guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        if (paused || reachedLimit) && !presentationNeedsRefresh { return }
        guard let drawable=view.currentDrawable else { return }
        if (paused || reachedLimit), accumTexture != nil, lastDisplay != nil {
            if let command=commandQueue.makeCommandBuffer(), presentCurrentFrame(command,output:drawable.texture) {
                presentationNeedsRefresh = false
                command.present(drawable);command.commit()
            }
            return
        }
        renderElapsed += max(0,now.timeIntervalSince(lastTick))
        renderFrame(output:drawable.texture,drawable:drawable)
    }
    func renderFrame(output: MTLTexture, drawable: CAMetalDrawable? = nil) {
        guard inFlightFrames.wait(timeout: .now()) == .success else { return }
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

        if accumTexture == nil || accumTexture?.width != w || accumTexture?.height != h {
            let desc32 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
            desc32.usage = [.shaderRead, .shaderWrite]
            desc32.storageMode = .private
            let desc16 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            desc16.usage = [.shaderRead, .shaderWrite]
            desc16.storageMode = .private

            // Publish a complete set only after every allocation succeeds.
            guard let newAccum = device.makeTexture(descriptor: desc32),
                  let newSample = device.makeTexture(descriptor: desc32),
                  let newPosition = device.makeTexture(descriptor: desc32),
                  let newHistoryPosition = device.makeTexture(descriptor: desc32),
                  let newNormal = device.makeTexture(descriptor: desc16),
                  let newHistoryNormal = device.makeTexture(descriptor: desc16),
                  let newAlbedo = device.makeTexture(descriptor: desc16),
                  let newPosA = device.makeTexture(descriptor: desc32),
                  let newEmitA = device.makeTexture(descriptor: desc32),
                  let newWeightA = device.makeTexture(descriptor: desc32),
                  let newPosB = device.makeTexture(descriptor: desc32),
                  let newEmitB = device.makeTexture(descriptor: desc32),
                  let newWeightB = device.makeTexture(descriptor: desc32) else {
                onError?("Could not allocate render textures. Try a smaller window.")
                return
            }
            accumTexture = newAccum
            sampleTexture = newSample
            gbufferPosDepth = newPosition
            historyPosDepth = newHistoryPosition
            gbufferNormalMat = newNormal
            historyNormalMat = newHistoryNormal
            gbufferAlbedoRough = newAlbedo
            resPosDirA = newPosA; resEmitPdfA = newEmitA; resWeightsA = newWeightA
            resPosDirB = newPosB; resEmitPdfB = newEmitB; resWeightsB = newWeightB

            resetAccumulation()
        }

        guard let accum = accumTexture, let samples = sampleTexture,
              let gPos = gbufferPosDepth,
              let gNorm = gbufferNormalMat,
              let gAlb = gbufferAlbedoRough,
              let hPos = historyPosDepth, let hNorm = historyNormalMat,
              let rPosA = resPosDirA, let rEmitA = resEmitPdfA, let rWeightA = resWeightsA,
              let rPosB = resPosDirB, let rEmitB = resEmitPdfB, let rWeightB = resWeightsB,
              let cmdBuffer = commandQueue.makeCommandBuffer() else { return }

        let nextFrame = frameIndex + 1
        let nextSample = sampleIndex == UInt32.max ? 1 : sampleIndex + 1

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
            width: UInt32(w),
            height: UInt32(h),
            jitter: frameJitter(nextSample), sampleIndex: nextSample,
            environment: SIMD4(options.environmentIntensity, options.environmentRotation * .pi / 180, materials.environmentData == nil ? 0 : 1, Float(materials.nodeCount)),
            lens: SIMD4(options.aperture,options.focusDistance,materials.hasSceneGraph ? 1 : 0,0),
            light: SIMD4(options.lightColor*options.lightIntensity,options.lightSize)
        )
        lastUniforms=uniforms

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let gridSize = MTLSize(width: w, height: h, depth: 1)

        // PASS 1: G-Buffer & ReSTIR Temporal Reuse
        guard let enc1 = cmdBuffer.makeComputeCommandEncoder() else { return }
        do {
            enc1.label = "Pass 1: G-Buffer & ReSTIR Temporal"
            enc1.setComputePipelineState(restirTemporalPipeline)
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
            guard materials.bind(enc1) else {
                enc1.endEncoding()
                onError?("Could not update material bindings.")
                return
            }
            enc1.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc1.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            enc1.endEncoding()
        }

        // PASS 2: Spatial Resampling & Full Path Tracing
        guard let enc2 = cmdBuffer.makeComputeCommandEncoder() else { return }
        do {
            enc2.label = "Pass 2: Spatial Resampling & Shading"
            enc2.setComputePipelineState(shadingPipeline)
            enc2.setTexture(gPos, index: 0)
            enc2.setTexture(gNorm, index: 1)
            enc2.setTexture(gAlb, index: 2)
            enc2.setTexture(rPosA, index: 3)
            enc2.setTexture(rEmitA, index: 4)
            enc2.setTexture(rWeightA, index: 5)
            enc2.setTexture(accum, index: 6)
            enc2.setTexture(samples, index: 7)
            guard materials.bind(enc2) else {
                enc2.endEncoding()
                onError?("Could not update material bindings.")
                return
            }
            enc2.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc2.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            enc2.endEncoding()
        }

        guard encodePresentation(commandBuffer: cmdBuffer, accumulation: accum, samples: samples,
            positions: gPos, normals: gNorm, materials: gAlb, output: output,
            uniforms: uniforms) != nil else { return }

        // Capture exactly the selected display (denoised when enabled).
        // Capture Frame Blit
        if let callback = self.captureCallback {
            self.captureCallback = nil
            let w=output.width, h=output.height
            let bytesPerRow = (w * 4 + 255) & ~255
            let totalBytes = bytesPerRow * h
            if let stagingBuffer = device.makeBuffer(length: totalBytes, options: .storageModeShared),
               let blitEnc = cmdBuffer.makeBlitCommandEncoder() {
                blitEnc.label = "Capture Blit"
                blitEnc.copy(from: output,
                             sourceSlice: 0,
                             sourceLevel: 0,
                             sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                             sourceSize: MTLSize(width: w, height: h, depth: 1),
                             to: stagingBuffer,
                             destinationOffset: 0,
                             destinationBytesPerRow: bytesPerRow,
                             destinationBytesPerImage: totalBytes)
                blitEnc.endEncoding()

                cmdBuffer.addCompletedHandler { completedBuffer in
                    guard completedBuffer.status == .completed else {
                        DispatchQueue.main.async { callback(nil) }
                        return
                    }
                    let data = Data(bytes: stagingBuffer.contents(), count: totalBytes)
                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
                    guard let provider = CGDataProvider(data: data as CFData),
                          let cgImage = CGImage(
                              width: w,
                              height: h,
                              bitsPerComponent: 8,
                              bitsPerPixel: 32,
                              bytesPerRow: bytesPerRow,
                              space: colorSpace,
                              bitmapInfo: bitmapInfo,
                              provider: provider,
                              decode: nil,
                              shouldInterpolate: false,
                              intent: .defaultIntent
                          ) else {
                        DispatchQueue.main.async { callback(nil) }
                        return
                    }

                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    let png = rep.representation(using: .png, properties: [:])
                    DispatchQueue.main.async {
                        callback(png)
                    }
                }
            } else {
                DispatchQueue.main.async { callback(nil) }
            }
        }

        let tmpPos = resPosDirA; resPosDirA = resPosDirB; resPosDirB = tmpPos
        let tmpEmit = resEmitPdfA; resEmitPdfA = resEmitPdfB; resEmitPdfB = tmpEmit
        let tmpWeight = resWeightsA; resWeightsA = resWeightsB; resWeightsB = tmpWeight

        swap(&gbufferPosDepth, &historyPosDepth)
        swap(&gbufferNormalMat, &historyNormalMat)
        self.prevViewProj = currViewProj
        frameIndex = nextFrame
        sampleIndex = nextSample
        let submittedGeneration = generation
        let semaphore = inFlightFrames
        cmdBuffer.addCompletedHandler { [weak self] completedBuffer in
            semaphore.signal()
            let errorMessage = completedBuffer.error?.localizedDescription
            let succeeded = completedBuffer.status == .completed
            DispatchQueue.main.async {
                guard let self = self else { return }
                if succeeded {
                    guard self.generation == submittedGeneration else { return }
                    self.completedSamples=nextFrame
                    self.gpuMilliseconds=(completedBuffer.gpuEndTime-completedBuffer.gpuStartTime)*1000
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
    private var dragged=false
    private var beganEdit=false
    private var lastPos: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragged=false; beganEdit=false
        lastPos = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = Float(p.x - lastPos.x)
        let dy = Float(p.y - lastPos.y)
        lastPos = p

        dragged = dragged || abs(dx)+abs(dy)>1
        if dragged && !beganEdit { beganEdit = true; onBeginEdit?() }
        if event.modifierFlags.contains(.shift), let renderer {
            let forward=simd_normalize(renderer.target-renderer.eyePosition)
            let right=simd_normalize(simd_cross(forward,SIMD3<Float>(0,1,0))), up=simd_cross(right,forward)
            renderer.target += (-right*dx-up*dy)*(renderer.distance*0.0015)
            onUserOrbit?();return
        }
        renderer?.yaw += dx * 0.007
        renderer?.pitch = max(-1.45, min(1.45, (renderer?.pitch ?? 0.0) - dy * 0.007))
        if dragged { onUserOrbit?() }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged {
            let p=convert(event.locationInWindow,from:nil)
            onPick?(SIMD2(Float(p.x/bounds.width),Float(1-p.y/bounds.height)))
        }
        onUserOrbit?()
    }
    override func scrollWheel(with event: NSEvent) {
        onBeginEdit?()
        let delta = Float(event.scrollingDeltaY)
        if delta != 0 {
            let current = renderer?.distance ?? 4.6
            renderer?.distance = max(0.0001, min(1_000_000, current * exp(-delta * 0.015)))
            onUserOrbit?()
        }
    }
}

// ============================================================================
// 4. GUI & HUD Layout
// ============================================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var studio: StudioController!
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let studio else { return .terminateNow }
        do {
            try studio.flushAutosave()
            return .terminateNow
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "The final autosave failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Cancel Quit")
            alert.addButton(withTitle: "Quit Anyway")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do {
            guard let device=MTLCreateSystemDefaultDevice() else { throw MaterialLibrary.error("Metal is unavailable.") }
            let renderer=try PathTracerRenderer(device:device)
            window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title="Metal Vibe Tracer";window.contentMinSize=NSSize(width:700,height:440);window.center()
            studio=StudioController(renderer:renderer,window:window)
            window.contentView=studio.view
            window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            studio.restoreAutosave()
        } catch { NSAlert(error:error).runModal(); NSApp.terminate(nil) }
    }
}

// ============================================================================
// 5. App Entry Point
// ============================================================================

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
