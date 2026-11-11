import Cocoa
import UniformTypeIdentifiers

// The scene file formats Open Scene File accepts: OpenUSD, glTF 2.0 and Wavefront OBJ.
enum SceneFile {
  static let extensions = ["usd", "usda", "usdc", "usdz"] + GLTFImporter.fileExtensions + ["obj"]
}

// What the scene browser asks for. A nil URL asks with an open panel first.
enum StartAction {
  case openProject(URL?), openScene(URL?), restoreSession
  // The SceneCatalog entry with this id. A download scene that is not installed does nothing (its Download button in
  // the browser downloads it).
  case scene(String)
}

// The scene browser (docs/SCENE_BROWSER_DESIGN.md §4), the content of the Scenes window (ScenesWindowController): a top
// row of file actions (open a project or a scene file, restore the last session) over filters and search, a grid of
// scene cards and the details pane of the selected card. While the GPU shaders compile at launch (AppDelegate) it shows
// their progress and the action queued until they are ready; afterwards StudioController drives it.
final class SceneBrowserView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
  enum Filter: Int, CaseIterable { case all, builtIn, included, downloads, installed }
  var onAction: ((StartAction) -> Void)?
  // The details pane's Download button for a download scene that is not installed.
  // Nil disables the button, as at launch, before the studio can download.
  var onDownload: ((SceneEntry) -> Void)? { didSet { updateDownloadEnabled() } }
  // The details pane's Cancel button while a download runs (setDownload).
  var onCancelDownload: (() -> Void)?
  var onCancelPending: (() -> Void)?
  // The Credits and licenses… link; nil hides it (the launch state, before the studio can show the credits sheet).
  var onCredits: (() -> Void)? { didSet { creditsButton.isHidden = onCredits == nil } }
  var filter: Filter = .all { didSet { applyFilter() } }
  var search = "" {
    didSet {
      if searchField.stringValue != search { searchField.stringValue = search }
      applyFilter()
    }
  }
  private(set) var visibleEntries: [SceneEntry] = []
  // Setting it fills the details pane and selects its card; nil empties the pane.
  var selection: SceneEntry? {
    didSet {
      fillDetails()
      syncGridSelection()
    }
  }

  // Gives the download scenes' installed state and remaining sizes; setting it reloads the cards and details.
  var library: ExampleLibrary { didSet { reload() } }
  private var actionButtons: [NSButton] = []
  private var actionsEnabled = true
  private let restoreRow = NSStackView()
  private let restoreInfo = NSTextField(labelWithString: "")
  private let progressRow = NSStackView()
  private let progressBar = NSProgressIndicator()
  private let progressLabel = NSTextField(labelWithString: "")
  private let hint = NSTextField(wrappingLabelWithString: "")
  private let pendingRow = NSStackView()
  private let pendingLabel = NSTextField(wrappingLabelWithString: "")
  private let searchField = NSSearchField()
  private var filterButtons: [NSButton] = []
  private let grid = NSCollectionView()
  private let gridScroll = NSScrollView()
  private let emptyLabel = NSTextField(labelWithString: "No scenes match")
  private let details = NSStackView()
  private let preview = ScenePreviewView()
  private let titleLabel = NSTextField(wrappingLabelWithString: "")
  private let summaryLabel = NSTextField(wrappingLabelWithString: "")
  private let specsLabel = NSTextField(wrappingLabelWithString: "")
  private let tagsLabel = NSTextField(wrappingLabelWithString: "")
  private let collectionLabel = NSTextField(wrappingLabelWithString: "")
  private let websiteButton = SceneBrowserView.link("scene-website")
  private let creditLabel = NSTextField(wrappingLabelWithString: "")
  private let licenseButton = SceneBrowserView.link("scene-license")
  private let termsLabel = NSTextField(wrappingLabelWithString: "")
  private let consentLabel = NSTextField(wrappingLabelWithString: "")
  private let downloadErrorLabel = NSTextField(wrappingLabelWithString: "")
  private let downloadRow = NSStackView()
  private let downloadBar = NSProgressIndicator()
  private let downloadStatus = NSTextField(wrappingLabelWithString: "")
  private let cancelDownload = ActionButton("Cancel") {}
  private let openButton = ActionButton("Open") {}
  private let downloadButton = ActionButton("Download") {}
  private let finderButton = ActionButton("Show in Finder") {}
  private let creditsButton = SceneBrowserView.link("scene-credits")
  // The running download (setDownload), shown while its entry is selected.
  private var download: (id: String, fraction: Double?, status: String?)?
  // The last failed download (showDownloadError), shown under its entry until the next attempt.
  private var downloadError: (id: String, message: String)?
  private static let cardIdentifier = NSUserInterfaceItemIdentifier("scene-card")

  init(library: ExampleLibrary = ExampleLibrary()) {
    self.library = library
    super.init(frame: .zero)
    wantsLayer = true
    identifier = NSUserInterfaceItemIdentifier("scene-browser")

    let top = buildTopRow()
    let filters = buildFilters()
    buildGrid()
    let detailsScroll = buildDetails()
    let columns = NSStackView(views: [filters, gridScroll, detailsScroll])
    columns.orientation = .horizontal
    columns.alignment = .top
    columns.spacing = 16
    columns.setHuggingPriority(.init(1), for: .vertical)
    let content = NSStackView(views: [top, progressRow, hint, pendingRow, columns])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 10
    content.distribution = .fill
    content.detachesHiddenViews = true
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    emptyLabel.identifier = NSUserInterfaceItemIdentifier("scene-empty")
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyLabel.isHidden = true
    addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      top.widthAnchor.constraint(equalTo: content.widthAnchor),
      columns.widthAnchor.constraint(equalTo: content.widthAnchor),
      hint.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
      filters.widthAnchor.constraint(equalToConstant: 140),
      detailsScroll.widthAnchor.constraint(equalToConstant: 260),
      gridScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: CardGridLayout.minimumWidth),
      gridScroll.heightAnchor.constraint(equalTo: columns.heightAnchor),
      detailsScroll.heightAnchor.constraint(equalTo: columns.heightAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: gridScroll.centerXAnchor),
      emptyLabel.topAnchor.constraint(equalTo: gridScroll.topAnchor, constant: 24),
    ])
    applyFilter()
  }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  // Esc hides the Scenes window.
  override func cancelOperation(_ sender: Any?) {
    (window?.windowController as? ScenesWindowController)?.hide()
  }
  override func updateLayer() {
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  }
  override var wantsUpdateLayer: Bool { true }

  // The cards' width follows the grid's (CardGridLayout).
  private var gridWidth: CGFloat = 0
  override func layout() {
    super.layout()
    if gridScroll.contentSize.width != gridWidth {
      gridWidth = gridScroll.contentSize.width
      grid.collectionViewLayout?.invalidateLayout()
    }
  }

  // MARK: Building

  private func buildTopRow() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 10
    for (title, id, action) in [
      ("Open Project…", "start-open", StartAction.openProject(nil)),
      ("Open Scene File…", "start-open-scene", .openScene(nil)),
    ] {
      let button = ActionButton(title) { [weak self] in self?.onAction?(action) }
      button.identifier = NSUserInterfaceItemIdentifier(id)
      row.addArrangedSubview(button)
      actionButtons.append(button)
    }
    restoreRow.orientation = .horizontal
    restoreRow.spacing = 8
    let restore = ActionButton("Restore Last Session") { [weak self] in self?.onAction?(.restoreSession) }
    restore.identifier = NSUserInterfaceItemIdentifier("start-restore")
    actionButtons.append(restore)
    restoreInfo.textColor = .secondaryLabelColor
    restoreInfo.font = .systemFont(ofSize: 11)
    restoreInfo.lineBreakMode = .byTruncatingTail
    restoreInfo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    restoreRow.addArrangedSubview(restore)
    restoreRow.addArrangedSubview(restoreInfo)
    restoreRow.isHidden = true
    row.addArrangedSubview(restoreRow)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    row.addArrangedSubview(spacer)
    row.detachesHiddenViews = true

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
    return row
  }

  private func buildFilters() -> NSView {
    searchField.identifier = NSUserInterfaceItemIdentifier("scene-search")
    searchField.placeholderString = "Search"
    searchField.sendsSearchStringImmediately = true
    searchField.target = self
    searchField.action = #selector(searchChanged)
    let column = NSStackView(views: [searchField])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4
    column.setCustomSpacing(12, after: searchField)
    for (filter, title) in zip(Filter.allCases, ["All", "Built-in", "Included", "Downloads", "Installed"]) {
      let button = NSButton(title: title, target: self, action: #selector(filterClicked(_:)))
      button.setButtonType(.pushOnPushOff)
      button.bezelStyle = .recessed
      button.alignment = .left
      button.tag = filter.rawValue
      button.identifier = NSUserInterfaceItemIdentifier("scene-filter-\(filter.rawValue)")
      column.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
      filterButtons.append(button)
    }
    searchField.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    return column
  }

  private func buildGrid() {
    grid.collectionViewLayout = CardGridLayout()
    grid.register(SceneCardItem.self, forItemWithIdentifier: Self.cardIdentifier)
    grid.dataSource = self
    grid.delegate = self
    grid.isSelectable = true
    grid.allowsEmptySelection = false
    grid.backgroundColors = [.clear]
    gridScroll.documentView = grid
    gridScroll.hasVerticalScroller = true
    gridScroll.drawsBackground = false
    gridScroll.borderType = .noBorder
    gridScroll.setContentHuggingPriority(.init(1), for: .horizontal)
  }

  private func buildDetails() -> NSScrollView {
    details.orientation = .vertical
    details.alignment = .leading
    details.spacing = 8
    details.detachesHiddenViews = true
    details.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 12)
    details.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    for label in [specsLabel, tagsLabel, collectionLabel, creditLabel, termsLabel, downloadStatus, consentLabel] {
      label.font = .systemFont(ofSize: 11)
      label.textColor = .secondaryLabelColor
    }
    consentLabel.identifier = NSUserInterfaceItemIdentifier("scene-download-consent")
    downloadErrorLabel.font = .systemFont(ofSize: 11)
    downloadErrorLabel.textColor = .systemRed
    downloadErrorLabel.identifier = NSUserInterfaceItemIdentifier("scene-download-error")
    downloadBar.style = .bar
    downloadBar.controlSize = .small
    downloadBar.minValue = 0
    downloadBar.maxValue = 1
    cancelDownload.actionBlock = { [weak self] in self?.onCancelDownload?() }
    cancelDownload.identifier = NSUserInterfaceItemIdentifier("scene-download-cancel")
    downloadRow.orientation = .vertical
    downloadRow.alignment = .leading
    downloadRow.spacing = 4
    for view in [downloadBar, downloadStatus, cancelDownload] { downloadRow.addArrangedSubview(view) }
    openButton.identifier = NSUserInterfaceItemIdentifier("scene-open")
    openButton.actionBlock = { [weak self] in
      if let id = self?.selection?.id { self?.onAction?(.scene(id)) }
    }
    downloadButton.identifier = NSUserInterfaceItemIdentifier("scene-download")
    downloadButton.actionBlock = { [weak self] in
      if let entry = self?.selection { self?.onDownload?(entry) }
    }
    for button in [openButton, downloadButton] { button.controlSize = .large }
    updateDownloadEnabled()
    actionButtons += [openButton, downloadButton]
    finderButton.identifier = NSUserInterfaceItemIdentifier("scene-show-in-finder")
    finderButton.actionBlock = { [weak self] in
      guard let self, let entry = self.selection else { return }
      NSWorkspace.shared.activateFileViewerSelecting([self.library.storage(entry)])
    }
    creditsButton.title = "Credits and licenses…"
    creditsButton.actionBlock = { [weak self] in self?.onCredits?() }
    creditsButton.isHidden = true
    actionButtons.append(creditsButton)
    for view in [preview, titleLabel, summaryLabel, specsLabel, tagsLabel, collectionLabel, websiteButton, creditLabel,
                 licenseButton, termsLabel, downloadRow, consentLabel, downloadErrorLabel, openButton, downloadButton,
                 finderButton, creditsButton] {
      details.addArrangedSubview(view)
    }
    details.setCustomSpacing(2, after: collectionLabel)
    details.setCustomSpacing(2, after: creditLabel)
    details.setCustomSpacing(14, after: termsLabel)

    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(details)
    let scroll = NSScrollView()
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    let width: CGFloat = 260 - 12
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      details.topAnchor.constraint(equalTo: document.topAnchor),
      details.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      details.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      details.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      preview.widthAnchor.constraint(equalToConstant: width),
      preview.heightAnchor.constraint(equalToConstant: (width * 9 / 16).rounded()),
      downloadRow.widthAnchor.constraint(equalToConstant: width),
      downloadBar.widthAnchor.constraint(equalTo: downloadRow.widthAnchor),
    ])
    for label in [titleLabel, summaryLabel, specsLabel, tagsLabel, collectionLabel, creditLabel, termsLabel, downloadStatus,
                  consentLabel, downloadErrorLabel] {
      label.preferredMaxLayoutWidth = width
    }
    return scroll
  }

  // A borderless button in the link colour.
  private static func link(_ id: String) -> ActionButton {
    let button = ActionButton("") {}
    button.isBordered = false
    button.contentTintColor = .linkColor
    button.identifier = NSUserInterfaceItemIdentifier(id)
    return button
  }

  // MARK: State

  // Re-reads the download scenes' installed state from the library.
  func reload() {
    applyFilter()
    fillDetails()
  }
  // The autosave's modification date; nil hides the restore button.
  func setRestore(_ date: Date?) {
    restoreRow.isHidden = date == nil
    if let date { restoreInfo.stringValue = "Autosaved " + date.formatted(date: .abbreviated, time: .shortened) }
  }
  // Shader compilation or another launch step; nil hides the progress row.
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
  // An action queued until the shaders are ready; nil hides it.
  func setPending(_ text: String?) {
    pendingRow.isHidden = text == nil
    pendingLabel.stringValue = text ?? ""
  }
  // Disabled while a queued action or a started operation is in progress: the action buttons and card selection.
  func setActionsEnabled(_ enabled: Bool) {
    actionsEnabled = enabled
    for button in actionButtons { button.isEnabled = enabled }
    updateDownloadEnabled()
    grid.isSelectable = enabled
  }
  private func updateDownloadEnabled() { downloadButton.isEnabled = actionsEnabled && onDownload != nil }
  // A running download of `entry` with its fraction done and status line, shown in the details pane while the entry
  // is selected in place of its Download button; nil restores the button.
  func setDownload(_ entry: SceneEntry?, fraction: Double?, status: String?) {
    download = entry.map { ($0.id, fraction, status) }
    if entry != nil { downloadError = nil }
    fillDetails()
  }
  // A failed download of `entry`: the pane shows `message` above its Download button; nil clears it.
  func showDownloadError(_ entry: SceneEntry, _ message: String?) {
    downloadError = message.map { (entry.id, $0) }
    fillDetails()
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
  // The scene's bundled 480 x 270 render (scripts/render_showcase.py --thumbnails), decoded once, or nil for a scene
  // without one (also remembered).
  @MainActor private static var thumbnails: [String: NSImage] = [:]
  @MainActor private static var withoutThumbnail: Set<String> = []
  @MainActor static func thumbnail(_ entry: SceneEntry) -> NSImage? {
    if let cached = thumbnails[entry.id] { return cached }
    if withoutThumbnail.contains(entry.id) { return nil }
    guard let image = SceneCatalog.bundledURL("Examples/Thumbnails/\(entry.id).jpg").flatMap({ NSImage(contentsOf: $0) })
    else {
      withoutThumbnail.insert(entry.id)
      return nil
    }
    thumbnails[entry.id] = image
    return image
  }

  // A card's line of specs: "262 k triangles · OBJ", "OpenUSD", or "Built-in" for a built-in scene.
  static func specLine(_ entry: SceneEntry) -> String {
    if entry.collection == .builtIn { return SceneEntry.Collection.builtIn.title }
    guard let triangles = entry.triangles else { return entry.format.title }
    return "\(count(triangles)) triangles · \(entry.format.title)"
  }
  // "262 k" or "2.8 M".
  private static func count(_ n: Int) -> String {
    if n >= 10_000_000 { return String(format: "%.0f M", Double(n) / 1e6) }
    if n >= 1_000_000 { return String(format: "%.1f M", Double(n) / 1e6) }
    return "\(Int((Double(n) / 1e3).rounded())) k"
  }
  // A card's state: "Included", "Download 80 MB" (what is still missing) or "Installed".
  func stateText(_ entry: SceneEntry) -> String {
    guard entry.isDownload else { return "Included" }
    let bytes = library.downloadBytes(entry)
    return bytes > 0 ? "Download \(SceneCatalog.megabytes(bytes))" : "Installed"
  }

  private func matches(_ entry: SceneEntry) -> Bool {
    switch filter {
    case .all: break
    case .builtIn: guard entry.collection == .builtIn else { return false }
    case .included: guard !entry.isDownload else { return false }
    case .downloads: guard entry.isDownload else { return false }
    case .installed: guard entry.isDownload, library.missing(entry).isEmpty else { return false }
    }
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return true }
    return ([entry.title, entry.credit ?? ""] + entry.tags).contains { $0.localizedCaseInsensitiveContains(query) }
  }
  // Recomputes the visible cards; the selection stays when still visible, else moves to the first card.
  private func applyFilter() {
    visibleEntries = SceneCatalog.entries.filter(matches)
    // The selected filter is also set in semibold, which shows in an inactive window too.
    for button in filterButtons {
      let selected = button.tag == filter.rawValue
      button.state = selected ? .on : .off
      button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: selected ? .semibold : .regular)
    }
    emptyLabel.isHidden = !visibleEntries.isEmpty
    grid.reloadData()
    if let current = selection, visibleEntries.contains(where: { $0.id == current.id }) {
      syncGridSelection()
    } else {
      selection = visibleEntries.first
    }
  }
  private func syncGridSelection() {
    let index = selection.flatMap { current in visibleEntries.firstIndex { $0.id == current.id } }
    let paths: Set<IndexPath> = index.map { [IndexPath(item: $0, section: 0)] } ?? []
    if grid.selectionIndexPaths != paths { grid.selectionIndexPaths = paths }
  }
  private func fillDetails() {
    guard let entry = selection else {
      details.isHidden = true
      return
    }
    details.isHidden = false
    preview.show(entry)
    titleLabel.stringValue = entry.title
    summaryLabel.stringValue = entry.summary
    var specs: [String] = []
    if let triangles = entry.triangles { specs.append("Triangles: \(triangles.formatted())") }
    if let materials = entry.materials { specs.append("Materials: \(materials)") }
    specs.append("Format: \(entry.format.title)")
    let missing = library.downloadBytes(entry)
    if missing > 0 {
      specs.append("Download: \(SceneCatalog.megabytes(missing))")
      specs.append("Disk: \(SceneCatalog.megabytes(library.diskBytes(entry)))")
    }
    specsLabel.stringValue = specs.joined(separator: "\n")
    tagsLabel.stringValue = "Tags: " + entry.tags.joined(separator: ", ")
    tagsLabel.isHidden = entry.tags.isEmpty
    collectionLabel.stringValue = entry.collection.title
    websiteButton.isHidden = entry.collection.website == nil
    if let website = entry.collection.website {
      websiteButton.title = website.host ?? website.absoluteString
      websiteButton.actionBlock = { NSWorkspace.shared.open(website) }
    }
    creditLabel.stringValue = entry.credit ?? ""
    creditLabel.isHidden = entry.credit == nil
    licenseButton.isHidden = entry.license == nil || entry.licenseURL == nil
    if let license = entry.license, let url = entry.licenseURL {
      licenseButton.title = license
      licenseButton.actionBlock = { NSWorkspace.shared.open(url) }
    }
    termsLabel.stringValue = entry.terms ?? ""
    termsLabel.isHidden = entry.terms == nil
    let running = download.flatMap { $0.id == entry.id ? $0 : nil }
    downloadRow.isHidden = running == nil
    cancelDownload.isHidden = running == nil
    if let running {
      downloadBar.isIndeterminate = running.fraction == nil
      downloadBar.doubleValue = running.fraction ?? 0
      if running.fraction == nil { downloadBar.startAnimation(nil) } else { downloadBar.stopAnimation(nil) }
      downloadStatus.stringValue = running.status ?? ""
    }
    consentLabel.isHidden = missing == 0 || running != nil
    consentLabel.stringValue = consentText(entry)
    let failed = downloadError.flatMap { $0.id == entry.id && running == nil && missing > 0 ? $0.message : nil }
    downloadErrorLabel.isHidden = failed == nil
    downloadErrorLabel.stringValue = failed ?? ""
    openButton.isHidden = missing > 0
    downloadButton.isHidden = missing == 0 || running != nil
    downloadButton.title = "Download \(SceneCatalog.megabytes(missing))"
    finderButton.isHidden = !entry.isDownload || missing > 0
  }

  // What the Download button does, which is the consent: "Downloads 80 MB from casual-effects.com and uses 120 MB in
  // ~/Library/Application Support/VibeTracer/Example Scenes/sponza."
  private func consentText(_ entry: SceneEntry) -> String {
    guard let host = library.missing(entry).first?.url.host else { return "" }
    let folder = (library.storage(entry).path as NSString).abbreviatingWithTildeInPath
    return "Downloads \(SceneCatalog.megabytes(library.downloadBytes(entry))) from \(host) and uses "
      + "\(SceneCatalog.megabytes(library.diskBytes(entry))) in \(folder)."
  }

  // MARK: Actions

  @objc private func searchChanged() { search = searchField.stringValue }
  @objc private func filterClicked(_ sender: NSButton) { filter = Filter(rawValue: sender.tag) ?? .all }

  // MARK: Grid

  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
    visibleEntries.count
  }
  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
    -> NSCollectionViewItem
  {
    let item = collectionView.makeItem(withIdentifier: Self.cardIdentifier, for: indexPath)
    let entry = visibleEntries[indexPath.item]
    (item as? SceneCardItem)?.show(entry, state: stateText(entry))
    return item
  }
  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard actionsEnabled, let index = indexPaths.first?.item, visibleEntries.indices.contains(index) else { return }
    selection = visibleEntries[index]
  }
}

