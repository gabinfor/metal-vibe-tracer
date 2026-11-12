# Scene browser: one catalog, one place to pick a scene

Status: **2026-11-12. Implemented** on `feature/scene-browser` (the catalog, the browser, downloads from its details pane, **Browse Scenes**, **Open Scene File…** and **Add Model…**, and the bundled thumbnails), except that the Happy Buddha and Chinese Dragon have no thumbnail until the question in §6 is settled; on 2026-11-11 the browser moved into its own **Scenes** window (`feature/scenes-window`, §2), and on 2026-11-12 the main window's placeholder became a main menu holding the file actions, recent projects, help and the launch progress, while the Scenes window became scenes only and opens on request (§2, §4). Design approved in conversation on 2026-11-10. Sections 1 and 2 record the situation and the decisions that led to the change; sections 3 to 8 describe the code as built. The Mitsuba importer ([MITSUBA_IMPORT_DESIGN.md](MITSUBA_IMPORT_DESIGN.md)) builds on this.

## 1. Problem (the state before this change)

This section is the problem statement; none of it describes the current code. Before the scene browser, scenes were offered from three separate lists in the code and four places in the UI, and file imports from three entries repeated in four places:

| Before | Where |
| --- | --- |
| `StudioController.sceneNames` (7 built-in scenes, the last the imported-mesh studio) | `Sources/StudioUI.swift` |
| `SpectralExamples.catalog` (5 bundled OpenUSD scenes) | `Sources/ExampleScenes.swift` |
| `ExampleScenes.catalog` (10 download scenes from `MCGUIRE2017`) | `Sources/ExampleScenes.swift` |
| Three button grids | Start screen (`Sources/StartScreen.swift`) |
| **Scene** selector with three groups | Inspector (`scenePicker`, `Sources/StudioUI.swift`) |
| **File › Open Example Scene** submenu | `Sources/StudioUI.swift`, `Sources/AppDelegate.swift` |
| Spectral examples and Example scenes panels | Project & Export page (`exampleScenePanel`) |
| **Import OBJ…**, **Open USD or glTF Scene…** | Start screen, File menu (two builders), Objects page, Project & Export page |

