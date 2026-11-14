import Foundation

/// How the machine moves, for estimating cycle time. Real values come from the machine profile; these defaults
/// are typical for a small machining centre.
public struct MotionModel: Sendable {
    /// Rapid traverse rate of each axis in mm/min. A rapid move takes as long as its slowest axis needs.
    public var rapidFeedMMPerMin = 15_000.0
    /// Axis acceleration and deceleration in mm/s^2.
    public var accelerationMMPerS2 = 1_500.0
    /// Time for one tool change in seconds.
    public var toolChangeSeconds = 5.0
    /// The sudden change of speed one axis is allowed at the join of two moves, in mm/s. A join that turns by a
    /// small angle needs only a small change, so the tool keeps its speed; a sharp corner needs a large one, so the
    /// tool slows until the change fits. Zero means an exact stop at every corner.
    public var cornerStepMMPerS = 5.0

    public init() {}
}

public struct TravelLimits: Sendable {
    public var minimum: SIMD3<Double>
    public var maximum: SIMD3<Double>

    public init(minimum: SIMD3<Double>, maximum: SIMD3<Double>) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// The result of fitting the acceleration of the motion model to a measured cycle time.
public enum AccelerationFit: Sendable, Equatable {
    case fitted(Double)
    /// The measured time is shorter than the program can run even with a very high acceleration, so the other values
    /// (rapid rate, tool change time) are too slow.
    case tooFast(shortestPossible: Double)
    /// The measured time is longer than the program takes even with a very low acceleration.
    case tooSlow(longestAtLowestAcceleration: Double)
}

extension Segment {
    /// Unit direction of travel at the start or end of the move. Zero for a move that has no length.
    func direction(atEnd: Bool) -> SIMD3<Double> {
        if !kind.isArc {
            let d = end - start
            let n = norm(d)
            return n > 1e-12 ? d / n : SIMD3<Double>(repeating: 0)
        }
        let ax = plane.axes
        let p = atEnd ? end : start
        let u = p[ax.a0] - center[ax.a0]
        let v = p[ax.a1] - center[ax.a1]
        let n = (u * u + v * v).squareRoot()
        guard n > 1e-12 else { return SIMD3<Double>(repeating: 0) }
        var t = SIMD3<Double>(repeating: 0)
        if kind == .arcCCW {
            t[ax.a0] = -v / n
            t[ax.a1] = u / n
        } else {
            t[ax.a0] = v / n
            t[ax.a1] = -u / n
        }
        return t
    }
}

extension Toolpath {
    /// Cycle time with acceleration: each move is a trapezoid of speed, and the tool only keeps its speed round a
    /// corner as far as the allowed speed step of an axis permits. Curves are limited by acceleration towards their
    /// centre (v squared over the radius), and rapid moves by the rate of the axis that has the most to travel.
    public func cycleTime(model: MotionModel = MotionModel()) -> Double {
        let n = segments.count
        let extra = dwellSeconds + Double(toolChanges) * model.toolChangeSeconds
        if n == 0 { return extra }
        let a = max(model.accelerationMMPerS2, 1)

        var length = [Double](repeating: 0, count: n)
        var cruise = [Double](repeating: 0, count: n)
        for (i, s) in segments.enumerated() {
            length[i] = s.length
            if s.kind == .rapid || s.feed <= 0 {
                // every axis moves at most at its rapid rate: along the path that is the rate divided by the
                // largest share of the move that one axis carries
                let u = s.direction(atEnd: false)
                let share = max(abs(u.x), abs(u.y), abs(u.z))
                cruise[i] = max(model.rapidFeedMMPerMin, 1) / 60 / max(share, 1e-9)
            } else {
                cruise[i] = max(s.feed, 1) / 60
            }
            if s.kind.isArc {
                let radius = s.arcGeometry.startRadius
                if radius > 0 { cruise[i] = min(cruise[i], max((a * radius).squareRoot(), 1)) }
            }
        }

        // speed at the start of each move; the last entry is the speed at the end of the program
        var speed = [Double](repeating: 0, count: n + 1)
        if n > 1 {
            for i in 1..<n {
                let t0 = segments[i - 1].direction(atEnd: true)
                let t1 = segments[i].direction(atEnd: false)
                var limit = min(cruise[i - 1], cruise[i])
                if norm(t0) > 0 && norm(t1) > 0 {
                    let change = t1 - t0
                    let step = max(abs(change.x), abs(change.y), abs(change.z))
                    if step > 1e-9 { limit = min(limit, max(model.cornerStepMMPerS, 0) / step) }
                }
                speed[i] = limit
            }
        }
        for i in 0..<n {
            speed[i + 1] = min(speed[i + 1], (speed[i] * speed[i] + 2 * a * length[i]).squareRoot())
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            speed[i] = min(speed[i], (speed[i + 1] * speed[i + 1] + 2 * a * length[i]).squareRoot())
        }

        var seconds = extra
        for i in 0..<n where length[i] > 0 {
            let c = cruise[i]
            let v0 = min(speed[i], c)
            let v1 = min(speed[i + 1], c)
            let d1 = (c * c - v0 * v0) / (2 * a)
            let d2 = (c * c - v1 * v1) / (2 * a)
            if d1 + d2 <= length[i] {
                seconds += (c - v0) / a + (c - v1) / a + (length[i] - d1 - d2) / c
            } else {
                let peak = ((2 * a * length[i] + v0 * v0 + v1 * v1) / 2).squareRoot()
                seconds += (peak - v0) / a + (peak - v1) / a
            }
        }
        return seconds
    }

