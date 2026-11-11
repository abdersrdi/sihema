import XCTest
@testable import SihemaCore

final class MacroTests: XCTestCase {
    private func run(_ text: String, config: MachineConfig = MachineConfig()) -> Toolpath {
        FanucInterpreter(config: config).run(text: text)
    }

    private func xs(_ tp: Toolpath) -> [Double] { tp.segments.map { $0.end.x } }

    func testExpressionPrecedence() {
        XCTAssertEqual(run("#1=[2+3*4]\nG01 X#1 F100\n").finalPosition.x, 14, accuracy: 1e-9)
        XCTAssertEqual(run("#1=[[2+3]*4]\nG01 X#1 F100\n").finalPosition.x, 20, accuracy: 1e-9)
        XCTAssertEqual(run("#1=[10-4-3]\nG01 X#1 F100\n").finalPosition.x, 3, accuracy: 1e-9)
        XCTAssertEqual(run("#1=[20/4/2]\nG01 X#1 F100\n").finalPosition.x, 2.5, accuracy: 1e-9)
        XCTAssertEqual(run("#1=[-3+10]\nG01 X#1 F100\n").finalPosition.x, 7, accuracy: 1e-9)
    }

    func testFunctions() {
        func value(_ expression: String) -> Double {
            run("#1=\(expression)\nG01 X#1 F100\n").finalPosition.x
        }
        XCTAssertEqual(value("SIN[30]"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(value("COS[60]"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(value("TAN[45]"), 1, accuracy: 1e-9)
        XCTAssertEqual(value("SQRT[16]"), 4, accuracy: 1e-9)
        XCTAssertEqual(value("ABS[-3.5]"), 3.5, accuracy: 1e-9)
        XCTAssertEqual(value("ATAN[1]/[1]"), 45, accuracy: 1e-9)
        XCTAssertEqual(value("ATAN[-1]/[1]"), 315, accuracy: 1e-9)
        XCTAssertEqual(value("FIX[2.7]"), 2, accuracy: 1e-9)
        XCTAssertEqual(value("FUP[2.1]"), 3, accuracy: 1e-9)
        XCTAssertEqual(value("ROUND[2.5]"), 3, accuracy: 1e-9)
        XCTAssertEqual(value("EXP[0]"), 1, accuracy: 1e-9)
        XCTAssertEqual(value("LN[1]"), 0, accuracy: 1e-9)
        XCTAssertEqual(value("ASIN[0.5]"), 30, accuracy: 1e-9)
        XCTAssertEqual(value("[7 MOD 4]"), 3, accuracy: 1e-9)
        XCTAssertEqual(value("[6 AND 3]"), 2, accuracy: 1e-9)
        XCTAssertEqual(value("[4 OR 1]"), 5, accuracy: 1e-9)
    }

    func testVariablesCanReferenceVariables() {
        let tp = run("#1=4\n#2=#1\n#3=[#2*2]\n#[#1+1]=9\nG01 X#3 Y#5 F100\n")
        XCTAssertEqual(tp.finalPosition.x, 8, accuracy: 1e-9)
        XCTAssertEqual(tp.finalPosition.y, 9, accuracy: 1e-9)
        let nested = run("#5=7\n#6=5\nG01 X#[#6] F100\n")
        XCTAssertEqual(nested.finalPosition.x, 7, accuracy: 1e-9)
    }

    func testNamedVariables() {
        let tp = run("#<depth> = 3\nG01 X#<depth> F100\n")
        XCTAssertEqual(tp.finalPosition.x, 3, accuracy: 1e-9)
    }

    func testVacantVariableLeavesTheWordOut() {
        let tp = run("G01 X#100 Y5 F100\n")
        XCTAssertEqual(tp.segments.count, 1)
        XCTAssertEqual(tp.finalPosition.x, 0, accuracy: 1e-9)
        XCTAssertEqual(tp.finalPosition.y, 5, accuracy: 1e-9)
    }

    func testIfGotoSkipsBlocks() {
        let tp = run("#1=10\nIF [#1 GT 5] GOTO 20\nG01 X1 F100\nN20 G01 X2 F100\n")
        XCTAssertEqual(xs(tp), [2])
        let notTaken = run("#1=1\nIF [#1 GT 5] GOTO 20\nG01 X1 F100\nN20 G01 X2 F100\n")
        XCTAssertEqual(xs(notTaken), [1, 2])
    }

    func testIfThenAssignment() {
        let tp = run("#1=5\nIF [#1 EQ 5] THEN #2=9\nG01 X#2 F100\n")
        XCTAssertEqual(tp.finalPosition.x, 9, accuracy: 1e-9)
        let skipped = run("#1=4\nIF [#1 EQ 5] THEN #2=9\nG01 X[#2+1] F100\n")
        XCTAssertEqual(skipped.finalPosition.x, 1, accuracy: 1e-9)
    }

    func testWhileLoop() {
        let tp = run("#1=0\nWHILE [#1 LT 3] DO1\nG01 X[#1*10] F100\n#1=[#1+1]\nEND1\nG01 Y5\n")
        XCTAssertEqual(tp.segments.count, 4)
        XCTAssertEqual(xs(tp), [0, 10, 20, 20])
        XCTAssertEqual(tp.finalPosition.y, 5, accuracy: 1e-9)
    }

    func testNestedWhileLoops() {
        let tp = run("""
        #1=0
        WHILE [#1 LT 2] DO1
        #2=0
        WHILE [#2 LT 3] DO2
        G01 X[#1*10+#2] F100
        #2=[#2+1]
        END2
        #1=[#1+1]
        END1
        """)
        XCTAssertEqual(xs(tp), [0, 1, 2, 10, 11, 12])
    }

    func testWhileThatNeverRunsSkipsToEnd() {
        let tp = run("#1=5\nWHILE [#1 LT 3] DO1\nG01 X99 F100\nEND1\nG01 X1\n")
        XCTAssertEqual(xs(tp), [1])
    }

    func testGotoLoop() {
        let tp = run("#1=0\nN10 G01 X#1 F100\n#1=[#1+1]\nIF [#1 LT 3] GOTO 10\n")
        XCTAssertEqual(xs(tp), [0, 1, 2])
    }

    func testEndlessLoopIsStopped() {
        var config = MachineConfig()
        config.maxExecutedBlocks = 500
        let tp = run("N10 #1=1\nGOTO 10\n", config: config)
        XCTAssertTrue(tp.diagnostics.contains { $0.severity == .error && $0.message.contains("loop") })
    }

    func testCurrentPositionVariable() {
        let tp = run("G01 X10 F100\n#1=#5001\nG01 X[#1+5]\n")
        XCTAssertEqual(tp.finalPosition.x, 15, accuracy: 1e-9)
    }

    func testSubprogramCall() {
        let tp = run("G01 X1 F100\nM98 P1000\nG01 X3\nM30\nO1000\nG01 X2\nM99\n")
        XCTAssertEqual(xs(tp), [1, 2, 3])
    }

    func testSubprogramRepeat() {
        let withL = run("G91 G01 F100\nM98 P1000 L3\nM30\nO1000\nG01 X1\nM99\n")
        XCTAssertEqual(withL.finalPosition.x, 3, accuracy: 1e-9)
        let withDigits = run("G91 G01 F100\nM98 P20100\nM30\nO100\nG01 X1\nM99\n")
        XCTAssertEqual(withDigits.finalPosition.x, 2, accuracy: 1e-9)
    }

    func testNestedSubprograms() {
        let tp = run("""
        G01 X1 F100
        M98 P10
        G01 X5
        M30
        O10
        G01 X2
        M98 P20
        G01 X4
        M99
        O20
        G01 X3
        M99
        """)
        XCTAssertEqual(xs(tp), [1, 2, 3, 4, 5])
    }

    func testHaasLocalSubprogram() {
        let tp = run("M97 P100\nG01 X7 F100\nM30\nN100 G01 X4 F100\nM99\n")
        XCTAssertEqual(xs(tp), [4, 7])
    }

    func testMacroCallPassesArguments() {
        let tp = run("G65 P9010 A5. B3.\nM30\nO9010\nG01 X[#1+#2] F100\nM99\n")
        XCTAssertEqual(tp.segments.count, 1)
        XCTAssertEqual(tp.finalPosition.x, 8, accuracy: 1e-9)
    }

    func testMacroCallRestoresLocalVariables() {
        let tp = run("#1=7\nG65 P9010 A2.\nG01 X#1 F100\nM30\nO9010\n#1=[#1+100]\nM99\n")
        XCTAssertEqual(tp.finalPosition.x, 7, accuracy: 1e-9)
    }

    func testCommonVariablesSurviveMacroCalls() {
        let tp = run("#100=1\nG65 P9010\nG01 X#100 F100\nM30\nO9010\n#100=[#100+4]\nM99\n")
        XCTAssertEqual(tp.finalPosition.x, 5, accuracy: 1e-9)
    }

    func testMissingSubprogramIsReported() {
        let tp = run("M98 P555\nG01 X1 F100\n")
        XCTAssertTrue(tp.diagnostics.contains { $0.severity == .error && $0.message.contains("O555") })
        XCTAssertEqual(tp.segments.count, 1)
    }

    func testRunawayRecursionIsStopped() {
        let tp = run("M98 P1\nM30\nO1\nM98 P1\nM99\n")
        XCTAssertTrue(tp.diagnostics.contains { $0.message.contains("nested") })
    }

    func testUserAlarmStopsTheProgram() {
        let tp = run("#3000=1 (BAD STOCK)\nG01 X1 F100\n")
        XCTAssertEqual(tp.segments.count, 0)
        XCTAssertTrue(tp.diagnostics.contains { $0.severity == .error && $0.message.contains("BAD STOCK") })
    }

    func testDivisionByZeroIsReported() {
        let tp = run("#1=[1/0]\nG01 X1 F100\n")
        XCTAssertTrue(tp.diagnostics.contains { $0.severity == .error && $0.message.contains("Division") })
        XCTAssertEqual(tp.segments.count, 1)
    }

    func testReadOnlyVariableIsReported() {
        let tp = run("#5001=3\nG01 X1 F100\n")
        XCTAssertTrue(tp.diagnostics.contains { $0.message.contains("read-only") })
    }

    func testCommentsInMacroLinesAreIgnored() {
        let tp = run("#1=5 (SET FIVE)\nG01 X#1 (MOVE) F100\n")
        XCTAssertEqual(tp.finalPosition.x, 5, accuracy: 1e-9)
    }

    func testAddressWordsWithExpressionsKeepOtherWords() {
        let tp = run("N10 G01 X[2*3] Y#1 Z-[1+1] F250\n")
        XCTAssertEqual(tp.finalPosition.x, 6, accuracy: 1e-9)
        XCTAssertEqual(tp.finalPosition.z, -2, accuracy: 1e-9)
        XCTAssertEqual(tp.segments[0].feed, 250, accuracy: 1e-9)
    }

    func testArcWithComputedCenter() {
        let tp = run("#1=10\nG00 X#1 Y0\nG03 X0 Y#1 I[0-#1] J0 F100\n")
        XCTAssertEqual(tp.segments[1].center.x, 0, accuracy: 1e-9)
        XCTAssertEqual(tp.segments[1].arcGeometry.sweep, Double.pi / 2, accuracy: 1e-9)
    }

    func testBlockOrderDoesNotMatterForLabels() {
        let tp = run("GOTO 30\nG01 X1 F100\nN30 G01 X3 F100\n")
        XCTAssertEqual(xs(tp), [3])
    }

    func testUnknownLabelIsReported() {
        let tp = run("GOTO 99\nG01 X1 F100\n")
        XCTAssertTrue(tp.diagnostics.contains { $0.message.contains("N99") })
    }

    // MARK: Units

    func testInchProgramWithoutG20IsFlagged() {
        let tp = run("G90\nG01 X0.125 Y0 F10.\nG01 X1.0 F10.\nG01 X2.5 F20.\n")
        XCTAssertTrue(tp.diagnostics.contains { $0.severity == .warning && $0.message.contains("inches") })
    }

    func testMillimetreProgramIsNotFlagged() {
        let tp = run("G90\nG01 X120 Y0 F800\nG01 X10 F1200\nG01 X250 F900\n")
        XCTAssertFalse(tp.diagnostics.contains { $0.message.contains("inches") })
    }

    func testExplicitUnitsSuppressTheWarning() {
        let tp = run("G20\nG01 X0.125 F10.\nG01 X1.0 F10.\n")
        XCTAssertFalse(tp.diagnostics.contains { $0.message.contains("inches") })
    }

    func testDefaultInchesConfiguration() {
        var config = MachineConfig()
        config.defaultInches = true
        let tp = run("G01 X1 F10\n", config: config)
        XCTAssertEqual(tp.segments[0].end.x, 25.4, accuracy: 1e-9)
        XCTAssertEqual(tp.segments[0].feed, 254, accuracy: 1e-9)
        XCTAssertTrue(tp.diagnostics.isEmpty)
    }

    // MARK: Tokenizer additions

    func testKeywordLinesAreFlaggedAsMacroLines() {
        let p = GCodeTokenizer.tokenize("GOTO10\nEND1\nWHILE[#1 LT 2]DO1\nG01 X1\n")
        XCTAssertTrue(p.lineFlags[0].contains(.macro))
        XCTAssertTrue(p.lineFlags[1].contains(.macro))
        XCTAssertTrue(p.lineFlags[2].contains(.macro))
        XCTAssertFalse(p.lineFlags[3].contains(.macro))
    }

    func testLineBytes() {
        let p = GCodeTokenizer.tokenize("G1 X1\r\nG1 X2\nG1 X3")
        XCTAssertEqual(String(decoding: p.lineBytes(0), as: UTF8.self), "G1 X1")
        XCTAssertEqual(String(decoding: p.lineBytes(1), as: UTF8.self), "G1 X2")
        XCTAssertEqual(String(decoding: p.lineBytes(2), as: UTF8.self), "G1 X3")
    }
}
