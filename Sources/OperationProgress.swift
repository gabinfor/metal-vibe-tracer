import Foundation
import Synchronization

// Progress of one long operation (shader compilation, an open, import, save, export or OIDN
// pass). Workers on any thread set the current phase and, where they can count their work, a
// fraction; the main thread polls `snapshot` for the progress bar (StudioController's activity
// strip, the start screen), so frequent updates never flood the main queue.
final class OperationProgress: Sendable {
  struct Snapshot: Equatable, Sendable {
    // Short status text ("Decoding textures").
    var phase: String
    // 0...1 when the work is counted; nil shows an indeterminate bar.
    var fraction: Double?
    // "12 of 40" style detail for counted phases.
    var detail: String?
    var text: String { detail.map { "\(phase) (\($0))" } ?? phase }
  }
  private let state: Mutex<Snapshot>
  private let cancelled = Mutex(false)
  init(_ phase: String) { state = Mutex(Snapshot(phase: phase)) }

  var snapshot: Snapshot { state.withLock { $0 } }
  var isCancelled: Bool { cancelled.withLock { $0 } }
  func cancel() { cancelled.withLock { $0 = true } }

  // An uncounted phase.
  func begin(_ phase: String) {
    state.withLock { $0 = Snapshot(phase: phase) }
  }
  func update(_ phase: String, fraction: Double) {
    let clamped = min(1, max(0, fraction))
    state.withLock { $0 = Snapshot(phase: phase, fraction: clamped) }
  }
  // A counted phase: `completed` of `total` items done.
  func update(_ phase: String, completed: Int, of total: Int) {
    guard total > 0 else { return begin(phase) }
    let done = min(completed, total)
    state.withLock {
      $0 = Snapshot(phase: phase, fraction: Double(done) / Double(total), detail: "\(done) of \(total)")
    }
  }
  // Counts one more item of the current counted phase (concurrent workers report through this).
  func advance(_ phase: String, total: Int) {
    state.withLock { s in
      let done = s.phase == phase ? min(total, Int(((s.fraction ?? 0) * Double(total)).rounded()) + 1) : 1
      s = Snapshot(phase: phase, fraction: Double(done) / Double(max(1, total)), detail: "\(done) of \(total)")
    }
  }
}
