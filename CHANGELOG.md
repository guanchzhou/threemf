# Changelog

All notable changes to threemf are documented here. Format: Keep a Changelog. Versions: SemVer.

## [Unreleased]

### Fixed
- **Finder thumbnails from embedded PNGs were drawn at a quarter of their size**: `renderImageThumbnail` sized the reply in pixels but the Quick Look drawing context is in backing pixels while `contextSize` is in points, so on a Retina display the model sat in the bottom-left corner of the icon. The reply is now sized in points and drawn into `contextSize × request.scale`.

## [1.6.2] - 2026-10-25

### Security
- **One central-directory walk per archive**: ZIPFoundation's `archive[path]` rescans the whole central directory on every lookup, so a crafted `.3mf` with tens of thousands of entries and components turned each thumbnail or component lookup into a full walk. Each opened archive now builds one path index (capped at 50,000 entries) and every lookup goes through it. `<component>` and build `<item>` elements are capped at 10,000 per model file, each component path is extracted at most once, and nested component expansion stops at 100,000 mesh instances.
- **Embedded thumbnails must be PNG**: `SafePNGValidator` requires the PNG signature, ImageIO type `public.png`, and exactly one image, so a TIFF, JPEG, GIF, or animated image named `.png` never reaches its decoder.
- **Downsampled thumbnail decode**: Finder thumbnails decode embedded and cached PNGs through `CGImageSourceCreateThumbnailAtIndex` at the requested size × scale instead of decoding up to 16 MP at full resolution.
- **Thumbnail fallback renders stop on a deadline**: the thumbnail extension's STL, G-code, and 3MF fallback parses give up after 5 seconds through `ParseCancellation(timeout:)`.
- **Release workflow hardening**: the signing certificate file is deleted in the cleanup step, the signed app is checked with `codesign --verify --deep --strict` before zipping, and every release job has a timeout.

### Fixed
- **Quick Look for Bambu-typed `.3mf` files**: the preview, thumbnail, and Spotlight importer also accept `com.bambulab.3mf`, the type Bambu Studio registers for `.3mf`. Double-click still opens the slicer.
- **Corrupt first thumbnail no longer hides later ones**: `ThreeMFExtractor.extractThumbnail` tries the next candidate when one is corrupt, oversized, or not a PNG, and throws only after every candidate failed.
- **Root model from `_rels/.rels`**: `ThreeMFMeshParser` follows the package's 3D-model relationship target (size-capped, DTD/entity declarations refused) and falls back to the conventional `3D/3dmodel.model` paths.
- **Spotlight 3MF indexing reads less**: the large-file metadata path decompresses at most 1 MB of the root model and stops at `<resources>`, and the full Spotlight path skips normal computation.
- **Quick Look 3MF previews keep ZIP work off the main thread**: plate listing, PNG extraction and decode, plate cycling, and Bambu plate JSON reads run on a background queue with stale-result checks, and each preview opens the archive once.
- **Homebrew zap removes the host app container**: `~/Library/Containers/com.andreymaltsev.3mf-quicklook` is included in the cask's `zap` list.

## [1.6.1] - 2026-10-20

### Security
- **XML entity guard on `model_settings.config` and UTF-16 `DOCTYPE`/`ENTITY` payloads**: `BambuModelConfig.parseModelSettings` now refuses `DOCTYPE`/`ENTITY` declarations and disables external entities before invoking `XMLParser`, and `ThreeMFMeshParser.containsDTDOrEntityDeclaration` scans raw bytes ignoring interleaved `0x00` bytes so UTF-16/UTF-32 XML payloads cannot bypass the check.
- **Bounded `paint_color` decoding**: `BambuModelConfig.decodePaintColor` caps input length at 4,096 hex chars and decodes nibbles directly from UTF-8 bytes without allocating an intermediate `[Bool]` bit array per triangle.

