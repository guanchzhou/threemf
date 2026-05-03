import AppKit

/// Static keyboard cheat sheet shown via the `?` overlay.
let keyboardShortcuts: [(key: String, action: String)] = [
    ("i", "Toggle info HUD"),
    ("w", "Wireframe view"),
    ("g", "Print-bed grid"),
    ("a", "XYZ axis gizmo"),
    ("c", "Cycle G-code color mode"),
    ("p", "Play/pause G-code animation"),
    ("1–6", "Camera presets (top/bottom/front/back/left/right)"),
    ("← →", "Cycle plates (Bambu 3MF)"),
    ("↑ ↓", "Step G-code layers"),
    ("?", "Show this help"),
]

/// Centered translucent panel listing all keyboard shortcuts. Click outside dismisses.
final class HelpOverlay: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            material = .windowBackground
            blendingMode = .behindWindow
        } else {
            material = .hudWindow
            blendingMode = .withinWindow
        }
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        let header = String(localized: "Keyboard shortcuts")
        let body = keyboardShortcuts
            .map { "  \($0.key.padding(toLength: 6, withPad: " ", startingAt: 0)) \($0.action)" }
            .joined(separator: "\n")
        label.stringValue = "\(header)\n\(body)"
        setAccessibilityRole(.popover)
        setAccessibilityLabel(header)
    }
}
