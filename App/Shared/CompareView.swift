import SwiftUI
import UniformTypeIdentifiers
import SihemaCore

private func splitLines(_ text: String) -> [String] {
    text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
}

/// Side-by-side comparison of this program with another file. Spacing, case, G1 against G01, 10.0 against 10,
/// comments and N numbers do not count as differences.
struct CompareView: View {
    let baseText: String

    struct Row: Identifiable, Sendable {
        let id: Int
        let kind: DiffKind
        let oldNumber: Int?
        let newNumber: Int?
        let oldText: String
        let newText: String
    }

    @State private var otherName: String?
    @State private var otherText: String?
    @State private var rows: [Row] = []
    @State private var busy = false
    @State private var importing = false
    @State private var changesOnly = true
    @State private var errorMessage: String?

    private var changeCount: Int { rows.filter { $0.kind != .same }.count }
    private var shownRows: [Row] { changesOnly ? rows.filter { $0.kind != .same } : rows }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Choose a program to compare") { importing = true }
                if let otherName {
                    Text(otherName).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if otherText != nil {
                    Toggle("Changes only", isOn: $changesOnly).toggleStyle(.switch).fixedSize()
                    Text(changeCount == 0 ? "No differences" : "\(changeCount) changed lines")
                        .font(.callout.monospacedDigit())
                }
            }
            .padding(12)
            Divider()

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.orange).padding()
            }
            if busy {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if otherText == nil {
                Text("Choose a second program to compare it with the one you have open.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shownRows.isEmpty {
                Text("The two programs do the same thing.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shownRows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        side(number: row.oldNumber, text: row.oldText, tint: row.kind == .removed ? .red : nil)
                        Divider()
                        side(number: row.newNumber, text: row.newText, tint: row.kind == .added ? .green : nil)
                    }
                    .listRowInsets(EdgeInsets())
                }
                .listStyle(.plain)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data],
                      allowsMultipleSelection: false) { result in
            load(result)
        }
        .onChange(of: baseText) { _, _ in recompute() }
        .task {
            // the screenshot tests compare against an edited copy of the sample program
            if UITestSupport.isDirect && otherText == nil {
                otherText = DemoPrograms.compareOther
                otherName = "demo-edited.nc"
                recompute()
            }
        }
    }

    private func side(number: Int?, text: String, tint: Color?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(verbatim: text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .background((tint ?? .clear).opacity(0.18))
    }

    private func load(_ result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "That file could not be read."
                return
            }
            otherText = String(decoding: data, as: UTF8.self)
            otherName = url.lastPathComponent
            recompute()
        }
    }

    private func recompute() {
        guard let other = otherText else { return }
        let base = baseText
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [Row] in
                let old = splitLines(base)
                let new = splitLines(other)
                let diff = ProgramCompare.compare(old: base, new: other)
                var built: [Row] = []
                built.reserveCapacity(diff.count)
                for (index, row) in diff.enumerated() {
                    let oldText = row.oldLine.flatMap { $0 < old.count ? old[$0] : nil } ?? ""
                    let newText = row.newLine.flatMap { $0 < new.count ? new[$0] : nil } ?? ""
                    built.append(Row(id: index, kind: row.kind,
                                     oldNumber: row.oldLine.map { $0 + 1 }, newNumber: row.newLine.map { $0 + 1 },
                                     oldText: oldText, newText: newText))
                }
                return built
            }.value
            rows = result
            busy = false
        }
    }
}
