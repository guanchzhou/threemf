import Foundation
import os
import SceneKit
import simd
import ZIPFoundation

public enum ThreeMFMeshParserError: Error, LocalizedError {
    case cannotOpenArchive
    case modelNotFound
    case parseFailed
    case noMeshData
    case sizeLimitExceeded
    case invalidComponentPath

    public var errorDescription: String? {
        switch self {
        case .cannotOpenArchive: "Cannot open .3mf archive"
        case .modelNotFound: "3D model not found in .3mf archive"
        case .parseFailed: "Failed to parse 3D model XML"
        case .noMeshData: "No mesh data found in 3D model"
        case .sizeLimitExceeded: "3MF mesh exceeds size limits"
        case .invalidComponentPath: "3MF component path is invalid"
        }
    }
}

private let log = Logger(subsystem: "com.andreymaltsev.3mf-quicklook", category: "ThreeMFMeshParser")

public enum ThreeMFMeshParser {
    /// Maximum allowed size for any single extracted model entry (500 MB).
    /// Both the declared central-directory size *and* the running streamed total are capped.
    private static let maxModelSize: UInt64 = 500 * 1024 * 1024

    /// Aggregate caps applied across the whole 3MF (sum of all components).
    public static let maxVertices: Int = 50_000_000
    public static let maxTriangles: Int = 100_000_000

    private static let modelPaths = [
        "3D/3dmodel.model",
        "3D/3DModel.model",
        "3d/3dmodel.model",
    ]

