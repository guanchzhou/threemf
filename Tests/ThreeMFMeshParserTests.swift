import SceneKit
import XCTest
import ZIPFoundation


class ThreeMFMeshParserTests: XCTestCase {

    // MARK: - 3MF Parsing

    func testParse3MF_simpleInlineMesh() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1" type="model">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0" />
                  <vertex x="10" y="0" z="0" />
                  <vertex x="0" y="10" z="0" />
                  <vertex x="0" y="0" z="10" />
                </vertices>
                <triangles>
                  <triangle v1="0" v2="1" v3="2" />
                  <triangle v1="0" v2="1" v3="3" />
                  <triangle v1="0" v2="2" v3="3" />
                  <triangle v1="1" v2="2" v3="3" />
                </triangles>
              </mesh>
            </object>
          </resources>
          <build>
            <item objectid="1" />
          </build>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)

        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.indices.count, 12) // 4 triangles * 3
        XCTAssertNotNil(mesh.normals)
    }

    func testParse3MF_buildItemTransform() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1" type="model">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0" />
                  <vertex x="1" y="0" z="0" />
                  <vertex x="0" y="1" z="0" />
                </vertices>
                <triangles>
                  <triangle v1="0" v2="1" v3="2" />
                </triangles>
              </mesh>
            </object>
          </resources>
          <build>
            <item objectid="1" transform="1 0 0 0 1 0 0 0 1 100 200 0" />
          </build>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)

        // Vertex at (0,0,0) should be translated to (100,200,0)
        let v0 = mesh.vertices[0]
        XCTAssertEqual(v0.x, 100.0, accuracy: 0.01)
        XCTAssertEqual(v0.y, 200.0, accuracy: 0.01)
    }

    func testParse3MF_noModel_throws() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("3mf")
        // Create a ZIP with no 3D/3dmodel.model
        guard let archive = Archive(url: url, accessMode: .create) else {
            XCTFail("Cannot create archive")
            return
        }
        let dummyData = "hello".data(using: .utf8)!
        try? archive.addEntry(with: "dummy.txt", type: .file, uncompressedSize: UInt32(dummyData.count), provider: { position, size in
            dummyData.subdata(in: position..<position + size)
        })
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFMeshParser.parseMesh(from: url))
    }

    func testParse3MF_emptyMesh_throws() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1" type="model">
              <mesh>
                <vertices />
                <triangles />
              </mesh>
            </object>
          </resources>
          <build />
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFMeshParser.parseMesh(from: url))
    }

    func testParse3MF_invalidFile_throws() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("3mf")
        try! "not a zip".data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFMeshParser.parseMesh(from: url))
    }

    // MARK: - Thumbnail Extraction

    func testExtractThumbnail_withPNG() throws {
        // Create a 3MF with a fake PNG thumbnail
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        let url = try make3MFFile(modelXML: "<model/>", thumbnailData: pngHeader)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try ThreeMFExtractor.extractThumbnail(from: url)
        XCTAssertEqual(data.prefix(4), pngHeader)
    }

    func testExtractThumbnail_noThumbnail_throws() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources />
          <build />
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFExtractor.extractThumbnail(from: url))
    }

    // MARK: - SceneBuilder

    func testBuildScene_producesValidScene() {
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

        let scene = SceneBuilder.buildScene(from: mesh)

        XCTAssertNotNil(scene)
        // Should have root children: model, camera, 3 lights
        XCTAssertGreaterThanOrEqual(scene.rootNode.childNodes.count, 4)
        // Should have a camera
        let cameras = scene.rootNode.childNodes.filter { $0.camera != nil }
        XCTAssertEqual(cameras.count, 1)
    }

    // MARK: - Integration with real files

    func testParseReal3MFFile() throws {
        let path = "/Users/andreymaltsev/Downloads/fruitflytrap-6CUTNL.3mf"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Test file not available")
        }
        let url = URL(fileURLWithPath: path)
        let mesh = try ThreeMFMeshParser.parseMesh(from: url)

        XCTAssertGreaterThan(mesh.vertices.count, 100)
        XCTAssertGreaterThan(mesh.indices.count, 100)
        XCTAssertNotNil(mesh.normals)
    }

    func testParseRealSTLFile() throws {
        let path = "/Users/andreymaltsev/Downloads/H2D exhaust.stl"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Test file not available")
        }
        let url = URL(fileURLWithPath: path)
        let mesh = try STLParser.parseMesh(from: url)

        XCTAssertGreaterThan(mesh.vertices.count, 100)
        XCTAssertGreaterThan(mesh.indices.count, 100)
    }

    // MARK: - Helpers

    func make3MFFile(modelXML: String, thumbnailData: Data? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("3mf")
        guard let archive = Archive(url: url, accessMode: .create) else {
            throw NSError(domain: "test", code: 1)
        }

        let modelData = modelXML.data(using: .utf8)!
        try archive.addEntry(
            with: "3D/3dmodel.model",
            type: .file,
            uncompressedSize: UInt32(modelData.count),
            provider: { position, size in
                modelData.subdata(in: position..<position + size)
            }
        )

        if let png = thumbnailData {
            try archive.addEntry(
                with: "Metadata/plate_1.png",
                type: .file,
                uncompressedSize: UInt32(png.count),
                provider: { position, size in
                    png.subdata(in: position..<position + size)
                }
            )
        }

        return url
    }
}
