import Foundation
import SceneKit
import ZIPFoundation

enum ThreeMFMeshParserError: Error, LocalizedError {
    case cannotOpenArchive
    case modelNotFound
    case parseFailed
    case noMeshData

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive: return "Cannot open .3mf archive"
        case .modelNotFound: return "3D model not found in .3mf archive"
        case .parseFailed: return "Failed to parse 3D model XML"
        case .noMeshData: return "No mesh data found in 3D model"
        }
    }
}

struct ThreeMFMeshParser {
    private static let modelPaths = [
        "3D/3dmodel.model",
        "3D/3DModel.model",
        "3d/3dmodel.model",
    ]

    /// Progress callback: receives a value from 0.0 to 1.0
    /// Phases: 0–0.4 = ZIP extraction, 0.4–0.8 = XML scanning, 0.8–1.0 = normal computation
    static func parseMesh(from fileURL: URL, progress: ((Float) -> Void)? = nil) throws -> MeshData {
        guard let archive = Archive(url: fileURL, accessMode: .read) else {
            throw ThreeMFMeshParserError.cannotOpenArchive
        }

        var modelData: Data?
        for path in modelPaths {
            if let entry = archive[path] {
                var data = Data()
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
                if !data.isEmpty {
                    modelData = data
                    break
                }
            }
        }

        guard let xmlData = modelData else {
            throw ThreeMFMeshParserError.modelNotFound
        }

        // Fast-path: scan bytes directly for vertex/triangle data
        let result = FastMeshScanner.scan(xmlData)

        // Parse each external component file into its own mesh
        var objectMeshes = result.objectMeshes

        // Build set of object IDs actually needed by build items
        // to avoid extracting/parsing large files we won't use
        let neededObjectIds: Set<String>
        if !result.buildItems.isEmpty {
            var needed = Set<String>()
            for item in result.buildItems {
                needed.insert(item.objectId)
                // Also include components referenced by build item objects
                for comp in result.components where comp.parentObjectId == item.objectId {
                    needed.insert(comp.objectId)
                }
            }
            neededObjectIds = needed
        } else {
            // No build section — need all components
            neededObjectIds = Set(result.components.map { $0.objectId })
        }

        // External component meshes — only extract those actually needed
        for comp in result.components {
            guard neededObjectIds.contains(comp.objectId) || neededObjectIds.contains(comp.parentObjectId) else {
                continue
            }
            let normalized = comp.path.hasPrefix("/") ? String(comp.path.dropFirst()) : comp.path
            if objectMeshes[comp.objectId] != nil { continue }

            if let entry = archive[normalized] {
                let totalSize = max(entry.uncompressedSize, 1)
                var data = Data()
                data.reserveCapacity(Int(totalSize))
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                    // 0–40%: ZIP extraction progress
                    progress?(0.4 * Float(data.count) / Float(totalSize))
                }
                if !data.isEmpty {
                    progress?(0.4)
                    let compResult = FastMeshScanner.scan(data) { scanFraction in
                        // 40–80%: scanning progress
                        progress?(0.4 + 0.4 * scanFraction)
                    }
                    for (_, mesh) in compResult.objectMeshes {
                        objectMeshes[comp.objectId] = mesh
                        break
                    }
                }
            }
        }

        // Assemble: use build items (with transforms) if available,
        // otherwise just merge all meshes
        var allVertices: [SCNVector3] = []
        var allIndices: [UInt32] = []

        if !result.buildItems.isEmpty {
            for item in result.buildItems {
                let meshObjId = resolveObjectMesh(
                    objectId: item.objectId,
                    components: result.components,
                    objectMeshes: objectMeshes
                )
                guard let mesh = objectMeshes[meshObjId] else { continue }

                let baseOffset = UInt32(allVertices.count)
                let transform = item.transform

                if transform == [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0] {
                    // Identity transform — skip per-vertex math
                    allVertices.append(contentsOf: mesh.vertices)
                } else {
                    allVertices.reserveCapacity(allVertices.count + mesh.vertices.count)
                    for v in mesh.vertices {
                        allVertices.append(applyTransform(v, transform))
                    }
                }
                allIndices.reserveCapacity(allIndices.count + mesh.indices.count)
                for idx in mesh.indices {
                    allIndices.append(idx + baseOffset)
                }
            }
        } else {
            for (_, mesh) in objectMeshes {
                let baseOffset = UInt32(allVertices.count)
                allVertices.append(contentsOf: mesh.vertices)
                for idx in mesh.indices {
                    allIndices.append(idx + baseOffset)
                }
            }
        }

