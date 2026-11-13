import XCTest
@testable import SihemaCore

final class InterpreterTests: XCTestCase {
    private func run(_ text: String, config: MachineConfig = MachineConfig()) -> Toolpath {
        FanucInterpreter(config: config).run(text: text)
    }

    private func assertPoint(_ p: SIMD3<Double>, _ x: Double, _ y: Double, _ z: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(p.z, z, accuracy: 1e-9, file: file, line: line)
    }

    func testLinearAndRapidMoves() {
        let tp = run("G21 G90\nG00 X10 Y20 Z5\nG01 Z-1 F200\nG01 X50 F300\n")
        XCTAssertEqual(tp.segments.count, 3)
        XCTAssertEqual(tp.segments[0].kind, .rapid)
        assertPoint(tp.segments[0].end, 10, 20, 5)
        XCTAssertEqual(tp.segments[1].kind, .linear)
        XCTAssertEqual(tp.segments[1].feed, 200, accuracy: 1e-9)
        assertPoint(tp.segments[1].end, 10, 20, -1)
        XCTAssertEqual(tp.segments[2].feed, 300, accuracy: 1e-9)
        assertPoint(tp.segments[2].end, 50, 20, -1)
        XCTAssertEqual(tp.segments[2].line, 3)
    }

    func testIncrementalMode() {
        let tp = run("G91 G01 X10 F100\nG01 X10\nG01 Y-5\n")
        assertPoint(tp.finalPosition, 20, -5, 0)
    }

    func testInchesConvertToMillimetres() {
        let tp = run("G20 G01 X1 F10\n")
        XCTAssertEqual(tp.segments[0].end.x, 25.4, accuracy: 1e-9)
        XCTAssertEqual(tp.segments[0].feed, 254, accuracy: 1e-9)
    }

    func testModalGCodeOnTheSameBlockAppliesToTheWholeBlock() {
        let tp = run("G01 X1 G20 F1\n")
        XCTAssertEqual(tp.segments[0].end.x, 25.4, accuracy: 1e-9)
    }

