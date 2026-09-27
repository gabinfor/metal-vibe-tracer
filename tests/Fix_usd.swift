// Regression checks for the OpenUSD import fixes (fixtures are written by tests/USDChecks.py).
func fixUSDChecks() throws {
  let folder = testOutputDirectory.appendingPathComponent("usd", isDirectory: true)
  func close(_ a: Float, _ b: Float, _ tolerance: Float = 0.001) -> Bool { abs(a - b) <= tolerance * max(1, abs(b)) }

  // Degenerate faces, placeholder meshes and zero-scaled subtrees no longer abort the import; an
  // unauthored focus orbits about the first surface on the view ray instead of a 0.1 mm pivot.
  let robust = try USDImporter.load(folder.appendingPathComponent("robust.usda"), into: ProjectDocument())
  let robustTriangles = try robust.document.graph!.renderTriangles()
  require(robustTriangles.count == 5 + 2 + 2 + 2 + 2, "robust USD stage flattens visible meshes only")
  require(close(robust.document.camera.distance, 5) && close(robust.document.options.focusDistance, 5),
    "unauthored USD focus uses the scene-derived orbit distance (\(robust.document.camera.distance))")
  require(robust.document.environmentData != nil && robust.document.options.environmentIntensity == 2,
    "untextured USD dome becomes a constant environment")
  try controller.restore(robust.document)
  require(testRenderer.materials.environmentData != nil, "constant dome environment decodes on the GPU path")

  let focused = try USDImporter.load(folder.appendingPathComponent("focus.usda"), into: ProjectDocument())
  require(close(focused.document.camera.distance, 5) && close(focused.document.options.focusDistance, 2),
    "authored USD focus stays separate from the orbit pivot")

  // Bright normalized small lights are clamped into the validated emission range.
  let power = try USDImporter.load(folder.appendingPathComponent("power.usda"), into: ProjectDocument())
  let emissions = power.document.scenes[6]!.emissions ?? [:]
  require(emissions.count == 5 && emissions.values.allSatisfy { $0.max() <= 1e8 }, "USD emission clamp")

  // MaterialX image colorSpace metadata reaches the compiled image decode.
  let spaces = try USDImporter.load(folder.appendingPathComponent("colorspace.usda"), into: ProjectDocument())
  let programs = Array((spaces.document.scenes[6]!.materialX ?? [:]).values)
  require(programs.count == 1 && programs[0].images.count == 1 && programs[0].images[0].srgb,
    "USD srgb_texture ND_image decodes as sRGB")
  let glowGraph = spaces.document.graph!
  let glowSlots = glowGraph.nodes.filter { $0.name.hasPrefix("Glow") }.compactMap { node in
    glowGraph.materials.first { $0.id == node.bindings.first }?.slot
  }
  let glowColors = glowSlots.map { spaces.document.scenes[6]!.surfaces[$0].color }
  require(glowSlots.count == 2 && Set(glowSlots).count == 2 && glowColors.contains(SIMD4(1, 0, 0, 1)) && glowColors.contains(SIMD4(0, 0, 1, 1)),
    "uncompilable USD material keeps per-prim displayColor fallbacks")

  // Sphere lights emit outward on every side, not only toward local -Z.
  let coverage = try USDImporter.load(folder.appendingPathComponent("light-coverage.usda"), into: ProjectDocument())
  try controller.restore(coverage.document)
  let kernel = """
  kernel void fix_usd_sphere(constant Uniforms &u [[buffer(0)]], constant SurfaceSettings *settings [[buffer(1)]],constant MaterialResources &images [[buffer(2)]],device float4 *out [[buffer(3)]]) {
   const float3 axes[6]={float3(1,0,0),float3(-1,0,0),float3(0,1,0),float3(0,-1,0),float3(0,0,1),float3(0,0,-1)};
   for(uint i=0;i<6;++i) {HitRecord h;Ray r={float3(1,1,0)+3*axes[i],-axes[i]};bool hit=trace_scene(r,6,h,images,u);out[i]=float4(hit?h.mat.emission:float3(-1),hit?1:0);}
  }
  """
  let library = try gpu.makeLibrary(source: metalSource + kernel, options: shaderCompileOptions())
  let pipeline = try gpu.makeComputePipelineState(function: library.makeFunction(name: "fix_usd_sphere")!)
  var uniforms = makeUniforms(scene: 6, mode: 0, width: 64, height: 48)
  uniforms.environment.w = Float(testRenderer.materials.nodeCount)
  uniforms.lens.z = 1
  let buffer = gpu.makeBuffer(length: 6 * 16, options: .storageModeShared)!
  let command = testRenderer.commandQueue.makeCommandBuffer()!
  let encoder = command.makeComputeCommandEncoder()!
  encoder.setComputePipelineState(pipeline)
  testRenderer.materials.bind(encoder)
  encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
  encoder.setBuffer(buffer, offset: 0, index: 3)
  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
  require(command.status == .completed, "USD sphere GPU command")
  let sides = (0..<6).map { buffer.contents().load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self) }
  print("USD sphere light seen from ±X, ±Y, ±Z: \(sides)")
  require(sides.allSatisfy { $0.w == 1 && $0.x > 0 && close($0.x, sides[0].x) }, "sphere light emits outward from every side")

  // Quitting during an import stops the python3 helper and removes its scratch folder.
  let scratch = { Set((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("vibe-usd-") } }
  let before = scratch()
  let job = USDImportJob()
  controller.usdImportJob = job
  DispatchQueue.global().async { _ = try? USDImporter.load(folder.appendingPathComponent("robust.usda"), into: ProjectDocument(), job: job) }
  let start = Date()
  while !job.isHelperRunning && Date().timeIntervalSince(start) < 10 { Thread.sleep(forTimeInterval: 0.01) }
  require(job.isHelperRunning, "USD helper started for the termination check")
  let delegate = AppDelegate()
  delegate.studio = controller
  delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
  require(job.isCancelled && !job.isHelperRunning, "quit terminates the USD helper")
  require(scratch().subtracting(before).isEmpty, "quit removes the USD scratch folder")
  controller.usdImportJob = nil
  print("PASS: USD robust import, orbit/focus separation, constant dome, emission clamp, image color space, sphere proxy, quit cancellation")
}
try fixUSDChecks()
