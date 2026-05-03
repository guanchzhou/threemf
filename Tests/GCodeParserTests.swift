import simd
import XCTest

final class GCodeParserTests: XCTestCase {
    private func writeTempFile(string: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gcode-\(UUID().uuidString)")
            .appendingPathExtension("gcode")
        try string.data(using: .utf8)!.write(to: url)
        return url
    }

    func testParse_simpleSquare_emitsExpectedSegments() throws {
        let gcode = """
        ; tiny square
        G0 X0 Y0 Z0.2 F600
        G1 X10 Y0 E1 F300
        G1 X10 Y10 E2
        G1 X0 Y10 E3
        G1 X0 Y0 E4
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.count, 5)
        XCTAssertEqual(toolpath.layerCount, 1)
        // 4 extrudes (the closing square) — first move is travel.
        let extrudes = toolpath.segments.count(where: { $0.extrudes })
        XCTAssertEqual(extrudes, 4)
        let travels = toolpath.segments.count(where: { !$0.extrudes })
        XCTAssertEqual(travels, 1)
    }

    func testParse_multipleLayers_detected() throws {
        let gcode = """
        G0 X0 Y0 Z0.2
        G1 X10 Y0 E1
        G0 X0 Y0 Z0.4
        G1 X10 Y0 E2
        G0 X0 Y0 Z0.6
        G1 X10 Y0 E3
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.layerCount, 3)
        // Each travel-then-extrude pair belongs to the same layer.
        let layerIndices = Set(toolpath.segments.map(\.layerIndex))
        XCTAssertEqual(layerIndices, [0, 1, 2])
    }

    func testParse_extrudedAndTravelLengths_summed() throws {
        let gcode = """
        G0 X0 Y0 Z0.2 F600
        G1 X10 Y0 E1
        G0 X20 Y0
        G1 X30 Y0 E2
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.totalExtrudedMM, 20, accuracy: 0.001)
        // First segment is X0→X0 Z0→Z0.2 (length 0.2 travel), G0 X20 from X10 is 10mm travel.
        XCTAssertEqual(toolpath.totalTravelMM, 10.2, accuracy: 0.001)
    }

    func testParse_emptyFile_throws() throws {
        let url = try writeTempFile(string: "")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try GCodeParser.parse(from: url))
    }

    func testParse_onlyComments_throws() throws {
        let gcode = """
        ; just comments
        ; nothing here
        ; truly empty
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try GCodeParser.parse(from: url))
    }

    func testParse_ignoresUnknownCommands() throws {
        let gcode = """
        M104 S200 ; set hot end temp (ignored)
        M140 S60  ; set bed temp (ignored)
        G28       ; home (ignored — not G0/G1)
        G0 X0 Y0 Z0.2
        G1 X10 Y0 E1
        M84       ; disable steppers (ignored)
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.count, 2)
    }

    func testParse_feedrateIsSticky() throws {
        let gcode = """
        G0 X0 Y0 Z0.2 F600
        G1 X10 Y0 E1
        G1 X20 Y0 E2
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.allSatisfy { $0.feedrate == 600 }, true)
    }

    func testParse_boundingBox_correct() throws {
        let gcode = """
        G0 X-5 Y-5 Z0
        G1 X5 Y5 Z2 E1
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        let bb = toolpath.boundingBox
        XCTAssertEqual(bb.min.x, -5, accuracy: 0.001)
        XCTAssertEqual(bb.min.y, -5, accuracy: 0.001)
        XCTAssertEqual(bb.max.x, 5, accuracy: 0.001)
        XCTAssertEqual(bb.max.y, 5, accuracy: 0.001)
        XCTAssertEqual(bb.max.z, 2, accuracy: 0.001)
    }

    func testParse_estimatedTime_fromFeedrate() throws {
        // 600 mm/min = 10 mm/s, 10mm move → 1 second.
        let gcode = """
        G0 X0 Y0 Z0.2 F600
        G1 X10 Y0 E1
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        // First travel is X0→X0 Z0→Z0.2 (0.2 mm @ 600 = 0.02 s) + 10mm at 600 = 1.0 s.
        XCTAssertEqual(toolpath.estimatedSeconds, 1.02, accuracy: 0.01)
    }
}
