import AppIntents
import AppKit
import Foundation
import SceneKit

/// Returns a textual summary of a .3mf, .stl, or .gcode file. Surface for Siri / Shortcuts.
struct ShowThreeMFInfo: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Show 3MF/STL Info"
    nonisolated(unsafe) static var description = IntentDescription(
        "Returns triangle count, vertex count, bounding box, and metadata for a .3mf, .stl, or .gcode file."
    )

    @Parameter(title: "File")
    var file: IntentFile

    static var openAppWhenRun: Bool {
        false
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = file.fileURL else {
            throw $file.needsValueError("Expected a file with an on-disk URL")
        }
        let ext = url.pathExtension.lowercased()
        let summary: String
        switch ext {
        case "gcode":
            let toolpath = try GCodeParser.parse(from: url, limits: .quickLook)
            let dims = toolpath.boundingBox.dimensions
            let etaSec = Int(toolpath.estimatedSeconds.rounded())
            summary = String(
                format: "%@: %d layers, %d segments, %.1f × %.1f × %.1f mm, ~%dh %02dm est.",
                url.lastPathComponent,
                toolpath.layerCount,
                toolpath.segments.count,
                dims.x, dims.y, dims.z,
                etaSec / 3600, (etaSec % 3600) / 60
            )
        case "stl", "3mf":
            let mesh: MeshData = ext == "stl"
                ? try STLParser.parseMesh(from: url, limits: .quickLook)
                : try ThreeMFMeshParser.parseMesh(from: url, limits: .quickLook)
            let stats = mesh.statistics()
            let dims = stats.boundingBox.dimensions
            var s = String(
                format: "%@: %d triangles, %d vertices, %.1f × %.1f × %.1f mm, volume %.1f cm³",
                url.lastPathComponent,
                mesh.indices.count / 3,
                mesh.vertices.count,
                dims.x, dims.y, dims.z,
                stats.volume / 1000
            )
            if let app = mesh.metadata?.application {
                s += " (sliced with \(app))"
            }
            summary = s
        default:
            throw $file.needsValueError("Expected a .3mf, .stl, or .gcode file")
        }
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

/// Renders a PNG thumbnail of a .3mf, .stl, or .gcode file at a specified size. Surface for Shortcuts.
struct RenderThreeMFThumbnail: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Render 3MF/STL Thumbnail"
    nonisolated(unsafe) static var description = IntentDescription(
        "Renders a PNG thumbnail of a .3mf, .stl, or .gcode file at the requested size."
    )

    /// Matches CLI.maxThumbnailSize — caps SCNRenderer.snapshot memory.
    private static let maxThumbnailSize = 4096

    @Parameter(title: "File")
    var file: IntentFile

    @Parameter(title: "Size", default: 512)
    var size: Int

    static var openAppWhenRun: Bool {
        false
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard size > 0, size <= Self.maxThumbnailSize else {
            throw $size.needsValueError("Expected size between 1 and \(Self.maxThumbnailSize)")
        }
        guard let url = file.fileURL else {
            throw $file.needsValueError("Expected a file with an on-disk URL")
        }
        let ext = url.pathExtension.lowercased()
        let scene: SCNScene
        switch ext {
        case "stl":
            let mesh = try STLParser.parseMesh(from: url, limits: .quickLook)
            scene = SceneBuilder.buildScene(from: mesh)
        case "3mf":
            let mesh = try ThreeMFMeshParser.parseMesh(from: url, limits: .quickLook)
            scene = SceneBuilder.buildScene(from: mesh)
        case "gcode":
            let toolpath = try GCodeParser.parse(
                from: url,
                limits: .quickLook,
                outputSegmentBudget: GCodeParser.thumbnailSegmentBudget,
                computesStatistics: false
            )
            scene = ToolpathSceneBuilder.buildTopDownScene(from: toolpath)
        default:
            throw $file.needsValueError("Expected a .3mf, .stl, or .gcode file")
        }
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        if let cam = scene.rootNode.childNode(withName: "camera", recursively: true) {
            renderer.pointOfView = cam
        }
        let pixelSize = CGSize(width: size, height: size)
        let image = renderer.snapshot(atTime: 0, with: pixelSize, antialiasingMode: .multisampling2X)

        guard
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let buffer = CFDataCreateMutable(nil, 0)
            .map({ NSMutableData(data: $0 as Data) }) ?? NSMutableData() as Optional,
            let dest = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil)
        else {
            throw NSError(domain: "ShowThreeMFInfo", code: 1)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ShowThreeMFInfo", code: 2)
        }
        return .result(value: IntentFile(
            data: buffer as Data,
            filename: "\(url.deletingPathExtension().lastPathComponent).png"
        ))
    }
}

/// Registers our intents as App Shortcuts so they appear in the Shortcuts app + Siri.
struct ThreeMFAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowThreeMFInfo(),
            phrases: ["Show \(.applicationName) info"],
            shortTitle: "3MF Info",
            systemImageName: "cube"
        )
        AppShortcut(
            intent: RenderThreeMFThumbnail(),
            phrases: ["Render \(.applicationName) thumbnail"],
            shortTitle: "3MF Thumbnail",
            systemImageName: "photo"
        )
    }
}
