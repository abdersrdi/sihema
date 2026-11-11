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

    public init() {}
}

/// Interprets Fanuc-style ISO G-code into a toolpath.
///
/// Phase 0 scope: G00 G01 G02 G03 (IJK and R, helical, all three planes), G04, G17-G19, G20/G21, G90/G91,
/// G90.1/G91.1, G94/G95, F S T M words, M2/M30 program end. Recognized but not simulated yet (reported
/// once as diagnostics): cutter radius compensation, canned cycles, G28/G53/G92, subprograms, macros.
public final class FanucInterpreter {
    public var config: MachineConfig

    public init(config: MachineConfig = MachineConfig()) {
        self.config = config
    }

    public func run(_ program: TokenizedProgram) -> Toolpath {
        var runner = Runner(config: config)
        runner.tp.segments.reserveCapacity(program.lineCount)
        let count = program.lineCount
        var line = 0
        while line < count && !runner.finished {
            let range = program.wordRange(line: line)
            if !range.isEmpty {
                runner.execute(line: line, words: program.words[range], flags: program.lineFlags[line])
            } else if program.lineFlags[line].contains(.macro) {
                runner.noteOnce(10003, line: line, .info,
                                "Macro variables and expressions are not evaluated yet; blocks that use them may be incomplete")
            }
            line += 1
        }
        runner.tp.finalPosition = runner.pos
        runner.tp.endedByProgramEnd = runner.finished
        return runner.tp
    }

    public func run(text: String) -> Toolpath {
        run(GCodeTokenizer.tokenize(text))
    }
}

private enum Motion {
    case none, rapid, linear, arcCW, arcCCW
}

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
    var inches = false
    var feedPerRev = false
    /// Programmed feed converted to millimetres (mm/min, or mm/rev when feed per revolution is active).
    var feedValue = 0.0
    var spindle = 0.0
    var tool: Int32 = 0
    var pendingTool: Int32 = 0
    var reported = Set<Int>()
    var finished = false

    init(config: MachineConfig) {
        self.config = config
        self.pos = config.startPosition
        self.motion = config.initialMotionLinear ? .linear : .none
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

    mutating func execute(line: Int, words: ArraySlice<GCodeWord>, flags: LineFlags) {
        if flags.contains(.macro) {
            noteOnce(10003, line: line, .info,
                     "Macro variables and expressions are not evaluated yet; blocks that use them may be incomplete")
        }

        var newMotion = motion
        var nonModal = 0

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
            case 400, 490, 540, 550, 560, 570, 580, 590: break
            case 410, 420:
                noteOnce(code, line: line, .warning,
                         "Cutter radius compensation (G41/G42) is not applied yet; the path shown is the programmed path")
            case 430, 440:
                noteOnce(code, line: line, .info, "Tool length compensation (G43/G44) is not applied yet")
            case 800:
                newMotion = .none
            case 810...890:
                noteOnce(10004, line: line, .warning,
                         "Canned cycles (G81-G89) are not simulated yet; their moves are skipped")
                newMotion = .none
            case 280, 530, 920:
                nonModal = code
                noteOnce(code, line: line, .info, "\(gName(code)) is not simulated yet and is skipped")
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
        var pHadDecimal = false
        var programEnd = false

        for w in words {
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
            case 65, 66, 67: // A B C
                noteOnce(10005, line: line, .info, "Rotary axes (A, B, C) are ignored in Phase 0")
            case 77 where w.hasValueFlag: // M
                switch Int(w.value.rounded()) {
                case 6: tool = pendingTool
                case 2, 30: programEnd = true
                case 98, 99:
                    noteOnce(10006, line: line, .warning, "Subprograms (M98/M99) are not executed yet")
                default: break
                }
            default: break
            }
        }

        if nonModal == 40 {
            if let x = rawX {
                tp.dwellSeconds += x
            } else if let p = rawP {
                tp.dwellSeconds += pHadDecimal ? p : p / 1000
            }
        } else if nonModal == 0 {
            motion = newMotion
            let isArc = motion == .arcCW || motion == .arcCCW
            let hasWork = axisMask != 0 || (isArc && (offsetMask != 0 || hasRadius))
            if hasWork {
                if motion == .none {
                    noteOnce(10001, line: line, .warning,
                             "Axis words without an active motion mode (G00-G03) are ignored")
                } else {
                    var target = pos
                    for k in 0..<3 where axisMask & (1 << UInt8(k)) != 0 {
                        target[k] = absolute ? axisValue[k] : pos[k] + axisValue[k]
                    }
                    move(line: line, target: target, offset: offset, offsetMask: offsetMask,
                         radius: radius, hasRadius: hasRadius)
                }
            }
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

        tp.segments.append(segment)
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
                center[k] = arcCenterAbsolute ? value : pos[k] + value
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
