import Foundation

public struct EndMill: Sendable {
    public enum Shape: Sendable { case flat, ball }

    public var shape: Shape
    public var radius: Double

    public init(shape: Shape, radius: Double) {
        self.shape = shape
        self.radius = radius
    }
}

/// Height-field ("dexel") model of the stock for 3-axis milling: one remaining height per column.
/// This is the CPU reference implementation. The Metal version must reproduce its results.
public final class DexelGrid {
    public let nx: Int
    public let ny: Int
    public let cell: Double
    public let originX: Double
    public let originY: Double
    public let stockTop: Float
    public private(set) var top: [Float]

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double, cell: Double, stockTop: Double) {
        precondition(cell > 0 && maxX > minX && maxY > minY, "invalid dexel grid")
        self.cell = cell
        self.originX = minX
        self.originY = minY
        self.nx = max(1, Int(((maxX - minX) / cell).rounded(.up)))
        self.ny = max(1, Int(((maxY - minY) / cell).rounded(.up)))
        self.stockTop = Float(stockTop)
        self.top = [Float](repeating: Float(stockTop), count: nx * ny)
    }

    /// Remaining height of the column that contains (x, y), or nil outside the grid.
    public func height(x: Double, y: Double) -> Double? {
        let i = Int(((x - originX) / cell).rounded(.down))
        let j = Int(((y - originY) / cell).rounded(.down))
        guard i >= 0, i < nx, j >= 0, j < ny else { return nil }
        return Double(top[j * nx + i])
    }

    /// Material removed so far, in cubic millimetres.
    public var removedVolume: Double {
        var sum = 0.0
        for h in top { sum += Double(stockTop - h) }
        return sum * cell * cell
    }

    /// Moves the tool tip along a straight line and removes material. Returns how many columns were lowered.
    @discardableResult
    public func cutLine(tool: EndMill, from a: SIMD3<Double>, to b: SIMD3<Double>, includeStart: Bool = true) -> Int {
        let d = b - a
        let length = norm(d)
        let steps = max(1, Int((length / cell).rounded(.up)))
        var lowered = 0
        top.withUnsafeMutableBufferPointer { buffer in
            for s in (includeStart ? 0 : 1)...steps {
                let t = Double(s) / Double(steps)
                lowered += stamp(buffer, tool: tool, at: a + d * t)
            }
        }
        return lowered
    }

    private func stamp(_ buffer: UnsafeMutableBufferPointer<Float>, tool: EndMill, at p: SIMD3<Double>) -> Int {
        let r = tool.radius
        let r2 = r * r
        let i0 = max(0, Int(((p.x - r - originX) / cell).rounded(.down)))
        let i1 = min(nx - 1, Int(((p.x + r - originX) / cell).rounded(.down)))
        let j0 = max(0, Int(((p.y - r - originY) / cell).rounded(.down)))
        let j1 = min(ny - 1, Int(((p.y + r - originY) / cell).rounded(.down)))
        if i0 > i1 || j0 > j1 { return 0 }
        let ball = tool.shape == .ball
        var changed = 0
        for j in j0...j1 {
            let dy = originY + (Double(j) + 0.5) * cell - p.y
            let dy2 = dy * dy
            if dy2 > r2 { continue }
            let row = j * nx
            for i in i0...i1 {
                let dx = originX + (Double(i) + 0.5) * cell - p.x
                let d2 = dx * dx + dy2
                if d2 > r2 { continue }
                let z = ball ? p.z + r - (r2 - d2).squareRoot() : p.z
                let zf = Float(z)
                if zf < buffer[row + i] {
                    buffer[row + i] = zf
                    changed += 1
                }
            }
        }
        return changed
    }
}

public struct SimulationResult: Sendable {
    public var removedVolume: Double
    public var columnUpdates: Int
    /// Source lines of rapid moves that cut into the stock (a rapid that removes material is a crash).
    public var rapidMovesThroughStock: [Int]

    public init(removedVolume: Double, columnUpdates: Int, rapidMovesThroughStock: [Int]) {
        self.removedVolume = removedVolume
        self.columnUpdates = columnUpdates
        self.rapidMovesThroughStock = rapidMovesThroughStock
    }
}

public enum DexelSimulator {
    /// Replays a toolpath through the stock. Tools come from `tools` by tool number, with `defaultTool` otherwise.
    public static func simulate(toolpath: Toolpath, grid: DexelGrid, tools: [Int32: EndMill] = [:],
                                defaultTool: EndMill, arcTolerance: Double = 0.01) -> SimulationResult {
        var gouges = Set<Int>()
        var updates = 0
        var firstPoint = true
        for segment in toolpath.segments {
            let tool = tools[segment.tool] ?? defaultTool
            var lowered = 0
            if firstPoint {
                lowered += grid.cutLine(tool: tool, from: segment.start, to: segment.start)
                firstPoint = false
            }
            segment.forEachLine(tolerance: arcTolerance) { from, to in
                lowered += grid.cutLine(tool: tool, from: from, to: to, includeStart: false)
            }
            updates += lowered
            if segment.kind == .rapid && lowered > 0 {
                gouges.insert(Int(segment.line))
            }
        }
        return SimulationResult(removedVolume: grid.removedVolume, columnUpdates: updates,
                                rapidMovesThroughStock: gouges.sorted())
    }
}
