import Foundation
import SceneKit

enum STLParserError: Error, LocalizedError {
    case cannotReadFile
    case invalidFormat
    case noTriangles

    var errorDescription: String? {
        switch self {
        case .cannotReadFile: return "Cannot read STL file"
        case .invalidFormat: return "Invalid STL format"
        case .noTriangles: return "No triangles found in STL file"
        }
    }
}

struct STLParser {
    /// Hard cap on triangles to prevent OOM via crafted headers (UInt32 max is ~4.2B).
    static let maxTriangles = 50_000_000

    static func parseMesh(from fileURL: URL) throws -> MeshData {
        let data = try Data(contentsOf: fileURL)
        guard data.count > 84 else {
            return try parseASCII(data: data)
        }

        var triangleCount: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &triangleCount) { dest in
            data.copyBytes(to: dest, from: 80..<84)
        }
        let expectedSize = 84 + Int(triangleCount) * 50
        // Accept files >= expectedSize to tolerate trailing bytes some slicers append.
        if triangleCount > 0 && data.count >= expectedSize {
            return try parseBinary(data: data, triangleCount: Int(triangleCount))
        } else {
            return try parseASCII(data: data)
        }
    }

    private static func parseBinary(data: Data, triangleCount: Int) throws -> MeshData {
        guard triangleCount > 0 else { throw STLParserError.noTriangles }
        // Clamp to avoid huge reserveCapacity on a malicious header.
        let clampedCount = min(triangleCount, maxTriangles)

        var vertices: [simd_float3] = []
        var indices: [UInt32] = []
        var vertexMap: [VertexKey: UInt32] = [:]

        // Real-world dedup ratio is ~3:1 on closed manifolds; reserve conservatively.
        vertices.reserveCapacity(clampedCount)
        indices.reserveCapacity(clampedCount * 3)
        vertexMap.reserveCapacity(clampedCount / 2 + 1)

        try data.withUnsafeBytes { raw in
            guard raw.baseAddress != nil else { throw STLParserError.cannotReadFile }
            for i in 0..<clampedCount {
                let triOffset = 84 + i * 50 + 12 // skip header + normal
                for v in 0..<3 {
                    let vOffset = triOffset + v * 12
                    let x = raw.loadUnaligned(fromByteOffset: vOffset, as: Float.self)
                    let y = raw.loadUnaligned(fromByteOffset: vOffset + 4, as: Float.self)
                    let z = raw.loadUnaligned(fromByteOffset: vOffset + 8, as: Float.self)

                    let key = VertexKey(x: x, y: y, z: z)
                    if let existing = vertexMap[key] {
                        indices.append(existing)
                    } else {
                        let idx = UInt32(vertices.count)
                        vertexMap[key] = idx
                        vertices.append(simd_float3(x, y, z))
                        indices.append(idx)
                    }
                }
            }
        }

        var mesh = MeshData(vertices: vertices, indices: indices, normals: nil)
        mesh.computeNormals()
        return mesh
    }

    private static func parseASCII(data: Data) throws -> MeshData {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw STLParserError.cannotReadFile
        }

        var vertices: [simd_float3] = []
        var indices: [UInt32] = []
        var vertexMap: [VertexKey: UInt32] = [:]

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("vertex ") else { continue }

            let parts = trimmed.split(separator: " ")
            guard parts.count >= 4,
                  let x = Float(parts[1]),
                  let y = Float(parts[2]),
                  let z = Float(parts[3]) else { continue }

            let key = VertexKey(x: x, y: y, z: z)
            if let existing = vertexMap[key] {
                indices.append(existing)
            } else {
                let idx = UInt32(vertices.count)
                vertexMap[key] = idx
                vertices.append(simd_float3(x, y, z))
                indices.append(idx)
            }
        }

        guard indices.count >= 3 else { throw STLParserError.noTriangles }

        var mesh = MeshData(vertices: vertices, indices: indices, normals: nil)
        mesh.computeNormals()
        return mesh
    }
}

private struct VertexKey: Hashable {
    let ix: Int32
    let iy: Int32
    let iz: Int32

    init(x: Float, y: Float, z: Float) {
        ix = Int32((x * 10000).rounded())
        iy = Int32((y * 10000).rounded())
        iz = Int32((z * 10000).rounded())
    }
}
