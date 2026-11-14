import Foundation

@inline(__always)
func norm(_ v: SIMD3<Double>) -> Double {
    (v * v).sum().squareRoot()
}

/// Working plane. Axis indices: 0 = X, 1 = Y, 2 = Z.
public enum PlaneID: UInt8, Sendable {
    case xy = 0   // G17
    case zx = 1   // G18
    case yz = 2   // G19

    /// First and second axis of the plane, and the axis perpendicular to it (helical axis).
    public var axes: (a0: Int, a1: Int, h: Int) {
        switch self {
        case .xy: return (0, 1, 2)
        case .zx: return (2, 0, 1)
        case .yz: return (1, 2, 0)
        }
    }
}

public enum SegmentKind: UInt8, Sendable {
    case rapid, linear, arcCW, arcCCW

    public var isArc: Bool { self == .arcCW || self == .arcCCW }
}

public struct ArcGeometry: Sendable {
    public var startRadius: Double
    public var endRadius: Double
    public var startAngle: Double
    /// Signed sweep in radians: positive counter-clockwise, negative clockwise.
    public var sweep: Double
}

/// One motion of the tool: a rapid, a straight feed move or an arc. Coordinates are the machine position of the
/// tool tip in millimetres (work offsets and G92 are applied).
public struct Segment: Sendable {
    public var kind: SegmentKind
    public var plane: PlaneID
    public var start: SIMD3<Double>
    public var end: SIMD3<Double>
    /// Arc centre (all three components; the perpendicular component equals the start). Zero for straight moves.
    public var center: SIMD3<Double>
    /// Feed in mm/min. 0 for rapids.
    public var feed: Double
    public var tool: Int32
    /// Zero-based source line of the block that produced this move.
    public var line: Int32
    /// Cutter radius compensation while the program was read: 0 off, 1 left (G41), -1 right (G42).
    /// Cleared again once the compensation pass has produced the real tool centre path.
    public var compSide: Int8
    /// 0 none, 1 start-up block, 2 active, 3 cancel block.
    public var compPhase: UInt8
    public var compRadius: Double

    public init(kind: SegmentKind, plane: PlaneID, start: SIMD3<Double>, end: SIMD3<Double>,
                center: SIMD3<Double>, feed: Double, tool: Int32, line: Int32,
                compSide: Int8 = 0, compPhase: UInt8 = 0, compRadius: Double = 0) {
        self.kind = kind
        self.plane = plane
        self.start = start
        self.end = end
        self.center = center
        self.feed = feed
        self.tool = tool
        self.line = line
        self.compSide = compSide
        self.compPhase = compPhase
        self.compRadius = compRadius
    }

    /// Valid only for arcs.
    public var arcGeometry: ArcGeometry {
        let ax = plane.axes
        let su = start[ax.a0] - center[ax.a0]
        let sv = start[ax.a1] - center[ax.a1]
        let eu = end[ax.a0] - center[ax.a0]
        let ev = end[ax.a1] - center[ax.a1]
        let r0 = (su * su + sv * sv).squareRoot()
        let r1 = (eu * eu + ev * ev).squareRoot()
        let a0 = atan2(sv, su)
        let a1 = atan2(ev, eu)
        var sweep = a1 - a0
        if kind == .arcCCW {
            if sweep <= 1e-9 { sweep += 2 * Double.pi }
        } else {
            if sweep >= -1e-9 { sweep -= 2 * Double.pi }
        }
        return ArcGeometry(startRadius: r0, endRadius: r1, startAngle: a0, sweep: sweep)
    }

    /// Length of the move along the tool path.
    public var length: Double {
        if !kind.isArc { return norm(end - start) }
        let g = arcGeometry
        let planar = abs(g.sweep) * (g.startRadius + g.endRadius) / 2
        let lift = end[plane.axes.h] - start[plane.axes.h]
        return (planar * planar + lift * lift).squareRoot()
    }

