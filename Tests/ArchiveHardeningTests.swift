import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
#if canImport(ThreeMFCore)
    @testable import ThreeMFCore
#endif

/// Crafted-archive cases: lookup cost on huge central directories, component caps, thumbnail
/// fallback past corrupt candidates, PNG type enforcement, and `_rels/.rels` root discovery.
final class ArchiveHardeningTests: XCTestCase {
    private static let triangleMesh = """
    <mesh>
      <vertices>
        <vertex x="0" y="0" z="0" />
        <vertex x="1" y="0" z="0" />
        <vertex x="0" y="1" z="0" />
      </vertices>
      <triangles><triangle v1="0" v2="1" v3="2" /></triangles>
    </mesh>
    """

    // MARK: - Lookup cost

    func testManyEntriesAndComponents_parseWithinTimeBudget() throws {
        let componentCount = ThreeMFMeshParser.maxComponents + 5000
        var components = ""
        for n in 0 ..< componentCount {
            components += "<component objectid=\"\(n + 2)\" p:path=\"/3D/Objects/missing_\(n).model\" />\n"
        }
        let model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
               xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
          <resources>
            <object id="1" type="model"><components>
            \(components)
            </components></object>
          </resources>
          <build><item objectid="1" /></build>
        </model>
        """
        var entries: [(path: String, content: Data)] = (0 ..< 20000).map { n in
            (path: "Junk/entry_\(n).bin", content: Data())
        }
        entries.append((path: "3D/3dmodel.model", content: Data(model.utf8)))
        let url = try writeStoredZip(entries)
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date()
        XCTAssertThrowsError(try ThreeMFMeshParser.parseMesh(from: url, limits: .quickLook)) { error in
            XCTAssertEqual(error as? ThreeMFMeshParserError, .noMeshData)
        }
        XCTAssertThrowsError(try ThreeMFExtractor.extractThumbnail(from: url))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
    }

    func testScanner_capsComponentsAndBuildItems() {
        let extra = 50
        var body = "<resources><object id=\"1\"><components>"
        for n in 0 ..< ThreeMFMeshParser.maxComponents + extra {
            body += "<component objectid=\"\(n + 2)\" />"
        }
        body += "</components></object></resources><build>"
        for _ in 0 ..< ThreeMFMeshParser.maxBuildItems + extra {
            body += "<item objectid=\"1\" />"
        }
        body += "</build>"
        let result = FastMeshScanner.scan(Data("<model>\(body)</model>".utf8), limits: .quickLook)
        XCTAssertEqual(result.components.count, ThreeMFMeshParser.maxComponents)
        XCTAssertEqual(result.buildItems.count, ThreeMFMeshParser.maxBuildItems)
    }

    func testRepeatedComponentPath_aliasesEveryComponentToSharedFile() throws {
        let root = """
        <model xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
          <resources>
            <object id="1"><components>
              <component objectid="2" p:path="/3D/Objects/part.model" />
              <component objectid="3" p:path="/3D/Objects/part.model" transform="1 0 0 0 1 0 0 0 1 10 0 0" />
              <component objectid="4" p:path="/3D/Objects/part.model" transform="1 0 0 0 1 0 0 0 1 20 0 0" />
            </components></object>
          </resources>
          <build><item objectid="1" /></build>
        </model>
        """
        let part = "<model><resources><object id=\"10\">\(Self.triangleMesh)</object></resources></model>"
        let url = try writeStoredZip([
            (path: "3D/3dmodel.model", content: Data(root.utf8)),
            (path: "3D/Objects/part.model", content: Data(part.utf8)),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)
        XCTAssertEqual(mesh.vertices.count, 9)
        XCTAssertEqual(mesh.vertices.map(\.x).max(), 21)
    }

    // MARK: - Thumbnails

    func testExtractThumbnail_skipsCorruptFirstPlate() throws {
        let url = try writeStoredZip([
            (path: "Metadata/plate_1.png", content: Data("not a png".utf8)),
            (path: "Metadata/plate_2.png", content: TestPNG.tiny1x1),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try ThreeMFExtractor.extractThumbnail(from: url), TestPNG.tiny1x1)
    }

    func testExtractThumbnail_fallbackSkipsCorruptCandidate() throws {
        let url = try writeStoredZip([
            (path: "Metadata/a_bad.png", content: Data("not a png".utf8)),
            (path: "Metadata/b_good.png", content: TestPNG.tiny1x1),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try ThreeMFExtractor.extractThumbnail(from: url), TestPNG.tiny1x1)
    }

    func testExtractThumbnail_rejectsJPEGNamedPNG() throws {
        let jpeg = try encodedImage(type: .jpeg, width: 4, height: 4)
        let url = try writeStoredZip([(path: "Metadata/plate_1.png", content: jpeg)])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFExtractor.extractThumbnail(from: url)) { error in
            XCTAssertEqual(error as? ThreeMFExtractorError, .noThumbnailFound)
        }
    }

    func testValidator_rejectsNonPNGFormats() throws {
        for type in [UTType.tiff, .jpeg, .gif] {
            let data = try encodedImage(type: type, width: 4, height: 4)
            XCTAssertThrowsError(try SafePNGValidator.validatePNGData(data), type.identifier) { error in
                XCTAssertEqual(error as? SafePNGValidator.ValidationError, .invalidImage)
            }
            XCTAssertNil(SafePNGValidator.cgImage(fromPNG: data, maxPixelSize: 64))
        }
    }

    func testValidator_rejectsPNGSignatureOnTIFFPayload() throws {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try data.append(encodedImage(type: .tiff, width: 4, height: 4))
        XCTAssertThrowsError(try SafePNGValidator.validatePNGData(data))
    }

    func testCGImage_downsamplesToMaxPixelSize() throws {
        let png = try encodedImage(type: .png, width: 1000, height: 500)
        let image = try XCTUnwrap(SafePNGValidator.cgImage(fromPNG: png, maxPixelSize: 100))
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 50)

        let small = try XCTUnwrap(SafePNGValidator.cgImage(fromPNG: TestPNG.tiny1x1, maxPixelSize: 100))
        XCTAssertEqual(small.width, 1)
    }

    // MARK: - Root model discovery

    func testParseMesh_followsPackageRelationshipToNonstandardRoot() throws {
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Target="/Metadata/thumbnail.png" Id="rel0"
            Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail" />
          <Relationship Target="/3D/Custom%20Root/main.model" Id="rel1"
            Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel" />
        </Relationships>
        """
        let model = """
        <model><metadata name="Title">Rel root</metadata>
        <resources><object id="1">\(Self.triangleMesh)</object></resources>
        <build><item objectid="1" /></build></model>
        """
        let url = try writeStoredZip([
            (path: "_rels/.rels", content: Data(rels.utf8)),
            (path: "3D/Custom Root/main.model", content: Data(model.utf8)),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)
        XCTAssertEqual(mesh.vertices.count, 3)
        XCTAssertEqual(try ThreeMFMeshParser.parseMetadata(from: url)?.title, "Rel root")
    }

    func testRelationshipTarget_rejectsDTDAndTraversal() {
        let type = "http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"
        let withDTD = """
        <?xml version="1.0"?><!DOCTYPE r [<!ENTITY a "x">]>
        <Relationships><Relationship Target="/3D/a.model" Type="\(type)" /></Relationships>
        """
        XCTAssertNil(ThreeMFMeshParser.modelRelationshipTarget(inRelationships: Data(withDTD.utf8)))

        let traversal = "<Relationships><Relationship Target=\"/../evil.model\" Type=\"\(type)\" /></Relationships>"
        XCTAssertNil(ThreeMFMeshParser.modelRelationshipTarget(inRelationships: Data(traversal.utf8)))

        let ok = "<Relationships><Relationship Target=\"/3D/a.model\" Type=\"\(type)\" /></Relationships>"
        XCTAssertEqual(ThreeMFMeshParser.modelRelationshipTarget(inRelationships: Data(ok.utf8)), "3D/a.model")
    }

    func testParseMesh_fallsBackToConventionalPathWhenRelationshipMissing() throws {
        let rels = """
        <Relationships><Relationship Target="/3D/absent.model"
          Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel" /></Relationships>
        """
        let model = "<model><resources><object id=\"1\">\(Self.triangleMesh)</object></resources></model>"
        let url = try writeStoredZip([
            (path: "_rels/.rels", content: Data(rels.utf8)),
            (path: "3D/3dmodel.model", content: Data(model.utf8)),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try ThreeMFMeshParser.parseMesh(from: url).vertices.count, 3)
    }

    // MARK: - Spotlight

    func testParseMetadata_stopsAtResources() throws {
        let model = """
        <model><metadata name="Title">Early</metadata>
        <resources><object id="1">\(Self.triangleMesh)</object></resources>
        <metadata name="Designer">Late</metadata></model>
        """
        let url = try writeStoredZip([(path: "3D/3dmodel.model", content: Data(model.utf8))])
        defer { try? FileManager.default.removeItem(at: url) }

        let md = try XCTUnwrap(ThreeMFMeshParser.parseMetadata(from: url))
        XCTAssertEqual(md.title, "Early")
        XCTAssertNil(md.designer)
    }

    func testParseMesh_withoutNormals_keepsGeometry() throws {
        let model = "<model><resources><object id=\"1\">\(Self.triangleMesh)</object></resources></model>"
        let url = try writeStoredZip([(path: "3D/3dmodel.model", content: Data(model.utf8))])
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url, computesNormals: false)
        XCTAssertNil(mesh.normals)
        XCTAssertEqual(mesh.indices.count, 3)

        let attrs = NSMutableDictionary()
        XCTAssertTrue(SpotlightMetadataExtractor.populate(attributes: attrs, fileURL: url))
        XCTAssertEqual(attrs["com_andreymaltsev_threemf_triangleCount"] as? NSNumber, 1)
    }

    // MARK: - Deadlines

    func testTimeoutToken_expires() {
        XCTAssertTrue(ParseCancellation(timeout: 0).isCancelled)
        XCTAssertFalse(ParseCancellation(timeout: 60).isCancelled)
    }

    func testExtractThumbnail_aggregateBudgetCapsMultiCandidateDecompression() throws {
        // First corrupt candidate consumes 4096 bytes of a 4100-byte aggregate budget,
        // leaving only 4 bytes so both subsequent candidates exceed the remaining budget.
        let junk = Data(repeating: 0x41, count: 4096)
        let url = try writeStoredZip([
            (path: "Metadata/plate_1.png", content: junk),
            (path: "Metadata/plate_2.png", content: junk),
            (path: "Metadata/plate_3.png", content: TestPNG.tiny1x1),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ThreeMFArchive(url: url)
        XCTAssertThrowsError(
            try ThreeMFExtractor.extractThumbnail(from: archive, aggregateByteBudget: 4100)
        ) { error in
            XCTAssertEqual(error as? ThreeMFExtractorError, .thumbnailTooLarge)
        }
    }

    func testExtractThumbnail_preCancelledThrowsCancellationError() throws {
        let url = try writeStoredZip([(path: "Metadata/plate_1.png", content: TestPNG.tiny1x1)])
        defer { try? FileManager.default.removeItem(at: url) }

        let token = ParseCancellation()
        token.cancel()
        XCTAssertThrowsError(
            try ThreeMFExtractor.extractThumbnail(from: url, cancellation: token)
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testExtractThumbnail_respectsLoweredFallbackCandidateCap() throws {
        var entries: [(path: String, content: Data)] = (0 ..< ThreeMFExtractor.maxFallbackCandidates).map { i in
            (path: "Metadata/bad_\(i).png", content: Data("not-a-png".utf8))
        }
        entries.append((path: "Metadata/z_valid.png", content: TestPNG.tiny1x1))
        let url = try writeStoredZip(entries)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(ThreeMFExtractor.maxFallbackCandidates, 32)
        XCTAssertThrowsError(try ThreeMFExtractor.extractThumbnail(from: url)) { error in
            XCTAssertEqual(error as? ThreeMFExtractorError, .noThumbnailFound)
        }
    }

    // MARK: - Helpers

    /// Writes a stored (uncompressed) ZIP directly. ZIPFoundation rewrites the central
    /// directory on every `addEntry`, which makes 20,000-entry fixtures quadratic to build.
    private func writeStoredZip(_ entries: [(path: String, content: Data)]) throws -> URL {
        func le16(_ value: Int, into data: inout Data) {
            withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) }
        }
        func le32(_ value: UInt32, into data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        var body = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = entry.content.crc32(checksum: 0)
            let size = UInt32(entry.content.count)
            let offset = UInt32(body.count)

            le32(0x0403_4B50, into: &body)
            le16(20, into: &body) // version needed
            le16(0x0800, into: &body) // UTF-8 names
            le16(0, into: &body) // stored
            le16(0, into: &body) // time
            le16(0x21, into: &body) // date 1980-01-01
            le32(crc, into: &body)
            le32(size, into: &body)
            le32(size, into: &body)
            le16(name.count, into: &body)
            le16(0, into: &body)
            body.append(name)
            body.append(entry.content)

            le32(0x0201_4B50, into: &central)
            le16(20, into: &central) // version made by
            le16(20, into: &central)
            le16(0x0800, into: &central)
            le16(0, into: &central)
            le16(0, into: &central)
            le16(0x21, into: &central)
            le32(crc, into: &central)
            le32(size, into: &central)
            le32(size, into: &central)
            le16(name.count, into: &central)
            le16(0, into: &central) // extra
            le16(0, into: &central) // comment
            le16(0, into: &central) // disk
            le16(0, into: &central) // internal attributes
            le32(0, into: &central) // external attributes
            le32(offset, into: &central)
            central.append(name)
        }
        let centralOffset = UInt32(body.count)
        body.append(central)
        le32(0x0605_4B50, into: &body)
        le16(0, into: &body)
        le16(0, into: &body)
        le16(entries.count, into: &body)
        le16(entries.count, into: &body)
        le32(UInt32(central.count), into: &body)
        le32(centralOffset, into: &body)
        le16(0, into: &body)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardening-\(UUID().uuidString)")
            .appendingPathExtension("3mf")
        try body.write(to: url)
        return url
    }

    private func encodedImage(type: UTType, width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let buffer = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            buffer,
            type.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return buffer as Data
    }
}