extension SceneBrowserView {
  // Asks for the file of an open or import action as a sheet on `window`; other actions need none.
  static func chooseFile(for action: StartAction, window: NSWindow, _ chosen: @escaping (StartAction) -> Void) {
    let (title, extensions, make): (String, [String], (URL) -> StartAction)
    switch action {
    case .openProject(nil): (title, extensions, make) = ("Open Metal Vibe Tracer project", ["vtrace", "json"], { .openProject($0) })
    case .openScene(nil): (title, extensions, make) = ("Open scene file", SceneFile.extensions, { .openScene($0) })
    default: return chosen(action)
    }
    let panel = NSOpenPanel()
    panel.title = title
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
    panel.beginSheetModal(for: window) { response in
      if response == .OK, let url = panel.url { chosen(make(url)) }
    }
  }
  // What a queued action will do, for the browser's pending row ("Opening Sponza.vtrace").
  static func describe(_ action: StartAction) -> String {
    switch action {
    case .openProject(let url): return "Opening \(url?.lastPathComponent ?? "a project")"
    case .openScene(let url): return "Opening \(url?.lastPathComponent ?? "a scene")"
    case .scene(let id): return "Opening \(SceneCatalog.entry(id)?.title ?? "a scene")"
    case .restoreSession: return "Restoring the last session"
    }
  }
}

