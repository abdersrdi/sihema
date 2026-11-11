import SwiftUI
import UniformTypeIdentifiers

/// A G-code program. Phase 0 keeps it as plain text; encoding detection and very large file handling come later.
struct GCodeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .data] }
    static var writableContentTypes: [UTType] { [.plainText] }

    static let starterText = "%\nO0001 (NEW PROGRAM)\nG21 G90 G17\nG00 X0 Y0 Z5\nG01 Z-1 F200\nG01 X40 F400\nG03 X40 Y20 I0 J10\nG01 X0\nG00 Z5\nM30\n%\n"

    var text: String

    init(text: String = GCodeDocument.starterText) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