    /// Calls `body` with consecutive straight pieces. For arcs the pieces keep the chord error below `tolerance`.
    public func forEachLine(tolerance: Double, _ body: (SIMD3<Double>, SIMD3<Double>) -> Void) {
        if !kind.isArc {
            body(start, end)
            return
        }
        let g = arcGeometry
        let ax = plane.axes
        let radius = max(g.startRadius, g.endRadius)
        var steps = 1
        if radius > tolerance {
            let maxAngle = 2 * acos(max(-1.0, min(1.0, 1 - tolerance / radius)))
            if maxAngle > 1e-9 {
                steps = max(1, min(200_000, Int((abs(g.sweep) / maxAngle).rounded(.up))))
            }
        }
        var previous = start
        if steps > 1 {
            for k in 1..<steps {
                let t = Double(k) / Double(steps)
                let angle = g.startAngle + g.sweep * t
                let r = g.startRadius + (g.endRadius - g.startRadius) * t
                var p = SIMD3<Double>(repeating: 0)
                p[ax.a0] = center[ax.a0] + r * cos(angle)
                p[ax.a1] = center[ax.a1] + r * sin(angle)
                p[ax.h] = start[ax.h] + (end[ax.h] - start[ax.h]) * t
                body(previous, p)
                previous = p
            }
        }
        body(previous, end)
    }

    /// All points of the flattened move, including start and end.
    public func flattened(tolerance: Double) -> [SIMD3<Double>] {
        var points: [SIMD3<Double>] = [start]
        forEachLine(tolerance: tolerance) { _, to in points.append(to) }
        return points
    }
}

public struct Diagnostic: Sendable {
    public enum Severity: Sendable { case info, warning, error }
    public var severity: Severity
    /// Zero-based source line.
    public var line: Int
    public var message: String
}

/// Where the cutter radius used for compensation came from.
public enum RadiusSource: Sendable, Equatable {
    /// The program set it itself (G10 L12 or L13).
    case program
    /// The user's tool table.
    case table
    /// A guess from the comment next to the tool change.
    case comment(line: Int)
    /// Nothing was known, so compensation was skipped.
    case missing
}

/// One offset register used with G41 or G42.
public struct CompensationUse: Sendable {
    public var register: Int
    /// The tool that was in the spindle at the first use.
    public var tool: Int
    /// Radius in millimetres, or nil when it was missing.
    public var radius: Double?
    public var source: RadiusSource
    /// Zero-based line of the first use.
    public var line: Int
}

/// The result of interpreting a program: the moves, what the interpreter could not handle, and totals.
public struct Toolpath: Sendable {
    public var segments: [Segment] = []
    public var diagnostics: [Diagnostic] = []
    public var suppressedDiagnostics = 0
    public var boundsMin = SIMD3<Double>(repeating: 0)
    public var boundsMax = SIMD3<Double>(repeating: 0)
    public var hasBounds = false
    /// Every offset register the program used with G41/G42, keyed by register number.
    public var compensationUse: [Int: CompensationUse] = [:]
    public var rapidLength = 0.0
    public var cuttingLength = 0.0
    public var dwellSeconds = 0.0
    public var toolChanges = 0
    public var finalPosition = SIMD3<Double>(repeating: 0)
    public var endedByProgramEnd = false

    public init() {}

    /// Simple cycle time: straight division of length by feed, no acceleration yet.
    public func estimatedSeconds(rapidFeed: Double) -> Double {
        var seconds = dwellSeconds
        if rapidFeed > 0 { seconds += rapidLength / rapidFeed * 60 }
        for s in segments where s.kind != .rapid && s.feed > 0 {
            seconds += s.length / s.feed * 60
        }
        return seconds
    }

    /// Recomputes lengths and bounds after the segments were replaced.
    mutating func recomputeTotals() {
        rapidLength = 0
        cuttingLength = 0
        hasBounds = false
        for s in segments {
            let length = s.length
            if s.kind == .rapid { rapidLength += length } else { cuttingLength += length }
            extend(bounds: s.start)
            extend(bounds: s.end)
            if s.kind.isArc {
                s.forEachLine(tolerance: 0.05) { _, to in extend(bounds: to) }
            }
        }
    }

    mutating func extend(bounds point: SIMD3<Double>) {
        if !hasBounds {
            boundsMin = point
            boundsMax = point
            hasBounds = true
        } else {
            boundsMin = pointwiseMin(boundsMin, point)
            boundsMax = pointwiseMax(boundsMax, point)
        }
    }
}
