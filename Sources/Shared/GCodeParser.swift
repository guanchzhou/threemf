import Foundation
import os
import simd

private let log = Logger(subsystem: "com.andreymaltsev.3mf-quicklook", category: "GCode")

public enum GCodeParserError: Error, LocalizedError {
    case cannotReadFile
    case fileTooLarge
    case noSegments

    public var errorDescription: String? {
        switch self {
        case .cannotReadFile: "Cannot read G-code file"
        case .fileTooLarge: "G-code file exceeds maximum size"
        case .noSegments: "No toolpath segments found in G-code file"
        }
    }
}

/// Streaming line-oriented parser for `.gcode` files. Recognizes G0/G1 linear moves and
/// G2/G3 arcs with X/Y/Z/E/F parameters; tracks modal M82/M83 and G90/G91. Layer
/// boundaries detected by Z increase.
public enum GCodeParser {
    /// Hard cap on file size before parsing — bounds memory.
    public static let maxFileSize = ResourceLimits.cli.maxGCodeFileBytes

    /// Hard cap on segment count for the CLI (Quick Look uses ``ResourceLimits/quickLook``).
    public static let maxSegments = ResourceLimits.cli.maxGCodeSegments

    /// Finder thumbnail budget. The parser still walks the whole file (so the silhouette
    /// spans the print) but keeps at most this many segments via online stride doubling.
    public static let thumbnailSegmentBudget = 32768

    /// Target chord length (mm) when subdividing G2/G3 arcs into straight segments.
    private static let arcChordMM: Float = 0.5

    /// Per-arc segment cap so a huge radius cannot exhaust the segment budget alone.
    private static let maxSegmentsPerArc = 16384

    public static func parse(
        from fileURL: URL,
        limits: ResourceLimits = .cli,
        cancellation: ParseCancellation? = nil,
        outputSegmentBudget: Int? = nil,
        computesStatistics: Bool = true
    ) throws -> ToolpathData {
        let data: Data
        do {
            data = try BoundedFileReader.dataContents(of: fileURL, maxByteCount: limits.maxGCodeFileBytes)
        } catch BoundedFileReader.ReadError.fileTooLarge {
            throw GCodeParserError.fileTooLarge
        }
        guard !data.isEmpty else {
            throw GCodeParserError.noSegments
        }
        return try parse(
            data: data,
            limits: limits,
            cancellation: cancellation,
            outputSegmentBudget: outputSegmentBudget,
            computesStatistics: computesStatistics
        )
    }

    public static func parse(
        data: Data,
        limits: ResourceLimits = .cli,
        cancellation: ParseCancellation? = nil,
        outputSegmentBudget: Int? = nil,
        computesStatistics: Bool = true
    ) throws -> ToolpathData {
        var segments: [ToolpathSegment] = []
        var pos = simd_float3(0, 0, 0)
        var lastE: Float = 0
        var feedrate: Float = 0
        var layerIndex = 0
        var lastLayerZ: Float = -.infinity
        var totalExtrudedMM: Float = 0
        var totalTravelMM: Float = 0
        var estimatedSeconds: Double = 0
        var absoluteE = true
        var absoluteXYZ = true
        var planeIsXY = true
        let downsampleBudget: Int? = outputSegmentBudget.map { requested in
            max(2, min(requested, limits.maxGCodeSegments))
        }
        var keepStride = 1
        var moveIndex = 0
        var hitSegmentCap = false

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw GCodeParserError.cannotReadFile
            }
            let count = raw.count
            var i = 0
            var poller = CancellationPoller(cancellation)

