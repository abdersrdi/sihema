import Foundation

private typealias V2 = SIMD2<Double>

@inline(__always) private func dot2(_ a: V2, _ b: V2) -> Double { a.x * b.x + a.y * b.y }
@inline(__always) private func cross2(_ a: V2, _ b: V2) -> Double { a.x * b.y - a.y * b.x }
@inline(__always) private func len2(_ a: V2) -> Double { dot2(a, a).squareRoot() }

/// A line or an arc in the compensation plane.
private struct Prim {
    var isArc: Bool
    var p0: V2
    var p1: V2
    var center: V2
    var ccw: Bool
    var radius: Double
    /// Size of the sweep in radians (arcs only).
    var sweep: Double

    func tangent(atEnd: Bool) -> V2 {
        if !isArc {
            let d = p1 - p0
            let n = len2(d)
            return n > 0 ? d / n : V2(1, 0)
        }
        let r = (atEnd ? p1 : p0) - center
        let n = len2(r)
        guard n > 0 else { return V2(1, 0) }
        return ccw ? V2(-r.y, r.x) / n : V2(r.y, -r.x) / n
    }
}

/// The path of the tool when the cutter is on `side` (+1 left, -1 right) of the programmed path.
private func offset(_ p: Prim, side: Double, r: Double) -> Prim? {
    if !p.isArc {
        let t = p.tangent(atEnd: false)
        let distance: Double = side * r
        let normal = V2(-t.y, t.x)
        let n = V2(normal.x * distance, normal.y * distance)
        var q = p
        q.p0 = p.p0 + n
        q.p1 = p.p1 + n
        return q
    }
    let direction = p.ccw ? 1.0 : -1.0
    let newRadius = p.radius - side * direction * r
    if newRadius < 1e-9 { return nil }
    let k = newRadius / p.radius
    var q = p
    q.p0 = p.center + (p.p0 - p.center) * k
    q.p1 = p.center + (p.p1 - p.center) * k
    q.radius = newRadius
    return q
}

private func lineCircle(_ line: Prim, _ arc: Prim) -> [V2] {
    let d = line.p1 - line.p0
    let f = line.p0 - arc.center
    let a = dot2(d, d)
    let b = 2 * dot2(f, d)
    let c = dot2(f, f) - arc.radius * arc.radius
    let discriminant = b * b - 4 * a * c
    if a < 1e-18 || discriminant < 0 { return [] }
    let root = discriminant.squareRoot()
    return [(-b - root) / (2 * a), (-b + root) / (2 * a)].map { line.p0 + d * $0 }
}

private func circleCircle(_ a: Prim, _ b: Prim) -> [V2] {
    let d = b.center - a.center
    let distance = len2(d)
    if distance < 1e-12 { return [] }
    let x = (distance * distance + a.radius * a.radius - b.radius * b.radius) / (2 * distance)
    let h2 = a.radius * a.radius - x * x
    if h2 < 0 { return [] }
    let h = h2.squareRoot()
    let u = d / distance
    let n = V2(-u.y, u.x)
    let base = a.center + u * x
    return [base + n * h, base - n * h]
}

/// Intersections of the full lines or circles that carry two primitives.
private func intersections(_ a: Prim, _ b: Prim) -> [V2] {
    switch (a.isArc, b.isArc) {
    case (false, false):
        let da = a.p1 - a.p0
        let db = b.p1 - b.p0
        let denominator = cross2(da, db)
        if abs(denominator) < 1e-12 * max(1, len2(da) * len2(db)) { return [] }
        let t = cross2(b.p0 - a.p0, db) / denominator
        return [a.p0 + da * t]
    case (false, true): return lineCircle(a, b)
    case (true, false): return lineCircle(b, a)
    case (true, true): return circleCircle(a, b)
    }
}

private struct Joint {
    /// Where the offset path of the first move ends.
    var exit: V2
    /// Where the offset path of the second move starts.
    var entry: V2
    /// For an outside corner: the arc around the programmed corner that joins exit to entry.
    var connectorCenter: V2?
    var connectorCCW = false
    var problem: String?
}

