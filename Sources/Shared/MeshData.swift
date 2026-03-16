import SceneKit
import simd

struct MeshData {
    var vertices: [SCNVector3]
    var indices: [UInt32]
    var normals: [SCNVector3]?

    mutating func computeNormals(progress: ((Float) -> Void)? = nil) {
        let count = vertices.count
        var accum = [simd_float3](repeating: .zero, count: count)

        let totalTriangles = indices.count / 3
        let reportInterval = max(totalTriangles / 20, 1) // report ~20 times

        for i in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[i])
            let i1 = Int(indices[i + 1])
            let i2 = Int(indices[i + 2])

            let v0 = simd_float3(Float(vertices[i0].x), Float(vertices[i0].y), Float(vertices[i0].z))
            let v1 = simd_float3(Float(vertices[i1].x), Float(vertices[i1].y), Float(vertices[i1].z))
            let v2 = simd_float3(Float(vertices[i2].x), Float(vertices[i2].y), Float(vertices[i2].z))

            let normal = simd_cross(v1 - v0, v2 - v0)

            accum[i0] += normal
            accum[i1] += normal
            accum[i2] += normal

            if let progress = progress, (i / 3) % reportInterval == 0 {
                progress(Float(i / 3) / Float(totalTriangles))
            }
        }

        normals = accum.map { n in
            let len = simd_length(n)
            guard len > 0 else { return SCNVector3(0, 1, 0) }
            let normalized = n / len
            return SCNVector3(normalized.x, normalized.y, normalized.z)
        }
        progress?(1.0)
    }
}
