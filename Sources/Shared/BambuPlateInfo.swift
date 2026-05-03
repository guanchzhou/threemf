import Foundation

/// Subset of fields from Bambu Studio's / OrcaSlicer's per-plate JSON
/// (`Metadata/plate_<N>.json`). Schema is informal and varies between slicer versions;
/// every field is optional and we never throw on missing keys.
public struct BambuPlateInfo: Sendable, Hashable {
    /// Printer model name (e.g. `Bambu Lab P1S`). From `printer_model_id` or `machine_id`.
    public let machineId: String?
    /// Total filament weight across all extruders, in grams. Sum of `filament_used_g` array
    /// when present, else nil.
    public let totalFilamentGrams: Double?
    /// Estimated print time in seconds. From `prediction` (Bambu) when present.
    public let predictionSeconds: Int?
    /// Display title from `title`, when present.
    public let title: String?

    public init(
        machineId: String? = nil,
        totalFilamentGrams: Double? = nil,
        predictionSeconds: Int? = nil,
        title: String? = nil
    ) {
        self.machineId = machineId
        self.totalFilamentGrams = totalFilamentGrams
        self.predictionSeconds = predictionSeconds
        self.title = title
    }

    public var isEmpty: Bool {
        machineId == nil && totalFilamentGrams == nil && predictionSeconds == nil && title == nil
    }

    /// Parses `Metadata/plate_<N>.json` bytes. Returns nil if the JSON is malformed.
    /// Tolerant of missing fields — every output property is optional.
    public static func parse(_ data: Data) -> BambuPlateInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let machine = (object["printer_model_id"] as? String) ?? (object["machine_id"] as? String)
        let title = object["title"] as? String

        var weight: Double?
        if let used = object["filament_used_g"] as? [Double] {
            weight = used.reduce(0, +)
        } else if let total = object["weight"] as? Double {
            weight = total
        }

        var prediction: Int?
        if let p = object["prediction"] as? Int {
            prediction = p
        } else if let p = object["prediction"] as? Double {
            prediction = Int(p)
        }

        let info = BambuPlateInfo(
            machineId: machine,
            totalFilamentGrams: weight,
            predictionSeconds: prediction,
            title: title
        )
        return info.isEmpty ? nil : info
    }
}
