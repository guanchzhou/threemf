import AppKit
import SceneKit
import simd

public enum SceneBuilder {
    public static func buildScene(from mesh: MeshData) -> SCNScene {
        let scene = SCNScene()

        // Geometry: build SCNGeometrySource directly from the simd_float3 buffer
        // (stride = 16 bytes, components = 3 × Float = 12 bytes; SceneKit handles padding).
        let vertexSource = makeFloatSource(mesh.vertices, semantic: .vertex)
        var sources = [vertexSource]
        if let normals = mesh.normals, !normals.isEmpty {
            sources.append(makeFloatSource(normals, semantic: .normal))
        }

        // Build elements: one per material when triangleMaterials is set, else a single element.
        let elements = makeElements(mesh: mesh)
        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = makeMaterials(mesh: mesh, elementCount: elements.count)

        // Model node
        let modelNode = SCNNode(geometry: geometry)

        // 3D printing models use Z-up, SceneKit uses Y-up — rotate -90° around X
        modelNode.eulerAngles.x = -.pi / 2

        scene.rootNode.addChildNode(modelNode)

        // Center and scale (after rotation)
        let (minBound, maxBound) = modelNode.boundingBox
        let center = SCNVector3(
            (minBound.x + maxBound.x) / 2,
            (minBound.y + maxBound.y) / 2,
            (minBound.z + maxBound.z) / 2
        )
        modelNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)

        let size = SCNVector3(
            maxBound.x - minBound.x,
            maxBound.y - minBound.y,
            maxBound.z - minBound.z
        )
        let maxDim = max(size.x, size.y, size.z)
        let normalizeScale: Float = maxDim > 0 ? 2.0 / Float(maxDim) : 1.0
        modelNode.scale = SCNVector3(normalizeScale, normalizeScale, normalizeScale)

        // Camera — front-right, slightly above (classic 3/4 view). The distance is fitted
        // to the model's silhouette so it fills ~90% of the frame, rather than a fixed
        // position that over-margins non-cubic models (e.g. tall/flat parts).
        let halfExtents = simd_float3(Float(size.x), Float(size.y), Float(size.z)) * (0.5 * normalizeScale)
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true
        // Pin the FOV to the vertical axis so framing is aspect-independent: the preview
        // pane is landscape, so vertical is the limiting dimension.
        cameraNode.camera?.projectionDirection = .vertical
        cameraNode.camera?.fieldOfView = 45
        cameraNode.position = fittedCameraPosition(
            halfExtents: halfExtents,
            direction: simd_float3(-2.5, 1.5, 4),
            fovDegrees: 45,
            fill: 0.9
        )
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 400
        ambientLight.light?.color = NSColor(white: 1.0, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        // Key light — from upper right
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 800
        keyLight.light?.color = NSColor(white: 1.0, alpha: 1.0)
        keyLight.position = SCNVector3(5, 8, 5)
        keyLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyLight)

