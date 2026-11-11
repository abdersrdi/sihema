import SwiftUI
import SihemaCore

/// Numbers from the core: size of the program, speed, diagnostics, and a first 3-axis material removal run.
struct ReportView: View {
    let analysis: Analysis?

    @State private var simulationText: String?
    @State private var simulating = false

    var body: some View {
        content
            .task(id: automaticRun) {
                // the screenshot tests start the material removal by themselves
                if UITestSupport.simulate, simulationText == nil, let analysis { runSimulation(analysis) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let analysis {
            List {
                Section("Program") {
                    row("Lines", "\(analysis.lineCount)")
                    row("Words", "\(analysis.wordCount)")
                    row("Moves", "\(analysis.toolpath.segments.count)")
                    row("Cutting length", String(format: "%.1f mm", analysis.toolpath.cuttingLength))
                    row("Rapid length", String(format: "%.1f mm", analysis.toolpath.rapidLength))
                    row("Cycle time (with acceleration)", formatTime(analysis.toolpath.cycleTime()))
                }
                Section("Core speed") {
                    row("Tokenize", String(format: "%.3f s", analysis.tokenizeSeconds))
                    row("Interpret", String(format: "%.3f s", analysis.interpretSeconds))
                }
                Section("Simulation (3-axis, flat 6 mm tool, stock top at Z0)") {
                    Button(simulating ? "Simulating..." : "Run material removal") {
                        runSimulation(analysis)
                    }
                    .disabled(simulating || analysis.toolpath.segments.isEmpty)
                    if let simulationText { Text(simulationText).font(.callout.monospaced()) }
                }
                Section("Messages (\(analysis.toolpath.diagnostics.count + analysis.toolpath.suppressedDiagnostics))") {
                    if analysis.toolpath.diagnostics.isEmpty {
                        Text("Nothing to report.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(analysis.toolpath.diagnostics.enumerated()), id: \.offset) { _, d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Line \(d.line + 1)").font(.caption).foregroundStyle(.secondary)
                            Text(d.message)
                        }
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var automaticRun: String { analysis?.id.uuidString ?? "" }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%ld:%02ld:%02ld", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func runSimulation(_ analysis: Analysis) {
        simulating = true
        simulationText = nil
        let path = analysis.toolpath
        Task {
            let text = await Task.detached(priority: .userInitiated) { () -> String in
                let margin = 5.0
                let minX = path.boundsMin.x - margin
                let minY = path.boundsMin.y - margin
                let maxX = path.boundsMax.x + margin
                let maxY = path.boundsMax.y + margin
                // keep the grid under about 4 million columns
                var cell = 0.25
                while ((maxX - minX) / cell) * ((maxY - minY) / cell) > 4_000_000 { cell *= 1.5 }
                let grid = DexelGrid(minX: minX, minY: minY, maxX: maxX, maxY: maxY, cell: cell, stockTop: 0)
                let clock = ContinuousClock()
                var result = SimulationResult(removedVolume: 0, columnUpdates: 0, rapidMovesThroughStock: [])
                let elapsed = clock.measure {
                    result = DexelSimulator.simulate(toolpath: path, grid: grid,
                                                     defaultTool: EndMill(shape: .flat, radius: 3))
                }
                var lines = [
                    "Grid \(grid.nx) x \(grid.ny) columns at " + String(format: "%.2f mm", cell),
                    String(format: "Time %.2f s", elapsed.seconds),
                    String(format: "Removed %.0f mm3", result.removedVolume),
                    "Rapid moves through stock: \(result.rapidMovesThroughStock.count)"
                ]
                if !result.rapidMovesThroughStock.isEmpty {
                    let shown = result.rapidMovesThroughStock.prefix(10).map { String($0 + 1) }.joined(separator: ", ")
                    lines.append("Lines: \(shown)")
                }
                return lines.joined(separator: "\n")
            }.value
            simulationText = text
            simulating = false
        }
    }
}
