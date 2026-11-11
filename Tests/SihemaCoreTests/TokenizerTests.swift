import XCTest
@testable import SihemaCore

final class TokenizerTests: XCTestCase {
    private func words(_ text: String, line: Int = 0) -> [GCodeWord] {
        let p = GCodeTokenizer.tokenize(text)
        return Array(p.words[p.wordRange(line: line)])
    }

    func testBasicWords() {
        let w = words("G01 X10.5 Y-2 F100\n")
        XCTAssertEqual(w.count, 4)
        XCTAssertEqual(w[0].character, "G")
        XCTAssertEqual(w[0].value, 1)
        XCTAssertEqual(w[1].character, "X")
        XCTAssertEqual(w[1].value, 10.5, accuracy: 1e-12)
        XCTAssertTrue(w[1].hadDecimal)
        XCTAssertEqual(w[2].value, -2)
        XCTAssertFalse(w[2].hadDecimal)
        XCTAssertEqual(w[3].value, 100)
    }

    func testTrailingAndLeadingDecimalPoint() {
        let w = words("X10. Y.5 Z-.25")
        XCTAssertEqual(w[0].value, 10, accuracy: 1e-12)
        XCTAssertEqual(w[1].value, 0.5, accuracy: 1e-12)
        XCTAssertEqual(w[2].value, -0.25, accuracy: 1e-12)
    }

    func testCommentsAreSkipped() {
        let p = GCodeTokenizer.tokenize("G0 X1 (move over) Y2 ; rest of line\nG1 X3\n")
        XCTAssertEqual(p.lineCount, 2)
        XCTAssertEqual(p.wordRange(line: 0).count, 3)
        XCTAssertTrue(p.lineFlags[0].contains(.comment))
        XCTAssertFalse(p.lineFlags[1].contains(.comment))
    }

    func testLineEndings() {
        let p = GCodeTokenizer.tokenize("G1 X1\r\nG1 X2\rG1 X3\nG1 X4")
        XCTAssertEqual(p.lineCount, 4)
        XCTAssertEqual(p.words.count, 8)
    }

    func testTrailingNewlineDoesNotAddALine() {
        XCTAssertEqual(GCodeTokenizer.tokenize("G1 X1\n").lineCount, 1)
        XCTAssertEqual(GCodeTokenizer.tokenize("\n").lineCount, 1)
        XCTAssertEqual(GCodeTokenizer.tokenize("").lineCount, 0)
    }

    func testLowercaseAndSpaces() {
        let w = words("g1 x 5 y-3")
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(w[0].character, "G")
        XCTAssertEqual(w[1].character, "X")
        XCTAssertEqual(w[1].value, 5)
        XCTAssertEqual(w[2].value, -3)
    }

    func testBlockSkip() {
        let p = GCodeTokenizer.tokenize("/G1 X1\n/2 G1 X2\nG1 X3\n")
        XCTAssertTrue(p.lineFlags[0].contains(.blockSkip))
        XCTAssertTrue(p.lineFlags[1].contains(.blockSkip))
        XCTAssertFalse(p.lineFlags[2].contains(.blockSkip))
        XCTAssertEqual(p.wordRange(line: 1).count, 2)
    }

    func testMacroLinesAreFlagged() {
        let p = GCodeTokenizer.tokenize("#100=5\nG1 X[#100+1]\n")
        XCTAssertTrue(p.lineFlags[0].contains(.macro))
        XCTAssertEqual(p.wordRange(line: 0).count, 0)
        XCTAssertTrue(p.lineFlags[1].contains(.macro))
        let w = Array(p.words[p.wordRange(line: 1)])
        XCTAssertEqual(w.count, 2)
        XCTAssertFalse(w[1].hasValueFlag)
        XCTAssertTrue(w[1].isMacroWord)
    }

    func testProgramDelimiterAndNumber() {
        let p = GCodeTokenizer.tokenize("%\nO1234\nG0 X1\n%\n")
        XCTAssertEqual(p.lineCount, 4)
        XCTAssertTrue(p.lineFlags[0].contains(.delimiter))
        let o = p.words[p.wordRange(line: 1).lowerBound]
        XCTAssertEqual(o.character, "O")
        XCTAssertEqual(o.value, 1234)
        XCTAssertTrue(p.lineFlags[3].contains(.delimiter))
    }

    func testWordOffsetsPointAtTheLetter() {
        let text = "G1 X10\nG1 Y20\n"
        let p = GCodeTokenizer.tokenize(text)
        let bytes = Array(text.utf8)
        for word in p.words {
            XCTAssertEqual(bytes[Int(word.offset)] & 0xDF, word.letter)
        }
    }

    func testPrecision() {
        let w = words("X0.001 Y123456.789 Z-0.0005")
        XCTAssertEqual(w[0].value, 0.001, accuracy: 1e-15)
        XCTAssertEqual(w[1].value, 123456.789, accuracy: 1e-9)
        XCTAssertEqual(w[2].value, -0.0005, accuracy: 1e-15)
    }

    func testManyLines() {
        var text = ""
        for i in 0..<5000 { text += "G01 X\(i) Y\(i) F100\n" }
        let p = GCodeTokenizer.tokenize(text)
        XCTAssertEqual(p.lineCount, 5000)
        XCTAssertEqual(p.words.count, 20000)
        XCTAssertEqual(p.words[p.wordRange(line: 4999)][p.wordRange(line: 4999).lowerBound + 1].value, 4999)
    }

    func testTokenizesData() {
        let data = Data("G1 X1\nG1 X2\n".utf8)
        XCTAssertEqual(GCodeTokenizer.tokenize(data).lineCount, 2)
    }
}
