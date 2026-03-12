import Foundation
import SceneKit
import ZIPFoundation

enum ThreeMFMeshParserError: Error, LocalizedError {
    case cannotOpenArchive
    case modelNotFound
    case parseFailed
    case noMeshData

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive: return "Cannot open .3mf archive"
        case .modelNotFound: return "3D model not found in .3mf archive"
        case .parseFailed: return "Failed to parse 3D model XML"
        case .noMeshData: return "No mesh data found in 3D model"
        }
    }
}

struct ThreeMFMeshParser {
    private static let modelPaths = [
        "3D/3dmodel.model",
        "3D/3DModel.model",
        "3d/3dmodel.model",
    ]

    static func parseMesh(from fileURL: URL) throws -> MeshData {
        guard let archive = Archive(url: fileURL, accessMode: .read) else {
            throw ThreeMFMeshParserError.cannotOpenArchive
        }

        var modelData: Data?
        for path in modelPaths {
            if let entry = archive[path] {
                var data = Data()
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
                if !data.isEmpty {
                    modelData = data
                    break
                }
            }
        }

        guard let xmlData = modelData else {
            throw ThreeMFMeshParserError.modelNotFound
        }

        // Parse root model
        let rootDelegate = ThreeMFXMLDelegate()
        let parser = XMLParser(data: xmlData)
        parser.delegate = rootDelegate
        _ = parser.parse()

        // Build a map of object ID -> (component path, component transform)
        // and object ID -> inline mesh vertices/indices
        // Then resolve build items with their transforms

        // Parse each external component file into its own mesh
        var objectMeshes: [String: (vertices: [SCNVector3], indices: [UInt32])] = [:]

        // Inline meshes from root (keyed by object ID)
        for (objId, mesh) in rootDelegate.objectMeshes {
            objectMeshes[objId] = mesh
        }

        // External component meshes
        for comp in rootDelegate.components {
            let normalized = comp.path.hasPrefix("/") ? String(comp.path.dropFirst()) : comp.path
            if objectMeshes[comp.objectId] != nil { continue }

            if let entry = archive[normalized] {
                var data = Data()
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
                if !data.isEmpty {
                    let compDelegate = ThreeMFXMLDelegate()
                    let compParser = XMLParser(data: data)
                    compParser.delegate = compDelegate
                    _ = compParser.parse()
                    // Use the first mesh found in this file
                    for (_, mesh) in compDelegate.objectMeshes {
                        objectMeshes[comp.objectId] = mesh
                        break
                    }
                }
            }
        }

        // Now assemble: use build items (with transforms) if available,
        // otherwise just merge all meshes
        var allVertices: [SCNVector3] = []
        var allIndices: [UInt32] = []

        if !rootDelegate.buildItems.isEmpty {
            // Only include objects referenced in build items
            for item in rootDelegate.buildItems {
                // Resolve object: might reference an object that has components
                let meshObjId = resolveObjectMesh(
                    objectId: item.objectId,
                    components: rootDelegate.components,
                    objectMeshes: objectMeshes
                )
                guard let mesh = objectMeshes[meshObjId] else { continue }

                let baseOffset = UInt32(allVertices.count)
                let transform = item.transform

                // Apply transform to vertices
                for v in mesh.vertices {
                    let tv = applyTransform(v, transform)
                    allVertices.append(tv)
                }
                for idx in mesh.indices {
                    allIndices.append(idx + baseOffset)
                }
            }
        } else {
            // No build section — just merge all meshes
            for (_, mesh) in objectMeshes {
                let baseOffset = UInt32(allVertices.count)
                allVertices.append(contentsOf: mesh.vertices)
                for idx in mesh.indices {
                    allIndices.append(idx + baseOffset)
                }
            }
        }

        guard !allVertices.isEmpty, !allIndices.isEmpty else {
            throw ThreeMFMeshParserError.noMeshData
        }

        var mesh = MeshData(vertices: allVertices, indices: allIndices, normals: nil)
        mesh.computeNormals()
        return mesh
    }