### Fixed
- **3MF nested component reachability and shared external `.model` files**: `ThreeMFMeshParser` computes `neededObjectIds` transitively across multi-level `<component>` hierarchies and imports all `<object>` meshes discovered in an external `.model` file by their object IDs so sibling components referencing the same archive entry do not re-extract or collide on dictionary iteration order.
- **G-code `G92` resets, parenthesized comments, and travel/Z-hop layer tracking**: `GCodeParser` handles `G92` coordinate/extruder resets (such as `G92 E0` in `M82` mode), skips inline `( ... )` comments during parameter parsing, and avoids collapsing or inflating `layerCount` across pre-print nozzle lifts and travel Z-hops.
- **World-space camera framing, presets, and G-code top-down thumbnails**: `SceneBuilder` and `ToolpathSceneBuilder` map local Z-up bounds to SceneKit Y-up world half-extents before fitting the camera; Quick Look camera presets (`1`–`6`) frame to the active model's normalized half-extents and reset `fieldOfView`; and `ToolpathSceneBuilder.buildTopDownScene` fits the camera to the toolpath silhouette.
- **Quick Look `< 2 MB` Bambu plate HUD, wireframe isolation, axis gizmo orientation, and bed grid placement**: `< 2 MB` 3MFs that auto-load into 3D now populate `BambuPlateInfo` in the HUD; wireframe toggle (`w`) only affects the triangle mesh node; the axis gizmo (`a`) rotates live with world orientation as the camera orbits; the bed grid (`g`) sits at the model's base; and dismissing the help overlay (`?`) removes its outside-click gesture recognizer.
- **CLI `.gcode` thumbnails, `--cache` key scoping, `--plate` validation, `batch` error handling, and usage exit codes**: `threemf-cli thumbnail` renders `.gcode` files, scopes `--cache` entries by `--size` and `--plate`, validates `--plate` values, exits non-zero when `batch info` encounters a failing file or unknown action, and returns exit code `2` on usage errors.
- **SwiftPM test suite (`swift test`)**: `ThreeMFCoreTests` builds and passes via `swift test`, and `test.yml` runs both Xcode and SwiftPM test suites.

## [1.6.0] - 2026-09-29

### Fixed
- **Slicer G-code dialects**: zero-padded `G00`/`G01` moves are parsed, `M83` relative extrusion is classified as extrusion, and `G90`/`G91` select absolute or relative XYZ. `G2`/`G3` arcs in the XY plane are linearized into chords so arc-welded toolpaths stay connected.
- **Non-finite G-code coordinates**: values such as `1e999` are dropped instead of reaching the camera. Scientific notation stays inside the number instead of being read as a second `E` word.
- **Camera presets**: keys 1–6 use the same fitted framing as the opening view.
- **Multi-object plate thumbnails**: plate discovery walks the archive name list instead of stopping after 256 entries, so `Metadata/plate_N.png` is still found when hundreds of `3D/Objects` entries come first.
- **Thumbnail cache freshness**: the cache key includes sub-second modification time, so a resave in the same second is not served as the previous PNG.
- **Host copy and Shortcuts**: the host window mentions `.gcode`, and the thumbnail shortcut renders G-code as well as meshes.

### Security
- **XML fallback refuses internal entities**: a model that contains a `DOCTYPE` or `ENTITY` declaration is not passed to `NSXMLParser`, so a crafted `.3mf` cannot expand a billion-laughs payload inside Quick Look.
- **Shortcuts thumbnail size**: the render intent rejects sizes outside 1…4096, matching the CLI.
- **CLI batch errors are valid JSON**: failure lines are encoded with `JSONEncoder`, so a quote in a filename cannot break the JSONL stream.

### Changed
- **G-code preview memory**: Quick Look keeps at most 131,072 display segments while still walking the file for layer count and time estimates. Layer scrubbing and playback show or hide prebuilt per-layer nodes instead of rebuilding line geometry every frame.
- **CLI batch concurrency**: `batch` runs at most one parse per CPU at a time.
- **Finder Sync scope**: the extension watches the home directory and local volumes, and looks up installed slicers once.

## [1.5.2] - 2026-09-14

### Changed
- **G-code Finder thumbnails downsample the toolpath**: the thumbnail path still reads the whole file (so the silhouette spans the print) but keeps at most 32,768 segments via online stride doubling, instead of building a SceneKit line geometry for up to 2 million Quick Look segments. Discarded moves no longer allocate segment values or compute length/ETA statistics that Finder thumbnails do not display.
- **Thumbnail cache eviction is deterministic and cheaper**: every store that pushes the cache past the 100 MB soft cap LRU-evicts immediately. A process-local byte total avoids walking the directory after every under-budget store, with a deterministic periodic rescan to reconcile other processes and macOS cache eviction. The previous 1-in-32 random skip could leave the cache over budget across many stores.

### Added
- **3MF and G-code performance budgets**: `PerformanceTests` now times synthetic 3MF and G-code parses against the same wall-clock budgets as STL (0.250 s small / 1.500 s large), plus end-to-end 3MF and G-code parse → SceneKit → 256 px snapshot budgets.

## [1.5.1] - 2026-09-14

