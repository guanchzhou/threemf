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

    func testInvalidation_onSubsecondMtimeChange() throws {
        let url = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // Same whole second, different fractional mtime — key uses milliseconds.
        let first = Date(timeIntervalSince1970: 1_700_000_000.100)
        try FileManager.default.setAttributes([.modificationDate: first], ofItemAtPath: url.path)
        ThumbnailCache.store(png, for: url)
        XCTAssertNotNil(ThumbnailCache.cachedThumbnail(for: url))

        let sameSecond = Date(timeIntervalSince1970: 1_700_000_000.900)
        try FileManager.default.setAttributes([.modificationDate: sameSecond], ofItemAtPath: url.path)
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

    func testStore_evictsOldestWhenOverCap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let blob = Data(repeating: 0xAB, count: 40)
        let a = try makeSourceFile(content: "a")
        let b = try makeSourceFile(content: "b")
        let c = try makeSourceFile(content: "c")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
            try? FileManager.default.removeItem(at: c)
        }

        try ThumbnailCache.withIsolatedCache(directory: dir, maxBytes: 90) {
            ThumbnailCache.store(blob, for: a)
            let afterA = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            XCTAssertEqual(afterA.count, 1)
            var oldest = afterA[0]
            var stale = URLResourceValues()
            stale.contentAccessDate = Date.distantPast
            try oldest.setResourceValues(stale)

            ThumbnailCache.store(blob, for: b)
            ThumbnailCache.store(blob, for: c)

            XCTAssertNil(ThumbnailCache.cachedThumbnail(for: a))
            XCTAssertEqual(ThumbnailCache.cachedThumbnail(for: b), blob)
            XCTAssertEqual(ThumbnailCache.cachedThumbnail(for: c), blob)
        }
    }

    func testStore_reusesTrackedSizeBelowCap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try makeSourceFile(content: "a")
        let b = try makeSourceFile(content: "b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        ThumbnailCache.withIsolatedCache(directory: dir, maxBytes: 1024) {
            ThumbnailCache.store(png, for: a)
            XCTAssertEqual(ThumbnailCache.testDirectoryScanCount, 1)

            ThumbnailCache.store(png, for: b)
            XCTAssertEqual(ThumbnailCache.testDirectoryScanCount, 1)
        }
    }
}