// The Scenes window: the app's one scene browser in its own window, which opens at launch in front of the main window
// and is shown again by File › Browse Scenes… and the Browse buttons. Its close button and Esc hide it; it is never
// released. `ordersOnScreen` false keeps the window off screen and only tracks `isVisible` (the test suite).
final class ScenesWindowController: NSWindowController, NSWindowDelegate {
  let browser: SceneBrowserView
  // Whether the window is shown: set by show() and hide().
  private(set) var isVisible = false
  private let ordersOnScreen: Bool
  private weak var parent: NSWindow?
  // Until the window is first shown without a remembered frame, when it is centred over `parent`.
  private var needsPlacement: Bool

  init(browser: SceneBrowserView = SceneBrowserView(), over parent: NSWindow? = nil, ordersOnScreen: Bool = true) {
    self.browser = browser
    self.parent = parent
    self.ordersOnScreen = ordersOnScreen
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Scenes"
    window.identifier = NSUserInterfaceItemIdentifier("scenes-window")
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 700, height: 440)
    window.contentView = browser
    window.initialFirstResponder = browser
    needsPlacement = true
    if ordersOnScreen {
      needsPlacement = !window.setFrameUsingName("ScenesWindow")
      window.setFrameAutosaveName("ScenesWindow")
    }
    super.init(window: window)
    window.delegate = self
  }
  required init?(coder: NSCoder) { fatalError() }

  // Shows the window and makes it key, or brings it to the front when it is already shown.
  func show() {
    isVisible = true
    guard ordersOnScreen, let window else { return }
    if needsPlacement {
      needsPlacement = false
      if let parent {
        let frame = window.frame, around = parent.frame
        window.setFrameOrigin(NSPoint(x: around.midX - frame.width / 2, y: around.midY - frame.height / 2))
      } else {
        window.center()
      }
    }
    window.makeKeyAndOrderFront(nil)
  }
  func hide() {
    isVisible = false
    window?.orderOut(nil)
  }
  // The close button (and Close Window) hides the window instead of closing it.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }
}

