import Foundation
import simd

/// Bambu Studio / OrcaSlicer per-project configuration that lives **outside** the model XML:
/// `Metadata/model_settings.config` (plate ↔ object layout, per-object extruder assignment)
/// and `Metadata/project_settings.config` (the `filament_colour` palette).
///
/// These files carry the multi-color/plate intent for Bambu 3MFs, which do **not** use
/// core-spec `<basematerials displaycolor>` or per-triangle paint. Color is assigned
/// per object via an extruder index that maps into the filament palette.
///
/// Parsing is pure (`Data` in, value out) and tolerant: missing files, missing keys, or
/// malformed content yield an empty/partial config, never a throw.
public struct BambuModelConfig: Sendable, Hashable {
    /// One print plate, in `plater_id` order.
    public struct ResolvedPlate: Sendable, Hashable {
        /// 1-based `plater_id`.
        public let id: Int
        /// `plater_name` (e.g. "Body and Head"). May be empty.
        public let name: String
        /// Object ids (matching 3MF `<object id>` / build-item `objectid`) placed on this plate.
        public let objectIds: [String]

        public init(id: Int, name: String, objectIds: [String]) {
            self.id = id
            self.name = name
            self.objectIds = objectIds
        }
    }

    /// Plates in display order (sorted by `plater_id`). Empty for single-plate / non-Bambu files.
    public let plates: [ResolvedPlate]
    /// Object id → 1-based extruder index (from `<metadata key="extruder">`).
    public let objectExtruder: [String: Int]
    /// Filament palette in extruder order (index 0 = extruder 1). RGBA in 0...1.
    public let filamentColours: [SIMD4<Float>]

    public init(
        plates: [ResolvedPlate] = [],
        objectExtruder: [String: Int] = [:],
        filamentColours: [SIMD4<Float>] = []
    ) {
        self.plates = plates
        self.objectExtruder = objectExtruder
        self.filamentColours = filamentColours
    }

    public var isEmpty: Bool {
        plates.isEmpty && objectExtruder.isEmpty && filamentColours.isEmpty
    }

    // MARK: - Resolved lookups for the mesh pipeline

    /// Object id → 0-based index into `plates`. Empty when there are no plates.
    public var objectPlateIndex: [String: Int] {
        var map: [String: Int] = [:]
        for (idx, plate) in plates.enumerated() {
            for oid in plate.objectIds { map[oid] = idx }
        }
        return map
    }

    /// Materials derived from the filament palette, one per filament, in extruder order.
    /// Index `i` corresponds to extruder `i + 1`. Empty when no palette is present.
    public func materials() -> [BaseMaterial] {
        filamentColours.enumerated().map { idx, colour in
            BaseMaterial(name: "Filament \(idx + 1)", color: colour)
        }
    }

    /// True when there's enough information to color the mesh by object (a palette plus at
    /// least one object→extruder assignment).
    public var hasColorAssignment: Bool {
        !filamentColours.isEmpty && !objectExtruder.isEmpty
    }

    /// Object id → 0-based material index (extruder − 1), clamped to the palette range.
    /// Objects with no extruder, or an out-of-range one, are omitted (caller uses -1/default).
    public var objectMaterialIndex: [String: Int] {
        var map: [String: Int] = [:]
        for (oid, extruder) in objectExtruder {
            let matIdx = extruder - 1
            if matIdx >= 0, matIdx < filamentColours.count {
                map[oid] = matIdx
            }
        }
        return map
    }

    // MARK: - Parsing

    /// Parses the two Bambu config files. Either may be `nil` (absent from the archive).
    public static func parse(modelSettings: Data?, projectSettings: Data?) -> BambuModelConfig {
        let (plates, extruders) = parseModelSettings(modelSettings)
        let colours = parseFilamentColours(projectSettings)
        return BambuModelConfig(plates: plates, objectExtruder: extruders, filamentColours: colours)
    }

