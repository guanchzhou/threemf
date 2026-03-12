import Foundation
import ZIPFoundation

enum ThreeMFExtractorError: Error, LocalizedError {
    case cannotOpenArchive
    case noThumbnailFound

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive:
            return "Cannot open .3mf archive"
        case .noThumbnailFound:
            return "No thumbnail image found in .3mf file"
        }
    }
}

struct ThreeMFExtractor {
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
        guard let archive = Archive(url: fileURL, accessMode: .read) else {
            throw ThreeMFExtractorError.cannotOpenArchive
        }

        // Try known paths first (fast path)
        for path in knownThumbnailPaths {
            if let entry = archive[path] {
                var data = Data()
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
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
                var data = Data()
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                }
                if !data.isEmpty {
                    return data
                }
            }
        }

        throw ThreeMFExtractorError.noThumbnailFound
    }
}
