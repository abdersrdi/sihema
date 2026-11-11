import SwiftUI
import SihemaCore

struct ContentView: View {
    @Binding var document: GCodeDocument
    @State private var analysis: Analysis?
    @State private var selection = UITestSupport.tab ?? "code"

    var body: some View {
        TabView(selection: $selection) {
            CodeEditorView(text: $document.text)
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag("code")
            ToolpathView(analysis: analysis)
                .tabItem { Label("Path", systemImage: "scribble.variable") }
                .tag("path")
            CompareView(baseText: document.text)
                .tabItem { Label("Compare", systemImage: "rectangle.split.2x1") }
                .tag("compare")
            ReportView(analysis: analysis)
                .tabItem { Label("Report", systemImage: "list.bullet.rectangle") }
                .tag("report")
        }
        .task(id: document.text) {
            // wait for typing to pause, then analyse off the main thread
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let text = document.text
            let result = await Task.detached(priority: .userInitiated) {
                Analysis.make(text: text)
            }.value
            if !Task.isCancelled { analysis = result }
        }
    }
}
