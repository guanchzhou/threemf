import AppKit
import Foundation
import SceneKit
import simd

enum CLIError: Error, LocalizedError {
    case unsupportedFormat(String)
    case fileNotFound(String)
    case thumbnailEncodingFailed
    case rendererCreationFailed

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(ext):
            return "Unsupported file format: .\(ext) (expected .3mf or .stl)"
        case let .fileNotFound(path):
            return "File not found: \(path)"
        case .thumbnailEncodingFailed:
            return "Failed to encode thumbnail PNG"
        case .rendererCreationFailed:
            return "Failed to create SceneKit renderer"
        }
    }
}

enum CLI {
    static func printUsage() {
        let usage = """
        threemf-cli — headless thumbnail/info for .3mf and .stl files

        Usage:
          threemf-cli info <file>
          threemf-cli thumbnail <input> <output.png> [--size N]

        Commands:
          info        Print JSON with format, triangle count, vertex count,
                      bounding box, and materials.
          thumbnail   Render a 3D thumbnail PNG (default size 512).
        """
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
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
        let mesh = try loadMesh(from: file, format: format)
        let bbox = computeBoundingBox(vertices: mesh.vertices)

        let payload = InfoPayload(
            format: format.rawValue,
            triangleCount: mesh.indices.count / 3,
            vertexCount: mesh.vertices.count,
            boundingBox: BoundingBoxPayload(
                min: [bbox.min.x, bbox.min.y, bbox.min.z],
                max: [bbox.max.x, bbox.max.y, bbox.max.z]
            ),
            materials: mesh.materials.map { mat in
                MaterialPayload(
                    name: mat.name,
                    color: mat.color.map { [$0.x, $0.y, $0.z, $0.w] }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func thumbnail(input: URL, output: URL, size: Int) throws {
        try ensureExists(input)
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
    }

    // MARK: - Helpers

    enum FileFormat: String {
        case threemf = "3mf"
        case stl
    }

    static func detectFormat(_ url: URL) -> FileFormat {
        let ext = url.pathExtension.lowercased()
        return ext == "stl" ? .stl : .threemf
    }

    static func loadMesh(from url: URL, format: FileFormat) throws -> MeshData {
        switch format {
        case .threemf:
            return try ThreeMFMeshParser.parseMesh(from: url)
        case .stl:
            return try STLParser.parseMesh(from: url)
        }
    }

    static func ensureExists(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            throw CLIError.fileNotFound(url.path)
        }
    }

    struct BoundingBox {
        let min: simd_float3
        let max: simd_float3
    }

    static func computeBoundingBox(vertices: [simd_float3]) -> BoundingBox {
        guard let first = vertices.first else {
            return BoundingBox(min: .zero, max: .zero)
        }
        var lo = first
        var hi = first
        for v in vertices.dropFirst() {
            lo = simd.min(lo, v)
            hi = simd.max(hi, v)
        }
        return BoundingBox(min: lo, max: hi)
    }
}

// MARK: - JSON payloads

private struct InfoPayload: Encodable {
    let format: String
    let triangleCount: Int
    let vertexCount: Int
    let boundingBox: BoundingBoxPayload
    let materials: [MaterialPayload]
}

private struct BoundingBoxPayload: Encodable {
    let min: [Float]
    let max: [Float]
}

private struct MaterialPayload: Encodable {
    let name: String
    let color: [Float]?
}
