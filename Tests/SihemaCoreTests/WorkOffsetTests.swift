import XCTest
@testable import SihemaCore

final class WorkOffsetTests: XCTestCase {
    private func run(_ text: String, offsets: [Int: SIMD3<Double>] = [:], configure: (inout MachineConfig) -> Void = { _ in }) -> Toolpath {
        var config = MachineConfig()
        config.workOffsets = offsets
        configure(&config)
        return FanucInterpreter(config: config).run(text: text)
    }

    private func assertPoint(_ p: SIMD3<Double>, _ x: Double, _ y: Double, _ z: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 1e-9, "x", file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 1e-9, "y", file: file, line: line)
        XCTAssertEqual(p.z, z, accuracy: 1e-9, "z", file: file, line: line)
    }

    func testG54OffsetMovesTheWorkZero() {
        let tp = run("G54 G90 G01 X5 Y5 Z5 F100\n", offsets: [54: SIMD3(10, 20, 30)])
        assertPoint(tp.finalPosition, 15, 25, 35)
    }

    func testDifferentWorkOffsetsGiveDifferentMachinePositions() {
        let tp = run("G54 G01 X0 Y0 Z0 F100\nG55 G01 X0 Y0 Z0\n", offsets: [54: SIMD3(10, 0, 0), 55: SIMD3(100, 50, 0)])
        XCTAssertEqual(tp.segments.count, 2)
        assertPoint(tp.segments[0].end, 10, 0, 0)
        assertPoint(tp.segments[1].end, 100, 50, 0)
    }

    func testIncrementalMovesIgnoreTheOffset() {
        let tp = run("G54 G90 G01 X0 Y0 Z0 F100\nG91 G01 X5\n", offsets: [54: SIMD3(10, 0, 0)])
        assertPoint(tp.finalPosition, 15, 0, 0)
    }

    func testG92ShiftsTheCoordinateSystem() {
        let tp = run("G01 X10 F100\nG92 X0\nG01 X5\n")
        XCTAssertEqual(tp.segments.count, 2)
        assertPoint(tp.finalPosition, 15, 0, 0)
    }

    func testG92CanBeCancelled() {
        let tp = run("G01 X10 F100\nG92 X0\nG92.1\nG01 X5\n")
        assertPoint(tp.finalPosition, 5, 0, 0)
    }

    func testG53UsesMachineCoordinates() {
        let tp = run("G54 G90 G53 G00 X0 Z0\n", offsets: [54: SIMD3(100, 0, 40)]) { $0.startPosition = SIMD3(100, 7, 40) }
        XCTAssertEqual(tp.segments.count, 1)
        XCTAssertEqual(tp.segments[0].kind, .rapid)
        assertPoint(tp.finalPosition, 0, 7, 0)
    }

    func testG53DoesNotChangeTheModalMotion() {
        let tp = run("G01 F100\nG53 G00 X5\nX7\n")
        XCTAssertEqual(tp.segments[0].kind, .rapid)
        XCTAssertEqual(tp.segments[1].kind, .linear)
    }

    func testG28ReturnsToTheReferencePosition() {
        let tp = run("G01 X10 Y10 Z10 F100\nG91 G28 Z0\n") { $0.referencePosition = SIMD3(0, 0, 100) }
        // no intermediate move (Z0 incremental), then a rapid to the reference Z
        XCTAssertEqual(tp.segments.count, 2)
        XCTAssertEqual(tp.segments[1].kind, .rapid)
        assertPoint(tp.finalPosition, 10, 10, 100)
    }

    func testG28ThroughAnIntermediatePoint() {
        let tp = run("G01 X10 Y10 Z10 F100\nG90 G28 X20 Y10\n") { $0.referencePosition = SIMD3(0, 0, 0) }
        XCTAssertEqual(tp.segments.count, 3)
        assertPoint(tp.segments[1].end, 20, 10, 10)
        assertPoint(tp.finalPosition, 0, 0, 10)
    }

    func testG28WithoutAxesSendsEverythingHome() {
        let tp = run("G01 X10 Y10 Z10 F100\nG28\n") { $0.referencePosition = SIMD3(1, 2, 3) }
        assertPoint(tp.finalPosition, 1, 2, 3)
    }

    func testG10SetsAWorkOffset() {
        let tp = run("G10 L2 P1 X50 Y0 Z0\nG54 G01 X1 Y0 Z0 F100\n")
        assertPoint(tp.finalPosition, 51, 0, 0)
    }

    func testG10L20AddsToAnOffset() {
        let tp = run("G10 L20 P1 X5\nG10 L20 P1 X5\nG54 G01 X0 Y0 Z0 F100\n")
        assertPoint(tp.finalPosition, 10, 0, 0)
    }

    func testExtendedWorkOffsets() {
        let tp = run("G54.1 P2 G01 X1 Y0 Z0 F100\n") { $0.extendedWorkOffsets = [2: SIMD3(200, 0, 0)] }
        assertPoint(tp.finalPosition, 201, 0, 0)
        let haas = run("G154 P2 G01 X1 Y0 Z0 F100\n") { $0.extendedWorkOffsets = [2: SIMD3(200, 0, 0)] }
        assertPoint(haas.finalPosition, 201, 0, 0)
    }

    func testPositionVariableReportsWorkCoordinates() {
        let tp = run("G54 G01 X5 Y0 Z0 F100\n#1=#5001\nG01 X[#1+1]\n", offsets: [54: SIMD3(10, 0, 0)])
        assertPoint(tp.finalPosition, 16, 0, 0)
    }

    func testArcCenterFollowsTheOffset() {
        let tp = run("G54 G00 X10 Y0 Z0\nG03 X0 Y10 I-10 J0 F100\n", offsets: [54: SIMD3(100, 50, 0)])
        let arc = tp.segments[1]
        assertPoint(arc.center, 100, 50, 0)
        XCTAssertEqual(arc.arcGeometry.sweep, Double.pi / 2, accuracy: 1e-9)
    }

    func testAbsoluteArcCentreUsesWorkCoordinates() {
        let tp = run("G90.1 G54 G00 X10 Y0 Z0\nG03 X0 Y10 I0 J0 F100\n", offsets: [54: SIMD3(100, 50, 0)])
        assertPoint(tp.segments[1].center, 100, 50, 0)
    }

    func testBoundsAreInMachineCoordinates() {
        let tp = run("G54 G01 X0 Y0 Z0 F100\nG01 X10 Y10\n", offsets: [54: SIMD3(100, 200, 0)])
        assertPoint(tp.boundsMin, 0, 0, 0)
        assertPoint(tp.boundsMax, 110, 210, 0)
    }
}
