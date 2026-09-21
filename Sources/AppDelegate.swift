import Cocoa
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
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
      guard let device = MTLCreateSystemDefaultDevice() else {
        throw MaterialLibrary.error("Metal is unavailable.")
      }
      let renderer = try PathTracerRenderer(device: device)
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "Metal Vibe Tracer"
      window.contentMinSize = NSSize(width: 700, height: 440)
      window.center()
      studio = StudioController(renderer: renderer, window: window)
      window.contentView = studio.view
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      studio.restoreAutosave()
    } catch {
      NSAlert(error: error).runModal()
      NSApp.terminate(nil)
    }
  }
}
