import SceneKit

struct MeshData {
    var vertices: [SCNVector3]
    var indices: [UInt32]
    var normals: [SCNVector3]?

    mutating func computeNormals() {
        var accum = [SCNVector3](repeating: SCNVector3(0, 0, 0), count: vertices.count)

        for i in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[i])
            let i1 = Int(indices[i + 1])
            let i2 = Int(indices[i + 2])

            let v0 = vertices[i0]
            let v1 = vertices[i1]
            let v2 = vertices[i2]

            let edge1 = SCNVector3(v1.x - v0.x, v1.y - v0.y, v1.z - v0.z)
            let edge2 = SCNVector3(v2.x - v0.x, v2.y - v0.y, v2.z - v0.z)

            let normal = SCNVector3(
                edge1.y * edge2.z - edge1.z * edge2.y,
                edge1.z * edge2.x - edge1.x * edge2.z,
                edge1.x * edge2.y - edge1.y * edge2.x
            )

            accum[i0] = SCNVector3(accum[i0].x + normal.x, accum[i0].y + normal.y, accum[i0].z + normal.z)
            accum[i1] = SCNVector3(accum[i1].x + normal.x, accum[i1].y + normal.y, accum[i1].z + normal.z)
            accum[i2] = SCNVector3(accum[i2].x + normal.x, accum[i2].y + normal.y, accum[i2].z + normal.z)
        }

        normals = accum.map { n in
            let len = sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
            guard len > 0 else { return SCNVector3(0, 1, 0) }
            return SCNVector3(n.x / len, n.y / len, n.z / len)
        }
    }
}
