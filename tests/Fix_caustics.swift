// Caustic light paths (docs/CAUSTICS_DESIGN.md): light tracing and photons add what the camera paths leave out, so
// renders with caustics on agree with long path-traced references (caustics off). glTF scenes whose floor is lit only
// by caustics: an emitter facing up under a polished metal ceiling (L S D; shading_kernel's camera paths), and an
// emitter facing down through a glass slab, absorbing (L S S D with an interior medium; volume_path) or clear (no
// medium; shading_kernel, where photons are gathered at later receivers too), a floor inside a clear block (L S D, a
// pool: photons inside an object), the clear slab in haze (L S S M: volume photons) and under a sun (light paths from
// the environment), in RGB and spectral transport (photons at shared wavelength groups), with a pinhole and a thin lens,
// and with emission guiding (docs/CAUSTICS_DESIGN.md §5) on the mirror and the clear slab.
@MainActor func fixCausticChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("caustics", isDirectory: true)
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let r = testRenderer

  // A GLB of square quads (each facing +Y before its node's rotation and scale), one material per quad.
  struct Quad { var size: Float; var translation: [Float]; var rotation: [Float]; var scale: [Float] = [1, 1, 1]; var material: [String: Any] }
  func glb(_ name: String, quads: [Quad]) throws -> ProjectDocument {
    var bin = Data(), views: [[String: Any]] = [], accessors: [[String: Any]] = []
    func add(_ floats: [Float], _ type: String, _ count: Int) -> Int {
      views.append(["buffer": 0, "byteOffset": bin.count, "byteLength": 4 * floats.count])
      floats.withUnsafeBytes { bin.append(contentsOf: $0) }
      accessors.append(["bufferView": views.count - 1, "componentType": 5126, "count": count, "type": type])
      if type == "VEC3" {
        accessors[accessors.count - 1]["min"] = (0..<3).map { c in stride(from: c, to: floats.count, by: 3).map { floats[$0] }.min()! }
        accessors[accessors.count - 1]["max"] = (0..<3).map { c in stride(from: c, to: floats.count, by: 3).map { floats[$0] }.max()! }
      }
      return accessors.count - 1
    }
    var meshes: [[String: Any]] = [], nodes: [[String: Any]] = []
    for (i, q) in quads.enumerated() {
      let s = q.size / 2
      // Counter-clockwise seen from +Y: the winding normal (and an emitter's emitting side) is +Y.
      let p = add([-s, 0, -s, -s, 0, s, s, 0, s, -s, 0, -s, s, 0, s, s, 0, -s], "VEC3", 6)
      let n = add(Array(repeating: [Float(0), 1, 0], count: 6).flatMap { $0 }, "VEC3", 6)
      meshes.append(["primitives": [["attributes": ["POSITION": p, "NORMAL": n], "material": i]]])
      nodes.append(["mesh": i, "translation": q.translation, "rotation": q.rotation, "scale": q.scale])
    }
    var json: [String: Any] = [
      "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": Array(0..<quads.count)]], "nodes": nodes, "meshes": meshes,
      "materials": quads.map(\.material), "bufferViews": views, "accessors": accessors, "buffers": [["byteLength": bin.count]],
    ]
    json["extensionsUsed"] = ["KHR_materials_transmission", "KHR_materials_volume", "KHR_materials_emissive_strength"]
    var text = try JSONSerialization.data(withJSONObject: json)
    while text.count % 4 != 0 { text.append(0x20) }
    while bin.count % 4 != 0 { bin.append(0) }
    var out = Data("glTF".utf8)
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; out.append(Data(bytes: &x, count: 4)) }
    u32(2); u32(12 + 8 + text.count + 8 + bin.count)
    u32(text.count); u32(0x4E4F_534A); out.append(text)
    u32(bin.count); u32(0x004E_4942); out.append(bin)
    let url = folder.appendingPathComponent(name + ".glb")
    try out.write(to: url)
    return try GLTFImporter.load(url, into: ProjectDocument()).document
  }
  let floor: [String: Any] = ["pbrMetallicRoughness": ["baseColorFactor": [0.8, 0.8, 0.8, 1], "metallicFactor": 0, "roughnessFactor": 1]]
  let lamp: [String: Any] = ["pbrMetallicRoughness": ["baseColorFactor": [0, 0, 0, 1], "metallicFactor": 0],
                             "emissiveFactor": [1, 0.9, 0.7], "extensions": ["KHR_materials_emissive_strength": ["emissiveStrength": 8]]]
  let mirror: [String: Any] = ["pbrMetallicRoughness": ["baseColorFactor": [0.9, 0.9, 0.9, 1], "metallicFactor": 1, "roughnessFactor": 0.08]]
  let glass: [String: Any] = ["pbrMetallicRoughness": ["metallicFactor": 0, "roughnessFactor": 0.05],
                              "extensions": ["KHR_materials_transmission": ["transmissionFactor": 1],
                                             "KHR_materials_volume": ["thicknessFactor": 0.3, "attenuationDistance": 0.5,
                                                                      "attenuationColor": [0.6, 0.85, 0.9]]]]
  var clearGlass = glass
  clearGlass["extensions"] = ["KHR_materials_transmission": ["transmissionFactor": 1], "KHR_materials_volume": ["thicknessFactor": 0.3]]
  let up: [Float] = [0, 0, 0, 1], down: [Float] = [1, 0, 0, 0]
  // Mirror: the floor sees the lamp only in the metal ceiling.
  let mirrorScene = try glb("mirror", quads: [
    Quad(size: 4, translation: [0, 0, 0], rotation: up, material: floor),
    Quad(size: 0.6, translation: [0, 1.6, 0], rotation: up, material: lamp),
    Quad(size: 3, translation: [0, 2.4, 0], rotation: down, material: mirror),
  ])
  // Glass: the lamp shines down through a closed slab (top, bottom, four outward-facing sides) with an absorbing interior,
  // in front of a diffuse back wall, so caustic light also reaches the camera after a diffuse bounce (photons gathered
  // at a later receiver).
  let half: Float = 1.25, top: Float = 1.0
  func side(_ axis: Int, _ sign: Float, _ glass: [String: Any], bottom: Float) -> Quad {
    // A quarter turn about Z (X sides) or X (Z sides) turns +Y to the outward normal; the scale then shrinks the
    // in-plane axis that became vertical to the slab's thickness.
    let c = sin(Float.pi / 4), angle = sign > 0 ? -c : c
    var translation: [Float] = [0, (top + bottom) / 2, 0]
    translation[axis] = sign * half
    let thin = (top - bottom) / (2 * half)
    return Quad(size: 2 * half, translation: translation, rotation: axis == 0 ? [0, 0, angle, c] : [-angle, 0, 0, c],
                scale: axis == 0 ? [thin, 1, 1] : [1, 1, thin], material: glass)
  }
  func slab(_ name: String, _ glass: [String: Any], bottom: Float = 0.7, floorSize: Float = 4) throws -> ProjectDocument {
    try glb(name, quads: [
      Quad(size: floorSize, translation: [0, 0, 0], rotation: up, material: floor),
      Quad(size: 0.6, translation: [0, 2.2, 0], rotation: down, material: lamp),
      Quad(size: 2 * half, translation: [0, top, 0], rotation: up, material: glass),
      Quad(size: 2 * half, translation: [0, bottom, 0], rotation: down, material: glass),
      side(0, 1, glass, bottom: bottom), side(0, -1, glass, bottom: bottom), side(2, 1, glass, bottom: bottom),
      side(2, -1, glass, bottom: bottom),
      Quad(size: 4, translation: [0, 2, -1.6], rotation: [sin(Float.pi / 4), 0, 0, sin(Float.pi / 4)], material: floor),
    ])
  }
  let glassScene = try slab("glass", glass), clearScene = try slab("clear-glass", clearGlass)
  // Immersed: the floor lies inside a clear block (a pool), so light and camera paths cross into the glass once.
  let immersedScene = try slab("immersed", clearGlass, bottom: -0.3, floorSize: 2.4)
  require(glassScene.scenes[6]?.materialX?.values.contains { $0.medium != nil } == true, "the absorbing slab has an interior medium")
  require(clearScene.scenes[6]?.materialX?.values.contains { $0.medium != nil } == false, "the clear slab has no medium")

  let w = 64, hgt = 48
  // `sun`: a directional sun of a 23° cone besides the lamp, so light paths also start from the environment.
  func view(aperture: Float, sun: Bool = false) -> Uniforms {
    var v = makeUniforms(scene: 6, mode: 1, width: w, height: hgt)
    let eye = SIMD3<Float>(0, 2.0, 2.8), target = SIMD3<Float>(0, 0, 0.2)
    v.cameraPos = SIMD4(eye, 50); v.cameraTarget = SIMD4(target, 8)
    v.currentViewProj = makePerspective(fovyRadians: 50 * .pi / 180, aspect: Float(w) / Float(hgt), near: 0.05, far: 100)
      * makeLookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
    v.prevViewProj = v.currentViewProj
    v.environment = .zero
    v.sunParams.w = 0
    v.lens = SIMD4(aperture, simd_distance(eye, target), 1, sun ? 0.02 : 0)
    if sun { v.sunParams = SIMD4(simd_normalize(SIMD3<Float>(0.3, 1, 0.2)), 2) }
    return v
  }
  func luminance(_ c: SIMD4<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
  let savedPaths = r.causticPaths, savedCaustics = r.caustics, savedTransport = r.lightTransport, savedMedium = r.medium
  r.causticPaths = 1 << 16
  // `reach`: the half-width of the floor's middle region, under the mirror or around the slab (whose own footprint the
  // camera sees only through the glass). With photons the slab's top, through which the camera sees the floor's
  // caustic, is checked as well. `haze`: a scattering scene medium, whose light focused by the glass camera paths gather
  // as volume photons.
  let haze = SceneMedium(density: 0.3, albedo: SIMD3(repeating: 0.9), anisotropy: 0.3, rayleigh: false)
  for (name, document, aperture, reach, mode, medium) in [
    ("mirror", mirrorScene, Float(0), Float(0.6), CausticMode.lightTracing, SceneMedium?.none),
    ("mirror, thin lens", mirrorScene, 0.05, 0.6, .lightTracing, nil), ("mirror, guided", mirrorScene, 0, 0.6, .lightTracingGuided, nil),
    ("absorbing glass", glassScene, 0, 1.8, .lightTracing, nil), ("absorbing glass, photons", glassScene, 0, 1.8, .photons, nil),
    ("clear glass, photons", clearScene, 0, 1.8, .photons, nil),
    ("clear glass, photons, guided", clearScene, 0, 1.8, .photonsGuided, nil), ("immersed floor, photons", immersedScene, 0, 1.8, .photons, nil),
    ("clear glass in haze, photons", clearScene, 0, 1.8, .photons, haze),
    ("clear glass in sun, photons", clearScene, 0, 1.8, .photons, nil),
  ] {
    for transport in [LightTransport.rgb, .spectral] {
      let label = "\(name), \(transport == .rgb ? "RGB" : "spectral")"
      try controller.restore(document)
      r.medium = medium
      r.lightTransport = transport
      r.caustics = .off
      let reference = render(view(aperture: aperture, sun: name.contains("sun")), samples: 8192)
      // The floor: pixels whose primary hit is the floor plane (y = 0), and its middle under the mirror or slab (chosen by
      // position, not by brightness, which would favour pixels where the reference's noise runs high).
      let floorPixels = reference.indices.filter { lastPositions[$0].w > 0 && abs(lastPositions[$0].y) < 1e-3 }
      let middle = floorPixels.filter { abs(lastPositions[$0].x) < reach && abs(lastPositions[$0].z) < reach }
      let throughAll = reference.indices.filter { lastPositions[$0].w > 0 && abs(lastPositions[$0].y - top) < 1e-3
        && abs(lastPositions[$0].x) < 1.1 && abs(lastPositions[$0].z) < 1.1 }
      let wall = reference.indices.filter { lastPositions[$0].w > 0 && abs(lastPositions[$0].z + 1.6) < 1e-3 }
      r.caustics = mode
      require(r.activeCaustics && r.activePhotons == mode.photons && r.activeSamplingMode == 1,
        "\(label): caustic light paths are active with Standard MIS")
      let traced = render(view(aperture: aperture, sun: name.contains("sun")), samples: 512)
      require(r.activeMediaPhotons == (mode.photons && r.hasMedia), "\(label): photons are gathered in media")
      func mean(_ image: [SIMD4<Float>], _ pixels: [Int]) -> Float { pixels.reduce(0) { $0 + luminance(image[$1]) } / Float(pixels.count) }
      // Standard error of a region's mean from the pixels' noise, estimated by differences with the right-hand
      // neighbour (half their mean square), which the smooth floor lighting barely affects.
      func standardError(_ image: [SIMD4<Float>], _ pixels: [Int]) -> Float {
        let inside = Set(pixels)
        let d = pixels.filter { $0 % w + 1 < w && inside.contains($0 + 1) }.map { luminance(image[$0]) - luminance(image[$0 + 1]) }
        return (d.reduce(0) { $0 + $1 * $1 } / Float(max(1, 2 * d.count)) / Float(pixels.count)).squareRoot()
      }
      // Both estimators are unbiased: their means agree within four combined standard errors.
      func agreement(_ pixels: [Int]) -> (ratio: Float, sigmas: Float) {
        let a = mean(traced, pixels), b = mean(reference, pixels)
        let error = (pow(standardError(traced, pixels), 2) + pow(standardError(reference, pixels), 2)).squareRoot()
        return (a / b, abs(a - b) / max(error, 1e-12))
      }
      savePreview([reference, traced], width: w, height: hgt, name: "caustics-\(name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ",", with: ""))-\(transport == .rgb ? "rgb" : "spectral").png")
      // The immersed floor is seen only through the glass; in haze, volume photons light every pixel.
      if !name.hasPrefix("immersed") && medium == nil {
        let whole = agreement(floorPixels), caustic = agreement(middle)
        print("caustics \(label): \(floorPixels.count) floor pixels (\(middle.count) in the middle), light-traced / path-traced mean "
          + "\(whole.ratio) (\(whole.sigmas) sigma), middle \(caustic.ratio) (\(caustic.sigmas) sigma)")
        require(floorPixels.count > 600 && middle.count > 150 && mean(reference, floorPixels) > 0.001 && whole.sigmas < 4 && caustic.sigmas < 4
            && abs(whole.ratio - 1) < 0.1 && abs(caustic.ratio - 1) < 0.15,
          "\(label): caustic light tracing matches path tracing on a caustic-lit floor (\(whole), \(caustic))")
      }
      // In haze, a rare spectral camera path through the slab's glossy top toward the lamp (the same sample in both
      // renders, whose shared sample sequence the reference's 8192 samples dilute 16 times more) is not what the
      // photons are checked for: pixels whose reference exceeds 20 times its median are left out.
      var shared = Set<Int>()
      if medium != nil {
        let median = reference.map(luminance).sorted()[reference.count / 2]
        shared = Set(reference.indices.filter { luminance(reference[$0]) > 20 * median })
        print("caustics \(label): \(shared.count) pixels with a shared camera-path outlier left out")
      }
      let through = throughAll.filter { !shared.contains($0) }
      if medium != nil {
        let all = reference.indices.filter { !shared.contains($0) }, whole = agreement(all)
        let a = mean(traced, all), b = mean(reference, all)
        let error = (pow(standardError(traced, all), 2) + pow(standardError(reference, all), 2)).squareRoot()
        print("caustics \(label): whole image, photons / path-traced mean \(whole.ratio) (\(whole.sigmas) sigma)")
        require(abs(a - b) < 4 * error + 0.03 * b, "\(label): volume photons match path tracing over the image (\(whole))")
      }
      if mode.photons {
        // The floor seen through the slab: photon gathering is consistent, not unbiased, so its radius may add a few
        // per cent on top of the noise.
        let seen = agreement(through)
        let a = mean(traced, through), b = mean(reference, through)
        let error = (pow(standardError(traced, through), 2) + pow(standardError(reference, through), 2)).squareRoot()
        print("caustics \(label): \(through.count) pixels see the floor through the slab, photons / path-traced mean \(seen.ratio) (\(seen.sigmas) sigma)")
        require(through.count > 300 && abs(a - b) < 4 * error + 0.03 * b,
          "\(label): photons gathered through glass match path tracing (\(seen))")
        // The back wall, lit by the floor's caustic after a diffuse bounce: photons gathered at a later receiver.
        let bounced = agreement(wall)
        let c = mean(traced, wall), d = mean(reference, wall)
        let wallError = (pow(standardError(traced, wall), 2) + pow(standardError(reference, wall), 2)).squareRoot()
        print("caustics \(label): \(wall.count) back-wall pixels, photons / path-traced mean \(bounced.ratio) (\(bounced.sigmas) sigma)")
        require(wall.count > 60 && abs(c - d) < 4 * wallError + 0.03 * d,
          "\(label): photons gathered after a diffuse bounce match path tracing (\(bounced))")
      }
    }
  }
  r.causticPaths = savedPaths
  r.caustics = savedCaustics
  r.lightTransport = savedTransport
  r.medium = savedMedium
  print("PASS: caustic light tracing and photons agree with path tracing (metal mirror, thin lens, absorbing glass; photons through absorbing and clear glass, on an immersed floor, in haze and under a sun; guided; RGB and spectral)")
}
try fixCausticChecks()