    /// Resolve an object ID to the actual mesh object ID by following component references
    private static func resolveObjectMesh(
        objectId: String,
        components: [ComponentRef],
        objectMeshes: [String: (vertices: [SCNVector3], indices: [UInt32])]
    ) -> String {
        // If this object has a direct mesh, use it
        if objectMeshes[objectId] != nil {
            return objectId
        }
        // Otherwise, find a component that belongs to this object's parent
        for comp in components {
            if comp.parentObjectId == objectId, objectMeshes[comp.objectId] != nil {
                return comp.objectId
            }
        }
        return objectId
    }
}

struct ComponentRef {
    let parentObjectId: String
    let objectId: String
    let path: String
    let transform: [Float]
}

struct BuildItem {
    let objectId: String
    let transform: [Float] // 12 floats: 3x3 rotation + 3 translation (column-major)
}

private func applyTransform(_ v: SCNVector3, _ m: [Float]) -> SCNVector3 {
    let vx = Float(v.x)
    let vy = Float(v.y)
    let vz = Float(v.z)
    let x = (m[0] * vx) + (m[3] * vy) + (m[6] * vz) + m[9]
    let y = (m[1] * vx) + (m[4] * vy) + (m[7] * vz) + m[10]
    let z = (m[2] * vx) + (m[5] * vy) + (m[8] * vz) + m[11]
    return SCNVector3(x, y, z)
}

private func parseTransform(_ str: String) -> [Float] {
    let parts = str.split(separator: " ").compactMap { Float($0) }
    guard parts.count == 12 else {
        return [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0] // identity
    }
    return parts
}

private class ThreeMFXMLDelegate: NSObject, XMLParserDelegate {
    var objectMeshes: [String: (vertices: [SCNVector3], indices: [UInt32])] = [:]
    var components: [ComponentRef] = []
    var buildItems: [BuildItem] = []

    private var currentObjectId: String?
    private var currentVertices: [SCNVector3] = []
    private var currentIndices: [UInt32] = []
    private var inMesh = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = elementName.lowercased()
            .replacingOccurrences(of: "^[^:]+:", with: "", options: .regularExpression)

        switch name {
        case "object":
            currentObjectId = attributes["id"]
            currentVertices = []
            currentIndices = []

        case "mesh":
            inMesh = true

        case "vertex" where inMesh:
            if let xs = attributes["x"], let ys = attributes["y"], let zs = attributes["z"],
               let x = Float(xs), let y = Float(ys), let z = Float(zs) {
                currentVertices.append(SCNVector3(x, y, z))
            }

        case "triangle" where inMesh:
            if let v1s = attributes["v1"], let v2s = attributes["v2"], let v3s = attributes["v3"],
               let v1 = UInt32(v1s), let v2 = UInt32(v2s), let v3 = UInt32(v3s) {
                currentIndices.append(v1)
                currentIndices.append(v2)
                currentIndices.append(v3)
            }

        case "component":
            if let parentId = currentObjectId,
               let objId = attributes["objectid"] {
                let path = attributes["p:path"] ?? attributes["path"] ?? ""
                let transformStr = attributes["transform"] ?? "1 0 0 0 1 0 0 0 1 0 0 0"
                components.append(ComponentRef(
                    parentObjectId: parentId,
                    objectId: objId,
                    path: path,
                    transform: parseTransform(transformStr)
                ))
            }

        case "item":
            if let objId = attributes["objectid"] {
                let transformStr = attributes["transform"] ?? "1 0 0 0 1 0 0 0 1 0 0 0"
                buildItems.append(BuildItem(
                    objectId: objId,
                    transform: parseTransform(transformStr)
                ))
            }

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = elementName.lowercased()
            .replacingOccurrences(of: "^[^:]+:", with: "", options: .regularExpression)

        switch name {
        case "mesh":
            inMesh = false

        case "object":
            if let objId = currentObjectId, !currentVertices.isEmpty {
                objectMeshes[objId] = (vertices: currentVertices, indices: currentIndices)
            }
            currentObjectId = nil

        default:
            break
        }
    }
}
