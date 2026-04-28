import Foundation
import ZIPFoundation

enum ThreeMFExtractorError: Error, LocalizedError {
    case cannotOpenArchive
    case noThumbnailFound
    case thumbnailTooLarge

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive:
            return "Cannot open .3mf archive"
        case .noThumbnailFound:
            return "No thumbnail image found in .3mf file"
        case .thumbnailTooLarge:
            return "Thumbnail image exceeds maximum allowed size"
        }
    }
}

struct ThreeMFExtractor {
    /// Maximum allowed thumbnail size (10 MB) to prevent ZIP bomb attacks
    private static let maxThumbnailSize = 10 * 1024 * 1024

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

    static func extractThumbnail(from fileURL: URL) throws -> Data {
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

        // Fallback: find any PNG in thumbnail-like directories
        for entry in archive {
            let path = entry.path.lowercased()
            if path.hasSuffix(".png") &&
                (path.hasPrefix("metadata/") || path.hasPrefix("thumbnail/")) {
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
}
