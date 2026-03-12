import Cocoa
import QuickLookUI
import SceneKit

class PreviewViewController: NSViewController, QLPreviewingController {

    override func loadView() {
        self.view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "3mf":
            if let mesh = try? ThreeMFMeshParser.parseMesh(from: url) {
                show3DScene(from: mesh)
                handler(nil)
            } else {
                do {
                    let imageData = try ThreeMFExtractor.extractThumbnail(from: url)
                    guard let image = NSImage(data: imageData) else {
                        handler(ThreeMFExtractorError.noThumbnailFound)
                        return
                    }
                    showImage(image)
                    handler(nil)
                } catch {
                    handler(error)
                }
            }

        case "stl":
            do {
                let mesh = try STLParser.parseMesh(from: url)
                show3DScene(from: mesh)
                handler(nil)
            } catch {
                handler(error)
            }

        default:
            handler(ThreeMFExtractorError.noThumbnailFound)
        }
    }

    private func show3DScene(from mesh: MeshData) {
        let scene = SceneBuilder.buildScene(from: mesh)
        let scnView = ZoomSCNView()
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = .windowBackgroundColor
        scnView.antialiasingMode = .multisampling4X
        scnView.defaultCameraController.interactionMode = .orbitTurntable
        scnView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scnView)
        NSLayoutConstraint.activate([
            scnView.topAnchor.constraint(equalTo: view.topAnchor),
            scnView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scnView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func showImage(_ image: NSImage) {
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
    }
}

/// SCNView subclass: scroll = zoom, right-drag = pan, left-drag = orbit
class ZoomSCNView: SCNView {
    private var isPanning = false
    private var lastPanPoint: NSPoint = .zero

    override func scrollWheel(with event: NSEvent) {
        guard let camera = pointOfView?.camera else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.2 : 1.0)
        let newFOV = camera.fieldOfView - delta
        camera.fieldOfView = min(max(newFOV, 5), 120)
    }

    override func rightMouseDown(with event: NSEvent) {
        isPanning = true
        lastPanPoint = event.locationInWindow
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isPanning, let cameraNode = pointOfView else { return }
        let current = event.locationInWindow
        let dx = Float(current.x - lastPanPoint.x) * 0.005
        let dy = Float(current.y - lastPanPoint.y) * 0.005
        lastPanPoint = current

        let right = cameraNode.simdWorldRight
        let up = cameraNode.simdWorldUp
        let translation = right * (-dx) + up * (-dy)
        cameraNode.simdWorldPosition += translation
    }

    override func rightMouseUp(with event: NSEvent) {
        isPanning = false
    }
}
