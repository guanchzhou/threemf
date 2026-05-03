import Foundation
import simd
import Testing

/// Pilot suite using Apple's `swift-testing` framework (`@Test` macros) instead of XCTest.
/// Coexists with the XCTest suites; demonstrates the modern pattern for new tests we add
/// going forward. Migration of existing suites is a follow-up.
@Suite("MeshData (swift-testing pilot)")
struct MeshDataPilotTests {
    @Test("Empty mesh has zero bounding box")
    func emptyBoundingBox() {
        let mesh = MeshData(vertices: [], indices: [])
        let bb = mesh.boundingBox
        #expect(bb.min == .zero)
        #expect(bb.max == .zero)
        #expect(bb.dimensions == .zero)
    }

    @Test("Bounding box matches min/max of vertices")
    func nonEmptyBoundingBox() {
        let mesh = MeshData(
            vertices: [
                simd_float3(0, 0, 0),
                simd_float3(10, 0, 0),
                simd_float3(0, 20, 0),
                simd_float3(0, 0, 30),
            ],
            indices: [0, 1, 2]
        )
        let bb = mesh.boundingBox
        #expect(bb.min == simd_float3(0, 0, 0))
        #expect(bb.max == simd_float3(10, 20, 30))
        #expect(bb.dimensions == simd_float3(10, 20, 30))
    }

    @Test("Volume of an axis-aligned unit cube is 1")
    func unitCubeVolume() {
        // 8 corners of a 1×1×1 cube. Indices walk the 12 outward-facing triangles.
        let v: [simd_float3] = [
            simd_float3(0, 0, 0), simd_float3(1, 0, 0),
            simd_float3(1, 1, 0), simd_float3(0, 1, 0),
            simd_float3(0, 0, 1), simd_float3(1, 0, 1),
            simd_float3(1, 1, 1), simd_float3(0, 1, 1),
        ]
        let i: [UInt32] = [
            // bottom (-Z)
            0, 2, 1, 0, 3, 2,
            // top (+Z)
            4, 5, 6, 4, 6, 7,
            // front (-Y)
            0, 1, 5, 0, 5, 4,
            // back (+Y)
            2, 3, 7, 2, 7, 6,
            // left (-X)
            0, 4, 7, 0, 7, 3,
            // right (+X)
            1, 2, 6, 1, 6, 5,
        ]
        let mesh = MeshData(vertices: v, indices: i)
        #expect(abs(mesh.volume - 1.0) < 1e-5)
    }

    @Test("Volume of an empty mesh is 0")
    func emptyVolume() {
        let mesh = MeshData(vertices: [], indices: [])
        #expect(mesh.volume == 0)
    }

    @Test("Volume of a single-triangle (degenerate) mesh is 0")
    func singleTriangleVolume() {
        let mesh = MeshData(
            vertices: [
                simd_float3(0, 0, 0),
                simd_float3(1, 0, 0),
                simd_float3(0, 1, 0),
            ],
            indices: [0, 1, 2]
        )
        // Single triangle is an open mesh — divergence-theorem volume from a single
        // triangle is the signed tetrahedral volume between origin and the triangle.
        // For a triangle in the z=0 plane, the resulting tetrahedron has zero volume.
        #expect(mesh.volume == 0)
    }

    @Test("Volume is invariant to winding (uses abs)")
    func invertedMeshVolume() {
        // Same unit cube but with reversed winding (flipped triangles).
        let v: [simd_float3] = [
            simd_float3(0, 0, 0), simd_float3(1, 0, 0),
            simd_float3(1, 1, 0), simd_float3(0, 1, 0),
            simd_float3(0, 0, 1), simd_float3(1, 0, 1),
            simd_float3(1, 1, 1), simd_float3(0, 1, 1),
        ]
        // Reversed winding compared to unitCubeVolume — every triangle's vertex order swapped.
        let i: [UInt32] = [
            0, 1, 2, 0, 2, 3,
            4, 6, 5, 4, 7, 6,
            0, 5, 1, 0, 4, 5,
            2, 7, 3, 2, 6, 7,
            0, 7, 4, 0, 3, 7,
            1, 6, 2, 1, 5, 6,
        ]
        let mesh = MeshData(vertices: v, indices: i)
        // abs() in the volume formula means inverted-winding meshes still report 1.0.
        #expect(abs(mesh.volume - 1.0) < 1e-5)
    }

    @Test("statistics() matches separate boundingBox + volume calls")
    func statisticsParity() {
        let v: [simd_float3] = [
            simd_float3(0, 0, 0), simd_float3(2, 0, 0),
            simd_float3(2, 3, 0), simd_float3(0, 3, 0),
            simd_float3(0, 0, 4), simd_float3(2, 0, 4),
            simd_float3(2, 3, 4), simd_float3(0, 3, 4),
        ]
        let i: [UInt32] = [
            0, 2, 1, 0, 3, 2,
            4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4,
            2, 3, 7, 2, 7, 6,
            0, 4, 7, 0, 7, 3,
            1, 2, 6, 1, 6, 5,
        ]
        let mesh = MeshData(vertices: v, indices: i)
        let combined = mesh.statistics()
        #expect(combined.boundingBox == mesh.boundingBox)
        #expect(abs(combined.volume - mesh.volume) < 1e-5)
        // 2×3×4 box → volume 24.
        #expect(abs(combined.volume - 24.0) < 1e-4)
    }
}