    /// Parses `model_settings.config` (XML) into plates and object→extruder assignments.
    private static func parseModelSettings(_ data: Data?) -> ([ResolvedPlate], [String: Int]) {
        guard let data, !data.isEmpty else { return ([], [:]) }
        let delegate = ModelSettingsDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return ([], [:]) }
        // Plates sorted by id so display order is deterministic and matches plater_id.
        let plates = delegate.plates
            .map { ResolvedPlate(id: $0.id, name: $0.name, objectIds: $0.objectIds) }
            .sorted { $0.id < $1.id }
        return (plates, delegate.objectExtruder)
    }

    /// Parses `filament_colour` from `project_settings.config` (JSON). The value is an array
    /// of hex strings like `"#RRGGBB"` / `"#RRGGBBAA"`.
    private static func parseFilamentColours(_ data: Data?) -> [SIMD4<Float>] {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["filament_colour"] as? [String]
        else { return [] }
        return raw.map { parseHexColor($0) ?? SIMD4<Float>(0.85, 0.85, 0.85, 1) }
    }

    /// Decodes a Bambu/PrusaSlicer `paint_color` (a.k.a. `mmu_segmentation`) hex string into
    /// the dominant **extruder index (1-based)** painted on the triangle, or `0` for none/base.
    ///
    /// Format (see brain `3mf-paint-color-encoding`): the hex is a little-endian bitstream —
    /// process hex chars right-to-left, each nibble LSB-first. Per triangle: 2 bits = number of
    /// split sides (0 = leaf); a leaf then has 2 bits `sc` (`<3` → state, `==3` → 4-bit extended
    /// `3+e`, `e==14` → 8-bit extended `17+v`). A split triangle has 2 bits `special_side` then
    /// `nss+1` recursive children; we collect leaf states and return the most common painted one.
    static func decodePaintColor(_ hex: String) -> Int {
        guard !hex.isEmpty else { return 0 }
        var bits: [Bool] = []
        bits.reserveCapacity(hex.count * 4)
        for ch in hex.reversed() {
            guard let v = ch.hexDigitValue else { return 0 }
            bits.append(v & 1 != 0)
            bits.append(v & 2 != 0)
            bits.append(v & 4 != 0)
            bits.append(v & 8 != 0)
        }
        var pos = 0
        func read(_ n: Int) -> Int {
            var r = 0
            for i in 0 ..< n {
                guard pos < bits.count else { break }
                if bits[pos] { r |= (1 << i) }
                pos += 1
            }
            return r
        }
        var states: [Int] = []
        func decode(depth: Int) {
            guard depth < 32, pos < bits.count else { return }
            let nss = read(2)
            if nss == 0 {
                let sc = read(2)
                let state: Int
                if sc < 3 {
                    state = sc
                } else {
                    let e = read(4)
                    if e == 14 { state = 17 + read(8) } else { state = 3 + e }
                }
                states.append(state)
            } else {
                _ = read(2) // special_side
                for _ in 0 ... nss { decode(depth: depth + 1) } // nss + 1 children
            }
        }
        decode(depth: 0)
        let painted = states.filter { $0 >= 1 }
        guard !painted.isEmpty else { return 0 }
        var counts: [Int: Int] = [:]
        for s in painted { counts[s, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }

    /// Parses `#RRGGBB` / `#RRGGBBAA` into RGBA 0...1. Returns nil on malformed input.
    static func parseHexColor(_ s: String) -> SIMD4<Float>? {
        guard s.hasPrefix("#") else { return nil }
        let hex = s.dropFirst()
        guard hex.count == 6 || hex.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: String(hex)).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Float
        if hex.count == 6 {
            r = Float((value >> 16) & 0xFF) / 255
            g = Float((value >> 8) & 0xFF) / 255
            b = Float(value & 0xFF) / 255
            a = 1
        } else {
            r = Float((value >> 24) & 0xFF) / 255
            g = Float((value >> 16) & 0xFF) / 255
            b = Float((value >> 8) & 0xFF) / 255
            a = Float(value & 0xFF) / 255
        }
        return SIMD4<Float>(r, g, b, a)
    }
}

/// Collects plates and per-object extruder assignments from `model_settings.config`.
/// Uses the element stack so a `<metadata key="extruder">` is attributed to its immediate
/// parent: an `<object>` (object-level color), not a nested `<part>` or `<model_instance>`.
private final class ModelSettingsDelegate: NSObject, XMLParserDelegate {
    struct PlateAcc {
        let id: Int
        var name: String = ""
        var objectIds: [String] = []
    }

    private(set) var plates: [PlateAcc] = []
    private(set) var objectExtruder: [String: Int] = [:]

    private var stack: [String] = []
    private var currentObjectId: String?
    private var currentPlate: PlateAcc?

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String]
    ) {
        let parent = stack.last
        switch elementName {
        case "object":
            currentObjectId = attributeDict["id"]
        case "plate":
            currentPlate = PlateAcc(id: 0)
        case "metadata":
            handleMetadata(key: attributeDict["key"], value: attributeDict["value"], parent: parent)
        default:
            break
        }
        stack.append(elementName)
    }

    private func handleMetadata(key: String?, value: String?, parent: String?) {
        guard let key, let value else { return }
        switch parent {
        case "object":
            if key == "extruder", let oid = currentObjectId, let n = Int(value) {
                objectExtruder[oid] = n
            }
        case "plate":
            if key == "plater_id", let id = Int(value) {
                currentPlate = PlateAcc(
                    id: id,
                    name: currentPlate?.name ?? "",
                    objectIds: currentPlate?.objectIds ?? []
                )
            } else if key == "plater_name" {
                currentPlate?.name = value
            }
        case "model_instance":
            if key == "object_id" {
                currentPlate?.objectIds.append(value)
            }
        default:
            break
        }
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        if !stack.isEmpty { stack.removeLast() }
        switch elementName {
        case "object":
            currentObjectId = nil
        case "plate":
            if let plate = currentPlate { plates.append(plate) }
            currentPlate = nil
        default:
            break
        }
    }
}
