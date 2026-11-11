import XCTest
@testable import SihemaCore

final class DexelTests: XCTestCase {
    private func grid() -> DexelGrid {
        DexelGrid(minX: 0, minY: 0, maxX: 20, maxY: 20, cell: 0.1, stockTop: 10)
    }

    func testFlatToolPlungeRemovesADisc() {
        let g = grid()
        let lowered = g.cutLine(tool: EndMill(shape: .flat, radius: 2), from: SIMD3(10, 10, 6), to: SIMD3(10, 10, 6))
        // disc area / cell area = pi * 4 / 0.01
        XCTAssertGreaterThan(lowered, 1200)
        XCTAssertLessThan(lowered, 1320)
        XCTAssertEqual(g.height(x: 10.05, y: 10.05)!, 6, accuracy: 1e-5)
        XCTAssertEqual(g.height(x: 13.05, y: 10.05)!, 10, accuracy: 1e-5)
        XCTAssertEqual(g.height(x: 1, y: 1)!, 10, accuracy: 1e-5)
    }

    func testBallToolProfile() {
        let g = grid()
        let r = 2.0
        g.cutLine(tool: EndMill(shape: .ball, radius: r), from: SIMD3(10, 10, 6), to: SIMD3(10, 10, 6))
        for (x, y) in [(10.05, 10.05), (11.05, 10.05), (10.05, 11.55), (9.25, 9.25)] {
            // cell centres sit at k * 0.1 + 0.05; the tool centre is at (10, 10)
            let cx = (x / 0.1).rounded(.down) * 0.1 + 0.05
            let cy = (y / 0.1).rounded(.down) * 0.1 + 0.05
            let d2 = (cx - 10) * (cx - 10) + (cy - 10) * (cy - 10)
            let expected = 6 + r - (r * r - d2).squareRoot()
            XCTAssertEqual(g.height(x: x, y: y)!, expected, accuracy: 1e-4, "at \(x),\(y)")
        }
        XCTAssertEqual(g.height(x: 12.5, y: 10.05)!, 10, accuracy: 1e-5)
    }

    func testToolAboveTheStockChangesNothing() {
        let g = grid()
        let lowered = g.cutLine(tool: EndMill(shape: .flat, radius: 2), from: SIMD3(2, 10, 12), to: SIMD3(18, 10, 12))
        XCTAssertEqual(lowered, 0)
        XCTAssertEqual(g.removedVolume, 0, accuracy: 1e-9)
    }

    func testSlotVolume() {
        let g = grid()
        g.cutLine(tool: EndMill(shape: .flat, radius: 1), from: SIMD3(5, 10, 8), to: SIMD3(15, 10, 8))
        // 2 mm wide, 10 mm long, 2 mm deep, plus two half-discs at the ends
        let expected = (2.0 * 10.0 + Double.pi) * 2.0
        XCTAssertEqual(g.removedVolume, expected, accuracy: expected * 0.04)
    }

    func testRepeatingAPassRemovesNothingMore() {
        let g = grid()
        let tool = EndMill(shape: .flat, radius: 1)
        g.cutLine(tool: tool, from: SIMD3(5, 10, 8), to: SIMD3(15, 10, 8))
        let first = g.removedVolume
        g.cutLine(tool: tool, from: SIMD3(5, 10, 8), to: SIMD3(15, 10, 8))
        XCTAssertEqual(g.removedVolume, first, accuracy: 1e-9)
    }

    func testRapidThroughStockIsDetected() {
        var config = MachineConfig()
        config.startPosition = SIMD3(0, 10, 12)
        let tp = FanucInterpreter(config: config).run(text: "G00 X2 Y10 Z12\nG00 X15\nG00 Z8\nG00 X5\n")
        let result = DexelSimulator.simulate(toolpath: tp, grid: grid(), defaultTool: EndMill(shape: .flat, radius: 1))
        XCTAssertEqual(result.rapidMovesThroughStock, [2, 3])
        XCTAssertGreaterThan(result.removedVolume, 0)
    }

    func testFeedMovesAreNotFlaggedAsCrashes() {
        var config = MachineConfig()
        config.startPosition = SIMD3(0, 10, 12)
        let tp = FanucInterpreter(config: config).run(text: "G00 X5 Y10 Z12\nG01 Z8 F100\nG01 X15\nG00 Z12\n")
        let result = DexelSimulator.simulate(toolpath: tp, grid: grid(), defaultTool: EndMill(shape: .flat, radius: 1))
        XCTAssertEqual(result.rapidMovesThroughStock, [])
        XCTAssertGreaterThan(result.removedVolume, 0)
    }

    func testArcCutRemovesMaterialAlongTheArc() {
        var config = MachineConfig()
        config.startPosition = SIMD3(10, 5, 12)
        let tp = FanucInterpreter(config: config).run(text: "G01 Z8 F100\nG03 X10 Y15 I0 J5 F100\n")
        let g = grid()
        _ = DexelSimulator.simulate(toolpath: tp, grid: g, defaultTool: EndMill(shape: .flat, radius: 0.5))
        // the arc bulges towards +X, so the point (15, 10) is on the cut and (5, 10) is not
        XCTAssertEqual(g.height(x: 15.0, y: 10.05)!, 8, accuracy: 1e-5)
        XCTAssertEqual(g.height(x: 5.0, y: 10.05)!, 10, accuracy: 1e-5)
    }

    func testHeightOutsideTheGridIsNil() {
        XCTAssertNil(grid().height(x: -1, y: 5))
        XCTAssertNil(grid().height(x: 5, y: 25))
    }
}
