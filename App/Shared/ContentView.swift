import SwiftUI
import SihemaCore

struct ContentView: View {
    @Binding var document: GCodeDocument
    @State private var analysis: Analysis?

    var body: some View {
        TabView {
            CodeEditorView(text: $document.text)
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            ToolpathView(analysis: analysis)
                .tabItem { Label("Path", systemImage: "scribble.variable") }
            CompareView(baseText: document.text)
                .tabItem { Label("Compare", systemImage: "rectangle.split.2x1") }
            ReportView(analysis: analysis)
                .tabItem { Label("Report", systemImage: "list.bullet.rectangle") }
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
