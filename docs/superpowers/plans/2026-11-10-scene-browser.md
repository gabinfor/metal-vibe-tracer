# Scene Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One built-in scene catalog and one in-window browser with previews and specs replace the three scene lists, the four places that show them, and the separate import entries.

**Architecture:** `SceneCatalog.entries` (new `Sources/SceneCatalog.swift`) is the only scene list. `SceneBrowserView` (new `Sources/SceneBrowser.swift`) replaces `StartScreenView`: it is the launch screen and reopens over the viewport. The existing download, verify and extract code (`ExampleLibrary`, `ExampleSceneDownload`) and the existing open paths are reused; only their callers and parameter types change.

**Tech Stack:** Swift 6, AppKit (no SwiftUI, as the rest of the UI), the repository's GPU test harness (`tests/verify.py`), Python 3 scripts.

**Spec:** `docs/SCENE_BROWSER_DESIGN.md`

## Global Constraints

- Start on a branch cut after the glTF work on `feature/gltf-import` is committed. Do not commit onto `feature/gltf-import`'s uncommitted tree.
- `AGENTS.md` applies to every task: update the affected docs in the same change, keep citation keys and Codable fields, leave no unused code (grep `tests/` too), no drive-by refactors, keep the marker `// 5. App Entry Point`.
- Built-in scene indices and `StudioController.sceneNames` stay; projects store the index.
- No network request before the user clicks **Download** in the details pane.
- Tests run with `python3 tests/verify.py --only <file> [...]`. The full suite (`python3 tests/verify.py`) runs once, in Task 8.
- UI copy is sentence case with the exact labels below: **Open Project…**, **Open Scene File…**, **Restore Last Session**, **Browse Scenes…**, **Browse…**, **Add Model…**, **Open**, **Download *size***, **Cancel**, **Show in Finder**, **Credits and licenses…**, **Close**. Filters: **All**, **Built-in**, **Included**, **Downloads**, **Installed**.
- Thumbnails: rendered at 960 × 540 without the denoiser, shipped as 480 × 270 JPEG.
- Happy Buddha (`buddha`) and Chinese Dragon (`chinese-dragon`) ship without a thumbnail until the user confirms the Stanford terms allow it.

## Review Focus

1. A download is running and the user selects another card or closes the browser: the download continues, and its progress is shown again when its card is reselected. (Task 5)
2. The window is at its minimum size, 700 × 440: the browser scrolls instead of clipping the **Open** / **Download** button. (Task 4)
3. A search that matches nothing: the grid shows "No scenes match" and the details pane is empty, without a crash on the missing selection. (Task 4)
4. The disk fills or the archive digest mismatches mid-download: the pane shows the error text and returns to the **Download** button; finished archives stay installed. (Task 5)
5. **Open Scene File…** on an `.obj` while a project with unsaved changes is open: the discard confirmation appears before anything is replaced. (Task 3)

---

### Task 1: The catalog

**Files:**
- Create: `Sources/SceneCatalog.swift`
- Modify: `Sources/ExampleScenes.swift` (remove `ExampleScene`, `ExampleScenes`, `SpectralExample`, `SpectralExamples`; retarget `ExampleLibrary`, `ExampleSceneDownload` and the `StudioController` extension)
- Modify: every caller of the removed types (`Sources/StartScreen.swift`, `Sources/StudioUI.swift`, `Sources/AppDelegate.swift`, `scripts/render_showcase.py` driver if it names them)
- Test: `tests/Fix_example-scenes.swift`

**Interfaces:**
- Produces:

```swift
struct SceneEntry: Sendable {
  enum Collection: String, Sendable, CaseIterable { case builtIn, spectral, mcguire }
  enum Source: Sendable {
    case builtIn(Int)                       // index into StudioController.sceneNames
    case bundled(String)                    // repository path, the same under Contents/Resources
    case download(storage: String, file: String, archives: [ExampleArchive])
  }
  enum Format: String, Sendable { case procedural, usd, obj }
  var id: String
  var title: String
  var summary: String
  var collection: Collection
  var source: Source
  var format: Format
  var triangles: Int?
  var materials: Int?
  var tags: [String]
  var credit: String?
  var license: String?
  var licenseURL: URL?
  var terms: String?
  var shot: String?
  var archives: [ExampleArchive]            // empty unless .download
  var isDownload: Bool
  var work: String                          // title up to " (", as ExampleScene.work
  var attribution: String?                  // ExampleScene.attribution's text; nil without a credit
}
extension SceneEntry.Collection {
  var title: String                         // "Built-in", "Spectral examples", "McGuire Computer Graphics Archive"
  var website: URL?                         // .mcguire: https://casual-effects.com/data/
}
enum SceneCatalog {
  static let entries: [SceneEntry]
  static func entry(_ id: String) -> SceneEntry?
  static var credits: [String]              // one line per credited work, as ExampleScenes.credits
  static let stanfordTerms: String
  static func megabytes(_ bytes: Int64) -> String
  static func bundledURL(_ path: String) -> URL?   // SpectralExamples.url
}
```

