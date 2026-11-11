import Foundation

public struct MachineConfig: Sendable {
    /// Rapid traverse rate used for cycle time, in mm/min.
    public var rapidFeedMMPerMin = 15_000.0
    /// Chord error allowed when arcs are flattened for display or simulation, in mm.
    public var arcTolerance = 0.005
    /// Allowed difference between the start and end radius of an arc, in mm.
    public var arcRadiusTolerance = 0.01
    public var startPosition = SIMD3<Double>(repeating: 0)
    /// Diagnostics beyond this many are counted but not stored.
    public var maxDiagnostics = 500
    /// Fanuc controls usually power up in G01.
    public var initialMotionLinear = true
    /// Units used until the program says G20 or G21. Controllers set this with a parameter.
    public var defaultInches = false
    /// Safety stop for endless loops, in executed blocks.
    public var maxExecutedBlocks = 20_000_000
    /// Deepest nesting of subprogram and macro calls.
    public var maxCallDepth = 32
    /// Machine position of each work zero G54-G59 (keys 54-59), in mm. Missing entries are zero.
    public var workOffsets: [Int: SIMD3<Double>] = [:]
    /// Extra work offsets for G54.1 P1.. (Fanuc) and G154 P1.. (Haas), keyed by P.
    public var extendedWorkOffsets: [Int: SIMD3<Double>] = [:]
    /// Machine position reached by G28.
    public var referencePosition = SIMD3<Double>(repeating: 0)
    /// Machine position reached by G30.
    public var secondReferencePosition = SIMD3<Double>(repeating: 0)
    /// Cutter radius for each offset number D, in mm. G41/G42 need an entry for the D they use.
    public var cutterRadii: [Int: Double] = [:]

    public init() {}
}

/// Interprets Fanuc-style ISO G-code into a toolpath.
///
/// Supported: G00 G01 G02 G03 (IJK and R, helical, all three planes), G04, G17-G19, G20/G21, G90/G91, G90.1/G91.1,
/// G94/G95, F S T M words, M2/M30 program end, Macro B (variables, expressions, functions, IF/GOTO, WHILE/DO/END),
/// subprograms (M98/M99, Haas M97) and macro calls (G65). Recognized but not simulated yet (reported once as
/// diagnostics): cutter radius compensation, canned cycles, G28/G53/G92, rotary axes.
public final class FanucInterpreter {
    public var config: MachineConfig

    public init(config: MachineConfig = MachineConfig()) {
        self.config = config
    }

    public func run(_ program: TokenizedProgram) -> Toolpath {
        var runner = Runner(config: config, program: program)
        runner.tp.segments.reserveCapacity(program.lineCount)
        if !config.defaultInches && looksLikeInches(program) {
            runner.note(.warning, line: 0,
                        "No G20 or G21 in this program, so millimetres are assumed, but the numbers look like inches. Set the default units if that is wrong")
        }
        let count = program.lineCount
        var pc = 0
        var blocks = 0
        while pc < count && !runner.finished {
            blocks += 1
            if blocks > config.maxExecutedBlocks {
                runner.note(.error, line: pc, "Stopped after \(config.maxExecutedBlocks) blocks; the program may loop forever")
                break
            }
            let line = pc
            pc += 1
            runner.jump = nil
            let flags = program.lineFlags[line]
            if flags.contains(.macro) {
                runner.executeMacroLine(line: line, program: program)
            } else {
                let range = program.wordRange(line: line)
                if !range.isEmpty {
                    runner.execute(line: line, words: program.words[range], flags: flags)
                }
            }
            if let code = runner.vars.alarmCode {
                let text = runner.alarmMessage.map { ": " + $0 } ?? ""
                runner.note(.error, line: line, "Program alarm (#3000 = \(code))\(text)")
                runner.finished = true
            }
            if let target = runner.jump { pc = target }
        }
        runner.tp.finalPosition = runner.pos
        runner.tp.endedByProgramEnd = runner.finished
        if runner.usedComp {
            CutterCompensation.apply(&runner.tp, maxDiagnostics: config.maxDiagnostics)
        }
        return runner.tp
    }

