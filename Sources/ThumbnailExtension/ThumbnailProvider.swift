import AppKit
import ImageIO
import os
import QuickLookThumbnailing
import SceneKit
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.andreymaltsev.3mf-quicklook", category: "thumbnail")

class ThumbnailProvider: QLThumbnailProvider {
    /// Skip 3D rendering when no embedded PNG is available and the source file is huge.
    /// Heuristic is intentionally conservative — render time scales with mesh complexity,
    /// and a huge file is a strong proxy without us having to open the archive.
    private static let huge3MFNoEmbedThresholdBytes: Int64 = 100 * 1024 * 1024 // 100 MB
    private static let hugeSTLThresholdBytes: Int64 = 50 * 1024 * 1024 // 50 MB

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let ext = request.fileURL.pathExtension.lowercased()

        // Cache check — both .3mf and .stl write a PNG to the cache after rendering,
        // so a hit here saves the entire parse+render path on the second preview.
        if let cached = ThumbnailCache.cachedThumbnail(for: request.fileURL),
           let image = NSImage(data: cached)
        {
            renderImageThumbnail(image: image, request: request, handler: handler)
            return
        }

        switch ext {
        case "3mf":
            provideThumbnailFor3MF(request: request, handler: handler)
        case "stl":
            provideThumbnailForSTL(request: request, handler: handler)
        case "gcode":
            provideThumbnailForGCode(request: request, handler: handler)
        default:
            log.error("Unsupported thumbnail format: \(ext, privacy: .public)")
            handler(nil, ThreeMFExtractorError.noThumbnailFound)
        }
    }

    private func provideThumbnailForGCode(
        request: QLFileThumbnailRequest,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let fileSize = fileSizeBytes(for: request.fileURL)
        // 200 MB is well above typical (10–50 MB), but a 500 MB pathological file
        // should still skip thumbnailing — the parse cost outweighs the benefit.
        if fileSize > 200 * 1024 * 1024 {
            log.debug("Skipping G-code render for huge file (\(fileSize) bytes)")
            handler(nil, nil)
            return
        }

        do {
            let toolpath = try GCodeParser.parse(from: request.fileURL)
            let scene = ToolpathSceneBuilder.buildTopDownScene(from: toolpath)
            let maxSize = request.maximumSize
            let size = CGSize(width: min(maxSize.width, 512), height: min(maxSize.height, 512))

            let renderer = SCNRenderer(device: nil, options: nil)
            renderer.scene = scene
            if let cam = scene.rootNode.childNode(withName: "camera", recursively: true) {
                renderer.pointOfView = cam
            }
            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling2X)

            if let png = pngRepresentation(of: image) {
                ThumbnailCache.store(png, for: request.fileURL)
            }
            let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
                image.draw(in: CGRect(origin: .zero, size: size))
                return true
            }
            handler(reply, nil)
        } catch {
            log.error("G-code thumbnail parse failed: \(error.localizedDescription, privacy: .public)")
            handler(nil, error)
        }
    }

    private func provideThumbnailFor3MF(
        request: QLFileThumbnailRequest,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // Try embedded PNG first (fast).
        if let imageData = try? ThreeMFExtractor.extractThumbnail(from: request.fileURL),
           let image = NSImage(data: imageData)
        {
            // Cache the raw PNG so subsequent previews skip the ZIP walk.
            ThumbnailCache.store(imageData, for: request.fileURL)
            renderImageThumbnail(image: image, request: request, handler: handler)
            return
        }

        // No embedded PNG — fall back to a 3D render. Skip render for huge files
        // (sandbox-safe: just stat the file and let Finder use a generic icon).
        let fileSize = fileSizeBytes(for: request.fileURL)
        if fileSize > Self.huge3MFNoEmbedThresholdBytes {
            log.debug("Skipping 3D render for huge 3MF (\(fileSize) bytes)")
            handler(nil, nil)
            return
        }

        do {
            let mesh = try ThreeMFMeshParser.parseMesh(from: request.fileURL)
            renderSceneThumbnail(mesh: mesh, request: request, handler: handler)
        } catch {
            log.error("3MF thumbnail mesh parse failed: \(error.localizedDescription, privacy: .public)")
            handler(nil, error)
        }
    }

    private func provideThumbnailForSTL(
        request: QLFileThumbnailRequest,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let fileSize = fileSizeBytes(for: request.fileURL)
        if fileSize > Self.hugeSTLThresholdBytes {
            log.debug("Skipping 3D render for huge STL (\(fileSize) bytes)")
            handler(nil, nil)
            return
        }

        do {
            let mesh = try STLParser.parseMesh(from: request.fileURL)
            renderSceneThumbnail(mesh: mesh, request: request, handler: handler)
        } catch {
            log.error("STL thumbnail parse failed: \(error.localizedDescription, privacy: .public)")
            handler(nil, error)
        }
    }

    private func renderImageThumbnail(
        image: NSImage,
        request: QLFileThumbnailRequest,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let maxSize = request.maximumSize
        let imageSize = image.size
        let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height, 1.0)
        let thumbnailSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        let reply = QLThumbnailReply(contextSize: thumbnailSize) { () -> Bool in
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
            return true
        }
        handler(reply, nil)
    }

    private func renderSceneThumbnail(
        mesh: MeshData,
        request: QLFileThumbnailRequest,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let scene = SceneBuilder.buildScene(from: mesh)
        let maxSize = request.maximumSize
        let size = CGSize(width: min(maxSize.width, 512), height: min(maxSize.height, 512))

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene

        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling2X)

        // Cache the rendered PNG so subsequent previews skip the parse+render path.
        // Use ImageIO directly (CGImage → CGImageDestination) instead of routing through
        // TIFF + NSBitmapImageRep, which doubles the encode cost for no benefit.
        if let png = pngRepresentation(of: image) {
            ThumbnailCache.store(png, for: request.fileURL)
        }

        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            image.draw(in: CGRect(origin: .zero, size: size))
            return true
        }
        handler(reply, nil)
    }

    private func fileSizeBytes(for url: URL) -> Int64 {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return 0
        }
        return Int64(size)
    }

    /// PNG-encode an `NSImage` via ImageIO (CGImage → CGImageDestination → Data).
    /// Avoids the TIFF intermediate that `NSBitmapImageRep(data: image.tiffRepresentation)` creates.
    private func pngRepresentation(of image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
