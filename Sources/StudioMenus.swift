import Cocoa

// The main menu bar, its actions and their validation.
extension StudioController {
  func installMenus() {
    let main = NSMenu()
    func menu(_ title: String, _ entries: [(String, String, Selector)]) {
      let item = NSMenuItem()
      item.title = title
      let sub = NSMenu(title: title)
      item.submenu = sub
      main.addItem(item)
      for (title, key, selector) in entries {
        let e = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        e.target = self
        sub.addItem(e)
      }
    }
    menu("Metal Vibe Tracer", [("Quit Metal Vibe Tracer", "q", #selector(quit))])
    menu(
      "File",
      [
        ("Open Project…", "o", #selector(openAction)), ("Save Project", "s", #selector(saveAction)),
        ("Save Project As…", "S", #selector(saveAsAction)),
        ("Open Scene File…", "", #selector(openSceneFileAction)),
        ("Browse Scenes…", "O", #selector(browseScenesAction)),
        ("Credits and Licenses…", "", #selector(exampleCreditsAction)),
        ("Show Downloaded Scenes in Finder", "", #selector(revealExampleScenesAction)),
        ("Export…", "e", #selector(exportAction)),
      ])
    if let file = main.items.last?.submenu {
      let item = recent.menuItem(target: self, open: #selector(openRecentAction(_:)), clear: #selector(clearRecentAction))
      openRecentMenu = item.submenu
      file.insertItem(item, at: 1)
    }
    // Standard application and window commands go to NSApp and the key window.
    if let app = main.items.first?.submenu {
      let hide = NSMenuItem(title: "Hide Metal Vibe Tracer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
      let others = NSMenuItem(
        title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
      others.keyEquivalentModifierMask = [.command, .option]
      let all = NSMenuItem(
        title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
      // Inserted in order above Quit.
      for item in [hide, others, all, .separator()] {
        app.insertItem(item, at: app.numberOfItems - 1)
      }
    }
    main.items.last?.submenu?.addItem(.separator())
    main.items.last?.submenu?.addItem(
      NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    menu("Edit", [("Undo", "z", #selector(undoAction)), ("Redo", "Z", #selector(redoAction))])
    // Standard responder-chain editing shortcuts remain available in numeric fields.
    if let edit = main.items.last?.submenu {
      for (title, key, selector) in [
        ("Cut", "x", #selector(NSText.cut(_:))), ("Copy", "c", #selector(NSText.copy(_:))),
        ("Paste", "v", #selector(NSText.paste(_:))),
        ("Select All", "a", #selector(NSText.selectAll(_:))),
      ] { edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
    }
    menu(
      "Render",
      [("Pause / Resume", "p", #selector(pauseAction)), ("Restart", "r", #selector(restartAction)),
       ("Denoise Current Frame with OIDN", "", #selector(oidnAction)),
       ("Clear OIDN Preview", "", #selector(clearOIDNAction))])
    menu("View", [("Show / Hide Inspector", "i", #selector(inspectorAction)), ("Frame Selection", "f", #selector(frameSelectionAction)), ("Frame All Imported Objects", "F", #selector(frameAllAction))])
    if let viewMenu = main.items.last?.submenu {
      viewMenu.addItem(.separator())
      for (index, title) in Self.viewportNames.enumerated() {
        let item = NSMenuItem(title: title, action: #selector(viewportAction(_:)), keyEquivalent: "")
        item.tag = index
        item.target = self
        viewMenu.addItem(item)
      }
    }
    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowItem.submenu = windowMenu
    windowMenu.addItem(
      NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
    windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
    windowMenu.addItem(.separator())
    windowMenu.addItem(
      NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
    main.addItem(windowItem)
    NSApp.mainMenu = main
    NSApp.windowsMenu = windowMenu
  }
  @objc func inspectorAction() { setInspectorVisible(!sidebarVisible) }
  @objc func oidnAction() { guard !isBusy else { return }; startOIDNPreview() }
  @objc func clearOIDNAction() { guard !isBusy else { return }; clearOIDNPreview(); rebuild() }
  @objc func viewportAction(_ sender: NSMenuItem) {
    guard !isBusy else { return }
    checkpoint("Viewport")
    renderer.viewportMode = UInt32(sender.tag)
    changed(reset: false)
    rebuild()
  }
  @objc func saveAsAction() { saveProject(asNew: true) }
  @objc func openSceneFileAction() { openSceneFile() }
  @objc func browseScenesAction() { browseScenes() }
  @objc func openRecentAction(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL { openRecent(url) }
  }
  @objc func clearRecentAction() { recent.clear() }
  @objc func frameSelectionAction() { guard !isBusy else { return }; frameMesh() }
  @objc func frameAllAction() { guard !isBusy else { return }; selectedNode = nil; frameMesh() }
  @objc func quit() { NSApp.terminate(nil) }
  @objc func openAction() { openProject() }
  @objc func saveAction() { saveProject() }
  @objc func exportAction() { showPage(5) }
  @objc func undoAction() {
    guard !isBusy else { return }
    history.undo()
  }
  @objc func redoAction() {
    guard !isBusy else { return }
    history.redo()
  }
  @objc func pauseAction() { pause() }
  @objc func restartAction() { restart() }
}

extension StudioController: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(quit) { return true }
    if item.action == #selector(inspectorAction) { return true }
    if item.action == #selector(exampleCreditsAction) || item.action == #selector(revealExampleScenesAction) {
      return true
    }
    if item.action == #selector(viewportAction(_:)) {
      item.state = Int(renderer.viewportMode) == item.tag ? .on : .off
    }
    if isBusy { return false }
    // With no document loaded only the commands that open one apply.
    if startScreen != nil {
      return [
        #selector(openAction), #selector(openRecentAction(_:)), #selector(clearRecentAction), #selector(openSceneFileAction),
        #selector(browseScenesAction),
      ].contains(item.action)
    }
    if item.action == #selector(undoAction) {
      item.title = history.undoMenuItemTitle
      return history.canUndo
    }
    if item.action == #selector(redoAction) {
      item.title = history.redoMenuItemTitle
      return history.canRedo
    }
    if item.action == #selector(clearOIDNAction) { return renderer.offlineDenoisedPreview != nil }
    if item.action == #selector(oidnAction) { return renderer.offlineDenoisedPreview == nil }
    if item.action == #selector(frameSelectionAction) || item.action == #selector(frameAllAction) {
      return project.graph?.nodes.contains { $0.mesh != nil } == true || !project.triangles.isEmpty
    }
    return true
  }
}