        // Fill light — from lower left
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.intensity = 300
        fillLight.light?.color = NSColor(white: 1.0, alpha: 1.0)
        fillLight.position = SCNVector3(-4, -2, 3)
        fillLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillLight)

        // Background
        scene.background.contents = NSColor.windowBackgroundColor

        return scene
    }

    // MARK: - Helpers

    /// Camera position along `direction` (from the origin, where the centered model sits)
    /// that frames a box of the given half-extents so its view-plane silhouette fills
    /// roughly `fill` of the vertical field of view.
    ///
    /// Aspect-independent: it fits the smallest enclosing circle of the box's corners in
    /// the plane perpendicular to the view direction, so the result never clips vertically
    /// regardless of the pane's aspect ratio (the camera uses a `.vertical` projection).
    static func fittedCameraPosition(
        halfExtents h: simd_float3,
        direction: simd_float3,
        fovDegrees: Float,
        fill: Float
    ) -> SCNVector3 {
        let dir = simd_length(direction) > 0 ? simd_normalize(direction) : simd_float3(0, 0, 1)
        // Radius of the enclosing circle in the view plane: the largest perpendicular
        // distance from the view axis to any of the 8 box corners.
        var rPerp: Float = 0
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    let corner = simd_float3(sx * h.x, sy * h.y, sz * h.z)
                    let along = simd_dot(corner, dir)
                    rPerp = max(rPerp, simd_length(corner - along * dir))
                }
            }
        }
        guard rPerp > 0 else { return SCNVector3(dir.x, dir.y, dir.z) }
        let halfFOV = (fovDegrees * .pi / 180) / 2
        // Clamp the usable angle so a degenerate fill never divides by ~0.
        let usable = max(0.05, tan(halfFOV * min(max(fill, 0.1), 1.0)))
        let dist = rPerp / usable
        return SCNVector3(dir.x * dist, dir.y * dist, dir.z * dist)
    }

    /// Wrap a `[simd_float3]` buffer as an SCNGeometrySource without per-vertex copies.
    /// stride = 16 (simd_float3 is 16-byte aligned); SceneKit reads the first 12 bytes per stride.
    private static func makeFloatSource(
        _ buffer: [simd_float3],
        semantic: SCNGeometrySource.Semantic
    ) -> SCNGeometrySource {
        let stride = MemoryLayout<simd_float3>.stride
        let data = buffer.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(
            data: data,
            semantic: semantic,
            vectorCount: buffer.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0,
            dataStride: stride
        )
    }

    /// Returns one SCNGeometryElement per material when `triangleMaterials` is set,
    /// else a single element covering all triangles.
    private static func makeElements(mesh: MeshData) -> [SCNGeometryElement] {
        let triCount = mesh.indices.count / 3
        guard !mesh.triangleMaterials.isEmpty,
              mesh.triangleMaterials.count == triCount,
              !mesh.materials.isEmpty
        else {
            return [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)]
        }

        // Group triangles by material index. -1 (default) becomes its own group.
        var groups: [Int: [UInt32]] = [:]
        for t in 0 ..< triCount {
            let m = mesh.triangleMaterials[t]
            let i0 = mesh.indices[t * 3]
            let i1 = mesh.indices[t * 3 + 1]
            let i2 = mesh.indices[t * 3 + 2]
            groups[m, default: []].append(contentsOf: [i0, i1, i2])
        }

        // Stable order: default group (-1) first, then materials in ascending order.
        let orderedKeys = groups.keys.sorted { a, b in
            if a == -1 { return true }
            if b == -1 { return false }
            return a < b
        }

        return orderedKeys.compactMap { key in
            guard let idx = groups[key], !idx.isEmpty else { return nil }
            return SCNGeometryElement(indices: idx, primitiveType: .triangles)
        }
    }

    /// Materials in the same order as elements emitted by `makeElements`.
    private static func makeMaterials(mesh: MeshData, elementCount _: Int) -> [SCNMaterial] {
        let defaultMaterial = makeDefaultMaterial()

        guard !mesh.triangleMaterials.isEmpty, !mesh.materials.isEmpty else {
            return [defaultMaterial]
        }

        // Re-derive ordered keys the same way `makeElements` did.
        var seen = Set<Int>()
        var orderedKeys: [Int] = []
        if mesh.triangleMaterials.contains(-1) {
            seen.insert(-1)
            orderedKeys.append(-1)
        }
        for m in mesh.triangleMaterials.sorted() where m >= 0 {
            if seen.insert(m).inserted { orderedKeys.append(m) }
        }

        return orderedKeys.map { key in
            if key == -1 { return defaultMaterial }
            guard key < mesh.materials.count, let color = mesh.materials[key].color else {
                return defaultMaterial
            }
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(
                srgbRed: CGFloat(color.x),
                green: CGFloat(color.y),
                blue: CGFloat(color.z),
                alpha: CGFloat(color.w)
            )
            mat.specular.contents = NSColor(white: 0.3, alpha: 1.0)
            mat.shininess = 0.3
            mat.lightingModel = .phong
            mat.isDoubleSided = true
            return mat
        }
    }

    /// Builds an XYZ axis gizmo (3 colored cylinders + spheres at the origin).
    /// Caller decides where to place it; the node is sized to ~0.4 units.
    public static func makeAxisGizmoNode() -> SCNNode {
        let root = SCNNode()
        root.name = "axisGizmo"
        let length: CGFloat = 0.4
        let radius: CGFloat = 0.012
        let halfF = Float(length) / 2
        let halfPi: Float = .pi / 2
        struct AxisSpec { let axis: simd_float3; let color: NSColor; let euler: SCNVector3 }
        let specs: [AxisSpec] = [
            AxisSpec(
                axis: simd_float3(1, 0, 0),
                color: .systemRed,
                euler: SCNVector3(0, 0, -halfPi)
            ),
            AxisSpec(
                axis: simd_float3(0, 1, 0),
                color: .systemGreen,
                euler: SCNVector3(0, 0, 0)
            ),
            AxisSpec(
                axis: simd_float3(0, 0, 1),
                color: .systemBlue,
                euler: SCNVector3(halfPi, 0, 0)
            ),
        ]
        for spec in specs {
            let cylinder = SCNCylinder(radius: radius, height: length)
            let mat = SCNMaterial()
            mat.diffuse.contents = spec.color
            mat.lightingModel = .constant
            cylinder.firstMaterial = mat
            let node = SCNNode(geometry: cylinder)
            node.eulerAngles = spec.euler
            // Translate halfway along the axis so the cylinder starts at origin.
            node.position = SCNVector3(spec.axis.x * halfF, spec.axis.y * halfF, spec.axis.z * halfF)
            root.addChildNode(node)
        }
        return root
    }

    /// Builds a wireframe grid plane representing the print bed.
    /// `extent` is half-width per side; `divisions` controls density.
    public static func makeBedGridNode(extent: Float = 1.2, divisions: Int = 12) -> SCNNode {
        let root = SCNNode()
        root.name = "bedGrid"
        let step = (extent * 2) / Float(divisions)
        var verts: [simd_float3] = []
        var idx: [UInt32] = []
        for i in 0 ... divisions {
            let v = -extent + Float(i) * step
            // X-aligned line
            verts.append(simd_float3(-extent, 0, v))
            verts.append(simd_float3(extent, 0, v))
            // Z-aligned line
            verts.append(simd_float3(v, 0, -extent))
            verts.append(simd_float3(v, 0, extent))
        }
        for i in 0 ..< UInt32(verts.count) {
            idx.append(i)
        }

        let stride = MemoryLayout<simd_float3>.stride
        let data = verts.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = SCNGeometrySource(
            data: data,
            semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0,
            dataStride: stride
        )
        let element = SCNGeometryElement(indices: idx, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor.tertiaryLabelColor
        mat.lightingModel = .constant
        geometry.firstMaterial = mat
        let node = SCNNode(geometry: geometry)
        // Place the grid just below the model's bottom (model is normalized to ±1).
        node.position = SCNVector3(0, -1, 0)
        root.addChildNode(node)
        return root
    }

    private static func makeDefaultMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(white: 0.85, alpha: 1.0)
        material.specular.contents = NSColor(white: 0.3, alpha: 1.0)
        material.shininess = 0.3
        material.lightingModel = .phong
        material.isDoubleSided = true
        return material
    }
}
