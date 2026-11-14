import Foundation

/// A cutter size read from the comment next to a tool change, for when the machine's offset table is not known.
public struct ToolGuess: Sendable, Equatable {
    public var tool: Int
    /// Cutter radius in millimetres.
    public var radius: Double
    /// Zero-based line of the comment the size came from.
    public var line: Int
}

/// Reads tool sizes out of the comments CAM systems put next to a tool change, such as `(T1 D=10. CR=0.)`,
/// `(10 MM END MILL)` or `(1/2 FLAT ENDMILL)`. These are guesses, and the app says so wherever it uses one.
public enum ToolComments {
    private static let toolWords = ["FLAT", "END", "BALL", "BULL", "MILL", "EM", "ENDMILL", "CUTTER", "ROUGH",
                                    "FINISH", "FACE", "SLOT", "KEYSEAT", "CHAMFER", "SPOT", "DRILL", "REAM",
                                    "TAP", "BORE", "ENGRAV", "TAPER", "HELICAL", "CORNER"]

    /// Tool number to size for every tool change in the program.
    public static func guesses(in program: TokenizedProgram, defaultInches: Bool) -> [Int: ToolGuess] {
        var result: [Int: ToolGuess] = [:]
        let count = program.lineCount
        // the units the program works in, so a tool list at the top is read correctly before the G20/G21
        var inches = defaultInches
        findUnits: for line in 0..<count {
            for word in program.words[program.wordRange(line: line)] where word.letter == 71 && word.hasValueFlag {
                let code = (word.value * 10).clampedInt
                if code == 200 { inches = true; break findUnits }
                if code == 210 { inches = false; break findUnits }
            }
        }
        // 1. a comment that names its tool and its size: `(T1 D=10.)`, `( T18 | FR_10 | TOOL DIA. - 10. )`
        for line in 0..<count {
            let text = String(decoding: program.lineBytes(line), as: UTF8.self)
            for comment in commentTexts(in: text) {
                guard let tool = singleToolNumber(in: comment),
                      let diameter = parseDiameter(comment, inches: inches), result[tool] == nil else { continue }
                result[tool] = ToolGuess(tool: tool, radius: diameter / 2, line: line)
            }
        }
        // 2. a comment next to the tool change itself
        for line in 0..<count {
            let range = program.wordRange(line: line)
            var toolNumber: Int?
            var hasM6 = false
            for word in program.words[range] where word.hasValueFlag {
                switch word.letter {
                case 71: // G
                    let code = (word.value * 10).clampedInt
                    if code == 200 { inches = true } else if code == 210 { inches = false }
                case 84: toolNumber = word.value.clampedInt
                case 77: if word.value.clampedInt == 6 { hasM6 = true }
                default: break
                }
            }
            guard let tool = toolNumber, tool > 0 else { continue }
            if !hasM6 {
                // the change may be on the next line: `T1` then `M6`
                guard line + 1 < count else { continue }
                let next = program.wordRange(line: line + 1)
                guard program.words[next].contains(where: { $0.letter == 77 && $0.value.clampedInt == 6 }) else { continue }
            }
            if result[tool] != nil { continue }
            // the comment on the same line, then the comment lines just above it, then the line below
            var candidates: [Int] = [line]
            var up = line - 1
            while up >= 0 && candidates.count < 4 && isCommentOnly(program, up) {
                candidates.append(up)
                up -= 1
            }
            if line + 1 < count && isCommentOnly(program, line + 1) { candidates.append(line + 1) }
            for candidate in candidates {
                let text = String(decoding: program.lineBytes(candidate), as: UTF8.self)
                if let diameter = parseDiameter(text, inches: inches) {
                    result[tool] = ToolGuess(tool: tool, radius: diameter / 2, line: candidate)
                    break
                }
            }
        }
        return result
    }

    /// The text inside (...) comments and after a semicolon.
    private static func commentTexts(in line: String) -> [String] {
        var texts: [String] = []
        var current = ""
        var depth = 0
        for ch in line {
            if depth == 0 && ch == ";" {
                break
            } else if ch == "(" {
                if depth == 0 { current = "" } else { current.append(ch) }
                depth += 1
            } else if ch == ")" && depth > 0 {
                depth -= 1
                if depth == 0 { texts.append(current) } else { current.append(ch) }
            } else if depth > 0 {
                current.append(ch)
            }
        }
        if depth > 0 { texts.append(current) } // an unterminated comment
        if let semi = line.firstIndex(of: ";") { texts.append(String(line[line.index(after: semi)...])) }
        return texts
    }

