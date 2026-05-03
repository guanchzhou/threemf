# Toolpath formats

How `ThreeMFCore` represents G-code toolpaths.

## Overview

G-code is the line-segment-oriented output of a slicer (Bambu Studio, OrcaSlicer,
PrusaSlicer, Cura, …). Every move is encoded as a `G0` (rapid travel) or `G1`
(extrusion) command with X/Y/Z/E/F parameters.

ThreeMFCore models a parsed G-code file as `ToolpathData`, distinct from `MeshData`
because triangle-oriented mesh structures don't compose well with line-segment
rendering (`SCNGeometryElement(.line)` vs `SCNGeometryElement(.triangles)`).

The pipeline:

```
.gcode → GCodeParser.parse(from:) → ToolpathData → ToolpathSceneBuilder.buildScene → SCNScene
```

## Topics

### G-code parsing

- ``GCodeParser``
- ``GCodeParserError``
- ``ToolpathSegment``
- ``ToolpathData``

### Rendering

- ``ToolpathSceneBuilder``
- ``ToolpathSceneBuilder/ColorMode``

## Color modes

`ToolpathSceneBuilder.ColorMode` controls per-segment vertex colors:

- ``ToolpathSceneBuilder/ColorMode/layerRainbow`` (default) — bottom red → top violet.
  Useful for understanding layer order in tall prints.
- ``ToolpathSceneBuilder/ColorMode/travelVsExtrusion`` — gray for travels, blue for
  extrusion. Use this to spot wasted moves.
- ``ToolpathSceneBuilder/ColorMode/feedrate`` — heatmap by feed rate (slow blue,
  fast red). Use this to find slow areas in a print.
- ``ToolpathSceneBuilder/ColorMode/uniform`` — single accent color. Cleanest view.

## Safety caps

- `GCodeParser.maxFileSize` (500 MB) — input cap before parsing begins.
- `GCodeParser.maxSegments` (20M) — output cap; the parser stops emitting segments
  once it hits this number.

These mirror `STLParser.maxFileSize` / `STLParser.maxTriangles` and bound memory
under crafted-input attack scenarios.
