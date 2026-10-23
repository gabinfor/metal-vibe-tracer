// Measures how long the app takes from process launch to an on-screen window and, for builds that
// report it, to ready GPU shaders (tests/PERFORMANCE.md, Launch time).
// Not part of the app or the test suite.
//
//   xcrun swiftc -O -swift-version 6 scripts/measure_launch.swift -o build/measure_launch
//   build/measure_launch build/MetalVibeTracer.app [--runs N] [--cold] [--timeout seconds]
//
// The window is found with CGWindowListCopyWindowInfo (owner PID and layer only, which need no
// screen-recording permission). Builds with launch tracing print `VIBE_LAUNCH <event> <unix time>`
// to standard error when VIBE_LAUNCH_TRACE=1; events: window (shown) and shaders-ready.
// --cold runs a copy of the bundle under a new bundle identifier, so the Metal compiler service finds
// no cached library or pipelines (a "fresh build"); the copy and its caches are deleted afterwards.
// Each run is terminated with SIGTERM after its last event, so the app never writes an autosave.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
  print("usage: measure_launch <MetalVibeTracer.app> [--runs N] [--cold] [--timeout seconds]")
  exit(2)
}
func value(_ flag: String) -> String? {
  arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}
let app = URL(fileURLWithPath: arguments[1])
let runs = Int(value("--runs") ?? "") ?? 3
let timeout = Double(value("--timeout") ?? "") ?? 600
let cold = arguments.contains("--cold")

func now() -> Double { Date().timeIntervalSince1970 }

func windowVisible(_ pid: pid_t) -> Bool {
  guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] else { return false }
  return list.contains { entry in
    (entry[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) == pid } == true
      && (entry[kCGWindowLayer as String] as? Int) == 0
  }
}

// A bundle copy under a bundle identifier no Metal cache has seen. The compiler service keeps its
// library and pipeline caches per bundle identifier ($(getconf DARWIN_USER_CACHE_DIR)/<identifier>).
func coldCopy(_ run: Int) throws -> (bundle: URL, identifier: String) {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("measure-launch-\(getpid())-\(run)")
  try? FileManager.default.removeItem(at: folder)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let copy = folder.appendingPathComponent(app.lastPathComponent)
  try FileManager.default.copyItem(at: app, to: copy)
  let plist = copy.appendingPathComponent("Contents/Info.plist")
  let identifier = "local.vibetracer.measure-launch-\(UInt32.random(in: 1...UInt32.max))"
  var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
  info["CFBundleIdentifier"] = identifier
  try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
  return (copy, identifier)
}
func removeCaches(_ identifier: String) {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return }
  let caches = URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent(identifier)
  try? FileManager.default.removeItem(at: caches)
  let preferences = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences/\(identifier).plist")
  try? FileManager.default.removeItem(at: preferences)
}

final class Events: @unchecked Sendable {
  let lock = NSLock()
  var times: [String: Double] = [:]
  var buffer = Data()
  // Called on the pipe's reader queue with each chunk of standard error.
  func append(_ chunk: Data) {
    lock.lock(); buffer.append(chunk); var lines: [String] = []
    while let newline = buffer.firstIndex(of: 10) {
      lines.append(String(decoding: buffer[..<newline], as: UTF8.self))
      buffer.removeSubrange(...newline)
    }
    lock.unlock()
    for line in lines { record(Substring(line)) }
  }
  func record(_ line: Substring) {
    let parts = line.split(separator: " ")
    guard parts.count == 3, parts[0] == "VIBE_LAUNCH", let t = Double(parts[2]) else { return }
    lock.lock(); times[String(parts[1])] = t; lock.unlock()
  }
  func get(_ name: String) -> Double? { lock.lock(); defer { lock.unlock() }; return times[name] }
}

print("app: \(app.path)\(cold ? " (cold shader caches)" : "")")
print("run  window(s)  shaders-ready(s)")
for run in 1...runs {
  let copy = cold ? try coldCopy(run) : nil
  let bundle = copy?.bundle ?? app
  defer {
    if let copy {
      try? FileManager.default.removeItem(at: copy.bundle.deletingLastPathComponent())
      removeCaches(copy.identifier)
    }
  }
  let process = Process()
  process.executableURL = bundle.appendingPathComponent("Contents/MacOS/MetalVibeTracer")
  process.environment = ProcessInfo.processInfo.environment.merging(["VIBE_LAUNCH_TRACE": "1"]) { $1 }
  let pipe = Pipe()
  process.standardError = pipe
  process.standardOutput = FileHandle.nullDevice
  let events = Events()
  pipe.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    if !chunk.isEmpty { events.append(chunk) }
  }
  let start = now()
  try process.run()
  var window: Double?
  // Builds without tracing report only the window; traced builds also wait for ready shaders.
  while now() - start < timeout, process.isRunning {
    if window == nil, windowVisible(process.processIdentifier) { window = now() - start }
    if window != nil, events.get("window") == nil, now() - start > window! + 5 { break }
    if window != nil, events.get("shaders-ready") != nil { break }
    usleep(2000)
  }
  process.terminate()
  process.waitUntilExit()
  pipe.fileHandleForReading.readabilityHandler = nil
  func format(_ t: Double?) -> String { t.map { String(format: "%.3f", $0) } ?? "-" }
  print(String(format: "%3d", run), format(window).padding(toLength: 10, withPad: " ", startingAt: 0),
        format(events.get("shaders-ready").map { $0 - start }))
}
