import AppKit
import SceneKit
import simd

struct SceneBuilder {
    static func buildScene(from mesh: MeshData) -> SCNScene {
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
        if maxDim > 0 {
            let scale = 2.0 / Float(maxDim)
            modelNode.scale = SCNVector3(scale, scale, scale)
        }

        // Camera — front-right, slightly above (classic 3/4 view)
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true
        cameraNode.camera?.fieldOfView = 45
        cameraNode.position = SCNVector3(-2.5, 1.5, 4)
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

    /// Wrap a `[simd_float3]` buffer as an SCNGeometrySource without per-vertex copies.
    /// stride = 16 (simd_float3 is 16-byte aligned); SceneKit reads the first 12 bytes per stride.
    private static func makeFloatSource(_ buffer: [simd_float3], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
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
        for t in 0..<triCount {
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
    private static func makeMaterials(mesh: MeshData, elementCount: Int) -> [SCNMaterial] {
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
