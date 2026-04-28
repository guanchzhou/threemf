# Changelog

All notable changes to threemf are documented here. Format: Keep a Changelog. Versions: SemVer.

## [Unreleased]

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
