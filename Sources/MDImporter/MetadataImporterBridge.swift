import CoreFoundation
import Foundation
import simd

/// Spotlight calls our C entrypoint, which calls this. Returns true on success.
/// Populates `attributes` with both standard `kMDItem*` keys and custom
/// `com_andreymaltsev_threemf_*` keys declared in Schema.xml.
@_cdecl("ThreeMFExtractMetadata")
public func ThreeMFExtractMetadata(
    attributes: CFMutableDictionary,
    contentTypeUTI _: CFString,
    pathToFile: CFString
) -> DarwinBoolean {
    // Spotlight (mdworker) calls this once per indexed file across the user's filesystem.
    // Without an autorelease pool, every Foundation/AppKit object created during parse
    // accumulates until the process exits — for a full reindex of a 3D-print library,
    // that's enough to OOM mdworker. Wrap the body explicitly.
    autoreleasepool {
        let path = pathToFile as String
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        // For very large 3MF files, full mesh parse risks mdworker timeout. Take a
        // metadata-only fast path: only scan `<metadata>` tags, emit textual attributes,
        // skip triangle/vertex/bbox stats.
        let largeFastPathThreshold = 50 * 1024 * 1024 // 50 MB
        if ext == "3mf", fileSize > largeFastPathThreshold {
            let attrs = attributes as NSMutableDictionary
            do {
                let md = try ThreeMFMeshParser.parseMetadata(from: url)
                if let app = md?.application {
                    attrs["com_andreymaltsev_threemf_slicer"] = app
                }
                if let designer = md?.designer {
                    attrs[kMDItemAuthors as String] = [designer]
                }
                if let title = md?.title {
                    attrs[kMDItemTitle as String] = title
                }
                attrs[kMDItemDescription as String] = "Large 3MF (\(fileSize) bytes)"
                return true
            } catch {
                // Archive failed to open — broken/encrypted/non-ZIP. mdworker will retry later.
                return false
            }
        }

        // G-code path: emit segment/layer-based custom keys, no triangle stats.
        if ext == "gcode" {
            do {
                let toolpath = try GCodeParser.parse(from: url)
                let attrs = attributes as NSMutableDictionary
                let dims = toolpath.boundingBox.dimensions
                attrs[kMDItemDescription as String] = String(
                    format: "%d layers, %d segments, %.1f × %.1f × %.1f mm",
                    toolpath.layerCount, toolpath.segments.count, dims.x, dims.y, dims.z
                )
                attrs["com_andreymaltsev_threemf_layerCount"] = NSNumber(value: toolpath.layerCount)
                attrs["com_andreymaltsev_threemf_segmentCount"] = NSNumber(value: toolpath.segments.count)
                attrs["com_andreymaltsev_threemf_widthMM"] = NSNumber(value: Double(dims.x))
                attrs["com_andreymaltsev_threemf_depthMM"] = NSNumber(value: Double(dims.y))
                attrs["com_andreymaltsev_threemf_heightMM"] = NSNumber(value: Double(dims.z))
                return true
            } catch {
                return false
            }
        }

        let mesh: MeshData
        do {
            switch ext {
            case "stl":
                mesh = try STLParser.parseMesh(from: url)
            case "3mf":
                mesh = try ThreeMFMeshParser.parseMesh(from: url)
            default:
                return false
            }
        } catch {
            return false
        }

        let triangleCount = mesh.indices.count / 3
        let vertexCount = mesh.vertices.count
        let dims = mesh.boundingBox.dimensions

        let attrs = attributes as NSMutableDictionary

        // Standard Spotlight keys — visible in Finder "Get Info" without a schema entry.
        attrs[kMDItemDescription as String] = String(
            format: "%d triangles, %d vertices, %.1f × %.1f × %.1f mm",
            triangleCount, vertexCount, dims.x, dims.y, dims.z
        )

        // Custom keys (declared in Schema.xml). Spotlight prefixes use underscores.
        attrs["com_andreymaltsev_threemf_triangleCount"] = NSNumber(value: triangleCount)
        attrs["com_andreymaltsev_threemf_vertexCount"] = NSNumber(value: vertexCount)
        attrs["com_andreymaltsev_threemf_widthMM"] = NSNumber(value: Double(dims.x))
        attrs["com_andreymaltsev_threemf_depthMM"] = NSNumber(value: Double(dims.y))
        attrs["com_andreymaltsev_threemf_heightMM"] = NSNumber(value: Double(dims.z))

        if let md = mesh.metadata {
            if let app = md.application {
                attrs["com_andreymaltsev_threemf_slicer"] = app
            }
            if let designer = md.designer {
                attrs[kMDItemAuthors as String] = [designer]
            }
            if let title = md.title {
                attrs[kMDItemTitle as String] = title
            }
        }

        return true
    }
}
