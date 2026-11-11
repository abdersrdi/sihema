import Foundation

/// One G-code word, for example `X10.5` or `G01`.
public struct GCodeWord: Sendable, Equatable {
    public var letter: UInt8      // ASCII uppercase letter, for example 71 for "G"
    public var flags: UInt8
    public var offset: Int32      // byte offset of the letter in the source text
    public var value: Double

    public static let hasValue: UInt8 = 1
    public static let hadDecimalPoint: UInt8 = 2
    public static let hadSign: UInt8 = 4
    /// The value is an expression (`[...]` or `#var`). Not evaluated yet, so `value` is 0.
    public static let isMacro: UInt8 = 8

    public init(letter: UInt8, flags: UInt8, offset: Int32, value: Double) {
        self.letter = letter
        self.flags = flags
        self.offset = offset
        self.value = value
    }

    public var hasValueFlag: Bool { flags & GCodeWord.hasValue != 0 }
    public var hadDecimal: Bool { flags & GCodeWord.hadDecimalPoint != 0 }
    public var isMacroWord: Bool { flags & GCodeWord.isMacro != 0 }
    public var character: Character { Character(UnicodeScalar(letter)) }
}

public struct LineFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let blockSkip = LineFlags(rawValue: 1)
    public static let comment = LineFlags(rawValue: 2)
    public static let macro = LineFlags(rawValue: 4)
    public static let delimiter = LineFlags(rawValue: 8)
}

/// A whole program tokenized into flat arrays (no per-line allocation), so very large files stay cheap.
public struct TokenizedProgram: Sendable {
    public internal(set) var words: [GCodeWord] = []
    /// Index into `words` where each line starts. Has `lineCount + 1` entries (the last one is a sentinel).
    public internal(set) var lineWordStart: [Int] = []
    public internal(set) var lineFlags: [LineFlags] = []

    public init() {}

    public var lineCount: Int { lineFlags.count }

    public func wordRange(line: Int) -> Range<Int> {
        lineWordStart[line]..<lineWordStart[line + 1]
    }
}

/// Fast byte-level tokenizer for ISO G-code (Fanuc style).
///
/// Handles `(comments)`, `; comments`, `%` delimiters, `/` block skip, lowercase letters, spaces between
/// a letter and its number, CR, LF and CRLF line ends. Macro variables and expressions are recognized
/// and flagged but not evaluated yet.
public enum GCodeTokenizer {
    private static let pow10: [Double] = {
        var table: [Double] = []
        var p = 1.0
        for _ in 0...18 {
            table.append(p)
            p *= 10
        }
        return table
    }()

    public static func tokenize(_ text: String) -> TokenizedProgram {
        var copy = text
        return copy.withUTF8 { tokenize($0) }
    }

    public static func tokenize(_ data: Data) -> TokenizedProgram {
        data.withUnsafeBytes { raw in
            tokenize(raw.bindMemory(to: UInt8.self))
        }
    }

    public static func tokenize(_ buf: UnsafeBufferPointer<UInt8>) -> TokenizedProgram {
        var program = TokenizedProgram()
        let n = buf.count
        program.words.reserveCapacity(n / 5 + 16)
        program.lineWordStart.reserveCapacity(n / 20 + 16)
        program.lineFlags.reserveCapacity(n / 20 + 16)
        let powers = pow10

        var i = 0
        while i < n {
            program.lineWordStart.append(program.words.count)
            var lineFlags: LineFlags = []
            var atStart = true

            scan: while i < n {
                let c = buf[i]
                switch c {
                case 10: // \n
                    i += 1
                    break scan
                case 13: // \r or \r\n
                    i += 1
                    if i < n && buf[i] == 10 { i += 1 }
                    break scan
                case 32, 9:
                    i += 1
                case 47: // '/'
                    i += 1
                    if atStart {
                        lineFlags.insert(.blockSkip)
                        if i < n && buf[i] >= 48 && buf[i] <= 57 { i += 1 }
                    }
                case 40: // '('
                    lineFlags.insert(.comment)
                    atStart = false
                    i += 1
                    while i < n && buf[i] != 41 && buf[i] != 10 && buf[i] != 13 { i += 1 }
                    if i < n && buf[i] == 41 { i += 1 }
                case 59: // ';'
                    lineFlags.insert(.comment)
                    atStart = false
                    i += 1
                    while i < n && buf[i] != 10 && buf[i] != 13 { i += 1 }
                case 37: // '%'
                    lineFlags.insert(.delimiter)
                    atStart = false
                    i += 1
                case 35, 91, 93, 61: // '#' '[' ']' '='
                    lineFlags.insert(.macro)
                    atStart = false
                    i += 1
                default:
                    atStart = false
                    let upper = c & 0xDF
                    if upper >= 65 && upper <= 90 {
                        let start = i
                        i += 1
                        while i < n && (buf[i] == 32 || buf[i] == 9) { i += 1 }

                        var flags: UInt8 = 0
                        var negative = false
                        if i < n && (buf[i] == 43 || buf[i] == 45) {
                            negative = buf[i] == 45
                            flags |= GCodeWord.hadSign
                            i += 1
                        }

                        var mantissa: UInt64 = 0
                        var digits = 0
                        var fraction = 0
                        var seenDot = false
                        var anyDigit = false
                        while i < n {
                            let d = buf[i]
                            if d >= 48 && d <= 57 {
                                anyDigit = true
                                if digits < 18 {
                                    mantissa = mantissa &* 10 &+ UInt64(d &- 48)
                                    digits += 1
                                    if seenDot { fraction += 1 }
                                }
                                i += 1
                            } else if d == 46 && !seenDot {
                                seenDot = true
                                flags |= GCodeWord.hadDecimalPoint
                                i += 1
                            } else {
                                break
                            }
                        }

                        var value = Double(mantissa)
                        if fraction > 0 { value /= powers[fraction] }
                        if negative { value = -value }
                        if anyDigit {
                            flags |= GCodeWord.hasValue
                        } else if i < n && (buf[i] == 91 || buf[i] == 35) {
                            flags |= GCodeWord.isMacro
                        }
                        program.words.append(
                            GCodeWord(letter: upper, flags: flags, offset: Int32(truncatingIfNeeded: start), value: value)
                        )
                    } else {
                        i += 1
                    }
                }
            }
            program.lineFlags.append(lineFlags)
        }
        program.lineWordStart.append(program.words.count)
        return program
    }
}
