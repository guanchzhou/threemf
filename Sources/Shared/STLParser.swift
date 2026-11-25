import Foundation
import SceneKit

public enum STLParserError: Error, LocalizedError {
    case cannotReadFile
    case invalidFormat
    case noTriangles
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .cannotReadFile: "Cannot read STL file"
        case .invalidFormat: "Invalid STL format"
        case .noTriangles: "No triangles found in STL file"
        case .fileTooLarge: "STL file exceeds maximum size"
        }
    }
}

public enum STLParser {
    /// Hard cap on triangles to prevent OOM via crafted headers (UInt32 max is ~4.2B).
    public static let maxTriangles = ResourceLimits.cli.maxSTLTriangles

    /// Hard cap on raw STL file size for the CLI (Quick Look uses ``ResourceLimits/quickLook``).
    public static let maxFileSize = ResourceLimits.cli.maxSTLFileBytes

    public static func parseMesh(
        from fileURL: URL,
        limits: ResourceLimits = .cli,
        cancellation: ParseCancellation? = nil,
        computesNormals: Bool = true
    ) throws -> MeshData {
        let data: Data
        do {
            data = try BoundedFileReader.dataContents(of: fileURL, maxByteCount: limits.maxSTLFileBytes)
        } catch BoundedFileReader.ReadError.fileTooLarge {
            throw STLParserError.fileTooLarge
        }
        return try parseMesh(
            data: data,
            limits: limits,
            cancellation: cancellation,
            computesNormals: computesNormals
        )
    }

