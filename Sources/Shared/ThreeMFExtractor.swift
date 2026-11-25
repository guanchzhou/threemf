import Foundation
import ZIPFoundation

public enum ThreeMFExtractorError: Error, LocalizedError {
    case cannotOpenArchive
    case noThumbnailFound
    case thumbnailTooLarge

    public var errorDescription: String? {
        switch self {
        case .cannotOpenArchive:
            "Cannot open .3mf archive"
        case .noThumbnailFound:
            "No thumbnail image found in .3mf file"
        case .thumbnailTooLarge:
            "Thumbnail image exceeds maximum allowed size"
        }
    }
}

public enum ThreeMFExtractor {
    /// Maximum allowed thumbnail size (10 MB) to prevent ZIP bomb attacks
    private static let maxThumbnailSize = 10 * 1024 * 1024

    /// Aggregate decompression byte budget across all thumbnail candidates in one call (24 MB).
    static let maxAggregateExtractBytes = 24 * 1024 * 1024

    /// Cap on *candidate* thumbnail paths considered during the extractThumbnail fallback.
    /// Only paths under `metadata/` / `thumbnail/` with a `.png` suffix count; model entries
    /// do not. Bounds extraction attempts, not directory walks.
    static let maxFallbackCandidates = 32

    private final class ExtractionBudget {
        private(set) var remaining: Int

        init(_ total: Int) {
            remaining = total
        }

        func consume(_ byteCount: Int) throws {
            guard byteCount >= 0, byteCount <= remaining else {
                remaining = 0
                throw ThreeMFExtractorError.thumbnailTooLarge
            }
            remaining -= byteCount
        }
    }

    private static let knownThumbnailPaths = [
        "Metadata/plate_1.png",
        "Metadata/plate_2.png",
        "Metadata/plate_3.png",
        "Metadata/plate_4.png",
        "Metadata/thumbnail.png",
        "Metadata/top_1.png",
        "Metadata/top_2.png",
        "Metadata/top_3.png",
        "Metadata/top_4.png",
        "thumbnail/thumbnail1.png",
        "thumbnail/thumbnail.png",
        "3D/Metadata/thumbnail.png",
    ]

    public static func extractThumbnail(
        from fileURL: URL,
        cancellation: ParseCancellation? = nil
    ) throws -> Data {
        try cancellation?.check()
        let archive: ThreeMFArchive
        do {
            archive = try ThreeMFArchive(url: fileURL)
        } catch {
            throw ThreeMFExtractorError.cannotOpenArchive
        }
        return try extractThumbnail(from: archive, cancellation: cancellation)
    }

