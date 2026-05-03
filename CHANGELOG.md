# Changelog

All notable changes to threemf are documented here. Format: Keep a Changelog. Versions: SemVer.

## [Unreleased]

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
