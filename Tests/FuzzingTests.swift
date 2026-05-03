import Foundation
import Testing
import ZIPFoundation

/// Smoke-fuzzing harness using swift-testing's `@Test` macros (XCTest version migrated).
/// Feeds randomized byte sequences to STLParser and ThreeMFMeshParser to assert they
/// never crash. Any thrown error is acceptable; the contract is "no UB / no crash".
///
/// Uses a deterministic seeded RNG so failures are reproducible. Defaults to 200 iterations
/// per suite; set `THREEMF_FUZZ_ITERATIONS` for longer runs in nightly CI.
@Suite("Parser fuzzing")
struct FuzzingTests {
    private var iterations: Int {
        if let env = ProcessInfo.processInfo.environment["THREEMF_FUZZ_ITERATIONS"],
           let n = Int(env)
        {
            return n
        }
        return 200
    }

    @Test("STL parser never crashes on random bytes")
    func fuzzSTLRandom() throws {
        var rng = SeededRNG(seed: 0xC0FFEE)
        for _ in 0 ..< iterations {
            let bytes = randomBytes(length: rng.uniform(in: 0 ... 8192), rng: &rng)
            let url = try writeTempFile(bytes: bytes, ext: "stl")
            defer { try? FileManager.default.removeItem(at: url) }
            // Either succeeds or throws — anything else (crash, abort, infinite loop) is the bug.
            _ = try? STLParser.parseMesh(from: url)
        }
    }

    @Test("3MF parser never crashes on random bytes")
    func fuzz3MFRandomBytes() throws {
        // Random byte sequences mostly fail at the ZIP layer; this exercises that path.
        var rng = SeededRNG(seed: 0xBEEF)
        for _ in 0 ..< iterations {
            let bytes = randomBytes(length: rng.uniform(in: 0 ... 8192), rng: &rng)
            let url = try writeTempFile(bytes: bytes, ext: "3mf")
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try? ThreeMFMeshParser.parseMesh(from: url)
        }
    }

    @Test("3MF FastMeshScanner never crashes on random XML-like bytes")
    func fuzz3MFRandomXML() throws {
        // Build a valid ZIP whose model file is random XML-like garbage.
        // This stresses FastMeshScanner on byte sequences that reach the parser
        // but aren't well-formed.
        var rng = SeededRNG(seed: 0xDEAD_BEEF)
        for _ in 0 ..< iterations {
            let xml = randomXMLLike(rng: &rng)
            let url = try makeArchive(modelXML: xml)
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try? ThreeMFMeshParser.parseMesh(from: url)
        }
    }

    // MARK: - Helpers

    private func writeTempFile(bytes: [UInt8], ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try Data(bytes).write(to: url)
        return url
    }

    private func makeArchive(modelXML: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-\(UUID().uuidString)")
            .appendingPathExtension("3mf")
        let archive = try Archive(url: url, accessMode: .create)
        let data = modelXML.data(using: .utf8) ?? Data()
        try archive.addEntry(
            with: "3D/3dmodel.model",
            type: .file,
            uncompressedSize: UInt32(data.count),
            provider: { position, size in
                data.subdata(in: position ..< position + size)
            }
        )
        return url
    }

    private func randomBytes(length: Int, rng: inout SeededRNG) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(length)
        for _ in 0 ..< length {
            out.append(UInt8(rng.uniform(in: 0 ... 255)))
        }
        return out
    }

    /// Produces XML-ish bytes: opens/closes random tags with random attribute names and
    /// values, occasionally injecting `<vertex>` and `<triangle>` with random numbers.
    private func randomXMLLike(rng: inout SeededRNG) -> String {
        var out = "<model>"
        let depth = rng.uniform(in: 1 ... 50)
        for _ in 0 ..< depth {
            switch rng.uniform(in: 0 ... 5) {
            case 0:
                out += "<vertex x=\"\(rng.uniformFloat())\" y=\"\(rng.uniformFloat())\" z=\"\(rng.uniformFloat())\"/>"
            case 1:
                out += "<triangle v1=\"\(rng.uniform(in: 0 ... 1000))\" v2=\"\(rng.uniform(in: 0 ... 1000))\" v3=\"\(rng.uniform(in: 0 ... 1000))\"/>"
            case 2:
                out += "<mesh>"
            case 3:
                out += "</mesh>"
            case 4:
                out += "<object id=\"\(rng.uniform(in: 0 ... 100))\">"
            default:
                out += "<garbage attr=\"\(rng.uniform(in: 0 ... 9999))\"/>"
            }
        }
        out += "</model>"
        return out
    }
}

/// Tiny deterministic LCG. Good enough for fuzzing seeds; not for crypto.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed | 1
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func uniform(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func uniformFloat() -> Float {
        Float(next() % 10000) / 100 - 50
    }
}
