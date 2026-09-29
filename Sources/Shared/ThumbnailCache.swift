import CryptoKit
import Foundation
import os

/// Disk-backed cache for rendered thumbnail PNGs, keyed by `(SHA-256(path), size, mtime)`.
///
/// Quick Look extensions can't write xattrs to source files (sandboxed), but they can
/// write into their own container's `Caches/` directory — which macOS auto-evicts on low
/// disk. Keying by size + mtime means edits invalidate the cache automatically; keying by
/// the path hash means moved/renamed files re-render but identical content at a stable
/// path stays cached.
///
/// Cache hits avoid the full 3MF unzip + ZIP-walk + PNG decode round-trip, which is the
/// dominant cost for an embedded-thumbnail-only render path.
public enum ThumbnailCache {
    /// Subdirectory within the extension's Caches folder.
    private static let subdirectory = "ThumbnailCache"

    /// Soft cap on the cache directory's total size. macOS auto-evicts Caches/ on low disk,
    /// but a soft cap bounds growth in the meantime — important for power users with many 3D files.
    private static let maxCacheBytes: Int = 100 * 1024 * 1024 // 100 MB

    private struct Runtime {
        var directory: URL?
        var maxCacheBytes: Int?
        var trackedDirectory: URL?
        var trackedBytes: Int?
        var storesSinceScan = 0
        var directoryScanCount = 0
    }

    /// Test isolation: production never sets this. Lets tests use a temp directory and a
    /// tiny cap without touching the user's real thumbnail cache.
    private static let runtime = OSAllocatedUnfairLock(initialState: Runtime())

    /// Runs `body` against an isolated cache directory and byte cap, then restores production
    /// defaults. Not reentrant.
    static func withIsolatedCache<T>(
        directory: URL,
        maxBytes: Int,
        _ body: () throws -> T
    ) rethrows -> T {
        runtime.withLock { $0 = Runtime(directory: directory, maxCacheBytes: maxBytes) }
        defer { runtime.withLock { $0 = Runtime() } }
        return try body()
    }

    /// Returns cached PNG data for `url` if a fresh entry exists, else nil.
    /// `extraKey` lets a single source file produce multiple cache entries (e.g. per
    /// plate for Bambu 3MFs) without aliasing — the key combines source path/size/mtime
    /// with the extra string.
    public static func cachedThumbnail(for url: URL, extraKey: String = "") -> Data? {
        guard let key = cacheKey(for: url, extraKey: extraKey) else { return nil }
        let file = cacheFileURL(for: key)
        return try? Data(contentsOf: file)
    }

    /// Stores PNG data for `url`. Best-effort: errors are silently ignored (the worst case
    /// is a cache miss next time, which is the same as no cache).
    public static func store(_ data: Data, for url: URL, extraKey: String = "") {
        guard !data.isEmpty, let key = cacheKey(for: url, extraKey: extraKey) else { return }
        let dir = cacheDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = cacheFileURL(for: key)
        let previousBytes = fileSize(at: file)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return
        }

        // Scan once to establish the process-local total, then update it by write deltas.
        // A deterministic periodic rescan reconciles writes from other processes and OS
        // cache eviction. Crossing the cap always triggers an immediate LRU scan.
        if shouldScanAfterStore(
            directory: dir,
            byteDelta: data.count - previousBytes
        ) {
            evictIfOversized()
        }
    }

    /// Walks the cache directory and removes oldest files (by access date) until total
    /// size is below `maxCacheBytes`. Public so tests can drive eviction deterministically.
    public static func evictIfOversized() {
        let fm = FileManager.default
        let dir = cacheDirectory()
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let stats: [(url: URL, size: Int, accessed: Date)] = entries.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
            guard let size = values?.fileSize else { return nil }
            return (url, size, values?.contentAccessDate ?? .distantPast)
        }
        var totalBytes = stats.reduce(0) { $0 + $1.size }
        let cap = resolvedMaxCacheBytes()
        if totalBytes > cap {
            // Oldest-accessed first.
            let oldestFirst = stats.sorted { $0.accessed < $1.accessed }
            for entry in oldestFirst {
                if totalBytes <= cap {
                    break
                }
                do {
                    try fm.removeItem(at: entry.url)
                    totalBytes -= entry.size
                } catch {
                    continue
                }
            }
        }
        recordDirectoryScan(directory: dir, totalBytes: totalBytes)
    }

    // MARK: - Internal

    /// Cache key combines a stable hash of the file path (+ optional extraKey) with
    /// size + mtime so any edit or move produces a different key (cache miss) without
    /// tracking inode changes. `extraKey` discriminates per-plate / per-variant entries.
    private static func cacheKey(for url: URL, extraKey: String = "") -> String? {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int,
            let mtime = attrs[.modificationDate] as? Date
        else { return nil }

        let composite = extraKey.isEmpty ? url.path : "\(url.path)::\(extraKey)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        // 16 hex chars (64 bits) of the path hash is plenty for collision avoidance
        // among a single user's thumbnailable files.
        let pathHash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        // Milliseconds so two writes in the same second with different fractional
        // mtimes don't share a key.
        let mtimeMs = Int((mtime.timeIntervalSince1970 * 1000).rounded())
        return "\(pathHash)-\(size)-\(mtimeMs)"
    }

    private static func resolvedMaxCacheBytes() -> Int {
        runtime.withLock { $0.maxCacheBytes } ?? maxCacheBytes
    }

    private static func fileSize(at url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func shouldScanAfterStore(directory: URL, byteDelta: Int) -> Bool {
        runtime.withLock { state in
            guard
                state.trackedDirectory == directory,
                let trackedBytes = state.trackedBytes
            else {
                return true
            }
            let updatedBytes = max(0, trackedBytes + byteDelta)
            state.trackedBytes = updatedBytes
            state.storesSinceScan += 1
            return updatedBytes > (state.maxCacheBytes ?? maxCacheBytes)
                || state.storesSinceScan >= 32
        }
    }

    private static func recordDirectoryScan(directory: URL, totalBytes: Int) {
        runtime.withLock { state in
            state.trackedDirectory = directory
            state.trackedBytes = totalBytes
            state.storesSinceScan = 0
            state.directoryScanCount += 1
        }
    }

    static var testDirectoryScanCount: Int {
        runtime.withLock { $0.directoryScanCount }
    }

    private static func cacheDirectory() -> URL {
        if let override = runtime.withLock({ $0.directory }) {
            return override
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(subdirectory, isDirectory: true)
    }

    private static func cacheFileURL(for key: String) -> URL {
        cacheDirectory()
            .appendingPathComponent(key)
            .appendingPathExtension("png")
    }
}
