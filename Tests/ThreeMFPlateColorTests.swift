import Foundation
import simd
import Testing
import ZIPFoundation

/// Integration test: a synthesized multi-plate Bambu-style 3MF should come out of
/// `ThreeMFMeshParser.parseMesh` with per-object colors (from the filament palette) and
/// per-triangle plate membership. Guards the wiring between BambuModelConfig and assembly.
@Suite("ThreeMF plate + color integration")
struct ThreeMFPlateColorTests {
    private static let rootModel = """
    <?xml version="1.0" encoding="UTF-8"?>
    <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
     <resources>
      <object id="1" type="model"><mesh>
        <vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/></vertices>
        <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
      </mesh></object>
      <object id="2" type="model"><mesh>
        <vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/></vertices>
        <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
      </mesh></object>
     </resources>
     <build>
      <item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
      <item objectid="2" transform="1 0 0 0 1 0 0 0 1 100 0 0"/>
     </build>
    </model>
    """

    private static let modelSettings = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config>
     <object id="1"><metadata key="extruder" value="1"/></object>
     <object id="2"><metadata key="extruder" value="2"/></object>
     <plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="Plate A"/>
       <model_instance><metadata key="object_id" value="1"/></model_instance></plate>
     <plate><metadata key="plater_id" value="2"/><metadata key="plater_name" value="Plate B"/>
       <model_instance><metadata key="object_id" value="2"/></model_instance></plate>
    </config>
    """

    private static let projectSettings = ##"{"filament_colour": ["#FF0000", "#00FF00"]}"##

    private func makeArchive() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate-color-\(UUID().uuidString)")
            .appendingPathExtension("3mf")
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ string: String) throws {
            let data = Data(string.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: UInt32(data.count),
                provider: { position, size in data.subdata(in: position ..< position + size) }
            )
        }
        try add("3D/3dmodel.model", Self.rootModel)
        try add("Metadata/model_settings.config", Self.modelSettings)
        try add("Metadata/project_settings.config", Self.projectSettings)
        return url
    }

    @Test("Parser assigns palette materials and plate membership per object")
    func platesAndColors() throws {
        let url = try makeArchive()
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)

        // Two plates, in plater_id order.
        #expect(mesh.plates == [PlateInfo(id: 1, name: "Plate A"), PlateInfo(id: 2, name: "Plate B")])

        // Palette → two materials, red then green.
        #expect(mesh.materials.count == 2)
        #expect(mesh.materials[0].color == SIMD4<Float>(1, 0, 0, 1))
        #expect(mesh.materials[1].color == SIMD4<Float>(0, 1, 0, 1))

        // Two triangles (one per object), tagged in build order.
        #expect(mesh.indices.count == 6)
        #expect(mesh.triangleMaterials == [0, 1]) // obj1→ext1→mat0, obj2→ext2→mat1
        #expect(mesh.trianglePlates == [0, 1]) // obj1→plateA(0), obj2→plateB(1)
    }

    /// Single object, multi-color via per-triangle paint_color (the Ender_Egg case).
    private static let paintedModel = """
    <?xml version="1.0" encoding="UTF-8"?>
    <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
     <resources>
      <object id="1" type="model"><mesh>
        <vertices>
          <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/>
          <vertex x="0" y="10" z="0"/><vertex x="10" y="10" z="0"/>
        </vertices>
        <triangles>
          <triangle v1="0" v2="1" v3="2"/>
          <triangle v1="2" v2="1" v3="3" paint_color="8"/>
        </triangles>
      </mesh></object>
     </resources>
     <build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build>
    </model>
    """
    private static let paintedModelSettings = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config><object id="1"><metadata key="extruder" value="1"/></object></config>
    """
    private static let paintedProjectSettings = ##"{"filament_colour": ["#AA0000", "#00BB00"]}"##

    @Test("Per-triangle paint_color overrides the object base color")
    func paintOverride() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("painted-\(UUID().uuidString)").appendingPathExtension("3mf")
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ s: String) throws {
            let data = Data(s.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: UInt32(data.count),
                provider: { p, n in data.subdata(in: p ..< p + n) }
            )
        }
        try add("3D/3dmodel.model", Self.paintedModel)
        try add("Metadata/model_settings.config", Self.paintedModelSettings)
        try add("Metadata/project_settings.config", Self.paintedProjectSettings)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFMeshParser.parseMesh(from: url)
        #expect(mesh.materials.count == 2)
        // Triangle 0 unpainted → base extruder 1 → mat 0 (#AA0000).
        // Triangle 1 paint_color "8" → extruder 2 → mat 1 (#00BB00).
        #expect(mesh.triangleMaterials == [0, 1])
    }
}
