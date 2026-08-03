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
            String(localized: "Unsupported file format")
        case let .meshLoadFailed(underlying):
            String(
                format: String(localized: "Failed to load mesh: %@"),
                underlying.localizedDescription
            )
        }
    }
}

@MainActor
class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    /// File-size threshold below which we skip the embedded-thumbnail path entirely
    /// and load the 3D scene directly. Small 3MFs parse in well under a second.
    private static let autoLoad3DSizeThreshold: Int64 = 2 * 1024 * 1024 // 2 MB

    private var fileURL: URL?
    private var fileSizeBytes: Int64 = 0
    private var loadedMesh: MeshData?
    private var loadedToolpath: ToolpathData?
    private weak var scnView: ZoomSCNView?
    private weak var hudView: HUDOverlay?
    private weak var helpView: HelpOverlay?
    /// Embedded plate thumbnails (Bambu/Orca 3MFs). Empty for non-plate files.
    private var plates: [ThreeMFExtractor.PlateThumbnail] = []
    private var currentPlateIndex: Int = 0
    /// Geometry-level plates for the active 3D scene (multi-plate Bambu/Orca 3MFs). Drives
    /// plate switching in 3D mode, distinct from the PNG-thumbnail `plates` used pre-load.
    private var meshPlates: [PlateInfo] = []
    private weak var plateImageView: NSImageView?
    private weak var plateLabel: NSTextField?
    /// Visible scene helpers (toggleable).
    private var axisGizmoNode: SCNNode?
    private var bedGridNode: SCNNode?
    /// G-code-specific scene state.
    private weak var toolpathModelNode: SCNNode?
    private weak var layerScrubber: LayerScrubber?
    private var animationTask: Task<Void, Never>?
    private var toolpathColorMode: ToolpathSceneBuilder.ColorMode = .layerRainbow

    override func loadView() {
        let v = KeyableView()
        v.keyDownHandler = { [weak self] event in
            self?.handleRootKeyDown(event: event) ?? false
        }
        self.view = v
    }

    /// Returns true if the event was handled. Used by both KeyableView (thumbnail mode)
    /// and ZoomSCNView (3D mode) so the same shortcuts work in both views.
    fileprivate func handleRootKeyDown(event: NSEvent) -> Bool {
        // Plate-cycling arrow keys work whenever plates are loaded, regardless of mode.
        let key = Int(event.keyCode)
        if key == 123 {
            cyclePlate(-1); return true
        } // left arrow
        if key == 124 {
            cyclePlate(+1); return true
        } // right arrow
        // Layer-stepping arrow keys (G-code mode). No-op outside G-code preview.
        if key == 126 {
            stepLayer(+1); return layerScrubber != nil
        } // up arrow
        if key == 125 {
            stepLayer(-1); return layerScrubber != nil
        } // down arrow

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
        switch chars.lowercased() {
        case "?": toggleHelp(); return true
        case "p":
            if layerScrubber != nil {
                toggleToolpathAnimation()
                return true
            }
            return false
        default: return false
        }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        fileURL = url
        fileSizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let ext = url.pathExtension.lowercased()
        log.debug("preparePreviewOfFile ext=\(ext, privacy: .public) size=\(self.fileSizeBytes)")

        // QuickLook gives us a non-Sendable completion handler. We always invoke it
        // exactly once from the main queue, so it's safe to ship across concurrency
        // domains via nonisolated(unsafe).
        nonisolated(unsafe) let h = handler

        switch ext {
        case "3mf":
            prepare3MFPreview(url: url, handler: handler)
        case "stl":
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let mesh = try STLParser.parseMesh(from: url)
                    DispatchQueue.main.async {
                        self.show3DScene(from: mesh)
                        h(nil)
                    }
                } catch {
                    log.error("STL parse failed: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async {
                        h(PreviewError.meshLoadFailed(underlying: error))
                    }
                }
            }
        case "gcode":
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let toolpath = try GCodeParser.parse(from: url)
                    DispatchQueue.main.async {
                        self.showToolpathScene(from: toolpath)
                        h(nil)
                    }
                } catch {
                    log.error("G-code parse failed: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async {
                        h(PreviewError.meshLoadFailed(underlying: error))
                    }
                }
            }
        default:
            log.error("Unsupported preview format: \(ext, privacy: .public)")
            handler(PreviewError.unsupportedFormat)
        }
    }

    /// Renders a G-code toolpath in the SCNView. Mirrors `show3DScene` but uses
    /// `ToolpathSceneBuilder` and skips mesh-only HUD stats.
    private func showToolpathScene(from toolpath: ToolpathData) {
        log.debug("showToolpathScene segments=\(toolpath.segments.count) layers=\(toolpath.layerCount)")
        loadedToolpath = toolpath
        let scene = ToolpathSceneBuilder.buildScene(from: toolpath)
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
        toolpathModelNode = scene.rootNode.childNode(withName: "toolpath", recursively: false)

        // HUD shared with mesh previews — populated with toolpath-specific lines.
        let hud = HUDOverlay()
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.update(toolpathStats: makeToolpathStats(for: toolpath))
        hud.onClose = { [weak self] in self?.toggleHUD() }
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
        ])
        hudView = hud

        addHelpBadge()

        // Layer scrubber pinned to the bottom for multi-layer toolpaths.
        if toolpath.layerCount > 1 {
            let scrubber = LayerScrubber(layerCount: toolpath.layerCount)
            scrubber.translatesAutoresizingMaskIntoConstraints = false
            scrubber.setLayer(toolpath.layerCount - 1)
            scrubber.onChange = { [weak self] layer in
                self?.setVisibleToolpathLayers(through: layer)
            }
            view.addSubview(scrubber)
            NSLayoutConstraint.activate([
                scrubber.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
                scrubber.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
                scrubber.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            ])
            layerScrubber = scrubber
        }

        DispatchQueue.main.async { [weak scnView] in
            scnView?.window?.makeFirstResponder(scnView)
        }
    }

    /// Re-emits the toolpath geometry to show only segments in `0...layer`.
    private func setVisibleToolpathLayers(through layer: Int) {
        guard let toolpath = loadedToolpath, let node = toolpathModelNode else { return }
        let geometry = ToolpathSceneBuilder.makeGeometry(
            toolpath: toolpath,
            colorMode: toolpathColorMode,
            visibleLayers: 0 ... max(0, layer)
        )
        node.geometry = geometry
    }

    /// Cycles the toolpath color mode (`c` key). Re-emits geometry with the new colors.
    private func cycleToolpathColorMode() {
        guard let toolpath = loadedToolpath, let node = toolpathModelNode else { return }
        let order: [ToolpathSceneBuilder.ColorMode] = [
            .layerRainbow, .travelVsExtrusion, .feedrate, .uniform,
        ]
        let nextIndex = (order.firstIndex(of: toolpathColorMode) ?? 0) + 1
        toolpathColorMode = order[nextIndex % order.count]
        let visible: ClosedRange<Int>? = layerScrubber.map { 0 ... $0.currentLayer }
        let geometry = ToolpathSceneBuilder.makeGeometry(
            toolpath: toolpath,
            colorMode: toolpathColorMode,
            visibleLayers: visible
        )
        node.geometry = geometry
        // Refresh the HUD label so the new mode appears under "Color Mode".
        if let hud = hudView {
            hud.update(toolpathStats: makeToolpathStats(for: toolpath))
        }
    }

    private func makeToolpathStats(for toolpath: ToolpathData) -> ToolpathHUDStats {
        let modeLabel = switch toolpathColorMode {
        case .layerRainbow: String(localized: "Layer rainbow")
        case .travelVsExtrusion: String(localized: "Travel vs extrusion")
        case .feedrate: String(localized: "Feedrate heatmap")
        case .uniform: String(localized: "Uniform")
        }
        return ToolpathHUDStats(
            segmentCount: toolpath.segments.count,
            layerCount: toolpath.layerCount,
            totalExtrudedMM: toolpath.totalExtrudedMM,
            totalTravelMM: toolpath.totalTravelMM,
            estimatedSeconds: toolpath.estimatedSeconds,
            dimensionsMM: toolpath.boundingBox.dimensions,
            fileSize: fileSizeBytes,
            colorMode: modeLabel
        )
    }

    /// Steps the layer scrubber by `delta`. No-op if no scrubber is present (STL/3MF preview).
    private func stepLayer(_ delta: Int) {
        guard let scrubber = layerScrubber else { return }
        let next = scrubber.currentLayer + delta
        scrubber.setLayer(next)
        setVisibleToolpathLayers(through: scrubber.currentLayer)
    }

    /// Toggles an animation that sweeps the scrubber from layer 0 to top over ~3 seconds.
    /// Uses a MainActor Task with `Task.sleep` instead of Timer so the per-tick closure
    /// is naturally main-actor-isolated under Swift 6 strict concurrency.
    private func toggleToolpathAnimation() {
        if let task = animationTask {
            task.cancel()
            animationTask = nil
            return
        }
        guard let scrubber = layerScrubber, let toolpath = loadedToolpath else { return }
        let total = toolpath.layerCount
        guard total > 1 else { return }
        scrubber.setLayer(0)
        setVisibleToolpathLayers(through: 0)
        let stepSize = max(1, total / 90)

        animationTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled,
                  let scrubber = self.layerScrubber,
                  scrubber.currentLayer < total - 1
            {
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 fps
                if Task.isCancelled {
                    break
                }
                let next = min(total - 1, scrubber.currentLayer + stepSize)
                scrubber.setLayer(next)
                self.setVisibleToolpathLayers(through: next)
            }
            self?.animationTask = nil
        }
    }

    private func prepare3MFPreview(url: URL, handler: @escaping (Error?) -> Void) {
        // Same Sendable opt-out as preparePreviewOfFile — handler is always called from main.
        nonisolated(unsafe) let h = handler

        // For small 3MFs, parsing the full mesh is fast enough that the embedded-thumbnail
        // detour is unnecessary friction. Load 3D directly.
        if fileSizeBytes > 0, fileSizeBytes < Self.autoLoad3DSizeThreshold {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let mesh = try ThreeMFMeshParser.parseMesh(from: url)
                    DispatchQueue.main.async {
                        self.show3DScene(from: mesh)
                        h(nil)
                    }
                } catch {
                    log.error("Auto-load 3MF parse failed: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async {
                        h(PreviewError.meshLoadFailed(underlying: error))
                    }
                }
            }
            return
        }

        // Larger files: enumerate plates (Bambu/Orca 3MFs) so the user can cycle through
        // them with arrow keys before paying the cost of full 3D mesh parsing. Lazy: the
        // refs are cheap (paths only); PNG bytes are extracted on demand.
        plates = ThreeMFExtractor.listPlates(from: url)
        currentPlateIndex = 0

        // Fall back to the legacy single-thumbnail extractor when no plates were found.
        let firstImage: NSImage? = if !plates.isEmpty,
                                      let data = try? ThreeMFExtractor.extractPlate(plates[0], from: url),
                                      let img = NSImage(data: data)
        {
            img
        } else if let imageData = try? ThreeMFExtractor.extractThumbnail(from: url) {
            NSImage(data: imageData)
        } else {
            nil
        }

        if let image = firstImage {
            // Show thumbnail + "Show 3D" button. Already on main (QuickLook invokes us on main).
            showImage(image)
            if plates.count > 1 {
                showPlateLabel()
                // Quick Look chrome usually owns first responder by the time we get here,
                // so the root view's opportunistic claim in viewDidMoveToWindow doesn't fire.
                // Force it now so the ← → arrow keys actually reach our keyDownHandler.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.view.window?.makeFirstResponder(self.view)
                }
            }
            showShow3DButton()
            handler(nil)
        } else {
            // No thumbnail at all — fall back to direct 3D load.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let mesh = try ThreeMFMeshParser.parseMesh(from: url)
                    DispatchQueue.main.async {
                        self.show3DScene(from: mesh)
                        h(nil)
                    }
                } catch {
                    log.error("3MF mesh parse failed: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async {
                        h(PreviewError.meshLoadFailed(underlying: error))
                    }
                }
            }
        }
    }

    // MARK: - Plate cycling

    private func showPlateLabel() {
        let prev = makePlateChevron(symbol: "‹", action: #selector(plateChevronPrev))
        let next = makePlateChevron(symbol: "›", action: #selector(plateChevronNext))

        let label = NSTextField(labelWithString: plateLabelText())
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [prev, label, next])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
        plateLabel = label
    }

    private func makePlateChevron(symbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = symbol
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.setButtonType(.momentaryChange)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func plateChevronPrev() {
        cyclePlate(-1)
    }

    @objc private func plateChevronNext() {
        cyclePlate(+1)
    }

    private func plateLabelText() -> String {
        // 3D mode labels with the geometry plates (and their names); thumbnail mode counts PNGs.
        if scnView != nil, meshPlates.count > 1 {
            let base = String(
                format: String(localized: "Plate %d / %d"),
                currentPlateIndex + 1, meshPlates.count
            )
            let name = meshPlates[safe: currentPlateIndex]?.name ?? ""
            return name.isEmpty ? base : "\(base) · \(name)"
        }
        let n = plates.count
        let i = currentPlateIndex + 1
        return String(
            format: String(localized: "Plate %d / %d"),
            i, n
        )
    }

    private func cyclePlate(_ direction: Int) {
        // 3D mode: rebuild the scene for the newly-selected plate.
        if scnView != nil, meshPlates.count > 1 {
            currentPlateIndex = (currentPlateIndex + direction + meshPlates.count) % meshPlates.count
            rebuildPlateScene()
            plateLabel?.stringValue = plateLabelText()
            return
        }
        // 2D thumbnail mode: swap the embedded plate PNG.
        guard plates.count > 1, let url = fileURL else { return }
        let next = (currentPlateIndex + direction + plates.count) % plates.count
        currentPlateIndex = next
        if let imageView = plateImageView,
           let data = try? ThreeMFExtractor.extractPlate(plates[next], from: url),
           let image = NSImage(data: data)
        {
            imageView.image = image
        }
        plateLabel?.stringValue = plateLabelText()
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
        meshPlates = mesh.plates
        currentPlateIndex = 0
        // Multi-plate Bambu/Orca files render one plate at a time (default: plate 1).
        let displayMesh = meshPlates.count > 1 ? mesh.submesh(plateIndex: 0) : mesh
        let scene = SceneBuilder.buildScene(from: displayMesh)
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

        // HUD overlay — pinned (no auto-fade). Dismissable via `i`, `?` overlay, or its × button.
        let hud = HUDOverlay()
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.update(stats: makeStats(for: displayMesh))
        hud.onClose = { [weak self] in self?.toggleHUD() }
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
        ])
        hudView = hud

        addHelpBadge()

        // Multi-plate file: show the plate label + chevrons so ← → cycling is discoverable.
        if meshPlates.count > 1 {
            showPlateLabel()
        }

        // Make the SCNView first responder so it receives key events.
        DispatchQueue.main.async { [weak scnView] in
            scnView?.window?.makeFirstResponder(scnView)
        }
    }

    /// Rebuilds the active 3D scene to show `currentPlateIndex`'s geometry, reframing to it.
    /// Used when cycling plates in 3D mode.
    private func rebuildPlateScene() {
        guard let mesh = loadedMesh, let scnView, meshPlates.count > 1 else { return }
        let displayMesh = mesh.submesh(plateIndex: currentPlateIndex)
        let scene = SceneBuilder.buildScene(from: displayMesh)
        scnView.scene = scene
        if let cam = scene.rootNode.childNode(withName: "camera", recursively: true) {
            scnView.pointOfView = cam
        }
        // The scene was replaced — the optional axis/grid helpers are gone with it; clear the
        // references so their toggle state stays consistent (treated as off until re-toggled).
        axisGizmoNode = nil
        bedGridNode = nil
        hudView?.update(stats: makeStats(for: displayMesh))
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
        plateImageView = imageView
    }

    // MARK: - HUD

    private func makeStats(for mesh: MeshData) -> HUDStats {
        // Single-walk bbox+volume — avoids two O(N) passes over `vertices`.
        let stats = mesh.statistics()
        // Bambu/Orca plate JSON keyed by the currently-selected plate index (1-based).
        // Always falls back to nil when not a Bambu file or JSON missing.
        let plateInfo: BambuPlateInfo? = if let url = fileURL,
                                            !plates.isEmpty,
                                            let idx = plates[safe: currentPlateIndex]?.index
        {
            ThreeMFExtractor.extractPlateInfo(plateIndex: idx, from: url)
        } else {
            nil
        }
        return HUDStats(
            triangleCount: mesh.indices.count / 3,
            vertexCount: mesh.vertices.count,
            dimensionsMM: stats.boundingBox.dimensions,
            volumeMM3: stats.volume,
            fileSize: fileSizeBytes,
            metadata: mesh.metadata,
            bambuPlate: plateInfo,
            materials: mesh.materials
        )
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
        if hud.alphaValue < 0.5 {
            fadeInHUD()
        } else {
            fadeOutHUD()
        }
    }

    // MARK: - Key handling (called from ZoomSCNView)

    /// Returns true if event was handled. Called from ZoomSCNView when a 3D scene is showing.
    fileprivate func handleSceneKeyDown(event: NSEvent) -> Bool {
        // Shared root shortcuts (?, arrows) take precedence so they work in 3D mode too.
        if handleRootKeyDown(event: event) {
            return true
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
        let c = chars.lowercased()
        switch c {
        case "i": toggleHUD(); return true
        case "w": toggleWireframe(); return true
        case "g": toggleBedGrid(); return true
        case "a": toggleAxisGizmo(); return true
        case "c":
            if loadedToolpath != nil {
                cycleToolpathColorMode()
                return true
            }
            return false
        case "1": setCameraPreset(.top); return true
        case "2": setCameraPreset(.bottom); return true
        case "3": setCameraPreset(.front); return true
        case "4": setCameraPreset(.back); return true
        case "5": setCameraPreset(.left); return true
        case "6": setCameraPreset(.right); return true
        default: return false
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
                // Wireframe over Phong is hard to read against dark backgrounds —
                // switch to constant lighting so lines render at full diffuse color
                // regardless of normal/light geometry. Restore on toggle off.
                material.lightingModel = (next == .lines) ? .constant : .phong
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
        let position
            // SceneBuilder normalizes the model to ±1 around origin and rotates 3D-print Z-up to Y-up.
            // Presets are expressed in SceneKit's Y-up world-space.
            = switch preset
        {
        case .top:
            SCNVector3(0, distance, 0.001)
        case .bottom:
            SCNVector3(0, -distance, 0.001)
        case .front:
            SCNVector3(0, 0, distance)
        case .back:
            SCNVector3(0, 0, -distance)
        case .left:
            SCNVector3(-distance, 0, 0)
        case .right:
            SCNVector3(distance, 0, 0)
        }

        // Respect "Reduce motion" — snap instead of animating.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        SCNTransaction.begin()
        SCNTransaction.animationDuration = reduceMotion ? 0 : 0.4
        cameraNode.position = position
        cameraNode.look(at: SCNVector3(0, 0, 0))
        SCNTransaction.commit()
        log.debug("camera preset \(String(describing: preset), privacy: .public)")
    }

    // MARK: - Toggleable scene helpers and help overlay

    /// Circular "?" badge anchored top-right of the scene. Toggles the keyboard cheat sheet
    /// for users who don't know the `?` shortcut.
    private func addHelpBadge() {
        let button = NSButton()
        button.title = "?"
        button.bezelStyle = .circular
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        button.target = self
        button.action = #selector(helpBadgeTapped)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = String(localized: "Keyboard shortcuts")
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            button.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @objc private func helpBadgeTapped() {
        toggleHelp()
    }

    private func toggleHelp() {
        if let existing = helpView {
            existing.removeFromSuperview()
            helpView = nil
            return
        }
        let help = HelpOverlay()
        help.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(help)
        NSLayoutConstraint.activate([
            help.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            help.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        // Click anywhere outside the overlay dismisses it. The overlay's own click is
        // swallowed by adding the recognizer to the parent view; clicks that hit the
        // overlay propagate up to it (which doesn't handle clicks → falls through to us).
        // Filter by hit-test inside the action to ignore clicks on the overlay itself.
        let click = NSClickGestureRecognizer(target: self, action: #selector(dismissHelpIfOutside(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        help.addGestureRecognizer(NSClickGestureRecognizer()) // swallow clicks on the overlay
        view.addGestureRecognizer(click)
        helpView = help
    }

    @objc private func dismissHelpIfOutside(_ recognizer: NSClickGestureRecognizer) {
        guard let help = helpView else { return }
        let point = recognizer.location(in: help)
        // If the click landed inside the overlay, ignore — the overlay has its own
        // recognizer that swallowed it. Otherwise dismiss.
        if !help.bounds.contains(point) {
            help.removeFromSuperview()
            helpView = nil
            view.removeGestureRecognizer(recognizer)
        }
    }

    private func toggleAxisGizmo() {
        if let existing = axisGizmoNode {
            existing.removeFromParentNode()
            axisGizmoNode = nil
            return
        }
        guard let scene = scnView?.scene else { return }
        let node = SceneBuilder.makeAxisGizmoNode()
        // Pin to lower-right corner regardless of camera orbit by attaching to camera.
        if let camera = scene.rootNode.childNode(withName: "camera", recursively: true) {
            node.position = SCNVector3(0.7, -0.55, -2)
            camera.addChildNode(node)
        } else {
            scene.rootNode.addChildNode(node)
        }
        axisGizmoNode = node
    }

    private func toggleBedGrid() {
        if let existing = bedGridNode {
            existing.removeFromParentNode()
            bedGridNode = nil
            return
        }
        guard let scene = scnView?.scene else { return }
        let node = SceneBuilder.makeBedGridNode()
        scene.rootNode.addChildNode(node)
        bedGridNode = node
    }
}

// HUDStats, HUDOverlay → HUDOverlay.swift
// keyboardShortcuts, HelpOverlay → HelpOverlay.swift
// ZoomSCNView, KeyableView → SceneInteractionViews.swift
// Show3DButton, LoadingOverlay → PreviewOverlays.swift

private extension Array {
    /// Returns the element at `index` if it's in bounds, else `nil`.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
