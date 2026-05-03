import Dispatch
import Foundation
import os
import SceneKit
import simd

/// One material from `<basematerials>` in the 3MF model.
public struct BaseMaterial: Sendable, Hashable {
    public let name: String
    /// RGBA in 0...1 range. `nil` = inherit default.
    public let color: SIMD4<Float>?

    public init(name: String, color: SIMD4<Float>?) {
        self.name = name
        self.color = color
    }
}

/// Axis-aligned bounding box of a mesh in its source coordinate space (3D-print conventions: mm).
public struct BoundingBox: Sendable, Hashable {
    public let min: simd_float3
    public let max: simd_float3

    public init(min: simd_float3, max: simd_float3) {
        self.min = min
        self.max = max
    }

    /// `max - min`. `(.zero, .zero)` for an empty mesh, so dimensions are `.zero`.
    public var dimensions: simd_float3 {
        max - min
    }
}

/// Standard 3MF `<metadata>` fields plus any unrecognized keys preserved verbatim.
/// Only present for `.3mf` files; `.stl` has no metadata.
public struct ThreeMFMetadata: Sendable, Hashable {
    public var application: String?
    public var creationDate: String?
    public var modificationDate: String?
    public var title: String?
    public var designer: String?
    /// Other 3MF metadata keys (`Description`, `LicenseTerms`, slicer-specific…) preserved as-is.
    public var other: [String: String]

    public init(
        application: String? = nil,
        creationDate: String? = nil,
        modificationDate: String? = nil,
        title: String? = nil,
        designer: String? = nil,
        other: [String: String] = [:]
    ) {
        self.application = application
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.title = title
        self.designer = designer
        self.other = other
    }

    public var isEmpty: Bool {
        application == nil && creationDate == nil && modificationDate == nil
            && title == nil && designer == nil && other.isEmpty
    }
}

public struct MeshData {
    public var vertices: [simd_float3]
    public var indices: [UInt32]
    public var normals: [simd_float3]?
    /// Optional materials and per-triangle material indices.
    /// When present, SceneBuilder emits one SCNGeometryElement per material.
    public var materials: [BaseMaterial] = []
    /// Length is `indices.count / 3`. Index into `materials`. `-1` = default material.
    public var triangleMaterials: [Int] = []
    /// Optional 3MF metadata. `nil` for STL or 3MF files with no `<metadata>` tags.
    public var metadata: ThreeMFMetadata?

    public init(
        vertices: [simd_float3],
        indices: [UInt32],
        normals: [simd_float3]? = nil,
        materials: [BaseMaterial] = [],
        triangleMaterials: [Int] = [],
        metadata: ThreeMFMetadata? = nil
    ) {
        self.vertices = vertices
        self.indices = indices
        self.normals = normals
        self.materials = materials
        self.triangleMaterials = triangleMaterials
        self.metadata = metadata
    }

    /// Signed mesh volume via the divergence theorem (sum of signed tetrahedral volumes).
    /// Result is in cubic mesh-space units (mm³ for typical 3D-print files). For closed,
    /// outward-oriented meshes this is positive and matches the printed-part volume; for
    /// non-manifold or inverted meshes the value can be wrong but never crashes. O(N).
    public var volume: Float {
        var sixV: Float = 0
        let count = indices.count / 3
        for t in 0 ..< count {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            let v0 = vertices[i0]
            let v1 = vertices[i1]
            let v2 = vertices[i2]
            sixV += simd_dot(v0, simd_cross(v1, v2))
        }
        return abs(sixV) / 6
    }

    /// Single-walk computation of bounding box AND volume — saves one O(N) traversal
    /// over `boundingBox` and `volume` accessed separately. Use this when both are
    /// needed in the same UI pass.
    public func statistics() -> (boundingBox: BoundingBox, volume: Float) {
        guard let first = vertices.first else {
            return (BoundingBox(min: .zero, max: .zero), 0)
        }
        var lo = first
        var hi = first
        for v in vertices.dropFirst() {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }

        var sixV: Float = 0
        let count = indices.count / 3
        for t in 0 ..< count {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            sixV += simd_dot(vertices[i0], simd_cross(vertices[i1], vertices[i2]))
        }
        return (BoundingBox(min: lo, max: hi), abs(sixV) / 6)
    }

    /// Axis-aligned bounding box of `vertices` in mesh-space units. O(N).
    /// `(min: .zero, max: .zero)` for empty meshes.
    public var boundingBox: BoundingBox {
        guard let first = vertices.first else {
            return BoundingBox(min: .zero, max: .zero)
        }
        var lo = first
        var hi = first
        for v in vertices.dropFirst() {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return BoundingBox(min: lo, max: hi)
    }

    /// Computes per-vertex normals by accumulating face normals.
    /// Parallelizes across CPU cores using per-thread scratch buffers and a final reduce.
    public mutating func computeNormals(progress: ((Float) -> Void)? = nil) {
        let count = vertices.count
        let totalTriangles = indices.count / 3
        guard count > 0, totalTriangles > 0 else {
            normals = []
            progress?(1.0)
            return
        }

        // Single-threaded path for small meshes — parallel overhead isn't worth it.
        if totalTriangles < 50000 {
            normals = computeNormalsSerial(progress: progress)
            return
        }

        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunks = min(cores * 2, max(1, totalTriangles / 25000))

        // Hoist into immutable locals so the concurrent block doesn't capture inout self.
        // Arrays are COW — these are zero-copy references to the same storage.
        let verticesLocal = vertices
        let indicesLocal = indices
        nonisolated(unsafe) let progressLocal = progress

        // Per-chunk scratch as a flat raw allocation. Each chunk writes to a disjoint
        // [chunkIdx * count, (chunkIdx + 1) * count) range, so the captured base
        // pointer is safe to share across threads even though the compiler can't prove it.
        let total = chunks * count
        let flat = UnsafeMutablePointer<simd_float3>.allocate(capacity: total)
        flat.initialize(repeating: .zero, count: total)
        defer {
            flat.deinitialize(count: total)
            flat.deallocate()
        }
        nonisolated(unsafe) let flatBase = flat

        let reported = OSAllocatedUnfairLock(initialState: 0)
        let reportInterval = max(chunks / 20, 1)

        DispatchQueue.concurrentPerform(iterations: chunks) { chunkIdx in
            let start = (totalTriangles * chunkIdx) / chunks
            let end = (totalTriangles * (chunkIdx + 1)) / chunks
            let local = flatBase.advanced(by: chunkIdx * count)
            verticesLocal.withUnsafeBufferPointer { vPtr in
                indicesLocal.withUnsafeBufferPointer { iPtr in
                    for t in start ..< end {
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

            if let progressLocal {
                let count = reported.withLock { state -> Int in
                    state += 1
                    return state
                }
                if count % reportInterval == 0 || count == chunks {
                    progressLocal(Float(count) / Float(chunks))
                }
            }
        }

        // Reduce: sum each chunk's partial buffer into a single accumulator.
        var accum = [simd_float3](repeating: .zero, count: count)
        for chunkIdx in 0 ..< chunks {
            let base = flatBase.advanced(by: chunkIdx * count)
            for i in 0 ..< count {
                accum[i] += base[i]
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

        for t in 0 ..< totalTriangles {
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
