import AppKit
import SceneKit

/// SCNView subclass: scroll = zoom (FOV), right-drag = pan, left-drag = orbit.
/// Forwards keyDown to a callback so the controller handles HUD/wireframe/preset shortcuts.
class ZoomSCNView: SCNView {
    private var isPanning = false
    private var lastPanPoint: NSPoint = .zero

    /// Returns true if the event was consumed.
    var keyDownHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

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
        let translation = right * -dx + up * -dy
        cameraNode.simdWorldPosition += translation
    }

    override func rightMouseUp(with _: NSEvent) {
        isPanning = false
    }
}

/// Plain NSView that can become first responder and forwards keyDown to a callback.
/// Used as the controller's root view so `?` and arrow keys are captured even before
/// the SCNView (which is the usual key target) has been added.
final class KeyableView: NSView {
    var keyDownHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Only become first responder if nothing else has claimed it. Some Quick Look
        // chrome (search fields, etc.) may legitimately want focus; we don't steal it.
        guard let window else { return }
        let current = window.firstResponder
        if current == nil || current === window {
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}
