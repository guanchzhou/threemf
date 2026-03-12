# Agents

## Project overview

**threemf** is a macOS Quick Look plugin for previewing `.3mf` and `.stl` 3D printing files in Finder. Press Space on a file to see an interactive 3D preview with orbit, pan, and zoom.

## Architecture

```
Sources/
├── HostApp/           # Minimal SwiftUI host app (just a container for extensions)
├── Shared/            # Core logic shared between both extensions
│   ├── MeshData.swift           # Vertex/index/normal data model
│   ├── STLParser.swift          # Binary + ASCII STL parser
│   ├── ThreeMFMeshParser.swift  # 3MF XML mesh parser (ZIP + component refs)
│   ├── ThreeMFExtractor.swift   # PNG thumbnail extractor from 3MF ZIP
│   └── SceneBuilder.swift       # Creates SceneKit scene from MeshData
├── PreviewExtension/  # QLPreviewingController — spacebar preview
└── ThumbnailExtension/# QLThumbnailProvider — Finder icon thumbnails
Tests/                 # Unit tests for parsers, scene builder, thumbnail extraction
```

## Build

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
xcodebuild -project threemf.xcodeproj -scheme ThreeMFQuickLook -configuration Release build
```

For CI (no code signing):
```bash
xcodebuild ... CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## Test

```bash
xcodebuild -project threemf.xcodeproj -scheme ThreeMFTests -configuration Debug test
```

## Key decisions

- **Brand**: always "threemf" (lowercase, one word)
- **3D first, thumbnail fallback**: for .3mf files, try parsing the 3D mesh; if that fails, extract the embedded PNG thumbnail
- **Z-up to Y-up**: 3D printing models use Z as vertical axis, SceneKit uses Y — apply -90° X rotation
- **SceneKit for rendering**: uses Metal under the hood, no custom shaders — SCNGeometry + SCNView with `allowsCameraControl`
- **Custom scroll handling**: `ZoomSCNView` subclass overrides scroll wheel for FOV zoom instead of dolly
- **Right-click pan**: custom `rightMouseDragged` handler for camera panning
- **No external deps except ZIPFoundation**: STL parsing, XML parsing, SceneKit rendering all use system frameworks
- **Vertex deduplication**: STL parser uses quantized coordinate keys (multiply by 10000, round to Int32) for fast dedup

## 3MF format notes

- `.3mf` files are ZIP archives
- Root model at `3D/3dmodel.model` (XML)
- Bambu Studio stores meshes in external files referenced via `<component p:path="/3D/Objects/object_N.model">`
- Build placement via `<build><item objectid="N" transform="..."/>` — 12-float column-major affine transform
- Thumbnails at `Metadata/plate_1.png` (and variants)

## CI/CD

- **test.yml**: runs on push/PR to main
- **release.yml**: runs on tag push (`v*`) — builds, signs, notarizes, creates GitHub release with SLSA provenance, updates Homebrew tap
- **codeql.yml**: CodeQL security scanning on push/PR + weekly
- **dependency-review.yml**: checks for vulnerable deps on PRs

## Don't

- Don't add Co-Authored-By to commits
- Don't use "3MF", "3mf", "three-mf" as the brand name — it's "threemf"
- Don't forget SBOM (`sbom.json`) when adding dependencies
