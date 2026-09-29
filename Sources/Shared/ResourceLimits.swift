import Foundation

/// Per-surface caps for parsing 3D-print files. Quick Look and Spotlight use tighter
/// budgets than the headless CLI so extension processes stay within jetsam limits.
public struct ResourceLimits: Sendable {
    public var maxModelExtractBytes: UInt64
    public var maxMetadataSidecarBytes: UInt64
    public var maxVertices: Int
    public var maxTriangles: Int
    public var maxSTLTriangles: Int
    public var maxSTLFileBytes: Int
    public var maxGCodeFileBytes: Int
    public var maxGCodeSegments: Int
    /// Cap on segments kept for interactive Quick Look display. The parser still walks
    /// the whole file (layer indexes + length/ETA stats) when this budget is set.
    public var previewGCodeSegments: Int

    public static let cli = ResourceLimits(
        maxModelExtractBytes: 500 * 1024 * 1024,
        maxMetadataSidecarBytes: 8 * 1024 * 1024,
        maxVertices: 50_000_000,
        maxTriangles: 100_000_000,
        maxSTLTriangles: 50_000_000,
        maxSTLFileBytes: 2 * 1024 * 1024 * 1024,
        maxGCodeFileBytes: 500 * 1024 * 1024,
        maxGCodeSegments: 20_000_000,
        previewGCodeSegments: 20_000_000
    )

    public static let quickLook = ResourceLimits(
        maxModelExtractBytes: 80 * 1024 * 1024,
        maxMetadataSidecarBytes: 4 * 1024 * 1024,
        maxVertices: 10_000_000,
        maxTriangles: 20_000_000,
        maxSTLTriangles: 10_000_000,
        maxSTLFileBytes: 100 * 1024 * 1024,
        maxGCodeFileBytes: 200 * 1024 * 1024,
        maxGCodeSegments: 2_000_000,
        previewGCodeSegments: 131_072
    )

    /// Spotlight mesh/toolpath indexing for files under the large-file fast-path threshold.
    public static let spotlight = quickLook
}
