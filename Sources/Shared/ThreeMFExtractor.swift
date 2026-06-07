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

    /// Hard cap on entries scanned during the fallback PNG search. Bounds work on
    /// archives with very large central directories; we only need to find one PNG.
    private static let maxFallbackEntries = 256

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

    public static func extractThumbnail(from fileURL: URL) throws -> Data {
        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            throw ThreeMFExtractorError.cannotOpenArchive
        }

        // Try known paths first (fast path)
        for path in knownThumbnailPaths {
            if let entry = archive[path] {
                guard entry.uncompressedSize <= UInt64(maxThumbnailSize) else {
                    throw ThreeMFExtractorError.thumbnailTooLarge
                }
                var data = Data()
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                    if data.count > maxThumbnailSize {
                        throw ThreeMFExtractorError.thumbnailTooLarge
                    }
                }
                if !data.isEmpty {
                    return data
                }
            }
        }

        // Fallback: find any PNG in thumbnail-like directories.
        // Bounded by maxFallbackEntries to prevent pathological archives from stalling.
        var scanned = 0
        for entry in archive {
            scanned += 1
            if scanned > maxFallbackEntries { break }
            let path = entry.path.lowercased()
            if path.hasSuffix(".png"),
               path.hasPrefix("metadata/") || path.hasPrefix("thumbnail/")
            {
                guard entry.uncompressedSize <= UInt64(maxThumbnailSize) else {
                    throw ThreeMFExtractorError.thumbnailTooLarge
                }
                var data = Data()
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                    if data.count > maxThumbnailSize {
                        throw ThreeMFExtractorError.thumbnailTooLarge
                    }
                }
                if !data.isEmpty {
                    return data
                }
            }
        }

        throw ThreeMFExtractorError.noThumbnailFound
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
        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            return []
        }

        // One entry per real plate. Bambu emits several PNGs per plate
        // (`plate_<N>.png`, `plate_<N>_small.png`, `plate_no_light_<N>.png`, `top_<N>.png`);
        // only the canonical full-size render — basename exactly `plate_<N>.png` or, as a
        // fallback, `top_<N>.png` — counts as a plate. Anything with an extra suffix is a variant.
        // `kind` 0 = plate (preferred), 1 = top; we keep one path per plate index.
        var byIndex: [Int: (kind: Int, path: String)] = [:]
        var scanned = 0

        for entry in archive {
            scanned += 1
            if scanned > maxFallbackEntries { break }
            let lower = entry.path.lowercased()
            guard lower.hasPrefix("metadata/"), lower.hasSuffix(".png") else { continue }
            let basename = String(lower.split(separator: "/").last ?? "")
            guard let (kind, idx) = Self.plateKindAndIndex(basename: basename) else { continue }
            guard entry.uncompressedSize <= UInt64(maxThumbnailSize) else { continue }
            // Prefer the `plate_` render over `top_` for the same index; keep the first of a kind.
            if let existing = byIndex[idx], existing.kind <= kind { continue }
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

        let archive = try Archive(url: fileURL, accessMode: .read)
        guard let entry = archive[plate.path] else { return nil }
        guard entry.uncompressedSize <= UInt64(maxThumbnailSize) else {
            throw ThreeMFExtractorError.thumbnailTooLarge
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
            if data.count > maxThumbnailSize {
                throw ThreeMFExtractorError.thumbnailTooLarge
            }
        }
        guard !data.isEmpty else { return nil }
        ThumbnailCache.store(data, for: fileURL, extraKey: plate.path)
        return data
    }

    /// Extracts and parses Bambu/Orca per-plate JSON metadata (`Metadata/plate_<N>.json`).
    /// Returns nil if the archive lacks the JSON for that plate or it can't be parsed.
    /// Bounded by `maxThumbnailSize` (the JSON is small in practice — a few KB).
    public static func extractPlateInfo(plateIndex: Int, from fileURL: URL) -> BambuPlateInfo? {
        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            return nil
        }
        let candidatePaths = [
            "Metadata/plate_\(plateIndex).json",
            "Metadata/plate_\(plateIndex)/plate_\(plateIndex).json",
        ]
        for path in candidatePaths {
            guard let entry = archive[path] else { continue }
            guard entry.uncompressedSize <= UInt64(maxThumbnailSize) else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                    if data.count > maxThumbnailSize {
                        throw ThreeMFExtractorError.thumbnailTooLarge
                    }
                }
            } catch {
                continue
            }
            if let info = BambuPlateInfo.parse(data) { return info }
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
            if let n = Int(mid) { return (kind, n) }
        }
        return nil
    }
}
