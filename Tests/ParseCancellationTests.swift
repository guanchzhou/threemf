import os
import simd
import XCTest
import ZIPFoundation
#if canImport(ThreeMFCore)
    @testable import ThreeMFCore
#endif

/// Covers cooperative cancellation: a cancelled token must abort a parse with
/// `CancellationError` instead of running to completion and discarding the result.
final class ParseCancellationTests: XCTestCase {
    func testToken_startsLive_andLatchesOnCancel() {
        let token = ParseCancellation()
        XCTAssertFalse(token.isCancelled)
        XCTAssertNoThrow(try token.check())

        token.cancel()
        XCTAssertTrue(token.isCancelled)
        XCTAssertThrowsError(try token.check()) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - STL

    func testSTLBinarySerial_preCancelledThrows() throws {
        let data = binarySTL(triangleCount: 4096)
        let token = ParseCancellation()
        token.cancel()

        XCTAssertThrowsError(
            try STLParser.parseBinarySerial(data: data, triangleCount: 4096, cancellation: token)
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSTLBinaryParallel_preCancelledThrows() throws {
        // Above `parallelTriangleThreshold` so this exercises the concurrentPerform path,
        // where chunks cannot throw and the token is re-checked after the barrier.
        let count = 120_000
        let data = binarySTL(triangleCount: count)
        let token = ParseCancellation()
        token.cancel()

        XCTAssertThrowsError(
            try STLParser.parseBinaryParallel(data: data, triangleCount: count, cancellation: token)
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSTLParse_uncancelledTokenStillParses() throws {
        let data = binarySTL(triangleCount: 128)
        let token = ParseCancellation()

        let mesh = try STLParser.parseMesh(data: data, limits: .cli, cancellation: token)
        XCTAssertEqual(mesh.indices.count, 128 * 3)
        XCTAssertFalse(token.isCancelled)
    }

    /// An ASCII-looking file is tried as ASCII first; cancellation there must propagate
    /// rather than falling through to a second full pass over the binary path.
    func testSTLAsciiPath_preCancelledThrows() throws {
        var ascii = "solid test\n"
        for i in 0 ..< 200 {
            ascii += """
            facet normal 0 0 1
            outer loop
            vertex \(i) 0 0
            vertex \(i) 1 0
            vertex \(i) 0 1
            endloop
            endfacet

            """
        }
        ascii += "endsolid test\n"
        let token = ParseCancellation()
        token.cancel()

        XCTAssertThrowsError(
            try STLParser.parseMesh(
                data: Data(ascii.utf8),
                limits: .cli,
                cancellation: token
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - G-code

    func testGCode_preCancelledThrows() throws {
        var gcode = ""
        for i in 0 ..< 2000 {
            gcode += "G1 X\(i % 100) Y\(i % 50) Z\(Double(i) * 0.01) E\(i)\n"
        }
        let token = ParseCancellation()
        token.cancel()

        XCTAssertThrowsError(
            try GCodeParser.parse(data: Data(gcode.utf8), cancellation: token)
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Normals

    func testComputeNormals_preCancelledThrowsOnSerialPath() {
        var mesh = MeshData(
            vertices: [simd_float3(0, 0, 0), simd_float3(1, 0, 0), simd_float3(0, 1, 0)],
            indices: [0, 1, 2],
            normals: nil
        )
        let token = ParseCancellation()
        token.cancel()

        XCTAssertThrowsError(try mesh.computeNormals(cancellation: token)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testThreeMF_nsxmlFallbackPreCancelledThrows() throws {
        // XML without <object> or <build> bypasses FastMeshScanner's object map and reaches nsxmlFallback.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model><mesh><vertices>
          <vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/>
        </vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></model>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-nsxml-\(UUID().uuidString)")
            .appendingPathExtension("3mf")
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        let data = Data(xml.utf8)
        try archive.addEntry(
            with: "3D/3dmodel.model",
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                let start = Int(position)
                return data.subdata(in: start ..< start + size)
            }
        )
        // Uncancelled succeeds via nsxmlFallback.
        let uncancelled = try ThreeMFMeshParser.parseMesh(from: url, computesNormals: false)
        XCTAssertEqual(uncancelled.vertices.count, 3)

        // Cancelled throws CancellationError instead of running XMLParser.
        let token = ParseCancellation()
        token.cancel()
        XCTAssertThrowsError(
            try ThreeMFMeshParser.parseMesh(from: url, cancellation: token, computesNormals: false)
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// Cancelling from another thread mid-parse must stop the parse, not merely discard its
    /// result. The parse is large enough that it cannot plausibly finish first.
    func testCancelDuringParse_abortsInsteadOfCompleting() {
        let count = 1_200_000
        let data = binarySTL(triangleCount: count)
        let token = ParseCancellation()

        let finished = expectation(description: "parse returned")
        let caughtCancellation = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try STLParser.parseMesh(data: data, limits: .cli, cancellation: token)
            } catch {
                caughtCancellation.withLock { $0 = error is CancellationError }
            }
            finished.fulfill()
        }

        // Give the worker a moment to enter the parse loop, then cancel.
        Thread.sleep(forTimeInterval: 0.05)
        token.cancel()

        wait(for: [finished], timeout: 10)
        XCTAssertTrue(caughtCancellation.withLock { $0 })
    }

    // MARK: - Helpers

    /// Builds a binary STL of `triangleCount` identical triangles. The repeated geometry keeps
    /// fixture construction cheap; the parser still walks every triangle, which is what these
    /// tests measure.
    private func binarySTL(triangleCount: Int) -> Data {
        var triangle: [UInt8] = []
        triangle.reserveCapacity(50)
        let floats: [Float] = [
            0, 0, 1, // normal
            0, 0, 0, // v0
            1, 0, 0, // v1
            0, 1, 0, // v2
        ]
        for value in floats {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { triangle.append(contentsOf: $0) }
        }
        triangle.append(contentsOf: [0, 0]) // attribute byte count

        var bytes = [UInt8](repeating: 0, count: 80)
        bytes.reserveCapacity(84 + triangleCount * 50)
        withUnsafeBytes(of: UInt32(triangleCount).littleEndian) { bytes.append(contentsOf: $0) }
        for _ in 0 ..< triangleCount {
            bytes.append(contentsOf: triangle)
        }
        return Data(bytes)
    }
}
