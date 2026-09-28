// A USD stage lit only by graph-emissive materials (OpenPBR emission or PreviewSurface
// emissiveColor) is authored lighting: it imports without the neutral inspection sky and
// renders its floor lit by the emitter alone. A stage with no lights and no emission (an
// explicit zero emission_luminance included) still gets the neutral sky.
@MainActor func fixUSDLightingChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("usd-lighting", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let neutralSky = "No supported authored lighting: neutral procedural sky used for inspection."
  // A 4 x 4 m floor and, 1 m above it facing down, a 1 x 1 m quad bound to `material`.
  func stage(_ name: String, material: String) throws -> URL {
    let url = folder.appendingPathComponent(name + ".usda")
    try """
      #usda 1.0
      (
          defaultPrim = "World"
          metersPerUnit = 1
          upAxis = "Y"
      )
      def Xform "World"
      {
          def Mesh "Floor"
          {
              int[] faceVertexCounts = [4]
              int[] faceVertexIndices = [0, 3, 2, 1]
              point3f[] points = [(-2, 0, -2), (2, 0, -2), (2, 0, 2), (-2, 0, 2)]
              color3f[] primvars:displayColor = [(0.5, 0.5, 0.5)]
              uniform token subdivisionScheme = "none"
          }
          def Mesh "Panel" (prepend apiSchemas = ["MaterialBindingAPI"])
          {
              int[] faceVertexCounts = [4]
              int[] faceVertexIndices = [0, 1, 2, 3]
              point3f[] points = [(-0.5, 1, -0.5), (0.5, 1, -0.5), (0.5, 1, 0.5), (-0.5, 1, 0.5)]
              uniform token subdivisionScheme = "none"
              rel material:binding = </World/Look>
          }
          def Material "Look"
          {
      \(material)
          }
      }
      """.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
  func openPBR(_ luminance: Float) -> String {
    """
            token outputs:mtlx:surface.connect = </World/Look/Surface.outputs:out>
            def Shader "Surface"
            {
                uniform token info:id = "ND_open_pbr_surface_surfaceshader"
                color3f inputs:base_color = (0, 0, 0)
                float inputs:emission_luminance = \(luminance)
                color3f inputs:emission_color = (1, 0.9, 0.8)
                token outputs:out
            }
    """
  }
  func previewSurface(_ emissive: String) -> String {
    """
            token outputs:surface.connect = </World/Look/Surface.outputs:surface>
            def Shader "Surface"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (0.2, 0.2, 0.2)
                color3f inputs:emissiveColor = \(emissive)
                token outputs:surface
            }
    """
  }
  func emitterWeight(_ result: USDImportResult) -> Double {
    let slot = result.document.graph!.materials.first(where: { $0.name == "Look" })?.slot ?? -1
    return result.document.scenes[6]!.materialX?[slot]?.emissionWeight ?? -1
  }

  // Emissive-only stages: no neutral sky, sun and environment stay off, and the report says
  // the emissive materials light the scene.
  let lamp = try USDImporter.load(try stage("emissive-openpbr", material: openPBR(3)), into: ProjectDocument())
  let preview = try USDImporter.load(try stage("emissive-preview", material: previewSurface("(2, 2, 2)")), into: ProjectDocument())
  for (label, result) in [("OpenPBR emission", lamp), ("PreviewSurface emissiveColor", preview)] {
    let o = result.document.options
    require(emitterWeight(result) > 0 && result.document.scenes[6]!.emissions?.isEmpty != false,
      "\(label): the stage's only light is a graph-emissive material (\(result.report))")
    require(!result.report.contains(neutralSky) && o.environmentIntensity == 0 && o.sunIntensity == 0
        && result.document.environmentData == nil,
      "\(label): an emissive-only stage imports without the neutral inspection sky (\(result.report))")
    require(result.report.contains { $0.contains("emissive materials light the scene") },
      "\(label): the import report says emissive materials light the scene (\(result.report))")
  }

  // The imported lighting renders the floor lit by the emitter alone; misses see no sky.
  try controller.restore(lamp.document)
  var view = makeUniforms(scene: 6, mode: 1, width: 64, height: 48)
  let eye = SIMD3<Float>(0, 0.6, -2.2), target = SIMD3<Float>(0, 0.3, 0.3)
  view.cameraPos = SIMD4(eye, 60); view.cameraTarget = SIMD4(target, 16)
  view.currentViewProj = makePerspective(fovyRadians: 60 * .pi / 180, aspect: 64.0 / 48, near: 0.05, far: 100)
    * makeLookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
  view.prevViewProj = view.currentViewProj
  view.environment = SIMD4(lamp.document.options.environmentIntensity, 0, 0, Float(testRenderer.materials.nodeCount))
  view.sunParams.w = lamp.document.options.sunIntensity
  view.lens.z = 1
  let pixels = render(view, samples: 64)
  let floor = pixels.indices.filter { lastPositions[$0].w > 0 && lastNormals[$0].y > 0.99 && abs(lastPositions[$0].y) < 1e-3 }
  // Background pixels at least 3 pixels from any hit (edge pixels average in jittered hits).
  let missed = pixels.indices.map { lastPositions[$0].w <= 0 }
  let misses = pixels.indices.filter { i in
    let x = i % 64, y = i / 64
    return (-2...2).allSatisfy { dy in (-2...2).allSatisfy { dx in
      missed[min(47, max(0, y + dy)) * 64 + min(63, max(0, x + dx))]
    }}
  }
  let floorMean = floor.reduce(Float(0)) { $0 + pixels[$1].x + pixels[$1].y + pixels[$1].z } / Float(max(1, floor.count))
  let missMax = misses.map { pixels[$0].x + pixels[$0].y + pixels[$0].z }.max() ?? 0
  print("Emissive-only USD stage: floor pixels \(floor.count), mean \(floorMean); sky pixels \(misses.count), max \(missMax)")
  require(floor.count > 300 && misses.count > 20, "the view sees the floor and the background (\(floor.count), \(misses.count))")
  require(floorMean > 0.05 && missMax < 1e-6, "the emissive material alone lights the floor; there is no sky")
  savePreview([pixels], width: 64, height: 48, name: "usd-emissive-only.png")

  // No lights and no emission (none authored, or explicitly zero): the neutral sky is kept.
  let unlit = [
    ("no emission", previewSurface("(0, 0, 0)")), ("zero emission_luminance", openPBR(0)),
  ]
  for (label, material) in unlit {
    let result = try USDImporter.load(try stage("unlit-" + label.replacingOccurrences(of: " ", with: "-"), material: material), into: ProjectDocument())
    require(emitterWeight(result) <= 0 && result.report.contains(neutralSky)
        && result.document.options.environmentIntensity == 1 && result.document.options.sunIntensity == 0
        && !result.report.contains { $0.contains("emissive materials light the scene") },
      "\(label): a stage with no lights and no emission keeps the neutral inspection sky (\(result.report))")
  }
  print("PASS: fix-usd-lighting emissive-only stages import without the neutral sky and light their floor; unlit stages keep it")
}
try fixUSDLightingChecks()