    static func parseMesh(
        data: Data,
        limits: ResourceLimits,
        cancellation: ParseCancellation? = nil,
        computesNormals: Bool = true
    ) throws -> MeshData {
        guard data.count > 84 else {
            return try parseASCII(
                data: data,
                limits: limits,
                cancellation: cancellation,
                computesNormals: computesNormals
            )
        }

        // Standard STL detection: ASCII files begin with `solid `. The pure size-based
        // check that follows can mis-classify carefully crafted ASCII files (whose first
        // 80 bytes happen to encode a plausible triangle count + matching size) as binary,
        // so we try ASCII first when the magic prefix is present. Some buggy slicers do
        // emit binary files starting with `solid` (their 80-byte header just happens to);
        // those get a binary fallback when ASCII parsing produces no triangles.
        let startsWithSolid = data.starts(with: [0x73, 0x6F, 0x6C, 0x69, 0x64]) // "solid"
        if startsWithSolid {
            do {
                return try parseASCII(
                    data: data,
                    limits: limits,
                    cancellation: cancellation,
                    computesNormals: computesNormals
                )
            } catch is CancellationError {
                // Cancellation is not a parse failure — never fall through to the binary
                // path, or a cancelled preview would start a second full parse.
                throw CancellationError()
            } catch {
                // Genuine ASCII failure: fall through to binary detection below.
            }
        }

        var triangleCount: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &triangleCount) { dest in
            data.copyBytes(to: dest, from: 80 ..< 84)
        }
        let expectedSize = 84 + Int(triangleCount) * 50
        // Accept files >= expectedSize to tolerate trailing bytes some slicers append.
        if triangleCount > 0, data.count >= expectedSize {
            return try parseBinary(
                data: data,
                triangleCount: Int(triangleCount),
                limits: limits,
                cancellation: cancellation,
                computesNormals: computesNormals
            )
        } else {
            return try parseASCII(
                data: data,
                limits: limits,
                cancellation: cancellation,
                computesNormals: computesNormals
            )
        }
    }

    /// Threshold above which binary parsing fans out across cores. Below this, the parallel
    /// overhead (per-chunk allocations + final merge) dwarfs the gain.
    private static let parallelTriangleThreshold = 100_000

    private static func parseBinary(
        data: Data,
        triangleCount: Int,
        limits: ResourceLimits,
        cancellation: ParseCancellation?,
        computesNormals: Bool
    ) throws -> MeshData {
        guard triangleCount > 0 else { throw STLParserError.noTriangles }
        let clampedCount = min(triangleCount, limits.maxSTLTriangles)

        if clampedCount >= parallelTriangleThreshold {
            return try parseBinaryParallel(
                data: data,
                triangleCount: clampedCount,
                limits: limits,
                cancellation: cancellation,
                computesNormals: computesNormals
            )
        }
        return try parseBinarySerial(
            data: data,
            triangleCount: clampedCount,
            limits: limits,
            cancellation: cancellation,
            computesNormals: computesNormals
        )
    }

    /// Internal so tests can compare serial vs parallel paths on identical input.
    /// Not part of the public API — callers should use `parseMesh(from:)`.
    static func parseBinarySerial(
        data: Data,
        triangleCount: Int,
        limits _: ResourceLimits = .cli,
        cancellation: ParseCancellation? = nil,
        computesNormals: Bool = true
    ) throws -> MeshData {
        var vertices: [simd_float3] = []
        var indices: [UInt32] = []
        var vertexMap: [VertexKey: UInt32] = [:]

        // Real-world dedup ratio is ~3:1 on closed manifolds; reserve conservatively.
        vertices.reserveCapacity(triangleCount)
        indices.reserveCapacity(triangleCount * 3)
        vertexMap.reserveCapacity(triangleCount / 2 + 1)

        try data.withUnsafeBytes { raw in
            guard raw.baseAddress != nil else { throw STLParserError.cannotReadFile }
            var poller = CancellationPoller(cancellation)
            for i in 0 ..< triangleCount {
                try poller.tick()
                let triOffset = 84 + i * 50 + 12 // skip header + normal
                let x0 = raw.loadUnaligned(fromByteOffset: triOffset, as: Float.self)
                let y0 = raw.loadUnaligned(fromByteOffset: triOffset + 4, as: Float.self)
                let z0 = raw.loadUnaligned(fromByteOffset: triOffset + 8, as: Float.self)
                let x1 = raw.loadUnaligned(fromByteOffset: triOffset + 12, as: Float.self)
                let y1 = raw.loadUnaligned(fromByteOffset: triOffset + 16, as: Float.self)
                let z1 = raw.loadUnaligned(fromByteOffset: triOffset + 20, as: Float.self)
                let x2 = raw.loadUnaligned(fromByteOffset: triOffset + 24, as: Float.self)
                let y2 = raw.loadUnaligned(fromByteOffset: triOffset + 28, as: Float.self)
                let z2 = raw.loadUnaligned(fromByteOffset: triOffset + 32, as: Float.self)
                guard x0.isFinite, y0.isFinite, z0.isFinite,
                      x1.isFinite, y1.isFinite, z1.isFinite,
                      x2.isFinite, y2.isFinite, z2.isFinite
                else { continue }

                for (x, y, z) in [(x0, y0, z0), (x1, y1, z1), (x2, y2, z2)] {
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

        guard indices.count >= 3 else { throw STLParserError.noTriangles }

        var mesh = MeshData(vertices: vertices, indices: indices, normals: nil)
        if computesNormals {
            try mesh.computeNormals(cancellation: cancellation)
        }
        return mesh
    }

    /// Multi-core binary STL parser. Each thread builds its own (vertices, indices, localMap)
    /// over a disjoint triangle range. A final serial merge re-keys local indices to a global
    /// dedup map. Speedup is ~2–3× on M-series for >1M-triangle files.
    /// Internal so tests can compare against `parseBinarySerial` on identical input.
    static func parseBinaryParallel(
        data: Data,
        triangleCount: Int,
        limits: ResourceLimits = .cli,
        cancellation: ParseCancellation? = nil,
        computesNormals: Bool = true
    ) throws -> MeshData {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunks = min(cores * 2, max(1, triangleCount / 50000))
        if chunks <= 1 {
            return try parseBinarySerial(
                data: data,
                triangleCount: triangleCount,
                limits: limits,
                cancellation: cancellation,
                computesNormals: computesNormals
            )
        }

        let results = (0 ..< chunks).map { _ in ChunkResult() }

        // Captures: Data is Sendable; `[ChunkResult]` is Sendable because ChunkResult
        // opts in via @unchecked Sendable (each thread mutates only its own instance,
        // disjoint by index).
        let resultsLocal = results
        let dataLocal = data

        DispatchQueue.concurrentPerform(iterations: chunks) { chunkIdx in
            let start = (triangleCount * chunkIdx) / chunks
            let end = (triangleCount * (chunkIdx + 1)) / chunks
            let result = resultsLocal[chunkIdx]
            let triPerChunk = end - start
            result.vertices.reserveCapacity(triPerChunk)
            result.indices.reserveCapacity(triPerChunk * 3)
            result.localMap.reserveCapacity(triPerChunk)

            dataLocal.withUnsafeBytes { raw in
                var poller = CancellationPoller(cancellation)
                for i in start ..< end {
                    if poller.tickIsCancelled() {
                        return
                    }
                    let triOffset = 84 + i * 50 + 12 // skip header + normal
                    let x0 = raw.loadUnaligned(fromByteOffset: triOffset, as: Float.self)
                    let y0 = raw.loadUnaligned(fromByteOffset: triOffset + 4, as: Float.self)
                    let z0 = raw.loadUnaligned(fromByteOffset: triOffset + 8, as: Float.self)
                    let x1 = raw.loadUnaligned(fromByteOffset: triOffset + 12, as: Float.self)
                    let y1 = raw.loadUnaligned(fromByteOffset: triOffset + 16, as: Float.self)
                    let z1 = raw.loadUnaligned(fromByteOffset: triOffset + 20, as: Float.self)
                    let x2 = raw.loadUnaligned(fromByteOffset: triOffset + 24, as: Float.self)
                    let y2 = raw.loadUnaligned(fromByteOffset: triOffset + 28, as: Float.self)
                    let z2 = raw.loadUnaligned(fromByteOffset: triOffset + 32, as: Float.self)
                    guard x0.isFinite, y0.isFinite, z0.isFinite,
                          x1.isFinite, y1.isFinite, z1.isFinite,
                          x2.isFinite, y2.isFinite, z2.isFinite
                    else { continue }

                    for (x, y, z) in [(x0, y0, z0), (x1, y1, z1), (x2, y2, z2)] {
                        let key = VertexKey(x: x, y: y, z: z)
                        if let existing = result.localMap[key] {
                            result.indices.append(existing)
                        } else {
                            let idx = UInt32(result.vertices.count)
                            result.localMap[key] = idx
                            result.vertices.append(simd_float3(x, y, z))
                            result.indices.append(idx)
                        }
                    }
                }
            }
        }

        // A cancelled chunk returns with a truncated vertex list, so merging would yield a
        // silently incomplete mesh. Bail before the merge instead.
        try cancellation?.check()

        // Serial merge: walk each chunk's vertex list and remap local→global indices.
        // The merge is O(total_local_vertices) hash lookups — cheap relative to the
        // per-thread work just done.
        var globalMap: [VertexKey: UInt32] = [:]
        var globalVertices: [simd_float3] = []
        var globalIndices: [UInt32] = []
        globalVertices.reserveCapacity(triangleCount)
        globalIndices.reserveCapacity(triangleCount * 3)
        globalMap.reserveCapacity(triangleCount)

        var mergePoller = CancellationPoller(cancellation)
        for chunk in results {
            var remap = [UInt32](repeating: 0, count: chunk.vertices.count)
            for (localIdx, vertex) in chunk.vertices.enumerated() {
                try mergePoller.tick()
                let key = VertexKey(x: vertex.x, y: vertex.y, z: vertex.z)
                if let globalIdx = globalMap[key] {
                    remap[localIdx] = globalIdx
                } else {
                    let globalIdx = UInt32(globalVertices.count)
                    globalMap[key] = globalIdx
                    globalVertices.append(vertex)
                    remap[localIdx] = globalIdx
                }
            }
            for localIdx in chunk.indices {
                globalIndices.append(remap[Int(localIdx)])
            }
        }

        guard globalIndices.count >= 3 else { throw STLParserError.noTriangles }

        var mesh = MeshData(vertices: globalVertices, indices: globalIndices, normals: nil)
        if computesNormals {
            try mesh.computeNormals(cancellation: cancellation)
        }
        return mesh
    }

    /// Byte-level ASCII STL parser — avoids `String(data:)` allocation on the whole file.
    /// Scans line-by-line for `vertex X Y Z` tokens, parses floats inline.
    private static func parseASCII(
        data: Data,
        limits: ResourceLimits,
        cancellation: ParseCancellation?,
        computesNormals: Bool
    ) throws -> MeshData {
        var vertices: [simd_float3] = []
        var indices: [UInt32] = []
        var vertexMap: [VertexKey: UInt32] = [:]

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw STLParserError.cannotReadFile
            }
            let count = raw.count
            var pos = 0
            var poller = CancellationPoller(cancellation)
            var pendingVerts: [simd_float3] = []
            pendingVerts.reserveCapacity(3)
            var pendingCount = 0
            var pendingInvalid = false

            while pos < count {
                try poller.tick()
                // Skip leading whitespace on the line.
                while pos < count, base[pos] == 0x20 || base[pos] == 0x09 {
                    pos += 1
                }

                // Match the literal `vertex` followed by whitespace.
                if pos + 7 <= count,
                   base[pos] == 0x76, base[pos + 1] == 0x65, base[pos + 2] == 0x72,
                   base[pos + 3] == 0x74, base[pos + 4] == 0x65, base[pos + 5] == 0x78,
                   base[pos + 6] == 0x20 || base[pos + 6] == 0x09
                {
                    pos += 6 // past `vertex`
                    let xRange = try scanFloatToken(base: base, count: count, pos: &pos, poller: &poller)
                    let yRange = try scanFloatToken(base: base, count: count, pos: &pos, poller: &poller)
                    let zRange = try scanFloatToken(base: base, count: count, pos: &pos, poller: &poller)
                    if let xRange, let yRange, let zRange {
                        let x = parseFloatBytes(base: base, range: xRange)
                        let y = parseFloatBytes(base: base, range: yRange)
                        let z = parseFloatBytes(base: base, range: zRange)
                        pendingCount += 1
                        if x.isFinite, y.isFinite, z.isFinite {
                            pendingVerts.append(simd_float3(x, y, z))
                        } else {
                            pendingInvalid = true
                        }
                        if pendingCount == 3 {
                            if !pendingInvalid, pendingVerts.count == 3 {
                                for v in pendingVerts {
                                    let key = VertexKey(x: v.x, y: v.y, z: v.z)
                                    if let existing = vertexMap[key] {
                                        indices.append(existing)
                                    } else {
                                        let idx = UInt32(vertices.count)
                                        vertexMap[key] = idx
                                        vertices.append(v)
                                        indices.append(idx)
                                    }
                                }
                            }
                            pendingVerts.removeAll(keepingCapacity: true)
                            pendingCount = 0
                            pendingInvalid = false
                            // Bound aggregate triangle count under aggressive crafted input.
                            if indices.count >= limits.maxSTLTriangles * 3 {
                                break
                            }
                        }
                    }
                } else if pos + 7 <= count,
                          base[pos] == 0x65, base[pos + 1] == 0x6E, base[pos + 2] == 0x64,
                          base[pos + 3] == 0x6C, base[pos + 4] == 0x6F, base[pos + 5] == 0x6F,
                          base[pos + 6] == 0x70
                {
                    // `endloop` — reset partial facet state so malformed loops don't shift alignment.
                    pendingVerts.removeAll(keepingCapacity: true)
                    pendingCount = 0
                    pendingInvalid = false
                }
                // Advance to next newline.
                while pos < count, base[pos] != 0x0A {
                    try poller.tick()
                    pos += 1
                }
                if pos < count {
                    pos += 1
                }
            }
        }

        guard indices.count >= 3 else { throw STLParserError.noTriangles }

        var mesh = MeshData(vertices: vertices, indices: indices, normals: nil)
        if computesNormals {
            try mesh.computeNormals(cancellation: cancellation)
        }
        return mesh
    }

    /// Skips whitespace then returns the byte range of the next non-whitespace token.
    /// Advances `pos` past the token. Returns nil at end-of-buffer.
    @inline(__always)
    private static func scanFloatToken(
        base: UnsafePointer<UInt8>,
        count: Int,
        pos: inout Int,
        poller: inout CancellationPoller
    ) throws -> Range<Int>? {
        while pos < count, base[pos] == 0x20 || base[pos] == 0x09 {
            try poller.tick()
            pos += 1
        }
        let start = pos
        while pos < count {
            try poller.tick()
            let c = base[pos]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                break
            }
            pos += 1
            // No valid STL coordinate needs an unbounded token. Stop retaining/scanning
            // absurd input while preserving the outer line scan's cancellation checks.
            if pos - start >= 256 {
                break
            }
        }
        return start < pos ? start ..< pos : nil
    }

    /// Inline float parse over a byte range — handles sign, fraction, exponent.
    @inline(__always)
    private static func parseFloatBytes(base: UnsafePointer<UInt8>, range: Range<Int>) -> Float {
        var i = range.lowerBound
        let end = range.upperBound
        guard i < end else { return 0 }

        var negative = false
        if base[i] == 0x2D {
            negative = true; i += 1
        } else if base[i] == 0x2B {
            i += 1
        }

        var intPart: Double = 0
        while i < end, base[i] >= 0x30, base[i] <= 0x39 {
            intPart = intPart * 10 + Double(base[i] - 0x30)
            i += 1
        }
        var fracPart: Double = 0
        if i < end, base[i] == 0x2E {
            i += 1
            var divisor: Double = 10
            while i < end, base[i] >= 0x30, base[i] <= 0x39 {
                fracPart += Double(base[i] - 0x30) / divisor
                divisor *= 10
                i += 1
            }
        }
        var result = intPart + fracPart
        if i < end, base[i] == 0x65 || base[i] == 0x45 {
            i += 1
            var expNeg = false
            if i < end, base[i] == 0x2D {
                expNeg = true; i += 1
            } else if i < end, base[i] == 0x2B {
                i += 1
            }
            var exp = 0
            while i < end, base[i] >= 0x30, base[i] <= 0x39 {
                if exp <= 400 {
                    exp = exp * 10 + Int(base[i] - 0x30)
                }
                i += 1
            }
            result *= pow(10.0, Double(expNeg ? -exp : exp))
        }
        return Float(negative ? -result : result)
    }
}