- `ExampleLibrary`: `storage(_:)`, `missing(_:)`, `downloadBytes(_:)`, `diskBytes(_:)` take `SceneEntry` (zero / empty for non-downloads); `objURL(_:)` becomes `sceneFileURL(_ entry: SceneEntry) -> URL?`. `ExampleSceneDownload.run` takes `SceneEntry`.
- Entry ids, in order: `pavilion`, `cornell-box`, `veach-mis`, `cornell-glass-mirror`, `cornell-fog`, `reflective-ring` (built-in indices 0–5); `newton-series`, `abbe-row`, `tyndall-tank`, `lamp-spectra`, `lantern-arcade` (shots `spectral-<id>`); `sponza`, `san-miguel`, `bistro-exterior`, `bistro-interior`, `bedroom`, `breakfast-room`, `buddha`, `chinese-dragon`, `fireplace-room`, `living-room` (shots, archives, digests, credits and terms copied unchanged from `ExampleScenes.catalog`).
- Triangles / materials for the downloads, from `REFERENCES.md` `MCGUIRE2017`: 262,266 / 25; 9,963,375 / 287; 2,833,329 / 132; 1,020,903 / 66; 383,504 / 7; 269,764 / 14; 1,087,304 / nil; 871,198 / nil; 142,983 / 22; 580,592 / 42. Built-in and spectral entries: nil.
- Tags: spectral entries `["spectral"]` plus one of `"thin film"`, `"dispersion"`, `"fog"`, `"light spectra"`, `"many lights"`; `cornell-fog` `["fog"]`; `cornell-glass-mirror` `["glass"]`; textured downloads `["textures"]`.

- [ ] **Step 1: Rewrite the catalog section of `tests/Fix_example-scenes.swift` against the new types.** Assertions:

```swift
let entries = SceneCatalog.entries
require(Set(entries.map(\.id)).count == entries.count && entries.count == 21, "catalog ids are unique")
require(entries.filter(\.isDownload).compactMap(\.shot) == ["sponza-noon", "san-miguel-golden",
  "bistro-exterior-golden", "bistro-interior", "bedroom", "breakfast-room", "buddha", "chinese-dragon",
  "fireplace-room", "living-room"], "download entries keep their shots")
for entry in entries {
  if case .builtIn(let index) = entry.source {
    require(entry.shot == nil && StudioController.sceneNames.indices.contains(index) && index < 6, "\(entry.id) is a built-in scene")
  } else {
    require(shots.contains { $0.name == entry.shot }, "\(entry.id) has its showcase shot")
  }
  require(entry.id.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }, "\(entry.id) is a file-safe id")
}
require(SceneCatalog.entry("sponza")?.triangles == 262_266 && SceneCatalog.entry("nope") == nil, "lookup by id")
```

Keep the existing archive, digest, attribution, credits (9 lines), marker, verification, extraction and controller-open assertions, renamed onto `SceneEntry`.

- [ ] **Step 2: Run** `python3 tests/verify.py --only Fix_example-scenes.swift`. Expected: compile failure, `SceneCatalog` not found.
- [ ] **Step 3: Implement `Sources/SceneCatalog.swift`** and retarget `ExampleLibrary`, `ExampleSceneDownload` and the callers. Callers keep today's behaviour for now by looking entries up through `SceneCatalog.entries.filter` on collection (the lists themselves go in Tasks 4 and 6). Move the `REFERENCES.md` citation comments with the code.
- [ ] **Step 4: Run** `python3 tests/verify.py --only Fix_example-scenes.swift Fix_start-screen.swift`. Expected: PASS lines for both, no failures.
- [ ] **Step 5: Commit** `git commit -m "Scene catalog: one list for built-in, bundled and download scenes"`.

### Task 2: Opening a catalog entry

