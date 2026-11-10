# Scene browser: one catalog, one place to pick a scene

Status: **2026-11-11. Implemented** on `feature/scene-browser` (the catalog, the browser, downloads from its details pane, **Browse Scenes**, **Open Scene File…** and **Add Model…**, and the bundled thumbnails), except that the Happy Buddha and Chinese Dragon have no thumbnail until the question in §6 is settled. Design approved in conversation on 2026-11-10. Sections 1 and 2 record the situation and the decisions that led to the change; sections 3 to 8 describe the code as built. The Mitsuba importer ([MITSUBA_IMPORT_DESIGN.md](MITSUBA_IMPORT_DESIGN.md)) builds on this.

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
- The browser lives **in the main window**, in place of the start screen.
- One **Open Scene File…** entry replaces the separate import entries.

Out of scope: a remote catalog, user-added catalog entries, removing an installed download from within the app (**Show in Finder** stays), ratings or search beyond a title and tag filter.

## 3. Catalog

`Sources/SceneCatalog.swift` holds `SceneCatalog.entries: [SceneEntry]`, the only list the UI reads.

| Field | Meaning |
| --- | --- |
| `id` | Stable string (`"cornell-box"`, `"sponza"`); names the thumbnail and the UI identifiers |
| `title`, `summary` | Card title and the description in the details pane |
| `collection` | `.builtIn`, `.spectral`, `.mcguire` (later `.bitterli`); gives the collection's name, website and credits wording |
| `source` | `.builtIn(index)`, `.bundled(path)` or `.download(storage:, file:, archives:)` |
| `format` | `.procedural`, `.usd`, `.obj` (later `.mitsuba`); selects the importer |
| `triangles`, `materials` | Specs shown on the card and in the details; nil for a built-in scene without a meaningful count |
| `tags` | Short feature labels (`"caustics"`, `"spectral"`, `"fog"`, `"textures"`) for the details pane and the search field |
| `credit`, `license`, `licenseURL`, `terms` | The credited work, its license, the license link and what the license asks of renders; nil for scenes that are part of the app. `attribution` (the import report's first line) is built from them |
| `shot` | The `scripts/showcase.json` shot applied on open; nil for built-in scenes |

Download size and disk size come from the entry's archives through `ExampleLibrary`. `ExampleArchive`, `ExampleLibrary` and `ExampleSceneDownload` are unchanged by the catalog; `SceneEntry` replaced `ExampleScene` and `SpectralExamples.Example`. The built-in scene indices and `StudioController.sceneNames` stay, since projects store the index; the catalog refers to them. The imported-mesh studio (index 6) has no entry.

## 4. Browser

`SceneBrowserView` (`Sources/SceneBrowser.swift`) replaced the start screen. `StartAction.scene(id)` replaced `.builtInScene`, `.example` and `.download`. Every open path goes through `StudioController.openScene(_:)`, which confirms discarding changes and dispatches on the entry's source. `openScene` never starts a download: for a download entry that is not installed it does nothing. That entry's details pane has **Download** (`StudioController.beginSceneDownload`), which installs it and then opens it, and no **Open**. **Download** is disabled until the launch shader compile finishes, when the studio can download.

Layout, top to bottom and left to right:

- **Top row:** **Open Project…**, **Open Scene File…**, **Restore Last Session** with its note, **Close** when the browser is over a document, then the launch progress row and the pending-action row (what a choice made during the shader compile will do, with Cancel).
- **Filters:** All, Built-in, Included (built-in and bundled scenes), Downloads, Installed (downloads on disk), and a search field matching titles, tags and credits; "No scenes match" when nothing passes both.
- **Cards:** thumbnail, title, one line of specs (`262 k triangles · OBJ`; the format alone without a triangle count, *Built-in* for a built-in scene), and a state: *Included*, *Download 80 MB* or *Installed*.
- **Details** for the selected card: larger preview, summary, specs (triangles, materials, format, download size, disk size, tags), collection with its website link, credit, license link, license terms, and one button: **Open** or **Download *size***. Installed downloads add **Show in Finder**. **Credits and licenses…** opens the credits sheet; it appears once the studio is ready (not during the launch shader compile). The File menu has the same sheet as **Credits and Licenses…**, and **Show Downloaded Scenes in Finder**, which is also a File menu item.

Behaviour:

- **Consent.** The details pane states the download size, disk use, source host, destination folder and license, which the former consent sheet stated. The **Download** button is the consent and the sheet is gone. Nothing is requested from the network before that click.
- **Progress.** The details pane shows the download bar, the status line and **Cancel**, in place of the former progress sheet, and again when the card is selected after another was. A failed or cancelled download leaves finished archives in place; a failure shows its message above **Download**.
- **Opening.** **Open** runs one of three paths: a built-in scene, a bundled stage with its shot, or an installed download with its shot and attribution line in the import report. Opening a scene or a project from the browser over a loaded document asks to save or discard unsaved changes first; Cancel keeps the browser open. **Open Scene File…** asks that question after the file is chosen, not before the open panel.
- **Reopening.** With a scene loaded, **File › Browse Scenes…** (⇧⌘O, `StudioController.browseScenes`) and the inspector's **Browse…** button show the browser over the viewport; Esc or **Close** (`closeSceneBrowser`) dismisses it and the render resumes. The document stays loaded and autosave keeps running, the last session is not retired and **Restore Last Session** is not offered. A running download is unaffected by closing it. Esc does nothing at launch. **Open Project…** does not react to Return on the browser; ⌘O opens a project.
- **Busy state.** Cards and buttons (**Download** included) are disabled while a project operation runs, and while one choice waits for the shaders. During the launch compile, one scene or file can be chosen; it waits with the note "Opening … once the shaders are ready." and **Cancel** drops it. **Credits and licenses…** is not shown until the studio is ready.

## 5. What is replaced

| Before | Now |
| --- | --- |
| Start screen's three grids | The browser |
| Inspector **Scene** selector | The current scene's name and a **Browse…** button |
| **File › Open Example Scene** | **File › Browse Scenes…** |
| Project & Export page example panels | Removed; credits are reached from the browser and the File menu |
| **Import OBJ…** and **Open USD or glTF Scene…** | **Open Scene File…** in the File menu and the browser's top row: USD, glTF or OBJ, opened as a new untitled scene, by file extension |
| Adding an OBJ to the current scene | **Add Model…** on the Objects page only (the former **Import OBJ…** behaviour) |

## 6. Thumbnails

- `scripts/render_showcase.py` gets a thumbnail mode: for each catalog entry it renders the entry's shot (or the built-in scene's default view) at 960 × 540, without the denoiser, and writes a 480 × 270 JPEG (quality 0.85) named `<id>.jpg` into `Examples/Thumbnails`, with the ids that have one in `scene-ids.txt`. The build copies the folder into the bundle, `scripts/check_bundle.py` checks one JPEG per id of that list, and `SceneBrowserView.thumbnail` decodes each image once and keeps it. The Cornell Fog Study's thumbnail shows its default state, fog off, so it looks like the Cornell Box with a brighter light.
- Download scenes render from the `obj` paths of their shots (`build/scenes/…`); the mode skips and lists the ones whose files are missing.
- A thumbnail of a licensed scene is an adapted work. The card and the details pane show the credit; `REFERENCES.md` lists the thumbnails under `MCGUIRE2017` with author and license. The Bedroom's thumbnail is shared under CC BY-SA 4.0.
- **Open question (user to confirm):** whether shipping renders of the Happy Buddha and Chinese Dragon in the app fits the Stanford 3D Scanning Repository terms (`STANFORD3DSCAN`). Until confirmed, those two entries (`SceneCatalog.thumbnailExempt`) have no thumbnail and their cards show a neutral placeholder with the specs; they are not in `scene-ids.txt`.

