import Foundation
import XCTest

/// Covers the CLI's error-UX surface: format resolution, --size validation, and the
/// missing/unsupported-file paths. CLI.swift is compiled into this test bundle (see
/// project.yml) so these pure helpers are unit-testable without spawning the binary.
final class CLITests: XCTestCase {
    // MARK: - resolveFormat

    func testResolveFormat_knownExtensions() throws {
        XCTAssertEqual(try CLI.resolveFormat(URL(fileURLWithPath: "m.stl")), .stl)
        XCTAssertEqual(try CLI.resolveFormat(URL(fileURLWithPath: "m.STL")), .stl) // case-insensitive
        XCTAssertEqual(try CLI.resolveFormat(URL(fileURLWithPath: "m.gcode")), .gcode)
        XCTAssertEqual(try CLI.resolveFormat(URL(fileURLWithPath: "m.3mf")), .threemf)
    }

    func testResolveFormat_extensionlessDefaultsTo3MF() throws {
        // Archives are sometimes exported without a suffix — keep the lenient default.
        XCTAssertEqual(try CLI.resolveFormat(URL(fileURLWithPath: "model")), .threemf)
    }

    func testResolveFormat_unknownExtension_throwsClearError() {
        XCTAssertThrowsError(try CLI.resolveFormat(URL(fileURLWithPath: "report.txt"))) { error in
            // The message must name the bad extension and the supported set — not a
            // misleading downstream "cannot open .3mf archive".
            let msg = (error as? CLIError)?.errorDescription ?? ""
            XCTAssertTrue(msg.contains(".txt"), msg)
            XCTAssertTrue(msg.contains(".stl") && msg.contains(".gcode"), msg)
        }
    }

    // MARK: - resolveSize

    func testResolveSize_absent_defaults512() throws {
        XCTAssertEqual(try CLI.resolveSize(from: ["thumbnail", "a", "b"]), 512)
    }

    func testResolveSize_valid() throws {
        XCTAssertEqual(try CLI.resolveSize(from: ["thumbnail", "a", "b", "--size", "1024"]), 1024)
    }

    func testResolveSize_zeroOrNegative_throws() {
        // The bug this guards: --size 0 → CGSize(0,0) snapshot → broken/blank image.
        XCTAssertThrowsError(try CLI.resolveSize(from: ["--size", "0"]))
        XCTAssertThrowsError(try CLI.resolveSize(from: ["--size", "-5"]))
    }

    func testResolveSize_nonNumeric_throwsInsteadOfSilentDefault() {
        // Old behavior silently rendered 512 on a typo; now it fails loudly.
        XCTAssertThrowsError(try CLI.resolveSize(from: ["--size", "huge"]))
    }

    func testResolveSize_aboveCap_throws() {
        XCTAssertThrowsError(try CLI.resolveSize(from: ["--size", "\(CLI.maxThumbnailSize + 1)"]))
    }

    func testResolveSize_missingValue_throws() {
        XCTAssertThrowsError(try CLI.resolveSize(from: ["thumbnail", "a", "b", "--size"]))
    }

    // MARK: - missing / unsupported file paths (end-to-end through a command)

    func testValidate_missingFile_throwsFileNotFound() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).stl")
        XCTAssertThrowsError(try CLI.validate(file: url)) { error in
            XCTAssertTrue((error as? CLIError)?.errorDescription?.contains("File not found") ?? false)
        }
    }

    func testValidate_unsupportedExtension_throwsUnsupported() throws {
        // A real file with an unsupported extension must fail at format resolution,
        // not with a confusing parse error.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        try Data("not a model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CLI.validate(file: url)) { error in
            XCTAssertTrue((error as? CLIError)?.errorDescription?.contains("Unsupported file format") ?? false)
        }
    }
}
