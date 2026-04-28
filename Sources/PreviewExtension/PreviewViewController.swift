import Cocoa
import os
import QuickLookUI
import SceneKit
import simd

private let log = Logger(subsystem: "com.andreymaltsev.3mf-quicklook", category: "preview")

enum PreviewError: Error, LocalizedError {
    case unsupportedFormat
    case meshLoadFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return String(localized: "Unsupported file format")
        case .meshLoadFailed(let underlying):
            return String(
                format: String(localized: "Failed to load mesh: %@"),
                underlying.localizedDescription
            )
        }
    }
}

class PreviewViewController: NSViewController, QLPreviewingController {
    private var fileURL: URL?
    private var fileSizeBytes: Int64 = 0
    private var loadedMesh: MeshData?
    private weak var scnView: ZoomSCNView?
    private weak var hudView: HUDOverlay?
    private var hudUserToggled = false
    private var hudFadeWorkItem: DispatchWorkItem?

    override func loadView() {
        self.view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        fileURL = url
        fileSizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let ext = url.pathExtension.lowercased()
        log.debug("preparePreviewOfFile ext=\(ext, privacy: .public) size=\(self.fileSizeBytes)")

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
                    log.error("STL parse failed: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async {
                        handler(PreviewError.meshLoadFailed(underlying: error))
                    }
                }
            }
        default:
            log.error("Unsupported preview format: \(ext, privacy: .public)")
            handler(PreviewError.unsupportedFormat)
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
            // No thumbnail — load 3D directly. Propagate the real error if it fails.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let mesh = try ThreeMFMeshParser.parseMesh(from: url)
                    DispatchQueue.main.async {
                        self.show3DScene(from: mesh)
                        handler(nil)
                    }
                } catch {
                    log.error("3MF mesh parse failed: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async {
                        handler(PreviewError.meshLoadFailed(underlying: error))
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
            do {
                let mesh = try ThreeMFMeshParser.parseMesh(from: url, progress: progressCallback)
                DispatchQueue.main.async {
                    for subview in self.view.subviews {
                        subview.removeFromSuperview()
                    }
                    self.show3DScene(from: mesh)
                }
            } catch {
                log.error("3MF Show3D parse failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self.replaceOverlayWithError(overlay: overlay, error: error)
                }
            }
        }
    }

    private func replaceOverlayWithError(overlay: NSView, error: Error) {
        overlay.removeFromSuperview()
        let label = NSTextField(labelWithString: String(
            format: String(localized: "Failed to load 3D — %@"),
            error.localizedDescription
        ))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - View builders

    private func show3DScene(from mesh: MeshData) {
        log.debug("show3DScene vertices=\(mesh.vertices.count) tris=\(mesh.indices.count / 3)")
        loadedMesh = mesh
        let scene = SceneBuilder.buildScene(from: mesh)
        let scnView = ZoomSCNView()
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = .windowBackgroundColor
        scnView.antialiasingMode = .multisampling2X
        scnView.defaultCameraController.interactionMode = .orbitTurntable
        scnView.translatesAutoresizingMaskIntoConstraints = false
        scnView.keyDownHandler = { [weak self] event in
            self?.handleSceneKeyDown(event: event) ?? false
        }
        view.addSubview(scnView)
        NSLayoutConstraint.activate([
            scnView.topAnchor.constraint(equalTo: view.topAnchor),
            scnView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scnView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.scnView = scnView

        // HUD overlay — shown on first scene-display, auto-fades after 3s if not toggled.
        let hud = HUDOverlay()
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.update(stats: makeStats(for: mesh))
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
        ])
        hudView = hud

        scheduleHUDAutoFade()

        // Make the SCNView first responder so it receives key events.
        DispatchQueue.main.async { [weak scnView] in
            scnView?.window?.makeFirstResponder(scnView)
        }
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

    // MARK: - HUD

    private func makeStats(for mesh: MeshData) -> HUDStats {
        let triangleCount = mesh.indices.count / 3
        let vertexCount = mesh.vertices.count

        // Bounds in mesh-space units. 3MF/STL conventionally use millimeters.
        var minB = simd_float3(repeating: .greatestFiniteMagnitude)
        var maxB = simd_float3(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices {
            minB = simd_min(minB, v)
            maxB = simd_max(maxB, v)
        }
        let dims: simd_float3
        if mesh.vertices.isEmpty {
            dims = .zero
        } else {
            dims = maxB - minB
        }
        return HUDStats(
            triangleCount: triangleCount,
            vertexCount: vertexCount,
            dimensionsMM: dims,
            fileSize: fileSizeBytes
        )
    }

    private func scheduleHUDAutoFade() {
        hudFadeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.hudUserToggled else { return }
            self.fadeOutHUD()
        }
        hudFadeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    private func fadeOutHUD() {
        guard let hud = hudView else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            hud.animator().alphaValue = 0
        }
    }

    private func fadeInHUD() {
        guard let hud = hudView else { return }
        hud.alphaValue = 0
        hud.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            hud.animator().alphaValue = 1
        }
    }

    private func toggleHUD() {
        guard let hud = hudView else { return }
        hudUserToggled = true
        hudFadeWorkItem?.cancel()
        if hud.alphaValue < 0.5 {
            fadeInHUD()
        } else {
            fadeOutHUD()
        }
    }

    // MARK: - Key handling (called from ZoomSCNView)

    /// Returns true if event was handled.
    fileprivate func handleSceneKeyDown(event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
        let c = chars.lowercased()
        switch c {
        case "i":
            toggleHUD()
            return true
        case "w":
            toggleWireframe()
            return true
        case "1":
            setCameraPreset(.top); return true
        case "2":
            setCameraPreset(.bottom); return true
        case "3":
            setCameraPreset(.front); return true
        case "4":
            setCameraPreset(.back); return true
        case "5":
            setCameraPreset(.left); return true
        case "6":
            setCameraPreset(.right); return true
        default:
            return false
        }
    }

    // MARK: - Wireframe toggle

    private func toggleWireframe() {
        guard let scene = scnView?.scene else { return }
        // Find the first geometry node in the scene (the one added by SceneBuilder).
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let current = geometry.materials.first?.fillMode ?? .fill
            let next: SCNFillMode = (current == .fill) ? .lines : .fill
            for material in geometry.materials {
                material.fillMode = next
            }
        }
        log.debug("wireframe toggled")
    }

    // MARK: - Camera presets

    private enum CameraPreset {
        case top, bottom, front, back, left, right
    }

    private func setCameraPreset(_ preset: CameraPreset) {
        guard let scnView, let cameraNode = scnView.pointOfView else { return }
        // Distance roughly matches SceneBuilder's initial camera (~5 units away from origin).
        let distance: Float = 5.0
        let position: SCNVector3
        // SceneBuilder normalizes the model to ±1 around origin and rotates 3D-print Z-up to Y-up.
        // Presets are expressed in SceneKit's Y-up world-space.
        switch preset {
        case .top:
            position = SCNVector3(0, distance, 0.001)
        case .bottom:
            position = SCNVector3(0, -distance, 0.001)
        case .front:
            position = SCNVector3(0, 0, distance)
        case .back:
            position = SCNVector3(0, 0, -distance)
        case .left:
            position = SCNVector3(-distance, 0, 0)
        case .right:
            position = SCNVector3(distance, 0, 0)
        }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        cameraNode.position = position
        cameraNode.look(at: SCNVector3(0, 0, 0))
        SCNTransaction.commit()
        log.debug("camera preset \(String(describing: preset), privacy: .public)")
    }
}