    /// Validate a component-relative path inside the archive. Rejects traversal
    /// attempts and non-`.model` entries to harden against crafted archives.
    private static func sanitizeComponentPath(_ path: String) -> String? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty,
              !trimmed.contains(".."),
              !trimmed.contains("\\"),
              !trimmed.hasPrefix("/"),
              !trimmed.contains(":"),
              trimmed.lowercased().hasSuffix(".model")
        else { return nil }
        return trimmed
    }

    /// Streams an archive entry into a Data, enforcing both declared and runtime size caps.
    private static func extractCapped(
        _ archive: Archive,
        entry: Entry,
        cap: UInt64,
        progress: ((Float) -> Void)? = nil
    ) throws -> Data {
        guard entry.uncompressedSize <= cap else {
            throw ThreeMFMeshParserError.sizeLimitExceeded
        }
        let totalSize = max(entry.uncompressedSize, 1)
        var data = Data()
        data.reserveCapacity(Int(totalSize))
        _ = try archive.extract(entry) { chunk in
            // Defense against ZIP bombs: enforce the cap on the *actual* stream too.
            if UInt64(data.count) + UInt64(chunk.count) > cap {
                throw ThreeMFMeshParserError.sizeLimitExceeded
            }
            data.append(chunk)
            progress?(Float(data.count) / Float(totalSize))
        }
        return data
    }

    /// Fast path that extracts only `<metadata>` tags from the root model file.
    /// Skips component traversal, mesh assembly, and normal computation — useful for
    /// Spotlight indexing where we only need application/title/designer attributes.
    /// **Throws** when the archive can't be opened (vs returning nil); **returns nil**
    /// when the archive opens cleanly but has no `<metadata>` tags. Lets callers
    /// distinguish "file is broken" from "file simply has no metadata."
    public static func parseMetadata(from fileURL: URL) throws -> ThreeMFMetadata? {
        let archive = try Archive(url: fileURL, accessMode: .read)
        for path in modelPaths {
            guard let entry = archive[path] else { continue }
            guard let data = try? extractCapped(archive, entry: entry, cap: maxModelSize) else {
                continue
            }
            let result = FastMeshScanner.scan(data)
            return result.metadata.isEmpty ? nil : result.metadata
        }
        return nil
    }

    /// Progress callback: receives a value from 0.0 to 1.0
    /// Phases: 0–0.4 = ZIP extraction, 0.4–0.8 = XML scanning, 0.8–1.0 = normal computation
    public static func parseMesh(from fileURL: URL, progress: ((Float) -> Void)? = nil) throws -> MeshData {
        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            throw ThreeMFMeshParserError.cannotOpenArchive
        }

        var modelData: Data?
        for path in modelPaths {
            if let entry = archive[path] {
                let data = try extractCapped(archive, entry: entry, cap: maxModelSize)
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

        // Defensive fallback: if the byte-level scanner returned nothing (unusual
        // namespace, CDATA-wrapped mesh, structurally exotic 3MF), try NSXMLParser
        // on the root model file as a one-shot recovery.
        if result.objectMeshes.isEmpty, result.components.isEmpty, result.buildItems.isEmpty {
            if let fallback = nsxmlFallback(xmlData: xmlData) {
                log.notice("FastMeshScanner returned empty; using NSXMLParser fallback")
                progress?(0.8)
                var mesh = MeshData(
                    vertices: fallback.vertices,
                    indices: fallback.indices,
                    normals: nil,
                    metadata: result.metadata.isEmpty ? nil : result.metadata
                )
                mesh.computeNormals { fraction in progress?(0.8 + 0.2 * fraction) }
                return mesh
            }
        }

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
            neededObjectIds = Set(result.components.map(\.objectId))
        }

        // External component meshes — only extract those actually needed
        for comp in result.components {
            guard neededObjectIds.contains(comp.objectId) || neededObjectIds.contains(comp.parentObjectId) else {
                continue
            }
            guard let normalized = sanitizeComponentPath(comp.path) else {
                log.error("Rejected suspicious component path: \(comp.path, privacy: .public)")
                continue
            }
            if objectMeshes[comp.objectId] != nil { continue }

            if let entry = archive[normalized] {
                let data: Data
                do {
                    data = try extractCapped(archive, entry: entry, cap: maxModelSize) { fraction in
                        // 0–40%: ZIP extraction progress
                        progress?(0.4 * fraction)
                    }
                } catch {
                    log
                        .error(
                            "Component extract failed for \(normalized, privacy: .public): \(error.localizedDescription)"
                        )
                    continue
                }
                if !data.isEmpty {
                    progress?(0.4)
                    let compResult = FastMeshScanner.scan(data) { scanFraction in
                        // 40–80%: scanning progress
                        progress?(0.4 + 0.4 * scanFraction)
                    }
                    if let firstMesh = compResult.objectMeshes.first {
                        objectMeshes[comp.objectId] = firstMesh.value
                    }
                }
            }
        }

        // Assemble: use build items (with transforms) if available,
        // otherwise just merge all meshes (sorted by id for determinism)
        var allVertices: [simd_float3] = []
        var allIndices: [UInt32] = []
        let allMaterials: [BaseMaterial] = result.materials
        var allTriangleMats: [Int] = []

        /// Aggregate caps to bound memory.
        func canAppend(verts: Int, tris: Int) -> Bool {
            allVertices.count + verts <= maxVertices
                && (allIndices.count / 3) + tris <= maxTriangles
        }

        if !result.buildItems.isEmpty {
            for item in result.buildItems {
                let meshObjId = resolveObjectMesh(
                    objectId: item.objectId,
                    components: result.components,
                    objectMeshes: objectMeshes
                )
                guard let mesh = objectMeshes[meshObjId] else { continue }
                guard canAppend(verts: mesh.vertices.count, tris: mesh.indices.count / 3) else {
                    log.error("Skipping object \(meshObjId, privacy: .public) — would exceed aggregate caps")
                    continue
                }

                let baseOffset = UInt32(allVertices.count)
                let transform = item.transform

                if transform == [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0] {
                    // Identity transform — skip per-vertex math
                    allVertices.append(contentsOf: mesh.vertices)
                } else {
                    allVertices.reserveCapacity(allVertices.count + mesh.vertices.count)
                    let m = transform
                    for v in mesh.vertices {
                        let x = (m[0] * v.x) + (m[3] * v.y) + (m[6] * v.z) + m[9]
                        let y = (m[1] * v.x) + (m[4] * v.y) + (m[7] * v.z) + m[10]
                        let z = (m[2] * v.x) + (m[5] * v.y) + (m[8] * v.z) + m[11]
                        allVertices.append(simd_float3(x, y, z))
                    }
                }
                allIndices.reserveCapacity(allIndices.count + mesh.indices.count)
                let triBase = allIndices.count / 3
                for idx in mesh.indices {
                    allIndices.append(idx + baseOffset)
                }
                if !mesh.triangleMaterials.isEmpty {
                    if allTriangleMats.count < triBase {
                        allTriangleMats.append(contentsOf: repeatElement(-1, count: triBase - allTriangleMats.count))
                    }
                    allTriangleMats.append(contentsOf: mesh.triangleMaterials)
                }
            }
        } else {
            // Sort for deterministic display order across launches.
            for objId in objectMeshes.keys.sorted() {
                guard let mesh = objectMeshes[objId] else { continue }
                guard canAppend(verts: mesh.vertices.count, tris: mesh.indices.count / 3) else { continue }
                let baseOffset = UInt32(allVertices.count)
                let triBase = allIndices.count / 3
                allVertices.append(contentsOf: mesh.vertices)
                for idx in mesh.indices {
                    allIndices.append(idx + baseOffset)
                }
                if !mesh.triangleMaterials.isEmpty {
                    if allTriangleMats.count < triBase {
                        allTriangleMats.append(contentsOf: repeatElement(-1, count: triBase - allTriangleMats.count))
                    }
                    allTriangleMats.append(contentsOf: mesh.triangleMaterials)
                }
            }
        }

        guard !allVertices.isEmpty, !allIndices.isEmpty else {
            throw ThreeMFMeshParserError.noMeshData
        }

        // Pad triangleMaterials trailing tail with -1 so length matches triangle count.
        if !allTriangleMats.isEmpty {
            let target = allIndices.count / 3
            if allTriangleMats.count < target {
                allTriangleMats.append(contentsOf: repeatElement(-1, count: target - allTriangleMats.count))
            }
        }

        // Filter out triangles with out-of-range indices before SceneKit sees them.
        let vCount = UInt32(allVertices.count)
        var filteredIndices: [UInt32] = []
        filteredIndices.reserveCapacity(allIndices.count)
        var filteredMats: [Int] = []
        filteredMats.reserveCapacity(allTriangleMats.count)
        var t = 0
        while t * 3 + 2 < allIndices.count {
            let a = allIndices[t * 3], b = allIndices[t * 3 + 1], c = allIndices[t * 3 + 2]
            if a < vCount, b < vCount, c < vCount {
                filteredIndices.append(a)
                filteredIndices.append(b)
                filteredIndices.append(c)
                if !allTriangleMats.isEmpty, t < allTriangleMats.count {
                    filteredMats.append(allTriangleMats[t])
                }
            }
            t += 1
        }

        guard !filteredIndices.isEmpty else {
            throw ThreeMFMeshParserError.noMeshData
        }

        progress?(0.8)
        var mesh = MeshData(vertices: allVertices, indices: filteredIndices, normals: nil)
        mesh.materials = allMaterials
        mesh.triangleMaterials = filteredMats
        mesh.metadata = result.metadata.isEmpty ? nil : result.metadata
        mesh.computeNormals { normalFraction in
            // 80–100%: normal computation progress
            progress?(0.8 + 0.2 * normalFraction)
        }
        return mesh
    }

    /// Runs `XMLParser` (NSXMLParser) over the root model file to recover vertices and
    /// triangles when the byte-level fast scanner returned empty. Bounded by the same
    /// `maxVertices` / `maxTriangles` aggregate caps. Returns nil if it can't recover anything.
    private static func nsxmlFallback(xmlData: Data) -> (vertices: [simd_float3], indices: [UInt32])? {
        let delegate = NSXMLFallbackDelegate(maxVertices: maxVertices, maxTriangles: maxTriangles)
        let parser = XMLParser(data: xmlData)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        // Filter out-of-range indices so SceneKit never sees a bad triangle.
        let vCount = UInt32(delegate.vertices.count)
        var safeIndices: [UInt32] = []
        safeIndices.reserveCapacity(delegate.indices.count)
        var t = 0
        while t * 3 + 2 < delegate.indices.count {
            let a = delegate.indices[t * 3]
            let b = delegate.indices[t * 3 + 1]
            let c = delegate.indices[t * 3 + 2]
            if a < vCount, b < vCount, c < vCount {
                safeIndices.append(a)
                safeIndices.append(b)
                safeIndices.append(c)
            }
            t += 1
        }
        guard !delegate.vertices.isEmpty, safeIndices.count >= 3 else { return nil }
        return (delegate.vertices, safeIndices)
    }

    private static func resolveObjectMesh(
        objectId: String,
        components: [ComponentRef],
        objectMeshes: [String: (vertices: [simd_float3], indices: [UInt32], triangleMaterials: [Int])]
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

// MARK: - NSXMLParser fallback delegate

/// Minimal `XMLParser` delegate used when the byte-level scanner can't recover any meshes.
/// Reads only `<vertex>` and `<triangle>` inside any `<mesh>` element; aggregate caps abort parsing.
private final class NSXMLFallbackDelegate: NSObject, XMLParserDelegate {
    var vertices: [simd_float3] = []
    var indices: [UInt32] = []
    private var inMesh = false
    private let maxVertices: Int
    private let maxTriangles: Int

    init(maxVertices: Int, maxTriangles: Int) {
        self.maxVertices = maxVertices
        self.maxTriangles = maxTriangles
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attrs: [String: String] = [:]
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch local.lowercased() {
        case "mesh":
            inMesh = true
        case "vertex" where inMesh:
            if vertices.count >= maxVertices { parser.abortParsing(); return }
            guard
                let xs = attrs["x"], let ys = attrs["y"], let zs = attrs["z"],
                let x = Float(xs), let y = Float(ys), let z = Float(zs),
                x.isFinite, y.isFinite, z.isFinite
            else { return }
            vertices.append(simd_float3(x, y, z))
        case "triangle" where inMesh:
            if indices.count / 3 >= maxTriangles { parser.abortParsing(); return }
            guard
                let v1s = attrs["v1"], let v2s = attrs["v2"], let v3s = attrs["v3"],
                let v1 = UInt32(v1s), let v2 = UInt32(v2s), let v3 = UInt32(v3s)
            else { return }
            indices.append(v1)
            indices.append(v2)
            indices.append(v3)
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
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local.lowercased() == "mesh" { inMesh = false }
    }
}

// MARK: - Fast byte-level mesh scanner

typealias ObjectMesh = (vertices: [simd_float3], indices: [UInt32], triangleMaterials: [Int])

/// Scans 3MF XML bytes directly without NSXMLParser overhead.
/// For large meshes (millions of vertices), this is 5-10x faster than NSXMLParser
/// because it avoids String/Dictionary allocation per element.
enum FastMeshScanner {
    struct ScanResult {
        var objectMeshes: [String: ObjectMesh]
        var components: [ComponentRef]
        var buildItems: [BuildItem]
        /// Flat list of materials encountered in this scan. Triangles' indices into this list
        /// live in `objectMeshes[*].triangleMaterials`.
        var materials: [BaseMaterial]
        /// Standard 3MF `<metadata>` tags from the root model file.
        var metadata: ThreeMFMetadata
    }

    static func scan(_ data: Data, progress: ((Float) -> Void)? = nil) -> ScanResult {
        data.withUnsafeBytes { rawBuffer -> ScanResult in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return ScanResult(
                    objectMeshes: [:],
                    components: [],
                    buildItems: [],
                    materials: [],
                    metadata: ThreeMFMetadata()
                )
            }
            let count = rawBuffer.count
            var scanner = ByteScanner(base: base, count: count)
            return scanner.scan(progress: progress)
        }
    }
}

private struct ByteScanner {
    let base: UnsafePointer<UInt8>
    let count: Int
    var pos: Int = 0

    // Current parsing state
    var objectMeshes: [String: ObjectMesh] = [:]
    var components: [ComponentRef] = []
    var buildItems: [BuildItem] = []
    var materials: [BaseMaterial] = []
    var metadata = ThreeMFMetadata()

    /// Map: basematerials group id (`<basematerials id="N">`) → range in `materials` array.
    private var materialGroups: [String: Range<Int>] = [:]
    /// While inside a `<basematerials>` block, accumulate entries here.
    private var currentMatGroupId: String?
    private var currentMatGroupStart: Int = 0

    private var currentObjectId: String?
    private var currentVertices: [simd_float3] = []
    private var currentIndices: [UInt32] = []
    private var currentTriMaterials: [Int] = []
    private var hasAnyMaterial = false
    private var inMesh = false

    init(base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.count = count
    }

    // ASCII constants
    private static let lt: UInt8 = 0x3C // <
    private static let gt: UInt8 = 0x3E // >
    private static let slash: UInt8 = 0x2F // /
    private static let space: UInt8 = 0x20 // space
    private static let tab: UInt8 = 0x09
    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let eq: UInt8 = 0x3D // =
    private static let quote: UInt8 = 0x22 // "
    private static let sQuote: UInt8 = 0x27 // '

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
            if let progress, pos >= nextReport {
                progress(Float(pos) / Float(count))
                nextReport = pos + reportInterval
            }

            // Find next '<'
            guard skipTo(ByteScanner.lt) else { break }
            pos += 1 // skip '<'
            guard pos < count else { break }

            // Skip closing tags quickly
            if base[pos] == ByteScanner.slash {
                // Closing tag — check if it's </mesh>, </object>, or </basematerials>
                pos += 1
                let tagStart = pos
                skipToTagEnd()
                let tagLen = pos - tagStart
                if tagLen >= 4, matchesAt(tagStart, "mesh") {
                    inMesh = false
                } else if tagLen >= 6, matchesAt(tagStart, "object") {
                    if let objId = currentObjectId, !currentVertices.isEmpty {
                        let mats = hasAnyMaterial ? currentTriMaterials : []
                        objectMeshes[objId] = (
                            vertices: currentVertices,
                            indices: currentIndices,
                            triangleMaterials: mats
                        )
                    }
                    currentObjectId = nil
                    hasAnyMaterial = false
                    currentTriMaterials = []
                } else if tagLen >= 13, matchesAt(tagStart, "basematerials") {
                    if let gid = currentMatGroupId {
                        materialGroups[gid] = currentMatGroupStart ..< materials.count
                    }
                    currentMatGroupId = nil
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
            case .basematerials:
                parseBaseMaterialsOpen()
            case .base:
                parseBaseEntry()
            case .metadata:
                parseMetadataTag()
            default:
                skipToTagEnd()
            }
        }

        return FastMeshScanner.ScanResult(
            objectMeshes: objectMeshes,
            components: components,
            buildItems: buildItems,
            materials: materials,
            metadata: metadata
        )
    }

    // MARK: - Tag name matching

    private enum TagKind {
        case vertex, triangle, mesh, object, component, item, basematerials, base, metadata, other
    }

    private mutating func readTagName() -> TagKind {
        let start = pos
        // Advance to whitespace or '>' or '/'
        while pos < count {
            let c = base[pos]
            if c == ByteScanner.space || c == ByteScanner.tab || c == ByteScanner.cr ||
                c == ByteScanner.lf || c == ByteScanner.gt || c == ByteScanner.slash
            {
                break
            }
            pos += 1
        }

        // Find the local name (after last ':')
        var nameStart = start
        for i in start ..< pos {
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
            if matchesCaseInsensitiveAt(nameStart, "base") { return .base }
        case 6:
            if matchesCaseInsensitiveAt(nameStart, "vertex") { return .vertex }
            if matchesCaseInsensitiveAt(nameStart, "object") { return .object }
        case 8:
            if matchesCaseInsensitiveAt(nameStart, "triangle") { return .triangle }
            if matchesCaseInsensitiveAt(nameStart, "metadata") { return .metadata }
        case 9:
            if matchesCaseInsensitiveAt(nameStart, "component") { return .component }
        case 13:
            if matchesCaseInsensitiveAt(nameStart, "basematerials") { return .basematerials }
        default:
            break
        }
        return .other
    }

    // MARK: - Element parsers

    private mutating func parseVertex() {
        var x: Float = 0, y: Float = 0, z: Float = 0
        var gotX = false, gotY = false, gotZ = false

        while pos < count, base[pos] != ByteScanner.gt {
            skipWhitespace()
            guard pos < count && base[pos] != ByteScanner.gt && base[pos] != ByteScanner.slash else { break }

            // Read attribute name
            let attrStart = pos
            while pos < count && base[pos] != ByteScanner.eq && base[pos] != ByteScanner.space &&
                base[pos] != ByteScanner.gt
            {
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
            while pos < count, base[pos] != quoteChar {
                pos += 1
            }
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

        if gotX, gotY, gotZ {
            currentVertices.append(simd_float3(x, y, z))
        }
    }

    private mutating func parseTriangle() {
        var v1: UInt32 = 0, v2: UInt32 = 0, v3: UInt32 = 0
        var gotV1 = false, gotV2 = false, gotV3 = false
        var pid: String?
        var p1Idx: Int?

        while pos < count, base[pos] != ByteScanner.gt {
            skipWhitespace()
            guard pos < count && base[pos] != ByteScanner.gt && base[pos] != ByteScanner.slash else { break }

            let attrStart = pos
            while pos < count && base[pos] != ByteScanner.eq && base[pos] != ByteScanner.space &&
                base[pos] != ByteScanner.gt
            {
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
            while pos < count, base[pos] != quoteChar {
                pos += 1
            }
            let valEnd = pos
            if pos < count { pos += 1 }

            // Match v1, v2, v3 (vertex indices) and p1 (per-tri material) and pid (group id).
            if attrLen == 2 {
                let a0 = base[attrStart], a1 = base[attrStart + 1]
                if a0 == 0x76 || a0 == 0x56 { // 'v'/'V'
                    if a1 == 0x31 {
                        v1 = parseUInt32FromBytes(valStart, valEnd); gotV1 = true
                    } else if a1 == 0x32 {
                        v2 = parseUInt32FromBytes(valStart, valEnd); gotV2 = true
                    } else if a1 == 0x33 {
                        v3 = parseUInt32FromBytes(valStart, valEnd); gotV3 = true
                    }
                } else if a0 == 0x70 || a0 == 0x50, a1 == 0x31 { // 'p1'
                    p1Idx = Int(parseUInt32FromBytes(valStart, valEnd))
                }
            } else if attrLen == 3 {
                if base[attrStart] == 0x70 || base[attrStart] == 0x50,
                   base[attrStart + 1] == 0x69 || base[attrStart + 1] == 0x49,
                   base[attrStart + 2] == 0x64 || base[attrStart + 2] == 0x44
                {
                    pid = stringFromBytes(valStart, valEnd)
                }
            }
        }
        skipToTagEnd()

        if gotV1, gotV2, gotV3 {
            currentIndices.append(v1)
            currentIndices.append(v2)
            currentIndices.append(v3)
            // Resolve material: pid identifies a basematerials group, p1 is the entry within it.
            // We map (pid, p1) to a global material index. Default to 0 when unspecified.
            if let pid, let p1 = p1Idx, let range = materialGroups[pid] {
                let gIdx = range.lowerBound + p1
                if gIdx < range.upperBound {
                    currentTriMaterials.append(gIdx)
                    hasAnyMaterial = true
                } else {
                    currentTriMaterials.append(-1)
                }
            } else {
                currentTriMaterials.append(-1)
            }
        }
    }

    private mutating func parseObject() {
        currentObjectId = readStringAttribute("id")
        currentVertices = []
        currentIndices = []
        currentTriMaterials = []
        hasAnyMaterial = false
        skipToTagEnd()
    }

    private mutating func parseBaseMaterialsOpen() {
        if let id = readStringAttribute("id") {
            currentMatGroupId = id
            currentMatGroupStart = materials.count
        }
        skipToTagEnd()
    }

    private mutating func parseBaseEntry() {
        let attrs = readAttributes(["name", "displaycolor"])
        let name = attrs["name"] ?? ""
        let color = parseHexColor(attrs["displaycolor"])
        materials.append(BaseMaterial(name: name, color: color))
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

    /// Parses `<metadata name="X">value</metadata>`. The value is the text content
    /// between the open and close tags. Standard 3MF keys (Application, CreationDate,
    /// ModificationDate, Title, Designer) populate strongly-typed fields; everything
    /// else lands in `metadata.other` so slicer-specific extensions are preserved.
    private mutating func parseMetadataTag() {
        let attrs = readAttributes(["name"])
        let name = attrs["name"] ?? ""
        skipToTagEnd()
        // Capture text up to next '<' (start of close tag).
        let textStart = pos
        _ = skipTo(ByteScanner.lt)
        let textEnd = pos
        guard !name.isEmpty, textEnd > textStart else { return }
        let value = stringFromBytes(textStart, textEnd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch name {
        case "Application": metadata.application = value
        case "CreationDate": metadata.creationDate = value
        case "ModificationDate": metadata.modificationDate = value
        case "Title": metadata.title = value
        case "Designer": metadata.designer = value
        default: metadata.other[name] = value
        }
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

        while pos < count, base[pos] != ByteScanner.gt {
            skipWhitespace()
            guard pos < count && base[pos] != ByteScanner.gt && base[pos] != ByteScanner.slash else { break }

            let attrStart = pos
            while pos < count && base[pos] != ByteScanner.eq && base[pos] != ByteScanner.space &&
                base[pos] != ByteScanner.gt
            {
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
            while pos < count, base[pos] != quoteChar {
                pos += 1
            }
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
            if b != ch, b != ch - 32 { return false } // lowercase or uppercase
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
            guard c >= 0x30, c <= 0x39 else { break }
            intPart = intPart * 10 + Double(c - 0x30)
            i += 1
        }

        var fracPart: Double = 0
        if i < end, base[i] == 0x2E { // '.'
            i += 1
            var divisor: Double = 10
            while i < end {
                let c = base[i]
                guard c >= 0x30, c <= 0x39 else { break }
                fracPart += Double(c - 0x30) / divisor
                divisor *= 10
                i += 1
            }
        }

        var result = intPart + fracPart

        // Handle scientific notation (e.g., 1.5e-3)
        if i < end, base[i] == 0x65 || base[i] == 0x45 { // 'e' or 'E'
            i += 1
            var expNeg = false
            if i < end, base[i] == 0x2D {
                expNeg = true
                i += 1
            } else if i < end, base[i] == 0x2B {
                i += 1
            }
            var exp = 0
            while i < end {
                let c = base[i]
                guard c >= 0x30, c <= 0x39 else { break }
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
            guard c >= 0x30, c <= 0x39 else { break } // '0'-'9'
            result = result &* 10 &+ UInt32(c - 0x30)
            i += 1
        }
        return result
    }
}

// MARK: - Transform & color helpers

/// Parse `displaycolor` form `#RRGGBB` or `#RRGGBBAA` into RGBA components.
private func parseHexColor(_ s: String?) -> SIMD4<Float>? {
    guard let s, s.hasPrefix("#") else { return nil }
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

private func parseTransformString(_ str: String) -> [Float] {
    let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
    let parts = str.split(separator: " ").compactMap { Float($0) }
    guard parts.count == 12 else {
        log.error("parseTransformString: expected 12 floats, got \(parts.count, privacy: .public) — using identity")
        return identity
    }
    // Reject non-finite or wildly out-of-range entries to keep transformed vertices bounded.
    // 1e6 is far beyond any realistic build volume in mm — acts as a defense against crafted files.
    guard parts.allSatisfy({ $0.isFinite && abs($0) < 1e6 }) else {
        log.error("parseTransformString: non-finite or oversized matrix entry — using identity")
        return identity
    }
    return parts
}