    /// The tool number named in a comment (T18, T01), when exactly one is.
    private static func singleToolNumber(in comment: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[Tt]0*([0-9]{1,3})(?![0-9A-Za-z])"#) else { return nil }
        let range = NSRange(comment.startIndex..., in: comment)
        var found = Set<Int>()
        for match in regex.matches(in: comment, range: range) {
            if let r = Range(match.range(at: 1), in: comment), let n = Int(comment[r]), n > 0 { found.insert(n) }
        }
        return found.count == 1 ? found.first : nil
    }

    private static func isCommentOnly(_ program: TokenizedProgram, _ line: Int) -> Bool {
        let bytes = program.lineBytes(line)
        var seenOpen = false
        for b in bytes {
            if b == 32 || b == 9 || b == 13 { continue }
            if b == 40 { seenOpen = true; break }
            if b == 37 || b == 59 { return false }
            if b == 79 || b == 78 { continue } // a program or sequence number in front of it
            if b >= 48 && b <= 57 { continue }
            return false
        }
        return seenOpen
    }

    /// The cutter diameter in millimetres found in a comment, or nil. `inches` says what a bare number means.
    public static func parseDiameter(_ text: String, inches: Bool) -> Double? {
        let upper = text.uppercased()
        let toInches = 25.4
        func accept(_ mm: Double) -> Double? { (mm >= 0.05 && mm <= 500) ? mm : nil }

        // D=10.  (Fusion, HSMWorks, many Haas posts): the number is in the program's units
        if let value = firstNumber(in: upper, after: #"\bD\s*=\s*"#) {
            return accept(inches ? value * toInches : value)
        }
        // DIA 10, DIA=10, DIAMETER 10, a diameter sign
        if let value = firstNumber(in: upper, after: #"(?:\bDIA(?:METER|\.)?\s*[=:\-]?\s*|[Ø⌀]\s*)"#) {
            return accept(inches ? value * toInches : value)
        }
        // 10 MM, 6.35MM
        if let value = firstNumber(in: upper, before: #"\s*MM\b"#) {
            return accept(value)
        }
        // 1/2, 3/8 and so on: fractions are inches
        if let fraction = firstFraction(in: upper), hasToolWord(upper) {
            return accept(fraction * toInches)
        }
        // 0.25 IN, .5", 1 INCH
        if let value = firstNumber(in: upper, before: #"\s*(?:INCH|IN\b|")"#) {
            return accept(value * toInches)
        }
        // a bare size in front of a tool word: .25 FLAT ENDMILL, 12. FACE MILL
        if hasToolWord(upper), let value = firstNumber(in: upper, before: #"\s+(?:FLAT|END|BALL|BULL|EM\b|CORNER|CUTTER|FACE|MILL)"#) {
            return accept(inches ? value * toInches : value)
        }
        return nil
    }

    private static func hasToolWord(_ upper: String) -> Bool {
        toolWords.contains { upper.contains($0) }
    }

    private static func number(_ text: Substring) -> Double? {
        var s = String(text)
        if s.hasPrefix(".") { s = "0" + s }
        if s.hasSuffix(".") { s += "0" }
        return Double(s)
    }

    private static let numberPattern = #"([0-9]*\.?[0-9]+|[0-9]+\.)"#

    private static func firstNumber(in text: String, after prefix: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: prefix + numberPattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: match.numberOfRanges - 1), in: text) else { return nil }
        return number(text[r])
    }

    private static func firstNumber(in text: String, before suffix: String) -> Double? {
        // the number must not be glued to a letter or digit in front of it (OP1 FACE is not a 1 mm cutter)
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Z0-9.])"# + numberPattern + suffix) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return number(text[r])
    }

    private static func firstFraction(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"\b([0-9]{1,2})\s*/\s*([0-9]{1,2})\b"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
              let numerator = Double(text[a]), let denominator = Double(text[b]), denominator > 0 else { return nil }
        let value = numerator / denominator
        return (value > 0 && value <= 6) ? value : nil
    }
}
