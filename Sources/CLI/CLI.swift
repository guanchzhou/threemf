import AppKit
import Foundation
import ImageIO
import SceneKit
import simd
#if canImport(ThreeMFCore)
    import ThreeMFCore
#endif

enum CLIError: Error, LocalizedError {
    case unsupportedFormat(String)
    case fileNotFound(String)
    case invalidSize(String)
    case invalidPlate(String)
    case invalidBatchAction(String)
    case batchValidationFailed
    case thumbnailEncodingFailed
    case rendererCreationFailed

    var isUsageError: Bool {
        switch self {
        case .invalidSize, .invalidPlate, .invalidBatchAction:
            true
        case .unsupportedFormat, .fileNotFound, .batchValidationFailed,
             .thumbnailEncodingFailed, .rendererCreationFailed:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(ext):
            // Empty ext prints as "." — name it so the message stays legible.
            "Unsupported file format: \(ext.isEmpty ? "(no extension)" : ".\(ext)") (expected .3mf, .stl, or .gcode)"
        case let .fileNotFound(path):
            "File not found: \(path)"
        case let .invalidSize(detail):
            "Invalid --size value: \(detail)"
        case let .invalidPlate(detail):
            "Invalid --plate value: \(detail)"
        case let .invalidBatchAction(action):
            "Unknown batch action: \(action) (expected 'info' or 'validate')"
        case .batchValidationFailed:
            "One or more files failed validation"
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
        threemf-cli — headless thumbnail/info for .3mf, .stl, and .gcode files

        Usage:
          threemf-cli info <file>
          threemf-cli validate <file>
          threemf-cli thumbnail <input> <output.png> [--size N] [--cache] [--plate N]
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
          --size N    For 'thumbnail': output edge length in pixels (1…4096, default 512).
          --plate N   For 'thumbnail': render only plate N (1-based) of a multi-plate 3MF.
          --cache     For 'thumbnail': read/write the shared ThumbnailCache so
                      repeated invocations reuse a previously rendered PNG.

        Exit codes: 0 success · 1 runtime error (missing/corrupt/unsupported file) · 2 usage.
        """
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
    }

    /// Runs `info` or `validate` across many files concurrently. Output is JSONL for info
    /// and PASS/FAIL lines for validate, emitted in deterministic input order.
    /// Exits non-zero if any file fails to parse.
    /// In-flight work is capped at `max(1, activeProcessorCount)` so a huge batch cannot
    /// spawn one task per file immediately.
    static func batch(action: String, files: [URL]) async throws {
        guard action == "info" || action == "validate" else {
            throw CLIError.invalidBatchAction(action)
        }
        var anyFailed = false
        let concurrency = max(1, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: (Int, String, Bool).self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < files.count else { return }
                let idx = nextIndex
                let file = files[idx]
                nextIndex += 1
                group.addTask {
                    if action == "info" {
                        let (line, failed) = await Self.infoLine(for: file)
                        return (idx, line, failed)
                    } else {
                        let (line, failed) = await Self.validateLine(for: file)
                        return (idx, line, failed)
                    }
                }
            }

            for _ in 0 ..< min(concurrency, files.count) {
                enqueueNext()
            }

            var nextToWrite = 0
            var pending: [Int: (line: String, failed: Bool)] = [:]
            for await (idx, line, failed) in group {
                pending[idx] = (line, failed)
                while let ready = pending.removeValue(forKey: nextToWrite) {
                    if ready.failed {
                        anyFailed = true
                    }
                    FileHandle.standardOutput.write(Data("\(ready.line)\n".utf8))
                    nextToWrite += 1
                }
                enqueueNext()
            }
        }
        if anyFailed {
            throw CLIError.batchValidationFailed
        }
    }

    private static func infoLine(for file: URL) async -> (line: String, failed: Bool) {
        do {
            try ensureExists(file)
            let format = try resolveFormat(file)
            let payload = try buildInfoPayload(file: file, format: format)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            if let text = String(data: data, encoding: .utf8) {
                return (text, false)
            }
            return (encodeInfoErrorLine(fileName: file.lastPathComponent, message: "UTF-8 encode failed"), true)
        } catch {
            return (
                encodeInfoErrorLine(fileName: file.lastPathComponent, message: error.localizedDescription),
                true
            )
        }
    }

    /// Encodes a batch-info failure as a single JSON object (`file` + `error`, sorted keys).
    /// Used instead of string interpolation so quotes in filenames stay valid JSONL.
    static func encodeInfoErrorLine(fileName: String, message: String) -> String {
        struct ErrorPayload: Encodable {
            let file: String
            let error: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ErrorPayload(file: fileName, error: message)),
              let line = String(data: data, encoding: .utf8)
        else {
            return #"{"error":"encode failed","file":""}"#
        }
        return line
    }

    private static func validateLine(for file: URL) async -> (line: String, failed: Bool) {
        do {
            try ensureExists(file)
            let format = try resolveFormat(file)
            switch format {
            case .gcode: _ = try GCodeParser.parse(from: file)
            case .threemf, .stl: _ = try loadMesh(from: file, format: format, computesNormals: false)
            }
            return ("PASS \(file.lastPathComponent)", false)
        } catch {
            return ("FAIL \(file.lastPathComponent): \(error.localizedDescription)", true)
        }
    }

    /// Parses the file and prints PASS/FAIL. Used in CI pipelines to confirm files
    /// are well-formed before farming them out to slicers.
    static func validate(file: URL) throws {
        try ensureExists(file)
        let format = try resolveFormat(file)
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
                let mesh = try loadMesh(from: file, format: format, computesNormals: false)
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

    /// Resolves the `--size N` flag. Absent → default 512. Present but non-numeric,
    /// non-positive, or above `maxThumbnailSize` → throws, so a typo like `--size 0` or
    /// `--size huge` fails loudly instead of silently rendering the default (or a 0×0 image).
    static func resolveSize(from args: [String]) throws -> Int {
        guard let idx = args.firstIndex(of: "--size") else { return 512 }
        guard idx + 1 < args.count else { throw CLIError.invalidSize("(missing value)") }
        let raw = args[idx + 1]
        guard let n = Int(raw) else {
            throw CLIError.invalidSize("\(raw) (expected an integer 1...\(maxThumbnailSize))")
        }
        guard n > 0, n <= maxThumbnailSize else {
            throw CLIError.invalidSize("\(n) (expected 1...\(maxThumbnailSize))")
        }
        return n
    }

    /// Resolves the optional `--plate N` (1-based) flag from argv.
    /// Absent → `nil`. Present with missing, non-numeric, or `< 1` value → throws `CLIError.invalidPlate`.
    static func resolvePlate(from args: [String]) throws -> Int? {
        guard let idx = args.firstIndex(of: "--plate") else { return nil }
        guard idx + 1 < args.count else { throw CLIError.invalidPlate("(missing value)") }
        let raw = args[idx + 1]
        guard let n = Int(raw), n >= 1 else {
            throw CLIError.invalidPlate("\(raw) (expected an integer >= 1)")
        }
        return n
    }

    /// Parses optional `--plate N` (1-based) flag from argv. Returns nil if absent or invalid.
    static func parsePlate(from args: [String]) -> Int? {
        try? resolvePlate(from: args)
    }

    // MARK: - Commands

    static func info(file: URL) throws {
        try ensureExists(file)
        let format = try resolveFormat(file)
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
            let mesh = try loadMesh(from: file, format: format, computesNormals: false)
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

    static func thumbnail(input: URL, output: URL, size: Int, useCache: Bool = false, plate: Int? = nil) throws {
        try ensureExists(input)

        // Include size and plate in the cache key so different sizes/plates don't alias.
        let cacheExtraKey = "size=\(size):plate=\(plate ?? 0)"
        if useCache, let cached = ThumbnailCache.cachedThumbnail(for: input, extraKey: cacheExtraKey) {
            try cached.write(to: output, options: .atomic)
            return
        }

        let format = try resolveFormat(input)
        let scene: SCNScene
        switch format {
        case .gcode:
            let toolpath = try GCodeParser.parse(
                from: input,
                outputSegmentBudget: GCodeParser.thumbnailSegmentBudget,
                computesStatistics: false
            )
            scene = ToolpathSceneBuilder.buildTopDownScene(from: toolpath)
        case .threemf, .stl:
            var mesh = try loadMesh(from: input, format: format)
            // `--plate N` (1-based) renders only that plate of a multi-plate Bambu/Orca 3MF.
            if let plate, !mesh.plates.isEmpty {
                let idx = max(0, min(plate - 1, mesh.plates.count - 1))
                mesh = mesh.submesh(plateIndex: idx)
            }
            scene = SceneBuilder.buildScene(from: mesh)
        }

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        // Pick the camera node SceneBuilder/ToolpathSceneBuilder added so framing is correct.
        if let cam = scene.rootNode.childNode(withName: "camera", recursively: true) {
            renderer.pointOfView = cam
        }

        let pixelSize = CGSize(width: size, height: size)
        let image = renderer.snapshot(atTime: 0, with: pixelSize, antialiasingMode: .multisampling2X)

        guard let png = encodePNG(image) else {
            throw CLIError.thumbnailEncodingFailed
        }

        try png.write(to: output, options: .atomic)
        if useCache {
            ThumbnailCache.store(png, for: input, extraKey: cacheExtraKey)
        }
    }

    private static func encodePNG(_ image: NSImage) -> Data? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let buffer = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                if CGImageDestinationFinalize(dest) {
                    return buffer as Data
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Helpers

    enum FileFormat: String {
        case threemf = "3mf"
        case stl
        case gcode
    }

    /// Largest thumbnail edge we'll render. Above this the snapshot allocation is huge
    /// (size² × 4 bytes × MSAA) for no practical gain; reject with a clear message instead.
    static let maxThumbnailSize = 4096

    /// Resolves the file format from its extension, throwing a clear error for anything we
    /// don't handle. Extensionless files default to `.3mf` (archives are sometimes exported
    /// without a suffix); any *other* unknown extension is rejected explicitly, so the user
    /// sees "unsupported format" rather than a misleading downstream 3MF/ZIP parse error.
    static func resolveFormat(_ url: URL) throws -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "stl": .stl
        case "gcode": .gcode
        case "3mf", "": .threemf
        case let other: throw CLIError.unsupportedFormat(other)
        }
    }

    static func loadMesh(
        from url: URL,
        format: FileFormat,
        computesNormals: Bool = true
    ) throws -> MeshData {
        switch format {
        case .threemf:
            try ThreeMFMeshParser.parseMesh(from: url, computesNormals: computesNormals)
        case .stl:
            try STLParser.parseMesh(from: url, computesNormals: computesNormals)
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