        guard !allVertices.isEmpty, !allIndices.isEmpty else {
            throw ThreeMFMeshParserError.noMeshData
        }

        progress?(0.8)
        var mesh = MeshData(vertices: allVertices, indices: allIndices, normals: nil)
        mesh.computeNormals { normalFraction in
            // 80–100%: normal computation progress
            progress?(0.8 + 0.2 * normalFraction)
        }
        return mesh
    }

    private static func resolveObjectMesh(
        objectId: String,
        components: [ComponentRef],
        objectMeshes: [String: (vertices: [SCNVector3], indices: [UInt32])]
    ) -> String {
        if objectMeshes[objectId] != nil {
            return objectId
        }
        for comp in components {
            if comp.parentObjectId == objectId, objectMeshes[comp.objectId] != nil {
                return comp.objectId
            }
        }
        return objectId
    }
}

struct ComponentRef {
    let parentObjectId: String
    let objectId: String
    let path: String
    let transform: [Float]
}

struct BuildItem {
    let objectId: String
    let transform: [Float]
}

// MARK: - Fast byte-level mesh scanner

/// Scans 3MF XML bytes directly without NSXMLParser overhead.
/// For large meshes (millions of vertices), this is 5-10x faster than NSXMLParser
/// because it avoids String/Dictionary allocation per element.
private enum FastMeshScanner {
    struct ScanResult {
        var objectMeshes: [String: (vertices: [SCNVector3], indices: [UInt32])]
        var components: [ComponentRef]
        var buildItems: [BuildItem]
    }

    static func scan(_ data: Data, progress: ((Float) -> Void)? = nil) -> ScanResult {
        return data.withUnsafeBytes { rawBuffer -> ScanResult in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return ScanResult(objectMeshes: [:], components: [], buildItems: [])
            }
            let count = rawBuffer.count
            var scanner = ByteScanner(base: base, count: count)
            return scanner.scan(progress: progress)
        }
    }
}

