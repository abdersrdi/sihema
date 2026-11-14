import XCTest
@testable import SihemaCore

final class ToolTableTests: XCTestCase {
    private func run(_ text: String, radii: [Int: Double] = [:], inches: Bool = false) -> Toolpath {
        var config = MachineConfig()
        config.cutterRadii = radii
        config.defaultInches = inches
        return FanucInterpreter(config: config).run(text: text)
    }

    // MARK: Reading sizes from comments

    func testDiameterFromCommonCommentStyles() {
        let cases: [(String, Bool, Double?)] = [
            ("(T1 D=10. CR=0. - ZMIN=-5. - FLAT END MILL)", false, 10),
            ("(T1  D=0.25 CR=0. - FLAT)", true, 6.35),
            ("(10 MM END MILL)", false, 10),
            ("(6.35MM BALL)", false, 6.35),
            ("(1/2 FLAT ENDMILL)", false, 12.7),
            ("(3/8 EM)", true, 9.525),
            ("(.25 FLAT ENDMILL)", true, 6.35),
            ("(12. FACE MILL)", false, 12),
            ("(DIA 6)", false, 6),
            ("(DIAMETER=8)", false, 8),
            ("(0.5 INCH CUTTER)", false, 12.7),
            ("(PART 1/4 PLATE)", false, nil),
            ("(OP1 FACE 2 SIDES)", false, nil),
            ("(D=10000)", false, nil),
            ("(NO SIZE HERE)", false, nil)
        ]
        for (text, inches, expected) in cases {
            let got = ToolComments.parseDiameter(text, inches: inches)
            if let expected {
                XCTAssertNotNil(got, text)
                XCTAssertEqual(got ?? 0, expected, accuracy: 1e-6, text)
            } else {
                XCTAssertNil(got, text)
            }
        }
    }

