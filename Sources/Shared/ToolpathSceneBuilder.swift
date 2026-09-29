import AppKit
import SceneKit
import simd

/// Builds an SCNScene from `ToolpathData`. Each layer is a child node under the
/// `toolpath` parent with its own line-primitive SCNGeometry. Lights/camera mirror
/// `SceneBuilder.buildScene`.
public enum ToolpathSceneBuilder {
    /// How segments are colored in the rendered scene.
    public enum ColorMode: Sendable, Hashable {
        /// Layer-index rainbow (default). Bottom = red, top = violet.
        case layerRainbow
        /// Travel moves gray, extrusion moves accent-colored.
        case travelVsExtrusion
        /// Heatmap by feedrate: slow = blue, fast = red.
        case feedrate
        /// Single accent color regardless of segment role.
        case uniform
    }

    private static let layerNodePrefix = "layer-"

    public static func buildScene(
        from toolpath: ToolpathData,
        colorMode: ColorMode = .layerRainbow,
        visibleLayers: ClosedRange<Int>? = nil
    ) -> SCNScene {
        let scene = SCNScene()
        let modelNode = SCNNode()
        modelNode.name = "toolpath"

        addLayerNodes(to: modelNode, toolpath: toolpath, colorMode: colorMode)
        if let range = visibleLayers {
            for child in modelNode.childNodes {
                guard let idx = layerIndex(from: child) else { continue }
                child.isHidden = !range.contains(idx)
            }
        }

        // 3D-print Z-up to SceneKit Y-up.
        modelNode.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(modelNode)

        // Center + scale to ±1 to match the rest of the app's framing convention.
        let (lo, hi) = (toolpath.boundingBox.min, toolpath.boundingBox.max)
        let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        modelNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        let dims = hi - lo
        let maxDim = max(dims.x, max(dims.y, dims.z))
        let normalizeScale: Float = maxDim > 0 ? 2.0 / maxDim : 1.0
        modelNode.scale = SCNVector3(normalizeScale, normalizeScale, normalizeScale)

        // Camera (3/4 view, matching SceneBuilder.buildScene defaults) with the same
        // silhouette-fitted distance so framing is consistent across mesh and toolpath.
        let halfExtents = dims * (0.5 * normalizeScale)
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true
        cameraNode.camera?.projectionDirection = .vertical
        cameraNode.camera?.fieldOfView = 45
        cameraNode.position = SceneBuilder.fittedCameraPosition(
            halfExtents: halfExtents,
            direction: simd_float3(-2.5, 1.5, 4),
            fovDegrees: 45,
            fill: 0.9
        )
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Lights — toolpath geometry uses constant lighting so this is mostly cosmetic
        // for the background, but we keep them for parity with mesh scenes.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 600
        scene.rootNode.addChildNode(ambient)

        scene.background.contents = NSColor.windowBackgroundColor
        return scene
    }

    /// Builds a top-down camera scene suitable for thumbnail rendering.
    public static func buildTopDownScene(
        from toolpath: ToolpathData,
        colorMode: ColorMode = .layerRainbow
    ) -> SCNScene {
        let scene = buildScene(from: toolpath, colorMode: colorMode)
        if let cam = scene.rootNode.childNode(withName: "camera", recursively: true) {
            cam.position = SCNVector3(0, 5, 0.001)
            cam.look(at: SCNVector3(0, 0, 0))
        }
        return scene
    }

    /// Shows layers with `layerIndex <= layer` and hides the rest. Does not rebuild geometry.
    public static func setVisibleLayers(through layer: Int, on modelNode: SCNNode) {
        for child in modelNode.childNodes {
            guard let idx = layerIndex(from: child) else { continue }
            child.isHidden = idx > layer
        }
    }

    /// Rebuilds each layer child's line geometry with a new color mode. Preserves `isHidden`.
    public static func applyColorMode(
        _ colorMode: ColorMode,
        to modelNode: SCNNode,
        toolpath: ToolpathData
    ) {
        let layerCount = max(1, toolpath.layerCount)
        let (minFeed, maxFeed) = feedrateBounds(toolpath.segments)
        let grouped = segmentsByLayer(toolpath.segments)
        for child in modelNode.childNodes {
            guard let idx = layerIndex(from: child) else { continue }
            let segs = grouped[idx] ?? []
            child.geometry = makeGeometry(
                segments: segs,
                colorMode: colorMode,
                layerCount: layerCount,
                minFeed: minFeed,
                maxFeed: maxFeed
            )
        }
    }

    // MARK: - Internals

