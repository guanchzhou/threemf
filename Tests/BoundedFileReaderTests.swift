import Darwin
import XCTest
#if canImport(ThreeMFCore)
    @testable import ThreeMFCore
#endif

final class BoundedFileReaderTests: XCTestCase {
    func testRead_rejectsWhenDeclaredSizeExceedsCap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-\(UUID().uuidString)")
            .appendingPathExtension("bin")
        let payload = Data(repeating: 0x41, count: 64)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try BoundedFileReader.dataContents(of: url, maxByteCount: 32)
        ) { error in
            XCTAssertEqual(error as? BoundedFileReader.ReadError, .fileTooLarge)
        }
    }

    func testRead_succeedsWhenWithinCap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-\(UUID().uuidString)")
            .appendingPathExtension("bin")
        let payload = Data([0x01, 0x02, 0x03])
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try BoundedFileReader.dataContents(of: url, maxByteCount: 10)
        XCTAssertEqual(data, payload)
    }

    func testRead_rejectsDirectoryAndFIFO() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try BoundedFileReader.dataContents(of: dir, maxByteCount: 1024))

        let fifo = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try BoundedFileReader.dataContents(of: fifo, maxByteCount: 1024))
    }

    func testSTLParser_rejectsSparseOversizeFromStat() throws {
        let url = sparseFileURL(ext: "stl", logicalSize: Int64(STLParser.maxFileSize) + 1)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try STLParser.parseMesh(from: url)) { error in
            XCTAssertEqual(error as? STLParserError, .fileTooLarge)
        }
    }

    func testGCodeParser_rejectsSparseOversizeFromStat() throws {
        let url = sparseFileURL(ext: "gcode", logicalSize: Int64(GCodeParser.maxFileSize) + 1)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try GCodeParser.parse(from: url)) { error in
            XCTAssertEqual(error as? GCodeParserError, .fileTooLarge)
        }
    }

    private func sparseFileURL(ext: String, logicalSize: Int64) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sparse-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        precondition(fd >= 0, "open failed")
        precondition(ftruncate(fd, logicalSize) == 0, "ftruncate failed")
        close(fd)
        return url
    }
}
