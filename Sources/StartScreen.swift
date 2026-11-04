import Cocoa
import UniformTypeIdentifiers

// What the start screen asks for. A nil URL asks with an open panel first.
enum StartAction {
  case openProject(URL?), importOBJ(URL?), importUSD(URL?), builtInScene(Int), restoreSession
  // A bundled example (SpectralExamples.catalog) or a downloadable one (ExampleScenes.catalog, after consent).
  case example(Int), download(Int)
}

// The window's empty start state: nothing is loaded and nothing renders until the user opens a
// project, imports a model, picks a built-in or example scene or restores the last session. While the GPU
// shaders compile at launch (AppDelegate) it shows their progress and the action queued until
// they are ready; afterwards StudioController shows it over the viewport.
final class StartScreenView: NSView {
  var onAction: ((StartAction) -> Void)?
  var onCancelPending: (() -> Void)?
  private let content = NSStackView()
  private var actionButtons: [NSButton] = []
  private let restoreRow = NSStackView()
  private let restoreInfo = NSTextField(labelWithString: "")
  private let progressRow = NSStackView()
  let progressBar = NSProgressIndicator()
  let progressLabel = NSTextField(labelWithString: "")
  private let hint = NSTextField(wrappingLabelWithString: "")
  private let pendingRow = NSStackView()
  let pendingLabel = NSTextField(wrappingLabelWithString: "")
  // Built-in scene titles (StudioController.sceneNames without the imported-mesh studio).
  static let builtInScenes = Array(StudioController.sceneNames.prefix(6))

  // `library` gives the download examples' remaining sizes.
  init(library: ExampleLibrary = ExampleLibrary()) {
    super.init(frame: .zero)
    wantsLayer = true
    identifier = NSUserInterfaceItemIdentifier("start-screen")
    content.orientation = .vertical
    content.alignment = .centerX
    content.spacing = 14
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)

    let title = NSTextField(labelWithString: "Metal Vibe Tracer")
    title.font = .systemFont(ofSize: 26, weight: .semibold)
    let subtitle = NSTextField(wrappingLabelWithString:
      "No scene is loaded. Open a project, import a model, or start from a built-in or example scene.")
    subtitle.alignment = .center
    subtitle.textColor = .secondaryLabelColor
    content.addArrangedSubview(title)
    content.addArrangedSubview(subtitle)
    content.setCustomSpacing(22, after: subtitle)

    let files = NSStackView()
    files.orientation = .horizontal
    files.spacing = 10
    for (title, id, action) in [
      ("Open Project…", "start-open", StartAction.openProject(nil)),
      ("Import OBJ…", "start-import-obj", .importOBJ(nil)),
      ("Open USD Scene…", "start-import-usd", .importUSD(nil)),
    ] {
      let button = ActionButton(title) { [weak self] in self?.onAction?(action) }
      button.identifier = NSUserInterfaceItemIdentifier(id)
      button.controlSize = .large
      if id == "start-open" { button.keyEquivalent = "\r" }
      files.addArrangedSubview(button)
      actionButtons.append(button)
    }
    content.addArrangedSubview(files)
    content.setCustomSpacing(22, after: files)

    // Scene sections: a heading, an optional note and a grid of buttons, `perRow` to a row.
    func section(_ title: String, note: String? = nil, perRow: Int = 3, _ buttons: [(String, String, StartAction)]) {
      let heading = NSTextField(labelWithString: title)
      heading.font = .systemFont(ofSize: 13, weight: .semibold)
      content.addArrangedSubview(heading)
      if let note {
        let label = NSTextField(labelWithString: note)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        content.addArrangedSubview(label)
        content.setCustomSpacing(4, after: heading)
      }
      let rows = stride(from: 0, to: buttons.count, by: perRow).map { start in
        buttons[start..<min(start + perRow, buttons.count)].map { title, id, action -> NSView in
          let button = ActionButton(title) { [weak self] in self?.onAction?(action) }
          button.identifier = NSUserInterfaceItemIdentifier(id)
          actionButtons.append(button)
          return button
        }
      }
      let grid = NSGridView(views: rows)
      grid.rowSpacing = 8
      grid.columnSpacing = 8
      for column in 0..<grid.numberOfColumns { grid.column(at: column).xPlacement = .fill }
      content.addArrangedSubview(grid)
      content.setCustomSpacing(22, after: grid)
    }
    section("Built-in scenes", Self.builtInScenes.enumerated().map { ($1, "start-scene-\($0)", .builtInScene($0)) })
    section("Example scenes", SpectralExamples.catalog.enumerated().map { ($1.title, "start-example-\($0)", .example($0)) })
    section("Download examples", note: "From Morgan McGuire's archive; downloaded once, after you agree.", perRow: 2,
            ExampleScenes.catalog.enumerated().map { index, scene in
              (Self.downloadTitle(scene, library), "start-download-\(index)", .download(index))
            })