private struct VertexKey: Hashable {
    let ix: Int32
    let iy: Int32
    let iz: Int32

    init(x: Float, y: Float, z: Float) {
        ix = Self.quantize(x)
        iy = Self.quantize(y)
        iz = Self.quantize(z)
    }

    /// Quantize a coordinate to a fixed-point bucket without ever trapping.
    /// WHY: `Int32(Float)` fatal-errors on NaN/Inf and on any finite value outside
    /// Int32's range. A crafted STL can supply NaN/Inf (binary reinterpret, or an ASCII
    /// `1e999` that overflows to Inf) or a huge finite coord (1e30 → 1e34 after scaling) —
    /// each would crash the Quick Look extension (DoS on preview). Guard finiteness, then
    /// clamp to the representable range so degenerate vertices collapse harmlessly instead.
    @inline(__always)
    private static func quantize(_ v: Float) -> Int32 {
        guard v.isFinite else { return 0 }
        let scaled = (Double(v) * 10000).rounded()
        if scaled >= Double(Int32.max) {
            return Int32.max
        }
        if scaled <= Double(Int32.min) {
            return Int32.min
        }
        return Int32(scaled)
    }
}

/// Per-chunk scratch for the parallel STL parser. `@unchecked Sendable` is correct
/// here because `concurrentPerform` only ever passes one chunk index per closure
/// invocation — each thread touches a distinct instance.
private final class ChunkResult: @unchecked Sendable {
    var vertices: [simd_float3] = []
    var indices: [UInt32] = []
    var localMap: [VertexKey: UInt32] = [:]
}
