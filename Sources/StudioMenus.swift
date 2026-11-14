import Cocoa

// The menu bar, its actions and their validation. AppDelegate installs the same menu bar at launch, with itself as the
// target: commands it does not implement stay disabled until the studio takes over, so the bar keeps its shape.
extension StudioController {
  // The menu bar: App, File, Edit, Render, View, Window and Help. Commands go to `target`; the standard application,
  // window and text commands go to NSApp and the responder chain. Returns the bar, its Window and Help menus and the
  // File › Open Recent submenu (which the owner refills when the recent projects change).
  static func makeMenuBar(target: AnyObject, recent: RecentProjects)
    -> (bar: NSMenu, window: NSMenu, help: NSMenu, openRecent: NSMenu)
  {
    let bar = NSMenu()
    func menu(_ title: String) -> NSMenu {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let sub = NSMenu(title: title)
      item.submenu = sub
      bar.addItem(item)
      return sub
    }
    // An item sent to `target` (or, with `standard`, to NSApp / the responder chain).
    @discardableResult func add(
      _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
      modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0, standard: Bool = false
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.tag = tag
      if !standard { item.target = target }
      menu.addItem(item)
      return item
    }
    let app = menu("Metal Vibe Tracer")
    add(app, "About Metal Vibe Tracer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), standard: true)
    app.addItem(.separator())
    add(app, "Hide Metal Vibe Tracer", #selector(NSApplication.hide(_:)), "h", standard: true)
    add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option],
      standard: true)
    add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), standard: true)
    app.addItem(.separator())
    add(app, "Quit Metal Vibe Tracer", #selector(NSApplication.terminate(_:)), "q", standard: true)

    let file = menu("File")
    add(file, "New Project", #selector(newProjectAction), "n")
    add(file, "Open Project…", #selector(openAction), "o")
    let recentItem = recent.menuItem(target: target, open: #selector(openRecentAction(_:)), clear: #selector(clearRecentAction))
    file.addItem(recentItem)
    add(file, "Open Scene File…", #selector(openSceneFileAction))
    add(file, "Browse Scenes…", #selector(browseScenesAction), "O")
    file.addItem(.separator())
    add(file, "Save", #selector(saveAction), "s")
    add(file, "Save As…", #selector(saveAsAction), "S")
    file.addItem(.separator())
    add(file, "Add Model…", #selector(addModelAction))
    add(file, "Import MaterialX…", #selector(importMaterialXAction))
    add(file, "Load Environment Image…", #selector(loadEnvironmentAction))
    file.addItem(.separator())
    add(file, "Export…", #selector(exportAction), "e")
    file.addItem(.separator())
    add(file, "Show Downloaded Scenes in Finder", #selector(revealExampleScenesAction))
    file.addItem(.separator())
    add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", standard: true)

    let edit = menu("Edit")
    add(edit, "Undo", #selector(undoAction), "z")
    add(edit, "Redo", #selector(redoAction), "Z")
    edit.addItem(.separator())
    // Standard responder-chain editing shortcuts for the numeric fields.
    add(edit, "Cut", #selector(NSText.cut(_:)), "x", standard: true)
    add(edit, "Copy", #selector(NSText.copy(_:)), "c", standard: true)
    add(edit, "Paste", #selector(NSText.paste(_:)), "v", standard: true)
    add(edit, "Select All", #selector(NSText.selectAll(_:)), "a", standard: true)

    let render = menu("Render")
    add(render, "Pause", #selector(pauseAction), "p")
    add(render, "Restart", #selector(restartAction), "r")
    render.addItem(.separator())
    add(render, "Denoise Current Frame", #selector(oidnAction))
    add(render, "Clear Denoised Preview", #selector(clearOIDNAction))
    render.addItem(.separator())
    add(render, "Limit GPU Load", #selector(gpuLoadLimitAction)).toolTip =
      "Leaves a tenth of the GPU's time free while rendering and exporting, so the rest of the system stays responsive. Turn it off for the fastest render."

    let view = menu("View")
    add(view, "Hide Inspector", #selector(inspectorAction), "i")
    view.addItem(.separator())
    for (index, title) in pageTitles.enumerated() {
      add(view, title, #selector(showTabAction(_:)), "\(index + 1)", tag: index)
    }
    view.addItem(.separator())
    add(view, "Frame Selection", #selector(frameSelectionAction), "f")
    add(view, "Frame All", #selector(frameAllAction), "F")
    view.addItem(.separator())
    for (index, title) in viewportNames.enumerated() {
      add(view, title, #selector(viewportAction(_:)), tag: index)
    }

    let window = menu("Window")
    add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", standard: true)
    add(window, "Zoom", #selector(NSWindow.performZoom(_:)), standard: true)
    window.addItem(.separator())
    add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), standard: true)

    let help = menu("Help")
    add(help, "User Guide", #selector(userGuideAction))
    add(help, "Credits and Licenses…", #selector(exampleCreditsAction))
    return (bar, window, help, recentItem.submenu!)
  }
  func installMenus() {
    let menus = Self.makeMenuBar(target: self, recent: recent)
    openRecentMenu = menus.openRecent
    NSApp.mainMenu = menus.bar
    NSApp.windowsMenu = menus.window
    NSApp.helpMenu = menus.help
  }
  @objc func newProjectAction() { confirmDiscardingChanges { [weak self] in self?.performStartAction(.newProject) } }
  @objc func inspectorAction() { setInspectorVisible(!sidebarVisible) }
  @objc func showTabAction(_ sender: NSMenuItem) {
    guard !isBusy, startScreen == nil else { return }
    showPage(sender.tag)
  }
  @objc func oidnAction() { guard !isBusy else { return }; startOIDNPreview() }
  @objc func clearOIDNAction() { guard !isBusy else { return }; clearOIDNPreview(); rebuild() }
  @objc func viewportAction(_ sender: NSMenuItem) { setViewportMode(sender.tag) }
  @objc func saveAsAction() { saveProject(asNew: true) }
  @objc func openSceneFileAction() { openSceneFile() }
  @objc func browseScenesAction() { browseScenes() }
  @objc func openRecentAction(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL { openRecent(url) }
  }
  @objc func clearRecentAction() { recent.clear() }
  @objc func addModelAction() { guard !isBusy else { return }; addModel() }
  @objc func importMaterialXAction() { guard !isBusy else { return }; importMaterialX() }
  @objc func loadEnvironmentAction() { guard !isBusy else { return }; loadEnvironment() }
  @objc func frameSelectionAction() { guard !isBusy else { return }; frameMesh() }
  @objc func frameAllAction() { guard !isBusy else { return }; selectedNode = nil; frameMesh() }
  @objc func openAction() { openProject() }
  @objc func saveAction() { saveProject() }
  @objc func exportAction() { showPage(5) }
  @objc func userGuideAction() { NSWorkspace.shared.open(MainMenuView.userGuideURL) }
  @objc func undoAction() {
    guard !isBusy else { return }
    history.undo()
  }
  @objc func redoAction() {
    guard !isBusy else { return }
    history.redo()
  }
  @objc func pauseAction() { pause() }
  @objc func gpuLoadLimitAction() { limitsGPULoad.toggle() }
  @objc func restartAction() { restart() }
}

extension StudioController: NSMenuItemValidation {
  // Titles and checkmarks follow the state; commands that need a document are disabled on the main menu, and every
  // command but the inspector toggle, Limit GPU Load, Help and Show Downloaded Scenes in Finder is disabled while busy.
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(viewportAction(_:)): item.state = Int(renderer.viewportMode) == item.tag ? .on : .off
    case #selector(showTabAction(_:)): item.state = startScreen == nil && page == item.tag ? .on : .off
    case #selector(pauseAction): item.title = renderer.paused ? "Resume" : "Pause"
    case #selector(inspectorAction):
      item.title = sidebarVisible ? "Hide Inspector" : "Show Inspector"
      return startScreen == nil
    case #selector(gpuLoadLimitAction):
      item.state = limitsGPULoad ? .on : .off
      return true
    case #selector(exampleCreditsAction), #selector(revealExampleScenesAction), #selector(userGuideAction):
      return true
    default: break
    }
    if isBusy { return false }
    // With no document loaded only the commands that open one apply.
    if startScreen != nil {
      return [
        #selector(newProjectAction), #selector(openAction), #selector(openRecentAction(_:)), #selector(clearRecentAction),
        #selector(openSceneFileAction), #selector(browseScenesAction),
      ].contains(item.action)
    }
    switch item.action {
    case #selector(undoAction):
      item.title = history.undoMenuItemTitle
      return history.canUndo
    case #selector(redoAction):
      item.title = history.redoMenuItemTitle
      return history.canRedo
    case #selector(clearOIDNAction): return renderer.offlineDenoisedPreview != nil
    case #selector(oidnAction): return renderer.offlineDenoisedPreview == nil
    case #selector(frameSelectionAction), #selector(frameAllAction):
      return project.graph?.nodes.contains { $0.mesh != nil } == true || !project.triangles.isEmpty
    default: return true
    }
  }
}
