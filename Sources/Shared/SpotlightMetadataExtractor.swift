import CoreServices
import Foundation

/// Shared Spotlight attribute population for `.3mf`, `.stl`, and `.gcode`. Used by the
/// mdimporter bridge and unit tests.
enum SpotlightMetadataExtractor {
    /// Returns `true` when attributes were populated (including lightweight large-file stubs).
    /// Returns `false` when the file type is unsupported or parsing failed irrecoverably.
    static func populate(attributes: NSMutableDictionary, fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        guard let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            // Fail closed: an unreadable size must never select the full-parse path.
            return false
        }
        let large = fileSize > SpotlightIndexing.largeFileFastPathByteCount

        if ext == "3mf", large {
            return populateLarge3MF(attributes: attributes, fileURL: fileURL, fileSize: fileSize)
        }
        if ext == "gcode", large {
            return populateLargeGCode(attributes: attributes, fileSize: fileSize)
        }
        if ext == "stl", large {
            return populateLargeSTL(attributes: attributes, fileSize: fileSize)
        }

        if ext == "gcode" {
            return populateGCode(attributes: attributes, fileURL: fileURL)
        }

        let mesh: MeshData
        do {
            switch ext {
            case "stl":
                mesh = try STLParser.parseMesh(from: fileURL, limits: .spotlight, computesNormals: false)
            case "3mf":
                mesh = try ThreeMFMeshParser.parseMesh(from: fileURL, limits: .spotlight, computesNormals: false)
            default:
                return false
            }
        } catch {
            return false
        }
        populateMesh(attributes: attributes, mesh: mesh)
        return true
    }

    private static func populateLarge3MF(
        attributes: NSMutableDictionary,
        fileURL: URL,
        fileSize: Int
    ) -> Bool {
        do {
            let md = try ThreeMFMeshParser.parseMetadata(from: fileURL, limits: .spotlight)
            if let app = md?.application {
                attributes["com_andreymaltsev_threemf_slicer"] = app
            }
            if let designer = md?.designer {
                attributes[kMDItemAuthors as String] = [designer]
            }
            if let title = md?.title {
                attributes[kMDItemTitle as String] = title
            }
            attributes[kMDItemDescription as String] = "Large 3MF (\(fileSize) bytes)"
            return true
        } catch {
            return false
        }
    }

    private static func populateLargeGCode(attributes: NSMutableDictionary, fileSize: Int) -> Bool {
        attributes[kMDItemDescription as String] = "Large G-code (\(fileSize) bytes)"
        return true
    }

    private static func populateLargeSTL(attributes: NSMutableDictionary, fileSize: Int) -> Bool {
        attributes[kMDItemDescription as String] = "Large STL (\(fileSize) bytes)"
        return true
    }

    private static func populateGCode(attributes: NSMutableDictionary, fileURL: URL) -> Bool {
        do {
            let toolpath = try GCodeParser.parse(from: fileURL, limits: .spotlight)
            let dims = toolpath.boundingBox.dimensions
            attributes[kMDItemDescription as String] = String(
                format: "%d layers, %d segments, %.1f × %.1f × %.1f mm",
                toolpath.layerCount, toolpath.segments.count, dims.x, dims.y, dims.z
            )
            attributes["com_andreymaltsev_threemf_layerCount"] = NSNumber(value: toolpath.layerCount)
            attributes["com_andreymaltsev_threemf_segmentCount"] = NSNumber(value: toolpath.segments.count)
            attributes["com_andreymaltsev_threemf_widthMM"] = NSNumber(value: Double(dims.x))
            attributes["com_andreymaltsev_threemf_depthMM"] = NSNumber(value: Double(dims.y))
            attributes["com_andreymaltsev_threemf_heightMM"] = NSNumber(value: Double(dims.z))
            return true
        } catch {
            return false
        }
    }

    private static func populateMesh(attributes: NSMutableDictionary, mesh: MeshData) {
        let triangleCount = mesh.indices.count / 3
        let vertexCount = mesh.vertices.count
        let dims = mesh.boundingBox.dimensions

        attributes[kMDItemDescription as String] = String(
            format: "%d triangles, %d vertices, %.1f × %.1f × %.1f mm",
            triangleCount, vertexCount, dims.x, dims.y, dims.z
        )
        attributes["com_andreymaltsev_threemf_triangleCount"] = NSNumber(value: triangleCount)
        attributes["com_andreymaltsev_threemf_vertexCount"] = NSNumber(value: vertexCount)
        attributes["com_andreymaltsev_threemf_widthMM"] = NSNumber(value: Double(dims.x))
        attributes["com_andreymaltsev_threemf_depthMM"] = NSNumber(value: Double(dims.y))
        attributes["com_andreymaltsev_threemf_heightMM"] = NSNumber(value: Double(dims.z))

        if let md = mesh.metadata {
            if let app = md.application {
                attributes["com_andreymaltsev_threemf_slicer"] = app
            }
            if let designer = md.designer {
                attributes[kMDItemAuthors as String] = [designer]
            }
            if let title = md.title {
                attributes[kMDItemTitle as String] = title
            }
        }
    }
}