fileprivate struct ByteScanner {
    let base: UnsafePointer<UInt8>
    let count: Int
    var pos: Int = 0

    // Current parsing state
    var objectMeshes: [String: (vertices: [SCNVector3], indices: [UInt32])] = [:]
    var components: [ComponentRef] = []
    var buildItems: [BuildItem] = []

    private var currentObjectId: String?
    private var currentVertices: [SCNVector3] = []
    private var currentIndices: [UInt32] = []
    private var inMesh = false

    init(base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.count = count
    }

    // ASCII constants
    private static let lt: UInt8 = 0x3C       // <
    private static let gt: UInt8 = 0x3E       // >
    private static let slash: UInt8 = 0x2F    // /
    private static let space: UInt8 = 0x20    // space
    private static let tab: UInt8 = 0x09
    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let eq: UInt8 = 0x3D       // =
    private static let quote: UInt8 = 0x22    // "
    private static let sQuote: UInt8 = 0x27   // '

    mutating func scan(progress: ((Float) -> Void)? = nil) -> FastMeshScanner.ScanResult {
        // Pre-estimate capacity: ~60 bytes per vertex line, ~65 bytes per triangle line
        // A typical mesh is roughly 50% vertices + 50% triangles by byte count
        let estimatedVertices = count / 120
        if estimatedVertices > 1000 {
            currentVertices.reserveCapacity(estimatedVertices)
            currentIndices.reserveCapacity(estimatedVertices * 3)
        }

        let reportInterval = max(count / 40, 1) // report ~40 times
        var nextReport = reportInterval

        while pos < count {
            // Report scanning progress periodically
            if let progress = progress, pos >= nextReport {
                progress(Float(pos) / Float(count))
                nextReport = pos + reportInterval
            }

            // Find next '<'
            guard skipTo(ByteScanner.lt) else { break }
            pos += 1 // skip '<'
            guard pos < count else { break }

            // Skip closing tags quickly
            if base[pos] == ByteScanner.slash {
                // Closing tag — check if it's </mesh> or </object>
                pos += 1
                let tagStart = pos
                skipToTagEnd()
                let tagLen = pos - tagStart
                if tagLen >= 4 && matchesAt(tagStart, "mesh") {
                    inMesh = false
                } else if tagLen >= 6 && matchesAt(tagStart, "object") {
                    if let objId = currentObjectId, !currentVertices.isEmpty {
                        objectMeshes[objId] = (vertices: currentVertices, indices: currentIndices)
                    }
                    currentObjectId = nil
                }
                continue
            }

            // Skip processing instructions and comments
            if base[pos] == 0x3F || base[pos] == 0x21 { // ? or !
                skipToTagEnd()
                continue
            }

            // Read tag name (stripping namespace prefix)
            let tagName = readTagName()

            switch tagName {
            case .vertex where inMesh:
                parseVertex()
            case .triangle where inMesh:
                parseTriangle()
            case .mesh:
                inMesh = true
                skipToTagEnd()
            case .object:
                parseObject()
            case .component:
                parseComponent()
            case .item:
                parseItem()
            default:
                skipToTagEnd()
            }
        }

        return FastMeshScanner.ScanResult(
            objectMeshes: objectMeshes,
            components: components,
            buildItems: buildItems
        )
    }

    // MARK: - Tag name matching

    private enum TagKind {
        case vertex, triangle, mesh, object, component, item, other
    }

    private mutating func readTagName() -> TagKind {
        let start = pos
        // Advance to whitespace or '>' or '/'
        while pos < count {
            let c = base[pos]
            if c == ByteScanner.space || c == ByteScanner.tab || c == ByteScanner.cr ||
               c == ByteScanner.lf || c == ByteScanner.gt || c == ByteScanner.slash {
                break
            }
            pos += 1
        }

        // Find the local name (after last ':')
        var nameStart = start
        for i in start..<pos {
            if base[i] == 0x3A { // ':'
                nameStart = i + 1
            }
        }

        let len = pos - nameStart
        // Match common tag names by length then first char
        switch len {
        case 4:
            if matchesCaseInsensitiveAt(nameStart, "mesh") { return .mesh }
            if matchesCaseInsensitiveAt(nameStart, "item") { return .item }
        case 6:
            if matchesCaseInsensitiveAt(nameStart, "vertex") { return .vertex }
            if matchesCaseInsensitiveAt(nameStart, "object") { return .object }
        case 8:
            if matchesCaseInsensitiveAt(nameStart, "triangle") { return .triangle }
        case 9:
            if matchesCaseInsensitiveAt(nameStart, "component") { return .component }
        default:
            break
        }
        return .other
    }

    // MARK: - Element parsers

    private mutating func parseVertex() {
        var x: Float = 0, y: Float = 0, z: Float = 0
        var gotX = false, gotY = false, gotZ = false

        while pos < count && base[pos] != ByteScanner.gt {
            skipWhitespace()
            guard pos < count && base[pos] != ByteScanner.gt && base[pos] != ByteScanner.slash else { break }

            // Read attribute name
            let attrStart = pos
            while pos < count && base[pos] != ByteScanner.eq && base[pos] != ByteScanner.space &&
                  base[pos] != ByteScanner.gt {
                pos += 1
            }
            let attrLen = pos - attrStart

            guard pos < count && base[pos] == ByteScanner.eq else { continue }
            pos += 1 // skip '='
            guard pos < count else { break }

            let quoteChar = base[pos]
            guard quoteChar == ByteScanner.quote || quoteChar == ByteScanner.sQuote else { continue }
            pos += 1

            let valStart = pos
            while pos < count && base[pos] != quoteChar { pos += 1 }
            let valEnd = pos
            if pos < count { pos += 1 } // skip closing quote

            // Match single-char attribute names x, y, z
            if attrLen == 1 {
                let attrChar = base[attrStart]
                if attrChar == 0x78 || attrChar == 0x58 { // 'x' or 'X'
                    x = parseFloatFromBytes(valStart, valEnd)
                    gotX = true
                } else if attrChar == 0x79 || attrChar == 0x59 { // 'y' or 'Y'
                    y = parseFloatFromBytes(valStart, valEnd)
                    gotY = true
                } else if attrChar == 0x7A || attrChar == 0x5A { // 'z' or 'Z'
                    z = parseFloatFromBytes(valStart, valEnd)
                    gotZ = true
                }
            }
        }
        skipToTagEnd()

        if gotX && gotY && gotZ {
            currentVertices.append(SCNVector3(x, y, z))
        }
    }

    private mutating func parseTriangle() {
        var v1: UInt32 = 0, v2: UInt32 = 0, v3: UInt32 = 0
        var gotV1 = false, gotV2 = false, gotV3 = false

        while pos < count && base[pos] != ByteScanner.gt {
            skipWhitespace()
            guard pos < count && base[pos] != ByteScanner.gt && base[pos] != ByteScanner.slash else { break }

            let attrStart = pos
            while pos < count && base[pos] != ByteScanner.eq && base[pos] != ByteScanner.space &&
                  base[pos] != ByteScanner.gt {
                pos += 1
            }
            let attrLen = pos - attrStart

            guard pos < count && base[pos] == ByteScanner.eq else { continue }
            pos += 1
            guard pos < count else { break }

            let quoteChar = base[pos]
            guard quoteChar == ByteScanner.quote || quoteChar == ByteScanner.sQuote else { continue }
            pos += 1

            let valStart = pos
            while pos < count && base[pos] != quoteChar { pos += 1 }
            let valEnd = pos
            if pos < count { pos += 1 }

            // Match v1, v2, v3
            if attrLen == 2 && (base[attrStart] == 0x76 || base[attrStart] == 0x56) { // 'v' or 'V'
                let digit = base[attrStart + 1]
                if digit == 0x31 { // '1'
                    v1 = parseUInt32FromBytes(valStart, valEnd)
                    gotV1 = true
                } else if digit == 0x32 { // '2'
                    v2 = parseUInt32FromBytes(valStart, valEnd)
                    gotV2 = true
                } else if digit == 0x33 { // '3'
                    v3 = parseUInt32FromBytes(valStart, valEnd)
                    gotV3 = true
                }
            }
        }
        skipToTagEnd()

        if gotV1 && gotV2 && gotV3 {
            currentIndices.append(v1)
            currentIndices.append(v2)
            currentIndices.append(v3)
        }
    }

    private mutating func parseObject() {
        currentObjectId = readStringAttribute("id")
        currentVertices = []
        currentIndices = []
        skipToTagEnd()
    }

    private mutating func parseComponent() {
        let attrs = readAttributes(["objectid", "p:path", "path", "transform"])
        if let parentId = currentObjectId, let objId = attrs["objectid"] {
            let path = attrs["p:path"] ?? attrs["path"] ?? ""
            let transformStr = attrs["transform"] ?? "1 0 0 0 1 0 0 0 1 0 0 0"
            components.append(ComponentRef(
                parentObjectId: parentId,
                objectId: objId,
                path: path,
                transform: parseTransformString(transformStr)
            ))
        }
        skipToTagEnd()
    }

    private mutating func parseItem() {
        let attrs = readAttributes(["objectid", "transform"])
        if let objId = attrs["objectid"] {
            let transformStr = attrs["transform"] ?? "1 0 0 0 1 0 0 0 1 0 0 0"
            buildItems.append(BuildItem(
                objectId: objId,
                transform: parseTransformString(transformStr)
            ))
        }
        skipToTagEnd()
    }

    // MARK: - Attribute reading (for non-hot-path elements)

    private mutating func readStringAttribute(_ name: String) -> String? {
        let saved = pos
        let attrs = readAttributes([name])
        pos = saved
        return attrs[name]
    }

    private mutating func readAttributes(_ names: Set<String>) -> [String: String] {
        var result: [String: String] = [:]

        while pos < count && base[pos] != ByteScanner.gt {
            skipWhitespace()
            guard pos < count && base[pos] != ByteScanner.gt && base[pos] != ByteScanner.slash else { break }

            let attrStart = pos
            while pos < count && base[pos] != ByteScanner.eq && base[pos] != ByteScanner.space &&
                  base[pos] != ByteScanner.gt {
                pos += 1
            }
            let attrName = stringFromBytes(attrStart, pos)

            guard pos < count && base[pos] == ByteScanner.eq else { continue }
            pos += 1
            guard pos < count else { break }

            let quoteChar = base[pos]
            guard quoteChar == ByteScanner.quote || quoteChar == ByteScanner.sQuote else { continue }
            pos += 1

            let valStart = pos
            while pos < count && base[pos] != quoteChar { pos += 1 }
            let valEnd = pos
            if pos < count { pos += 1 }

            if names.contains(attrName) {
                result[attrName] = stringFromBytes(valStart, valEnd)
            }
        }
        return result
    }

    // MARK: - Low-level helpers

    @inline(__always)
    private mutating func skipWhitespace() {
        while pos < count {
            let c = base[pos]
            if c == ByteScanner.space || c == ByteScanner.tab || c == ByteScanner.cr || c == ByteScanner.lf {
                pos += 1
            } else {
                break
            }
        }
    }

    @inline(__always)
    private mutating func skipTo(_ byte: UInt8) -> Bool {
        // Use memchr for fast scanning
        if let found = memchr(base + pos, Int32(byte), count - pos) {
            pos = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            return true
        }
        pos = count
        return false
    }

    @inline(__always)
    private func stringFromBytes(_ start: Int, _ end: Int) -> String {
        let len = end - start
        guard len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: base + start, count: len), as: UTF8.self)
    }

    @inline(__always)
    private mutating func skipToTagEnd() {
        _ = skipTo(ByteScanner.gt)
        if pos < count { pos += 1 }
    }

    @inline(__always)
    private func matchesAt(_ offset: Int, _ str: String) -> Bool {
        let utf8 = str.utf8
        guard offset + utf8.count <= count else { return false }
        for (i, ch) in utf8.enumerated() {
            if base[offset + i] != ch { return false }
        }
        return true
    }

    @inline(__always)
    private func matchesCaseInsensitiveAt(_ offset: Int, _ lowercase: String) -> Bool {
        let utf8 = lowercase.utf8
        guard offset + utf8.count <= count else { return false }
        for (i, ch) in utf8.enumerated() {
            let b = base[offset + i]
            if b != ch && b != ch - 32 { return false } // lowercase or uppercase
        }
        return true
    }

    // MARK: - Fast number parsing from bytes

    @inline(__always)
    private func parseFloatFromBytes(_ start: Int, _ end: Int) -> Float {
        // Fast inline float parser — avoids String allocation and strtof overhead
        let len = end - start
        guard len > 0 else { return 0 }

        var i = start
        var negative = false
        if base[i] == 0x2D { // '-'
            negative = true
            i += 1
        } else if base[i] == 0x2B { // '+'
            i += 1
        }

        var intPart: Double = 0
        while i < end {
            let c = base[i]
            guard c >= 0x30 && c <= 0x39 else { break }
            intPart = intPart * 10 + Double(c - 0x30)
            i += 1
        }

        var fracPart: Double = 0
        if i < end && base[i] == 0x2E { // '.'
            i += 1
            var divisor: Double = 10
            while i < end {
                let c = base[i]
                guard c >= 0x30 && c <= 0x39 else { break }
                fracPart += Double(c - 0x30) / divisor
                divisor *= 10
                i += 1
            }
        }

        var result = intPart + fracPart

        // Handle scientific notation (e.g., 1.5e-3)
        if i < end && (base[i] == 0x65 || base[i] == 0x45) { // 'e' or 'E'
            i += 1
            var expNeg = false
            if i < end && base[i] == 0x2D {
                expNeg = true
                i += 1
            } else if i < end && base[i] == 0x2B {
                i += 1
            }
            var exp: Int = 0
            while i < end {
                let c = base[i]
                guard c >= 0x30 && c <= 0x39 else { break }
                exp = exp * 10 + Int(c - 0x30)
                i += 1
            }
            if expNeg {
                result /= pow(10.0, Double(exp))
            } else {
                result *= pow(10.0, Double(exp))
            }
        }

        return Float(negative ? -result : result)
    }

    @inline(__always)
    private func parseUInt32FromBytes(_ start: Int, _ end: Int) -> UInt32 {
        var result: UInt32 = 0
        var i = start
        while i < end {
            let c = base[i]
            guard c >= 0x30 && c <= 0x39 else { break } // '0'-'9'
            result = result &* 10 &+ UInt32(c - 0x30)
            i += 1
        }
        return result
    }
}

// MARK: - Transform helpers

private func applyTransform(_ v: SCNVector3, _ m: [Float]) -> SCNVector3 {
    let vx = Float(v.x)
    let vy = Float(v.y)
    let vz = Float(v.z)
    let x = (m[0] * vx) + (m[3] * vy) + (m[6] * vz) + m[9]
    let y = (m[1] * vx) + (m[4] * vy) + (m[7] * vz) + m[10]
    let z = (m[2] * vx) + (m[5] * vy) + (m[8] * vz) + m[11]
    return SCNVector3(x, y, z)
}

private func parseTransformString(_ str: String) -> [Float] {
    let parts = str.split(separator: " ").compactMap { Float($0) }
    guard parts.count == 12 else {
        return [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
    }
    return parts
}
