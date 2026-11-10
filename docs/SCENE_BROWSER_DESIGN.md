# Scene browser: one catalog, one place to pick a scene

Status: **2026-11-10. Proposed; nothing implemented.** Design approved in conversation on 2026-11-10. Implementation starts on a branch cut after the glTF import work on `feature/gltf-import` is committed. The Mitsuba importer ([MITSUBA_IMPORT_DESIGN.md](MITSUBA_IMPORT_DESIGN.md)) builds on this.

## 1. Problem

Scenes are offered from three separate lists in the code and four places in the UI, and file imports from three entries repeated in four places:

| Today | Where |
| --- | --- |
| `StudioController.sceneNames` (7 built-in scenes, the last the imported-mesh studio) | `Sources/StudioUI.swift` |
| `SpectralExamples.catalog` (5 bundled OpenUSD scenes) | `Sources/ExampleScenes.swift` |
| `ExampleScenes.catalog` (10 download scenes from `MCGUIRE2017`) | `Sources/ExampleScenes.swift` |
| Three button grids | Start screen (`Sources/StartScreen.swift`) |
| **Scene** selector with three groups | Inspector (`scenePicker`, `Sources/StudioUI.swift`) |
| **File › Open Example Scene** submenu | `Sources/StudioUI.swift`, `Sources/AppDelegate.swift` |
| Spectral examples and Example scenes panels | Project & Export page (`exampleScenePanel`) |
| **Import OBJ…**, **Open USD or glTF Scene…** | Start screen, File menu (two builders), Objects page, Project & Export page |

A scene is described by a title and a one-line summary; there is no preview. Adding a collection (Bitterli's scenes) would add a fourth group to each list.

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
| `credit`, `license`, `licenseURL`, `terms` | As `ExampleScene` today; nil for scenes that are part of the app |
| `shot` | The `scripts/showcase.json` shot applied on open; nil for built-in scenes |

Download size and disk size come from the entry's archives through `ExampleLibrary`, as today. `ExampleArchive`, `ExampleLibrary` and `ExampleSceneDownload` keep their behaviour; `ExampleScene` and `SpectralExamples.Example` are replaced by `SceneEntry`. The built-in scene indices and `StudioController.sceneNames` stay, since projects store the index; the catalog refers to them. The imported-mesh studio (index 6) has no entry.

## 4. Browser

`SceneBrowserView` replaces `StartScreenView`'s scene sections. `StartAction.scene(id)` replaces `.builtInScene`, `.example` and `.download`. Every open path goes through `StudioController.openScene(_:)`, which confirms discarding changes and dispatches on the entry's source; a download entry that is not installed does nothing there; its details pane's **Download** button (`StudioController.beginSceneDownload`) installs it and then opens it, and `openOrDownloadScene` only selects such an entry in the browser.

Layout, top to bottom and left to right:

- **Top row:** **Open Project…**, **Open Scene File…**, **Restore Last Session** with its note, then the launch progress row and the pending-action row that `StartScreenView` has today.
- **Filters:** All, Built-in, Included, Downloads, Installed, and a search field matching titles, tags and credits.
- **Cards:** thumbnail, title, one line of specs (`262 k triangles · OBJ`), and a state: *Included*, *Download 80 MB* or *Installed*.
- **Details** for the selected card: larger preview, summary, specs (triangles, materials, format, download size, disk size, tags), collection with its website link, credit, license link, license terms, and one button: **Open** or **Download *size***. Installed downloads add **Show in Finder**. A **Credits and licenses…** link opens the existing credits sheet, extended per collection.

Behaviour:

- **Consent.** The details pane states the download size, disk use, source host, destination folder and license, which is what the consent sheet states today. The **Download** button is the consent and replaces the sheet. Nothing is requested from the network before that click.
- **Progress.** The details pane shows the download bar, the status line and **Cancel**, in place of the progress sheet. A failed or cancelled download leaves finished archives in place, as today.
- **Opening.** **Open** runs the existing paths: a built-in scene, a bundled stage with its shot, or an installed download with its shot and attribution line in the import report.
- **Reopening.** With a scene loaded, **File › Browse Scenes…** and the inspector's **Browse…** button show the browser over the viewport; Esc or **Close** dismisses it and the render resumes. Opening a scene from it asks before discarding unsaved changes.
- **Busy state.** While shaders compile or a project operation runs, cards and buttons are disabled as the start screen's buttons are today.

## 5. What is replaced

| Today | After |
| --- | --- |
| Start screen's three grids | The browser |
| Inspector **Scene** selector | The current scene's name and a **Browse…** button |
| **File › Open Example Scene** | **File › Browse Scenes…** |
| Project & Export page example panels | Removed; credits are reached from the browser and the File menu |
| **Import OBJ…** and **Open USD or glTF Scene…** | **Open Scene File…** in the File menu and the browser's top row: USD, glTF or OBJ, opened as a new untitled scene, by file extension |
| Adding an OBJ to the current scene | **Add Model…** on the Objects page only (today's **Import OBJ…** behaviour) |

## 6. Thumbnails

- `scripts/render_showcase.py` gets a thumbnail mode: for each catalog entry it renders the entry's shot (or the built-in scene's default view) at 960 × 540, without the denoiser, and writes a 480 × 270 JPEG named `<id>.jpg` into a `SceneThumbnails` resource folder. The build copies the folder into the bundle and `scripts/check_bundle.py` checks one file per entry.
- Download scenes must be installed locally to render their thumbnails; the mode skips and lists the ones that are missing.
- A thumbnail of a licensed scene is an adapted work. The card and the details pane show the credit; `REFERENCES.md` lists the thumbnails under `MCGUIRE2017` with author and license. The Bedroom's thumbnail is shared under CC BY-SA 4.0.
- **Open question (user to confirm before implementation):** whether shipping renders of the Happy Buddha and Chinese Dragon in the app fits the Stanford 3D Scanning Repository terms (`STANFORD3DSCAN`). Until confirmed, those two entries have no thumbnail and their cards show a neutral placeholder with the specs; the bundle check exempts them explicitly.

## 7. Errors

- A missing thumbnail shows the placeholder; it never blocks opening.
- A bundled scene missing from the bundle, a missing shot, a failed download, a size or digest mismatch and a full disk report the messages they report today, in the details pane's status line and the usual error alert.

## 8. Tests

- `tests/Fix_example-scenes.swift` moves onto `SceneCatalog`: unique ids, every non-built-in entry has a shot in `showcase.json`, every download entry has archives with a size and digest, markers, size and digest rejection, extraction and opening an installed scene without the network.
- `tests/Fix_start-screen.swift` follows the new identifiers (`scene-card-<id>`, `scene-open`, `scene-download`, `start-open`, `start-open-scene`, `start-restore`) and covers filtering, selection, the busy state and the consent rule: no download starts without the button.
- A check that every entry except the exempted ones has a thumbnail in the resource folder.
- Per the project's test-timing rule, `tests/verify.py --only` checks during development and the full suite before release.

## 9. Documentation

Same change: `README.md` (how to open the example scenes), `docs/USER_GUIDE.md` (start screen, scene selector, example scenes, import entries), `CHANGELOG.md`, `REFERENCES.md` (`MCGUIRE2017` used-in symbols and thumbnails), `docs/images/README.md` if thumbnails are reused there, and this document's status line.
