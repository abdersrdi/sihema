import SwiftUI

struct SihemaApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: GCodeDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}

/// Used by the automated screenshot tests: a plain window with a ready-made program, no document browser.
struct DirectApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup { DirectRoot() }
            .defaultSize(width: 1100, height: 760)
        #else
        WindowGroup { DirectRoot() }
        #endif
    }
}

struct DirectRoot: View {
    @State private var document = GCodeDocument(text: DemoPrograms.main)

    var body: some View {
        ContentView(document: $document)
    }
}

@main
enum Launcher {
    static func main() {
        if UITestSupport.isDirect {
            DirectApp.main()
        } else {
            SihemaApp.main()
        }
    }
}