    public func run(text: String) -> Toolpath {
        run(GCodeTokenizer.tokenize(text))
    }
}

/// Programs with no G20/G21 whose feeds and sizes are small are probably in inches.
private func looksLikeInches(_ program: TokenizedProgram) -> Bool {
    var feeds: [Double] = []
    var largest = 0.0
    for w in program.words where w.hasValueFlag {
        switch w.letter {
        case 71:
            if w.value == 20 || w.value == 21 { return false }
        case 70:
            if feeds.count < 4000 { feeds.append(w.value) }
        case 88, 89, 90:
            largest = max(largest, abs(w.value))
        default:
            break
        }
    }
    guard feeds.count >= 2 else { return false }
    feeds.sort()
    return feeds[feeds.count / 2] < 80 && largest < 60
}

private enum Motion {
    case none, rapid, linear, arcCW, arcCCW
}

private enum PendingCall {
    case sub(number: Int, count: Int, local: Bool)
    case macro(number: Int, args: [UInt8: Double])
    case ret
}

private struct CallFrame {
    var returnLine: Int
    var repeatLeft: Int
    var startLine: Int
    var savedLocals: [Int: Double]?
}

/// Which local variable each G65 argument letter fills.
private let macroArgumentVariables: [UInt8: Int] = [
    65: 1, 66: 2, 67: 3, 73: 4, 74: 5, 75: 6, 68: 7, 69: 8, 70: 9, 72: 11, 77: 13,
    81: 17, 82: 18, 83: 19, 84: 20, 85: 21, 86: 22, 87: 23, 88: 24, 89: 25, 90: 26
]

/// Name of a G code stored as tenths, for example 901 becomes "G90.1".
private func gName(_ code: Int) -> String {
    code % 10 == 0 ? "G\(code / 10)" : "G\(code / 10).\(code % 10)"
}

private struct Runner {
    let config: MachineConfig
    var tp = Toolpath()
    var pos: SIMD3<Double>
    var motion: Motion
    var plane = PlaneID.xy
    var absolute = true
    var arcCenterAbsolute = false
    var inches: Bool
    var feedPerRev = false
    /// Programmed feed converted to millimetres (mm/min, or mm/rev when feed per revolution is active).
    var feedValue = 0.0
    var spindle = 0.0
    var tool: Int32 = 0
    var pendingTool: Int32 = 0
    var reported = Set<Int>()
    var finished = false

    // flow control
    var jump: Int?
    var pendingCall: PendingCall?
    var callStack: [CallFrame] = []
    var vars = MacroVariables()
    var alarmMessage: String?

    // coordinate systems: `pos` is always the machine position of the tool tip
    var offsets: [Int: SIMD3<Double>]
    var activeOffset = 54
    var g92Shift = SIMD3<Double>(repeating: 0)

    // cutter radius compensation
    var compSide: Int8 = 0
    var compRadius = 0.0
    var compStartPending = false
    var compCancelPending = false
    var usedComp = false
    var lastD = 0
    var shift: SIMD3<Double> { (offsets[activeOffset] ?? SIMD3<Double>(repeating: 0)) + g92Shift }
    var labels: [Int: [Int]] = [:]
    var programLines: [Int: Int] = [:]
    var loopEnd: [Int: Int] = [:]
    var loopStart: [Int: Int] = [:]

    init(config: MachineConfig, program: TokenizedProgram) {
        self.config = config
        self.pos = config.startPosition
        self.motion = config.initialMotionLinear ? .linear : .none
        self.inches = config.defaultInches
        var table = config.workOffsets
        for (p, value) in config.extendedWorkOffsets { table[1000 + p] = value }
        self.offsets = table
        indexProgram(program)
    }

