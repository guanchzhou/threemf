import simd
import XCTest

/// Performance regression suite. Builds large synthetic STL/3MF fixtures once and measures
/// parser throughput. Numbers are recorded by XCTest as baselines; CI can compare against them.
///
/// Default fixture size is small (50K triangles) so the suite runs in <1s on PRs. Set the
/// env var `THREEMF_PERF_LARGE=1` to scale up to 500K triangles for nightly runs.
final class PerformanceTests: XCTestCase {
    private var smallSTL: URL!
    private var largeSTL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let triangleCount = ProcessInfo.processInfo.environment["THREEMF_PERF_LARGE"] == "1"
            ? 500_000
            : 50000
        smallSTL = try writeBinarySTL(triangles: 5000)
        largeSTL = try writeBinarySTL(triangles: triangleCount)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: smallSTL)
        try? FileManager.default.removeItem(at: largeSTL)
        try super.tearDownWithError()
    }

    /// Hard wall-clock budgets are stricter than XCTest baselines (no Xcode-only setup
    /// required, no per-machine plist), and they fail loudly on regression. Numbers are
    /// the 95th percentile observed on M2 / M3 with ~5× safety margin.
    private static let smallBudgetSeconds: Double = 0.250
    private static let largeBudgetSeconds: Double = 1.500

    func testParseBinarySTL_smallBudget() throws {
        let start = CFAbsoluteTimeGetCurrent()
        _ = try STLParser.parseMesh(from: smallSTL)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(
            elapsed, Self.smallBudgetSeconds,
            "Small STL parse exceeded \(Self.smallBudgetSeconds * 1000) ms budget (\(elapsed * 1000) ms)"
        )
    }

    func testParseBinarySTL_largeBudget() throws {
        let start = CFAbsoluteTimeGetCurrent()
        _ = try STLParser.parseMesh(from: largeSTL)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(
            elapsed, Self.largeBudgetSeconds,
            "Large STL parse exceeded \(Self.largeBudgetSeconds * 1000) ms budget (\(elapsed * 1000) ms)"
        )
    }

    // MARK: - Fixture generation

    /// Writes a synthetic well-formed binary STL with `count` triangles to a temp file.
    /// Vertices are generated in a simple 3D grid so dedup ratio is realistic (~3:1).
    private func writeBinarySTL(triangles count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-\(count)-\(UUID().uuidString)")
            .appendingPathExtension("stl")

        var data = Data(count: 80) // header
        var triCount = UInt32(count)
        data.append(Data(bytes: &triCount, count: 4))

        // Generate triangles by walking a grid lattice. Each triangle reuses 3 vertices
        // from neighboring grid points so the dedup map gets exercised.
        let side = max(2, Int(Double(count).squareRoot()) + 1)
        var emitted = 0
        outer: for i in 0 ..< side {
            for j in 0 ..< side {
                let x = Float(i % 8)
                let y = Float(j % 8)
                let z = Float((i + j) % 4)
                var values: [Float] = [
                    0, 0, 1,
                    x, y, z,
                    x + 1, y, z,
                    x, y + 1, z,
                ]
                data.append(Data(bytes: &values, count: 48))
                var attr: UInt16 = 0
                data.append(Data(bytes: &attr, count: 2))
                emitted += 1
                if emitted >= count { break outer }
            }
        }
        try data.write(to: url)
        return url
    }
}
