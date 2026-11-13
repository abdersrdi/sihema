import Foundation

struct MacroError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum VariableReference {
    case number(Int)
    case named(String)
}

/// Macro B variables. `#1`-`#99` are local to the current macro call, everything from `#100` up is common.
/// Reading a variable that was never set gives "vacant" (nil): 0 inside an expression, and an address word
/// that uses it is left out of the block.
final class MacroVariables {
    var common: [Int: Double] = [:]
    var local: [Int: Double] = [:]
    var named: [String: Double] = [:]
    /// Current program position, for `#5001`-`#5003`.
    var position = SIMD3<Double>(repeating: 0)
    /// Set when the program writes `#3000` (a user alarm).
    var alarmCode: Int?

    func read(_ reference: VariableReference) -> Double? {
        switch reference {
        case .number(let id): return read(id)
        case .named(let name): return named[name]
        }
    }

    func read(_ id: Int) -> Double? {
        switch id {
        case 0: return nil
        case 5001, 5021: return position.x
        case 5002, 5022: return position.y
        case 5003, 5023: return position.z
        case 1...99: return local[id]
        default: return common[id]
        }
    }

    func write(_ reference: VariableReference, _ value: Double?) throws {
        switch reference {
        case .number(let id): try write(id, value)
        case .named(let name): named[name] = value
        }
    }

    func write(_ id: Int, _ value: Double?) throws {
        switch id {
        case 0:
            throw MacroError("#0 cannot be changed")
        case 5001...5003, 5021...5023:
            throw MacroError("#\(id) is read-only")
        case 3000:
            if let value, value != 0 { alarmCode = Int(value.rounded()) }
        case 1...99:
            local[id] = value
        default:
            common[id] = value
        }
    }
}

/// Reads one line of macro text: variable assignments, expressions in brackets, functions and addresses.
final class MacroParser {
    private let bytes: [UInt8]
    private(set) var index = 0
    private let vars: MacroVariables
    /// True when the last literal had a decimal point.
    private(set) var lastHadDecimal = false
    private(set) var lastComment = ""

    init(_ line: ArraySlice<UInt8>, vars: MacroVariables) {
        self.bytes = Array(line)
        self.vars = vars
    }

    // MARK: Low level

    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    func advance(_ count: Int = 1) { index = min(bytes.count, index + count) }

    func skipSpace() {
        while index < bytes.count && (bytes[index] == 32 || bytes[index] == 9) { index += 1 }
    }

    private func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    /// The run of letters at the cursor in capitals, without consuming it.
    func peekAlphaRun() -> String {
        var j = index
        var run = ""
        while j < bytes.count && isLetter(bytes[j]) {
            run.append(Character(UnicodeScalar(bytes[j] & 0xDF)))
            j += 1
        }
        return run
    }

    func skipComment() {
        // at '('
        advance()
        var text: [UInt8] = []
        while index < bytes.count && bytes[index] != 41 {
            text.append(bytes[index])
            index += 1
        }
        if index < bytes.count { advance() }
        lastComment = String(decoding: text, as: UTF8.self)
    }

    func expect(_ c: UInt8) throws {
        skipSpace()
        guard peek() == c else {
            throw MacroError("Expected \(Character(UnicodeScalar(c)))")
        }
        advance()
    }

    // MARK: Variables

    func parseReference() throws -> VariableReference {
        // at '#'
        advance()
        guard let c = peek() else { throw MacroError("Incomplete variable") }
        if c == 60 { // '<'
            advance()
            var name = ""
            while let d = peek(), d != 62 {
                name.append(Character(UnicodeScalar(d)))
                advance()
            }
            guard peek() == 62 else { throw MacroError("Unclosed variable name") }
            advance()
            return .named(name.lowercased())
        }
        if c == 91 { // '['
            advance()
            let value = try parseExpression()
            try expect(93)
            return .number(Int(value.rounded()))
        }
        if c == 35 { // '#'
            let inner = try parseReference()
            return .number(Int((vars.read(inner) ?? 0).rounded()))
        }
        var number = 0
        var any = false
        while let d = peek(), isDigit(d) {
            number = number * 10 + Int(d - 48)
            any = true
            advance()
        }
        guard any else { throw MacroError("Missing variable number") }
        return .number(number)
    }

    func assign(_ reference: VariableReference, _ value: Double?) throws {
        try vars.write(reference, value)
    }

    /// The right-hand side of `#n = ...`. Fanuc wants brackets around an expression, but Haas and many other
    /// controls accept `#1=#1+1` and `#2=#3*2` as they are, so a value followed by an operator is read as one.
    /// A bare value stays as it is, so a vacant variable is still vacant.
    func parseAssignedValue() throws -> Double? {
        let start = index
        let value = try parseOperand()
        skipSpace()
        var continues = false
        if let c = peek() {
            if c == 43 || c == 45 || c == 42 || c == 47 {
                continues = true
            } else {
                let op = peekAlphaRun()
                continues = ["AND", "OR", "XOR", "MOD"].contains(op)
            }
        }
        guard continues else { return value }
        index = start
        return try parseExpressionToEnd()
    }

    /// An unbracketed expression: arithmetic and logic, no comparisons (those need brackets).
    private func parseExpressionToEnd() throws -> Double {
        try parseExpression()
    }