    /// The acceleration at which this program takes `measuredSeconds`, with the other values of `model` kept.
    /// The time only falls as acceleration rises, so the answer is found by halving the range.
    public func fitAcceleration(toMeasuredSeconds measured: Double, model: MotionModel = MotionModel()) -> AccelerationFit {
        var m = model
        let lowest = 5.0, highest = 200_000.0
        m.accelerationMMPerS2 = highest
        let fastest = cycleTime(model: m)
        m.accelerationMMPerS2 = lowest
        let slowest = cycleTime(model: m)
        if measured < fastest { return .tooFast(shortestPossible: fastest) }
        if measured > slowest { return .tooSlow(longestAtLowestAcceleration: slowest) }
        var low = lowest, high = highest
        for _ in 0..<60 {
            let middle = (low * high).squareRoot() // halve on a logarithmic scale: the range spans decades
            m.accelerationMMPerS2 = middle
            if cycleTime(model: m) > measured { low = middle } else { high = middle }
        }
        return .fitted((low * high).squareRoot())
    }

    /// One message for each axis and direction in which the path leaves the machine's travel, naming the first block.
    public func travelViolations(_ limits: TravelLimits) -> [Diagnostic] {
        var found = [Bool](repeating: false, count: 6)
        var result: [Diagnostic] = []
        let names = ["X", "Y", "Z"]
        let tolerance = 1e-6

        func check(_ p: SIMD3<Double>, line: Int) {
            for k in 0..<3 {
                if p[k] < limits.minimum[k] - tolerance && !found[k * 2] {
                    found[k * 2] = true
                    result.append(Diagnostic(severity: .warning, line: line,
                        message: "\(names[k]) goes below its travel limit: \(String(format: "%.3f", p[k])) (limit \(String(format: "%.3f", limits.minimum[k])))"))
                }
                if p[k] > limits.maximum[k] + tolerance && !found[k * 2 + 1] {
                    found[k * 2 + 1] = true
                    result.append(Diagnostic(severity: .warning, line: line,
                        message: "\(names[k]) goes above its travel limit: \(String(format: "%.3f", p[k])) (limit \(String(format: "%.3f", limits.maximum[k])))"))
                }
            }
        }

        for s in segments {
            let line = Int(s.line)
            check(s.end, line: line)
            if s.kind.isArc {
                s.forEachLine(tolerance: 0.05) { _, to in check(to, line: line) }
            } else {
                check(s.start, line: line)
            }
            if !found.contains(false) { break }
        }
        return result
    }
}
