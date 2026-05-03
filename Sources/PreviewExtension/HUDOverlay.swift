import AppKit
import simd

/// Stats rendered in the info HUD overlay.
struct HUDStats {
    let triangleCount: Int
    let vertexCount: Int
    let dimensionsMM: simd_float3
    /// Mesh volume in mm³ (assuming 3D-print convention).
    let volumeMM3: Float
    let fileSize: Int64
    /// Optional 3MF metadata. `nil` for STL.
    let metadata: ThreeMFMetadata?
    /// Optional Bambu/Orca plate JSON (filament weight, print time, machine).
    let bambuPlate: BambuPlateInfo?
    /// Multi-material list (3MF `<basematerials>`). Empty for single-material / STL.
    let materials: [BaseMaterial]
}

/// Stats for a G-code preview. Distinct from `HUDStats` because the available
/// numbers (segments / layers / extruded mm / travel mm / time) don't overlap
/// with mesh stats (triangles / vertices / volume).
struct ToolpathHUDStats {
    let segmentCount: Int
    let layerCount: Int
    let totalExtrudedMM: Float
    let totalTravelMM: Float
    let estimatedSeconds: Double
    let dimensionsMM: simd_float3
    let fileSize: Int64
    let colorMode: String
}

/// Translucent panel showing triangle/vertex/bbox/volume/file/metadata. Toggleable via `i`.
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
        // Respect "Reduce transparency" — render a solid panel instead of the vibrancy effect.
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

        // Volume in cm³ for human readability (1 cm³ = 1 ml). 3D-printed parts are
        // typically 1–500 cm³; mm³ is too granular and m³ is absurd for hobby printing.
        let volumeCM3 = stats.volumeMM3 / 1000.0
        let volumeStr = volumeCM3 > 0 ? String(format: "%.1f cm³", volumeCM3) : "—"

        var lines = [
            "\(String(localized: "Triangles")): \(stats.triangleCount.formatted())",
            "\(String(localized: "Vertices")): \(stats.vertexCount.formatted())",
            "\(String(localized: "Bounds")): \(dimsStr)",
            "\(String(localized: "Volume")): \(volumeStr)",
            "\(String(localized: "File")): \(fileSizeStr)",
        ]

        // Append 3MF metadata when available.
        if let md = stats.metadata {
            if let app = md.application { lines.append("\(String(localized: "Slicer")): \(app)") }
            if let title = md.title { lines.append("\(String(localized: "Title")): \(title)") }
            if let designer = md.designer { lines.append("\(String(localized: "Designer")): \(designer)") }
            if let date = md.creationDate { lines.append("\(String(localized: "Created")): \(date)") }
        }

        // Bambu/Orca plate JSON: filament weight, print time, machine.
        if let bp = stats.bambuPlate {
            if let machine = bp.machineId { lines.append("\(String(localized: "Printer")): \(machine)") }
            if let g = bp
                .totalFilamentGrams { lines.append("\(String(localized: "Filament")): \(String(format: "%.1f g", g))") }
            if let s = bp.predictionSeconds {
                let h = s / 3600
                let m = (s % 3600) / 60
                let timeStr = h > 0 ? "\(h)h \(m)m" : "\(m)m"
                lines.append("\(String(localized: "Print Time")): \(timeStr)")
            }
        }

        // Multi-material list with hex color codes (3MF `<basematerials>`).
        if !stats.materials.isEmpty {
            lines.append("\(String(localized: "Materials")): \(stats.materials.count)")
            for mat in stats.materials.prefix(8) {
                let hex = mat.color.map { c in
                    let r = Int((c.x * 255).rounded())
                    let g = Int((c.y * 255).rounded())
                    let b = Int((c.z * 255).rounded())
                    return String(format: "#%02X%02X%02X", r, g, b)
                } ?? "—"
                let name = mat.name.isEmpty ? "(unnamed)" : mat.name
                lines.append("  \(hex)  \(name)")
            }
            if stats.materials.count > 8 {
                lines.append("  …and \(stats.materials.count - 8) more")
            }
        }

        label.stringValue = lines.joined(separator: "\n")
    }

    /// Renders G-code stats in the same panel.
    func update(toolpathStats stats: ToolpathHUDStats) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let fileSizeStr = stats.fileSize > 0 ? formatter.string(fromByteCount: stats.fileSize) : "—"

        let dims = stats.dimensionsMM
        let dimsStr = String(
            format: "%.1f \u{00D7} %.1f \u{00D7} %.1f mm",
            dims.x, dims.y, dims.z
        )

        let etaSeconds = Int(stats.estimatedSeconds.rounded())
        let etaStr = if etaSeconds <= 0 {
            "—"
        } else {
            String(format: "%dh %02dm %02ds", etaSeconds / 3600, (etaSeconds % 3600) / 60, etaSeconds % 60)
        }

        let lines = [
            "\(String(localized: "Layers")): \(stats.layerCount.formatted())",
            "\(String(localized: "Segments")): \(stats.segmentCount.formatted())",
            "\(String(localized: "Extruded")): \(String(format: "%.1f mm", stats.totalExtrudedMM))",
            "\(String(localized: "Travel")): \(String(format: "%.1f mm", stats.totalTravelMM))",
            "\(String(localized: "Bounds")): \(dimsStr)",
            "\(String(localized: "Print Time")): \(etaStr)",
            "\(String(localized: "Color Mode")): \(stats.colorMode)",
            "\(String(localized: "File")): \(fileSizeStr)",
        ]
        label.stringValue = lines.joined(separator: "\n")
    }
}
