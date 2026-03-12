import SceneKit
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
        let url = writeTempFile(data: data, ext: "stl")
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
        let url = writeTempFile(data: data, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)

        // Should deduplicate: 4 unique vertices, not 6
        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.indices.count, 6)
    }

    func testParseBinarySTL_emptyFile_throws() {
        let data = Data(count: 84) // header + 0 triangles
        var mutable = data
        mutable.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(0), toByteOffset: 80, as: UInt32.self)
        }
        let url = writeTempFile(data: mutable, ext: "stl")
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
        let url = writeTempFile(string: ascii, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try STLParser.parseMesh(from: url)

        XCTAssertEqual(mesh.vertices.count, 3)
        XCTAssertEqual(mesh.indices.count, 3)
    }

    func testParseASCIISTL_noVertices_throws() {
        let ascii = "solid empty\nendsolid empty\n"
        let url = writeTempFile(string: ascii, ext: "stl")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try STLParser.parseMesh(from: url))
    }

    // MARK: - MeshData normals

    func testComputeNormals_flatTriangle() {
        var mesh = MeshData(
            vertices: [
                SCNVector3(0, 0, 0),
                SCNVector3(1, 0, 0),
                SCNVector3(0, 1, 0),
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

    func writeTempFile(data: Data, ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try! data.write(to: url)
        return url
    }

    func writeTempFile(string: String, ext: String) -> URL {
        writeTempFile(data: string.data(using: .utf8)!, ext: ext)
    }
}
