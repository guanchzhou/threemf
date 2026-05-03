import AppKit
import Foundation
import SceneKit
import simd
#if canImport(ThreeMFCore)
    import ThreeMFCore
#endif

enum CLIError: Error, LocalizedError {
    case unsupportedFormat(String)
    case fileNotFound(String)
    case thumbnailEncodingFailed
    case rendererCreationFailed

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(ext):
            "Unsupported file format: .\(ext) (expected .3mf or .stl)"
        case let .fileNotFound(path):
            "File not found: \(path)"
        case .thumbnailEncodingFailed:
            "Failed to encode thumbnail PNG"
        case .rendererCreationFailed:
            "Failed to create SceneKit renderer"
        }
    }
}

enum CLI {
    static func printUsage() {
        let usage = """
        threemf-cli — headless thumbnail/info for .3mf and .stl files

        Usage:
          threemf-cli info <file>
          threemf-cli validate <file>
          threemf-cli thumbnail <input> <output.png> [--size N] [--cache]
          threemf-cli batch info <files...>
          threemf-cli batch validate <files...>

        Commands:
          info        Print JSON with format, triangle count, vertex count,
                      bounding box, materials, and 3MF metadata when present.
          validate    Parse the file and print PASS/FAIL. Exit 0 on success.
          thumbnail   Render a 3D thumbnail PNG (default size 512).
          batch       Run 'info' or 'validate' across many files in parallel.
                      Output is JSONL (one JSON object per line) for 'info'
                      and PASS/FAIL lines for 'validate'.

        Flags:
          --cache     For 'thumbnail': read/write the shared ThumbnailCache so
                      repeated invocations reuse a previously rendered PNG.
        """
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
    }

    /// Runs `info` or `validate` across many files concurrently. Output is JSONL for info
    /// and PASS/FAIL lines for validate. Exits non-zero if any file fails to parse.
    static func batch(action: String, files: [URL]) async throws {
        var anyFailed = false
        await withTaskGroup(of: String?.self) { group in
            for file in files {
                group.addTask {
                    switch action {
                    case "info":
                        await Self.infoLine(for: file)
                    case "validate":
                        await Self.validateLine(for: file)
                    default:
                        nil
                    }
                }
            }
            for await line in group {
                guard let line else { continue }
                if line.hasPrefix("FAIL ") { anyFailed = true }
                FileHandle.standardOutput.write(Data("\(line)\n".utf8))
            }
        }
        if anyFailed {
            throw CLIError.fileNotFound("one or more files failed validation")
        }
    }

    private static func infoLine(for file: URL) async -> String? {
        do {
            try ensureExists(file)
            let format = detectFormat(file)
            let payload = try buildInfoPayload(file: file, format: format)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            return String(data: data, encoding: .utf8)
        } catch {
            return "{\"file\":\"\(file.lastPathComponent)\",\"error\":\"\(error.localizedDescription)\"}"
        }
    }

