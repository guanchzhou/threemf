import AppKit
import SceneKit

struct SceneBuilder {
    static func buildScene(from mesh: MeshData) -> SCNScene {
        let scene = SCNScene()

        // Geometry
        let vertexSource = SCNGeometrySource(vertices: mesh.vertices)
        var sources = [vertexSource]
        if let normals = mesh.normals {
            sources.append(SCNGeometrySource(normals: normals))
        }

        let element = SCNGeometryElement(
            indices: mesh.indices,
            primitiveType: .triangles
        )

        let geometry = SCNGeometry(sources: sources, elements: [element])

        // Material
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(white: 0.85, alpha: 1.0)
        material.specular.contents = NSColor(white: 0.3, alpha: 1.0)
        material.shininess = 0.3
        material.lightingModel = .phong
        material.isDoubleSided = true
        geometry.materials = [material]

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
}