**Files:**
- Modify: `Sources/ExampleScenes.swift` (`StudioController` extension), `Sources/StartScreen.swift` (`StartAction`), `Sources/StudioUI.swift` (`performStartAction`), `Sources/AppDelegate.swift`
- Test: `tests/Fix_example-scenes.swift`, `tests/Fix_start-screen.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces:

```swift
enum StartAction { case openProject(URL?), openScene(URL?), scene(String), restoreSession }   // openScene lands in Task 3
extension StudioController {
  func openScene(_ entry: SceneEntry)       // confirms discarding changes, then opens; a download entry
                                            // that is not installed does nothing and returns
  func isInstalled(_ entry: SceneEntry) -> Bool   // true for built-in and bundled entries
}
```

`openScene` replaces `startBuiltInScene` callers, `openSpectralExample` and `openExampleScene` + `beginExampleImport`. `StartAction.builtInScene`, `.example` and `.download` are removed in this task; `.importOBJ` and `.importUSD` stay until Task 3.

- [ ] **Step 1: Tests.** In `Fix_example-scenes.swift`, open the locally installed synthetic scene through `controller.openScene(entry)` and keep the shot, emission-scale and attribution assertions. Add: `controller.openScene(notInstalled)` leaves `controller.document` unchanged and starts no `exampleDownload`. In `Fix_start-screen.swift`, replace `.builtInScene(1)` with `.scene("cornell-box")` and require the loaded scene index is 1.
- [ ] **Step 2: Run** both files with `--only`. Expected: compile failure.
- [ ] **Step 3: Implement** `openScene(_:)` by dispatching on `entry.source` to the three existing open paths, and `StartScreenView.describe` for `.scene` ("Opening *title*").
- [ ] **Step 4: Run** both files. Expected: PASS.
- [ ] **Step 5: Commit** `"Open scenes through their catalog entry"`.

### Task 3: Open Scene File… and Add Model…

**Files:**
- Modify: `Sources/StartScreen.swift` (`chooseFile`, `describe`), `Sources/StudioUI.swift` (File menu, `importMesh`, `importUSD`, validation list near line 2665, Project & Export page buttons near line 1210), `Sources/SceneGraphUI.swift:248-249`, `Sources/AppDelegate.swift:203-212`, `Sources/USDImporter.swift` (`importUSD` panel)
- Test: `tests/Fix_start-screen.swift`

**Interfaces:**
- Produces:

```swift
enum SceneFile {
  static let extensions: [String]           // ["usd", "usda", "usdc", "usdz"] + GLTFImporter.fileExtensions + ["obj"]
}
extension StudioController {
  func openSceneFile()                      // open panel titled "Open scene file", then beginOpenSceneFile
  func beginOpenSceneFile(_ url: URL)       // USD / glTF: beginImportUSD; OBJ: a new untitled document with the
                                            // OBJ appended and framed. Confirms discarding changes first.
  func addModel()                           // today's importMesh: appends an OBJ to the current scene
}
```

`StartAction.importOBJ` and `.importUSD` are replaced by `.openScene(URL?)`. Menu items: **Open Scene File…** (File menu, both builders). **Add Model…** appears only on the Objects page. The Project & Export page loses both import buttons.

- [ ] **Step 1: Tests** in `Fix_start-screen.swift`: `performStartAction(.openScene(objURL))` on the start screen loads a document whose graph has the OBJ's triangles and `controller.fileURL == nil`; with a dirty document, `beginOpenSceneFile` asks before replacing (find how the existing tests exercise `confirmDiscardingChanges` and do the same; if none do, add the smallest injectable hook to it); `SceneFile.extensions` contains `"glb"`, `"usdz"` and `"obj"`.
- [ ] **Step 2: Run.** Expected: compile failure.
- [ ] **Step 3: Implement.** OBJ-as-new-scene reuses the build closure of `beginExampleImport` without a shot.
- [ ] **Step 4: Run** `--only Fix_start-screen.swift Fix_ui-modes.swift Fix_frontend.swift`. Expected: PASS (update any label these files assert).
- [ ] **Step 5: Commit** `"One Open Scene File entry; Add Model on the Objects page"`.

### Task 4: The browser view

**Files:**
- Create: `Sources/SceneBrowser.swift`
- Delete: `Sources/StartScreen.swift` (move `StartAction`, `chooseFile` and `describe` into `SceneBrowser.swift`)
- Modify: `Sources/AppDelegate.swift`, `Sources/StudioUI.swift` (`startScreen` type, `showStartScreen`, `dismissStartScreen`)
- Test: `tests/Fix_start-screen.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:

```swift
final class SceneBrowserView: NSView {
  enum Filter: Int, CaseIterable { case all, builtIn, included, downloads, installed }
  var onAction: ((StartAction) -> Void)?
  var onDownload: ((SceneEntry) -> Void)?
  var onCancelDownload: (() -> Void)?
  var onCancelPending: (() -> Void)?
  var onClose: (() -> Void)?                // nil hides the Close button (launch state)
  init(library: ExampleLibrary = ExampleLibrary())
  var filter: Filter
  var search: String
  private(set) var visibleEntries: [SceneEntry]
  var selection: SceneEntry?                // setting it fills the details pane
  func reload()                             // re-reads installed state from the library
  func setRestore(_ date: Date?)
  func setProgress(_ snapshot: OperationProgress.Snapshot?, hint: String?)
  func setPending(_ text: String?)
  func setActionsEnabled(_ enabled: Bool)
  func setDownload(_ entry: SceneEntry?, fraction: Double?, status: String?)   // Task 5 drives it
  func control(_ id: String) -> NSControl?
  static func thumbnail(_ entry: SceneEntry) -> NSImage?   // nil until Task 7 ships images: placeholder shown
}
```

- Filter rules: Built-in = `.builtIn` collection; Included = built-in or bundled; Downloads = `isDownload`; Installed = `isDownload` and no missing archives. Search matches title, tags and credit, case-insensitively.
- Card state text: `Included`, `Download 80 MB` (`SceneCatalog.megabytes` of the missing bytes), `Installed`. Card spec line: `"262 k triangles · OBJ"`; built-in: `"Built-in"`.
- Identifiers: `scene-browser`, `scene-card-<id>`, `scene-filter-<rawValue>`, `scene-search`, `scene-open`, `scene-download`, `scene-download-cancel`, `scene-show-in-finder`, `scene-credits`, `scene-close`, `scene-empty`, and the kept `start-open`, `start-open-scene`, `start-restore`, `start-progress`, `start-cancel-pending`.
- Layout: top row, then a split of filters (fixed 140 pt), a scrolling `NSCollectionView` of cards (minimum card width 180 pt), and a details pane (fixed 260 pt) inside its own `NSScrollView`. The details pane lists, in order: preview, title, summary, specs, tags, collection with website link, credit, license link, terms, the primary button.
- Empty search: `scene-empty` label "No scenes match" and `selection == nil`.

- [ ] **Step 1: Tests** in `Fix_start-screen.swift`, replacing the button-grid assertions:

```swift
let browser = SceneBrowserView(library: ExampleLibrary(root: folder.appendingPathComponent("library")))
require(browser.visibleEntries.count == 21 && browser.selection?.id == "pavilion", "all scenes, first selected")
browser.filter = .downloads
require(browser.visibleEntries.count == 10 && browser.visibleEntries.allSatisfy(\.isDownload), "downloads filter")
browser.filter = .installed
require(browser.visibleEntries.isEmpty && browser.selection == nil && browser.control("scene-empty")?.isHidden == false, "nothing installed")
browser.filter = .all; browser.search = "bistro"
require(browser.visibleEntries.map(\.id) == ["bistro-exterior", "bistro-interior"], "search by title")
browser.search = "spectral"
require(browser.visibleEntries.count == 5, "search by tag")
browser.search = ""; browser.selection = SceneCatalog.entry("sponza")
require(browser.control("scene-download")?.isHidden == false && browser.control("scene-open")?.isHidden == true
  && (browser.control("scene-download") as? NSButton)?.title == "Download 80 MB", "a missing download offers Download")
browser.selection = SceneCatalog.entry("cornell-box")
require(browser.control("scene-open")?.isHidden == false && browser.control("scene-download")?.isHidden == true, "included scenes open")
browser.setActionsEnabled(false)
require(browser.control("scene-open")?.isEnabled == false && browser.control("start-open")?.isEnabled == false, "busy disables actions")
browser.frame = NSRect(x: 0, y: 0, width: 700, height: 440); browser.layoutSubtreeIfNeeded()
require(browser.control("scene-open").map { browser.bounds.contains($0.convert($0.bounds, to: browser).origin) || $0.enclosingScrollView != nil } == true,
  "at the minimum window size the primary button is reachable")
```

Keep the launch-compile, restore-row, pending-row and autosave assertions, moved onto `SceneBrowserView`.