    // MARK: Values

    /// Number, variable, bracketed expression, function or signed value. Nil means a vacant variable.
    func parseOperand() throws -> Double? {
        skipSpace()
        lastHadDecimal = false
        guard let c = peek() else { throw MacroError("Missing value") }
        switch c {
        case 35: // '#'
            return vars.read(try parseReference())
        case 91: // '['
            advance()
            let value = try parseExpression()
            try expect(93)
            return value
        case 43: // '+'
            advance()
            return try parseOperand() ?? 0
        case 45: // '-'
            advance()
            return -(try parseOperand() ?? 0)
        default:
            if isDigit(c) || c == 46 { return parseLiteral() }
            if isLetter(c) { return try parseFunction() }
            throw MacroError("Unexpected character '\(Character(UnicodeScalar(c)))'")
        }
    }

    private func parseLiteral() -> Double {
        var text = ""
        var seenDot = false
        while let d = peek() {
            if isDigit(d) {
                text.append(Character(UnicodeScalar(d)))
            } else if d == 46 && !seenDot {
                seenDot = true
                text.append(".")
            } else {
                break
            }
            advance()
        }
        lastHadDecimal = seenDot
        if text.hasPrefix(".") { text = "0" + text }
        if text.hasSuffix(".") { text += "0" }
        return Double(text) ?? 0
    }

    private func parseFunction() throws -> Double {
        let name = peekAlphaRun()
        advance(name.count)
        skipSpace()
        guard peek() == 91 else { throw MacroError("Unknown name \(name)") }
        advance()
        let first = try parseExpression()
        try expect(93)
        let degrees = Double.pi / 180
        switch name {
        case "SIN": return sin(first * degrees)
        case "COS": return cos(first * degrees)
        case "TAN": return tan(first * degrees)
        case "ASIN": return asin(first) / degrees
        case "ACOS": return acos(first) / degrees
        case "ATAN":
            skipSpace()
            var second = 1.0
            if peek() == 47 { // '/'
                advance()
                skipSpace()
                guard peek() == 91 else { throw MacroError("ATAN needs [y]/[x]") }
                advance()
                second = try parseExpression()
                try expect(93)
            }
            var angle = atan2(first, second) / degrees
            if angle < 0 { angle += 360 }
            return angle
        case "SQRT":
            guard first >= 0 else { throw MacroError("SQRT of a negative number") }
            return first.squareRoot()
        case "ABS": return abs(first)
        case "FIX": return first.rounded(.down)
        case "FUP": return first.rounded(.up)
        case "ROUND": return first.rounded(.toNearestOrAwayFromZero)
        case "LN":
            guard first > 0 else { throw MacroError("LN needs a positive number") }
            return log(first)
        case "EXP": return exp(first)
        case "BIN": return first
        case "BCD": return first
        default: throw MacroError("Unknown function \(name)")
        }
    }

    // MARK: Expressions (inside brackets)

    /// Comparison level: EQ NE GT LT GE LE.
    func parseExpression() throws -> Double {
        var left = try parseAdditive()
        while true {
            skipSpace()
            let op = peekAlphaRun()
            guard ["EQ", "NE", "GT", "LT", "GE", "LE"].contains(op) else { break }
            advance(op.count)
            let right = try parseAdditive()
            let equal = abs(left - right) < 1e-9
            switch op {
            case "EQ": left = equal ? 1 : 0
            case "NE": left = equal ? 0 : 1
            case "GT": left = (left > right && !equal) ? 1 : 0
            case "LT": left = (left < right && !equal) ? 1 : 0
            case "GE": left = (left > right || equal) ? 1 : 0
            default: left = (left < right || equal) ? 1 : 0
            }
        }
        return left
    }

    private func parseAdditive() throws -> Double {
        var left = try parseMultiplicative()
        while true {
            skipSpace()
            if peek() == 43 {
                advance()
                left += try parseMultiplicative()
            } else if peek() == 45 {
                advance()
                left -= try parseMultiplicative()
            } else {
                let op = peekAlphaRun()
                if op == "OR" {
                    advance(2)
                    let right = try parseMultiplicative()
                    left = Double(Int(left) | Int(right))
                } else if op == "XOR" {
                    advance(3)
                    let right = try parseMultiplicative()
                    left = Double(Int(left) ^ Int(right))
                } else {
                    break
                }
            }
        }
        return left
    }

    private func parseMultiplicative() throws -> Double {
        var left = try parseOperand() ?? 0
        while true {
            skipSpace()
            if peek() == 42 {
                advance()
                left *= try parseOperand() ?? 0
            } else if peek() == 47 {
                advance()
                let right = try parseOperand() ?? 0
                guard right != 0 else { throw MacroError("Division by zero") }
                left /= right
            } else {
                let op = peekAlphaRun()
                if op == "AND" {
                    advance(3)
                    let right = try parseOperand() ?? 0
                    left = Double(Int(left) & Int(right))
                } else if op == "MOD" {
                    advance(3)
                    let right = try parseOperand() ?? 0
                    guard right != 0 else { throw MacroError("MOD by zero") }
                    left = left.truncatingRemainder(dividingBy: right)
                } else {
                    break
                }
            }
        }
        return left
    }
}