private func makeJoint(_ a: Prim, _ b: Prim, _ oa: Prim?, _ ob: Prim?, side: Double) -> Joint {
    guard let oa, let ob else {
        return Joint(exit: a.p1, entry: a.p1, connectorCenter: nil,
                     problem: "the cutter radius is larger than an arc radius, so the offset path collapses")
    }
    let ta = a.tangent(atEnd: true)
    let tb = b.tangent(atEnd: false)
    let turn = cross2(ta, tb)
    let e = oa.p1
    let s = ob.p0
    if len2(e - s) < 1e-7 {
        return Joint(exit: e, entry: s, connectorCenter: nil, problem: nil)
    }
    if turn * side > 1e-9 {
        // inside corner: the two offset paths cross, so both are cut short at the crossing
        let candidates = intersections(oa, ob)
        guard let j = candidates.min(by: { len2($0 - a.p1) < len2($1 - a.p1) }) else {
            return Joint(exit: e, entry: s, connectorCenter: nil, problem: "the offset paths do not meet")
        }
        var problem: String?
        if !oa.isArc {
            let d = oa.p1 - oa.p0
            let t = dot2(j - oa.p0, d) / max(dot2(d, d), 1e-18)
            if t < -1e-6 { problem = "the cutter is too large for the move before this corner and would gouge" }
        }
        if !ob.isArc {
            let d = ob.p1 - ob.p0
            let t = dot2(j - ob.p0, d) / max(dot2(d, d), 1e-18)
            if t > 1 + 1e-6 { problem = "the cutter is too large for the move after this corner and would gouge" }
        }
        return Joint(exit: j, entry: j, connectorCenter: nil, problem: problem)
    }
    // outside corner (or a full reversal): the tool swings round the programmed corner
    let ccw = abs(turn) <= 1e-9 ? side < 0 : turn > 0
    return Joint(exit: e, entry: s, connectorCenter: a.p1, connectorCCW: ccw, problem: nil)
}

/// Turns the programmed path of blocks read under G41/G42 into the path of the tool centre.
enum CutterCompensation {
    static func apply(_ tp: inout Toolpath, maxDiagnostics: Int) {
        let input = tp.segments
        var output: [Segment] = []
        output.reserveCapacity(input.count + input.count / 8)
        var problems: [(line: Int, message: String)] = []

        var i = 0
        while i < input.count {
            let s = input[i]
            if s.compSide == 0 || s.compRadius <= 0 {
                output.append(s)
                i += 1
                continue
            }
            var j = i
            while j < input.count && input[j].compSide != 0 {
                j += 1
                if input[j - 1].compPhase == 3 { break }
            }
            compensate(Array(input[i..<j]), into: &output, problems: &problems)
            i = j
        }

        tp.segments = output
        for problem in problems {
            if tp.diagnostics.count < maxDiagnostics {
                tp.diagnostics.append(Diagnostic(severity: .warning, line: problem.line,
                                                 message: "Cutter radius compensation: " + problem.message))
            } else {
                tp.suppressedDiagnostics += 1
            }
        }
        tp.recomputeTotals()
    }

    private static func cleared(_ s: Segment) -> Segment {
        var t = s
        t.compSide = 0
        t.compPhase = 0
        t.compRadius = 0
        return t
    }