### Security
- **STL/G-code size caps enforced before read**: `BoundedFileReader` checks on-disk `fileSize` before `Data(contentsOf:options: .mappedIfSafe)`, so oversize files fail without loading multi-gigabyte payloads into Quick Look or Spotlight workers.
- **Spotlight large-file fast path for G-code and STL**: files over 50 MB get a lightweight description during indexing (same threshold as large 3MF metadata-only path), avoiding full toolpath/mesh parses in `mdworker`. A failed file-size lookup now fails closed instead of selecting the full parser.
- **`ResourceLimits` profiles**: Quick Look / Spotlight extensions use tighter parse caps than `threemf-cli`; Bambu `Metadata/*.config` sidecars are capped separately, and all extracted `.model` entries share one aggregate budget so component-heavy archives cannot multiply the per-entry cap.
- **PNG pixel-bomb guard**: embedded thumbnails are validated with ImageIO (`8192` max edge, `16 MP` max area) before `NSImage` decode. Dimension multiply uses overflow reporting so a crafted IHDR cannot trap.
- **Preview parses are cancelled, not just ignored**: dismissing or switching a Quick Look preview cancels the in-flight parse through `ParseCancellation`. STL (serial, parallel, ASCII), G-code, 3MF extraction/scanning/assembly, and normal computation all poll the token at loop boundaries and abort with `CancellationError`, so a dismissed preview stops consuming CPU instead of running to completion.
- **Preview load generation**: background mesh/toolpath parses no longer update the UI after Quick Look dismisses or switches files. The Quick Look completion handler still runs exactly once. App Intents use the Quick Look cap profile.
- **G-code fuzzing**: `FuzzingTests` now covers random `.gcode` bytes alongside STL/3MF.
- **Cancellation tests**: parser tests cover pre-cancelled STL, G-code, 3MF, and normal-computation paths plus a mid-flight cancel of a 1.2M-triangle STL, asserting the parse aborts rather than finishing.

## [1.5.0] - 2026-08-03
### Fixed
- **Component-based 3MF assemblies rendered wrong**: `<component>` transforms were parsed but never applied, so multi-part assemblies (common in CAD exports such as Fusion/SolidWorks) previewed with every sub-part collapsed at the origin, and only the first component appeared at all. Component transforms are now composed with the build-item transform — recursively and cycle-guarded — for both inline components and separate-file components (`p:path`).
- **Single-color 3MF objects previewed grey**: an object-level material (core-spec `pid`/`pindex`) was ignored, so files that assign one color per object (typical for single-color CAD/PrusaSlicer exports) rendered uncolored. Triangles now inherit the object's default material.
- **Crash on crafted mesh/toolpath files**: an `.stl` or `.gcode` with non-finite or out-of-range coordinates (NaN, ±Inf, `1e999`, or values beyond `Int32`) could trap an `Int(Float)` conversion and crash the Quick Look preview. Coordinate quantization (STL) and the print-time estimate (G-code) now guard for finiteness and clamp to a safe range.

### Changed
- **CLI error messages and exit codes**: `threemf-cli` now reports a clear "Unsupported file format" error (naming the extension and listing `.3mf`, `.stl`, `.gcode`) for unknown extensions instead of a misleading ".3mf archive" failure; validates `--size` (rejecting non-numeric, zero, negative, or oversized values instead of silently rendering the default or a 0×0 image); fixes a mislabeled batch-validation error; and documents its exit-code convention (`0` success, `1` runtime error, `2` usage) in `--help`.

## [1.4.0] - 2026-06-07
### Added
- **True-color 3MF previews**: previews now render real filament colors instead of flat grey. Two Bambu/Orca color mechanisms are decoded — per-object extruder assignment (`Metadata/model_settings.config` → `filament_colour` palette) and per-triangle MMU paint (`paint_color`). A painted single-object model like the Minecraft dragon egg renders black with purple speckles; a multi-object model like the chicken renders each part in its filament color.
- **3D multi-plate preview**: multi-plate Bambu/Orca projects now render one plate at a time (default: plate 1), framed to that plate. Switch plates with `←` / `→` or the on-screen `‹ ›` chevrons; the label shows `Plate i / n · Name` and the HUD reflects the visible plate. Single-plate and STL files are unaffected.
- **CLI**: `threemf-cli thumbnail <in> <out.png> --plate N` renders a single plate (1-based).
- **Info HUD**: close (`×`) button to dismiss the overlay.

### Changed
- **Camera framing**: models now fill ~90% of the preview frame instead of ~50%. The camera distance is fitted to the model's silhouette using an aspect-independent vertical field of view. Applies to mesh and G-code scenes.

### Fixed
- **Plate switcher counted phantom plates**: per-plate PNG variants (`plate_<N>_small.png`, `plate_no_light_<N>.png`, `top_<N>.png`) were each counted as a plate, e.g. "Plate 1 / 20" for a 5-plate file. `listPlates` now returns one entry per real plate (canonical `plate_<N>.png`, falling back to `top_<N>.png`).