// MARK: - HUD overlay

struct HUDStats {
    let triangleCount: Int
    let vertexCount: Int
    let dimensionsMM: simd_float3
    let fileSize: Int64
}

final class HUDOverlay: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    func update(stats: HUDStats) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let fileSizeStr = stats.fileSize > 0 ? formatter.string(fromByteCount: stats.fileSize) : "—"

        let dims = stats.dimensionsMM
        let dimsStr = String(
            format: "%.1f \u{00D7} %.1f \u{00D7} %.1f mm",
            dims.x, dims.y, dims.z
        )

        let triLabel = String(localized: "Triangles")
        let vertLabel = String(localized: "Vertices")
        let sizeLabel = String(localized: "Bounds")
        let fileLabel = String(localized: "File")

        label.stringValue = """
        \(triLabel): \(stats.triangleCount.formatted())
        \(vertLabel): \(stats.vertexCount.formatted())
        \(sizeLabel): \(dimsStr)
        \(fileLabel): \(fileSizeStr)
        """
    }
}

// MARK: - ZoomSCNView

/// SCNView subclass: scroll = zoom, right-drag = pan, left-drag = orbit.
/// Also handles keyboard shortcuts for HUD, wireframe, and camera presets.
class ZoomSCNView: SCNView {
    private var isPanning = false
    private var lastPanPoint: NSPoint = .zero

    /// Returns true if the event was consumed.
    var keyDownHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true { return }
        super.keyDown(with: event)
    }

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
        title = String(localized: "Show 3D")
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: NSFont.systemFontSize)
    }
}

// MARK: - LoadingOverlay

class LoadingOverlay: NSView {
    private let progressBar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    var progress: Double = 0 {
        didSet {
            progressBar.doubleValue = progress * 100
            let pct = Int(progress * 100)
            label.stringValue = String(
                format: String(localized: "Loading 3D… %d%%"),
                pct
            )
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

        label.stringValue = String(format: String(localized: "Loading 3D… %d%%"), 0)
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
