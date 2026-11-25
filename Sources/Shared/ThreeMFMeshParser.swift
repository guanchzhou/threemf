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
    /// Aggregate caps for the headless CLI (Quick Look uses ``ResourceLimits/quickLook``).
    public static let maxVertices: Int = ResourceLimits.cli.maxVertices
    public static let maxTriangles: Int = ResourceLimits.cli.maxTriangles

    /// Fallback root-model locations for archives whose `_rels/.rels` is missing or unusable.
    private static let modelPaths = [
        "3D/3dmodel.model",
        "3D/3DModel.model",
        "3d/3dmodel.model",
    ]

    private static let packageRelationshipsPath = "_rels/.rels"
    private static let maxPackageRelationshipsBytes: UInt64 = 1024 * 1024
    private static let modelRelationshipType = "http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"

    /// Caps on `<component>` and `<item>` elements collected from one `.model` file. Each
    /// component can cost an archive lookup and extraction, so the count must stay bounded.
    static let maxComponents = 10000
    static let maxBuildItems = 10000

    /// Caps on `<basematerials>` entries and `<metadata>` side entries collected by `FastMeshScanner`.
    static let maxMaterials = 4096
    static let maxMetadataOtherEntries = 256
    static let maxMetadataStringLength = 4096

    /// Initial buffer pre-allocation cap for `extractCapped` (4 MB) so crafted declared sizes
    /// cannot trigger huge upfront allocations before streaming begins.
    private static let maxInitialExtractCapacity = 4 * 1024 * 1024

    /// Cap on mesh instances one parse expands build items into. Nested components multiply
    /// (A→1,000×B→1,000×C is a million instances), which the per-file caps cannot bound.
    static let maxEmissions = 100_000

    /// The root model file holds `<metadata>` before `<resources>`, so Spotlight reads only
    /// this much of it.
    static let metadataPrefixBytes = 1024 * 1024

    /// Shared across every `.model` extraction in one parse so a component-heavy archive
    /// cannot multiply the per-entry cap by its number of entries.
    private final class ExtractionBudget {
        private(set) var remaining: UInt64

        init(_ total: UInt64) {
            remaining = total
        }

        func consume(_ byteCount: Int) throws {
            let count = UInt64(byteCount)
            guard count <= remaining else {
                throw ThreeMFMeshParserError.sizeLimitExceeded
            }
            remaining -= count
        }
    }

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
        _ archive: ThreeMFArchive,
        entry: Entry,
        cap: UInt64,
        budget: ExtractionBudget? = nil,
        cancellation: ParseCancellation? = nil,
        progress: ((Float) -> Void)? = nil
    ) throws -> Data {
        guard entry.uncompressedSize <= cap,
              entry.uncompressedSize <= (budget?.remaining ?? cap)
        else {
            throw ThreeMFMeshParserError.sizeLimitExceeded
        }
        let totalSize = max(entry.uncompressedSize, 1)
        var data = Data()
        let initialCapacity = min(Int(min(totalSize, UInt64(Int.max))), maxInitialExtractCapacity)
        data.reserveCapacity(initialCapacity)
        _ = try archive.archive.extract(entry) { chunk in
            // Chunks are large enough that polling every one is free.
            try cancellation?.check()
            // Defense against ZIP bombs: enforce the cap on the *actual* stream too.
            if UInt64(data.count) + UInt64(chunk.count) > cap {
                throw ThreeMFMeshParserError.sizeLimitExceeded
            }
            try budget?.consume(chunk.count)
            data.append(chunk)
            progress?(Float(data.count) / Float(totalSize))
        }
        return data
    }

    /// Reads an archive entry into memory if it exists, returning nil when absent or
    /// unreadable. Used for the small Bambu/Orca `Metadata/*.config` side files.
    private static func readEntryIfPresent(
        _ archive: ThreeMFArchive,
        path: String,
        limits: ResourceLimits
    ) -> Data? {
        guard let entry = archive.entry(path) else { return nil }
        return try? extractCapped(archive, entry: entry, cap: limits.maxMetadataSidecarBytes)
    }

    /// Root model paths to try in order: the `_rels/.rels` 3D-model relationship target when
    /// present and safe, then the conventional locations.
    private static func rootModelCandidates(_ archive: ThreeMFArchive) -> [String] {
        var candidates: [String] = []
        if let entry = archive.entry(packageRelationshipsPath),
           let data = try? extractCapped(archive, entry: entry, cap: maxPackageRelationshipsBytes),
           let target = modelRelationshipTarget(inRelationships: data)
        {
            candidates.append(target)
        }
        for path in modelPaths where !candidates.contains(path) {
            candidates.append(path)
        }
        return candidates
    }

    /// Returns the sanitized archive path of the first 3D-model relationship in an OPC
    /// `.rels` document, or nil when there is none or the document declares a DTD.
    static func modelRelationshipTarget(inRelationships data: Data) -> String? {
        // NSXMLParser expands internal entities even with external entities off.
        guard !containsDTDOrEntityDeclaration(data) else { return nil }
        let delegate = RelationshipsDelegate(type: modelRelationshipType)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        guard let target = delegate.target else { return nil }
        return sanitizeComponentPath(target.removingPercentEncoding ?? target)
    }

    /// Fast path that extracts only `<metadata>` tags from the root model file.
    /// Skips component traversal, mesh assembly, and normal computation — useful for
    /// Spotlight indexing where we only need application/title/designer attributes.
    /// **Throws** when the archive can't be opened (vs returning nil); **returns nil**
    /// when the archive opens cleanly but has no `<metadata>` tags. Lets callers
    /// distinguish "file is broken" from "file simply has no metadata."
    public static func parseMetadata(
        from fileURL: URL,
        limits: ResourceLimits = .cli
    ) throws -> ThreeMFMetadata? {
        let archive = try ThreeMFArchive(url: fileURL)
        for path in rootModelCandidates(archive) {
            guard let entry = archive.entry(path),
                  let data = try? extractPrefix(archive, entry: entry, maxBytes: metadataPrefixBytes)
            else {
                continue
            }
            let result = FastMeshScanner.scan(data, limits: limits, metadataOnly: true)
            return result.metadata.isEmpty ? nil : result.metadata
        }
        return nil
    }

    private struct PrefixComplete: Error {}

    /// Decompresses at most `maxBytes` of an entry, stopping the inflate stream early.
    private static func extractPrefix(_ archive: ThreeMFArchive, entry: Entry, maxBytes: Int) throws -> Data {
        var data = Data()
        do {
            _ = try archive.archive.extract(entry, skipCRC32: true) { chunk in
                data.append(chunk.prefix(maxBytes - data.count))
                if data.count >= maxBytes {
                    throw PrefixComplete()
                }
            }
        } catch is PrefixComplete {}
        return data
    }

    /// Progress callback: receives a value from 0.0 to 1.0
    /// Phases: 0–0.4 = ZIP extraction, 0.4–0.8 = XML scanning, 0.8–1.0 = normal computation
    /// Pass `computesNormals: false` when only counts, bounds, and metadata are needed.
    public static func parseMesh(
        from fileURL: URL,
        limits: ResourceLimits = .cli,
        cancellation: ParseCancellation? = nil,
        computesNormals: Bool = true,
        progress: ((Float) -> Void)? = nil
    ) throws -> MeshData {
        let archive: ThreeMFArchive
        do {
            archive = try ThreeMFArchive(url: fileURL)
        } catch {
            throw ThreeMFMeshParserError.cannotOpenArchive
        }
        return try parseMesh(
            from: archive,
            limits: limits,
            cancellation: cancellation,
            computesNormals: computesNormals,
            progress: progress
        )
    }

    static func parseMesh(
        from archive: ThreeMFArchive,
        limits: ResourceLimits = .cli,
        cancellation: ParseCancellation? = nil,
        computesNormals: Bool = true,
        progress: ((Float) -> Void)? = nil
    ) throws -> MeshData {
        let extractionBudget = ExtractionBudget(limits.maxModelExtractBytes)
        var modelData: Data?
        for path in rootModelCandidates(archive) {
            if let entry = archive.entry(path) {
                let data = try extractCapped(
                    archive,
                    entry: entry,
                    cap: limits.maxModelExtractBytes,
                    budget: extractionBudget,
                    cancellation: cancellation
                )
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
        let result = FastMeshScanner.scan(xmlData, limits: limits, cancellation: cancellation)
        try cancellation?.check()
        var remainingScanVertices = max(
            0,
            limits.maxVertices - result.objectMeshes.values.reduce(0) { $0 + $1.vertices.count }
        )
        var remainingScanTriangles = max(
            0,
            limits.maxTriangles - result.objectMeshes.values.reduce(0) { $0 + ($1.indices.count / 3) }
        )

        // Defensive fallback: if the byte-level scanner returned nothing (unusual
        // namespace, CDATA-wrapped mesh, structurally exotic 3MF), try NSXMLParser
        // on the root model file as a one-shot recovery.
        if result.objectMeshes.isEmpty, result.components.isEmpty, result.buildItems.isEmpty {
            if let fallback = try nsxmlFallback(
                xmlData: xmlData,
                limits: limits,
                cancellation: cancellation
            ) {
                log.notice("FastMeshScanner returned empty; using NSXMLParser fallback")
                progress?(0.8)
                var mesh = MeshData(
                    vertices: fallback.vertices,
                    indices: fallback.indices,
                    normals: nil,
                    metadata: result.metadata.isEmpty ? nil : result.metadata
                )
                if computesNormals {
                    try mesh.computeNormals(
                        progress: { fraction in progress?(0.8 + 0.2 * fraction) },
                        cancellation: cancellation
                    )
                }
                return mesh
            }
        }

        // Parse each external component file into its own mesh
        var objectMeshes = result.objectMeshes
        // Per-object Bambu paint states (merged from component files below).
        var objectPaintStates = result.objectPaintStates

        // Build set of object IDs actually needed by build items (transitively across
        // nested <component> chains up to maxComponentDepth) to avoid extracting/parsing
        // large files we won't use while still resolving multi-level assemblies.
        let neededObjectIds: Set<String>
        if !result.buildItems.isEmpty {
            var needed = Set<String>(result.buildItems.map(\.objectId))
            for _ in 0 ..< maxComponentDepth {
                var added = false
                for comp in result.components where needed.contains(comp.parentObjectId) {
                    if needed.insert(comp.objectId).inserted {
                        added = true
                    }
                }
                if !added {
                    break
                }
            }
            neededObjectIds = needed
        } else {
            // No build section — need all components
            neededObjectIds = Set(result.components.map(\.objectId))
        }

        // External component meshes — only extract those actually needed. Each archive path
        // is extracted at most once; its lowest object id aliases later components into it.
        var extractedPathFallbackKey: [String: String] = [:]
        var attemptedPaths = Set<String>()
        for comp in result.components {
            try cancellation?.check()
            guard neededObjectIds.contains(comp.objectId) || neededObjectIds.contains(comp.parentObjectId) else {
                continue
            }
            guard let normalized = sanitizeComponentPath(comp.path) else {
                log.error("Rejected suspicious component path: \(comp.path, privacy: .public)")
                continue
            }
            if objectMeshes[comp.objectId] != nil {
                continue
            }
            guard attemptedPaths.insert(normalized).inserted else {
                if let fallbackKey = extractedPathFallbackKey[normalized],
                   let fallbackMesh = objectMeshes[fallbackKey]
                {
                    objectMeshes[comp.objectId] = fallbackMesh
                    if let paint = objectPaintStates[fallbackKey] {
                        objectPaintStates[comp.objectId] = paint
                    }
                }
                continue
            }

            if let entry = archive.entry(normalized) {
                let data: Data
                do {
                    data = try extractCapped(
                        archive,
                        entry: entry,
                        cap: limits.maxModelExtractBytes,
                        budget: extractionBudget,
                        cancellation: cancellation
                    ) { fraction in
                        // 0–40%: ZIP extraction progress
                        progress?(0.4 * fraction)
                    }
                } catch is CancellationError {
                    // A cancelled extract must abort the whole parse, not skip one component
                    // and keep extracting the rest.
                    throw CancellationError()
                } catch ThreeMFMeshParserError.sizeLimitExceeded {
                    // The budget is shared across components; exhausting it must terminate
                    // the parse rather than turning the limit into a best-effort skip.
                    throw ThreeMFMeshParserError.sizeLimitExceeded
                } catch {
                    log
                        .error(
                            "Component extract failed for \(normalized, privacy: .public): \(error.localizedDescription)"
                        )
                    continue
                }
                if !data.isEmpty {
                    progress?(0.4)
                    var componentLimits = limits
                    componentLimits.maxVertices = remainingScanVertices
                    componentLimits.maxTriangles = remainingScanTriangles
                    let compResult = FastMeshScanner.scan(
                        data,
                        limits: componentLimits,
                        cancellation: cancellation
                    ) { scanFraction in
                        // 40–80%: scanning progress
                        progress?(0.4 + 0.4 * scanFraction)
                    }
                    try cancellation?.check()
                    // Import all objects discovered in this external .model file so sibling
                    // <component> references into the same file reuse them without re-extracting.
                    for key in compResult.objectMeshes.keys.sorted() {
                        guard let meshVal = compResult.objectMeshes[key] else { continue }
                        if objectMeshes[key] == nil {
                            objectMeshes[key] = meshVal
                        }
                        if let paint = compResult.objectPaintStates[key], objectPaintStates[key] == nil {
                            objectPaintStates[key] = paint
                        }
                        remainingScanVertices = max(0, remainingScanVertices - meshVal.vertices.count)
                        remainingScanTriangles = max(
                            0,
                            remainingScanTriangles - (meshVal.indices.count / 3)
                        )
                    }
                    // If the external file used a different internal <object id> than the
                    // referencing component's objectId, alias it deterministically.
                    if let fallbackKey = compResult.objectMeshes.keys.min(),
                       let fallbackMesh = compResult.objectMeshes[fallbackKey]
                    {
                        extractedPathFallbackKey[normalized] = fallbackKey
                        if objectMeshes[comp.objectId] == nil {
                            objectMeshes[comp.objectId] = fallbackMesh
                            if let paint = compResult.objectPaintStates[fallbackKey] {
                                objectPaintStates[comp.objectId] = paint
                            }
                        }
                    }
                }
            }
        }

        // Bambu/Orca color + plate layout lives outside the model XML, in the Metadata
        // config files. Tolerant: absent or malformed → empty config, no effect.
        let bambuConfig = BambuModelConfig.parse(
            modelSettings: readEntryIfPresent(archive, path: "Metadata/model_settings.config", limits: limits),
            projectSettings: readEntryIfPresent(archive, path: "Metadata/project_settings.config", limits: limits)
        )
        let bambuColor = bambuConfig.hasColorAssignment
        let bambuHasPlates = !bambuConfig.objectPlateIndex.isEmpty
        let bambuObjMaterial = bambuConfig.objectMaterialIndex
        let bambuObjPlate = bambuConfig.objectPlateIndex
        let bambuPaletteCount = bambuConfig.filamentColours.count

        // Assemble: use build items (with transforms) if available,
        // otherwise just merge all meshes (sorted by id for determinism)
        var allVertices: [simd_float3] = []
        var allIndices: [UInt32] = []
        // Bambu files assign color per object (extruder → filament palette) rather than via
        // core-spec <basematerials>; prefer that palette when present.
        let allMaterials: [BaseMaterial] = bambuColor ? bambuConfig.materials() : result.materials
        var allTriangleMats: [Int] = []
        // Per-triangle plate index, populated only for multi-plate Bambu/Orca files.
        var allTrianglePlates: [Int] = []

        func canAppend(verts: Int, tris: Int) -> Bool {
            // Aggregate caps to bound memory.
            allVertices.count + verts <= limits.maxVertices
                && (allIndices.count / 3) + tris <= limits.maxTriangles
        }

        if !result.buildItems.isEmpty {
            let componentsByParent = Dictionary(grouping: result.components, by: \.parentObjectId)
            var emissionBudget = maxEmissions
            for item in result.buildItems {
                // Flatten the item's object into concrete sub-meshes, each with its fully
                // composed transform (build-item ∘ nested component transforms). The common
                // Bambu/Orca case (object has its own mesh, no components) yields exactly one
                // emission at `item.transform`, so this is behavior-preserving there.
                let emissions = expandObject(
                    objectId: item.objectId,
                    transform: item.transform,
                    componentsByParent: componentsByParent,
                    objectMeshes: objectMeshes,
                    depth: 0,
                    visiting: [],
                    budget: &emissionBudget
                )
                for emission in emissions {
                    try cancellation?.check()
                    guard let mesh = objectMeshes[emission.meshObjectId] else { continue }
                    guard canAppend(verts: mesh.vertices.count, tris: mesh.indices.count / 3) else {
                        log
                            .error(
                                "Skipping object \(emission.meshObjectId, privacy: .public) — would exceed aggregate caps"
                            )
                        continue
                    }

                    let baseOffset = UInt32(allVertices.count)
                    let transform = emission.transform

                    if transform == [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0] {
                        // Identity transform — skip per-vertex math
                        allVertices.append(contentsOf: mesh.vertices)
                    } else {
                        guard transform.allSatisfy(\.isFinite) else { continue }
                        let m = transform
                        var transformed: [simd_float3] = []
                        transformed.reserveCapacity(mesh.vertices.count)
                        var allFinite = true
                        for v in mesh.vertices {
                            let x = (m[0] * v.x) + (m[3] * v.y) + (m[6] * v.z) + m[9]
                            let y = (m[1] * v.x) + (m[4] * v.y) + (m[7] * v.z) + m[10]
                            let z = (m[2] * v.x) + (m[5] * v.y) + (m[8] * v.z) + m[11]
                            guard x.isFinite, y.isFinite, z.isFinite else {
                                allFinite = false
                                break
                            }
                            transformed.append(simd_float3(x, y, z))
                        }
                        guard allFinite else { continue }
                        allVertices.append(contentsOf: transformed)
                    }
                    allIndices.reserveCapacity(allIndices.count + mesh.indices.count)
                    let triBase = allIndices.count / 3
                    let localVCount = UInt32(mesh.vertices.count)
                    for idx in mesh.indices {
                        if idx < localVCount {
                            let (offsetIdx, overflow) = idx.addingReportingOverflow(baseOffset)
                            allIndices.append(overflow ? UInt32.max : offsetIdx)
                        } else {
                            allIndices.append(UInt32.max)
                        }
                    }
                    let triCountThisItem = mesh.indices.count / 3
                    // Color: Bambu assigns one material per object (via extruder); otherwise
                    // fall back to the mesh's own core-spec per-triangle materials.
                    if bambuColor {
                        // Base color = object's extruder; per-triangle paint overrides it.
                        let baseMatIdx = bambuObjMaterial[item.objectId]
                            ?? bambuObjMaterial[emission.meshObjectId]
                            ?? -1
                        if allTriangleMats.count < triBase {
                            allTriangleMats.append(contentsOf: repeatElement(
                                -1,
                                count: triBase - allTriangleMats.count
                            ))
                        }
                        let paint = objectPaintStates[emission.meshObjectId]
                        if let paint, paint.count == triCountThisItem {
                            for state in paint {
                                // state is a 1-based extruder; palette index = state - 1.
                                if state >= 1, state - 1 < bambuPaletteCount {
                                    allTriangleMats.append(state - 1)
                                } else {
                                    allTriangleMats.append(baseMatIdx)
                                }
                            }
                        } else {
                            allTriangleMats.append(contentsOf: repeatElement(baseMatIdx, count: triCountThisItem))
                        }
                    } else if !mesh.triangleMaterials.isEmpty {
                        if allTriangleMats.count < triBase {
                            allTriangleMats.append(contentsOf: repeatElement(
                                -1,
                                count: triBase - allTriangleMats.count
                            ))
                        }
                        allTriangleMats.append(contentsOf: mesh.triangleMaterials)
                    }
                    // Plate membership (independent of color) so the preview can show one plate.
                    if bambuHasPlates {
                        let plateIdx = bambuObjPlate[item.objectId]
                            ?? bambuObjPlate[emission.meshObjectId]
                            ?? -1
                        if allTrianglePlates.count < triBase {
                            allTrianglePlates.append(contentsOf: repeatElement(
                                -1,
                                count: triBase - allTrianglePlates.count
                            ))
                        }
                        allTrianglePlates.append(contentsOf: repeatElement(plateIdx, count: triCountThisItem))
                    }
                }
            }
        } else {
            // Sort for deterministic display order across launches.
            for objId in objectMeshes.keys.sorted() {
                try cancellation?.check()
                guard let mesh = objectMeshes[objId],
                      canAppend(verts: mesh.vertices.count, tris: mesh.indices.count / 3) else { continue }
                let baseOffset = UInt32(allVertices.count)
                let triBase = allIndices.count / 3
                let localVCount = UInt32(mesh.vertices.count)
                allVertices.append(contentsOf: mesh.vertices)
                for idx in mesh.indices {
                    if idx < localVCount {
                        let (offsetIdx, overflow) = idx.addingReportingOverflow(baseOffset)
                        allIndices.append(overflow ? UInt32.max : offsetIdx)
                    } else {
                        allIndices.append(UInt32.max)
                    }
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

        // Pad trailing tails with -1 so per-triangle arrays match the triangle count.
        let triTarget = allIndices.count / 3
        if !allTriangleMats.isEmpty, allTriangleMats.count < triTarget {
            allTriangleMats.append(contentsOf: repeatElement(-1, count: triTarget - allTriangleMats.count))
        }
        if !allTrianglePlates.isEmpty, allTrianglePlates.count < triTarget {
            allTrianglePlates.append(contentsOf: repeatElement(-1, count: triTarget - allTrianglePlates.count))
        }

        // Filter out triangles with out-of-range indices before SceneKit sees them.
        // Per-triangle material and plate arrays are filtered in lockstep.
        let vCount = UInt32(allVertices.count)
        var filteredIndices: [UInt32] = []
        filteredIndices.reserveCapacity(allIndices.count)
        var filteredMats: [Int] = []
        filteredMats.reserveCapacity(allTriangleMats.count)
        var filteredPlates: [Int] = []
        filteredPlates.reserveCapacity(allTrianglePlates.count)
        var t = 0
        var filterPoller = CancellationPoller(cancellation)
        while t * 3 + 2 < allIndices.count {
            try filterPoller.tick()
            let a = allIndices[t * 3], b = allIndices[t * 3 + 1], c = allIndices[t * 3 + 2]
            if a < vCount, b < vCount, c < vCount {
                filteredIndices.append(a)
                filteredIndices.append(b)
                filteredIndices.append(c)
                if !allTriangleMats.isEmpty, t < allTriangleMats.count {
                    filteredMats.append(allTriangleMats[t])
                }
                if !allTrianglePlates.isEmpty, t < allTrianglePlates.count {
                    filteredPlates.append(allTrianglePlates[t])
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
        mesh.trianglePlates = filteredPlates
        mesh.plates = bambuConfig.plates.map { PlateInfo(id: $0.id, name: $0.name) }
        mesh.metadata = result.metadata.isEmpty ? nil : result.metadata
        if computesNormals {
            try mesh.computeNormals(
                progress: { normalFraction in
                    // 80–100%: normal computation progress
                    progress?(0.8 + 0.2 * normalFraction)
                },
                cancellation: cancellation
            )
        }
        return mesh
    }

    /// True when `xmlData` contains a `<!DOCTYPE` or `<!ENTITY` declaration (case-insensitive),
    /// across UTF-8, Latin-1, and UTF-16/UTF-32 (interleaved zero bytes).
    /// NSXMLParser expands *internal* entities even with `shouldResolveExternalEntities = false`,
    /// so any DTD/entity declaration is refused before parse rather than risk an entity bomb.
    static func containsDTDOrEntityDeclaration(_ xmlData: Data) -> Bool {
        xmlData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            let count = raw.count
            let doctype: [UInt8] = [0x21, 0x64, 0x6F, 0x63, 0x74, 0x79, 0x70, 0x65] // !doctype
            let entity: [UInt8] = [0x21, 0x65, 0x6E, 0x74, 0x69, 0x74, 0x79] // !entity
            var i = 0
            while i < count {
                if base[i] == 0x3C { // '<'
                    if matchesASCIIIgnoringNulls(base: base, count: count, after: i + 1, lowercaseTarget: doctype)
                        || matchesASCIIIgnoringNulls(base: base, count: count, after: i + 1, lowercaseTarget: entity)
                    {
                        return true
                    }
                }
                i += 1
            }
            return false
        }
    }

    private static func matchesASCIIIgnoringNulls(
        base: UnsafePointer<UInt8>,
        count: Int,
        after start: Int,
        lowercaseTarget: [UInt8]
    ) -> Bool {
        var pos = start
        for expected in lowercaseTarget {
            var zeros = 0
            while pos < count, base[pos] == 0x00, zeros < 4 {
                pos += 1
                zeros += 1
            }
            guard pos < count else { return false }
            let b = base[pos]
            let lower = (b >= 0x41 && b <= 0x5A) ? (b + 32) : b
            guard lower == expected else { return false }
            pos += 1
        }
        return true
    }

    /// Runs `XMLParser` (NSXMLParser) over the root model file to recover vertices and
    /// triangles when the byte-level fast scanner returned empty. Bounded by the same
    /// `maxVertices` / `maxTriangles` aggregate caps. Returns nil if it can't recover anything.
    private static func nsxmlFallback(
        xmlData: Data,
        limits: ResourceLimits,
        cancellation: ParseCancellation? = nil
    ) throws -> (vertices: [simd_float3], indices: [UInt32])? {
        try cancellation?.check()
        // Internal entity expansion is still on in NSXMLParser — skip the fallback entirely
        // when a DTD or entity declaration is present rather than parsing a bomb.
        if containsDTDOrEntityDeclaration(xmlData) {
            return nil
        }
        let delegate = NSXMLFallbackDelegate(
            maxVertices: limits.maxVertices,
            maxTriangles: limits.maxTriangles,
            cancellation: cancellation
        )
        let parser = XMLParser(data: xmlData)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        // Defense-in-depth: never fetch external DTDs/entities. This matches Foundation's
        // default, but we set it explicitly so the XXE-off posture survives future refactors.
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        try cancellation?.check()
        guard parsed else { return nil }
        // Filter out-of-range indices so SceneKit never sees a bad triangle.
        let vCount = UInt32(delegate.vertices.count)
        var safeIndices: [UInt32] = []
        safeIndices.reserveCapacity(delegate.indices.count)
        var t = 0
        var filterPoller = CancellationPoller(cancellation)
        while t * 3 + 2 < delegate.indices.count {
            try filterPoller.tick()
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

    /// Max component-nesting depth. 3MF assemblies are shallow in practice; the cap also
    /// bounds recursion on a malformed/circular file (belt-and-suspenders with the cycle set).
    private static let maxComponentDepth = 16

    /// Flattens an object into the list of `(meshObjectId, transform)` to emit, resolving
    /// `<component>` references recursively and composing their transforms. An object may
    /// contribute its own mesh *and* components. Each component's transform maps the child
    /// into this object's coordinate space, so it composes child-first with the inherited
    /// transform. Depth-bounded and cycle-guarded so a circular reference can't recurse
    /// without end. Replaces the old single-id resolver, which dropped every component
    /// transform and rendered only the first sub-mesh.
    private static func expandObject(
        objectId: String,
        transform: [Float],
        componentsByParent: [String: [ComponentRef]],
        objectMeshes: [String: (vertices: [simd_float3], indices: [UInt32], triangleMaterials: [Int])],
        depth: Int,
        visiting: Set<String>,
        budget: inout Int
    ) -> [(meshObjectId: String, transform: [Float])] {
        guard budget > 0, depth < maxComponentDepth, !visiting.contains(objectId) else { return [] }
        var out: [(meshObjectId: String, transform: [Float])] = []

        // The object's own mesh (if any) is emitted at the inherited transform.
        if objectMeshes[objectId] != nil {
            out.append((objectId, transform))
            budget -= 1
        }

        var childVisiting = visiting
        childVisiting.insert(objectId)
        for comp in componentsByParent[objectId] ?? [] {
            guard budget > 0 else { break }
            let composed = composeTransforms(comp.transform, transform)
            guard composed.allSatisfy(\.isFinite) else { continue }
            out.append(contentsOf: expandObject(
                objectId: comp.objectId,
                transform: composed,
                componentsByParent: componentsByParent,
                objectMeshes: objectMeshes,
                depth: depth + 1,
                visiting: childVisiting,
                budget: &budget
            ))
        }
        return out
    }

    /// Composes two 3MF transforms (12-float, 4×3, row-vector convention) so that applying
    /// the result equals applying `inner` then `outer`: `v · result == (v · inner) · outer`.
    /// Each matrix's implicit last column is (0,0,0,1); row 3 is the translation.
    static func composeTransforms(_ inner: [Float], _ outer: [Float]) -> [Float] {
        func e(_ m: [Float], _ r: Int, _ c: Int) -> Float {
            m[r * 3 + c]
        }
        var out = [Float](repeating: 0, count: 12)
        for i in 0 ..< 4 {
            for j in 0 ..< 3 {
                var s = e(inner, i, 0) * e(outer, 0, j)
                    + e(inner, i, 1) * e(outer, 1, j)
                    + e(inner, i, 2) * e(outer, 2, j)
                if i == 3 {
                    s += e(outer, 3, j)
                } // inner's implicit w=1 carries outer's translation
                out[i * 3 + j] = s
            }
        }
        return out
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
    private var poller: CancellationPoller

    init(maxVertices: Int, maxTriangles: Int, cancellation: ParseCancellation? = nil) {
        self.maxVertices = maxVertices
        self.maxTriangles = maxTriangles
        poller = CancellationPoller(cancellation)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attrs: [String: String] = [:]
    ) {
        if poller.tickIsCancelled() {
            parser.abortParsing()
            return
        }
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch local.lowercased() {
        case "mesh":
            inMesh = true
        case "vertex" where inMesh:
            if vertices.count >= maxVertices {
                parser.abortParsing(); return
            }
            guard
                let xs = attrs["x"], let ys = attrs["y"], let zs = attrs["z"],
                let x = Float(xs), let y = Float(ys), let z = Float(zs),
                x.isFinite, y.isFinite, z.isFinite
            else { return }
            vertices.append(simd_float3(x, y, z))
        case "triangle" where inMesh:
            if indices.count / 3 >= maxTriangles {
                parser.abortParsing(); return
            }
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
        if local.lowercased() == "mesh" {
            inMesh = false
        }
    }
}

// MARK: - Package relationships

/// Finds the `Target` of the first `<Relationship>` with the given `Type` in an OPC `.rels` file.
private final class RelationshipsDelegate: NSObject, XMLParserDelegate {
    private let type: String
    private(set) var target: String?

    init(type: String) {
        self.type = type
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attrs: [String: String] = [:]
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard local == "Relationship", attrs["Type"] == type, let value = attrs["Target"] else { return }
        target = value
        parser.abortParsing()
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
        /// Per-object decoded Bambu/Orca `paint_color` states, parallel to that object's
        /// triangles (1-based extruder, `0` = unpainted/base). Empty for objects with no paint.
        var objectPaintStates: [String: [Int]]
    }

    /// Returns whatever it assembled before cancellation, so callers must re-check the
    /// token before trusting the result.
    /// `metadataOnly` stops at the first `<resources>` tag, after the root `<metadata>` block.
    static func scan(
        _ data: Data,
        limits: ResourceLimits,
        cancellation: ParseCancellation? = nil,
        metadataOnly: Bool = false,
        progress: ((Float) -> Void)? = nil
    ) -> ScanResult {
        data.withUnsafeBytes { rawBuffer -> ScanResult in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return ScanResult(
                    objectMeshes: [:],
                    components: [],
                    buildItems: [],
                    materials: [],
                    metadata: ThreeMFMetadata(),
                    objectPaintStates: [:]
                )
            }
            let count = rawBuffer.count
            var scanner = ByteScanner(base: base, count: count, limits: limits)
            return scanner.scan(cancellation: cancellation, metadataOnly: metadataOnly, progress: progress)
        }
    }
}

private struct ByteScanner {
    let base: UnsafePointer<UInt8>
    let count: Int
    let limits: ResourceLimits
    var pos: Int = 0
    private var totalVertices = 0
    private var totalTriangles = 0

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
    /// Object-level default material (3MF core `pid`/`pindex`): triangles that carry no
    /// material of their own inherit these. nil when the object sets no default.
    private var currentObjectPid: String?
    private var currentObjectPindex: Int?
    private var currentVertices: [simd_float3] = []
    private var currentIndices: [UInt32] = []
    private var currentTriMaterials: [Int] = []
    private var hasAnyMaterial = false
    private var inMesh = false

    /// Per-object Bambu `paint_color` states (parallel to triangles; 0 = unpainted).
    var objectPaintStates: [String: [Int]] = [:]
    private var currentPaintStates: [Int] = []
    private var hasAnyPaint = false

    init(base: UnsafePointer<UInt8>, count: Int, limits: ResourceLimits) {
        self.base = base
        self.count = count
        self.limits = limits
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

    mutating func scan(
        cancellation: ParseCancellation? = nil,
        metadataOnly: Bool = false,
        progress: ((Float) -> Void)? = nil
    ) -> FastMeshScanner.ScanResult {
        // Pre-estimate capacity: ~60 bytes per vertex line, ~65 bytes per triangle line
        // A typical mesh is roughly 50% vertices + 50% triangles by byte count
        let estimatedVertices = min(count / 120, limits.maxVertices)
        if !metadataOnly, estimatedVertices > 1000 {
            currentVertices.reserveCapacity(estimatedVertices)
            currentIndices.reserveCapacity(estimatedVertices * 3)
        }

        let reportInterval = max(count / 40, 1) // report ~40 times
        var nextReport = reportInterval
        var poller = CancellationPoller(cancellation)

        while pos < count {
            // Cancellation abandons the scan with partial results; `parseMesh` re-checks
            // the token and throws rather than rendering a half-read mesh.
            if poller.tickIsCancelled() {
                break
            }

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
                        if hasAnyPaint {
                            objectPaintStates[objId] = currentPaintStates
                        }
                    }
                    currentObjectId = nil
                    hasAnyMaterial = false
                    currentTriMaterials = []
                    hasAnyPaint = false
                    currentPaintStates = []
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
            if metadataOnly, tagName == .resources {
                break
            }

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
            metadata: metadata,
            objectPaintStates: objectPaintStates
        )
    }

    // MARK: - Tag name matching

    private enum TagKind {
        case vertex, triangle, mesh, object, component, item, basematerials, base, metadata, resources, other
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
            if matchesCaseInsensitiveAt(nameStart, "mesh") {
                return .mesh
            }
            if matchesCaseInsensitiveAt(nameStart, "item") {
                return .item
            }
            if matchesCaseInsensitiveAt(nameStart, "base") {
                return .base
            }
        case 6:
            if matchesCaseInsensitiveAt(nameStart, "vertex") {
                return .vertex
            }
            if matchesCaseInsensitiveAt(nameStart, "object") {
                return .object
            }
        case 8:
            if matchesCaseInsensitiveAt(nameStart, "triangle") {
                return .triangle
            }
            if matchesCaseInsensitiveAt(nameStart, "metadata") {
                return .metadata
            }
        case 9:
            if matchesCaseInsensitiveAt(nameStart, "component") {
                return .component
            }
            if matchesCaseInsensitiveAt(nameStart, "resources") {
                return .resources
            }
        case 13:
            if matchesCaseInsensitiveAt(nameStart, "basematerials") {
                return .basematerials
            }
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
            if pos < count {
                pos += 1
            } // skip closing quote

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

        if gotX, gotY, gotZ, x.isFinite, y.isFinite, z.isFinite, totalVertices < limits.maxVertices {
            currentVertices.append(simd_float3(x, y, z))
            totalVertices += 1
        }
    }

    private mutating func parseTriangle() {
        var v1: UInt32 = 0, v2: UInt32 = 0, v3: UInt32 = 0
        var gotV1 = false, gotV2 = false, gotV3 = false
        var pid: String?
        var p1Idx: Int?
        var paintHex: String?

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
            if pos < count {
                pos += 1
            }

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
            } else if attrLen == 11, matchesCaseInsensitiveAt(attrStart, "paint_color") {
                // Bambu/Orca per-triangle MMU paint.
                paintHex = stringFromBytes(valStart, valEnd)
            }
        }
        skipToTagEnd()

        if gotV1, gotV2, gotV3, totalTriangles < limits.maxTriangles {
            currentIndices.append(v1)
            currentIndices.append(v2)
            currentIndices.append(v3)
            totalTriangles += 1
            // Resolve material: pid identifies a basematerials group, p1 is the entry within it.
            // A triangle without its own pid/p1 inherits the object's default (pid/pindex),
            // per 3MF core spec — the common shape for single-color objects.
            let effectivePid = pid ?? currentObjectPid
            let effectiveP1 = p1Idx ?? currentObjectPindex
            if let effectivePid, let effectiveP1, let range = materialGroups[effectivePid] {
                if effectiveP1 >= 0, effectiveP1 < range.count {
                    currentTriMaterials.append(range.lowerBound + effectiveP1)
                    hasAnyMaterial = true
                } else {
                    currentTriMaterials.append(-1)
                }
            } else {
                currentTriMaterials.append(-1)
            }
            // Per-triangle Bambu paint state (0 = unpainted → object's base extruder).
            if let paintHex {
                let state = BambuModelConfig.decodePaintColor(paintHex)
                currentPaintStates.append(state)
                if state >= 1 {
                    hasAnyPaint = true
                }
            } else {
                currentPaintStates.append(0)
            }
        }
    }

    private mutating func parseObject() {
        let attrs = readAttributes(["id", "pid", "pindex"])
        currentObjectId = attrs["id"]
        // Object-level default material — inherited by triangles lacking their own pid/p1.
        currentObjectPid = attrs["pid"]
        currentObjectPindex = attrs["pindex"].flatMap { Int($0) }
        currentVertices = []
        currentIndices = []
        currentTriMaterials = []
        hasAnyMaterial = false
        currentPaintStates = []
        hasAnyPaint = false
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
        guard materials.count < ThreeMFMeshParser.maxMaterials else {
            skipToTagEnd()
            return
        }
        let attrs = readAttributes(["name", "displaycolor"])
        let name = attrs["name"] ?? ""
        let color = parseHexColor(attrs["displaycolor"])
        materials.append(BaseMaterial(name: name, color: color))
        skipToTagEnd()
    }

    private mutating func parseComponent() {
        guard components.count < ThreeMFMeshParser.maxComponents else {
            skipToTagEnd()
            return
        }
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
        let rawName = attrs["name"] ?? ""
        skipToTagEnd()
        // Capture text up to next '<' (start of close tag).
        let textStart = pos
        _ = skipTo(ByteScanner.lt)
        let textEnd = pos
        guard !rawName.isEmpty, textEnd > textStart else { return }
        let maxLen = ThreeMFMeshParser.maxMetadataStringLength
        let name = rawName.count > maxLen ? String(rawName.prefix(maxLen)) : rawName
        let cappedEnd = min(textEnd, textStart + maxLen * 4)
        var value = stringFromBytes(textStart, cappedEnd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > maxLen {
            value = String(value.prefix(maxLen))
        }
        guard !value.isEmpty else { return }
        switch name {
        case "Application": metadata.application = value
        case "CreationDate": metadata.creationDate = value
        case "ModificationDate": metadata.modificationDate = value
        case "Title": metadata.title = value
        case "Designer": metadata.designer = value
        default:
            if metadata.other[name] != nil || metadata.other.count < ThreeMFMeshParser.maxMetadataOtherEntries {
                metadata.other[name] = value
            }
        }
    }

    private mutating func parseItem() {
        guard buildItems.count < ThreeMFMeshParser.maxBuildItems else {
            skipToTagEnd()
            return
        }
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
            if pos < count {
                pos += 1
            }

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
        if pos < count {
            pos += 1
        }
    }

    @inline(__always)
    private func matchesAt(_ offset: Int, _ str: String) -> Bool {
        let utf8 = str.utf8
        guard offset + utf8.count <= count else { return false }
        for (i, ch) in utf8.enumerated() {
            if base[offset + i] != ch {
                return false
            }
        }
        return true
    }

    @inline(__always)
    private func matchesCaseInsensitiveAt(_ offset: Int, _ lowercase: String) -> Bool {
        let utf8 = lowercase.utf8
        guard offset + utf8.count <= count else { return false }
        for (i, ch) in utf8.enumerated() {
            let b = base[offset + i]
            if b != ch, b != ch - 32 {
                return false
            } // lowercase or uppercase
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
                if exp <= 400 {
                    exp = exp * 10 + Int(c - 0x30)
                }
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
