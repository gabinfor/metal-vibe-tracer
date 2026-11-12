import Cocoa

// Where the recent projects are kept, newest first: the system's recent-documents list in the app
// (SystemRecentProjects), an in-memory list in the test suite.
@MainActor protocol RecentProjectsStore: AnyObject {
  var urls: [URL] { get }
  // Puts `url` first, once.
  func note(_ url: URL)
  func clear()
}

// The app's recent-documents list (NSDocumentController), which macOS keeps across launches.
final class SystemRecentProjects: RecentProjectsStore {
  var urls: [URL] { NSDocumentController.shared.recentDocumentURLs }
  func note(_ url: URL) { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
  func clear() { NSDocumentController.shared.clearRecentDocuments(nil) }
}

// The recent projects of the main menu and File › Open Recent: project files opened from a file, saved or saved as
// (not imported scene files, catalog scenes or the autosave). `onChange` is called after every change so that the
// owner (AppDelegate at launch, then StudioController) refreshes both lists.
@MainActor final class RecentProjects {
  // Rows of the main menu and items of File › Open Recent.
  static let maximumShown = 8
  let store: RecentProjectsStore
  var onChange: (() -> Void)?

  init(store: RecentProjectsStore = SystemRecentProjects()) { self.store = store }

  // Newest first.
  var urls: [URL] { store.urls }
  var shown: [URL] { Array(urls.prefix(Self.maximumShown)) }
  func note(_ url: URL) {
    store.note(url)
    onChange?()
  }
  // The store can only add and clear, so the others are added back, oldest first.
  func remove(_ url: URL) {
    let others = urls.filter { $0 != url }
    store.clear()
    for other in others.reversed() { store.note(other) }
    onChange?()
  }
  func clear() {
    store.clear()
    onChange?()
  }
  // Opens `url` with `open`, or, when the file is gone, removes it from the list and reports
  // "<name> is no longer at <folder>." with `report`.
  func open(_ url: URL, with open: (URL) -> Void, report: (String) -> Void) {
    guard FileManager.default.fileExists(atPath: url.path) else {
      remove(url)
      report("\(url.lastPathComponent) is no longer at \(Self.folder(url)).")
      return
    }
    open(url)
  }
  // The file's folder with the home folder abbreviated to ~.
  static func folder(_ url: URL) -> String {
    (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
  }
  // File › Open Recent: the shown projects by file name (each item's representedObject is its URL, sent to `open`),
  // a separator and Clear Menu (disabled when the list is empty).
  func menuItem(target: AnyObject, open: Selector, clear: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
    item.submenu = NSMenu(title: "Open Recent")
    fill(item.submenu!, target: target, open: open, clear: clear)
    return item
  }
  func fill(_ menu: NSMenu, target: AnyObject, open: Selector, clear: Selector) {
    menu.removeAllItems()
    for url in shown {
      let item = NSMenuItem(title: url.lastPathComponent, action: open, keyEquivalent: "")
      item.target = target
      item.representedObject = url
      item.toolTip = Self.folder(url)
      menu.addItem(item)
    }
    if !shown.isEmpty { menu.addItem(.separator()) }
    let clearItem = NSMenuItem(title: "Clear Menu", action: shown.isEmpty ? nil : clear, keyEquivalent: "")
    clearItem.target = target
    menu.addItem(clearItem)
  }
}

// The main window's content while no document is loaded (StudioController.startScreen, and AppDelegate's launch
// state before the studio exists): the app's name and version, a Start column (New Project, Open Project…, Open Scene
// File…, Browse Scenes…, Restore Last Session while an autosave exists), the recent projects, the launch progress and
// the action queued until the shaders are ready, and User Guide and Credits and licenses…. It scrolls when the window
// is too small for it.
final class MainMenuView: NSView {
  static let userGuideURL = URL(string: "https://github.com/gabinfor/metal-vibe-tracer/blob/main/docs/USER_GUIDE.md")!
  // New Project, Open Project…, Open Scene File… and Restore Last Session.
  var onAction: ((StartAction) -> Void)?
  var onBrowse: (() -> Void)?
  var onOpenRecent: ((URL) -> Void)?
  var onClearRecent: (() -> Void)?
  var onCancelPending: (() -> Void)?
  // Nil disables Credits and licenses…, as before the studio exists.
  var onCredits: (() -> Void)? { didSet { updateEnabled() } }
  // Opens User Guide's page; tests replace it.
  var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

  private var actionsEnabled = true
  private var startButtons: [NSButton] = []
  private let restoreRow = NSStackView()
  private let restoreInfo = NSTextField(labelWithString: "")
  private let recentRows = NSStackView()
  private var recentButtons: [NSButton] = []
  private let recentEmpty = NSTextField(labelWithString: "No recent projects")
  private let clearButton = MainMenuView.link("Clear", "menu-recent-clear")
  private let progressRow = NSStackView()
  private let progressBar = NSProgressIndicator()
  private let progressLabel = NSTextField(labelWithString: "")
  private let hint = NSTextField(wrappingLabelWithString: "")
  private let pendingRow = NSStackView()
  private let pendingLabel = NSTextField(wrappingLabelWithString: "")
  private let message = NSTextField(wrappingLabelWithString: "")
  private let guideButton = MainMenuView.link("User Guide", "menu-guide")
  private let creditsButton = MainMenuView.link("Credits and licenses…", "menu-credits")

