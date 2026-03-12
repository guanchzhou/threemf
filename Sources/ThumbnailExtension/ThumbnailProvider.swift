import AppKit
import QuickLookThumbnailing
import SceneKit

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let ext = request.fileURL.pathExtension.lowercased()

        switch ext {
        case "3mf":
            provideThumbnailFor3MF(request: request, handler: handler)
        case "stl":
            provideThumbnailForSTL(request: request, handler: handler)
        default:
            handler(nil, ThreeMFExtractorError.noThumbnailFound)
        }
    }

    private func provideThumbnailFor3MF(
        request: QLFileThumbnailRequest,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // Try embedded PNG first (fast), fall back to 3D render
        if let imageData = try? ThreeMFExtractor.extractThumbnail(from: request.fileURL),
           let image = NSImage(data: imageData) {
            renderImageThumbnail(image: image, request: request, handler: handler)
        } else if let mesh = try? ThreeMFMeshParser.parseMesh(from: request.fileURL) {
            renderSceneThumbnail(mesh: mesh, request: request, handler: handler)
        } else {
            handler(nil, ThreeMFExtractorError.noThumbnailFound)
        }
    }

    private func provideThumbnailForSTL(
        request: QLFileThumbnailRequest,
        handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let mesh = try STLParser.parseMesh(from: request.fileURL)
            renderSceneThumbnail(mesh: mesh, request: request, handler: handler)
        } catch {
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

        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)

        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            image.draw(in: CGRect(origin: .zero, size: size))
            return true
        }
        handler(reply, nil)
    }
}