## 7. Errors

- A missing thumbnail shows the placeholder; it never blocks opening.
- A bundled scene missing from the bundle, a missing shot, a failed download, a size or digest mismatch and a full disk report the messages they reported before the browser, in the details pane's status line and the usual error alert.

## 8. Tests

- `tests/Fix_example-scenes.swift` runs on `SceneCatalog`: unique ids, every non-built-in entry has a shot in `showcase.json`, every download entry has archives with a size and digest, markers, size and digest rejection, extraction, opening an installed scene without the network (and a missing one opening nothing), downloads from local archives (success, digest mismatch, cancel, a failure on the second archive, a download that outlives the browser), and one 480 × 270 thumbnail per entry but the exempted ones, listed in `scene-ids.txt`.
- `tests/Fix_start-screen.swift` uses the identifiers `scene-card-<id>`, `scene-open`, `scene-download`, `scene-download-cancel`, `scene-close`, `start-open`, `start-open-scene` and `start-restore`, and covers filtering and search, selection, the busy state, the consent rule (no download starts without the button), **Browse Scenes** over a document and its discard prompts.
- `scripts/check_bundle.py` checks the bundled thumbnails.
- Per the project's test-timing rule, `tests/verify.py --only` checks during development and the full suite before release.

## 9. Documentation

Updated with the change: `README.md` (how to open the example scenes), `docs/USER_GUIDE.md` (start screen, inspector **Scene** line, import entries, example scenes), `CHANGELOG.md`, `REFERENCES.md` (`MCGUIRE2017` used-in symbols and thumbnails), `docs/images/README.md` and this document.
