// Appended last by verify.py (full suite): legacy material path and delta BSDF regressions.
func fixBsdfLegacyChecks() throws {
  let folder = URL(fileURLWithPath: "build/checks/fix-bsdf-legacy", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  func fixture(_ name: String, _ pixel: [UInt8]) throws -> URL {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 8 * 4, bitsPerPixel: 32)!
    for i in 0..<64 { for c in 0..<4 { bitmap.bitmapData![i * 4 + c] = pixel[c] } }
    let url = folder.appendingPathComponent(name + ".png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    return url
  }
  // Tilted in both tangent axes: x = 0.5686, +Y green = 0.4118.
  let tilted = try fixture("tilted-normal", [200, 180, 255, 255])
  let flat = try fixture("flat-normal", [128, 128, 255, 255])
  let gray = try fixture("gray", [128, 128, 128, 255])
  let library = testRenderer.materials
  try library.restore(SceneState())
  try library.load(url: tilted, slot: 1, channel: 3)
  try library.load(url: flat, slot: 3, channel: 3)
  try library.load(url: gray, slot: 4, channel: 1)
  try library.load(url: gray, slot: 5, channel: 2)
  try library.load(url: gray, slot: 6, channel: 1)
  let graph = try MaterialXImporter.read(Data("""
    <materialx version="1.39">
    <normalmap name="normal" type="vector3"><input name="in" type="vector3" value="0.784314,0.705882,1"/></normalmap>
    <open_pbr_surface name="Tilt" type="surfaceshader"><input name="geometry_normal" type="vector3" nodename="normal"/></open_pbr_surface>
    </materialx>
    """.utf8), baseURL: folder, source: "Tilt.mtlx")
  require(graph.materials.count == 1, "normal-map MaterialX fixture compiles: \(graph.report)")
  try library.prepareMaterialX([2: graph.materials[0]])
  // A smooth-shaded panel facing +Z whose vertex normals lean toward +X.
  try library.setMesh(try OBJMesh.load("""
    v -1 0 0
    v 1 0 0
    v 1 2 0
    v -1 2 0
    vt 0 0
    vt 1 0
    vt 1 1
    vt 0 1
    vn 0.3 0 1
    f 1/1/1 2/2/1 3/3/1 4/4/1
    """))
  library.hasSceneGraph = false
  let kernel = """
    float3 fix_resolved_normal(HitRecord h, uint slot, Ray r, constant Uniforms &u, constant SurfaceSettings *settings, constant MaterialResources &images) {
        Material m = { DIFFUSE, float3(0.7f), float3(0), 0, 1 }; m.slot = slot; h.mat = m;
        resolve_material(h, r, u, settings, images, 0); return h.normal;
    }
    float4 fix_resolved_scalars(HitRecord h, Material m, Ray r, constant Uniforms &u, constant SurfaceSettings *settings, constant MaterialResources &images, device float4 *ior) {
        h.mat = m; resolve_material(h, r, u, settings, images, 0);
        *ior = float4(h.mat.ior); return float4(float(h.mat.type), h.mat.roughness, h.mat.metalness, h.mat.transmission);
    }
    kernel void fix_bsdf_legacy_checks(constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],
        constant MaterialResources &images [[buffer(2)]], device float4 *out [[buffer(3)]]) {
        Ray front = { float3(0.2f, 0.7f, 2), float3(0, 0, -1) }, back = { float3(0.2f, 0.7f, -2), float3(0, 0, 1) };
        HitRecord f, b;
        bool found = trace_scene(front, 6, f, images, u) && trace_scene(back, 6, b, images, u) && f.front_face && !b.front_face;
        out[0] = float4(f.normal, found ? 1 : 0);
        out[1] = float4(f.geometricNormal, 0);
        out[2] = float4(f.tangent, 0);
        out[3] = float4(fix_resolved_normal(f, 1, front, u, settings, images), 0);
        out[4] = float4(fix_resolved_normal(b, 1, back, u, settings, images), 0);
        out[5] = float4(fix_resolved_normal(f, 2, front, u, settings, images), 0);
        out[6] = float4(fix_resolved_normal(b, 2, back, u, settings, images), 0);
        out[7] = float4(fix_resolved_normal(f, 3, front, u, settings, images), 0);
        // Sphere and two-sided quad: the same point seen from both sides.
        Material matte = { DIFFUSE, float3(0.7f), float3(0), 0, 1 };
        float3 p = normalize(float3(0.3f, 0.5f, -0.8f)), w = normalize(p + float3(0.1f, 0, 0));
        Ray outside = { p + 3 * w, -w }, inside = { p - 0.5f * w, w };
        HitRecord so, si;
        bool sphere = intersect_sphere(outside, float3(0), 1, matte, 0.001f, 100, so) && intersect_sphere(inside, float3(0), 1, matte, 0.001f, 100, si);
        out[8] = float4(fix_resolved_normal(so, 1, outside, u, settings, images), sphere ? 1 : 0);
        out[9] = float4(fix_resolved_normal(si, 1, inside, u, settings, images), 0);
        float3 q = float3(0.2f, 0.3f, 0), d = normalize(float3(0.2f, -0.1f, -1));
        Ray above = { q - 3 * d, d }, below = { q + 3 * d, -d };
        HitRecord qa, qb;
        bool quad = intersect_quad(above, float3(-1, -1, 0), float3(2, 0, 0), float3(0, 2, 0), float3(0, 0, 1), false, matte, 0.001f, 100, qa)
            && intersect_quad(below, float3(-1, -1, 0), float3(2, 0, 0), float3(0, 2, 0), float3(0, 0, 1), false, matte, 0.001f, 100, qb);
        out[10] = float4(fix_resolved_normal(qa, 1, above, u, settings, images), quad ? 1 : 0);
        out[11] = float4(fix_resolved_normal(qb, 1, below, u, settings, images), 0);
        // Original scene materials promoted by roughness or metalness maps.
        Material glassMaterial = { DIELECTRIC, float3(1), float3(0), 0, 1.52f };
        matte.slot = 4; out[12] = fix_resolved_scalars(f, matte, front, u, settings, images, out + 15);
        matte.slot = 5; out[13] = fix_resolved_scalars(f, matte, front, u, settings, images, out + 16);
        glassMaterial.slot = 6; out[14] = fix_resolved_scalars(f, glassMaterial, front, u, settings, images, out + 17);
        // Delta glass Fresnel when exiting (cosI 0.76) and entering the dense side.
        uint seed = 71;
        float3 n = float3(0, 0, 1), exiting = float3(sqrt(1 - 0.76f * 0.76f), 0, -0.76f);
        Material glass = glassMaterial; glass.geometricNormal = n;
        float exitReflect = 0, enterReflect = 0;
        for (int i = 0; i < 8192; ++i) {
            float3 direction, weight; float pdf;
            if (sample_bsdf(glass, n, exiting, false, seed, direction, weight, pdf) && direction.z > 0) exitReflect += 1;
            if (sample_bsdf(glass, n, exiting, true, seed, direction, weight, pdf) && direction.z > 0) enterReflect += 1;
        }
        out[18] = float4(exitReflect / 8192, enterReflect / 8192, 0, 0);
        // Grazing delta events about a tilted shading normal must stay on their geometric side.
        float3 shading = normalize(float3(0.3f, 0, 1)), grazing = normalize(float3(0.9f, 0, -0.436f));
        Material chrome = { GLOSSY, float3(0.9f), float3(0), 0.001f, 1 }; chrome.geometricNormal = n;
        float3 direction, weight; float pdf;
        bool mirrored = sample_bsdf(chrome, shading, grazing, true, seed, direction, weight, pdf);
        out[19] = float4(direction, mirrored ? 1 : 0);
        float reflections = 0, transmissions = 0, crossings = 0;
        for (int i = 0; i < 4096; ++i) {
            if (!sample_bsdf(glass, shading, grazing, true, seed, direction, weight, pdf)) continue;
            bool reflected = weight.x > 0.9f;
            reflections += reflected ? 1 : 0; transmissions += reflected ? 0 : 1;
            if ((direction.z > 0) != reflected) crossings += 1;
        }
        out[20] = float4(reflections, transmissions, crossings, 0);
    }
    """
  let checks = try gpu.makeLibrary(source: metalSource + kernel, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(function: checks.makeFunction(name: "fix_bsdf_legacy_checks")!)
  var u = makeUniforms(scene: 6, mode: 0, width: 1, height: 1)
  u.environment.w = Float(library.nodeCount)
  let count = 21
  let buffer = gpu.makeBuffer(length: count * 16, options: .storageModeShared)!
  let command = testRenderer.commandQueue.makeCommandBuffer()!
  let encoder = command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(pipeline)
  library.bind(encoder)
  encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
  encoder.setBuffer(buffer, offset: 0, index: 3)
  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
  require(command.status == .completed, "legacy BSDF regression kernel completed")
  let out = (0..<count).map { buffer.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
  print("Legacy BSDF checks: \(out)")
  let smooth = xyz(out[0]), geometric = xyz(out[1]), tangent = xyz(out[2])
  require(out[0].w == 1 && simd_dot(smooth, geometric) < 0.99, "smooth mesh hit from both sides")
  // R-05: +Y green tilts toward the image top (+Y here), matching MaterialX normalmap.
  let legacy = xyz(out[3]), materialX = xyz(out[5])
  require(legacy.y > 0.2 && simd_dot(legacy, tangent) > 0.2, "inspector normal map follows +Y green and +X red")
  require(simd_length(legacy - materialX) < 0.01, "inspector and MaterialX normal maps agree")
  // R-06: a flat map keeps the interpolated shading normal.
  require(simd_dot(xyz(out[7]), smooth) > 0.9999, "flat inspector normal map keeps the smooth normal")
  // R-49: both sides of a surface see one perturbed normal.
  require(simd_dot(xyz(out[3]), xyz(out[4])) < -0.9999, "mesh normal map agrees between faces")
  require(simd_dot(xyz(out[5]), xyz(out[6])) < -0.9999, "MaterialX mesh normal map agrees between faces")
  require(out[8].w == 1 && simd_dot(xyz(out[8]), xyz(out[9])) < -0.9999, "sphere normal map agrees between faces")
  require(out[10].w == 1 && simd_dot(xyz(out[10]), xyz(out[11])) < -0.9999, "quad normal map agrees between faces")
  // R-22: maps on original scene materials use promoted, inspector-consistent scalars.
  let openPBR = Float(4)
  require(out[12].x == openPBR && abs(out[12].y - 0.502) < 0.004 && out[12].w == 0, "roughness map promotes a matte original material")
  require(out[13].x == openPBR && abs(out[13].y - 0.3) < 1e-5 && abs(out[13].z - 0.502) < 0.004 && abs(out[16].x - 1.5) < 1e-5,
    "metalness map on a matte original material keeps inspector roughness and IOR")
  require(out[14].x == openPBR && abs(out[14].y - 0.502) < 0.004 && out[14].w == 1 && abs(out[17].x - 1.52) < 1e-5,
    "roughness map keeps original glass transmissive")
  // R-54: exiting Schlick uses cosT (about 0.46 here); entering stays about 0.043.
  require(out[18].x > 0.38 && out[18].x < 0.53, "exiting delta glass reflectance")
  require(out[18].y > 0.03 && out[18].y < 0.06, "entering delta glass reflectance")
  // R-55: delta reflection and refraction never cross the geometric surface.
  require(out[19].w == 1 && out[19].z > 0, "grazing delta mirror stays above the geometric surface")
  require(out[20].x > 100 && out[20].y > 100 && out[20].z == 0, "grazing delta glass keeps reflection and refraction sides")
  try library.restore(SceneState())

  // R-93: the light well shows sRGB and stores linear light color.
  let savedLight = testRenderer.options.lightColor
  controller.page = 2; controller.rebuild(); controller.view.layoutSubtreeIfNeeded()
  func wells(_ view: NSView) -> [ActionColor] {
    (view as? ActionColor).map { [$0] } ?? view.subviews.flatMap(wells)
  }
  let lightWells = wells(controller.stack)
  require(lightWells.count == 1, "lighting page has one color well")
  lightWells[0].color = NSColor(srgbRed: 0.5, green: 0.25, blue: 1, alpha: 1)
  // StudioChecks disables event grouping; register the checkpoint in an explicit group.
  controller.history.beginUndoGrouping(); lightWells[0].changed(); controller.history.endUndoGrouping()
  let stored = testRenderer.options.lightColor
  require(abs(stored.x - 0.21404) < 0.001 && abs(stored.y - 0.05088) < 0.001 && abs(stored.z - 1) < 1e-5,
    "light color well decodes sRGB to linear")
  controller.rebuild()
  let shown = wells(controller.stack).first?.color.usingColorSpace(.sRGB)
  require(shown.map { abs($0.redComponent - 0.5) < 0.002 && abs($0.greenComponent - 0.25) < 0.002 } == true,
    "light color well re-encodes linear color for display")
  testRenderer.options.lightColor = savedLight
  controller.saveTimer?.invalidate()
  print("PASS: legacy normal-map frame, promoted original materials, delta Fresnel and geometric sides, light color well")
}
try fixBsdfLegacyChecks()
