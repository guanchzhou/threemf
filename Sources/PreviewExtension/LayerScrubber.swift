import AppKit

/// Compact slider + label pinned at the bottom of the preview to scrub through G-code
/// layers. Calls back with the topmost visible layer index (0-based, inclusive).
final class LayerScrubber: NSVisualEffectView {
    private let slider = NSSlider()
    private let label = NSTextField(labelWithString: "")
    private let layerCount: Int

    var onChange: ((Int) -> Void)?

    init(layerCount: Int) {
        self.layerCount = max(1, layerCount)
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentLayer: Int {
        Int(slider.doubleValue.rounded())
    }

    func setLayer(_ layer: Int) {
        let clamped = max(0, min(layerCount - 1, layer))
        slider.doubleValue = Double(clamped)
        updateLabel()
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

        slider.minValue = 0
        slider.maxValue = Double(max(0, layerCount - 1))
        slider.doubleValue = slider.maxValue
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        updateLabel()

        addSubview(slider)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @objc private func sliderChanged(_: Any?) {
        updateLabel()
        onChange?(currentLayer)
    }

    private func updateLabel() {
        let n = layerCount
        let i = currentLayer + 1
        label.stringValue = String(
            format: String(localized: "Layer %d / %d"),
            i, n
        )
    }
}
