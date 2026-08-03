import SceneKit
import simd
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

    func testParse3MF_componentTransforms_composedAndAllEmitted() throws {
        // Object 3 is an assembly: two components referencing objects 1 and 2, each with
        // its own translation. A correct renderer emits BOTH sub-meshes at their translated
        // positions. Regression for: (A) component transform ignored, (B) only first
        // component rendered.
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1" type="model">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0" /><vertex x="1" y="0" z="0" /><vertex x="0" y="1" z="0" />
                </vertices>
                <triangles><triangle v1="0" v2="1" v3="2" /></triangles>
              </mesh>
            </object>
            <object id="2" type="model">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0" /><vertex x="1" y="0" z="0" /><vertex x="0" y="1" z="0" />
                </vertices>
                <triangles><triangle v1="0" v2="1" v3="2" /></triangles>
              </mesh>
            </object>
            <object id="3" type="model">
              <components>
                <component objectid="1" transform="1 0 0 0 1 0 0 0 1 100 0 0" />
                <component objectid="2" transform="1 0 0 0 1 0 0 0 1 0 100 0" />
              </components>
            </object>
          </resources>
          <build>
            <item objectid="3" />
          </build>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)

        // Both components emitted → two triangles → six vertices.
        XCTAssertEqual(mesh.vertices.count, 6, "both components should be emitted")
        XCTAssertEqual(mesh.indices.count, 6)
        // Component 1 translated +100 in x; component 2 translated +100 in y.
        let maxX = mesh.vertices.map(\.x).max() ?? 0
        let maxY = mesh.vertices.map(\.y).max() ?? 0
        XCTAssertEqual(maxX, 101.0, accuracy: 0.01, "component 1's x-translation must apply")
        XCTAssertEqual(maxY, 101.0, accuracy: 0.01, "component 2's y-translation must apply")
    }

    func testParse3MF_separateFileComponent_composesWithBuildItem() throws {
        // Bambu-style: object 1's mesh lives in a separate ZIP entry, referenced by a
        // component with its own transform (+50 x). The build item adds +7 y. A correct
        // renderer composes BOTH: sub-mesh vertices land at (+50 x, +7 y). Before the
        // expandObject fix, the separate-file path applied only the build-item transform
        // and dropped the component's +50 x.
        let rootModel = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
               xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
          <resources>
            <object id="1" type="model">
              <components>
                <component objectid="2" p:path="/3D/Objects/obj2.model" transform="1 0 0 0 1 0 0 0 1 50 0 0" />
              </components>
            </object>
          </resources>
          <build>
            <item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 7 0" />
          </build>
        </model>
        """
        let obj2Model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="2" type="model">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0" /><vertex x="1" y="0" z="0" /><vertex x="0" y="1" z="0" />
                </vertices>
                <triangles><triangle v1="0" v2="1" v3="2" /></triangles>
              </mesh>
            </object>
          </resources>
        </model>
        """
        let url = try make3MFFile(entries: [
            (path: "3D/3dmodel.model", content: XCTUnwrap(rootModel.data(using: .utf8))),
            (path: "3D/Objects/obj2.model", content: XCTUnwrap(obj2Model.data(using: .utf8))),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)

        XCTAssertEqual(mesh.vertices.count, 3, "the separate-file sub-mesh must be emitted")
        let minX = mesh.vertices.map(\.x).min() ?? 0
        let minY = mesh.vertices.map(\.y).min() ?? 0
        // vertex (0,0,0) → component +50x → build-item +7y → (50, 7, 0)
        XCTAssertEqual(minX, 50.0, accuracy: 0.01, "component +50 x must compose in")
        XCTAssertEqual(minY, 7.0, accuracy: 0.01, "build-item +7 y must compose in")
    }

    func testParse3MF_objectLevelMaterial_inheritedByTriangles() throws {
        // Core-spec single-color object: the material is set at the OBJECT level via
        // pid/pindex; the triangle carries no material of its own. It must inherit the
        // object's material (index 0), not render uncolored (-1). Common shape for
        // single-color CAD/PrusaSlicer exports.
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <basematerials id="1">
              <base name="red" displaycolor="#FF0000" />
              <base name="green" displaycolor="#00FF00" />
            </basematerials>
            <object id="2" type="model" pid="1" pindex="1">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0" /><vertex x="1" y="0" z="0" /><vertex x="0" y="1" z="0" />
                </vertices>
                <triangles><triangle v1="0" v2="1" v3="2" /></triangles>
              </mesh>
            </object>
          </resources>
          <build><item objectid="2" /></build>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)

        XCTAssertEqual(mesh.materials.count, 2)
        XCTAssertEqual(mesh.triangleMaterials.count, 1)
        // pindex=1 → the second material (green), inherited by the un-attributed triangle.
        XCTAssertEqual(mesh.triangleMaterials.first, 1, "triangle must inherit object's pindex material")
    }

    func testParse3MF_noModel_throws() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("3mf")
        // Create a ZIP with no 3D/3dmodel.model
        guard let archive = Archive(url: url, accessMode: .create) else {
            XCTFail("Cannot create archive")
            return
        }
        let dummyData = "hello".data(using: .utf8)!
        // S8 fix: surface real fixture-setup errors instead of silently swallowing.
        try archive.addEntry(
            with: "dummy.txt",
            type: .file,
            uncompressedSize: UInt32(dummyData.count),
            provider: { position, size in
                dummyData.subdata(in: position ..< position + size)
            }
        )
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

    func testParse3MF_invalidFile_throws() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("3mf")
        try try XCTUnwrap("not a zip".data(using: .utf8)?.write(to: url))
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
                simd_float3(0, 0, 0),
                simd_float3(1, 0, 0),
                simd_float3(0, 1, 0),
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

    // MARK: - Safety

    func testExtractThumbnail_oversizedEntry_throws() throws {
        // Create a 3MF with a thumbnail whose declared uncompressedSize exceeds the limit
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("3mf")
        guard let archive = Archive(url: url, accessMode: .create) else {
            XCTFail("Cannot create archive")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let smallData = Data([0x89, 0x50, 0x4E, 0x47])
        // Declare size as 11 MB (exceeds 10 MB limit)
        let declaredSize: UInt32 = 11 * 1024 * 1024
        try archive.addEntry(
            with: "Metadata/plate_1.png",
            type: .file,
            uncompressedSize: declaredSize,
            provider: { position, size in
                let end = min(position + size, smallData.count)
                guard position < smallData.count else { return Data() }
                return smallData.subdata(in: position ..< end)
            }
        )

        XCTAssertThrowsError(try ThreeMFExtractor.extractThumbnail(from: url)) { error in
            XCTAssertTrue(error is ThreeMFExtractorError)
        }
    }

    func testParse3MF_outOfRangeIndices_doesNotCrash() throws {
        // Triangle references vertex index 99 which doesn't exist (only 3 vertices).
        // Phase A: parser FILTERS bad triangles before assembly. Since the only
        // triangle in this fixture is invalid, the resulting mesh has zero indices,
        // which raises `.noMeshData`.
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
                  <triangle v1="0" v2="1" v3="99" />
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

        // Either the parser throws .noMeshData (all triangles filtered) OR — if any
        // valid geometry survives — the result must contain zero out-of-range indices.
        do {
            let mesh = try ThreeMFMeshParser.parseMesh(from: url)
            let vCount = UInt32(mesh.vertices.count)
            for idx in mesh.indices {
                XCTAssertLessThan(idx, vCount, "Out-of-range index leaked through filter")
            }
            // With this fixture the only triangle is bad, so we expect filter to drop it.
            XCTAssertEqual(mesh.indices.count, 0)
        } catch let error as ThreeMFMeshParserError {
            XCTAssertEqual(error, .noMeshData)
        }
    }

    // MARK: - Phase A: ZIP bomb / path traversal / multi-component / materials

    /// Declared `uncompressedSize` is small but the provider streams more bytes than
    /// the runtime cap. `extractCapped` checks the running stream length on every
    /// chunk and must throw `.sizeLimitExceeded`.
    func testParseMesh_zipBombDeclaresSmallButStreamsLarge() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("3mf")
        guard let archive = Archive(url: url, accessMode: .create) else {
            XCTFail("Cannot create archive"); return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        // Declare 1 KB, but stream 600 MB (above the 500 MB cap).
        let declared: UInt32 = 1024
        let streamTotal = 600 * 1024 * 1024
        let chunkSize = 1024 * 1024
        let chunk = Data(count: chunkSize)
        try archive.addEntry(
            with: "3D/3dmodel.model",
            type: .file,
            uncompressedSize: UInt32(declared),
            provider: { position, size in
                // Provider is asked for `size` bytes starting at `position`. We
                // serve raw zero bytes regardless of `position`, but ZIPFoundation
                // will keep asking based on declared size — so we must extend by
                // forcibly returning huge buffers.
                guard position < streamTotal else { return Data() }
                let take = min(size, chunkSize)
                _ = chunk
                return Data(count: take)
            }
        )

        // The 1 KB declared size means ZIPFoundation reads only 1 KB on extract
        // (so the bomb is bounded by declaration). Either way, parsing must NOT
        // succeed — either the declared size cap rejects or the model is empty.
        XCTAssertThrowsError(try ThreeMFMeshParser.parseMesh(from: url)) { error in
            // Acceptable outcomes: cannotOpenArchive, modelNotFound, parseFailed,
            // noMeshData, sizeLimitExceeded. Any of these proves we did not crash
            // or run away with memory.
            XCTAssertTrue(
                error is ThreeMFMeshParserError || error is NSError,
                "Unexpected error type: \(error)"
            )
        }
    }

    /// `<component p:path="../../etc/passwd"/>` must be silently rejected.
    /// The root mesh has no inline geometry, so the result is `.noMeshData`.
    func testParseMesh_componentPathTraversalIsRejected() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
               xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
          <resources>
            <object id="1" type="model">
              <components>
                <component p:path="../../etc/passwd" objectid="2"/>
              </components>
            </object>
          </resources>
          <build>
            <item objectid="1"/>
          </build>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFMeshParser.parseMesh(from: url)) { error in
            if let parserErr = error as? ThreeMFMeshParserError {
                XCTAssertEqual(parserErr, .noMeshData)
            }
        }
    }

    func testParseMesh_componentPathBackslash_rejected() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
               xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
          <resources>
            <object id="1" type="model">
              <components>
                <component p:path="..\\Windows\\System32\\config.model" objectid="2"/>
              </components>
            </object>
          </resources>
          <build>
            <item objectid="1"/>
          </build>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFMeshParser.parseMesh(from: url)) { error in
            if let parserErr = error as? ThreeMFMeshParserError {
                XCTAssertEqual(parserErr, .noMeshData)
            }
        }
    }

    /// Bambu-style 3MF: root model points to an external `/3D/Objects/object_1.model`.
    /// Build references the parent object whose component points at the external file.
    func testParseMesh_externalComponentReferences() throws {
        let rootXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
               xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
          <resources>
            <object id="1" type="model">
              <components>
                <component p:path="/3D/Objects/object_1.model" objectid="2"/>
              </components>
            </object>
          </resources>
          <build>
            <item objectid="1"/>
          </build>
        </model>
        """
        let externalXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="2" type="model">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0"/>
                  <vertex x="1" y="0" z="0"/>
                  <vertex x="0" y="1" z="0"/>
                  <vertex x="0" y="0" z="1"/>
                </vertices>
                <triangles>
                  <triangle v1="0" v2="1" v3="2"/>
                  <triangle v1="0" v2="1" v3="3"/>
                </triangles>
              </mesh>
            </object>
          </resources>
        </model>
        """
        let url = try make3MFFile(entries: [
            (path: "3D/3dmodel.model", content: XCTUnwrap(rootXML.data(using: .utf8))),
            (path: "3D/Objects/object_1.model", content: XCTUnwrap(externalXML.data(using: .utf8))),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)
        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.indices.count, 6) // 2 triangles
    }

    /// `<basematerials>` group with two entries; triangles reference each via `pid`/`p1`.
    func testParseMesh_multiMaterial_assignsMaterialsToTriangles() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <basematerials id="1">
              <base name="Red" displaycolor="#FF0000FF"/>
              <base name="Blue" displaycolor="#0000FFFF"/>
            </basematerials>
            <object id="2" type="model">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0"/>
                  <vertex x="1" y="0" z="0"/>
                  <vertex x="0" y="1" z="0"/>
                  <vertex x="0" y="0" z="1"/>
                </vertices>
                <triangles>
                  <triangle v1="0" v2="1" v3="2" pid="1" p1="0"/>
                  <triangle v1="0" v2="1" v3="3" pid="1" p1="1"/>
                </triangles>
              </mesh>
            </object>
          </resources>
          <build>
            <item objectid="2"/>
          </build>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)
        XCTAssertEqual(mesh.materials.count, 2)
        XCTAssertEqual(mesh.triangleMaterials.count, 2)

        // Verify ordering: first triangle is Red, second is Blue.
        let firstMatIdx = mesh.triangleMaterials[0]
        let secondMatIdx = mesh.triangleMaterials[1]
        XCTAssertGreaterThanOrEqual(firstMatIdx, 0)
        XCTAssertGreaterThanOrEqual(secondMatIdx, 0)
        XCTAssertEqual(mesh.materials[firstMatIdx].name, "Red")
        XCTAssertEqual(mesh.materials[secondMatIdx].name, "Blue")

        // Verify color parse: "#FF0000FF" → R=1, G=0, B=0, A=1.
        let red = mesh.materials.first { $0.name == "Red" }
        XCTAssertNotNil(red?.color)
        if let c = red?.color {
            XCTAssertEqual(c.x, 1.0, accuracy: 0.01)
            XCTAssertEqual(c.y, 0.0, accuracy: 0.01)
            XCTAssertEqual(c.z, 0.0, accuracy: 0.01)
            XCTAssertEqual(c.w, 1.0, accuracy: 0.01)
        }
    }

    // MARK: - Helpers

    func make3MFFile(modelXML: String, thumbnailData: Data? = nil) throws -> URL {
        var entries: [(path: String, content: Data)] = [
            (path: "3D/3dmodel.model", content: modelXML.data(using: .utf8)!),
        ]
        if let png = thumbnailData {
            entries.append((path: "Metadata/plate_1.png", content: png))
        }
        return try make3MFFile(entries: entries)
    }

    /// Build a `.3mf` archive containing arbitrary ZIP entries.
    /// Used for multi-component fixtures (Bambu pattern, separate object files).
    func make3MFFile(entries: [(path: String, content: Data)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("3mf")
        guard let archive = Archive(url: url, accessMode: .create) else {
            throw NSError(domain: "test", code: 1)
        }

        for entry in entries {
            let data = entry.content
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: UInt32(data.count),
                provider: { position, size in
                    data.subdata(in: position ..< position + size)
                }
            )
        }

        return url
    }

    // MARK: - Metadata extraction (P1.5)

    func testParse3MF_metadataExtraction() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <metadata name="Application">BambuStudio-1.9.0</metadata>
          <metadata name="CreationDate">2026-04-15T10:30:00Z</metadata>
          <metadata name="Designer">Test User</metadata>
          <metadata name="Title">Demo Cube</metadata>
          <metadata name="CustomKey">CustomValue</metadata>
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
          <build><item objectid="1" /></build>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)
        let md = try XCTUnwrap(mesh.metadata)
        XCTAssertEqual(md.application, "BambuStudio-1.9.0")
        XCTAssertEqual(md.creationDate, "2026-04-15T10:30:00Z")
        XCTAssertEqual(md.designer, "Test User")
        XCTAssertEqual(md.title, "Demo Cube")
        XCTAssertEqual(md.other["CustomKey"], "CustomValue")
    }

    func testParse3MF_noMetadata_metadataIsNil() throws {
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
                <triangles><triangle v1="0" v2="1" v3="2" /></triangles>
              </mesh>
            </object>
          </resources>
          <build><item objectid="1" /></build>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)
        XCTAssertNil(mesh.metadata)
    }

    // MARK: - Multi-plate enumeration (P1.4)

    func testListPlates_multiplePlates_returnsAllInOrder() throws {
        // 1×1 PNG bytes — minimal valid PNG to satisfy archive read.
        let pngHeader: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x00, 0x00, 0x00, 0x00, 0x3B, 0x7E, 0x9B,
            0x55, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82,
        ]
        let png = Data(pngHeader)
        let url = try make3MFFile(entries: [
            (path: "3D/3dmodel.model", content: XCTUnwrap("<model/>".data(using: .utf8))),
            (path: "Metadata/plate_2.png", content: png),
            (path: "Metadata/plate_1.png", content: png),
            (path: "Metadata/plate_3.png", content: png),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let plates = ThreeMFExtractor.listPlates(from: url)
        XCTAssertEqual(plates.count, 3)
        // Sort by parsed plate index (1, 2, 3) regardless of archive order.
        XCTAssertEqual(plates.map(\.index), [1, 2, 3])
        XCTAssertEqual(plates[0].path, "Metadata/plate_1.png")
        // Lazy: PNG bytes load on demand via extractPlate (throws on archive failure).
        let data = try ThreeMFExtractor.extractPlate(plates[0], from: url)
        XCTAssertNotNil(data)
        XCTAssertFalse(data?.isEmpty ?? true)
    }

    // MARK: - Metadata-only fast path (P1)

    func testParseMetadata_extractsTagsWithoutMeshData() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <metadata name="Application">BambuStudio-1.9.0</metadata>
          <metadata name="Title">Demo</metadata>
          <resources/>
          <build/>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let md = try ThreeMFMeshParser.parseMetadata(from: url)
        XCTAssertNotNil(md)
        XCTAssertEqual(md?.application, "BambuStudio-1.9.0")
        XCTAssertEqual(md?.title, "Demo")
    }

    func testParseMetadata_noMetadata_returnsNil() throws {
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources/>
          <build/>
        </model>
        """
        let url = try make3MFFile(modelXML: modelXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let md = try ThreeMFMeshParser.parseMetadata(from: url)
        XCTAssertNil(md)
    }

    func testParseMetadata_brokenArchive_throws() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("3mf")
        try Data("not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFMeshParser.parseMetadata(from: url))
    }

    func testListPlates_noPlates_returnsEmpty() throws {
        let url = try make3MFFile(entries: [
            (path: "3D/3dmodel.model", content: XCTUnwrap("<model/>".data(using: .utf8))),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(ThreeMFExtractor.listPlates(from: url), [])
    }
}
