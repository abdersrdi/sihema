import Foundation

public enum DiffKind: Sendable {
    case same, removed, added
}

/// One row of a side-by-side comparison. Line numbers are zero-based positions in the original texts.
public struct DiffRow: Sendable, Equatable {
    public var kind: DiffKind
    public var oldLine: Int?
    public var newLine: Int?
}

public struct CompareOptions: Sendable {
    /// Ignore the N line numbers.
    public var ignoreSequenceNumbers = true
    /// Lines that are empty after removing comments are not compared.
    public var skipEmptyLines = true

    public init() {}
}

/// Compares two G-code programs line by line, ignoring differences that do not change what the machine does:
/// spacing, upper or lower case, `G1` against `G01`, `10.0` against `10`, comments and (optionally) N numbers.
public enum ProgramCompare {
    public static func compare(old: String, new: String, options: CompareOptions = CompareOptions()) -> [DiffRow] {
        let a = canonicalLines(old, options: options)
        let b = canonicalLines(new, options: options)
        let difference = b.map(\.text).difference(from: a.map(\.text))

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var rows: [DiffRow] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count && removed.contains(i) {
                rows.append(DiffRow(kind: .removed, oldLine: a[i].line, newLine: nil))
                i += 1
            } else if j < b.count && inserted.contains(j) {
                rows.append(DiffRow(kind: .added, oldLine: nil, newLine: b[j].line))
                j += 1
            } else if i < a.count && j < b.count {
                rows.append(DiffRow(kind: .same, oldLine: a[i].line, newLine: b[j].line))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return rows
    }

    /// Number of changed rows (added plus removed).
    public static func changeCount(_ rows: [DiffRow]) -> Int {
        rows.filter { $0.kind != .same }.count
    }

    private struct Canonical {
        var line: Int
        var text: String
    }

    private static func canonicalLines(_ text: String, options: CompareOptions) -> [Canonical] {
        let program = GCodeTokenizer.tokenize(text)
        var result: [Canonical] = []
        result.reserveCapacity(program.lineCount)
        for line in 0..<program.lineCount {
            var parts: [String] = []
            for w in program.words[program.wordRange(line: line)] {
                if options.ignoreSequenceNumbers && w.letter == 78 { continue }
                let letter = String(UnicodeScalar(w.letter))
                parts.append(w.hasValueFlag ? letter + number(w.value) : letter)
            }
            var canonical = parts.joined(separator: " ")
            if program.lineFlags[line].contains(.macro) {
                // macro lines are compared by their text without spaces and comments
                canonical = macroText(program, line: line)
            }
            if canonical.isEmpty && options.skipEmptyLines { continue }
            result.append(Canonical(line: line, text: canonical))
        }
        return result
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    private static func macroText(_ program: TokenizedProgram, line: Int) -> String {
        var out: [UInt8] = []
        var depth = 0
        for byte in program.lineBytes(line) {
            if byte == 40 { depth += 1; continue }
            if byte == 41 { depth = max(0, depth - 1); continue }
            if depth > 0 || byte == 32 || byte == 9 { continue }
            out.append(byte >= 97 && byte <= 122 ? byte - 32 : byte)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
