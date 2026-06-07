import Foundation
import simd
import Testing

/// Tests for parsing Bambu/Orca `model_settings.config` + `project_settings.config`.
/// Fixtures are trimmed-but-faithful copies of the real Chiken(2).3mf layout: 4 plates,
/// objects assigned to extruders 1–4, palette grey/black/red/white.
@Suite("BambuModelConfig")
struct BambuModelConfigTests {
    /// Mirrors Chiken(2).3mf: object→extruder + 4 plates with model_instance object refs.
    static let modelSettings = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config>
      <object id="6">
        <metadata key="name" value="Chicken leg.stl"/>
        <metadata key="extruder" value="1"/>
        <part id="1" subtype="normal_part">
          <metadata key="name" value="Chicken leg.stl"/>
          <metadata key="extruder" value="9"/>
        </part>
      </object>
      <object id="11">
        <metadata key="name" value="Chicken eye.stl"/>
        <metadata key="extruder" value="2"/>
      </object>
      <object id="14">
        <metadata key="name" value="Chicken red.stl"/>
        <metadata key="extruder" value="3"/>
      </object>
      <object id="2">
        <metadata key="name" value="Chiken body.stl"/>
        <metadata key="extruder" value="4"/>
      </object>
      <object id="4">
        <metadata key="name" value="Chiken head.stl"/>
        <metadata key="extruder" value="4"/>
      </object>
      <plate>
        <metadata key="plater_id" value="1"/>
        <metadata key="plater_name" value="Body and Head"/>
        <model_instance>
          <metadata key="object_id" value="2"/>
          <metadata key="instance_id" value="0"/>
        </model_instance>
        <model_instance>
          <metadata key="object_id" value="4"/>
          <metadata key="instance_id" value="0"/>
        </model_instance>
      </plate>
      <plate>
        <metadata key="plater_id" value="3"/>
        <metadata key="plater_name" value="Eye"/>
        <model_instance>
          <metadata key="object_id" value="11"/>
          <metadata key="instance_id" value="0"/>
        </model_instance>
      </plate>
      <plate>
        <metadata key="plater_id" value="2"/>
        <metadata key="plater_name" value="Leg and Nose"/>
        <model_instance>
          <metadata key="object_id" value="6"/>
          <metadata key="instance_id" value="0"/>
        </model_instance>
      </plate>
      <plate>
        <metadata key="plater_id" value="4"/>
        <metadata key="plater_name" value="Red"/>
        <model_instance>
          <metadata key="object_id" value="14"/>
          <metadata key="instance_id" value="0"/>
        </model_instance>
      </plate>
    </config>
    """

    /// Real chicken palette; `filament_colour` deliberately surrounded by other keys.
    static let projectSettings = """
    {
      "filament_settings_id": ["a", "b", "c", "d"],
      "filament_colour": ["#898989", "#000000", "#F72323", "#FFFFFF"],
      "filament_colour_type": ["0", "0", "0", "0"]
    }
    """

    private func config() -> BambuModelConfig {
        BambuModelConfig.parse(
            modelSettings: Self.modelSettings.data(using: .utf8),
            projectSettings: Self.projectSettings.data(using: .utf8)
        )
    }

    @Test("Plates are parsed and sorted by plater_id")
    func platesSorted() {
        let c = config()
        #expect(c.plates.map(\.id) == [1, 2, 3, 4])
        #expect(c.plates.map(\.name) == ["Body and Head", "Leg and Nose", "Eye", "Red"])
        // Plate 1 holds body + head.
        #expect(c.plates[0].objectIds == ["2", "4"])
    }

    @Test("Object→extruder uses object-level metadata, not nested <part>")
    func objectExtruder() {
        let c = config()
        // Object 6's <part> says extruder 9; the object-level value (1) must win.
        #expect(c.objectExtruder["6"] == 1)
        #expect(c.objectExtruder["11"] == 2)
        #expect(c.objectExtruder["14"] == 3)
        #expect(c.objectExtruder["2"] == 4)
        #expect(c.objectExtruder["4"] == 4)
    }

    @Test("Filament palette parsed to RGBA")
    func palette() {
        let c = config()
        #expect(c.filamentColours.count == 4)
        // #F72323 → (0.969, 0.137, 0.137, 1)
        let red = c.filamentColours[2]
        #expect(abs(red.x - 0.969) < 0.01)
        #expect(abs(red.y - 0.137) < 0.01)
        #expect(abs(red.z - 0.137) < 0.01)
        #expect(red.w == 1)
        // #FFFFFF → white
        #expect(c.filamentColours[3] == SIMD4<Float>(1, 1, 1, 1))
    }

    @Test("Resolved object→plate and object→material maps")
    func resolvedMaps() {
        let c = config()
        #expect(c.hasColorAssignment)
        // Plate index is 0-based into the sorted plates array.
        let planeIdx = c.objectPlateIndex
        #expect(planeIdx["2"] == 0) // plate 1
        #expect(planeIdx["6"] == 1) // plate 2
        #expect(planeIdx["11"] == 2) // plate 3
        #expect(planeIdx["14"] == 3) // plate 4
        // Material index = extruder − 1.
        let matIdx = c.objectMaterialIndex
        #expect(matIdx["2"] == 3) // white
        #expect(matIdx["11"] == 1) // black
        #expect(matIdx["14"] == 2) // red
        // Materials() carries the palette colors.
        let mats = c.materials()
        #expect(mats.count == 4)
        #expect(mats[2].color == c.filamentColours[2])
    }

    @Test("paint_color decodes to the painted extruder (1-based)")
    func paintColorDecode() {
        // Verified against real Makerworld files (Ender_Egg, TNT_clicker, Golem).
        #expect(BambuModelConfig.decodePaintColor("4") == 1)
        #expect(BambuModelConfig.decodePaintColor("8") == 2) // Ender_Egg speckle → black (ext2)
        #expect(BambuModelConfig.decodePaintColor("0C") == 3)
        #expect(BambuModelConfig.decodePaintColor("1C") == 4)
        #expect(BambuModelConfig.decodePaintColor("3C") == 6)
        // None / malformed → 0 (base).
        #expect(BambuModelConfig.decodePaintColor("") == 0)
        #expect(BambuModelConfig.decodePaintColor("zz") == 0)
    }

    @Test("Missing / malformed inputs yield an empty config, never a throw")
    func tolerantOfGarbage() {
        #expect(BambuModelConfig.parse(modelSettings: nil, projectSettings: nil).isEmpty)
        let garbage = "not xml or json".data(using: .utf8)
        let c = BambuModelConfig.parse(modelSettings: garbage, projectSettings: garbage)
        #expect(c.plates.isEmpty)
        #expect(c.filamentColours.isEmpty)
        #expect(!c.hasColorAssignment)
    }
}