    private static func compensate(_ segments: [Segment], into output: inout [Segment],
                                   problems: inout [(line: Int, message: String)]) {
        let side = Double(segments[0].compSide)
        let r = segments[0].compRadius
        let plane = segments[0].plane
        let ax = plane.axes

        func uv(_ p: SIMD3<Double>) -> V2 { V2(p[ax.a0], p[ax.a1]) }
        func make3(_ p: V2, h: Double) -> SIMD3<Double> {
            var q = SIMD3<Double>(repeating: 0)
            q[ax.a0] = p.x
            q[ax.a1] = p.y
            q[ax.h] = h
            return q
        }

        var planarIndex: [Int] = []
        var prims: [Prim] = []
        for (index, s) in segments.enumerated() {
            let planar = s.plane == plane && (s.kind.isArc || len2(uv(s.end) - uv(s.start)) > 1e-9)
            guard planar else { continue }
            planarIndex.append(index)
            if s.kind.isArc {
                let g = s.arcGeometry
                prims.append(Prim(isArc: true, p0: uv(s.start), p1: uv(s.end), center: uv(s.center),
                                  ccw: s.kind == .arcCCW, radius: g.startRadius, sweep: abs(g.sweep)))
            } else {
                prims.append(Prim(isArc: false, p0: uv(s.start), p1: uv(s.end), center: V2(0, 0),
                                  ccw: false, radius: 0, sweep: 0))
            }
        }
        if prims.isEmpty {
            for s in segments { output.append(cleared(s)) }
            return
        }

        let offsets = prims.map { offset($0, side: side, r: r) }
        var joints: [Joint] = []
        if prims.count > 1 {
            for k in 0..<(prims.count - 1) {
                let joint = makeJoint(prims[k], prims[k + 1], offsets[k], offsets[k + 1], side: side)
                joints.append(joint)
                if let problem = joint.problem {
                    problems.append((Int(segments[planarIndex[k + 1]].line), problem))
                }
            }
        }

        var cursor = segments[0].start
        var next = 0
        for (index, s) in segments.enumerated() {
            guard next < planarIndex.count, planarIndex[next] == index else {
                // a move outside the compensation plane (for example Z): same move, from where the tool centre is
                var t = cleared(s)
                t.start = cursor
                t.end = cursor + (s.end - s.start)
                output.append(t)
                cursor = t.end
                continue
            }
            let k = next
            next += 1
            let isFirst = k == 0
            let isLast = k == prims.count - 1

            if k > 0, let center = joints[k - 1].connectorCenter {
                let joint = joints[k - 1]
                let h = cursor[ax.h]
                let rapid = s.kind == .rapid
                let connector = Segment(
                    kind: rapid ? .rapid : (joint.connectorCCW ? .arcCCW : .arcCW), plane: plane,
                    start: make3(joint.exit, h: h), end: make3(joint.entry, h: h),
                    center: rapid ? SIMD3<Double>(repeating: 0) : make3(center, h: h),
                    feed: s.feed, tool: s.tool, line: s.line)
                output.append(connector)
                cursor = connector.end
            }

            let startsCompensation = isFirst && s.compPhase == 1
            let endsCompensation = isLast && s.compPhase == 3
            let startUV: V2 = isFirst ? (startsCompensation ? uv(s.start) : (offsets[k]?.p0 ?? uv(s.start))) : joints[k - 1].entry
            let endUV: V2 = isLast ? (endsCompensation ? uv(s.end) : (offsets[k]?.p1 ?? uv(s.end))) : joints[k].exit
            let straight = startsCompensation || endsCompensation || !s.kind.isArc || offsets[k] == nil

            var piece: Segment
            if straight {
                piece = Segment(kind: s.kind.isArc ? .linear : s.kind, plane: plane,
                                start: make3(startUV, h: s.start[ax.h]), end: make3(endUV, h: s.end[ax.h]),
                                center: SIMD3<Double>(repeating: 0), feed: s.feed, tool: s.tool, line: s.line)
            } else {
                let center = offsets[k]!.center
                piece = Segment(kind: s.kind, plane: plane,
                                start: make3(startUV, h: s.start[ax.h]), end: make3(endUV, h: s.end[ax.h]),
                                center: make3(center, h: s.start[ax.h]), feed: s.feed, tool: s.tool, line: s.line)
                if piece.arcGeometry.sweep.magnitude > prims[k].sweep + 1e-3 {
                    problems.append((Int(s.line), "the offset arc would be cut longer than the programmed arc; the corner is not trimmed"))
                    piece.start = make3(offsets[k]!.p0, h: s.start[ax.h])
                    piece.end = make3(offsets[k]!.p1, h: s.end[ax.h])
                }
            }
            output.append(piece)
            cursor = piece.end
        }
    }
}
