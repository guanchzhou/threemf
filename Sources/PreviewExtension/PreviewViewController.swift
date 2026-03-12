import Cocoa
import QuickLookUI

class PreviewViewController: NSViewController, QLPreviewingController {

    override func loadView() {
        self.view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let imageData = try ThreeMFExtractor.extractThumbnail(from: url)
            guard let image = NSImage(data: imageData) else {
                handler(ThreeMFExtractorError.noThumbnailFound)
                return
            }

            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: view.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            handler(nil)
        } catch {
            handler(error)
        }
    }
}