            func emitSegment(from start: simd_float3, to end: simd_float3, extrudes: Bool) {
                var keepsSegment = true
                if let budget = downsampleBudget {
                    if segments.count >= budget {
                        compactEvenIndices(&segments)
                        if keepStride < Int.max / 2 {
                            keepStride *= 2
                        }
                    }
                    keepsSegment = moveIndex % keepStride == 0
                    moveIndex += 1
                }

                if computesStatistics || keepsSegment {
                    let segment = ToolpathSegment(
                        start: start,
                        end: end,
                        extrudes: extrudes,
                        feedrate: feedrate,
                        layerIndex: layerIndex
                    )
                    if computesStatistics {
                        let len = segment.length
                        if len > 0 {
                            if extrudes {
                                totalExtrudedMM += len
                            } else {
                                totalTravelMM += len
                            }
                            if feedrate > 0 {
                                estimatedSeconds += Double(len) / Double(feedrate / 60)
                            }
                        }
                    }
                    if keepsSegment {
                        segments.append(segment)
                    }
                }

                if downsampleBudget == nil, segments.count >= limits.maxGCodeSegments {
                    log.notice("GCodeParser: reached maxSegments cap (\(limits.maxGCodeSegments)); truncating")
                    hitSegmentCap = true
                }
            }

            func noteLayer(forZ newZ: Float) {
                if newZ > lastLayerZ + 0.001 {
                    layerIndex = lastLayerZ == -.infinity ? 0 : layerIndex + 1
                    lastLayerZ = newZ
                }
            }

