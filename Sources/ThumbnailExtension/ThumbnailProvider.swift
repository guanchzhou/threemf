import AppKit
import QuickLookThumbnailing

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let imageData = try ThreeMFExtractor.extractThumbnail(from: request.fileURL)
            guard let image = NSImage(data: imageData) else {
                handler(nil, ThreeMFExtractorError.noThumbnailFound)
                return
            }

            let maxSize = request.maximumSize
            let imageSize = image.size
            let scale = min(
                maxSize.width / imageSize.width,
                maxSize.height / imageSize.height,
                1.0
            )
            let thumbnailSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )

            let reply = QLThumbnailReply(contextSize: thumbnailSize) { () -> Bool in
                image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