    mutating func indexProgram(_ program: TokenizedProgram) {
        var open: [Int: [Int]] = [:]
        for line in 0..<program.lineCount {
            let range = program.wordRange(line: line)
            if let first = program.words[range].first, first.hasValueFlag {
                if first.letter == 78 {
                    labels[Int(first.value), default: []].append(line)
                } else if first.letter == 79, programLines[Int(first.value)] == nil {
                    programLines[Int(first.value)] = line
                }
            }
            guard program.lineFlags[line].contains(.macro) else { continue }
            let bytes = Array(program.lineBytes(line))
            var i = 0
            while i < bytes.count {
                let c = bytes[i]
                if c == 40 {
                    while i < bytes.count && bytes[i] != 41 { i += 1 }
                    i += 1
                    continue
                }
                if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) {
                    var run = ""
                    while i < bytes.count && ((bytes[i] >= 65 && bytes[i] <= 90) || (bytes[i] >= 97 && bytes[i] <= 122)) {
                        run.append(Character(UnicodeScalar(bytes[i] & 0xDF)))
                        i += 1
                    }
                    var j = i
                    while j < bytes.count && bytes[j] == 32 { j += 1 }
                    var number = 0
                    var hasNumber = false
                    while j < bytes.count && bytes[j] >= 48 && bytes[j] <= 57 {
                        number = number * 10 + Int(bytes[j] - 48)
                        hasNumber = true
                        j += 1
                    }
                    if run == "DO" && hasNumber {
                        open[number, default: []].append(line)
                    } else if run == "END" && hasNumber, let start = open[number]?.popLast() {
                        loopEnd[start] = line
                        loopStart[line] = start
                    }
                    if hasNumber { i = j }
                    continue
                }
                i += 1
            }
        }
    }

    mutating func note(_ severity: Diagnostic.Severity, line: Int, _ message: String) {
        if tp.diagnostics.count >= config.maxDiagnostics {
            tp.suppressedDiagnostics += 1
            return
        }
        tp.diagnostics.append(Diagnostic(severity: severity, line: line, message: message))
    }

    /// Reports a message only the first time `key` is seen.
    mutating func noteOnce(_ key: Int, line: Int, _ severity: Diagnostic.Severity, _ message: @autoclosure () -> String) {
        if reported.contains(key) { return }
        reported.insert(key)
        note(severity, line: line, message())
    }

    // MARK: Macro lines

    mutating func executeMacroLine(line: Int, program: TokenizedProgram) {
        vars.position = pos - shift
        let parser = MacroParser(program.lineBytes(line), vars: vars)
        var words: [GCodeWord] = []
        do {
            try readMacroLine(parser, line: line, words: &words)
        } catch let error as MacroError {
            note(.error, line: line, "Macro error: \(error.message)")
            return
        } catch {
            return
        }
        if vars.alarmCode != nil && alarmMessage == nil { alarmMessage = parser.lastComment }
        if jump != nil || words.isEmpty { return }
        execute(line: line, words: words[...], flags: program.lineFlags[line].subtracting(.macro))
    }

    mutating func jumpToLabel(_ number: Int, from line: Int) throws {
        guard let lines = labels[number], !lines.isEmpty else {
            throw MacroError("Block N\(number) not found")
        }
        jump = lines.first(where: { $0 > line }) ?? lines[0]
    }

    mutating func readMacroLine(_ p: MacroParser, line: Int, words: inout [GCodeWord]) throws {
        while true {
            p.skipSpace()
            guard let c = p.peek() else { return }
            if c == 40 { p.skipComment(); continue }
            if c == 59 { return }
            if c == 37 || c == 47 { p.advance(); continue }
            if c == 35 {
                let reference = try p.parseReference()
                p.skipSpace()
                guard p.peek() == 61 else { throw MacroError("Expected = after a variable") }
                p.advance()
                let value = try p.parseOperand()
                try p.assign(reference, value)
                continue
            }
            let isLetter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            guard isLetter else { p.advance(); continue }

            let run = p.peekAlphaRun()
            switch run {
            case "IF":
                p.advance(2)
                p.skipSpace()
                guard p.peek() == 91 else { throw MacroError("IF needs [condition]") }
                p.advance()
                let condition = try p.parseExpression()
                try p.expect(93)
                p.skipSpace()
                let next = p.peekAlphaRun()
                if next == "GOTO" {
                    p.advance(4)
                    let target = Int((try p.parseOperand() ?? 0).rounded())
                    if condition != 0 {
                        try jumpToLabel(target, from: line)
                        return
                    }
                } else if next == "THEN" {
                    p.advance(4)
                    if condition == 0 { return }
                } else {
                    throw MacroError("IF needs GOTO or THEN")
                }
            case "WHILE":
                p.advance(5)
                p.skipSpace()
                guard p.peek() == 91 else { throw MacroError("WHILE needs [condition]") }
                p.advance()
                let condition = try p.parseExpression()
                try p.expect(93)
                p.skipSpace()
                guard p.peekAlphaRun() == "DO" else { throw MacroError("WHILE needs DO") }
                p.advance(2)
                _ = try p.parseOperand()
                if condition == 0 {
                    guard let end = loopEnd[line] else { throw MacroError("WHILE has no matching END") }
                    jump = end + 1
                    return
                }
            case "DO":
                p.advance(2)
                _ = try p.parseOperand()
            case "END":
                p.advance(3)
                _ = try p.parseOperand()
                guard let start = loopStart[line] else { throw MacroError("END has no matching WHILE") }
                jump = start
                return
            case "GOTO":
                p.advance(4)
                let target = Int((try p.parseOperand() ?? 0).rounded())
                try jumpToLabel(target, from: line)
                return
            default:
                if run.count > 1 {
                    noteOnce(10010, line: line, .info, "Macro statement \(run) is not supported yet and is ignored")
                    return
                }
                let letter = UInt8(ascii: UnicodeScalar(run)!)
                p.advance()
                p.skipSpace()
                if let next = p.peek(),
                   (next >= 48 && next <= 57) || next == 46 || next == 43 || next == 45 || next == 35 || next == 91 {
                    if let value = try p.parseOperand() {
                        let flags = GCodeWord.hasValue | (p.lastHadDecimal ? GCodeWord.hadDecimalPoint : 0)
                        words.append(GCodeWord(letter: letter, flags: flags, offset: 0, value: value))
                    }
                } else {
                    words.append(GCodeWord(letter: letter, flags: 0, offset: 0, value: 0))
                }
            }
        }
    }

    // MARK: Calls

    mutating func performCall(_ call: PendingCall, line: Int) {
        switch call {
        case .ret:
            guard var frame = callStack.popLast() else {
                noteOnce(10011, line: line, .info, "M99 in the main program ends the program")
                finished = true
                return
            }
            if frame.repeatLeft > 0 {
                frame.repeatLeft -= 1
                callStack.append(frame)
                jump = frame.startLine
            } else {
                if let saved = frame.savedLocals { vars.local = saved }
                jump = frame.returnLine
            }
        case .sub(let number, let count, let local):
            guard callStack.count < config.maxCallDepth else {
                note(.error, line: line, "Subprograms are nested deeper than \(config.maxCallDepth) levels")
                finished = true
                return
            }
            let target = local ? labels[number]?.first : programLines[number]
            guard let start = target else {
                note(.error, line: line, local ? "Block N\(number) for M97 not found" : "Subprogram O\(number) not found")
                return
            }
            callStack.append(CallFrame(returnLine: line + 1, repeatLeft: max(count, 1) - 1, startLine: start, savedLocals: nil))
            jump = start
        case .macro(let number, let args):
            guard callStack.count < config.maxCallDepth else {
                note(.error, line: line, "Macro calls are nested deeper than \(config.maxCallDepth) levels")
                finished = true
                return
            }
            guard let start = programLines[number] else {
                note(.error, line: line, "Macro program O\(number) not found")
                return
            }
            var locals: [Int: Double] = [:]
            for (letter, value) in args {
                if let id = macroArgumentVariables[letter] { locals[id] = value }
            }
            callStack.append(CallFrame(returnLine: line + 1, repeatLeft: 0, startLine: start, savedLocals: vars.local))
            vars.local = locals
            jump = start
        }
    }

    // MARK: Blocks

    mutating func execute(line: Int, words: ArraySlice<GCodeWord>, flags: LineFlags) {
        var newMotion = motion
        var nonModal = 0
        var isMacroCall = false
        var selectExtended = false
        var pendingSide: Int8 = 0
        var cancelComp = false
        var dWord: Int?

        // Pass 1: modal G codes first, so G20/G21/G90/G91/G17.. apply to the whole block.
        for w in words where w.letter == 71 && w.hasValueFlag {
            let code = Int((w.value * 10).rounded())
            switch code {
            case 0: newMotion = .rapid
            case 10: newMotion = .linear
            case 20: newMotion = .arcCW
            case 30: newMotion = .arcCCW
            case 40: nonModal = 40
            case 170: plane = .xy
            case 180: plane = .zx
            case 190: plane = .yz
            case 200: inches = true
            case 210: inches = false
            case 900: absolute = true
            case 910: absolute = false
            case 901: arcCenterAbsolute = true
            case 911: arcCenterAbsolute = false
            case 940: feedPerRev = false
            case 950: feedPerRev = true
            case 490: break
            case 400:
                cancelComp = true
            case 540, 550, 560, 570, 580, 590:
                activeOffset = code / 10
            case 541, 1540:
                selectExtended = true
            case 410:
                pendingSide = 1
            case 420:
                pendingSide = -1
            case 430, 440:
                noteOnce(code, line: line, .info,
                         "Tool length compensation (G43/G44) is read but does not change the tool tip path shown")
            case 100, 280, 300, 530, 920, 921:
                nonModal = code
            case 650:
                nonModal = 650
                isMacroCall = true
            case 800:
                newMotion = .none
            case 810...890:
                noteOnce(10004, line: line, .warning,
                         "Canned cycles (G81-G89) are not simulated yet; their moves are skipped")
                newMotion = .none
            default:
                noteOnce(code, line: line, .info, "\(gName(code)) is not supported yet and is ignored")
            }
        }

        // Pass 2: everything else.
        let scale = inches ? 25.4 : 1.0
        var axisValue = SIMD3<Double>(repeating: 0)
        var axisMask: UInt8 = 0
        var offset = SIMD3<Double>(repeating: 0)
        var offsetMask: UInt8 = 0
        var radius = 0.0
        var hasRadius = false
        var rawX: Double?
        var rawP: Double?
        var rawL: Double?
        var pHadDecimal = false
        var programEnd = false
        var callSub = false
        var callLocal = false
        var returnFromSub = false
        var macroArgs: [UInt8: Double] = [:]

        for w in words {
            if isMacroCall && w.letter != 71 && w.hasValueFlag { macroArgs[w.letter] = w.value }
            switch w.letter {
            case 88 where w.hasValueFlag: // X
                axisValue.x = w.value * scale; axisMask |= 1; rawX = w.value
            case 89 where w.hasValueFlag: // Y
                axisValue.y = w.value * scale; axisMask |= 2
            case 90 where w.hasValueFlag: // Z
                axisValue.z = w.value * scale; axisMask |= 4
            case 73 where w.hasValueFlag: // I
                offset.x = w.value * scale; offsetMask |= 1
            case 74 where w.hasValueFlag: // J
                offset.y = w.value * scale; offsetMask |= 2
            case 75 where w.hasValueFlag: // K
                offset.z = w.value * scale; offsetMask |= 4
            case 82 where w.hasValueFlag: // R
                radius = w.value * scale; hasRadius = true
            case 70 where w.hasValueFlag: // F
                feedValue = w.value * scale
            case 83 where w.hasValueFlag: // S
                spindle = w.value
            case 84 where w.hasValueFlag: // T
                pendingTool = Int32(truncatingIfNeeded: Int(w.value.rounded()))
            case 80 where w.hasValueFlag: // P
                rawP = w.value; pHadDecimal = w.hadDecimal
            case 76 where w.hasValueFlag: // L
                rawL = w.value
            case 68 where w.hasValueFlag: // D
                dWord = Int(w.value.rounded())
            case 65, 66, 67: // A B C
                if !isMacroCall {
                    noteOnce(10005, line: line, .info, "Rotary axes (A, B, C) are ignored in Phase 1")
                }
            case 77 where w.hasValueFlag: // M
                switch Int(w.value.rounded()) {
                case 6: tool = pendingTool
                case 2, 30: programEnd = true
                case 97: callLocal = true
                case 98: callSub = true
                case 99: returnFromSub = true
                default: break
                }
            default: break
            }
        }

        if selectExtended, let p = rawP {
            activeOffset = 1000 + Int(p.rounded())
        }
        let none = SIMD3<Double>(repeating: 0)

        if pendingSide != 0 {
            let d = dWord ?? lastD
            lastD = d
            if let radius = config.cutterRadii[d], radius > 0 {
                if compSide == 0 { compStartPending = true }
                compSide = pendingSide
                compRadius = radius
            } else {
                noteOnce(20000 + d, line: line, .warning,
                         "No cutter radius for D\(d) in the tool table, so cutter radius compensation is skipped")
            }
        }
        if cancelComp && compSide != 0 { compCancelPending = true }

        switch nonModal {
        case 40: // dwell
            if let x = rawX {
                tp.dwellSeconds += x
            } else if let p = rawP {
                tp.dwellSeconds += pHadDecimal ? p : p / 1000
            }

        case 100: // G10 L2 Pn: set a work offset (machine position of the work zero)
            let l = Int((rawL ?? 0).rounded())
            if l == 2 || l == 20, let p = rawP {
                let index = Int(p.rounded()) >= 1 && Int(p.rounded()) <= 6 ? 53 + Int(p.rounded()) : activeOffset
                var value = offsets[index] ?? none
                for k in 0..<3 where axisMask & (1 << UInt8(k)) != 0 {
                    value[k] = l == 2 ? axisValue[k] : value[k] + axisValue[k]
                }
                offsets[index] = value
            } else {
                noteOnce(10020, line: line, .info, "Only G10 L2 and L20 (work offsets) are supported; other G10 forms are ignored")
            }

        case 920: // G92: the current position gets new coordinates
            for k in 0..<3 where axisMask & (1 << UInt8(k)) != 0 {
                g92Shift[k] = pos[k] - (offsets[activeOffset] ?? none)[k] - axisValue[k]
            }

        case 921: // G92.1 cancels the shift
            g92Shift = none

        case 280, 300: // return to a reference position through an intermediate point
            let reference = nonModal == 280 ? config.referencePosition : config.secondReferencePosition
            let mask: UInt8 = axisMask == 0 ? 7 : axisMask
            var middle = pos
            for k in 0..<3 where axisMask & (1 << UInt8(k)) != 0 {
                middle[k] = absolute ? axisValue[k] + shift[k] : pos[k] + axisValue[k]
            }
            var home = middle
            for k in 0..<3 where mask & (1 << UInt8(k)) != 0 { home[k] = reference[k] }
            let saved = motion
            motion = .rapid
            if middle != pos {
                move(line: line, target: middle, offset: none, offsetMask: 0, radius: 0, hasRadius: false)
            }
            if home != pos {
                move(line: line, target: home, offset: none, offsetMask: 0, radius: 0, hasRadius: false)
            }
            motion = saved

        case 530: // G53: one block in machine coordinates
            let moving = (newMotion == .rapid || newMotion == .linear) ? newMotion
                : ((motion == .rapid || motion == .linear) ? motion : .rapid)
            if axisMask != 0 {
                var target = pos
                for k in 0..<3 where axisMask & (1 << UInt8(k)) != 0 { target[k] = axisValue[k] }
                let saved = motion
                motion = moving
                move(line: line, target: target, offset: none, offsetMask: 0, radius: 0, hasRadius: false)
                motion = saved
            }

        case 0:
            motion = newMotion
            let isArc = motion == .arcCW || motion == .arcCCW
            let hasWork = axisMask != 0 || (isArc && (offsetMask != 0 || hasRadius))
            if hasWork {
                if motion == .none {
                    noteOnce(10001, line: line, .warning,
                             "Axis words without an active motion mode (G00-G03) are ignored")
                } else {
                    let currentShift = shift
                    var target = pos
                    for k in 0..<3 where axisMask & (1 << UInt8(k)) != 0 {
                        target[k] = absolute ? axisValue[k] + currentShift[k] : pos[k] + axisValue[k]
                    }
                    move(line: line, target: target, offset: offset, offsetMask: offsetMask,
                         radius: radius, hasRadius: hasRadius)
                }
            }

        default:
            break
        }

        if isMacroCall, let p = macroArgs[80] {
            pendingCall = .macro(number: Int(p.rounded()), args: macroArgs)
        } else if callSub, let p = rawP {
            var number = Int(p.rounded())
            var count = rawL.map { Int($0.rounded()) } ?? 1
            if number > 9999 {
                count = number / 10000
                number %= 10000
            }
            pendingCall = .sub(number: number, count: count, local: false)
        } else if callLocal, let p = rawP {
            pendingCall = .sub(number: Int(p.rounded()), count: rawL.map { Int($0.rounded()) } ?? 1, local: true)
        } else if returnFromSub {
            pendingCall = .ret
        }
        if let call = pendingCall {
            pendingCall = nil
            performCall(call, line: line)
        }

        if programEnd { finished = true }
    }

    mutating func effectiveFeed(line: Int) -> Double {
        if feedPerRev {
            if spindle <= 0 {
                noteOnce(10007, line: line, .warning, "Feed per revolution (G95) used without a spindle speed")
                return 0
            }
            return feedValue * spindle
        }
        return feedValue
    }

    mutating func move(line: Int, target: SIMD3<Double>, offset: SIMD3<Double>, offsetMask: UInt8,
                       radius: Double, hasRadius: Bool) {
        let segment: Segment
        switch motion {
        case .rapid:
            segment = Segment(kind: .rapid, plane: plane, start: pos, end: target,
                              center: SIMD3<Double>(repeating: 0), feed: 0, tool: tool, line: Int32(line))
        case .linear:
            let feed = effectiveFeed(line: line)
            if feed <= 0 {
                noteOnce(10002, line: line, .warning, "Feed move (G01) without a feed rate")
            }
            segment = Segment(kind: .linear, plane: plane, start: pos, end: target,
                              center: SIMD3<Double>(repeating: 0), feed: feed, tool: tool, line: Int32(line))
        case .arcCW, .arcCCW:
            let feed = effectiveFeed(line: line)
            if feed <= 0 {
                noteOnce(10002, line: line, .warning, "Feed move (G02/G03) without a feed rate")
            }
            guard let center = arcCenter(line: line, target: target, offset: offset, offsetMask: offsetMask,
                                         radius: radius, hasRadius: hasRadius, ccw: motion == .arcCCW) else {
                return
            }
            segment = Segment(kind: motion == .arcCCW ? .arcCCW : .arcCW, plane: plane, start: pos, end: target,
                              center: center, feed: feed, tool: tool, line: Int32(line))
        case .none:
            return
        }

        var tagged = segment
        if compSide != 0 && compRadius > 0 {
            let ax = segment.plane.axes
            let du = segment.end[ax.a0] - segment.start[ax.a0]
            let dv = segment.end[ax.a1] - segment.start[ax.a1]
            let planar = segment.kind.isArc || du * du + dv * dv > 1e-18
            tagged.compSide = compSide
            tagged.compRadius = compRadius
            if planar && compStartPending {
                tagged.compPhase = 1
                compStartPending = false
            } else if planar && compCancelPending {
                tagged.compPhase = 3
                compCancelPending = false
                compSide = 0
            } else {
                tagged.compPhase = 2
            }
            usedComp = true
        }
        tp.segments.append(tagged)
        let length = segment.length
        if segment.kind == .rapid { tp.rapidLength += length } else { tp.cuttingLength += length }

        if segment.kind.isArc {
            segment.forEachLine(tolerance: max(config.arcTolerance, 0.05)) { _, to in
                tp.extend(bounds: to)
            }
        }
        tp.extend(bounds: segment.start)
        tp.extend(bounds: segment.end)
        pos = target
    }

    /// Finds the arc centre from I/J/K offsets or from R. Returns nil (after reporting) when the arc is invalid.
    mutating func arcCenter(line: Int, target: SIMD3<Double>, offset: SIMD3<Double>, offsetMask: UInt8,
                            radius: Double, hasRadius: Bool, ccw: Bool) -> SIMD3<Double>? {
        let ax = plane.axes
        var center = pos
        if hasRadius {
            let du = target[ax.a0] - pos[ax.a0]
            let dv = target[ax.a1] - pos[ax.a1]
            let d = (du * du + dv * dv).squareRoot()
            if d < 1e-9 {
                note(.error, line: line, "Arc with R needs different start and end points")
                return nil
            }
            let half = d / 2
            let h2 = radius * radius - half * half
            if h2 < -1e-6 * max(1, radius * radius) {
                note(.error, line: line, "Arc radius R is smaller than half the distance between start and end")
                return nil
            }
            let h = h2 > 0 ? h2.squareRoot() : 0
            let nu = -dv / d
            let nv = du / d
            let sign = (ccw ? 1.0 : -1.0) * (radius >= 0 ? 1.0 : -1.0)
            center[ax.a0] = pos[ax.a0] + du / 2 + sign * nu * h
            center[ax.a1] = pos[ax.a1] + dv / 2 + sign * nv * h
        } else {
            if offsetMask == 0 {
                note(.error, line: line, "Arc without I/J/K or R")
                return nil
            }
            for k in [ax.a0, ax.a1] {
                let value = offsetMask & (1 << UInt8(k)) != 0 ? offset[k] : 0
                center[k] = arcCenterAbsolute ? value + shift[k] : pos[k] + value
            }
        }
        center[ax.h] = pos[ax.h]

        let r0 = hypotenuse(pos, center, ax.a0, ax.a1)
        let r1 = hypotenuse(target, center, ax.a0, ax.a1)
        if r0 < 1e-9 {
            note(.error, line: line, "Arc with zero radius")
            return nil
        }
        if !hasRadius && abs(r0 - r1) > config.arcRadiusTolerance {
            note(.warning, line: line,
                 "Arc start and end radius differ by \(String(format: "%.4f", abs(r0 - r1))) mm; the controller would raise an alarm")
        }
        return center
    }

    func hypotenuse(_ p: SIMD3<Double>, _ c: SIMD3<Double>, _ a0: Int, _ a1: Int) -> Double {
        let u = p[a0] - c[a0]
        let v = p[a1] - c[a1]
        return (u * u + v * v).squareRoot()
    }
}
