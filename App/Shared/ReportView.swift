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
                let path = analysis.toolpath
                Section("Summary") {
                    row("Cycle time (with acceleration)", formatTime(path.cycleTime()))
                    row("Cutting length", String(format: "%.1f mm", path.cuttingLength))
                    row("Rapid length", String(format: "%.1f mm", path.rapidLength))
                    row("Tool changes", "\(path.toolChanges)")
                    if path.dwellSeconds > 0 {
                        row("Dwell", String(format: "%.1f s", path.dwellSeconds))
                    }
                    row("Program end", path.endedByProgramEnd ? "M2 / M30" : "None (no M2 or M30)")
                    row("Lines / moves", "\(analysis.lineCount) / \(path.segments.count)")
                }
                Section(messagesTitle(path)) {
                    if path.diagnostics.isEmpty {
                        Label("Nothing to report", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(path.diagnostics.enumerated()), id: \.offset) { _, d in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(d.severity))
                                .foregroundStyle(tint(d.severity))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Line \(d.line + 1)").font(.caption).foregroundStyle(.secondary)
                                Text(d.message)
                            }
                        }
                    }
                }
                if path.hasBounds {
                    Section("Extent of the path (machine coordinates)") {
                        extentRow("X", path.boundsMin.x, path.boundsMax.x)
                        extentRow("Y", path.boundsMin.y, path.boundsMax.y)
                        extentRow("Z", path.boundsMin.z, path.boundsMax.z)
                    }
                }
                Section("Material removal (3-axis, flat 6 mm tool, stock top at Z0)") {
                    Button(simulating ? "Simulating..." : "Run material removal") {
                        runSimulation(analysis)
                    }
                    .disabled(simulating || path.segments.isEmpty)
                    if let simulationText { Text(simulationText).font(.callout.monospaced()) }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var automaticRun: String { analysis?.id.uuidString ?? "" }

    private func messagesTitle(_ path: Toolpath) -> String {
        let errors = path.diagnostics.filter { $0.severity == .error }.count
        let warnings = path.diagnostics.filter { $0.severity == .warning }.count
        let hidden = path.suppressedDiagnostics
        var parts: [String] = []
        if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        if hidden > 0 { parts.append("\(hidden) more not shown") }
        return parts.isEmpty ? "Messages" : "Messages: " + parts.joined(separator: ", ")
    }

    private func icon(_ severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func tint(_ severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    private func extentRow(_ axis: String, _ low: Double, _ high: Double) -> some View {
        row(axis, String(format: "%.1f to %.1f  (%.1f mm)", low, high, high - low))
    }

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
                _ = elapsed
                let volume = result.removedVolume >= 10_000
                    ? String(format: "%.1f cm3", result.removedVolume / 1000)
                    : String(format: "%.0f mm3", result.removedVolume)
                var lines = [
                    "Material removed: " + volume,
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
