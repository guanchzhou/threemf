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

/// Streaming line-oriented parser for `.gcode` files. Recognizes G0/G1 moves with
/// X/Y/Z/E/F parameters; ignores everything else. Tracks current position and emits
/// one `ToolpathSegment` per move. Layer boundaries detected by Z increase.
public enum GCodeParser {
    /// Hard cap on file size before parsing — bounds memory.
    public static let maxFileSize = 500 * 1024 * 1024

    /// Hard cap on segment count to prevent OOM via crafted input.
    public static let maxSegments = 20_000_000

    public static func parse(from fileURL: URL) throws -> ToolpathData {
        let data = try Data(contentsOf: fileURL)
        guard data.count <= maxFileSize else {
            throw GCodeParserError.fileTooLarge
        }
        guard !data.isEmpty else {
            throw GCodeParserError.noSegments
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> ToolpathData {
        var segments: [ToolpathSegment] = []
        var pos = simd_float3(0, 0, 0)
        var lastE: Float = 0
        var feedrate: Float = 0
        var layerIndex = 0
        var lastLayerZ: Float = -.infinity
        var totalExtrudedMM: Float = 0
        var totalTravelMM: Float = 0
        var estimatedSeconds: Double = 0

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw GCodeParserError.cannotReadFile
            }
            let count = raw.count
            var i = 0

            while i < count {
                // Find end of line.
                var lineEnd = i
                while lineEnd < count, base[lineEnd] != 0x0A {
                    lineEnd += 1
                }
                defer { i = lineEnd + 1 }

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

                // Recognize G0 / G1 (case-insensitive). Anything else: skip line.
                guard endOfCode - p >= 2 else { continue }
                let c0 = base[p]
                let c1 = base[p + 1]
                let isG = (c0 == 0x47 || c0 == 0x67) // G or g
                let cmd = (c1 == 0x30 || c1 == 0x31) // 0 or 1
                guard isG, cmd else { continue }
                // Boundary check after G0/G1 — accept if next byte is whitespace, digit
                // beyond 1 means a different command (G10, G11) which we ignore for now.
                if p + 2 < endOfCode {
                    let c2 = base[p + 2]
                    if c2 >= 0x30, c2 <= 0x39 { continue } // G10, G11, G12, etc.
                }
                p += 2

                // Parse parameters: X<f> Y<f> Z<f> E<f> F<f>.
                var newX = pos.x, newY = pos.y, newZ = pos.z
                var newE = lastE
                var sawE = false

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
                        if c == 0x20 || c == 0x09 { break }
                        if c >= 0x41, c <= 0x5A { break } // A-Z
                        if c >= 0x61, c <= 0x7A { break } // a-z
                        p += 1
                    }
                    let value = parseFloat(base: base, start: valStart, end: p)

                    switch key {
                    case 0x58, 0x78: newX = value // X
                    case 0x59, 0x79: newY = value // Y
                    case 0x5A, 0x7A: newZ = value // Z
                    case 0x45, 0x65: newE = value; sawE = true // E
                    case 0x46, 0x66: feedrate = value // F (sticky across moves)
                    default: break
                    }
                }

                // Layer detection: Z increased relative to last layer's Z.
                if newZ > lastLayerZ + 0.001 {
                    layerIndex = lastLayerZ == -.infinity ? 0 : layerIndex + 1
                    lastLayerZ = newZ
                }

                let newPos = simd_float3(newX, newY, newZ)
                let extrudes = sawE && newE > lastE
                let segment = ToolpathSegment(
                    start: pos,
                    end: newPos,
                    extrudes: extrudes,
                    feedrate: feedrate,
                    layerIndex: layerIndex
                )
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
                segments.append(segment)
                pos = newPos
                lastE = newE

                if segments.count >= maxSegments {
                    log.notice("GCodeParser: reached maxSegments cap (\(Self.maxSegments)); truncating")
                    break
                }
            }
        }

        guard !segments.isEmpty else {
            throw GCodeParserError.noSegments
        }
        return ToolpathData(
            segments: segments,
            layerCount: layerIndex + 1,
            totalExtrudedMM: totalExtrudedMM,
            totalTravelMM: totalTravelMM,
            estimatedSeconds: estimatedSeconds
        )
    }

    /// Inline float parser over a byte range. Handles sign, fraction, exponent.
    @inline(__always)
    private static func parseFloat(base: UnsafePointer<UInt8>, start: Int, end: Int) -> Float {
        var i = start
        guard i < end else { return 0 }
        var negative = false
        if base[i] == 0x2D { negative = true; i += 1 }
        else if base[i] == 0x2B { i += 1 }
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
            if i < end, base[i] == 0x2D { expNeg = true; i += 1 }
            else if i < end, base[i] == 0x2B { i += 1 }
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
