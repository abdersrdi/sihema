import SwiftUI

struct SihemaApp: App {
    var body: some Scene {
        // under the screenshot tests a new document opens with the sample program
        DocumentGroup(newDocument: GCodeDocument(text: UITestSupport.isDirect ? DemoPrograms.main : GCodeDocument.starterText)) { file in
            ContentView(document: file.$document)
        }
    }
}

/// Used by the automated screenshot tests on iPhone and iPad: a plain window with a ready-made program, no
/// document browser. (On the Mac the document app itself is used, because a plain window never opens there.)
struct DirectApp: App {
    var body: some Scene {
        WindowGroup { DirectRoot() }
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
        #if os(macOS)
        SihemaApp.main()
        #else
        if UITestSupport.isDirect {
            DirectApp.main()
        } else {
            SihemaApp.main()
        }
        #endif
    }
}
