import Foundation

public enum SyntaxKind: UInt8, Sendable {
    case comment
    case generalCode   // G
    case miscCode      // M
    case sequence      // N and O
    case axis          // X Y Z A B C U V W
    case feed          // F
    case speed         // S
    case tool          // T D H
    case address       // I J K R P Q L and any other letter
    case macro         // # variables, [ ] = and keywords such as GOTO, WHILE
    case delimiter     // % and block skip
}

/// A coloured stretch of a line, in byte offsets from the start of the text that was scanned.
public struct SyntaxSpan: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var kind: SyntaxKind

    public init(start: Int, end: Int, kind: SyntaxKind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

/// Finds what to colour in G-code text. It works on bytes, so the editor can colour only the lines on screen.
public enum SyntaxHighlighter {
    public static func spans(in bytes: [UInt8]) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        let n = bytes.count
        var i = 0
        var atLineStart = true

        func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

        while i < n {
            let c = bytes[i]
            if c == 10 || c == 13 {
                atLineStart = true
                i += 1
                continue
            }
            if c == 32 || c == 9 {
                i += 1
                continue
            }
            let wasAtLineStart = atLineStart
            atLineStart = false

            switch c {
            case 40: // '(' comment to ')' or the end of the line
                let start = i
                i += 1
                while i < n && bytes[i] != 41 && bytes[i] != 10 && bytes[i] != 13 { i += 1 }
                if i < n && bytes[i] == 41 { i += 1 }
                spans.append(SyntaxSpan(start: start, end: i, kind: .comment))
            case 59: // ';' comment to the end of the line
                let start = i
                while i < n && bytes[i] != 10 && bytes[i] != 13 { i += 1 }
                spans.append(SyntaxSpan(start: start, end: i, kind: .comment))
            case 37: // '%'
                spans.append(SyntaxSpan(start: i, end: i + 1, kind: .delimiter))
                i += 1
            case 47: // '/' block skip at the start of a line
                if wasAtLineStart {
                    var end = i + 1
                    if end < n && isDigit(bytes[end]) { end += 1 }
                    spans.append(SyntaxSpan(start: i, end: end, kind: .delimiter))
                    i = end
                    atLineStart = true
                } else {
                    i += 1
                }
            case 35: // '#' variable: #100, #<name>
                let start = i
                i += 1
                if i < n && bytes[i] == 60 {
                    while i < n && bytes[i] != 62 && bytes[i] != 10 && bytes[i] != 13 { i += 1 }
                    if i < n && bytes[i] == 62 { i += 1 }
                } else {
                    while i < n && (isDigit(bytes[i]) || bytes[i] == 35) { i += 1 }
                }
                spans.append(SyntaxSpan(start: start, end: i, kind: .macro))
            case 91, 93, 61: // '[' ']' '='
                spans.append(SyntaxSpan(start: i, end: i + 1, kind: .macro))
                i += 1
            default:
                guard isLetter(c) else {
                    i += 1
                    continue
                }
                let start = i
                if i + 1 < n && isLetter(bytes[i + 1]) {
                    // two letters in a row: a keyword such as GOTO, WHILE, DO, END, SIN
                    while i < n && isLetter(bytes[i]) { i += 1 }
                    spans.append(SyntaxSpan(start: start, end: i, kind: .macro))
                    continue
                }
                i += 1
                if i < n && (bytes[i] == 43 || bytes[i] == 45) { i += 1 }
                while i < n && (isDigit(bytes[i]) || bytes[i] == 46) { i += 1 }
                let kind: SyntaxKind
                switch c & 0xDF {
                case 71: kind = .generalCode
                case 77: kind = .miscCode
                case 78, 79: kind = .sequence
                case 88, 89, 90, 65, 66, 67, 85, 86, 87: kind = .axis
                case 70: kind = .feed
                case 83: kind = .speed
                case 84, 68, 72: kind = .tool
                default: kind = .address
                }
                spans.append(SyntaxSpan(start: start, end: i, kind: kind))
            }
        }
        return spans
    }
}
