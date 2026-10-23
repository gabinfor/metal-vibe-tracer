// Veach MIS plates against Mitsuba 3 (REFERENCES.md MITSUBA3, ADOBEOPENPBR). The image-left plate of
// scene 2 (the camera's right is world -x, so it is plate 3, roughness 0.45) rendered 17% brighter than
// a single-scattering Mitsuba roughconductor. The two-sided near-mirror plate 0 was suspected; these
// checks pin both halves of the diagnosis. (1) A delta mirror quad reflects identically from either face:
// normal flip, Schlick cosine and mirrored direction. (2) A rough GLOSSY metal is the single-scattering
// GGX lobe (separable Smith, Schlick F0) plus Adobe's metal multiple-scattering lobe
//   scale min((1 - E(mu_i)) (1 - E(mu_o)) / (1 - E_avg), 1 / mu_i) / pi,  scale = Favg^2 = (F0 + (1 - F0) / 21)^2,
// which scripts/compare_mitsuba.py (openpbr_metal_ms) adds to its Mitsuba reference. A change to this
// model must update that reference too.
@MainActor func fixVeachPlateChecks() throws {
  let kernel = """
    kernel void fix_veach_plate_checks(device float4 *out [[buffer(0)]]) {
        // --- (1) Plate 0 of scene 2 from its front and back faces ---------------------------------
        float3 u = float3(-1.2f, 0, 0), v = float3(0, -1.4f * sin(0.6f), -1.4f * cos(0.6f));
        float3 c = float3(-2.4f - 0.6f, -0.85f, -0.5f) - u - v, n = normalize(cross(u, v));
        float3 center = c + 0.5f * (u + v), side = normalize(u);
        Material plate = { GLOSSY, float3(0.95f, 0.92f, 0.88f), float3(0), 0.005f, 1 };
        uint seed = 7u;
        for (int face = 0; face < 2; ++face) {
            float3 origin = center + (face == 0 ? 2.0f : -2.0f) * n + 0.7f * side;
            Ray r = { origin, normalize(center - origin) };
            HitRecord rec;
            bool hit = intersect_quad(r, c, u, v, n, false, plate, 0.001f, 1e30f, rec);
            Material m = rec.mat; m.geometricNormal = rec.geometricNormal;
            float3 direction; Spectrum weight; float pdf;
            bool sampled = hit && sample_bsdf(m, rec.normal, r.direction, rec.front_face, seed, direction, weight, pdf, Wavelengths());
            float cosine = dot(-r.direction, rec.normal);
            float3 schlick = plate.albedo + (1.0f - plate.albedo) * pow(1.0f - cosine, 5.0f);
            float3 mirrored = reflect(r.direction, rec.normal);
            out[3 * face + 0] = float4(rec.normal, hit && sampled ? 1.0f : 0.0f);
            out[3 * face + 1] = float4(float3(weight.x, weight.y, weight.z) - schlick, rec.front_face ? 1.0f : 0.0f);
            out[3 * face + 2] = float4(direction - mirrored, cosine);
        }
        // --- (2) Rough GLOSSY = single-scattering GGX + metal multiple scattering ------------------
        float roughness = 0.45f, alpha = roughness * roughness;
        Material metal = { GLOSSY, float3(0.95f, 0.92f, 0.88f), float3(0), roughness, 1 };
        float3 f0 = metal.albedo, favg = f0 + (1.0f - f0) / 21.0f;
        float3 normal = float3(0, 0, 1), wo = float3(sin(0.6f), 0, cos(0.6f));
        float3 directions[4] = { float3(-sin(0.6f), 0, cos(0.6f)), normalize(float3(0.2f, 0.5f, 0.8f)),
                                 normalize(float3(0.6f, -0.3f, 0.3f)), normalize(float3(-0.95f, 0.1f, 0.12f)) };
        for (int i = 0; i < 4; ++i) {
            float3 wi = directions[i], h = normalize(wo + wi);
            float d = alpha * alpha / (PI * pow(h.z * h.z * (alpha * alpha - 1.0f) + 1.0f, 2.0f));
            float g = openpbr_eval_aniso_smith_g1(wo, float2(alpha)) * openpbr_eval_aniso_smith_g1(wi, float2(alpha));
            float3 fresnel = f0 + (1.0f - f0) * pow(1.0f - dot(wo, h), 5.0f);
            float3 single = fresnel * d * g / (4.0f * wo.z * wi.z);
            float factors = min(vibe_metal_energy(alpha, wo.z) * vibe_metal_energy(alpha, wi.z)
                                / max(vibe_metal_average_energy(alpha), 1e-12f), 1.0f / wi.z);
            float3 multiple = favg * favg * factors / PI;
            Spectrum f = eval_bsdf(metal, normal, wo, wi, Wavelengths());
            float3 value = float3(f.x, f.y, f.z), expected = single + multiple;
            out[6 + i] = float4(abs(value - expected) / expected, multiple.y / expected.y);
        }
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernel, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "fix_veach_plate_checks")!)
  let count = 10
  let buffer = gpu.makeBuffer(length: count * 16, options: .storageModeShared)!
  let command = testRenderer.commandQueue.makeCommandBuffer()!
  let encoder = command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(pipeline)
  encoder.setBuffer(buffer, offset: 0, index: 0)
  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
  require(command.status == .completed, "Veach plate kernel completed")
  let out = (0..<count).map { buffer.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
  print("Veach plate checks: \(out)")
  // (1) Front (face 0) and back (face 1) of the two-sided delta plate.
  require(out[0].w == 1 && out[3].w == 1, "delta plate hit and sampled from both faces")
  require(out[1].w == 1 && out[4].w == 0, "front_face distinguishes the plate's faces")
  require(simd_dot(xyz(out[0]), xyz(out[3])) < -0.9999, "the back face's shading normal faces the back-side ray")
  require(abs(out[2].w - out[5].w) < 1e-5 && out[2].w > 0, "mirror-image rays meet both faces at one cosine")
  for face in [0, 1] {
    require(simd_length(xyz(out[3 * face + 1])) < 1e-5, "delta plate weight is Schlick(F0, cos) on face \(face)")
    require(simd_length(xyz(out[3 * face + 2])) < 1e-5, "delta plate reflects about the face's normal on face \(face)")
  }
  // (2) Separable-Smith GGX plus the multiple-scattering lobe; off the specular peak the latter dominates.
  for i in 0..<4 {
    require(xyz(out[6 + i]).max() < 2e-3, "rough GLOSSY metal = single + multiple scattering, direction \(i): \(out[6 + i])")
  }
  require(out[6].w < 0.05 && out[8].w > 0.3, "multiple scattering is small at the specular peak and large off it")
  print("PASS: Veach plates (two-sided delta mirror faces, OpenPBR metal multiple scattering of the Mitsuba reference)")
}
try fixVeachPlateChecks()
