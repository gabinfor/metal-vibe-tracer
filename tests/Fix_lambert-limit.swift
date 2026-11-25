// The Lambert limit of imported OpenPBR materials (REFERENCES.md OPENPBR, ADOBEOPENPBR): a MaterialX material whose
// only lobe is the smooth base diffuse one at full weight (material_lambert; Mitsuba's `diffuse`) resolves to the
// DIFFUSE type, which is evaluated and sampled as base_color / pi without preparing the layered BSDF. The upstream
// BSDF has that PDF there, and that value except within about 3 degrees of the horizon; every input that adds a lobe
// keeps the OPENPBR type.
@MainActor func fixLambertLimitChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("lambert-limit", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  func material(_ name: String, _ inputs: String) throws -> MaterialXProgram {
    let imported = try MaterialXImporter.read(
      Data(("<materialx version=\"1.39\"><open_pbr_surface name=\"\(name)\" type=\"surfaceshader\">" + inputs
        + "</open_pbr_surface></materialx>").utf8), baseURL: folder, source: name + ".mtlx")
    guard let program = imported.materials.first else { throw MaterialLibrary.error("\(name): \(imported.report)") }
    return program
  }
  let matte = "<input name=\"specular_weight\" type=\"float\" value=\"0\"/><input name=\"base_color\" type=\"color3\" value=\"0.8, 0.4, 0.2\"/>"
  var state = SceneState()
  state.materialX = [
    8: try material("Matte", matte),
    9: try material("Plastic", "<input name=\"base_color\" type=\"color3\" value=\"0.8, 0.4, 0.2\"/>"),
    10: try material("Glow", matte + "<input name=\"emission_luminance\" type=\"float\" value=\"100\"/>"),
    11: try material("Weighted", matte + "<input name=\"base_weight\" type=\"float\" value=\"0.5\"/>"),
  ]
  let l = try MaterialLibrary(device: gpu, function: testRenderer.materialFunction)
  try l.restore(state)
  let kernel = """
    float lambert_max(float3 v) { return max(abs(v.x), max(abs(v.y), abs(v.z))); }
    Material lambert_resolved(uint slot, bool front, constant Uniforms &u, constant SurfaceSettings *settings,
                              constant MaterialResources &images) {
        HitRecord h = {}; h.mat.type = DIFFUSE; h.mat.slot = slot; h.uv = float2(0.5f); h.front_face = front;
        h.normal = h.geometricNormal = float3(0, 0, 1);
        Ray ray = { float3(0, 0, 1), float3(0, 0, -1) };
        resolve_material(h, ray, u, settings, images, 0.0f);
        return h.mat;
    }
    kernel void lambert_probe(constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],
                              constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(3)]],
                              uint id [[thread_position_in_grid]]) {
        if (id != 0) return;
        Wavelengths wl;
        float3 n = float3(0, 0, 1);
        // The upstream BSDF in the limit, whatever the inputs of its weightless lobes.
        float upstreamValue = 0.0f, upstreamPdf = 0.0f, pairs = 0.0f, below = 0.0f;
        uint seed = 20261115u;
        Material limit = {};
        for (uint i = 0; i < 8192u; ++i) {
            Material m = {}; m.type = OPENPBR; m.usesMaterialX = 1u; m.baseWeight = 1.0f;
            m.albedo = rand_f3(seed);
            m.roughness = rand_f(seed); m.ior = 1.2f + rand_f(seed); m.specularColor = rand_f3(seed);
            m.coatRoughness = rand_f(seed); m.anisotropy = rand_f(seed);
            m.transmissionTint = float4(rand_f3(seed), i % 2u == 1u ? 1.0f : 0.0f);
            m.subsurface = float4(rand_f3(seed), 0.0f);
            m.geometricNormal = n;
            limit = m;
            float3 wo = sample_cosine_hemisphere(n, rand_f2(seed));
            float3 u = rand_f3(seed);
            float z = 1.0f - 2.0f * u.x, s = sqrt(max(0.0f, 1.0f - z * z));
            float3 wi = float3(s * cos(TWO_PI * u.y), s * sin(TWO_PI * u.y), z);
            if (wo.z < 0.02f || abs(wi.z) < 0.02f || !material_lambert(m)) continue;
            pairs += 1.0f; below += wi.z < 0.0f ? 1.0f : 0.0f;
            float3 expected = wi.z > 0.0f ? m.albedo / PI : float3(0.0f);
            OpenPBR_PreparedBsdf p = prepare_openpbr(m, n, wo);
            // Within about 3 degrees of the horizon (cosine below 0.05) the upstream value departs from base_color / pi
            // by up to 14% (0.07%, 2e-4 absolute, between 0.05 and 0.1; 0.003% beyond), weighted there by a cosine of at most 0.05.
            if (min(wo.z, abs(wi.z)) >= 0.05f)
                upstreamValue = max(upstreamValue, lambert_max(openpbr_get_sum_of_diffuse_specular(openpbr_eval(p, wi)) / abs(wi.z) - expected));
            upstreamPdf = max(upstreamPdf, abs(openpbr_pdf(p, wi) - max(0.0f, wi.z) / PI));
        }
        out[0] = float4(upstreamValue, upstreamPdf, pairs, below);
        // The predicate: one added lobe, weight or material class at a time leaves the limit.
        uint wrong = material_lambert(limit) ? 0u : 1u;
        for (uint c = 1u; c < 13u; ++c) {
            Material m = limit;
            if (c == 1u) m.specularWeight = 0.25f;
            if (c == 2u) m.metalness = 0.25f;
            if (c == 3u) m.coat = 0.25f;
            if (c == 4u) m.fuzz = 0.25f;
            if (c == 5u) m.transmission = 0.25f;
            if (c == 6u) m.diffuseRoughness = 0.25f;
            if (c == 7u) { m.transmissionTint.w = 1.0f; m.subsurface.w = 0.25f; }
            if (c == 8u) m.usesMaterialX = 0u;
            if (c == 9u) m.type = GLOSSY;
            if (c == 10u) m.type = DIELECTRIC;
            if (c == 11u) m.baseWeight = 0.5f;
            if (c == 12u) m.emission = float3(0, 1, 0);
            if (material_lambert(m)) wrong |= 1u << c;
        }
        out[1] = float4(float(wrong), 0, 0, 0);
        // Resolution: only the limit takes the DIFFUSE type, and the adapters then return the Lambert values.
        Material matte = lambert_resolved(8u, true, u, settings, images);
        out[2] = float4(float(uint(matte.type)), float(uint(lambert_resolved(9u, true, u, settings, images).type)),
                        float(uint(lambert_resolved(10u, true, u, settings, images).type)), float(uint(lambert_resolved(11u, true, u, settings, images).type)));
        out[3] = float4(matte.albedo, float(uint(lambert_resolved(10u, false, u, settings, images).type)));
        float adapterValue = 0.0f, adapterPdf = 0.0f, sampleError = 0.0f, sampled = 0.0f;
        for (uint i = 0; i < 4096u; ++i) {
            float3 wo = sample_cosine_hemisphere(n, rand_f2(seed));
            float3 wi = sample_cosine_hemisphere(n, rand_f2(seed));
            if (wo.z < 0.02f || wi.z < 0.02f) continue;
            float pdf;
            Spectrum f = eval_bsdf_with_pdf(matte, n, wo, wi, pdf, wl);
            adapterValue = max(adapterValue, lambert_max(f - matte.albedo / PI));
            adapterPdf = max(adapterPdf, abs(pdf - wi.z / PI));
            float3 d; Spectrum w; float samplePdf;
            if (sample_bsdf(matte, n, -wo, true, seed, d, w, samplePdf, wl)) {
                sampled += 1.0f;
                sampleError = max(sampleError, max(abs(samplePdf - d.z / PI), lambert_max(w - matte.albedo)));
            }
        }
        out[4] = float4(adapterValue, adapterPdf, sampleError, sampled);
        out[5] = float4(float(uint(DIFFUSE)), float(uint(OPENPBR)), 0, 0);
    }
    """
  let library = try gpu.makeLibrary(source: metalSource + kernel, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "lambert_probe")!)
  let out = gpu.makeBuffer(length: 6 * 16, options: .storageModeShared)!
  let command = testRenderer.commandQueue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(pipeline)
  require(l.bind(encoder), "the Lambert limit probe binds material resources")
  var uniforms = makeUniforms(scene: 6, mode: 0, width: 1, height: 1)
  encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
  encoder.setBuffer(out, offset: 0, index: 3)
  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
  let v = (0..<6).map { out.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  print("Lambert limit probe: \(v)")
  let diffuse = v[5].x, openPBR = v[5].y
  require(v[0].z > 6000 && v[0].w > 2000, "the probe covers reflected and below-surface directions (\(v[0]))")
  require(v[0].x < 5e-4 && v[0].y < 1e-4,
    "the upstream BSDF is base_color / pi (away from the horizon) with a cosine PDF in the Lambert limit (errors \(v[0].x), \(v[0].y))")
  require(v[1].x == 0, "material_lambert accepts only the limit, thin-walled or not (mask \(v[1].x))")
  require(v[2].x == diffuse && simd_reduce_max(simd_abs(v[3] - SIMD4(0.8, 0.4, 0.2, v[3].w))) < 1e-6,
    "a MaterialX material with specular_weight 0 resolves to DIFFUSE with its base colour (\(v[2]), \(v[3]))")
  require(v[2].y == openPBR && v[2].z == openPBR && v[2].w == openPBR,
    "a specular layer, emission or a partial base_weight keeps the layered BSDF (\(v[2]))")
  require(v[3].w == diffuse, "an emitter's back face, which emits nothing, is Lambertian (\(v[3].w))")
  require(v[4].w > 3000 && v[4].x < 1e-6 && v[4].y < 1e-6 && v[4].z < 1e-5,
    "the resolved material is evaluated and sampled as base_color / pi (errors \(v[4]))")
}
try fixLambertLimitChecks()
