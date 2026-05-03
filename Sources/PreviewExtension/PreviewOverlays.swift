import AppKit

/// "Show 3D" push button shown over the embedded thumbnail when the user opts in to a 3D render.
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

/// Determinate progress indicator shown while a 3MF mesh is being parsed and rendered.
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
