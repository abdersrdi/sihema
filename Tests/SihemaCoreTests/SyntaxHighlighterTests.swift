import XCTest
@testable import SihemaCore

final class SyntaxHighlighterTests: XCTestCase {
    private func spans(_ text: String) -> [SyntaxSpan] {
        SyntaxHighlighter.spans(in: Array(text.utf8))
    }

    private func pieces(_ text: String) -> [(String, SyntaxKind)] {
        let bytes = Array(text.utf8)
        return SyntaxHighlighter.spans(in: bytes).map {
            (String(decoding: bytes[$0.start..<$0.end], as: UTF8.self), $0.kind)
        }
    }

    func testWordsGetTheirKinds() {
        let p = pieces("N10 G01 X10.5 Y-2 Z.5 F100 S1200 T3 M06")
        XCTAssertEqual(p.map(\.0), ["N10", "G01", "X10.5", "Y-2", "Z.5", "F100", "S1200", "T3", "M06"])
        XCTAssertEqual(p.map(\.1), [.sequence, .generalCode, .axis, .axis, .axis, .feed, .speed, .tool, .miscCode])
    }

    func testCommentsAreOneSpan() {
        let p = pieces("G0 X1 (move over) Y2 ; rest of line")
        XCTAssertEqual(p.map(\.0), ["G0", "X1", "(move over)", "Y2", "; rest of line"])
        XCTAssertEqual(p.map(\.1), [.generalCode, .axis, .comment, .axis, .comment])
    }

    func testLettersInsideCommentsAreNotWords() {
        let p = pieces("(G01 X5 test)")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].1, .comment)
    }

    func testLowercaseWordsAreColoured() {
        let p = pieces("g1 x5 m30")
        XCTAssertEqual(p.map(\.1), [.generalCode, .axis, .miscCode])
    }

    func testMacroParts() {
        let p = pieces("#100=[#5001+2] G01 X#<depth>")
        XCTAssertEqual(p.map(\.0), ["#100", "=", "[", "#5001", "]", "G01", "X", "#<depth>"])
        XCTAssertEqual(p[0].1, .macro)
        XCTAssertEqual(p[2].1, .macro)
    }

    func testKeywordsAreMacroSpans() {
        let p = pieces("WHILE[#1 LT 3]DO1\nGOTO10")
        XCTAssertTrue(p.contains { $0.0 == "WHILE" && $0.1 == .macro })
        XCTAssertTrue(p.contains { $0.0 == "GOTO" && $0.1 == .macro })
        XCTAssertTrue(p.contains { $0.0 == "LT" && $0.1 == .macro })
    }

    func testDelimitersAndBlockSkip() {
        let p = pieces("%\n/G01 X1\n/2 G01 X2\n")
        XCTAssertEqual(p[0].1, .delimiter)
        XCTAssertTrue(p.contains { $0.0 == "/" && $0.1 == .delimiter })
        XCTAssertTrue(p.contains { $0.0 == "/2" && $0.1 == .delimiter })
    }

    func testSpansAreInOrderAndDoNotOverlap() {
        let all = spans("N10 G01 X10 (a) Y[#1+1] ; b\n#2=3 M30\n")
        for k in 1..<all.count {
            XCTAssertGreaterThanOrEqual(all[k].start, all[k - 1].end)
        }
    }

    func testOffsetsAreBytesNotCharacters() {
        // the comment contains a two-byte letter, so G01 starts at byte 11
        let bytes = Array("(caf\u{00E9}) G01".utf8)
        let found = SyntaxHighlighter.spans(in: bytes)
        XCTAssertEqual(found.last?.start, 8)
        XCTAssertEqual(found.last?.end, 11)
    }

    func testEmptyAndBlankInput() {
        XCTAssertTrue(spans("").isEmpty)
        XCTAssertTrue(spans("  \n\t\n").isEmpty)
    }
}
