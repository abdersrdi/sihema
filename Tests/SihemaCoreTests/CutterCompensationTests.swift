import XCTest
@testable import SihemaCore

final class CutterCompensationTests: XCTestCase {
    private func run(_ text: String, radii: [Int: Double] = [1: 2]) -> Toolpath {
        var config = MachineConfig()
        config.cutterRadii = radii
        return FanucInterpreter(config: config).run(text: text)
    }

    private func assertPoint(_ p: SIMD3<Double>, _ x: Double, _ y: Double, _ z: Double = 0,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 1e-9, "x", file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 1e-9, "y", file: file, line: line)
        XCTAssertEqual(p.z, z, accuracy: 1e-9, "z", file: file, line: line)
    }

    private func assertMove(_ s: Segment, from a: (Double, Double), to b: (Double, Double),
                            file: StaticString = #filePath, line: UInt = #line) {
        assertPoint(s.start, a.0, a.1, s.start.z, file: file, line: line)
        assertPoint(s.end, b.0, b.1, s.end.z, file: file, line: line)
    }

    /// Clockwise path round a 20 mm square part with the cutter on the left: every corner is an outside corner.
    func testOutsideCornersGetArcsAroundTheCorner() {
        let tp = run("""
        G00 X0 Y-10
        G41 D1 G01 X0 Y0 F100
        G01 X0 Y20
        G01 X20 Y20
        G01 X20 Y0
        G01 X0 Y0
        G40 G01 X-10 Y0
        """)
        XCTAssertEqual(tp.segments.count, 10)
        let s = tp.segments
        XCTAssertEqual(s[0].kind, .rapid)
        assertMove(s[1], from: (0, -10), to: (-2, 0))     // start-up
        assertMove(s[2], from: (-2, 0), to: (-2, 20))
        XCTAssertEqual(s[3].kind, .arcCW)
        assertMove(s[3], from: (-2, 20), to: (0, 22))
        assertPoint(s[3].center, 0, 20, 0)
        XCTAssertEqual(s[3].arcGeometry.sweep, -Double.pi / 2, accuracy: 1e-9)
        assertMove(s[4], from: (0, 22), to: (20, 22))
        XCTAssertEqual(s[5].kind, .arcCW)
        assertMove(s[5], from: (20, 22), to: (22, 20))
        assertMove(s[6], from: (22, 20), to: (22, 0))
        XCTAssertEqual(s[7].kind, .arcCW)
        assertMove(s[7], from: (22, 0), to: (20, -2))
        assertMove(s[8], from: (20, -2), to: (0, -2))
        assertMove(s[9], from: (0, -2), to: (-10, 0))     // cancel
        assertPoint(tp.boundsMin, -10, -10, 0)
        assertPoint(tp.boundsMax, 22.0, 22.0, 0)
    }

    /// Counter-clockwise path with the cutter on the left (inside the square): inside corners are cut sharp.
    func testInsideCornersAreTrimmedToTheCrossing() {
        let tp = run("""
        G00 X-10 Y0
        G41 D1 G01 X0 Y0 F100
        G01 X20 Y0
        G01 X20 Y20
        G01 X0 Y20
        G01 X0 Y0
        G40 G01 X-10 Y0
        """)
        XCTAssertEqual(tp.segments.count, 8)
        let s = tp.segments
        assertMove(s[1], from: (-10, 0), to: (0, 2))
        assertMove(s[2], from: (0, 2), to: (18, 2))
        assertMove(s[3], from: (18, 2), to: (18, 18))
        assertMove(s[4], from: (18, 18), to: (2, 18))
        assertMove(s[5], from: (2, 18), to: (2, 0))
        XCTAssertEqual(s[6].kind, .arcCW)
        assertMove(s[6], from: (2, 0), to: (0, -2))
        assertPoint(s[6].center, 0, 0, 0)
        assertMove(s[7], from: (0, -2), to: (-10, 0))
    }

    func testArcIsOffsetOutwardForLeftCompensationAroundAClockwiseArc() {
        let tp = run("G00 X10 Y10\nG41 D1 G01 X10 Y0 F100\nG02 X-10 Y0 I-10 J0\nG40 G01 X-10 Y10\n")
        XCTAssertEqual(tp.segments.count, 4)
        let arc = tp.segments[2]
        XCTAssertEqual(arc.kind, .arcCW)
        assertPoint(arc.center, 0, 0, 0)
        assertMove(arc, from: (12, 0), to: (-12, 0))
        XCTAssertEqual(arc.length, 12 * Double.pi, accuracy: 1e-9)
        assertMove(tp.segments[1], from: (10, 10), to: (12, 0))
        assertMove(tp.segments[3], from: (-12, 0), to: (-10, 10))
    }

    func testArcIsOffsetInwardForRightCompensationAroundAClockwiseArc() {
        let tp = run("G00 X10 Y10\nG42 D1 G01 X10 Y0 F100\nG02 X-10 Y0 I-10 J0\nG40 G01 X-10 Y10\n")
        let arc = tp.segments[2]
        assertMove(arc, from: (8, 0), to: (-8, 0))
        XCTAssertEqual(arc.length, 8 * Double.pi, accuracy: 1e-9)
    }

    func testCounterClockwiseArcFlipsTheOffsetDirection() {
        // CCW with the cutter on the left is inside the arc: radius 10 - 2
        let tp = run("G00 X10 Y-10\nG41 D1 G01 X10 Y0 F100\nG03 X-10 Y0 I-10 J0\nG40 G01 X-10 Y-10\n")
        assertMove(tp.segments[2], from: (8, 0), to: (-8, 0))
        XCTAssertEqual(tp.segments[2].kind, .arcCCW)
    }

    func testDifferentOffsetNumbersUseDifferentRadii() {
        let tp = run("""
        G00 X0 Y-10
        G41 D2 G01 X0 Y0 F100
        G01 X30 Y0
        G40 G01 X30 Y-10
        """, radii: [1: 2, 2: 5])
        XCTAssertEqual(tp.segments.count, 6)
        let s = tp.segments
        assertMove(s[1], from: (0, -10), to: (-5, 0))
        XCTAssertEqual(s[2].kind, .arcCW)
        assertMove(s[2], from: (-5, 0), to: (0, 5))
        XCTAssertEqual(s[2].arcGeometry.startRadius, 5, accuracy: 1e-9)
        assertMove(s[3], from: (0, 5), to: (30, 5))
        assertMove(s[4], from: (30, 5), to: (35, 0))
        assertMove(s[5], from: (35, 0), to: (30, -10))
    }

    func testZMoveInsideCompensationStaysAtTheToolCentre() {
        let tp = run("G00 X-10 Y0\nG41 D1 G01 X0 Y0 F100\nG01 Z-5\nG01 X20\nG40 G01 X30\n")
        XCTAssertEqual(tp.segments.count, 5)
        let s = tp.segments
        assertPoint(s[1].end, 0, 2, 0)
        assertPoint(s[2].start, 0, 2, 0)
        assertPoint(s[2].end, 0, 2, -5)
        assertPoint(s[3].start, 0, 2, -5)
        assertPoint(s[3].end, 20, 2, -5)
        assertPoint(s[4].end, 30, 0, -5)
    }

    func testFeedToolAndLineSurviveCompensation() {
        let tp = run("T5 M6\nG00 X0 Y-10\nG41 D1 G01 X0 Y0 F250\nG01 X0 Y20\nG40 G01 X-5 Y20\n")
        XCTAssertEqual(tp.segments[2].feed, 250, accuracy: 1e-9)
        XCTAssertEqual(tp.segments[2].tool, 5)
        XCTAssertEqual(tp.segments[2].line, 3)
        XCTAssertEqual(tp.segments[2].compSide, 0)
    }

    func testRapidMovesAreCompensatedToo() {
        let tp = run("G00 X0 Y-10\nG41 D1 G00 X0 Y0\nG00 X20 Y0\nG40 G00 X20 Y-10\n")
        // all compensated moves stay rapid, and a rapid corner is a straight connection, not an arc
        XCTAssertEqual(tp.segments.count, 6)
        XCTAssertTrue(tp.segments.allSatisfy { $0.kind == .rapid })
        assertMove(tp.segments[1], from: (0, -10), to: (-2, 0))
        assertMove(tp.segments[2], from: (-2, 0), to: (0, 2))
        assertMove(tp.segments[3], from: (0, 2), to: (20, 2))
        assertMove(tp.segments[4], from: (20, 2), to: (22, 0))
        assertMove(tp.segments[5], from: (22, 0), to: (20, -10))
    }

    func testNearlyTangentJoinsCarryOnWithoutAGap() {
        // arc and line meet tangentially, with the 4-decimal rounding a CAM post leaves behind
        let text = "G00 X-5 Y-10\nG41 D1 G01 X0 Y0 F100\nG01 X30 Y0\nG03 X40.0001 Y10 I0.0001 J10\nG01 X40.0001 Y30\nG40 G01 X30 Y40\n"
        let tp = run(text, radii: [1: 2])
        XCTAssertFalse(tp.diagnostics.contains { $0.severity == .warning })
        var gaps: [Double] = []
        let moves = tp.segments.filter { $0.kind != .rapid }
        for i in 1..<moves.count {
            let a = moves[i - 1].end, b = moves[i].start
            gaps.append(((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot())
        }
        XCTAssertLessThan(gaps.max() ?? 0, 3e-3)
    }

    func testShortMoveBetweenTwoCornersIsSkippedNotReversed() {
        // the closing line is shorter than the cutter radius between two inside corners: its offset would run
        // backwards and cut into the part, so it is skipped and reported
        let text = "G90 G21 G17\nG00 X3.9657 Y2.4350\nG42 D1 G01 X5.7935 Y15.4432 F500\nG01 X9.7790 Y14.8832\n"
            + "G01 X15.5916 Y-2.0216\nG2 X11.2172 Y-13.7432 I-9.3121 J-3.2019\nG01 X-7.2221 Y-24.4301\n"
            + "G01 X1.4500 Y16.0535\nG01 X5.7935 Y15.4432\nG40 G01 X3.9657 Y2.4350\nM30\n"
        let compensated = run(text, radii: [1: 3.712])
        let plain = run(text.replacingOccurrences(of: "G42 D1 ", with: "").replacingOccurrences(of: "G40 ", with: ""),
                        radii: [:])
        var programmed: [Int32: SIMD3<Double>] = [:]
        for s in plain.segments where s.kind == .linear { programmed[s.line] = s.end - s.start }
        for s in compensated.segments where s.kind == .linear {
            guard let d = programmed[s.line] else { continue }
            let c = s.end - s.start
            XCTAssertGreaterThanOrEqual(c.x * d.x + c.y * d.y, -1e-9, "move on line \(s.line) runs backwards")
        }
        XCTAssertTrue(compensated.diagnostics.contains { $0.message.contains("skipped") })
    }

    func testMissingRadiusLeavesThePathAsProgrammed() {
        let tp = run("G00 X0 Y-10\nG41 D7 G01 X0 Y0 F100\nG01 X10 Y0\nG40 G01 X10 Y-10\n")
        XCTAssertEqual(tp.segments.count, 4)
        assertMove(tp.segments[2], from: (0, 0), to: (10, 0))
        XCTAssertTrue(tp.diagnostics.contains { $0.message.contains("No cutter radius for D7") })
    }

    func testCutterLargerThanAnInsideArcIsReported() {
        let tp = run("G00 X0 Y-10\nG41 D1 G01 X1 Y0 F100\nG03 X0 Y1 I-1 J0\nG40 G01 X-5 Y1\n")
        XCTAssertTrue(tp.diagnostics.contains { $0.message.contains("Cutter radius compensation") && $0.message.contains("collapses") })
    }

    func testCancelLeavesTheNextMovesUncompensated() {
        let tp = run("""
        G00 X0 Y-10
        G41 D1 G01 X0 Y0 F100
        G01 X0 Y20
        G40 G01 X0 Y30
        G01 X10 Y30
        """)
        let last = tp.segments.last!
        assertMove(last, from: (0, 30), to: (10, 30))
        XCTAssertEqual(last.compSide, 0)
    }

    func testTotalsAndBoundsFollowTheCompensatedPath() {
        let tp = run("G00 X0 Y-10\nG41 D1 G01 X0 Y0 F100\nG01 X0 Y20\nG40 G01 X0 Y30\n")
        var rapid = 0.0
        var cutting = 0.0
        for s in tp.segments { if s.kind == .rapid { rapid += s.length } else { cutting += s.length } }
        XCTAssertEqual(tp.rapidLength, rapid, accuracy: 1e-9)
        XCTAssertEqual(tp.cuttingLength, cutting, accuracy: 1e-9)
        XCTAssertEqual(tp.boundsMin.x, -2, accuracy: 1e-9)
    }
}
