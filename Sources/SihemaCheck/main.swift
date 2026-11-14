import Foundation
import SihemaCore

// Prints a report for each G-code file given on the command line, and optionally an SVG of the XY path.
//
//   SihemaCheck file1.nc file2.ngc [--svg-dir out]

func fmt(_ v: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", v) }

func svg(for toolpath: Toolpath) -> String {
    let minX = toolpath.boundsMin.x, minY = toolpath.boundsMin.y
    let width = max(toolpath.boundsMax.x - minX, 1e-6), height = max(toolpath.boundsMax.y - minY, 1e-6)
    let scale = 800.0 / max(width, height)
    func point(_ p: SIMD3<Double>) -> String {
        "\(fmt((p.x - minX) * scale, 2)),\(fmt((height - (p.y - minY)) * scale, 2))"
    }
    var rapid = "", cut = ""
    for s in toolpath.segments {
        s.forEachLine(tolerance: max(width, height) * 1e-4) { a, b in
            let line = "M\(point(a))L\(point(b))"
            if s.kind == .rapid { rapid += line } else { cut += line }
        }
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -10 \(fmt(width * scale + 20, 0)) \(fmt(height * scale + 20, 0))" width="900">
    <rect x="-10" y="-10" width="100%" height="100%" fill="#14080d"/>
    <path d="\(rapid)" stroke="#73b8ed" stroke-width="0.6" fill="none" stroke-dasharray="3 3"/>
    <path d="\(cut)" stroke="#f5d1db" stroke-width="1" fill="none"/>
    </svg>
    """
}

var files: [String] = []
var svgDir: String?
var dumpPath: String?
var config = MachineConfig()
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--svg-dir", !args.isEmpty {
        svgDir = args.removeFirst()
    } else if a == "--dump", !args.isEmpty {
        // one line per segment: kind plane start(3) end(3) centre(3) feed, for checking the path with other tools
        dumpPath = args.removeFirst()
    } else if a == "--radii", !args.isEmpty {
        // for example --radii 1=3,2=5 gives D1 a 3 mm radius and D2 a 5 mm radius
        for pair in args.removeFirst().split(separator: ",") {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let d = Int(parts[0]), let r = Double(parts[1]) { config.cutterRadii[d] = r }
        }
    } else if a == "--inches" {
        config.defaultInches = true
    } else {
        files.append(a)
    }
}

for path in files {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("## \(path)\nCannot read file\n")
        continue
    }
    let tokens = GCodeTokenizer.tokenize(data)
    let toolpath = FanucInterpreter(config: config).run(tokens)
    let name = (path as NSString).lastPathComponent
    print("## \(name)")
    print("- lines \(tokens.lineCount), words \(tokens.words.count), moves \(toolpath.segments.count) "
          + "(rapid \(toolpath.segments.filter { $0.kind == .rapid }.count), arcs \(toolpath.segments.filter { $0.kind.isArc }.count))")
    if toolpath.hasBounds {
        print("- bounds X \(fmt(toolpath.boundsMin.x))..\(fmt(toolpath.boundsMax.x)), "
              + "Y \(fmt(toolpath.boundsMin.y))..\(fmt(toolpath.boundsMax.y)), "
              + "Z \(fmt(toolpath.boundsMin.z))..\(fmt(toolpath.boundsMax.z))")
    }
    print("- cutting \(fmt(toolpath.cuttingLength, 1)) mm, rapid \(fmt(toolpath.rapidLength, 1)) mm, "
          + "time \(fmt(toolpath.estimatedSeconds(rapidFeed: 15_000), 1)) s, ended by M2/M30: \(toolpath.endedByProgramEnd)")
    print("- final position X \(fmt(toolpath.finalPosition.x, 4)) Y \(fmt(toolpath.finalPosition.y, 4)) Z \(fmt(toolpath.finalPosition.z, 4))")
    var counts: [String: (count: Int, first: Int)] = [:]
    for d in toolpath.diagnostics {
        let key = "[\(d.severity)] \(d.message)"
        if let existing = counts[key] { counts[key] = (existing.count + 1, existing.first) } else { counts[key] = (1, d.line + 1) }
    }
    for (message, info) in counts.sorted(by: { $0.key < $1.key }) {
        print("  - \(message) (first at line \(info.first))")
    }
    if let dump = dumpPath {
        var rows: [String] = []
        for s in toolpath.segments {
            let kind: String
            switch s.kind {
            case .rapid: kind = "R"
            case .linear: kind = "L"
            case .arcCW: kind = "CW"
            case .arcCCW: kind = "CCW"
            }
            let numbers = [s.start.x, s.start.y, s.start.z, s.end.x, s.end.y, s.end.z,
                           s.center.x, s.center.y, s.center.z, s.feed].map { fmt($0, 9) }
            rows.append(kind + " " + String(s.plane.rawValue) + " " + numbers.joined(separator: " "))
        }
        try? (rows.joined(separator: "\u{0A}") + "\u{0A}").write(toFile: dump, atomically: true, encoding: .utf8)
    }
    if let dir = svgDir, toolpath.hasBounds {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? svg(for: toolpath).write(toFile: dir + "/" + name + ".svg", atomically: true, encoding: .utf8)
    }
    print("")
}