- [ ] **Step 2: Run.** Expected: compile failure.
- [ ] **Step 3: Implement `SceneBrowserView`** and switch `AppDelegate` and `StudioController` to it (`startScreen: SceneBrowserView?`). `onAction` for **Open** sends `.scene(id)`; `onDownload` is wired in Task 5.
- [ ] **Step 4: Run** `--only Fix_start-screen.swift`. Expected: PASS.
- [ ] **Step 5: Launch the app** (`./build.sh`, then open the built app) and check by eye: the browser at launch, each filter, the search field, and the layout at 700 × 440. Record what was checked in the commit body.
- [ ] **Step 6: Commit** `"Scene browser replaces the start screen's scene lists"`.

### Task 5: Download from the details pane

**Files:**
- Modify: `Sources/ExampleScenes.swift` (`confirmExampleDownload`, `beginExampleDownload`, the progress sheet), `Sources/SceneBrowser.swift`, `Sources/StudioUI.swift`
- Test: `tests/Fix_example-scenes.swift`, `tests/Fix_start-screen.swift`

**Interfaces:**
- Consumes: `SceneBrowserView.setDownload`, `onDownload`, `onCancelDownload`.
- Produces:

```swift
extension StudioController {
  func beginSceneDownload(_ entry: SceneEntry)   // starts ExampleSceneDownload; on success reloads the browser and
                                                 // opens the entry; on failure shows the error and restores the button
  func cancelSceneDownload()
  var downloadingScene: SceneEntry? { get }
}
```

The consent sheet (`confirmExampleDownload`) and the progress sheet are removed. The details pane of a missing download shows, above the button: `"Downloads <size> from <host> and uses <disk size> in <destination folder>."`, with host from the first archive's URL and the destination `ExampleLibrary.storage(entry).path` abbreviated with `~`.

- [ ] **Step 1: Tests.**
  - `Fix_start-screen.swift`: selecting `sponza` sets the pane's consent text to contain `"80 MB"`, `"casual-effects.com"` and `"Example Scenes/sponza"`; selecting cards and changing filters never calls `onDownload` (count it); `browser.setDownload(entry, fraction: 0.5, status: "x")` shows `scene-download-cancel` and hides `scene-download`; selecting another card hides the progress, and reselecting `entry` shows it again at 0.5; `setDownload(nil, …)` restores the button.
  - `Fix_example-scenes.swift`: with a `file://` archive whose digest is wrong, `beginSceneDownload` ends with `downloadingScene == nil`, the entry still missing, and the browser's status holding the mismatch message; with the correct local archive it ends installed and opened.
- [ ] **Step 2: Run** both. Expected: FAIL.
- [ ] **Step 3: Implement.** The download keeps running when the browser is dismissed; `showStartScreen` re-applies `setDownload` from `downloadingScene`.
- [ ] **Step 4: Run** both. Expected: PASS.
- [ ] **Step 5: Commit** `"Download scenes from the browser's details pane"`.

### Task 6: Reopen the browser; remove the old lists

**Files:**
- Modify: `Sources/StudioUI.swift` (`scenePicker`, `exampleTag` / `downloadTag`, File menu `Open Example Scene` block, `exampleSceneAction`, `spectralExampleAction`, menu validation), `Sources/ExampleScenes.swift` (`exampleScenePanel`, `exampleSceneTitle`, `showExampleCredits`), `Sources/AppDelegate.swift`
- Test: `tests/Fix_start-screen.swift`, `tests/Fix_ui-modes.swift`

**Interfaces:**
- Produces:

```swift
extension StudioController {
  func browseScenes()                       // shows the browser over a loaded document, with Close; Esc closes
  func closeSceneBrowser()                  // resumes the viewport; the document is untouched
  var isBrowsingScenes: Bool { get }
}
```

