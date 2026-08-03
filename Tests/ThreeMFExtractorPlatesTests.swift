import Foundation
import Testing
import ZIPFoundation

/// `listPlates` must return one entry per *real* plate. Bambu emits several PNGs per plate
/// (`plate_<N>.png`, `plate_<N>_small.png`, `plate_no_light_<N>.png`, `top_<N>.png`); only the
/// canonical full-size render counts, or the switcher shows phantom duplicate "plates".
@Suite("ThreeMFExtractor plate listing")
struct ThreeMFExtractorPlatesTests {
    @Test("plateKindAndIndex matches only canonical plate renders")
    func classifier() {
        #expect(ThreeMFExtractor.plateKindAndIndex(basename: "plate_1.png")?.kind == 0)
        #expect(ThreeMFExtractor.plateKindAndIndex(basename: "plate_1.png")?.index == 1)
        #expect(ThreeMFExtractor.plateKindAndIndex(basename: "plate_12.png")?.index == 12)
        #expect(ThreeMFExtractor.plateKindAndIndex(basename: "top_3.png")?.kind == 1)
        // Variants and unrelated PNGs are rejected.
        #expect(ThreeMFExtractor.plateKindAndIndex(basename: "plate_1_small.png") == nil)
        #expect(ThreeMFExtractor.plateKindAndIndex(basename: "plate_no_light_2.png") == nil)
        #expect(ThreeMFExtractor.plateKindAndIndex(basename: "pick_1.png") == nil)
        #expect(ThreeMFExtractor.plateKindAndIndex(basename: "thumbnail.png") == nil)
    }

    @Test("listPlates dedups variants to one entry per plate, preferring plate_ over top_")
    func listPlatesDedup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plates-\(UUID().uuidString)").appendingPathExtension("3mf")
        let archive = try Archive(url: url, accessMode: .create)
        let png = Data([0x89, 0x50, 0x4E, 0x47]) // dummy PNG-ish bytes
        // Two real plates, each with the full set of Bambu variant PNGs + noise.
        for path in [
            "Metadata/plate_1.png", "Metadata/plate_1_small.png",
            "Metadata/plate_no_light_1.png", "Metadata/top_1.png",
            "Metadata/plate_2.png", "Metadata/plate_2_small.png", "Metadata/top_2.png",
            "Metadata/thumbnail.png", "3D/3dmodel.model",
        ] {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: UInt32(png.count),
                provider: { p, n in png.subdata(in: p ..< p + n) }
            )
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let plates = ThreeMFExtractor.listPlates(from: url)
        #expect(plates.map(\.index) == [1, 2]) // exactly 2 plates, in order — not 7
        // Both resolve to the canonical full-size `plate_<N>.png`, not a variant or top_.
        #expect(plates[0].path == "Metadata/plate_1.png")
        #expect(plates[1].path == "Metadata/plate_2.png")
    }
}