// The main window's content while no document is loaded: a grey "No scene loaded" placeholder with a Browse Scenes…
// button that shows the Scenes window.
final class NoSceneView: NSView {
  init(browse: @escaping () -> Void) {
    super.init(frame: .zero)
    wantsLayer = true
    identifier = NSUserInterfaceItemIdentifier("no-scene")
    let label = NSTextField(labelWithString: "No scene loaded")
    label.font = .systemFont(ofSize: 17, weight: .medium)
    label.textColor = .secondaryLabelColor
    let button = ActionButton("Browse Scenes…", browse)
    button.identifier = NSUserInterfaceItemIdentifier("no-scene-browse")
    let stack = NSStackView(views: [label, button])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor }
}

private extension SceneEntry.Format {
  var title: String {
    switch self {
    case .procedural: return "Procedural"
    case .usd: return "OpenUSD"
    case .obj: return "OBJ"
    }
  }
}

// Cards fill the grid's width in columns at least `minimumWidth` wide, with 16:9 previews.
private final class CardGridLayout: NSCollectionViewFlowLayout {
  static let minimumWidth: CGFloat = 180, spacing: CGFloat = 12
  override init() {
    super.init()
    minimumInteritemSpacing = Self.spacing
    minimumLineSpacing = Self.spacing
  }
  required init?(coder: NSCoder) { fatalError() }
  override func prepare() {
    let width = collectionView?.enclosingScrollView?.contentSize.width ?? 0
    let columns = max(1, Int((width + Self.spacing) / (Self.minimumWidth + Self.spacing)))
    // Narrower than one minimum-width card (only before the grid is laid out), a card takes the available width.
    let cardWidth = width < Self.minimumWidth ? max(1, width.rounded(.down))
      : ((width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
    let size = NSSize(width: cardWidth, height: (cardWidth * 9 / 16).rounded() + 62)
    if itemSize != size { itemSize = size }
    super.prepare()
  }
}

// The details pane's document view, laid out from the top.
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

// A scene's thumbnail, or a flat placeholder naming its format while it has none.
private final class ScenePreviewView: NSView {
  private let image = NSImageView()
  private let label = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.masksToBounds = true
    image.imageScaling = .scaleAxesIndependently
    label.textColor = .secondaryLabelColor
    label.font = .systemFont(ofSize: 12, weight: .medium)
    for view in [image, label] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
      image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
      label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor }

  func show(_ entry: SceneEntry) {
    let thumbnail = SceneBrowserView.thumbnail(entry)
    image.image = thumbnail
    image.isHidden = thumbnail == nil
    label.isHidden = thumbnail != nil
    label.stringValue = entry.format.title
  }
}

// A card of the grid: preview, title, spec line and state; the selected card has an accent border.
private final class SceneCardItem: NSCollectionViewItem {
  private let card = SceneCardView()
  private let preview = ScenePreviewView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let specs = NSTextField(labelWithString: "")
  private let state = NSTextField(labelWithString: "")

