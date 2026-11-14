import XCTest
@testable import SihemaCore

final class TimeLimitsCompareTests: XCTestCase {
    private func path(_ text: String, configure: (inout MachineConfig) -> Void = { _ in }) -> Toolpath {
        var config = MachineConfig()
        configure(&config)
        return FanucInterpreter(config: config).run(text: text)
    }

    private func model(rapid: Double = 15_000, a: Double = 1_000) -> MotionModel {
        var m = MotionModel()
        m.rapidFeedMMPerMin = rapid
        m.accelerationMMPerS2 = a
        m.toolChangeSeconds = 5
        return m
    }

    // MARK: Cycle time

    func testSingleLongMoveIsATrapezoid() {
        // 100 mm at 100 mm/s with 1000 mm/s2: 0.1 s up, 0.1 s down, 90 mm at speed
        let tp = path("G01 X100 F6000\n")
        XCTAssertEqual(tp.cycleTime(model: model()), 1.1, accuracy: 1e-9)
    }

    func testShortMoveNeverReachesFullSpeed() {
        let tp = path("G01 X2 F6000\n")
        let peak = (1000.0 * 2).squareRoot()
        XCTAssertEqual(tp.cycleTime(model: model()), 2 * peak / 1000, accuracy: 1e-9)
    }

    func testCollinearMovesKeepTheirSpeed() {
        let tp = path("G01 X100 F6000\nG01 X200\n")
        XCTAssertEqual(tp.cycleTime(model: model()), 2.1, accuracy: 1e-9)
    }

    func testRightAngleCornerStopsTheToolWhenNoSpeedStepIsAllowed() {
        let tp = path("G01 X100 F6000\nG01 Y100\n")
        var exactStop = model()
        exactStop.cornerStepMMPerS = 0
        XCTAssertEqual(tp.cycleTime(model: exactStop), 2.2, accuracy: 1e-9)
        // with a step of 10 mm/s the tool goes through the corner at 10 mm/s and is faster overall
        var stepping = model()
        stepping.cornerStepMMPerS = 10
        XCTAssertLessThan(tp.cycleTime(model: stepping), 2.2)
    }

    func testAccelerationIsRecoveredFromAMeasuredTime() {
        let tp = path("G00 X80 Y40\nG01 X10 Y10 F3000\nG01 X60 Y10\nG03 X60 Y50 I0 J20\nG01 X10 Y50\nG00 X0 Y0\n")
        for truth in [250.0, 900.0, 2400.0, 8000.0] {
            var m = model()
            m.accelerationMMPerS2 = truth
            let measured = tp.cycleTime(model: m)
            guard case .fitted(let found) = tp.fitAcceleration(toMeasuredSeconds: measured, model: model()) else {
                return XCTFail("no fit for \(truth)")
            }
            XCTAssertEqual(found, truth, accuracy: truth * 0.01, "acceleration \(truth)")
        }
    }

    func testImpossibleMeasuredTimesAreSaidSo() {
        let tp = path("G00 X80 Y40\nG01 X10 Y10 F3000\n")
        if case .tooFast = tp.fitAcceleration(toMeasuredSeconds: 0.01, model: model()) {} else { XCTFail("too fast") }
        if case .tooSlow = tp.fitAcceleration(toMeasuredSeconds: 1e7, model: model()) {} else { XCTFail("too slow") }
    }

    func testDiagonalRapidIsLimitedByItsSlowestAxis() {
        // 100 mm in X and 100 mm in Y at 6000 mm/min per axis: each axis needs 1 s, so the move takes 1 s of
        // cruise (plus acceleration), not the 1.41 s a path of 141 mm at 100 mm/s would
        let tp = path("G00 X100 Y100\n")
        let diagonal = tp.cycleTime(model: model(rapid: 6000))
        let straight = path("G00 X100\n").cycleTime(model: model(rapid: 6000))
        XCTAssertEqual(diagonal, straight, accuracy: 0.2)
        XCTAssertLessThan(diagonal, 1.35)
    }

    func testSmallCircleIsLimitedByCentripetalAcceleration() {
        // radius 1 mm at 1000 mm/s2: at most sqrt(1000 * 1) = 31.6 mm/s, although the feed asks for 100 mm/s
        let small = path("G00 X1 Y0\nG03 X1 Y0 I-1 J0 F6000\n").cycleTime(model: model(rapid: 6000))
        let large = path("G00 X100 Y0\nG03 X100 Y0 I-100 J0 F6000\n").cycleTime(model: model(rapid: 6000))
        // the small circle is 2*pi mm long: at the limited speed it takes about 0.2 s, at full feed only 0.063 s
        XCTAssertGreaterThan(small - path("G00 X1 Y0\n").cycleTime(model: model(rapid: 6000)), 0.15)
        XCTAssertGreaterThan(large, 0)
    }

    func testGentleCornerSlowsTheToolOnlyALittle() {
        // 100 mm, then 100 mm at a slight angle (10 mm sideways), against one straight 199.4987 mm move
        let oneStraightMove = path("G01 X199.4987437 F6000\n").cycleTime(model: model())
        let gentle = path("G01 X100 F6000\nG01 X199.4987437 Y10\n").cycleTime(model: model())
        let sharp = path("G01 X100 F6000\nG01 X100 Y100\n").cycleTime(model: model())
        XCTAssertGreaterThan(gentle, oneStraightMove)
        XCTAssertLessThan(gentle, oneStraightMove + 0.05)
        XCTAssertLessThan(gentle, sharp)
    }

    func testRapidsUseTheRapidRate() {
        let tp = path("G00 X100\n")
        // 100 mm at 6000 mm/min rapid = 100 mm/s
        XCTAssertEqual(tp.cycleTime(model: model(rapid: 6000)), 1.1, accuracy: 1e-9)
    }

