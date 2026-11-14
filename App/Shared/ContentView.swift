import SwiftUI
import SihemaCore

struct ContentView: View {
    @Binding var document: GCodeDocument
    @State private var analysis: Analysis?
    @State private var selection = UITestSupport.tab ?? "code"
    @State private var jump: JumpRequest?
    @ObservedObject private var settings = ToolSettings.shared

    /// What an analysis depends on: the program and the sizes the user entered.
    private struct AnalysisKey: Equatable {
        var text: String
        var radii: [Int: Double]
        var inches: Bool
    }

    /// Lines with errors or warnings, tinted in the editor, and the line the user jumped to.
    private var marks: EditorMarks {
        var problems: [Int: Int] = [:]
        for d in analysis?.toolpath.diagnostics ?? [] where d.severity != .info {
            let rank = d.severity == .error ? 2 : 1
            problems[d.line] = max(problems[d.line] ?? 0, rank)
        }
        return EditorMarks(problems: problems, focus: jump?.line)
    }

    var body: some View {
        TabView(selection: $selection) {
            CodeEditorView(text: $document.text, marks: marks, jump: jump)
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag("code")
            ToolpathView(analysis: analysis)
                .tabItem { Label("Path", systemImage: "scribble.variable") }
                .tag("path")
            ToolsView(analysis: analysis, settings: settings)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag("tools")
            CompareView(baseText: document.text)
                .tabItem { Label("Compare", systemImage: "rectangle.split.2x1") }
                .tag("compare")
            ReportView(analysis: analysis) { line in
                jump = JumpRequest(line: line)
                selection = "code"
            }
                .tabItem { Label("Report", systemImage: "list.bullet.rectangle") }
                .tag("report")
        }
        .onAppear {
            if let line = UITestSupport.jumpLine { jump = JumpRequest(line: line) }
        }
        .task(id: AnalysisKey(text: document.text, radii: settings.radii, inches: settings.defaultInches)) {
            // wait for typing to pause, then analyse off the main thread
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let text = document.text
            let config = settings.machine
            let result = await Task.detached(priority: .userInitiated) {
                Analysis.make(text: text, config: config)
            }.value
            if !Task.isCancelled { analysis = result }
        }
    }
}