- The inspector's scene control: a label with the current scene's title (`SceneCatalog` title for a built-in index, the document's name otherwise) and a **Browse…** button, identifier `scene-browse`.
- **File › Browse Scenes…** (⇧⌘O) replaces the **Open Example Scene** submenu. **Credits and licenses…** stays in the File menu and in the browser.
- Unlike the launch state, browsing over a loaded document keeps autosave and does not retire the last session; `dismissStartScreen`'s autosave retirement runs only for the launch state.
- Remove: `scenePicker`'s menu, `exampleTag`, `downloadTag`, `exampleScenePanel` and its page entry, `exampleSceneTitle`, the two menu actions, `StartScreenView.downloadTitle`.

- [ ] **Step 1: Tests.** With a document loaded: `browseScenes()` sets `isBrowsingScenes`, pauses the viewport and leaves `controller.document` equal; `closeSceneBrowser()` resumes it; the autosave file's modification date is unchanged across browse and close; the File menu has `Browse Scenes…` and no `Open Example Scene`; the inspector has `scene-browse` and no popup titled "Scene".
- [ ] **Step 2: Run** `--only Fix_start-screen.swift Fix_ui-modes.swift`. Expected: FAIL.
- [ ] **Step 3: Implement** and remove the listed code. Grep `Sources/`, `tests/` and `scripts/` for each removed symbol.
- [ ] **Step 4: Run** `--only Fix_start-screen.swift Fix_ui-modes.swift Fix_frontend.swift Fix_example-scenes.swift`. Expected: PASS.
- [ ] **Step 5: Commit** `"Browse Scenes replaces the scene selector, menu and inspector lists"`.

### Task 7: Thumbnails

**Files:**
- Create: `Examples/Thumbnails/<id>.jpg` (19 files), `Examples/Thumbnails/README.md` (credits and licenses per image)
- Modify: `scripts/render_showcase.py`, `build.sh`, `scripts/check_bundle.py`, `Sources/SceneBrowser.swift`, `tests/Fix_example-scenes.swift`

**Interfaces:**
- `python3 scripts/render_showcase.py --thumbnails [--only ID ...]`: for each catalog entry, renders its shot (a built-in entry: its scene index at the default view) at 960 × 540 with `denoise` off, downsamples to 480 × 270 and writes `Examples/Thumbnails/<id>.jpg` at JPEG quality 0.85. The entry list comes from the Swift driver (`SceneCatalog.entries`), not a second list in Python. Entries whose download is not installed are skipped and listed at the end; the exit status is 0.
- `SceneBrowserView.thumbnail(_:)` loads `SceneCatalog.bundledURL("Examples/Thumbnails/<id>.jpg")`.
- `SceneCatalog.thumbnailExempt: Set<String> = ["buddha", "chinese-dragon"]`.
- `build.sh` copies `Examples/Thumbnails` to `Contents/Resources/Examples/Thumbnails`; `check_bundle.py` requires one JPEG per non-exempt id (ids read from a `scene-ids.txt` the Swift driver writes during the thumbnail run and that is checked in beside the images).

- [ ] **Step 1: Test** in `Fix_example-scenes.swift`: every entry not in `thumbnailExempt` has a readable 480 × 270 image at its path; exempt entries have none; `SceneBrowserView.thumbnail` returns nil for an exempt entry without throwing.
- [ ] **Step 2: Run.** Expected: FAIL (no images).
- [ ] **Step 3: Implement the thumbnail mode**, render (the ten download scenes must be installed under Application Support; report progress as samples done / target and elapsed time), add the build copy and bundle check.
- [ ] **Step 4: Write `Examples/Thumbnails/README.md`** and the `REFERENCES.md` `MCGUIRE2017` note: each licensed thumbnail with author, license and link; the Bedroom's under CC BY-SA 4.0; the two Stanford entries withheld pending the user's confirmation.
- [ ] **Step 5: Run** `--only Fix_example-scenes.swift Fix_build.swift`, then `./build.sh`. Expected: PASS, and `check_bundle.py` reports no problems.
- [ ] **Step 6: Commit** `"Bundled scene thumbnails"`.

### Task 8: Documentation and full verification

**Files:**
- Modify: `README.md`, `docs/USER_GUIDE.md`, `CHANGELOG.md`, `REFERENCES.md`, `docs/SCENE_BROWSER_DESIGN.md` (status line), `docs/images/README.md` if a thumbnail is reused there

- [ ] **Step 1: Update the docs.** `README.md`: how to open example scenes ("Download examples" wording near line 49). `docs/USER_GUIDE.md`: the start screen section (line 5), the Scene selector (line 13), the import entries (lines 59–63), the example scenes (lines 91–93). `CHANGELOG.md`: one user-visible entry. `REFERENCES.md`: `MCGUIRE2017` "Used in" symbols (`SceneCatalog`, `SceneEntry`, `SceneBrowserView`) replacing the removed ones. Check every label, path and count against the code.
- [ ] **Step 2: Grep for stale names:** `rg "Open Example Scene|Import OBJ…|Open USD or glTF|ExampleScenes\.|SpectralExamples|StartScreenView" -- . ':!docs/superpowers' ':!docs/archive'`. Expected: no hits outside `CHANGELOG.md` history.
- [ ] **Step 3: Run the full suite:** `python3 tests/verify.py`. Expected: every file prints its PASS lines and the run exits 0.
- [ ] **Step 4: Commit** `"Scene browser: documentation"`.