    restoreRow.orientation = .horizontal
    restoreRow.spacing = 10
    let restore = ActionButton("Restore Last Session") { [weak self] in self?.onAction?(.restoreSession) }
    restore.identifier = NSUserInterfaceItemIdentifier("start-restore")
    actionButtons.append(restore)
    restoreInfo.textColor = .secondaryLabelColor
    restoreInfo.font = .systemFont(ofSize: 11)
    restoreRow.addArrangedSubview(restore)
    restoreRow.addArrangedSubview(restoreInfo)
    restoreRow.isHidden = true
    content.addArrangedSubview(restoreRow)

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
    hint.alignment = .center
    hint.textColor = .secondaryLabelColor
    hint.font = .systemFont(ofSize: 11)
    hint.isHidden = true
    content.addArrangedSubview(progressRow)
    content.addArrangedSubview(hint)

    pendingRow.orientation = .horizontal
    pendingRow.spacing = 10
    pendingLabel.font = .systemFont(ofSize: 12)
    let cancel = ActionButton("Cancel") { [weak self] in self?.onCancelPending?() }
    cancel.identifier = NSUserInterfaceItemIdentifier("start-cancel-pending")
    pendingRow.addArrangedSubview(pendingLabel)
    pendingRow.addArrangedSubview(cancel)
    pendingRow.isHidden = true
    content.addArrangedSubview(pendingRow)

    NSLayoutConstraint.activate([
      content.centerXAnchor.constraint(equalTo: centerXAnchor),
      content.centerYAnchor.constraint(equalTo: centerYAnchor),
      content.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
      content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
      subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
      hint.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  }
  override var wantsUpdateLayer: Bool { true }

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
  // Disabled while a queued action or a started operation is in progress.
  func setActionsEnabled(_ enabled: Bool) {
    for button in actionButtons { button.isEnabled = enabled }
  }
  func button(_ id: String) -> NSButton? { actionButtons.first { $0.identifier?.rawValue == id } }
  // A download example's short title with the size still to download ("Crytek Sponza · 80 MB"), or the title alone.
  static func downloadTitle(_ scene: ExampleScene, _ library: ExampleLibrary) -> String {
    let bytes = library.downloadBytes(scene)
    return bytes > 0 ? "\(scene.shortTitle) · \(ExampleScenes.megabytes(bytes))" : scene.shortTitle
  }
}

extension StartScreenView {
  // Asks for the file of an open or import action as a sheet on `window`; other actions need none.
  static func chooseFile(for action: StartAction, window: NSWindow, _ chosen: @escaping (StartAction) -> Void) {
    let (title, extensions, make): (String, [String], (URL) -> StartAction)
    switch action {
    case .openProject(nil): (title, extensions, make) = ("Open Metal Vibe Tracer project", ["vtrace", "json"], { .openProject($0) })
    case .importOBJ(nil): (title, extensions, make) = ("Import OBJ mesh", ["obj"], { .importOBJ($0) })
    case .importUSD(nil): (title, extensions, make) = ("Open OpenUSD scene", ["usd", "usda", "usdc", "usdz"], { .importUSD($0) })
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
  // What a queued action will do, for the start screen ("Opens Sponza.vtrace…").
  static func describe(_ action: StartAction) -> String {
    switch action {
    case .openProject(let url): return "Opening \(url?.lastPathComponent ?? "a project")"
    case .importOBJ(let url): return "Importing \(url?.lastPathComponent ?? "an OBJ mesh")"
    case .importUSD(let url): return "Opening \(url?.lastPathComponent ?? "a USD scene")"
    case .builtInScene(let index): return "Loading \(builtInScenes[index])"
    case .example(let index): return "Opening \(SpectralExamples.catalog[index].title)"
    case .download(let index): return "Opening \(ExampleScenes.catalog[index].title)"
    case .restoreSession: return "Restoring the last session"
    }
  }
}