    /// Builds just the line-primitive geometry. Public for callers that want a single
    /// combined geometry (e.g. tests). Interactive preview uses per-layer nodes instead.
    public static func makeGeometry(
        toolpath: ToolpathData,
        colorMode: ColorMode,
        visibleLayers: ClosedRange<Int>?
    ) -> SCNGeometry {
        let filtered: [ToolpathSegment] = if let range = visibleLayers {
            toolpath.segments.filter { range.contains($0.layerIndex) }
        } else {
            toolpath.segments
        }
        let (minFeed, maxFeed) = feedrateBounds(filtered)
        return makeGeometry(
            segments: filtered,
            colorMode: colorMode,
            layerCount: max(1, toolpath.layerCount),
            minFeed: minFeed,
            maxFeed: maxFeed
        )
    }

    private static func addLayerNodes(
        to modelNode: SCNNode,
        toolpath: ToolpathData,
        colorMode: ColorMode
    ) {
        let layerCount = max(1, toolpath.layerCount)
        let (minFeed, maxFeed) = feedrateBounds(toolpath.segments)
        let grouped = segmentsByLayer(toolpath.segments)
        for layerIndex in grouped.keys.sorted() {
            let segs = grouped[layerIndex] ?? []
            let child = SCNNode(
                geometry: makeGeometry(
                    segments: segs,
                    colorMode: colorMode,
                    layerCount: layerCount,
                    minFeed: minFeed,
                    maxFeed: maxFeed
                )
            )
            child.name = layerNodeName(for: layerIndex)
            modelNode.addChildNode(child)
        }
    }

    private static func segmentsByLayer(_ segments: [ToolpathSegment]) -> [Int: [ToolpathSegment]] {
        var grouped: [Int: [ToolpathSegment]] = [:]
        for seg in segments {
            grouped[seg.layerIndex, default: []].append(seg)
        }
        return grouped
    }

    private static func feedrateBounds(_ segments: [ToolpathSegment]) -> (Float, Float) {
        let maxFeed = segments.map(\.feedrate).max() ?? 1
        let minFeed = segments.map(\.feedrate).filter { $0 > 0 }.min() ?? 1
        return (minFeed, maxFeed)
    }

    private static func layerNodeName(for index: Int) -> String {
        "\(layerNodePrefix)\(index)"
    }

    private static func layerIndex(from node: SCNNode) -> Int? {
        guard let name = node.name, name.hasPrefix(layerNodePrefix) else { return nil }
        return Int(name.dropFirst(layerNodePrefix.count))
    }

    private static func makeGeometry(
        segments: [ToolpathSegment],
        colorMode: ColorMode,
        layerCount: Int,
        minFeed: Float,
        maxFeed: Float
    ) -> SCNGeometry {
        var verts: [simd_float3] = []
        verts.reserveCapacity(segments.count * 2)
        var colors: [simd_float3] = []
        colors.reserveCapacity(segments.count * 2)
        var indices: [UInt32] = []
        indices.reserveCapacity(segments.count * 2)

        for (i, seg) in segments.enumerated() {
            verts.append(seg.start)
            verts.append(seg.end)
            indices.append(UInt32(i * 2))
            indices.append(UInt32(i * 2 + 1))
            let color = pickColor(
                segment: seg,
                colorMode: colorMode,
                layerCount: layerCount,
                minFeed: minFeed,
                maxFeed: maxFeed
            )
            colors.append(color)
            colors.append(color)
        }

        let stride = MemoryLayout<simd_float3>.stride
        let vertData = verts.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertSource = SCNGeometrySource(
            data: vertData,
            semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0,
            dataStride: stride
        )

        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0,
            dataStride: stride
        )

        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [vertSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        geometry.firstMaterial = material
        return geometry
    }

    private static func pickColor(
        segment: ToolpathSegment,
        colorMode: ColorMode,
        layerCount: Int,
        minFeed: Float,
        maxFeed: Float
    ) -> simd_float3 {
        switch colorMode {
        case .layerRainbow:
            let t = layerCount > 1 ? Float(segment.layerIndex) / Float(layerCount - 1) : 0
            return rainbow(t: t)
        case .travelVsExtrusion:
            return segment.extrudes
                ? simd_float3(0.2, 0.6, 1.0) // accent blue
                : simd_float3(0.5, 0.5, 0.5) // gray
        case .feedrate:
            let f = segment.feedrate
            guard f > 0, maxFeed > minFeed else { return simd_float3(0.5, 0.5, 0.5) }
            let t = (f - minFeed) / (maxFeed - minFeed)
            return simd_float3(t, 0.4, 1 - t)
        case .uniform:
            return simd_float3(0.2, 0.6, 1.0)
        }
    }

    /// HSV-style rainbow gradient with `t` in `[0,1]` mapping red→violet.
    private static func rainbow(t: Float) -> simd_float3 {
        let h = t * 0.83 // stop before wrapping back to red
        let s: Float = 0.9
        let v: Float = 0.95
        let c = v * s
        let hPrime = h * 6
        let x = c * (1 - abs(fmod(hPrime, 2) - 1))
        let m = v - c
        let r: Float, g: Float, b: Float
        switch Int(hPrime) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return simd_float3(r + m, g + m, b + m)
    }
}