    private static func validateLine(for file: URL) async -> String? {
        do {
            try ensureExists(file)
            let format = detectFormat(file)
            switch format {
            case .gcode: _ = try GCodeParser.parse(from: file)
            case .threemf, .stl: _ = try loadMesh(from: file, format: format)
            }
            return "PASS \(file.lastPathComponent)"
        } catch {
            return "FAIL \(file.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Parses the file and prints PASS/FAIL. Used in CI pipelines to confirm files
    /// are well-formed before farming them out to slicers.
    static func validate(file: URL) throws {
        try ensureExists(file)
        let format = detectFormat(file)
        do {
            let payload: String
            switch format {
            case .gcode:
                let toolpath = try GCodeParser.parse(from: file)
                payload = """
                PASS \(file.lastPathComponent)
                  format: \(format.rawValue)
                  layers: \(toolpath.layerCount)
                  segments: \(toolpath.segments.count)
                """
            case .threemf, .stl:
                let mesh = try loadMesh(from: file, format: format)
                payload = """
                PASS \(file.lastPathComponent)
                  format: \(format.rawValue)
                  triangles: \(mesh.indices.count / 3)
                  vertices: \(mesh.vertices.count)
                """
            }
            FileHandle.standardOutput.write(Data("\(payload)\n".utf8))
        } catch {
            FileHandle.standardError.write(
                Data("FAIL \(file.lastPathComponent): \(error.localizedDescription)\n".utf8)
            )
            throw error
        }
    }

    /// Parses optional `--size N` flag from argv. Returns nil if absent or invalid.
    static func parseSize(from args: [String]) -> Int? {
        guard let idx = args.firstIndex(of: "--size"), idx + 1 < args.count else {
            return nil
        }
        return Int(args[idx + 1])
    }

    // MARK: - Commands

    static func info(file: URL) throws {
        try ensureExists(file)
        let format = detectFormat(file)
        let payload = try buildInfoPayload(file: file, format: format)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    fileprivate static func buildInfoPayload(file: URL, format: FileFormat) throws -> InfoPayload {
        switch format {
        case .gcode:
            let toolpath = try GCodeParser.parse(from: file)
            let bbox = toolpath.boundingBox
            return InfoPayload(
                format: format.rawValue,
                triangleCount: nil,
                vertexCount: nil,
                segmentCount: toolpath.segments.count,
                layerCount: toolpath.layerCount,
                totalExtrudedMM: toolpath.totalExtrudedMM,
                totalTravelMM: toolpath.totalTravelMM,
                estimatedSeconds: toolpath.estimatedSeconds,
                boundingBox: BoundingBoxPayload(
                    min: [bbox.min.x, bbox.min.y, bbox.min.z],
                    max: [bbox.max.x, bbox.max.y, bbox.max.z]
                ),
                materials: nil,
                metadata: nil
            )
        case .threemf, .stl:
            let mesh = try loadMesh(from: file, format: format)
            let bbox = mesh.boundingBox
            return InfoPayload(
                format: format.rawValue,
                triangleCount: mesh.indices.count / 3,
                vertexCount: mesh.vertices.count,
                segmentCount: nil,
                layerCount: nil,
                totalExtrudedMM: nil,
                totalTravelMM: nil,
                estimatedSeconds: nil,
                boundingBox: BoundingBoxPayload(
                    min: [bbox.min.x, bbox.min.y, bbox.min.z],
                    max: [bbox.max.x, bbox.max.y, bbox.max.z]
                ),
                materials: mesh.materials.map { mat in
                    MaterialPayload(
                        name: mat.name,
                        color: mat.color.map { [$0.x, $0.y, $0.z, $0.w] }
                    )
                },
                metadata: mesh.metadata.map { md in
                    MetadataPayload(
                        application: md.application,
                        creationDate: md.creationDate,
                        modificationDate: md.modificationDate,
                        title: md.title,
                        designer: md.designer,
                        other: md.other.isEmpty ? nil : md.other
                    )
                }
            )
        }
    }

    static func thumbnail(input: URL, output: URL, size: Int, useCache: Bool = false) throws {
        try ensureExists(input)

        // Cache hit: write the cached PNG directly.
        if useCache, let cached = ThumbnailCache.cachedThumbnail(for: input) {
            try cached.write(to: output, options: .atomic)
            return
        }

        let format = detectFormat(input)
        let mesh = try loadMesh(from: input, format: format)
        let scene = SceneBuilder.buildScene(from: mesh)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        // Pick the camera node SceneBuilder added so the framing is correct.
        if let cam = scene.rootNode.childNode(withName: "camera", recursively: true) {
            renderer.pointOfView = cam
        }

        let pixelSize = CGSize(width: size, height: size)
        let image = renderer.snapshot(atTime: 0, with: pixelSize, antialiasingMode: .multisampling2X)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw CLIError.thumbnailEncodingFailed
        }

        try png.write(to: output, options: .atomic)
        if useCache {
            ThumbnailCache.store(png, for: input)
        }
    }

    // MARK: - Helpers

    enum FileFormat: String {
        case threemf = "3mf"
        case stl
        case gcode
    }

    static func detectFormat(_ url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "stl": .stl
        case "gcode": .gcode
        default: .threemf
        }
    }

    static func loadMesh(from url: URL, format: FileFormat) throws -> MeshData {
        switch format {
        case .threemf:
            try ThreeMFMeshParser.parseMesh(from: url)
        case .stl:
            try STLParser.parseMesh(from: url)
        case .gcode:
            // G-code is line-segment-oriented, not triangle-oriented. Callers should
            // route to `GCodeParser.parse(from:)` directly when format is .gcode.
            throw CLIError.unsupportedFormat("G-code files are not mesh-based; use the gcode info path")
        }
    }

    static func ensureExists(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            throw CLIError.fileNotFound(url.path)
        }
    }
}

// MARK: - JSON payloads

private struct InfoPayload: Encodable {
    let format: String
    let triangleCount: Int?
    let vertexCount: Int?
    let segmentCount: Int?
    let layerCount: Int?
    let totalExtrudedMM: Float?
    let totalTravelMM: Float?
    let estimatedSeconds: Double?
    let boundingBox: BoundingBoxPayload
    let materials: [MaterialPayload]?
    let metadata: MetadataPayload?
}

private struct BoundingBoxPayload: Encodable {
    let min: [Float]
    let max: [Float]
}

private struct MaterialPayload: Encodable {
    let name: String
    let color: [Float]?
}

private struct MetadataPayload: Encodable {
    let application: String?
    let creationDate: String?
    let modificationDate: String?
    let title: String?
    let designer: String?
    let other: [String: String]?
}