A scene was described by a title and a one-line summary, with no preview. Adding a collection (Bitterli's scenes) would have added a fourth group to each list.

## 2. Goal and decisions

A user picks any scene from one browser that shows a preview and the scene's specs, and downloads it from there if it is not installed. Decisions (user, 2026-11-10):

- The browser covers built-in, bundled and download scenes and **replaces** the existing lists.
- The catalog is **built into the app**: no remote index. Sizes and SHA-256 digests stay pinned in the code.
- Every scene has a **bundled thumbnail**.
- The browser lives **in its own Scenes window** (user, 2026-11-11, after trying the version that covered the main window).
- The main window shows a **main menu** until a scene is loaded (user, 2026-11-12, after trying the Scenes-window build, which showed a grey "No scene loaded" placeholder with the Scenes window in front of it at launch): file actions, recent projects, help and the launch progress. The Scenes window holds the scenes only and opens on request, not at launch. The main menu has no **Settings…**: the Settings page holds per-project render options, which have nothing to apply to with no document loaded.
- One **Open Scene File…** entry replaces the separate import entries.

Out of scope: a remote catalog, user-added catalog entries, removing an installed download from within the app (**Show in Finder** stays), ratings or search beyond a title and tag filter.

## 3. Catalog

`Sources/SceneCatalog.swift` holds `SceneCatalog.entries: [SceneEntry]`, the only list the UI reads.

| Field | Meaning |
| --- | --- |
| `id` | Stable string (`"cornell-box"`, `"sponza"`); names the thumbnail and the UI identifiers |
| `title`, `summary` | Card title and the description in the details pane |
| `collection` | `.builtIn`, `.spectral`, `.mcguire`, `.bitterli`; gives the collection's name, website and credits wording |
| `source` | `.builtIn(index)`, `.bundled(path)` or `.download(storage:, file:, archives:)` |
| `format` | `.procedural`, `.usd`, `.obj`, `.mitsuba`; selects the importer |
| `triangles`, `materials` | Specs shown on the card and in the details; nil for a built-in scene without a meaningful count |
| `tags` | Short feature labels (`"caustics"`, `"spectral"`, `"fog"`, `"textures"`) for the details pane and the search field |
| `credit`, `license`, `licenseURL`, `terms` | The credited work, its license, the license link and what the license asks of renders; nil for scenes that are part of the app. `attribution` (the import report's first line) is built from them |
| `shot` | The `scripts/showcase.json` shot applied on open; nil for built-in scenes |

Download size and disk size come from the entry's archives through `ExampleLibrary`. `ExampleArchive`, `ExampleLibrary` and `ExampleSceneDownload` are unchanged by the catalog; `SceneEntry` replaced `ExampleScene` and `SpectralExamples.Example`. The built-in scene indices and `StudioController.sceneNames` stay, since projects store the index; the catalog refers to them. The imported-mesh studio (index 6) has no entry.

## 4. Browser

`SceneBrowserView` (`Sources/SceneBrowser.swift`) replaced the start screen. `ScenesWindowController` (same file) hosts the app's one browser in the **Scenes** window: resizable, minimum content size 700 × 440, default 1000 × 700, centred over the main window the first time and remembering its frame afterwards (autosave name `ScenesWindow`). The window is created at launch but not shown; it holds the scenes only and opens on request (see Reopening). Its close button closes it and Esc hides it; it is never released, and showing it again reopens the same window.

Until a document is loaded, `MainMenuView` (`Sources/MainMenu.swift`, identifier `main-menu`) covers the main window's content (viewport and inspector): nothing renders, no autosave is written and the last session stays restorable (`StudioController.startScreen`, `showStartScreen`, `dismissStartScreen`). It shows the app's name and its version (`CFBundleShortVersionString`, omitted without a bundle); a **Start** column with **New Project**, **Open Project…**, **Open Scene File…**, **Browse Scenes…** and, while an autosave exists, **Restore Last Session** with "Autosaved *date*"; **Recent projects**, at most eight rows newest first, each the file name over its folder abbreviated with `~`, "No recent projects" when there are none and a **Clear** link otherwise; the launch progress row and the pending-action row (what a choice made during the shader compile will do, with **Cancel**); a message row; and **User Guide** (`MainMenuView.userGuideURL`, the guide on GitHub) and **Credits and licenses…**. Its buttons send `StartAction`s (`.newProject`, `.openProject(nil)`, `.openScene(nil)`, `.restoreSession`) to `AppDelegate.queueStartAction` during the launch compile, which queues them, and to `StudioController.performStartAction` afterwards. **Credits and licenses…** is disabled until the studio exists. At 700 × 440 the menu scrolls. It has no **Settings…** (§2).

`RecentProjects` (same file) wraps the system's recent-documents list (`NSDocumentController`, through `SystemRecentProjects`) behind the `RecentProjectsStore` protocol; the test controller uses an in-memory store. A project opened from a file, saved or saved as is noted (`beginOpenProject`, `beginSaveProject`); scene files, catalog scenes and the autosave are not. **File › Open Recent** lists the same projects, then **Clear Menu**, in both menu builders (`AppDelegate.installLaunchMenus`, `StudioController.installMenus`), and is refilled on every change. A recent project opens like **Open Project…** (`.openProject(url)`, with the unsaved-changes prompt); one whose file is gone is removed (`RecentProjects.remove`) and reported as "*name* is no longer at *folder*." in the status line, or in the main menu's message row before the studio exists. A missing file on a volume that is not connected (a path under `/Volumes` whose mount point is absent, `RecentProjects.volumeConnected`) stays listed and is reported as "*name* is on a volume that is not connected.". Where two listed projects share a file name, their **File › Open Recent** items add " — *folder*". `StartAction.scene(id)` replaced `.builtInScene`, `.example` and `.download`. Every open path goes through `StudioController.openScene(_:)`, which confirms discarding changes and dispatches on the entry's source. `openScene` never starts a download: for a download entry that is not installed it does nothing. That entry's details pane has **Download** (`StudioController.beginSceneDownload`), which installs it and then opens it when the Scenes window is shown with no sheet on it and that discards nothing (no document loaded, or a document without unsaved changes; otherwise the entry is selected, **Open** shows and the status line says it is downloaded), and no **Open** until then. **Download** is disabled until the launch shader compile finishes, when the studio can download.

The Scenes window's layout, left to right:

- **Filters:** All, Built-in, Included (built-in and bundled scenes), Downloads, Installed (downloads on disk), and a search field matching titles, tags and credits; "No scenes match" when nothing passes both.
- **Cards:** thumbnail, title, one line of specs (`262 k triangles · OBJ`; the format alone without a triangle count, *Built-in* for a built-in scene), and a state: *Included*, *Download 80 MB* or *Installed*.
- **Details** for the selected card: larger preview, summary, specs (triangles, materials, format, download size, disk size, tags), collection with its website link, credit, license link, license terms, and one button: **Open** or **Download *size***. Installed downloads add **Show in Finder**. **Credits and licenses…** opens the credits sheet; it appears once the studio is ready (not during the launch shader compile). The File menu has the same sheet as **Credits and Licenses…**, and **Show Downloaded Scenes in Finder**, which is also a File menu item.

Behaviour:

- **Consent.** The details pane states the download size, disk use, source host, destination folder and license, which the former consent sheet stated. The **Download** button is the consent and the sheet is gone. Nothing is requested from the network before that click.
- **Progress.** The details pane shows the download bar, the status line and **Cancel**, in place of the former progress sheet, and again when the card is selected after another was. A failed or cancelled download leaves finished archives in place; a failure shows its message above **Download**.
- **Opening.** **Open** runs one of four paths: a built-in scene, a bundled stage with its shot, an installed McGuire OBJ download with its shot and attribution line in the import report, or an installed Bitterli download, which the Mitsuba importer opens (`StudioController.beginMitsubaImport`, through `beginImportUSD`) with the shot's view and settings over the scene's own camera, film size and path depth, and the attribution line first in the import report. Like the bundled spectral examples, a catalog scene shows a status line ("Opened *title* *credit*, *license*. Credits: File > Credits and Licenses….") and not the import report sheet; the report stays available as **Import report…** on the Objects page. Opening a scene or a project from the browser over a loaded document asks to save or discard unsaved changes first; Cancel keeps the Scenes window open. **Open Scene File…** asks that question after the file is chosen, not before the open panel. Opening a document (a catalog scene, a scene file, a project, **New** or a restored session: `StudioController.associate` with `replaced`, and `restoreAutosave`) hides the Scenes window and brings the main window forward as the key window, out of the Dock if it was minimized (`ScenesWindowController.hideAfterOpening`); undo, redo and **Add Model…** leave the window as it is. The prompt, the credits sheet and the open panels (the main menu's, **File › Open Project…**, **Open Scene File…** and **Add Model…**, `StudioController.chooseOpen`) attach to the Scenes window while it is the key window, otherwise to the main window (`StudioController.sheetWindow`).
- **Reopening.** **File › Browse Scenes…** (⇧⌘O, `StudioController.browseScenes`; also in the launch menus), the inspector's **Browse…** button and the main menu's **Browse Scenes…** show the Scenes window and bring it to the front, whether or not a document is loaded; the menu item is enabled whenever the app is not busy. Showing or hiding the window never pauses the viewport or touches the document: autosave keeps running and the last session is not retired. A running download is unaffected by hiding the window, and its progress shows again when the window is shown and the entry selected.
- **Busy state.** Cards and buttons (**Download** included), and the main menu's buttons but **User Guide** and the queued action's **Cancel**, are disabled while a project operation runs, and while one choice waits for the shaders. During the launch compile, one scene, file, new project or session restore can be chosen; it waits on the main menu with its note ("Opening … once the shaders are ready.", "Creating a new project once the shaders are ready." or "Restoring the last session once the shaders are ready.", `SceneBrowserView.describe`) and **Cancel** drops it. Until the studio is ready, the Scenes window's **Credits and licenses…** link is hidden and the main menu's is shown disabled. During the compile, **File › Open Recent** and its **Clear Menu** are disabled while a choice waits (`AppDelegate.validateMenuItem`).

## 5. What is replaced

| Before | Now |
| --- | --- |
| Start screen's three grids | The browser, in the Scenes window; the file actions on the main menu |
| Inspector **Scene** selector | The current scene's name and a **Browse…** button |
| **File › Open Example Scene** | **File › Browse Scenes…** |
| Project & Export page example panels | Removed; credits are reached from the browser and the File menu |
| **Import OBJ…** and **Open USD or glTF Scene…** | **Open Scene File…** in the File menu and the main menu: USD, glTF, Mitsuba (`.xml`) or OBJ, opened as a new untitled scene, by file extension |
| Adding an OBJ to the current scene | **Add Model…** on the Objects page only (the former **Import OBJ…** behaviour) |

## 6. Thumbnails

- `scripts/render_showcase.py` gets a thumbnail mode: for each catalog entry it renders the entry's shot (or the built-in scene's default view) at 960 × 540, without the denoiser, and writes a 480 × 270 JPEG (quality 0.85) named `<id>.jpg` into `Examples/Thumbnails`, with the ids that have one in `scene-ids.txt`. The build copies the folder into the bundle, `scripts/check_bundle.py` checks one JPEG per id of that list, and `SceneBrowserView.thumbnail` decodes each image once and keeps it. The Cornell Fog Study opens with its atmosphere clear, so its thumbnail renders a `thumbnailOnly` shot of `showcase.json` (`"fog": 1`, the Atmosphere popup's Fog preview) that the README showcase run skips. A shot's `thumbnailSamples` replaces the default of its sample count capped at 256: 512 spp for the spectral examples (Tyndall Tank 1,024) and 1,024 for the Veach Bidir Room, whose grain 256 spp leaves.
- Download scenes render from the `obj` or `mitsuba` paths of their shots (`build/scenes/…`); the mode skips and lists the ones whose files are missing. A Mitsuba scene renders with its own camera (the shot's `view` "Mitsuba: camera") and path depth; the thumbnail's 960 × 540 replaces the scene's film size, so a camera whose film is narrower than 16:9, such as the square film of five of the ten Bitterli scenes, keeps its horizontal field of view and the 16:9 frame crops the film's horizontal band (a shot's own `fov` is left as it is).
- A thumbnail of a licensed scene is an adapted work. The details pane shows the credit, license and terms beside the larger preview, and the credits sheet lists every credited work; a card shows only the title, spec line and state. `REFERENCES.md` lists the thumbnails under `MCGUIRE2017` and `BITTERLI2016` with author and license. The Bedroom's thumbnail is shared under CC BY-SA 4.0.
- **Open question (user to confirm):** whether shipping renders of the Happy Buddha and Chinese Dragon in the app fits the Stanford 3D Scanning Repository terms (`STANFORD3DSCAN`). Until confirmed, those two entries (`SceneCatalog.thumbnailExempt`) have no thumbnail and their cards show a neutral placeholder with the specs; they are not in `scene-ids.txt`.

## 7. Errors

- A missing thumbnail shows the placeholder; it never blocks opening.
- A failed download, a size or digest mismatch and a full disk show their message in the details pane, above **Download**, and in the status line and the ⚠ error button (which shows the full message).
- A catalog scene that fails to open (an installed scene's file deleted or corrupt, a bundled scene missing from the bundle, a missing shot) leaves the document as it is and shows the error in the status line and the ⚠ error button, and, when the Scenes window is shown, in the details pane above **Open** (`SceneBrowserView.showOpenError`, from `StudioController.catalogOpenFailed`), where the window may be covering the status line. The Scenes window stays open; the next open of any scene clears the message. **Open Scene File…** and **Open Project…** report errors in the status line only.

## 8. Tests

- `tests/Fix_example-scenes.swift` runs on `SceneCatalog`: unique ids, every non-built-in entry has a shot in `showcase.json`, every download entry has archives with a size and digest, markers, size and digest rejection, extraction, opening an installed scene without the network (and a missing one opening nothing), downloads from local archives (success, digest mismatch, cancel, a failure on the second archive, a download that goes on while the Scenes window is hidden, one that finishes over an edited document or while the window is hidden, which opens nothing, and one that finishes over an unedited document with the window shown, which opens it), opening an installed Mitsuba scene (a synthetic scene from a local archive: its triangles, view, shot caustics mode, credit first in the report, an untitled document, the Scenes window hidden, and Cancel at the prompt changing nothing), an installed Mitsuba scene and an installed OBJ scene whose file was deleted (the document unchanged, the Scenes window still shown, the error in its details pane), and one 480 × 270 thumbnail per entry but the exempted ones, listed in `scene-ids.txt` (29 of 31).
- `tests/Fix_start-screen.swift` uses the identifiers `scenes-window` (the Scenes window), `main-menu` (the main menu), `menu-new`, `menu-open-project`, `menu-open-scene`, `menu-browse`, `menu-restore`, `menu-recent-<index>`, `menu-recent-empty`, `menu-recent-clear`, `menu-guide`, `menu-credits`, `menu-message`, `start-progress` and `start-cancel-pending` (its controls), `scene-card-<id>` (a card is found and selected), `scene-open`, `scene-download`, `scene-download-cancel` and `scene-show-in-finder`, and covers the main menu (paused, hidden viewport, no autosave, the Start buttons and their actions, Restore shown only with an autosave, the launch state's progress, pending and disabled rows, scrolling at 700 × 440, User Guide through an injected URL opener), recent projects with an in-memory store (opening, saving and saving as add a project; scene files, catalog scenes and the autosave do not; rows newest first, at most eight; a missing file removed with its message; Clear; **File › Open Recent**), a Scenes window without file actions that is not shown with the main menu, the Scenes window shown and hidden with and without a document (Esc, the main menu's **Browse Scenes…**, menu validation, the render and the autosave untouched), the absence of a Close button, filtering and search, selection, the busy state, the consent rule (no download starts without the button), and the discard prompts (a scene, a bundled scene and a project file; Cancel keeps the window open and the document, and an applied document hides the window). The test controller's Scenes window stays off screen (`ScenesWindowController(ordersOnScreen: false)`).
- `scripts/check_bundle.py` checks the bundled thumbnails: every listed id has one, identical to the repository's, and no other JPEG is bundled.
- Per the project's test-timing rule, `tests/verify.py --only` checks during development and the full suite before release.

## 9. Documentation

Updated with the change: `README.md` (how to open the example scenes), `docs/USER_GUIDE.md` (main menu and Scenes window, inspector **Scene** line, import entries, example scenes), `CHANGELOG.md`, `REFERENCES.md` (`MCGUIRE2017` used-in symbols and thumbnails), `docs/images/README.md` and this document.