    func testArcCounterClockwiseWithIJ() {
        let tp = run("G17 G90 G00 X10 Y0\nG03 X0 Y10 I-10 J0 F100\n")
        let s = tp.segments[1]
        XCTAssertEqual(s.kind, .arcCCW)
        assertPoint(s.center, 0, 0, 0)
        let g = s.arcGeometry
        XCTAssertEqual(g.sweep, Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(s.length, 10 * Double.pi / 2, accuracy: 1e-9)
    }

    func testArcClockwiseWithIJ() {
        let tp = run("G00 X0 Y10\nG02 X10 Y0 I0 J-10 F100\n")
        let s = tp.segments[1]
        XCTAssertEqual(s.kind, .arcCW)
        assertPoint(s.center, 0, 0, 0)
        XCTAssertEqual(s.arcGeometry.sweep, -Double.pi / 2, accuracy: 1e-9)
    }

    func testArcWithRadiusMinorAndMajor() {
        let minor = run("G00 X10 Y0\nG03 X0 Y10 R10 F100\n").segments[1]
        assertPoint(minor.center, 0, 0, 0)
        XCTAssertEqual(minor.arcGeometry.sweep, Double.pi / 2, accuracy: 1e-9)

        let major = run("G00 X10 Y0\nG03 X0 Y10 R-10 F100\n").segments[1]
        assertPoint(major.center, 10, 10, 0)
        XCTAssertEqual(major.arcGeometry.sweep, 3 * Double.pi / 2, accuracy: 1e-9)
    }

    func testFullCircle() {
        let s = run("G00 X10 Y0\nG03 X10 Y0 I-10 J0 F100\n").segments[1]
        XCTAssertEqual(s.arcGeometry.sweep, 2 * Double.pi, accuracy: 1e-9)
        XCTAssertEqual(s.length, 2 * Double.pi * 10, accuracy: 1e-9)
        let cw = run("G00 X10 Y0\nG02 X10 Y0 I-10 J0 F100\n").segments[1]
        XCTAssertEqual(cw.arcGeometry.sweep, -2 * Double.pi, accuracy: 1e-9)
    }

    func testHelix() {
        let s = run("G00 X10 Y0 Z0\nG03 X0 Y10 Z5 I-10 J0 F100\n").segments[1]
        let planar = 10 * Double.pi / 2
        XCTAssertEqual(s.length, (planar * planar + 25).squareRoot(), accuracy: 1e-9)
    }

    func testArcInZXPlane() {
        let s = run("G18 G00 X0 Z10\nG03 X10 Z0 K-10 I0 F100\n").segments[1]
        XCTAssertEqual(s.plane, .zx)
        assertPoint(s.center, 0, 0, 0)
        XCTAssertEqual(s.arcGeometry.sweep, Double.pi / 2, accuracy: 1e-9)
    }

    func testArcFlatteningStaysOnTheCircleAndWithinTolerance() {
        let s = run("G00 X50 Y0\nG03 X0 Y50 I-50 J0 F100\n").segments[1]
        let tolerance = 0.01
        let points = s.flattened(tolerance: tolerance)
        XCTAssertGreaterThan(points.count, 10)
        for p in points {
            XCTAssertEqual((p.x * p.x + p.y * p.y).squareRoot(), 50, accuracy: 1e-9)
        }
        for k in 0..<(points.count - 1) {
            let mid = (points[k] + points[k + 1]) / 2
            let distance = (mid.x * mid.x + mid.y * mid.y).squareRoot()
            XCTAssertGreaterThanOrEqual(distance, 50 - tolerance - 1e-9)
        }
        XCTAssertEqual(points.first!.x, 50, accuracy: 1e-12)
        XCTAssertEqual(points.last!.y, 50, accuracy: 1e-12)
    }

    func testFeedPerRevolution() {
        let tp = run("G95 S1000 G01 X10 F0.2\n")
        XCTAssertEqual(tp.segments[0].feed, 200, accuracy: 1e-9)
    }

    func testDwell() {
        XCTAssertEqual(run("G04 P500\n").dwellSeconds, 0.5, accuracy: 1e-12)
        XCTAssertEqual(run("G04 X2.\n").dwellSeconds, 2, accuracy: 1e-12)
        XCTAssertEqual(run("G04 P1.5\n").dwellSeconds, 1.5, accuracy: 1e-12)
    }

    func testToolChange() {
        let tp = run("T3 M6\nG01 X5 F100\nT7\nG01 X6\nM6\nG01 X7\n")
        XCTAssertEqual(tp.segments[0].tool, 3)
        XCTAssertEqual(tp.segments[1].tool, 3)
        XCTAssertEqual(tp.segments[2].tool, 7)
    }

    func testProgramEndStopsInterpretation() {
        let tp = run("G01 X1 F100\nM30\nG01 X2\n")
        XCTAssertEqual(tp.segments.count, 1)
        XCTAssertTrue(tp.endedByProgramEnd)
    }

    func testG81DrillsAndReturnsToInitialLevel() {
        let tp = run("G21 G90 G00 Z10\nG98 G81 X5 Y5 Z-5 R2 F100\nG80\n")
        let cuts = tp.segments.filter { $0.kind == .linear }
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].start.z, 2, accuracy: 1e-9)
        XCTAssertEqual(cuts[0].end.z, -5, accuracy: 1e-9)
        XCTAssertEqual(tp.segments.last?.end.z ?? 0, 10, accuracy: 1e-9)
    }

    func testG99ReturnsToRPlane() {
        let tp = run("G90 G00 Z10\nG99 G81 X5 Y5 Z-5 R2 F100\nX10\nG80\n")
        XCTAssertEqual(tp.segments.filter { $0.kind == .linear }.count, 2)
        XCTAssertEqual(tp.segments.last?.end.z ?? 0, 2, accuracy: 1e-9)
    }

    func testG83PecksInSteps() {
        let tp = run("G90 G00 Z10\nG83 X0 Y0 Z-9 R2 Q4 F100\nG80\n")
        let cuts = tp.segments.filter { $0.kind == .linear }
        XCTAssertEqual(cuts.count, 3)
        XCTAssertEqual(cuts.last?.end.z ?? 0, -9, accuracy: 1e-9)
    }

    func testG80KeepsEarlierMotionMode() {
        let tp = run("G01 F100\nG81 X1 Y1 Z-1 R1\nG80 X5 Y5\n")
        XCTAssertEqual(tp.segments.last?.end.x ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(tp.segments.last?.kind, .linear)
    }

    func testMissingCutterRadiusIsReportedOnce() {
        let tp = run("G41 D1 G01 X1 F100\nG42 G01 X2\nG41 G01 X3\n")
        XCTAssertEqual(tp.segments.count, 3)
        XCTAssertEqual(tp.diagnostics.filter { $0.message.contains("No cutter radius for D1") }.count, 1)
    }

    func testArcRadiusMismatchIsReported() {
        let tp = run("G00 X10 Y0\nG03 X0 Y9 I-10 J0 F100\n")
        XCTAssertEqual(tp.segments.count, 2)
        XCTAssertTrue(tp.diagnostics.contains { $0.severity == .warning && $0.message.contains("radius") })
    }

    func testArcErrors() {
        XCTAssertEqual(run("G00 X0 Y0\nG03 X5 Y5\n").segments.count, 1)
        XCTAssertEqual(run("G00 X0 Y0\nG03 X1 Y0 R0.1\n").segments.count, 1)
    }

    func testFeedMoveWithoutFeedIsReported() {
        let tp = run("G01 X10\n")
        XCTAssertTrue(tp.diagnostics.contains { $0.message.contains("without a feed") })
    }

    func testMacroVariablesAreEvaluated() {
        let tp = run("#1=5\nG01 X#1 F100\n")
        XCTAssertEqual(tp.segments.count, 1)
        XCTAssertEqual(tp.segments[0].end.x, 5, accuracy: 1e-9)
        XCTAssertTrue(tp.diagnostics.isEmpty)
    }

    func testCycleTime() {
        var config = MachineConfig()
        config.rapidFeedMMPerMin = 6000
        let tp = run("G00 X60\nG01 X160 F600\nG04 X2.\n", config: config)
        // 60 mm rapid at 6000 mm/min = 0.6 s, 100 mm at 600 mm/min = 10 s, dwell 2 s
        XCTAssertEqual(tp.estimatedSeconds(rapidFeed: 6000), 12.6, accuracy: 1e-9)
    }

    func testBounds() {
        let tp = run("G00 X-5 Y3 Z2\nG01 X20 Y-4 Z-1 F100\n")
        assertPoint(tp.boundsMin, -5, -4, -1)
        assertPoint(tp.boundsMax, 20, 3, 2)
    }

    func testRapidNeverHasAFeed() {
        let tp = run("F500\nG00 X10\n")
        XCTAssertEqual(tp.segments[0].feed, 0)
    }
}
