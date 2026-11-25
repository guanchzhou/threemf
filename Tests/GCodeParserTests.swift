import simd
import XCTest
#if canImport(ThreeMFCore)
    @testable import ThreeMFCore
#endif

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

    func testParse_craftedCoords_estimatedSecondsStaysFiniteAndInIntRange() throws {
        // Crafted G-code: `1e999` overflows to +Inf, `1e30` is huge-finite. Either would
        // make estimatedSeconds non-finite / > Int.max, and the HUD's Int(...) cast would
        // trap (crash the preview). The parser must sanitize it before returning.
        let gcode = """
        G0 X0 Y0 Z0.2 F1
        G1 X1e999 Y0 E1 F1
        G1 X1e30 Y1e30 E2 F1
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertTrue(toolpath.estimatedSeconds.isFinite)
        XCTAssertGreaterThanOrEqual(toolpath.estimatedSeconds, 0)
        // The whole point: the value survives an Int() cast without trapping.
        XCTAssertLessThanOrEqual(toolpath.estimatedSeconds, Double(Int.max))
        _ = Int(toolpath.estimatedSeconds.rounded())
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

    func testParse_outputSegmentBudget_capsCountButSpansWholeFile() throws {
        var lines = ["G0 X0 Y0 Z0.2 F600"]
        for i in 1 ... 256 {
            lines.append("G1 X\(i) Y0 E\(i)")
        }
        let url = try writeTempFile(string: lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url) }

        let full = try GCodeParser.parse(from: url)
        XCTAssertEqual(full.segments.count, 257)

        let sampled = try GCodeParser.parse(from: url, outputSegmentBudget: 16)
        XCTAssertLessThanOrEqual(sampled.segments.count, 16)
        XCTAssertGreaterThan(sampled.segments.count, 4)
        XCTAssertEqual(sampled.totalExtrudedMM, full.totalExtrudedMM, accuracy: 0.01)
        XCTAssertEqual(sampled.segments.first?.start.x ?? -.infinity, 0, accuracy: 0.001)
        XCTAssertGreaterThan(sampled.segments.last?.end.x ?? 0, 128)
        XCTAssertEqual(sampled.layerCount, full.layerCount)
    }

    func testParse_withoutStatisticsStillKeepsThumbnailMetadata() throws {
        let gcode = """
        G0 X0 Y0 Z0.2 F600
        G1 X10 Y0 E1
        G0 X10 Y10 Z0.4
        G1 X0 Y10 E2
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(
            from: url,
            outputSegmentBudget: 3,
            computesStatistics: false
        )

        XCTAssertLessThanOrEqual(toolpath.segments.count, 3)
        XCTAssertEqual(toolpath.layerCount, 2)
        XCTAssertEqual(toolpath.totalExtrudedMM, 0)
        XCTAssertEqual(toolpath.totalTravelMM, 0)
        XCTAssertEqual(toolpath.estimatedSeconds, 0)
    }

    func testParse_zeroPaddedG01_acceptedAsLinearMove() throws {
        let gcode = """
        G00 X0 Y0 Z0.2
        G01 X10 Y0 E1
        G01 X20 Y0 E2
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.count, 3)
        let extrudes = toolpath.segments.count(where: { $0.extrudes })
        XCTAssertEqual(extrudes, 2)
        XCTAssertEqual(toolpath.segments[1].end.x, 10, accuracy: 0.001)
        XCTAssertEqual(toolpath.segments[2].end.x, 20, accuracy: 0.001)
    }

    func testParse_relativeExtrusion_M83_bothDeltasExtrude() throws {
        let gcode = """
        G0 X0 Y0 Z0.2
        M83
        G1 X10 Y0 E0.5
        G1 X20 Y0 E0.5
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.count, 3)
        XCTAssertFalse(toolpath.segments[0].extrudes)
        XCTAssertTrue(toolpath.segments[1].extrudes)
        XCTAssertTrue(toolpath.segments[2].extrudes)
    }

    func testParse_relativeXYZ_G91_accumulatesPosition() throws {
        let gcode = """
        G0 X0 Y0 Z0
        G91
        G1 X10
        G1 X10
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.last?.end.x ?? -.infinity, 20, accuracy: 0.001)
    }

    func testParse_nonFiniteCoordinate_dropsMove() throws {
        let gcode = """
        G0 X0 Y0 Z0.2
        G1 X1e999 Y0 E1
        G1 X10 Y0 E2
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.count, 2)
        XCTAssertEqual(toolpath.segments[1].start.x, 0, accuracy: 0.001)
        XCTAssertEqual(toolpath.segments[1].end.x, 10, accuracy: 0.001)
        XCTAssertTrue(toolpath.segments.allSatisfy {
            $0.start.x.isFinite && $0.end.x.isFinite
        })
    }

    func testParse_arcG2_withIJ_subdividesAndReachesEndpoint() throws {
        // Semicircle clockwise from (0,0) to (10,0) around center (5,0): I=5 J=0.
        let gcode = """
        G0 X0 Y0 Z0.2
        G2 X10 Y0 I5 J0 E1 F600
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertGreaterThan(toolpath.segments.count, 2)
        let last = try XCTUnwrap(toolpath.segments.last)
        XCTAssertEqual(last.end.x, 10, accuracy: 0.01)
        XCTAssertEqual(last.end.y, 0, accuracy: 0.01)
        XCTAssertTrue(toolpath.segments.dropFirst().allSatisfy(\.extrudes))
        // G2 CW from (0,0)→(10,0) around (5,0) sweeps through positive Y.
        let midY = toolpath.segments.dropFirst().map(\.end.y).max() ?? 0
        XCTAssertGreaterThan(midY, 1)
    }

    func testParse_arcG3_withIJ_subdividesAndReachesEndpoint() throws {
        let gcode = """
        G0 X0 Y0 Z0.2
        G3 X10 Y0 I5 J0 E1 F600
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertGreaterThan(toolpath.segments.count, 2)
        let last = try XCTUnwrap(toolpath.segments.last)
        XCTAssertEqual(last.end.x, 10, accuracy: 0.01)
        XCTAssertEqual(last.end.y, 0, accuracy: 0.01)
        // G3 CCW from (0,0)→(10,0) around (5,0) sweeps through negative Y.
        let midY = toolpath.segments.dropFirst().map(\.end.y).min() ?? 0
        XCTAssertLessThan(midY, -1)
    }

    func testParse_g92ExtruderReset_allowsSubsequentM82Extrusion() throws {
        // Slicers in M82 (absolute E) mode prime to E20, then emit `G92 E0` before printing.
        let gcode = """
        G0 X0 Y0 Z0.2 F600
        G1 X10 Y0 E20
        G92 E0
        G1 X20 Y0 E0.5
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.count, 3)
        XCTAssertTrue(toolpath.segments[1].extrudes)
        XCTAssertTrue(toolpath.segments[2].extrudes)
        XCTAssertEqual(toolpath.totalExtrudedMM, 20, accuracy: 0.001)
    }

    func testParse_parenthesizedComments_ignoredInline() throws {
        let gcode = """
        (header comment with X999 E999)
        G0 X0 (skip X500) Y0 Z0.2
        G1 X10 (comment E-50 Y999) Y0 E1
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.count, 2)
        XCTAssertEqual(toolpath.segments[1].end.x, 10, accuracy: 0.001)
        XCTAssertEqual(toolpath.segments[1].end.y, 0, accuracy: 0.001)
        XCTAssertTrue(toolpath.segments[1].extrudes)
    }

    func testParse_startupLiftAndZHop_doNotCollapseOrInflateLayers() throws {
        // Homing lift G0 Z10 before layer 1 (Z0.2), plus a Z-hop to Z0.6 mid-layer 1.
        let gcode = """
        G0 X0 Y0 Z10
        G0 X0 Y0 Z0.2
        G1 X10 Y0 E1
        G0 X10 Y0 Z0.6
        G0 X10 Y10 Z0.6
        G0 X10 Y10 Z0.2
        G1 X0 Y10 E2
        G0 X0 Y10 Z0.4
        G1 X0 Y0 E3
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.layerCount, 2)
        let extrudeLayers = toolpath.segments.filter(\.extrudes).map(\.layerIndex)
        XCTAssertEqual(extrudeLayers, [0, 0, 1])
    }

    func testParse_extremeCommandNumberAndExponent_doNotTrap() throws {
        let gcode = """
        G99999999999999999999999999 X10 Y10
        M99999999999999999999999999 S200
        G0 X0 Y0 Z0.2
        G1 X1e9999999999999999999999 Y0 E1
        G1 X1e-9999999999999999999999 Y5 E1
        G1 X10 Y5 E2
        """
        let url = try writeTempFile(string: gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let toolpath = try GCodeParser.parse(from: url)
        XCTAssertEqual(toolpath.segments.count, 3)
        XCTAssertEqual(toolpath.segments[1].end.x, 0, accuracy: 1e-6)
        XCTAssertEqual(toolpath.segments[2].end.x, 10, accuracy: 1e-3)
    }

    func testParse_hugeArcRadius_clampsBeforeIntCastWithoutTrapping() throws {
        // 1) I1e18 -> finite arcRadius (1e18^2 = 1e36 fits in Float), rawSegs (~2.5e19) > Int.max;
        //    Double calculation + pre-Int clamp must avoid trapping and cap at maxSegmentsPerArc.
        let gcodeFiniteOverflow = """
        G0 X0 Y0 Z0.2
        G2 X10 Y0 I1e18 J0 E1 F600
        """
        let url1 = try writeTempFile(string: gcodeFiniteOverflow)
        defer { try? FileManager.default.removeItem(at: url1) }

        let tp1 = try GCodeParser.parse(from: url1)
        XCTAssertGreaterThan(tp1.segments.count, 1)
        XCTAssertLessThanOrEqual(tp1.segments.count, 16385)

        // 2) I1e38 -> simd_length overflows Float to +Inf; must skip cleanly without trapping.
        let gcodeInfRadius = """
        G0 X0 Y0 Z0.2
        G2 X10 Y0 I1e38 J0 E1 F600
        """
        let url2 = try writeTempFile(string: gcodeInfRadius)
        defer { try? FileManager.default.removeItem(at: url2) }

        let tp2 = try GCodeParser.parse(from: url2)
        XCTAssertEqual(tp2.segments.count, 1)
    }
}