  // The app's version from the bundle; nil (no Version line) when there is no bundle, as in the test suite.
  static var bundleVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

  init(version: String? = MainMenuView.bundleVersion) {
    super.init(frame: .zero)
    wantsLayer = true
    identifier = NSUserInterfaceItemIdentifier("main-menu")

    let title = NSTextField(labelWithString: "Metal Vibe Tracer")
    title.font = .systemFont(ofSize: 26, weight: .semibold)
    let header = NSStackView(views: [title])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 2
    if let version {
      let line = NSTextField(labelWithString: "Version \(version)")
      line.textColor = .secondaryLabelColor
      header.addArrangedSubview(line)
    }

    let columns = NSStackView(views: [buildStart(), buildRecent()])
    columns.orientation = .horizontal
    columns.alignment = .top
    columns.spacing = 48
    buildLaunchRows()
    message.font = .systemFont(ofSize: 12)
    message.identifier = NSUserInterfaceItemIdentifier("menu-message")
    message.isHidden = true
    guideButton.actionBlock = { [weak self] in self?.openURL(Self.userGuideURL) }
    creditsButton.actionBlock = { [weak self] in self?.onCredits?() }
    let footer = NSStackView(views: [guideButton, creditsButton])
    footer.orientation = .horizontal
    footer.spacing = 16

    let content = NSStackView(views: [header, columns, progressRow, hint, pendingRow, message, footer])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 14
    content.setCustomSpacing(28, after: header)
    content.setCustomSpacing(24, after: columns)
    content.detachesHiddenViews = true
    content.translatesAutoresizingMaskIntoConstraints = false

    let document = MenuDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(content)
    let scroll = NSScrollView()
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)
    let fill = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
    fill.priority = .defaultLow
    let margin = content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24)
    margin.priority = .defaultHigh
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor), fill,
      // Centred in the window when it fits, else from the top with a margin.
      content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
      content.centerYAnchor.constraint(equalTo: document.centerYAnchor),
      content.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor, constant: 32), margin,
      hint.widthAnchor.constraint(lessThanOrEqualTo: columns.widthAnchor),
      pendingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
      message.widthAnchor.constraint(lessThanOrEqualTo: columns.widthAnchor),
    ])
    setRecent([])
    updateEnabled()
  }
  required init?(coder: NSCoder) { fatalError() }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor }

  // MARK: Building

  private func buildStart() -> NSView {
    let column = NSStackView(views: [Self.heading("Start")])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8
    column.detachesHiddenViews = true
    let entries: [(String, String, () -> Void)] = [
      ("New Project", "menu-new", { [weak self] in self?.onAction?(.newProject) }),
      ("Open Project…", "menu-open-project", { [weak self] in self?.onAction?(.openProject(nil)) }),
      ("Open Scene File…", "menu-open-scene", { [weak self] in self?.onAction?(.openScene(nil)) }),
      ("Browse Scenes…", "menu-browse", { [weak self] in self?.onBrowse?() }),
      ("Restore Last Session", "menu-restore", { [weak self] in self?.onAction?(.restoreSession) }),
    ]
    for (title, id, action) in entries {
      let button = ActionButton(title, action)
      button.identifier = NSUserInterfaceItemIdentifier(id)
      button.controlSize = .large
      startButtons.append(button)
      if id == "menu-restore" {
        restoreInfo.textColor = .secondaryLabelColor
        restoreInfo.font = .systemFont(ofSize: 11)
        restoreRow.orientation = .vertical
        restoreRow.alignment = .leading
        restoreRow.spacing = 2
        restoreRow.addArrangedSubview(button)
        restoreRow.addArrangedSubview(restoreInfo)
        restoreRow.isHidden = true
        column.addArrangedSubview(restoreRow)
      } else {
        column.addArrangedSubview(button)
      }
      button.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }
    return column
  }

  private func buildRecent() -> NSView {
    recentRows.orientation = .vertical
    recentRows.alignment = .leading
    recentRows.spacing = 4
    recentEmpty.identifier = NSUserInterfaceItemIdentifier("menu-recent-empty")
    recentEmpty.textColor = .secondaryLabelColor
    clearButton.actionBlock = { [weak self] in self?.onClearRecent?() }
    let column = NSStackView(views: [Self.heading("Recent projects"), recentRows, recentEmpty, clearButton])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8
    column.detachesHiddenViews = true
    column.widthAnchor.constraint(equalToConstant: 320).isActive = true
    recentRows.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    return column
  }

  private func buildLaunchRows() {
    progressBar.style = .bar
    progressBar.controlSize = .small
    progressBar.minValue = 0
    progressBar.maxValue = 1
    progressBar.widthAnchor.constraint(equalToConstant: 220).isActive = true
    progressLabel.font = .systemFont(ofSize: 12)
    progressLabel.identifier = NSUserInterfaceItemIdentifier("start-progress")
    progressRow.orientation = .horizontal
    progressRow.spacing = 10
    progressRow.addArrangedSubview(progressBar)
    progressRow.addArrangedSubview(progressLabel)
    progressRow.isHidden = true
    hint.textColor = .secondaryLabelColor
    hint.font = .systemFont(ofSize: 11)
    hint.isHidden = true
    pendingRow.orientation = .horizontal
    pendingRow.spacing = 10
    pendingLabel.font = .systemFont(ofSize: 12)
    let cancel = ActionButton("Cancel") { [weak self] in self?.onCancelPending?() }
    cancel.identifier = NSUserInterfaceItemIdentifier("start-cancel-pending")
    pendingRow.addArrangedSubview(pendingLabel)
    pendingRow.addArrangedSubview(cancel)
    pendingRow.isHidden = true
  }

  private static func heading(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.textColor = .secondaryLabelColor
    return label
  }
  // A borderless button in the link colour.
  private static func link(_ title: String, _ id: String) -> ActionButton {
    let button = ActionButton(title) {}
    button.isBordered = false
    button.contentTintColor = .linkColor
    button.identifier = NSUserInterfaceItemIdentifier(id)
    return button
  }

  // MARK: State

  // The recent projects, newest first; the first RecentProjects.maximumShown get a row: the file name over its folder.
  func setRecent(_ urls: [URL]) {
    for button in recentButtons { button.removeFromSuperview() }
    recentButtons = urls.prefix(RecentProjects.maximumShown).enumerated().map { index, url in
      let button = ActionButton("") { [weak self] in self?.onOpenRecent?(url) }
      button.identifier = NSUserInterfaceItemIdentifier("menu-recent-\(index)")
      button.isBordered = false
      button.alignment = .left
      button.lineBreakMode = .byTruncatingMiddle
      let title = NSMutableAttributedString(
        string: url.lastPathComponent, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
      title.append(NSAttributedString(
        string: "\n" + RecentProjects.folder(url),
        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
      button.attributedTitle = title
      button.toolTip = url.path
      button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      return button
    }
    for button in recentButtons {
      recentRows.addArrangedSubview(button)
      button.widthAnchor.constraint(lessThanOrEqualTo: recentRows.widthAnchor).isActive = true
    }
    recentRows.isHidden = recentButtons.isEmpty
    recentEmpty.isHidden = !recentButtons.isEmpty
    clearButton.isHidden = recentButtons.isEmpty
    updateEnabled()
  }
  // The autosave's modification date; nil hides Restore Last Session.
  func setRestore(_ date: Date?) {
    restoreRow.isHidden = date == nil
    if let date { restoreInfo.stringValue = "Autosaved " + date.formatted(date: .abbreviated, time: .shortened) }
  }
  // Shader compilation or another operation; nil hides the progress row.
  func setProgress(_ snapshot: OperationProgress.Snapshot?, hint text: String? = nil) {
    progressRow.isHidden = snapshot == nil
    hint.isHidden = snapshot == nil || text == nil
    hint.stringValue = text ?? ""
    guard let snapshot else {
      progressBar.stopAnimation(nil)
      return
    }
    progressLabel.stringValue = snapshot.text
    if let fraction = snapshot.fraction {
      progressBar.isIndeterminate = false
      progressBar.doubleValue = fraction
    } else if !progressBar.isIndeterminate {
      progressBar.isIndeterminate = true
    }
    progressBar.startAnimation(nil)
  }
  // An action queued until the shaders are ready, with Cancel; nil hides it.
  func setPending(_ text: String?) {
    pendingRow.isHidden = text == nil
    pendingLabel.stringValue = text ?? ""
  }
  // A message before the studio exists, which has the status line for them; nil hides it.
  func setMessage(_ text: String?) {
    message.isHidden = text == nil
    message.stringValue = text ?? ""
  }
  // Disabled while a queued action or a started operation is in progress: the Start buttons, the recent rows, Clear and
  // Credits and licenses…. User Guide and the queued action's Cancel stay enabled.
  func setActionsEnabled(_ enabled: Bool) {
    actionsEnabled = enabled
    updateEnabled()
  }
  private func updateEnabled() {
    for button in startButtons + recentButtons + [clearButton] { button.isEnabled = actionsEnabled }
    creditsButton.isEnabled = actionsEnabled && onCredits != nil
  }
  // The control with this accessibility identifier.
  func control(_ id: String) -> NSControl? {
    func find(_ view: NSView) -> NSControl? {
      if let control = view as? NSControl, control.identifier?.rawValue == id { return control }
      for subview in view.subviews { if let found = find(subview) { return found } }
      return nil
    }
    return find(self)
  }
}

// The main menu's scroll document, laid out from the top.
private final class MenuDocumentView: NSView {
  override var isFlipped: Bool { true }
}
