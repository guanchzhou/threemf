import SceneKit
import simd
import XCTest

class STLParserTests: XCTestCase {
    // MARK: - Binary STL

    func testParseBinarySTL_singleTriangle() throws {
        let data = makeBinarySTL(triangles: [
            Triangle(
                normal: (0, 0, 1),
                v1: (0, 0, 0),
                v2: (1, 0, 0),
                v3: (0, 1, 0)
            ),
        ])
        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)

        XCTAssertEqual(mesh.vertices.count, 3)
        XCTAssertEqual(mesh.indices.count, 3)
        XCTAssertNotNil(mesh.normals)
        XCTAssertEqual(mesh.normals?.count, 3)
    }

    func testParseBinarySTL_twoTriangles_sharedVertices() throws {
        // Two triangles sharing an edge (2 shared vertices)
        let data = makeBinarySTL(triangles: [
            Triangle(normal: (0, 0, 1), v1: (0, 0, 0), v2: (1, 0, 0), v3: (0, 1, 0)),
            Triangle(normal: (0, 0, 1), v1: (1, 0, 0), v2: (1, 1, 0), v3: (0, 1, 0)),
        ])
        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)

        // Should deduplicate: 4 unique vertices, not 6
        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.indices.count, 6)
    }

    func testParseBinarySTL_emptyFile_throws() throws {
        let data = Data(count: 84) // header + 0 triangles
        var mutable = data
        mutable.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(0), toByteOffset: 80, as: UInt32.self)
        }
        let url = try writeTempFile(data: mutable, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try STLParser.parseMesh(from: url))
    }

    // MARK: - ASCII STL

    func testParseASCIISTL_singleTriangle() throws {
        let ascii = """
        solid test
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 1 0 0
              vertex 0 1 0
            endloop
          endfacet
        endsolid test
        """
        let url = try writeTempFile(string: ascii, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)

        XCTAssertEqual(mesh.vertices.count, 3)
        XCTAssertEqual(mesh.indices.count, 3)
    }

    func testParseASCIISTL_noVertices_throws() throws {
        let ascii = "solid empty\nendsolid empty\n"
        let url = try writeTempFile(string: ascii, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try STLParser.parseMesh(from: url))
    }

    func testParseBinarySTL_mismatchedTriangleCount_fallsBackToASCII() throws {
        // Header claims 100 triangles but file is only 84 + 50 bytes (1 triangle)
        var data = Data(count: 80) // header
        var claimedCount: UInt32 = 100
        data.append(Data(bytes: &claimedCount, count: 4))
        // Add 1 real triangle (50 bytes) — size won't match 84 + 100*50
        var values: [Float] = [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0]
        data.append(Data(bytes: &values, count: 48))
        var attr: UInt16 = 0
        data.append(Data(bytes: &attr, count: 2))

        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        // Size mismatch triggers ASCII fallback, which finds no vertices
        XCTAssertThrowsError(try STLParser.parseMesh(from: url))
    }

    func testParseSTL_fileSmallerThanHeader() throws {
        let data = Data(count: 40) // less than 84-byte header
        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        // Should fall through to ASCII parsing, then throw noTriangles
        XCTAssertThrowsError(try STLParser.parseMesh(from: url))
    }

    // MARK: - MeshData normals

    func testComputeNormals_flatTriangle() throws {
        var mesh = MeshData(
            vertices: [
                simd_float3(0, 0, 0),
                simd_float3(1, 0, 0),
                simd_float3(0, 1, 0),
            ],
            indices: [0, 1, 2],
            normals: nil
        )
        mesh.computeNormals()

        XCTAssertNotNil(mesh.normals)
        // Normal should point in +Z direction for this CCW triangle in XY plane
        for n in try XCTUnwrap(mesh.normals) {
            XCTAssertEqual(n.z, 1.0, accuracy: 0.01)
        }
    }

    // MARK: - Phase A: trailing bytes / clamped triangle count

    /// Slicers sometimes append metadata after the binary STL payload. The parser
    /// now accepts `data.count >= expectedSize` instead of strict equality.
    func testParseBinarySTL_acceptsTrailingBytes() throws {
        var data = makeBinarySTL(triangles: [
            Triangle(normal: (0, 0, 1), v1: (0, 0, 0), v2: (1, 0, 0), v3: (0, 1, 0)),
            Triangle(normal: (0, 0, 1), v1: (1, 0, 0), v2: (1, 1, 0), v3: (0, 1, 0)),
        ])
        // Append 100 bytes of garbage past the declared payload.
        data.append(Data(count: 100))

        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)
        // 2 triangles → 6 indices, 4 unique vertices after dedup.
        XCTAssertEqual(mesh.indices.count, 6)
        XCTAssertEqual(mesh.vertices.count, 4)
    }

    /// Header declares UInt32.max triangles but file is only the 84-byte header.
    /// Must NOT OOM via reserveCapacity. Falls back to ASCII (header bytes are not
    /// valid ASCII STL) and throws .noTriangles.
    func testParseBinarySTL_hugeHeaderTriangleCountIsClamped() throws {
        var data = Data(count: 80) // header
        var huge = UInt32.max
        data.append(Data(bytes: &huge, count: 4))
        // Total file is 84 bytes, smaller than 84 + huge*50, so it falls back to ASCII.

        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let expectation = XCTestExpectation(description: "parse returns within timeout")
        var thrown: Error?
        DispatchQueue.global().async {
            do {
                _ = try STLParser.parseMesh(from: url)
            } catch {
                thrown = error
            }
            expectation.fulfill()
        }
        // Test timeout safety net: if reserveCapacity were honored unclamped this
        // would either OOM or take far longer than 5s.
        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(thrown, "Expected an error from invalid STL")
    }

    // MARK: - Helpers

    struct Triangle {
        let normal: (Float, Float, Float)
        let v1: (Float, Float, Float)
        let v2: (Float, Float, Float)
        let v3: (Float, Float, Float)
    }

    func makeBinarySTL(triangles: [Triangle]) -> Data {
        var data = Data(count: 80) // header
        var count = UInt32(triangles.count)
        data.append(Data(bytes: &count, count: 4))

        for tri in triangles {
            var values: [Float] = [
                tri.normal.0, tri.normal.1, tri.normal.2,
                tri.v1.0, tri.v1.1, tri.v1.2,
                tri.v2.0, tri.v2.1, tri.v2.2,
                tri.v3.0, tri.v3.1, tri.v3.2,
            ]
            data.append(Data(bytes: &values, count: 48))
            var attr: UInt16 = 0
            data.append(Data(bytes: &attr, count: 2))
        }
        return data
    }

    func writeTempFile(data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }

    func writeTempFile(string: String, ext: String) throws -> URL {
        try writeTempFile(data: string.data(using: .utf8)!, ext: ext)
    }

    // MARK: - ASCII STL byte-parser edge cases

    func testParseASCIISTL_scientificNotation() throws {
        // Slicers occasionally emit floats in scientific form. The byte parser must accept them.
        let ascii = """
        solid sci
          facet normal 0 0 1
            outer loop
              vertex 1.5e-3 0 0
              vertex 2 0 0
              vertex 0 2.0E+1 0
            endloop
          endfacet
        endsolid sci
        """
        let url = try writeTempFile(string: ascii, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)
        XCTAssertEqual(mesh.vertices.count, 3)
        XCTAssertEqual(mesh.indices.count, 3)
        XCTAssertEqual(mesh.vertices[0].x, 0.0015, accuracy: 1e-7)
        XCTAssertEqual(mesh.vertices[2].y, 20.0, accuracy: 1e-5)
    }

    // MARK: - Parallel binary STL parser (P2)

    func testParseBinarySTL_aboveThreshold_usesParallelPath_andMatches() throws {
        // STLParser switches to multi-core parsing at >=100k triangles. This test
        // generates a fixture above the threshold and verifies the parallel path produces
        // a consistent vertex/index count. Catches accidental races in the chunk merge.
        let triangleCount = 120_000
        let data = makeBinarySTL(triangles: gridTriangles(count: triangleCount))
        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)
        // Triangle count is preserved — every input triangle yields 3 indices.
        XCTAssertEqual(mesh.indices.count, triangleCount * 3)
        // Vertex dedup must produce a number > 0 and ≤ 3 × triangle count.
        XCTAssertGreaterThan(mesh.vertices.count, 0)
        XCTAssertLessThanOrEqual(mesh.vertices.count, triangleCount * 3)
        // All indices must reference a valid vertex.
        let vCount = UInt32(mesh.vertices.count)
        XCTAssertTrue(mesh.indices.allSatisfy { $0 < vCount })
        // Normals computed.
        XCTAssertEqual(mesh.normals?.count, mesh.vertices.count)
    }

    /// Same input run through both binary parsers; output must agree on vertex count,
    /// triangle count, and triangle set (as quantized coordinate triples). This is the
    /// regression net for the parallel-merge logic.
    func testParseBinarySTL_serialAndParallel_agree() throws {
        let triangleCount = 5000
        let triangles = gridTriangles(count: triangleCount)
        let data = makeBinarySTL(triangles: triangles)

        let serial = try STLParser.parseBinarySerial(data: data, triangleCount: triangleCount)
        let parallel = try STLParser.parseBinaryParallel(data: data, triangleCount: triangleCount)

        XCTAssertEqual(serial.vertices.count, parallel.vertices.count)
        XCTAssertEqual(serial.indices.count, parallel.indices.count)
        XCTAssertEqual(serial.indices.count / 3, triangleCount)

        // Compare triangle sets — vertex ordering may legitimately differ between paths
        // because chunks discover unique vertices in different orders, but the unordered
        // set of (vertex-coord-triple, vertex-coord-triple, vertex-coord-triple) per
        // triangle must be identical.
        XCTAssertEqual(triangleSet(serial), triangleSet(parallel))
    }

    /// Quantized triangle coordinates as a hashable set.
    private func triangleSet(_ mesh: MeshData) -> Set<[Int32]> {
        var out = Set<[Int32]>()
        let count = mesh.indices.count / 3
        for t in 0 ..< count {
            let a = mesh.vertices[Int(mesh.indices[t * 3])]
            let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
            // Sort the three vertex tuples so the same triangle hashes the same regardless
            // of winding order quirks (we don't expect any here, but defensive).
            let q = [
                quantize(a),
                quantize(b),
                quantize(c),
            ].sorted { lhs, rhs in
                if lhs[0] != rhs[0] {
                    return lhs[0] < rhs[0]
                }
                if lhs[1] != rhs[1] {
                    return lhs[1] < rhs[1]
                }
                return lhs[2] < rhs[2]
            }
            out.insert(q.flatMap(\.self))
        }
        return out
    }

    private func quantize(_ v: simd_float3) -> [Int32] {
        [
            Int32((v.x * 10000).rounded()),
            Int32((v.y * 10000).rounded()),
            Int32((v.z * 10000).rounded()),
        ]
    }

    /// Builds `count` triangles on a small grid lattice so vertex dedup is exercised.
    private func gridTriangles(count: Int) -> [Triangle] {
        var out: [Triangle] = []
        out.reserveCapacity(count)
        let side = max(2, Int(Double(count).squareRoot()) + 1)
        outer: for i in 0 ..< side {
            for j in 0 ..< side {
                let x = Float(i % 8)
                let y = Float(j % 8)
                let z = Float((i + j) % 4)
                out.append(Triangle(
                    normal: (0, 0, 1),
                    v1: (x, y, z),
                    v2: (x + 1, y, z),
                    v3: (x, y + 1, z)
                ))
                if out.count >= count {
                    break outer
                }
            }
        }
        return out
    }

    func testParseSTL_solidPrefixedASCII_parsesAsASCII() throws {
        // Standard ASCII STL — must parse via the ASCII path because the prefix is "solid".
        let ascii = """
        solid example
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 1 0 0
              vertex 0 1 0
            endloop
          endfacet
        endsolid example
        """
        let url = try writeTempFile(string: ascii, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }
        let mesh = try STLParser.parseMesh(from: url)
        XCTAssertEqual(mesh.indices.count, 3)
    }

    func testParseSTL_solidPrefixedBinary_fallsBackToBinary() throws {
        // Construct a binary STL whose 80-byte header happens to begin with "solid"
        // (some buggy slicers do this). The ASCII path will fail (no `vertex` tokens)
        // and we should fall through to binary parsing.
        var data = Data()
        try data.append(XCTUnwrap("solid junk header — actual binary STL follows".data(using: .utf8)))
        // Pad header to exactly 80 bytes.
        if data.count < 80 {
            data.append(Data(count: 80 - data.count))
        } else {
            data = data.prefix(80)
        }
        // 1 triangle.
        var count: UInt32 = 1
        data.append(Data(bytes: &count, count: 4))
        var values: [Float] = [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0]
        data.append(Data(bytes: &values, count: 48))
        var attr: UInt16 = 0
        data.append(Data(bytes: &attr, count: 2))

        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }
        let mesh = try STLParser.parseMesh(from: url)
        XCTAssertEqual(mesh.indices.count, 3) // 1 triangle, 3 indices
    }

    // MARK: - Crafted-coordinate crash guards (regression: Int32(Float) trap)

    func testParseBinarySTL_nonFiniteCoords_doesNotTrap() throws {
        // A binary triangle carrying NaN and ±Inf coordinates. Before the quantize guard,
        // VertexKey's `Int32(Float)` cast fatal-errored on NaN/Inf — crashing the extension.
        let data = makeBinarySTL(triangles: [
            Triangle(
                normal: (0, 0, 1),
                v1: (.nan, 0, 0),
                v2: (.infinity, 1, 0),
                v3: (-.infinity, 0, 1)
            ),
        ])
        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        // Contract is "no trap": it parses (degenerate coords collapse) or throws — never crashes.
        let mesh = try STLParser.parseMesh(from: url)
        XCTAssertGreaterThan(mesh.vertices.count, 0)
    }

    func testParseBinarySTL_hugeFiniteCoords_doesNotTrap() throws {
        // Finite but far outside Int32 range after *10000 scaling (1e30 → 1e34).
        // `Int32(1e34)` also traps; the clamp path must handle this.
        let data = makeBinarySTL(triangles: [
            Triangle(normal: (0, 0, 1), v1: (1e30, -1e30, 0), v2: (1, 0, 0), v3: (0, 1, 0)),
        ])
        let url = try writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)
        XCTAssertEqual(mesh.indices.count, 3)
    }

    func testParseASCIISTL_overflowExponent_doesNotTrap() throws {
        // `1e999` overflows Float to +Inf in parseFloatBytes; the vertex key must not trap.
        let ascii = """
        solid overflow
          facet normal 0 0 1
            outer loop
              vertex 1e999 0 0
              vertex 1 0 0
              vertex 0 1 0
            endloop
          endfacet
        endsolid overflow
        """
        let url = try writeTempFile(string: ascii, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)
        XCTAssertEqual(mesh.indices.count, 3)
    }

    func testParseASCIISTL_tabSeparatedAndCRLF() throws {
        // Mix of tabs, multiple spaces, and CRLF — common when files come from Windows tools.
        let ascii =
            "solid x\r\n" +
            "  facet normal 0 0 1\r\n" +
            "    outer loop\r\n" +
            "      vertex\t0\t0\t0\r\n" +
            "      vertex   1   0   0\r\n" +
            "      vertex 0 1 0\r\n" +
            "    endloop\r\n" +
            "  endfacet\r\n" +
            "endsolid x\r\n"
        let url = try writeTempFile(string: ascii, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)
        XCTAssertEqual(mesh.vertices.count, 3)
        XCTAssertEqual(mesh.indices.count, 3)
    }
}
