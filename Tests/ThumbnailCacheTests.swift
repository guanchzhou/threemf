import Foundation
import XCTest

final class ThumbnailCacheTests: XCTestCase {
    /// Each test gets a unique source file so cache keys don't collide between tests.
    private func makeSourceFile(content: String = "test", ext: String = "stl") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-src-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    private let png: Data = // Minimal valid PNG (1×1 pixel, no compression). Just bytes — we don't render it.
        .init([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x00, 0x00, 0x00, 0x00, 0x3B, 0x7E, 0x9B,
            0x55, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82,
        ])

    func testCacheMiss_returnsNil() throws {
        let url = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ThumbnailCache.cachedThumbnail(for: url))
    }

    func testStoreAndRetrieve_roundTrip() throws {
        let url = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: url) }

        ThumbnailCache.store(png, for: url)
        let cached = ThumbnailCache.cachedThumbnail(for: url)
        XCTAssertEqual(cached, png)
    }

    func testInvalidation_onMtimeChange() throws {
        let url = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: url) }

        ThumbnailCache.store(png, for: url)
        XCTAssertNotNil(ThumbnailCache.cachedThumbnail(for: url))

        // Touch the file — the cache key includes mtime, so this should miss.
        let later = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        XCTAssertNil(ThumbnailCache.cachedThumbnail(for: url))
    }

    func testDifferentPaths_haveDifferentKeys() throws {
        let url1 = try makeSourceFile(content: "first")
        let url2 = try makeSourceFile(content: "second")
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        let pngA = Data([0x01, 0x02, 0x03])
        let pngB = Data([0x04, 0x05, 0x06])
        ThumbnailCache.store(pngA, for: url1)
        ThumbnailCache.store(pngB, for: url2)

        XCTAssertEqual(ThumbnailCache.cachedThumbnail(for: url1), pngA)
        XCTAssertEqual(ThumbnailCache.cachedThumbnail(for: url2), pngB)
    }

    func testEvictIfOversized_isNoOpWhenUnderLimit() throws {
        let url = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: url) }

        ThumbnailCache.store(png, for: url)
        // Below the soft cap; no eviction should occur.
        ThumbnailCache.evictIfOversized()
        XCTAssertNotNil(ThumbnailCache.cachedThumbnail(for: url))
    }

    func testStoreEmpty_isNoOp() throws {
        let url = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: url) }

        ThumbnailCache.store(Data(), for: url)
        XCTAssertNil(ThumbnailCache.cachedThumbnail(for: url))
    }
}
