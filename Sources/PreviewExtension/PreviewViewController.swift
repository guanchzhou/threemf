import Cocoa
import QuickLookUI
import SceneKit

class PreviewViewController: NSViewController, QLPreviewingController {
    private var fileURL: URL?

    override func loadView() {
        self.view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        fileURL = url
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "3mf":
            prepare3MFPreview(url: url, handler: handler)
        case "stl":
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let mesh = try STLParser.parseMesh(from: url)
                    DispatchQueue.main.async {
                        self.show3DScene(from: mesh)
                        handler(nil)
                    }
                } catch {
                    DispatchQueue.main.async { handler(error) }
                }
            }
        default:
            handler(ThreeMFExtractorError.noThumbnailFound)
        }
    }

    private func prepare3MFPreview(url: URL, handler: @escaping (Error?) -> Void) {
        // Extract thumbnail (fast — small PNG from ZIP)
        let thumbnailImage: NSImage?
        if let imageData = try? ThreeMFExtractor.extractThumbnail(from: url) {
            thumbnailImage = NSImage(data: imageData)
        } else {
            thumbnailImage = nil
        }

        if let image = thumbnailImage {
            // Show thumbnail + "Show 3D" button
            let showUI = {
                self.showImage(image)
                self.showShow3DButton()
                handler(nil)
            }
            if Thread.isMainThread { showUI() }
            else { DispatchQueue.main.async(execute: showUI) }
        } else {
            // No thumbnail — load 3D directly
            DispatchQueue.global(qos: .userInitiated).async {
                if let mesh = try? ThreeMFMeshParser.parseMesh(from: url) {
                    DispatchQueue.main.async {
                        self.show3DScene(from: mesh)
                        handler(nil)
                    }
                } else {
                    DispatchQueue.main.async {
                        handler(ThreeMFExtractorError.noThumbnailFound)
                    }
                }
            }
        }
    }

    // MARK: - "Show 3D" button

    private func showShow3DButton() {
        let button = Show3DButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(show3DButtonTapped)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    @objc private func show3DButtonTapped(_ sender: NSView) {
        guard let url = fileURL else { return }

        // Replace button with progress overlay
        sender.removeFromSuperview()
        let overlay = LoadingOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])

        DispatchQueue.global(qos: .userInitiated).async {
            let progressCallback: (Float) -> Void = { fraction in
                DispatchQueue.main.async {
                    overlay.progress = Double(fraction)
                }
            }
            guard let mesh = try? ThreeMFMeshParser.parseMesh(from: url, progress: progressCallback) else {
                DispatchQueue.main.async { overlay.removeFromSuperview() }
                return
            }
            DispatchQueue.main.async {
                for subview in self.view.subviews {
                    subview.removeFromSuperview()
                }
                self.show3DScene(from: mesh)
            }
        }
    }

    // MARK: - View builders

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

// MARK: - ZoomSCNView

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

// MARK: - Show3DButton

class Show3DButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        title = "Show 3D"
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: NSFont.systemFontSize)
    }
}

// MARK: - LoadingOverlay

class LoadingOverlay: NSView {
    private let progressBar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Loading 3D… 0%")

    var progress: Double = 0 {
        didSet {
            progressBar.doubleValue = progress * 100
            let pct = Int(progress * 100)
            label.stringValue = "Loading 3D… \(pct)%"
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.controlSize = .regular
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(progressBar)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            progressBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 80),

            heightAnchor.constraint(equalToConstant: 28),
        ])
    }
}
