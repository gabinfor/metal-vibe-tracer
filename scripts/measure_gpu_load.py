"""Measures what the GPU load limit (Render > Limit GPU Load) costs and what it gives another GPU client.

Usage: python3 scripts/measure_gpu_load.py [--seconds S]

A second command queue copies a 2560x1600 texture 60 times a second, a stand-in for another GPU client such as the
window server, while the app renders with the limit off and on (PathTracerRenderer.gpuLoadLimit). For the Cornell Box
(Standard MIS) and the Architectural Pavilion (ReSTIR) it reports:
- viewport: completed samples per second while a simulated 60 Hz display runs what PathTracerRenderer.draw does for
  --seconds on a 1280x800 drawable, at half and at full preview resolution, with the camera still;
- export: the time and samples per second of a raw 1920x1080 export through StudioController.startExport;
each with the copy's commit-to-completion latency (median, 90th percentile, maximum, and how many took longer than a
60 Hz refresh).
A development tool (tests/PERFORMANCE.md, GPU load limit); it compiles the production sources like
scripts/measure_throughput.py and is not part of the suite.
"""
import argparse
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
import harness  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=float, default=6)
arguments = parser.parse_args()

ROOT = harness.ROOT
driver = r'''
final class Latencies: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Double] = []
  func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
  func take() -> [Double] { lock.lock(); defer { values = []; lock.unlock() }; return values }
}
@MainActor func spinUntil(_ condition: () -> Bool, seconds: Double) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
  return condition()
}
let renderer = controller.renderer
let probeQueue = renderer.device.makeCommandQueue()!
let probeDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2560, height: 1600, mipmapped: false)
probeDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
let probeA = renderer.device.makeTexture(descriptor: probeDescriptor)!
let probeB = renderer.device.makeTexture(descriptor: probeDescriptor)!
let latencies = Latencies()
@MainActor func probe() {
  guard let command = probeQueue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return }
  blit.copy(from: probeA, to: probeB)
  blit.endEncoding()
  let start = CACurrentMediaTime()
  command.addCompletedHandler { _ in latencies.add((CACurrentMediaTime() - start) * 1000) }
  command.commit()
}
func summary(_ values: [Double]) -> String {
  let sorted = values.sorted()
  guard !sorted.isEmpty else { return "no probes" }
  func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
  let late = sorted.filter { $0 > 16.7 }.count
  return String(format: "probe ms median %.1f  p90 %.1f  max %.1f  late %d/%d", q(0.5), q(0.9), sorted.last!, late, sorted.count)
}
// Probes at 60 Hz until `done`, then returns the latencies.
@MainActor func probing(seconds: Double, until done: () -> Bool = { false }) -> [Double] {
  _ = latencies.take()
  let start = Date()
  var next = start
  while Date().timeIntervalSince(start) < seconds && !done() {
    probe()
    next = next.addingTimeInterval(1.0 / 60)
    _ = spinUntil({ Date() >= next }, seconds: 1)
  }
  _ = spinUntil({ false }, seconds: 0.3)
  return latencies.take()
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let seconds = Double(CommandLine.arguments[2])!
for (scene, strategy, exportSamples, label) in [(UInt32(1), UInt32(1), 96, "Cornell, Standard MIS"), (UInt32(0), UInt32(0), 32, "Pavilion, ReSTIR")] {
  var p = ProjectDocument()
  p.scene = scene
  testRenderer.sceneIndex = scene
  p.camera = CameraState(testRenderer)
  p.strategy = strategy
  p.options.maxSamples = 0; p.options.timeLimit = 0
  p.options.outputWidth = 1920; p.options.outputHeight = 1080
  p.options.exportSamples = UInt32(exportSamples)
  try controller.restore(p)
  print("\n== \(label)")
  for limited in [false, true] {
    controller.limitsGPULoad = limited
    // Viewport: what PathTracerRenderer.draw does at 60 Hz on a 1280x800 drawable, camera still.
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1280, height: 800, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let out = renderer.device.makeTexture(descriptor: descriptor)!
    for scale in [Float(0.5), Float(1)] {
      renderer.options.previewScale = scale
      renderer.paused = false
      renderer.resetAccumulation()
      func tick() {
        guard renderer.submissionDelay() == 0 else { return }
        renderer.renderFrame(output: out, samples: renderer.samplesPerFrame(targetMilliseconds: 800.0 / 60, limit: Int.max))
      }
      for _ in 0..<20 { tick(); _ = spinUntil({ false }, seconds: 1.0 / 60) }
      _ = spinUntil({ renderer.completedSamples == renderer.frameIndex }, seconds: 20)
      let first = renderer.completedSamples, start = Date()
      _ = latencies.take()
      var next = start
      while Date().timeIntervalSince(start) < seconds {
        tick(); probe()
        next = next.addingTimeInterval(1.0 / 60)
        _ = spinUntil({ Date() >= next }, seconds: 1)
      }
      let elapsed = Date().timeIntervalSince(start), done = Double(renderer.completedSamples &- first)
      _ = spinUntil({ renderer.completedSamples == renderer.frameIndex }, seconds: 20)
      print(String(format: "limit %@  viewport %dx%d: %.1f samples/s, %.0f ms GPU per frame   %@", limited ? "on " : "off",
                   Int(1280 * scale), Int(800 * scale), done / elapsed, renderer.gpuMilliseconds, summary(latencies.take())))
    }
    renderer.paused = true
    // Export: raw 1920x1080 through StudioController.startExport.
    controller.exportDenoise = false
    controller.exportRaw = true
    let url = folder.appendingPathComponent("pacing.exr")
    try? FileManager.default.removeItem(at: url)
    let start = Date()
    controller.startExport(url: url, hdr: true)
    let values = probing(seconds: 600) { controller.exportRenderer == nil }
    let exportSeconds = Date().timeIntervalSince(start) - 0.3
    print(String(format: "limit %@  export 1920x1080, %d samples: %.1f s, %.2f samples/s   %@", limited ? "on " : "off", exportSamples,
                 exportSeconds, Double(exportSamples) / exportSeconds, summary(values)))
  }
}
controller.saveTimer?.invalidate()
controller.autosaveQueue.sync {}
exit(0)
'''

for script in ('prepare_shaders.py', 'generate_spectral_tables.py'):
    subprocess.run([sys.executable, str(ROOT / 'scripts' / script)], check=True, stdout=subprocess.DEVNULL)
subprocess.run([sys.executable, str(ROOT / 'scripts/prepare_oidn.py'), '--arch', platform.machine()], check=True,
               stdout=subprocess.DEVNULL)
source = (harness.production_source() + '\nsetvbuf(stdout, nil, _IOLBF, 0)\n' + harness.gpu_helpers() + '\n'
          + harness.studio_controller() + driver)
with tempfile.TemporaryDirectory(prefix='vibe-tracer-gpu-load-') as directory:
    binary = harness.compile_swift(source, Path(directory), 'GPULoad')
    environment = {**os.environ, 'VIBE_TRACER_REPOSITORY': str(ROOT), harness.OUTPUT_VARIABLE: str(Path(directory) / 'output')}
    sys.exit(subprocess.run([str(binary), directory, str(arguments.seconds)], cwd=ROOT, env=environment).returncode)
