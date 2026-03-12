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
        if data.count == expectedSize {
            return try parseBinary(data: data, triangleCount: Int(triangleCount))
        } else {
            return try parseASCII(data: data)
        }
    }

    private static func readFloat(_ data: Data, _ offset: Int) -> Float {
        var value: Float = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset..<offset + 4)
        }
        return value
    }

    private static func parseBinary(data: Data, triangleCount: Int) throws -> MeshData {
        guard triangleCount > 0 else { throw STLParserError.noTriangles }

        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        var vertexMap: [VertexKey: UInt32] = [:]

        vertices.reserveCapacity(triangleCount)
        indices.reserveCapacity(triangleCount * 3)

        for i in 0..<triangleCount {
            let offset = 84 + i * 50
            for v in 0..<3 {
                let vOffset = offset + 12 + v * 12
                let x = readFloat(data, vOffset)
                let y = readFloat(data, vOffset + 4)
                let z = readFloat(data, vOffset + 8)

                let key = VertexKey(x: x, y: y, z: z)
                if let existing = vertexMap[key] {
                    indices.append(existing)
                } else {
                    let idx = UInt32(vertices.count)
                    vertexMap[key] = idx
                    vertices.append(SCNVector3(x, y, z))
                    indices.append(idx)
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

        var vertices: [SCNVector3] = []
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
                vertices.append(SCNVector3(x, y, z))
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
