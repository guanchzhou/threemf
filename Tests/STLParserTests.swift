import SceneKit
import XCTest
import simd


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

    func testComputeNormals_flatTriangle() {
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
        for n in mesh.normals! {
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
        var huge: UInt32 = UInt32.max
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
}