## [1.3.0] - 2026-05-03
### Added
- **G-code preview**: `.gcode` files now render their toolpath in Quick Look. Layer scrubber at the bottom (drag the slider or use `↑/↓`); animation playback (`p`); 4 color modes via `c` (layer rainbow / travel-vs-extrusion / feedrate heatmap / uniform).
- **G-code HUD**: shows layer count, segment count, total extruded mm, total travel mm, estimated print time (from feedrate-derived seconds), bbox, and current color mode.
- **G-code thumbnails**: top-down toolpath PNG rendered in Finder. Cached via existing `ThumbnailCache`.
- **G-code Spotlight**: custom keys `com_andreymaltsev_threemf_layerCount` and `com_andreymaltsev_threemf_segmentCount` indexed by the bundled mdimporter.
- **G-code in CLI**: `threemf-cli info`, `validate`, and `batch` all accept `.gcode` files. JSON output includes layerCount/segmentCount/totalExtrudedMM/totalTravelMM/estimatedSeconds.
- **G-code in App Intents**: `Show 3MF/STL Info` shortcut now also accepts `.gcode` and reports layer/segment/dimension/ETA.
- **G-code in Finder Sync**: right-click "Open in slicer" works for `.gcode` selections.
- New UTI `com.andreymaltsev.gcode` declared in HostApp Info.plist (no Apple public UTI exists).
- New `ToolpathData`, `GCodeParser`, `ToolpathSceneBuilder` types in `Sources/Shared` (public, part of `ThreeMFCore` SwiftPM lib).
- New `LayerScrubber` view in PreviewExtension.

### Changed
- PreviewViewController split: HUDOverlay, HelpOverlay, SceneInteractionViews, PreviewOverlays moved to their own files.
- Help overlay now lists `c`, `p`, and `↑/↓` G-code shortcuts.

### Security
- G-code parser caps file size at 500 MB and segment count at 20M (mirrors STL safety pattern).


## [1.2.0] - 2026-05-03
### Added
- **Spotlight Importer (`.mdimporter`)** target: indexes triangle count, vertex count, bbox dimensions, and slicer name as both standard (`kMDItemDescription`/`kMDItemTitle`/`kMDItemAuthors`) and custom Spotlight attributes. Schema declared via `Schema.xml`. Embedded into the host app at `Contents/Library/Spotlight/`.
- **Finder Sync extension**: right-click on `.3mf` / `.stl` files in `~/` or `/Volumes` shows "Open in Bambu Studio / OrcaSlicer / PrusaSlicer" — only installed slicers appear.
- **Disk-backed thumbnail cache** (`ThumbnailCache`) for the Quick Look thumbnail extension: SHA-256-keyed by `(path, size, mtime)`. LRU eviction with 100 MB soft cap. Cache hits skip the parse + render pipeline entirely.
- **Help overlay (`?` key)** listing all keyboard shortcuts. Click outside dismisses.
- **Bambu/Orca multi-plate selector**: arrow keys cycle through embedded plate thumbnails. Lazy: only the visible plate is extracted.
- **3MF metadata HUD**: shows slicer, title, designer, creation date when present.
- **XYZ axis gizmo (`a` key)** pinned to camera, **print-bed wireframe grid (`g` key)**, and `.constant`-lit **wireframe view (`w` key)** for dark-mode visibility.
- **Auto-load 3D for files < 2 MB**: skips embedded-thumbnail detour.
- **Camera reduce-motion** + HUD reduce-transparency accessibility respect.
- **NSXMLParser fallback** when the byte-level scanner returns no meshes.
- **Mesh volume** (cm³) in HUD via divergence theorem.
- **Localizable.xcstrings** catalog for the preview extension (English shipped; ready for community translations).
- **Performance regression suite** (`Tests/PerformanceTests.swift`): wall-clock budgets that fail loudly on regression.
- **Fuzzing harness** (`Tests/FuzzingTests.swift`): 600 randomized iterations across STL + 3MF + valid-ZIP-random-XML paths.
- **swift-testing pilot** (`Tests/MeshDataPilotTests.swift`): `@Test` macros coexisting with XCTest.
- **CLI**: new `validate` subcommand (PASS/FAIL), `--cache` flag for `thumbnail`, 3MF metadata in `info` JSON.