            while i < count {
                try poller.tick()
                if hitSegmentCap {
                    break
                }
                // Find end of line.
                var lineEnd = i
                while lineEnd < count, base[lineEnd] != 0x0A {
                    try poller.tick()
                    lineEnd += 1
                }
                defer { i = lineEnd + 1 }
                // Real G-code lines are tiny. Bounding pathological lines also bounds all
                // secondary scans over the same range after the cancellable newline search.
                guard lineEnd - i <= 1_048_576 else { continue }

                // Skip leading whitespace.
                var p = i
                while p < lineEnd, base[p] == 0x20 || base[p] == 0x09 {
                    p += 1
                }
                guard p < lineEnd else { continue }

                // Skip comments (`;` or `()` after the command). We process the part
                // before any `;` and ignore parenthesized comments inline-by-position.
                var commentStart = lineEnd
                for j in p ..< lineEnd where base[j] == 0x3B {
                    commentStart = j; break
                }
                let endOfCode = commentStart
                guard p < endOfCode else { continue }

                let letter = base[p]
                let isG = letter == 0x47 || letter == 0x67 // G or g
                let isM = letter == 0x4D || letter == 0x6D // M or m
                guard isG || isM else { continue }
                p += 1

                // Skip leading zeros, then parse the command number (G00 → 0, G01 → 1, G10 → 10).
                var sawZero = false
                while p < endOfCode, base[p] == 0x30 {
                    sawZero = true
                    p += 1
                }
                var cmdNum = 0
                if p < endOfCode, base[p] >= 0x31, base[p] <= 0x39 {
                    while p < endOfCode, base[p] >= 0x30, base[p] <= 0x39 {
                        cmdNum = cmdNum * 10 + Int(base[p] - 0x30)
                        p += 1
                    }
                } else if sawZero {
                    cmdNum = 0
                } else {
                    continue
                }

                // Standalone modal lines (M82/M83, G90/G91, G17/G18/G19).
                if isM {
                    if cmdNum == 82 {
                        absoluteE = true
                    } else if cmdNum == 83 {
                        absoluteE = false
                    }
                    continue
                }
                if cmdNum == 90 {
                    absoluteXYZ = true
                    continue
                }
                if cmdNum == 91 {
                    absoluteXYZ = false
                    continue
                }
                if cmdNum == 17 {
                    planeIsXY = true
                    continue
                }
                if cmdNum == 18 || cmdNum == 19 {
                    planeIsXY = false
                    continue
                }

                let isLinear = cmdNum == 0 || cmdNum == 1
                let isArcCW = cmdNum == 2
                let isArcCCW = cmdNum == 3
                guard isLinear || isArcCW || isArcCCW else { continue }

                // Non-XY plane: skip arcs (G17 assumed for arcs we do handle).
                if isArcCW || isArcCCW, !planeIsXY {
                    continue
                }

                // Parse parameters: X/Y/Z/E/F and I/J/R for arcs.
                var newX = pos.x, newY = pos.y, newZ = pos.z
                var newE = lastE
                var sawE = false
                var sawX = false, sawY = false, sawZ = false
                var iOffset: Float = 0, jOffset: Float = 0
                var sawI = false, sawJ = false
                var radius: Float = 0
                var sawR = false

                while p < endOfCode {
                    while p < endOfCode, base[p] == 0x20 || base[p] == 0x09 {
                        p += 1
                    }
                    guard p < endOfCode else { break }
                    let key = base[p]
                    p += 1
                    let valStart = p
                    while p < endOfCode {
                        let c = base[p]
                        // End of token when we hit whitespace or another letter.
                        // Keep an exponent marker (`1e999`, `1E-3`) inside the number so
                        // it is not parsed as a new E-axis word.
                        if c == 0x20 || c == 0x09 {
                            break
                        }
                        let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                        if isLetter {
                            let isExponent = c == 0x45 || c == 0x65
                            if isExponent, p > valStart, p + 1 < endOfCode {
                                let prev = base[p - 1]
                                let next = base[p + 1]
                                let prevDigit = prev >= 0x30 && prev <= 0x39
                                let nextOk = (next >= 0x30 && next <= 0x39) || next == 0x2B || next == 0x2D
                                if prevDigit, nextOk {
                                    p += 1
                                    continue
                                }
                            }
                            break
                        }
                        p += 1
                    }
                    let value = parseFloat(base: base, start: valStart, end: p)

                    switch key {
                    case 0x58, 0x78: // X
                        if absoluteXYZ {
                            newX = value
                        } else {
                            newX = pos.x + value
                        }
                        sawX = true
                    case 0x59, 0x79: // Y
                        if absoluteXYZ {
                            newY = value
                        } else {
                            newY = pos.y + value
                        }
                        sawY = true
                    case 0x5A, 0x7A: // Z
                        if absoluteXYZ {
                            newZ = value
                        } else {
                            newZ = pos.z + value
                        }
                        sawZ = true
                    case 0x45, 0x65: // E
                        newE = value
                        sawE = true
                    case 0x46, 0x66: // F (sticky across moves)
                        feedrate = value
                    case 0x49, 0x69: // I
                        iOffset = value
                        sawI = true
                    case 0x4A, 0x6A: // J
                        jOffset = value
                        sawJ = true
                    case 0x52, 0x72: // R
                        radius = value
                        sawR = true
                    default: break
                    }
                }

                // Drop moves with non-finite coordinates (e.g. 1e999 → Inf).
                if (sawX && !newX.isFinite) || (sawY && !newY.isFinite) || (sawZ && !newZ.isFinite)
                    || (sawE && !newE.isFinite)
                {
                    continue
                }
                if (sawI && !iOffset.isFinite) || (sawJ && !jOffset.isFinite) || (sawR && !radius.isFinite) {
                    continue
                }

                let extrudes: Bool = if absoluteE {
                    sawE && newE > lastE
                } else {
                    sawE && newE > 0
                }

                if isLinear {
                    noteLayer(forZ: newZ)
                    let newPos = simd_float3(newX, newY, newZ)
                    emitSegment(from: pos, to: newPos, extrudes: extrudes)
                    pos = newPos
                    if absoluteE, sawE {
                        lastE = newE
                    }
                    if hitSegmentCap {
                        break
                    }
                    continue
                }

                // G2/G3 arc in the XY plane (helical Z allowed).
                let endXY = simd_float2(newX, newY)
                let startXY = simd_float2(pos.x, pos.y)
                var center: simd_float2

                if sawI || sawJ {
                    center = startXY + simd_float2(iOffset, jOffset)
                } else if sawR {
                    let dx = endXY.x - startXY.x
                    let dy = endXY.y - startXY.y
                    let d = hypot(dx, dy)
                    let absR = abs(radius)
                    // Radius must reach the endpoint (chord half-length ≤ |R|).
                    guard d > 1e-8, absR * 2 >= d - 1e-5 else { continue }
                    let halfD = d * 0.5
                    let h = sqrt(max(0, absR * absR - halfD * halfD))
                    // Unit perpendicular to the chord.
                    let invD = 1 / d
                    var hx = -dy * invD
                    var hy = dx * invD
                    // Side selection: CW vs CCW, flipped for negative R (major arc).
                    let clockwise = isArcCW
                    if clockwise != (radius < 0) {
                        hx = -hx
                        hy = -hy
                    }
                    center = simd_float2(
                        (startXY.x + endXY.x) * 0.5 + hx * h,
                        (startXY.y + endXY.y) * 0.5 + hy * h
                    )
                } else {
                    continue
                }

                let radiusVec = startXY - center
                let arcRadius = simd_length(radiusVec)
                guard arcRadius > 1e-8, arcRadius.isFinite else { continue }

                let startAngle = atan2(startXY.y - center.y, startXY.x - center.x)
                let endAngle = atan2(endXY.y - center.y, endXY.x - center.x)

                var sweep: Float
                if isArcCW {
                    sweep = startAngle - endAngle
                    if sweep <= 1e-7 {
                        sweep += 2 * Float.pi
                    }
                } else {
                    sweep = endAngle - startAngle
                    if sweep <= 1e-7 {
                        sweep += 2 * Float.pi
                    }
                }

                let arcLength = abs(arcRadius * sweep)
                var nSeg = max(1, Int(ceil(Double(arcLength / arcChordMM))))
                nSeg = min(nSeg, maxSegmentsPerArc)
                if downsampleBudget == nil {
                    let remaining = max(1, limits.maxGCodeSegments - segments.count)
                    nSeg = min(nSeg, remaining)
                }

                noteLayer(forZ: newZ)

                var prev = pos
                for s in 1 ... nSeg {
                    try poller.tick()
                    let t = Float(s) / Float(nSeg)
                    let angle: Float = if isArcCW {
                        startAngle - sweep * t
                    } else {
                        startAngle + sweep * t
                    }
                    let xy = center + simd_float2(cos(angle), sin(angle)) * arcRadius
                    let z = pos.z + (newZ - pos.z) * t
                    // Snap the final chord exactly to the commanded endpoint.
                    let end = if s == nSeg {
                        simd_float3(newX, newY, newZ)
                    } else {
                        simd_float3(xy.x, xy.y, z)
                    }
                    emitSegment(from: prev, to: end, extrudes: extrudes)
                    prev = end
                    if hitSegmentCap {
                        break
                    }
                }
                pos = prev
                if absoluteE, sawE {
                    lastE = newE
                }
                if hitSegmentCap {
                    break
                }
            }
        }

        guard !segments.isEmpty else {
            throw GCodeParserError.noSegments
        }
        // Sanitize the ETA before it leaves the parser. Crafted coords (Inf via a `1e999`
        // token, or huge-finite via `1e30`) drive this non-finite or absurdly large; a
        // downstream `Int(estimatedSeconds)` (HUD ETA, CLI) would then trap and crash the
        // preview. Clamp to [0, 100 years] — anything beyond that is meaningless and
        // keeps every consumer's Int cast in range. Root-cause fix, protects all callers.
        let safeSeconds = estimatedSeconds.isFinite
            ? min(max(estimatedSeconds, 0), 3_153_600_000) // 100 * 365.25 * 24 * 3600
            : 0
        return ToolpathData(
            segments: segments,
            layerCount: layerIndex + 1,
            totalExtrudedMM: totalExtrudedMM,
            totalTravelMM: totalTravelMM,
            estimatedSeconds: safeSeconds
        )
    }

    /// Drops odd indices so a full buffer of `budget` samples becomes ~`budget/2`.
    /// Combined with doubling `keepStride`, later moves still land in the kept set.
    private static func compactEvenIndices(_ segments: inout [ToolpathSegment]) {
        var write = 0
        for read in stride(from: 0, to: segments.count, by: 2) {
            if write != read {
                segments[write] = segments[read]
            }
            write += 1
        }
        segments.removeSubrange(write...)
    }

    /// Inline float parser over a byte range. Handles sign, fraction, exponent.
    @inline(__always)
    private static func parseFloat(base: UnsafePointer<UInt8>, start: Int, end: Int) -> Float {
        var i = start
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
                exp = exp * 10 + Int(base[i] - 0x30)
                i += 1
            }
            result *= pow(10.0, Double(expNeg ? -exp : exp))
        }
        return Float(negative ? -result : result)
    }
}