    /// Returns the first candidate that extracts and validates as a PNG. A corrupt or oversized
    /// candidate does not end the search until the aggregate decompression budget is exhausted;
    /// cancellation aborts immediately.
    static func extractThumbnail(
        from archive: ThreeMFArchive,
        cancellation: ParseCancellation? = nil,
        aggregateByteBudget: Int = maxAggregateExtractBytes
    ) throws -> Data {
        var sawTooLarge = false
        var tried = Set<String>()
        let budget = ExtractionBudget(aggregateByteBudget)

        func attempt(_ entry: Entry) throws -> Data? {
            try cancellation?.check()
            do {
                return try validatedPNG(
                    extractThumbnailEntry(
                        entry,
                        from: archive,
                        budget: budget,
                        cancellation: cancellation
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch ThreeMFExtractorError.thumbnailTooLarge {
                sawTooLarge = true
            } catch {}
            return nil
        }

        for path in knownThumbnailPaths {
            try cancellation?.check()
            guard budget.remaining > 0 else { break }
            guard let entry = archive.entry(path) else { continue }
            tried.insert(path)
            if let data = try attempt(entry) {
                return data
            }
        }

        // Fallback: any PNG in thumbnail-like directories, in central-directory order.
        var candidates = 0
        for entry in archive.entries {
            try cancellation?.check()
            guard budget.remaining > 0 else { break }
            let path = entry.path.lowercased()
            guard path.hasSuffix(".png"),
                  path.hasPrefix("metadata/") || path.hasPrefix("thumbnail/"),
                  !tried.contains(entry.path)
            else { continue }
            candidates += 1
            if candidates > maxFallbackCandidates {
                break
            }
            tried.insert(entry.path)
            if let data = try attempt(entry) {
                return data
            }
        }

        throw sawTooLarge ? ThreeMFExtractorError.thumbnailTooLarge : ThreeMFExtractorError.noThumbnailFound
    }

    private static func extractThumbnailEntry(
        _ entry: Entry,
        from archive: ThreeMFArchive,
        budget: ExtractionBudget? = nil,
        cancellation: ParseCancellation? = nil
    ) throws -> Data {
        try cancellation?.check()
        guard entry.uncompressedSize <= UInt64(maxThumbnailSize) else {
            throw ThreeMFExtractorError.thumbnailTooLarge
        }
        if let budget, entry.uncompressedSize > UInt64(budget.remaining) {
            throw ThreeMFExtractorError.thumbnailTooLarge
        }
        var data = Data()
        _ = try archive.archive.extract(entry) { chunk in
            try cancellation?.check()
            if data.count + chunk.count > maxThumbnailSize {
                throw ThreeMFExtractorError.thumbnailTooLarge
            }
            try budget?.consume(chunk.count)
            data.append(chunk)
        }
        return data
    }

    private static func validatedPNG(_ data: Data) throws -> Data {
        do {
            try SafePNGValidator.validatePNGData(data)
        } catch SafePNGValidator.ValidationError.dimensionsTooLarge {
            throw ThreeMFExtractorError.thumbnailTooLarge
        } catch {
            throw ThreeMFExtractorError.noThumbnailFound
        }
        return data
    }

    /// Reference to a plate thumbnail inside a 3MF archive — path + index only, no data.
    /// Use `extractPlate(_:from:)` to load the PNG bytes on demand.
    public struct PlateThumbnail: Sendable, Hashable {
        /// Archive path (e.g. `Metadata/plate_1.png`) — used as a stable display label.
        public let path: String
        /// 1-based plate index parsed from the filename when present, else `nil`.
        public let index: Int?

        public init(path: String, index: Int?) {
            self.path = path
            self.index = index
        }
    }

    /// Lists plate thumbnail references in plate-index order. Lazy: does not extract
    /// PNG bytes — call `extractPlate(_:from:)` to load on demand. This avoids paying the
    /// extraction cost for plates the user never views.
    /// Returns `[]` for archives without plate metadata (common for non-Bambu 3MFs).
    public static func listPlates(from fileURL: URL) -> [PlateThumbnail] {
        guard let archive = try? ThreeMFArchive(url: fileURL) else { return [] }
        return listPlates(from: archive)
    }

    static func listPlates(from archive: ThreeMFArchive) -> [PlateThumbnail] {
        // One entry per real plate. Bambu emits several PNGs per plate
        // (`plate_<N>.png`, `plate_<N>_small.png`, `plate_no_light_<N>.png`, `top_<N>.png`);
        // only the canonical full-size render — basename exactly `plate_<N>.png` or, as a
        // fallback, `top_<N>.png` — counts as a plate. Anything with an extra suffix is a variant.
        // `kind` 0 = plate (preferred), 1 = top; we keep one path per plate index.
        var byIndex: [Int: (kind: Int, path: String)] = [:]

        for entry in archive.entries {
            let lower = entry.path.lowercased()
            guard lower.hasPrefix("metadata/"), lower.hasSuffix(".png") else { continue }
            let basename = String(lower.split(separator: "/").last ?? "")
            guard let (kind, idx) = Self.plateKindAndIndex(basename: basename) else { continue }
            guard entry.uncompressedSize <= UInt64(maxThumbnailSize) else { continue }
            // Prefer the `plate_` render over `top_` for the same index; keep the first of a kind.
            if let existing = byIndex[idx], existing.kind <= kind {
                continue
            }
            byIndex[idx] = (kind, entry.path)
        }

        return byIndex.keys.sorted().map { idx in
            PlateThumbnail(path: byIndex[idx]!.path, index: idx)
        }
    }

    /// Extracts the PNG bytes for a single plate. **Throws** if the archive can't be
    /// opened or the entry exceeds `maxThumbnailSize`. **Returns nil** when the plate
    /// path is not present in the archive (e.g. listing was stale).
    /// Repeated calls hit `ThumbnailCache` — keyed by `<archive-path>:<plate-path>` — so
    /// cycling between plates only pays the ZIP-extract cost once per plate per file mtime.
    public static func extractPlate(_ plate: PlateThumbnail, from fileURL: URL) throws -> Data? {
        // Cache hit: skip the ZIP extraction entirely. extraKey discriminates per-plate
        // entries within the same source archive.
        if let cached = ThumbnailCache.cachedThumbnail(for: fileURL, extraKey: plate.path) {
            return cached
        }
        return try extractPlate(plate, from: ThreeMFArchive(url: fileURL))
    }

    static func extractPlate(_ plate: PlateThumbnail, from archive: ThreeMFArchive) throws -> Data? {
        if let cached = ThumbnailCache.cachedThumbnail(for: archive.url, extraKey: plate.path) {
            return cached
        }
        guard let entry = archive.entry(plate.path) else { return nil }
        let data = try extractThumbnailEntry(entry, from: archive)
        guard !data.isEmpty else { return nil }
        let safe = try validatedPNG(data)
        ThumbnailCache.store(safe, for: archive.url, extraKey: plate.path)
        return safe
    }

    /// Extracts and parses Bambu/Orca per-plate JSON metadata (`Metadata/plate_<N>.json`).
    /// Returns nil if the archive lacks the JSON for that plate or it can't be parsed.
    /// Bounded by `maxThumbnailSize` (the JSON is small in practice — a few KB).
    public static func extractPlateInfo(plateIndex: Int, from fileURL: URL) -> BambuPlateInfo? {
        guard let archive = try? ThreeMFArchive(url: fileURL) else { return nil }
        return extractPlateInfo(plateIndex: plateIndex, from: archive)
    }

    static func extractPlateInfo(plateIndex: Int, from archive: ThreeMFArchive) -> BambuPlateInfo? {
        let candidatePaths = [
            "Metadata/plate_\(plateIndex).json",
            "Metadata/plate_\(plateIndex)/plate_\(plateIndex).json",
        ]
        for path in candidatePaths {
            guard let entry = archive.entry(path),
                  let data = try? extractThumbnailEntry(entry, from: archive)
            else { continue }
            if let info = BambuPlateInfo.parse(data) {
                return info
            }
        }
        return nil
    }

    /// Classifies a lowercased `Metadata/` PNG basename as a canonical plate render.
    /// Returns `(kind, index)` where kind 0 = `plate_<N>.png` (preferred), 1 = `top_<N>.png`.
    /// Returns nil for per-plate variants (`plate_<N>_small.png`, `plate_no_light_<N>.png`,
    /// `pick_<N>.png`, …) and non-plate PNGs — the exact-integer parse rejects any basename
    /// with an extra suffix after the number, so each real plate is counted once.
    static func plateKindAndIndex(basename: String) -> (kind: Int, index: Int)? {
        for (prefix, kind) in [("plate_", 0), ("top_", 1)] {
            guard basename.hasPrefix(prefix), basename.hasSuffix(".png") else { continue }
            let mid = basename.dropFirst(prefix.count).dropLast(4) // strip prefix and ".png"
            if let n = Int(mid) {
                return (kind, n)
            }
        }
        return nil
    }
}