    func testDwellAndToolChangesAreAdded() {
        let tp = path("T1 M6\nT2 M6\nG04 X3.\n")
        XCTAssertEqual(tp.toolChanges, 2)
        XCTAssertEqual(tp.cycleTime(model: model()), 13, accuracy: 1e-9)
    }

    func testArcsAreTimedByTheirLength() {
        let tp = path("G00 X10 Y0\nG03 X-10 Y0 I-10 J0 F6000\n")
        let seconds = tp.cycleTime(model: model(rapid: 6000))
        XCTAssertGreaterThan(seconds, 10 * Double.pi / 100)
        XCTAssertLessThan(seconds, 10 * Double.pi / 100 + 1)
    }

    func testEmptyProgramHasNoTime() {
        XCTAssertEqual(path("G21 G90\n").cycleTime(model: model()), 0)
    }

    // MARK: Travel limits

    func testMovesBeyondTravelAreReportedOncePerAxis() {
        let tp = path("G01 X50 F100\nG01 X150\nG01 X160\nG01 Y-5\n") {
            $0.travelLimits = TravelLimits(minimum: SIMD3(0, 0, 0), maximum: SIMD3(100, 100, 100))
        }
        let messages = tp.diagnostics.map(\.message)
        XCTAssertEqual(messages.filter { $0.contains("X goes above") }.count, 1)
        XCTAssertEqual(messages.filter { $0.contains("Y goes below") }.count, 1)
        XCTAssertTrue(tp.diagnostics.contains { $0.message.contains("X goes above") && $0.line == 1 })
    }

    func testArcsThatSwingOutsideTheTravelAreReported() {
        // both end points are inside, but the arc bulges past X 100
        let tp = path("G00 X90 Y10 Z0\nG03 X90 Y30 I0 J10 F100\n") {
            $0.travelLimits = TravelLimits(minimum: SIMD3(0, 0, -10), maximum: SIMD3(95, 100, 10))
        }
        XCTAssertTrue(tp.diagnostics.contains { $0.message.contains("X goes above") })
    }

    func testPathInsideTheTravelHasNoMessages() {
        let tp = path("G01 X50 Y50 F100\n") {
            $0.travelLimits = TravelLimits(minimum: SIMD3(0, 0, 0), maximum: SIMD3(100, 100, 100))
        }
        XCTAssertTrue(tp.diagnostics.isEmpty)
    }

    // MARK: Compare

    func testFormattingOnlyDifferencesAreIgnored() {
        let a = "N10 G01 X10.0 Y5 F100 (first)\nN20 G00 Z5.\n"
        let b = "g1 x10 y5.0 f100.\n  G0   Z5\n"
        let rows = ProgramCompare.compare(old: a, new: b)
        XCTAssertEqual(ProgramCompare.changeCount(rows), 0)
        XCTAssertEqual(rows.count, 2)
    }

    func testInsertedAndRemovedLines() {
        let a = "G01 X1\nG01 X2\nG01 X3\n"
        let b = "G01 X1\nG01 X2.5\nG01 X3\nG01 X4\n"
        let rows = ProgramCompare.compare(old: a, new: b)
        XCTAssertEqual(rows.filter { $0.kind == .removed }.map(\.oldLine), [1])
        XCTAssertEqual(rows.filter { $0.kind == .added }.map(\.newLine), [1, 3])
        XCTAssertEqual(ProgramCompare.changeCount(rows), 3)
    }

    func testRowsKeepTheOriginalLineNumbers() {
        let a = "(header)\n\nG01 X1\nG01 X2\n"
        let b = "G01 X1\n(note)\nG01 X2\nG01 X9\n"
        let rows = ProgramCompare.compare(old: a, new: b)
        let same = rows.filter { $0.kind == .same }
        XCTAssertEqual(same.map(\.oldLine), [2, 3])
        XCTAssertEqual(same.map(\.newLine), [0, 2])
        XCTAssertEqual(rows.last?.kind, .added)
        XCTAssertEqual(rows.last?.newLine, 3)
    }

    func testSequenceNumbersCanBeCompared() {
        var options = CompareOptions()
        options.ignoreSequenceNumbers = false
        let rows = ProgramCompare.compare(old: "N10 G01 X1\n", new: "N20 G01 X1\n", options: options)
        XCTAssertEqual(ProgramCompare.changeCount(rows), 2)
    }

    func testMacroLinesAreComparedByText() {
        let same = ProgramCompare.compare(old: "#1 = [2 * 3] (six)\n", new: "#1=[2*3]\n")
        XCTAssertEqual(ProgramCompare.changeCount(same), 0)
        let different = ProgramCompare.compare(old: "#1=[2*3]\n", new: "#1=[2*4]\n")
        XCTAssertEqual(ProgramCompare.changeCount(different), 2)
    }

    func testEmptyInputs() {
        XCTAssertTrue(ProgramCompare.compare(old: "", new: "").isEmpty)
        XCTAssertEqual(ProgramCompare.changeCount(ProgramCompare.compare(old: "", new: "G01 X1\n")), 1)
        XCTAssertEqual(ProgramCompare.changeCount(ProgramCompare.compare(old: "G01 X1\n", new: "")), 1)
    }

    func testCompareHandlesLargeFilesQuickly() {
        var a = ""
        var b = ""
        for i in 0..<20_000 {
            a += "G01 X\(i) Y\(i) F100\n"
            b += i % 1000 == 0 ? "G01 X\(i + 1) Y\(i) F100\n" : "G01 X\(i) Y\(i) F100\n"
        }
        let rows = ProgramCompare.compare(old: a, new: b)
        XCTAssertEqual(ProgramCompare.changeCount(rows), 40)
    }
}