  override func loadView() {
    titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    for label in [specs, state] {
      label.font = .systemFont(ofSize: 11)
      label.textColor = .secondaryLabelColor
    }
    let stack = NSStackView(views: [preview, titleLabel, specs, state])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.setCustomSpacing(6, after: preview)
    stack.translatesAutoresizingMaskIntoConstraints = false
    for label in [titleLabel, specs, state] { label.lineBreakMode = .byTruncatingTail }
    card.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
      preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
      preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 9.0 / 16.0),
      titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
      specs.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
    ])
    view = card
  }
  override var isSelected: Bool { didSet { card.isSelected = isSelected } }

  func show(_ entry: SceneEntry, state text: String) {
    _ = view
    card.identifier = NSUserInterfaceItemIdentifier("scene-card-\(entry.id)")
    card.setAccessibilityElement(true)
    card.setAccessibilityRole(.group)
    card.setAccessibilityLabel("\(entry.title), \(text)")
    preview.show(entry)
    titleLabel.stringValue = entry.title
    specs.stringValue = SceneBrowserView.specLine(entry)
    state.stringValue = text
    card.isSelected = isSelected
  }
}

private final class SceneCardView: NSView {
  var isSelected = false { didSet { needsDisplay = true } }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 2
  }
  required init?(coder: NSCoder) { fatalError() }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
  }
}
