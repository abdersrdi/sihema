import SwiftUI

@main
struct SihemaApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: GCodeDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
