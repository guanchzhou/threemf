import Dispatch
import Foundation
import os
import SceneKit
import simd

/// One material from `<basematerials>` in the 3MF model.
struct BaseMaterial: Sendable, Hashable {
    let name: String
    /// RGBA in 0...1 range. `nil` = inherit default.
    let color: SIMD4<Float>?
}

struct MeshData {
    var vertices: [simd_float3]
    var indices: [UInt32]
    var normals: [simd_float3]?
    /// Optional materials and per-triangle material indices.
    /// When present, SceneBuilder emits one SCNGeometryElement per material.
    var materials: [BaseMaterial] = []
    /// Length is `indices.count / 3`. Index into `materials`. Empty means single-material.
    var triangleMaterials: [Int] = []

    /// Computes per-vertex normals by accumulating face normals.
    /// Parallelizes across CPU cores using per-thread scratch buffers and a final reduce.
    mutating func computeNormals(progress: ((Float) -> Void)? = nil) {
        let count = vertices.count
        let totalTriangles = indices.count / 3
        guard count > 0, totalTriangles > 0 else {
            normals = []
            progress?(1.0)
            return
        }

        // Single-threaded path for small meshes — parallel overhead isn't worth it.
        if totalTriangles < 50_000 {
            normals = computeNormalsSerial(progress: progress)
            return
        }

        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunks = min(cores * 2, max(1, totalTriangles / 25_000))

        // Per-chunk scratch — avoids contention. Reduce at the end.
        var partials = Array(
            repeating: [simd_float3](repeating: .zero, count: count),
            count: chunks
        )

        let reported = OSAllocatedUnfairLock(initialState: 0)
        let reportInterval = max(chunks / 20, 1)

        partials.withUnsafeMutableBufferPointer { partialsPtr in
            DispatchQueue.concurrentPerform(iterations: chunks) { chunkIdx in
                let start = (totalTriangles * chunkIdx) / chunks
                let end = (totalTriangles * (chunkIdx + 1)) / chunks
                var local = partialsPtr[chunkIdx]
                vertices.withUnsafeBufferPointer { vPtr in
                    indices.withUnsafeBufferPointer { iPtr in
                        for t in start..<end {
                            let i0 = Int(iPtr[t * 3])
                            let i1 = Int(iPtr[t * 3 + 1])
                            let i2 = Int(iPtr[t * 3 + 2])
                            guard i0 < count, i1 < count, i2 < count else { continue }
                            let v0 = vPtr[i0]
                            let v1 = vPtr[i1]
                            let v2 = vPtr[i2]
                            let n = simd_cross(v1 - v0, v2 - v0)
                            local[i0] += n
                            local[i1] += n
                            local[i2] += n
                        }
                    }
                }
                partialsPtr[chunkIdx] = local

                if let progress {
                    let count = reported.withLock { state -> Int in
                        state += 1
                        return state
                    }
                    if count % reportInterval == 0 || count == chunks {
                        progress(Float(count) / Float(chunks))
                    }
                }
            }
        }

        // Reduce.
        var accum = partials[0]
        for p in partials.dropFirst() {
            for i in 0..<count {
                accum[i] += p[i]
            }
        }

        normals = accum.map { n in
            let len = simd_length(n)
            guard len > 0 else { return simd_float3(0, 1, 0) }
            return n / len
        }
        progress?(1.0)
    }

    private func computeNormalsSerial(progress: ((Float) -> Void)?) -> [simd_float3] {
        let count = vertices.count
        var accum = [simd_float3](repeating: .zero, count: count)

        let totalTriangles = indices.count / 3
        let reportInterval = max(totalTriangles / 20, 1)

        for t in 0..<totalTriangles {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            guard i0 < count, i1 < count, i2 < count else { continue }
            let normal = simd_cross(vertices[i1] - vertices[i0], vertices[i2] - vertices[i0])
            accum[i0] += normal
            accum[i1] += normal
            accum[i2] += normal
            if let progress, t % reportInterval == 0 {
                progress(Float(t) / Float(totalTriangles))
            }
        }

        progress?(1.0)
        return accum.map { n in
            let len = simd_length(n)
            guard len > 0 else { return simd_float3(0, 1, 0) }
            return n / len
        }
    }
}
