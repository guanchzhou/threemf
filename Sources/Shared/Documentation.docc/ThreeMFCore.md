# ``ThreeMFCore``

Parse `.3mf` and `.stl` files, render them to SceneKit scenes, and extract metadata.

## Overview

`ThreeMFCore` is the parsing + rendering core that powers the threemf macOS app, its Quick
Look extensions, its Spotlight Importer, its Finder Sync extension, and its CLI. The library
is also published as a standalone Swift Package so other tools can use the same parsers and
scene builder.

The library is organized around a small handful of public types:

- ``MeshData`` — vertex/index/normal/material data structure with computed `boundingBox`,
  `volume`, and `statistics()` helpers.
- ``STLParser`` — binary and ASCII STL parsing. Auto-detects format via `solid` magic prefix
  with binary fallback. Multi-core path activates at ≥100K triangles.
- ``ThreeMFMeshParser`` — 3MF (XML inside ZIP) parsing. Handles components with `p:path`
  references, build items with affine transforms, basematerials with hex colors. Has a
  metadata-only fast path (`parseMetadata(from:)`) for Spotlight indexing.
- ``ThreeMFExtractor`` — embedded thumbnail extraction, multi-plate listing, Bambu/Orca
  per-plate JSON parsing.
- ``SceneBuilder`` — turns ``MeshData`` into an SCNScene with lights, camera, axis gizmo,
  and bed grid helpers.
- ``ThumbnailCache`` — disk-backed PNG cache keyed by `(SHA256(path), size, mtime)`. Used
  by the thumbnail extension and CLI `--cache` flag.
- ``BambuPlateInfo`` — parsed Bambu Studio / OrcaSlicer per-plate metadata (filament weight,
  print time, machine model).

## Topics

### Parsing

- ``STLParser``
- ``ThreeMFMeshParser``
- ``ThreeMFExtractor``

### Data Model

- ``MeshData``
- ``BoundingBox``
- ``BaseMaterial``
- ``ThreeMFMetadata``
- ``BambuPlateInfo``

### Rendering

- ``SceneBuilder``

### Caching

- ``ThumbnailCache``

### Errors

- ``STLParserError``
- ``ThreeMFMeshParserError``
- ``ThreeMFExtractorError``

## Distribution

The threemf macOS app bundle ships at ``com.andreymaltsev.3mf-quicklook`` via Homebrew
(`brew install --cask guanchzhou/tap/threemf`). Quick Look + Spotlight + Finder Sync
extensions are embedded in the .app and registered on first launch. The `threemf-cli`
executable is a separate Swift Package product.

Source: <https://github.com/guanchzhou/threemf>
License: MIT
