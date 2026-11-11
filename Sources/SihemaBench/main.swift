import Foundation
import SihemaCore

// Phase 0 benchmark: how fast the core handles very large programs.
//
//   swift run -c release SihemaBench --lines 1000000 --dexel-moves 20000
//
// Prints a Markdown report.

func argument(_ name: String, default value: Int) -> Int {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: name), index + 1 < args.count, let v = Int(args[index + 1]) {
        return v
    }
    return value
}

/// Builds a synthetic CAM-style program: zig-zag passes with arcs at the row ends.
func makeProgram(lines: Int) -> String {
    var text = ""
    text.reserveCapacity(lines * 28)
    text += "%\nO1000 (SYNTHETIC BENCHMARK)\nG21 G90 G17 G94\nT1 M6\nS12000 M3\nG00 X0 Y0 Z5\nG01 Z-1 F800\n"
    var written = 7
    var y = 0.0
    var x = 0.0
    var direction = 1.0
    while written < lines - 3 {
        let nextX = x + 0.5 * direction
        if nextX > 100 || nextX < 0 {
            // half-circle turn to the next row, 0.5 mm further along Y
            let nextY = y + 0.5
            text += direction > 0
                ? "G03 X\(format(x)) Y\(format(nextY)) I0 J0.25 F800\n"
                : "G02 X\(format(x)) Y\(format(nextY)) I0 J0.25 F800\n"
            y = nextY
            direction = -direction
        } else {
            x = nextX
            text += "G01 X\(format(x)) Z-1. F800\n"
        }
        written += 1
    }
    text += "G00 Z5\nM30\n%\n"
    return text
}

func format(_ v: Double) -> String { String(format: "%.3f", v) }

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

func report(_ name: String, _ value: String, _ note: String = "") {
    print("| \(name) | \(value) | \(note) |")
}

let lineCount = argument("--lines", default: 1_000_000)
let dexelMoves = argument("--dexel-moves", default: 20_000)
let clock = ContinuousClock()

print("# Sihema core benchmark")
print("")
print("Lines requested: \(lineCount), dexel moves: \(dexelMoves)")
print("")
print("| Step | Result | Note |")
print("| --- | --- | --- |")

var program = ""
let tGenerate = clock.measure { program = makeProgram(lines: lineCount) }
report("Generate program", String(format: "%.2f s", seconds(tGenerate)),
       "\(program.utf8.count / 1024 / 1024) MiB of text")

var tokens = TokenizedProgram()
let tTokenize = clock.measure { tokens = GCodeTokenizer.tokenize(program) }
let tokenizeSeconds = seconds(tTokenize)
report("Tokenize", String(format: "%.3f s", tokenizeSeconds),
       "\(tokens.lineCount) lines, \(tokens.words.count) words, "
       + String(format: "%.1f M lines/s", Double(tokens.lineCount) / tokenizeSeconds / 1e6))

var toolpath = Toolpath()
let tInterpret = clock.measure { toolpath = FanucInterpreter().run(tokens) }
let interpretSeconds = seconds(tInterpret)
report("Interpret (Fanuc)", String(format: "%.3f s", interpretSeconds),
       "\(toolpath.segments.count) moves, "
       + String(format: "%.1f M moves/s", Double(toolpath.segments.count) / interpretSeconds / 1e6))
report("Diagnostics", "\(toolpath.diagnostics.count)",
       "\(toolpath.suppressedDiagnostics) suppressed")
report("Cycle time (simple)", String(format: "%.0f s", toolpath.estimatedSeconds(rapidFeed: 15_000)),
       "cutting \(Int(toolpath.cuttingLength)) mm, rapid \(Int(toolpath.rapidLength)) mm")

var flatPoints = 0
let tFlatten = clock.measure {
    for s in toolpath.segments {
        s.forEachLine(tolerance: 0.005) { _, _ in flatPoints += 1 }
    }
}
report("Flatten arcs (0.005 mm)", String(format: "%.3f s", seconds(tFlatten)), "\(flatPoints) straight pieces")

// Dexel: cut the first N moves into a 100 x 100 mm stock at 0.25 mm resolution.
var subset = Toolpath()
subset.segments = Array(toolpath.segments.prefix(dexelMoves))
let grid = DexelGrid(minX: -5, minY: -5, maxX: 105, maxY: 105, cell: 0.25, stockTop: 0)
var result = SimulationResult(removedVolume: 0, columnUpdates: 0, rapidMovesThroughStock: [])
let tDexel = clock.measure {
    result = DexelSimulator.simulate(toolpath: subset, grid: grid,
                                     defaultTool: EndMill(shape: .flat, radius: 3), arcTolerance: 0.01)
}
let dexelSeconds = seconds(tDexel)
report("Dexel CPU simulation", String(format: "%.3f s", dexelSeconds),
       "\(subset.segments.count) moves into \(grid.nx)x\(grid.ny) columns, "
       + String(format: "%.0f moves/s", Double(subset.segments.count) / dexelSeconds))
report("Removed volume", String(format: "%.0f mm3", result.removedVolume),
       "\(result.columnUpdates) column updates, \(result.rapidMovesThroughStock.count) rapid moves through stock")
