import Foundation
import simd

/// One straight-line move in a G-code program: `start → end`. Extrusion vs travel is
/// distinguished by `extrudes`. Feedrate is in mm/min as it appears in the G-code.
public struct ToolpathSegment: Sendable, Hashable {
    public let start: simd_float3
    public let end: simd_float3
    public let extrudes: Bool
    public let feedrate: Float
    public let layerIndex: Int

    public init(
        start: simd_float3,
        end: simd_float3,
        extrudes: Bool,
        feedrate: Float,
        layerIndex: Int
    ) {
        self.start = start
        self.end = end
        self.extrudes = extrudes
        self.feedrate = feedrate
        self.layerIndex = layerIndex
    }

    /// Euclidean length of the move (mm).
    public var length: Float {
        simd_length(end - start)
    }
}

/// Parsed result of a G-code file. Independent from `MeshData` because toolpaths are
/// line-segment-oriented rather than triangle-oriented.
public struct ToolpathData: Sendable {
    public var segments: [ToolpathSegment]
    public var layerCount: Int
    public var totalExtrudedMM: Float
    public var totalTravelMM: Float
    /// Estimated print time in seconds. Sum of `length / (feedrate/60)` across segments
    /// where feedrate > 0; segments without feedrate contribute 0 time.
    public var estimatedSeconds: Double

    public init(
        segments: [ToolpathSegment] = [],
        layerCount: Int = 0,
        totalExtrudedMM: Float = 0,
        totalTravelMM: Float = 0,
        estimatedSeconds: Double = 0
    ) {
        self.segments = segments
        self.layerCount = layerCount
        self.totalExtrudedMM = totalExtrudedMM
        self.totalTravelMM = totalTravelMM
        self.estimatedSeconds = estimatedSeconds
    }

    /// Axis-aligned bounding box across all segment endpoints. O(N).
    public var boundingBox: BoundingBox {
        guard let first = segments.first?.start else {
            return BoundingBox(min: .zero, max: .zero)
        }
        var lo = first
        var hi = first
        for s in segments {
            lo = simd_min(lo, s.start)
            lo = simd_min(lo, s.end)
            hi = simd_max(hi, s.start)
            hi = simd_max(hi, s.end)
        }
        return BoundingBox(min: lo, max: hi)
    }
}