### Changed
- **Swift 6 strict concurrency** mode enabled across all targets.
- **`Sources/Shared` types are now `public`** so the SwiftPM `ThreeMFCore` library is consumable externally.
- **Deployment target lowered macOS 26 → 14** to broaden install base ~×20.
- **Parallel binary STL parser** activates at ≥100K triangles (~2–3× on M-series for >1M-tri files).
- **Byte-level ASCII STL parser**: replaces `String(data:)` with raw-byte scan, no allocation overhead.
- **STL binary/ASCII detection**: prefers ASCII when file starts with `solid` magic (with binary fallback for buggy slicers).
- **`MeshData` adds `boundingBox`, `volume`, `metadata`** computed properties; CLI/Preview/MDImporter all share them.
- **CFBundleVersion auto-incremented** in CI from `git rev-list --count HEAD`.
- **CI**: SwiftFormat lint flipped from non-blocking to blocking. Universal-binary verification gate via `lipo -info`.
- **macOS Sonoma (14)** is now the documented minimum (Homebrew cask `>= :sonoma`).

### Security
- **`autoreleasepool`** wrap on the Spotlight importer Swift bridge — bounds mdworker memory across reindex.
- **Atomic refcount** in `MetadataImporter.c` (mdworker is multi-threaded).
- **CFPlugin factory boilerplate** hand-rolled (Xcode 16 dropped the template).
- **STL byte-parser file-size cap** (2 GiB) before any parsing decisions.
- **3MF transform validation**: rejects non-finite or oversized matrix entries (defends against crafted vertices producing Inf/NaN).
- **Path-traversal hardening**: rejects `..`, backslash, drive-letter prefixes in component paths.
- **ZIP fallback iteration cap** to bound work on archives with very large central directories.
- **Privacy Manifest** declares no tracking + Required Reasons API category C617.1.
- **`@preconcurrency QLPreviewingController`** on conformance + `nonisolated(unsafe)` on QuickLook completion handlers — Swift 6 escape hatches with documented safety invariants.

### Fixed
- `KeyableView` no longer steals first responder if it's already claimed by another view.
- Wireframe rendering switches to `.constant` lighting for visibility against dark backgrounds.
- Help overlay can be dismissed by clicking outside it.


## [1.1.0] - 2026-04-28
### Added
- 3MF multi-material rendering: parses `<basematerials>` and per-triangle `pid`/`p1` attrs (3MF Core spec). Renders with one SCNGeometryElement per material.
- Info HUD overlay (`i`) showing triangle count, vertex count, bounding box (mm), and file size.
- Wireframe view toggle (`w`).
- Camera preset keys (`1`–`6`) for top/bottom/front/back/left/right views with smooth animation.
- `threemf-cli` headless executable: `info <file>` (JSON output) and `thumbnail <input> <output.png>` subcommands.
- SwiftPM `Package.swift` exposing `ThreeMFCore` library and `threemf-cli` executable products.
- Universal binary releases (arm64 + x86_64) — drops `arch: :arm64` from Homebrew cask.
- SwiftFormat lint job in CI (non-blocking).
- Dependabot for GitHub Actions and Swift packages.

### Changed
- Mesh storage switched from `SCNVector3` (24 B/vertex) to `simd_float3` (16 B/vertex) — ~33% memory reduction on large meshes.
- Normal computation parallelized via `DispatchQueue.concurrentPerform` for meshes >50K triangles (4–6× speedup on M-series).
- Default antialiasing reduced from 4× to 2× MSAA for less GPU pressure on lower-end hardware.
- Release notes now extracted from `CHANGELOG.md` per tag (replaces auto-generated commit list).

### Security
- ZIP bomb hardening: extract callbacks enforce both declared and runtime size caps against `maxModelSize=500 MB`.
- Aggregate vertex/triangle caps (50 M / 100 M) prevent OOM via crafted multi-component 3MFs.
- Component path sanitization: rejects `..`, backslash, drive-letter prefixes, non-`.model` suffixes.
- Out-of-range vertex indices filtered before reaching SceneKit.
- STL `triangleCount` clamped to 50 M before `reserveCapacity` (prevents OOM via crafted header).
- STL parser accepts `data.count >= expectedSize` to tolerate trailing slicer bytes (was strict `==`).
- Random ephemeral keychain password in release pipeline (was empty string).

### Fixed
- Non-deterministic display order when 3MF has no `<build>` items (now sorted by object id).
- Silent failure in "Show 3D" path now shows inline error label.
- Wrong error type for unsupported file extensions (`PreviewError.unsupportedFormat`).
- `try?` swallowing fixture errors in tests replaced with explicit `try`.

## [1.0.5] - 2026-04-01
- Hardened parsers against malformed files.

## [1.0.4] - 2026-03-13
- Initial Homebrew tap distribution.