    func testGuessesFollowToolChanges() {
        let program = GCodeTokenizer.tokenize("(T1 D=10. FLAT END MILL)\nT1 M6\nG00 X0\n(6 MM BALL)\nT2 M6\nT3 M6\n")
        let guesses = ToolComments.guesses(in: program, defaultInches: false)
        XCTAssertEqual(guesses[1]?.radius ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(guesses[1]?.line, 0)
        XCTAssertEqual(guesses[2]?.radius ?? 0, 3, accuracy: 1e-9)
        XCTAssertNil(guesses[3])
    }

    func testToolChangeAndMOnSeparateLines() {
        let program = GCodeTokenizer.tokenize("T4 (8 MM END MILL)\nM6\n")
        XCTAssertEqual(ToolComments.guesses(in: program, defaultInches: false)[4]?.radius ?? 0, 4, accuracy: 1e-9)
    }

    func testUnitsFollowG20() {
        let program = GCodeTokenizer.tokenize("G20\n(.25 FLAT ENDMILL)\nT1 M6\n")
        XCTAssertEqual(ToolComments.guesses(in: program, defaultInches: false)[1]?.radius ?? 0, 3.175, accuracy: 1e-9)
    }

    // MARK: Using them for compensation

    private let program = "(10 MM END MILL)\nT1 M6\nG00 X0 Y-10\nG41 D1 G01 X0 Y0 F100\nG01 X10\nG40 G01 X10 Y-10\n"

    func testRadiusComesFromTheToolComment() {
        let tp = run(program)
        let use = tp.compensationUse[1]
        XCTAssertEqual(use?.radius ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(use?.source, .comment(line: 0))
        XCTAssertEqual(use?.tool, 1)
        // left-hand compensation moves the path 5 mm to the left of +X, which is +Y
        XCTAssertTrue(tp.segments.contains { abs($0.end.y - 5) < 1e-6 && abs($0.start.y - 5) < 1e-6 })
        XCTAssertTrue(tp.diagnostics.contains { $0.severity == .info && $0.message.contains("guess") })
        XCTAssertFalse(tp.diagnostics.contains { $0.severity == .warning })
    }

    func testTheUsersTableBeatsTheComment() {
        let tp = run(program, radii: [1: 3])
        XCTAssertEqual(tp.compensationUse[1]?.radius ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(tp.compensationUse[1]?.source, .table)
    }

    func testTheProgramsOwnG10BeatsTheTable() {
        let text = "G10 L12 P1 R4\n" + program
        let tp = run(text, radii: [1: 3])
        XCTAssertEqual(tp.compensationUse[1]?.radius ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(tp.compensationUse[1]?.source, .program)
    }

    func testWearIsAddedToTheRadius() {
        let tp = run("G10 L12 P1 R4\nG10 L13 P1 R0.1\nT1 M6\nG41 D1 G01 X1 F100\nG40 G01 X2\n")
        XCTAssertEqual(tp.compensationUse[1]?.radius ?? 0, 4.1, accuracy: 1e-9)
    }

    func testRegisterThatIsNotTheToolNumberIsNotGuessed() {
        let tp = run("(10 MM END MILL)\nT1 M6\nG41 D2 G01 X1 F100\nG40 G01 X2\n")
        XCTAssertNil(tp.compensationUse[2]?.radius)
        XCTAssertEqual(tp.compensationUse[2]?.source, .missing)
        XCTAssertTrue(tp.diagnostics.contains { $0.severity == .warning && $0.message.contains("D2") })
    }

    func testInchProgramsGiveRadiusInMillimetres() {
        let tp = run("G20\n(1/4 FLAT ENDMILL)\nT1 M6\nG41 D1 G01 X1 F100\nG40 G01 X2\n")
        XCTAssertEqual(tp.compensationUse[1]?.radius ?? 0, 3.175, accuracy: 1e-9)
    }

    func testG10RadiusInInches() {
        let tp = run("G20\nG10 L12 P1 R0.125\nT1 M6\nG41 D1 G01 X1 F100\nG40 G01 X2\n")
        XCTAssertEqual(tp.compensationUse[1]?.radius ?? 0, 3.175, accuracy: 1e-9)
    }

    func testToolListAtTheTopOfTheProgram() {
        let text = "( T18 | FR_10 | H18 | D18 | WEAR COMP | TOOL DIA. - 10. | XY STOCK TO LEAVE - -3. )\nN104 T18 M6\nN116 G41 D18 Y-67.5 F2500.\nG40 G01 X5\n"
        let tp = run(text)
        XCTAssertEqual(tp.compensationUse[18]?.radius ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(tp.compensationUse[18]?.source, .comment(line: 0))
    }

    func testCommentWithToolAndSizeFarAboveTheToolChange() {
        let text = "( ------- T02 DRILL 0.8450\" (BORE_1 PRE-DRILL) ------- )\nG00 G40 D0\nG90 G54\nT02 M06\nG41 D2 G01 X1 F100\nG40 G01 X2\n"
        let tp = run(text, inches: true)
        XCTAssertEqual(tp.compensationUse[2]?.radius ?? 0, 0.845 * 25.4 / 2, accuracy: 1e-6)
    }

    func testToolListWrittenBeforeG20IsReadInInches() {
        let text = "(T1 D=0.5 FLAT END MILL)\nG20\nT1 M6\nG41 D1 G01 X1 F100\nG40 G01 X2\n"
        XCTAssertEqual(run(text).compensationUse[1]?.radius ?? 0, 6.35, accuracy: 1e-9)
    }

    func testTheOffsetRegisterIsModal() {
        let text = "(10 MM END MILL)\nT1 M6\nD1\nG00 X0 Y-10\nG41 G01 X0 Y0 F100\nG01 X10\nG40 G01 X10 Y-10\n"
        let tp = run(text)
        XCTAssertEqual(tp.compensationUse[1]?.radius ?? 0, 5, accuracy: 1e-9)
        XCTAssertFalse(tp.diagnostics.contains { $0.severity == .warning })
    }

    func testD0MeansNoOffsetAndIsNotAWarning() {
        let tp = run("G41 G01 X1 F100\nG40 G01 X2\n")
        XCTAssertFalse(tp.diagnostics.contains { $0.severity == .warning })
        XCTAssertTrue(tp.compensationUse.isEmpty)
    }

    func testEveryRegisterUsedIsReported() {
        let tp = run("T1 M6\nG41 D1 G01 X1 F100\nG40 G01 X2\nT2 M6\nG42 D2 G01 X3\nG40 G01 X4\n", radii: [1: 2])
        XCTAssertEqual(Set(tp.compensationUse.keys), [1, 2])
        XCTAssertEqual(tp.compensationUse[1]?.source, .table)
        XCTAssertEqual(tp.compensationUse[2]?.source, .missing)
        XCTAssertEqual(tp.compensationUse[2]?.tool, 2)
    }
}
