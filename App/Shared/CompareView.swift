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
        /// A removed line and the added line that replaces it, shown on one row.
        var paired = false
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button("Choose file") { importing = true }
                    if let otherName {
                        Text(otherName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }
                if otherText != nil {
                    HStack(spacing: 12) {
                        Toggle("Changes only", isOn: $changesOnly).toggleStyle(.switch).fixedSize()
                        Spacer()
                        Text(changeCount == 0 ? "No differences" : (changeCount == 1 ? "1 change" : "\(changeCount) changes"))
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                    }
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
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1)
                        side(number: row.newNumber, text: row.newText, tint: (row.kind == .added || row.paired) ? .green : nil)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
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
                func make(_ row: DiffRow, id: Int) -> Row {
                    let oldText = row.oldLine.flatMap { $0 < old.count ? old[$0] : nil } ?? ""
                    let newText = row.newLine.flatMap { $0 < new.count ? new[$0] : nil } ?? ""
                    return Row(id: id, kind: row.kind,
                               oldNumber: row.oldLine.map { $0 + 1 }, newNumber: row.newLine.map { $0 + 1 },
                               oldText: oldText, newText: newText)
                }
                // a run of removed lines straight followed by a run of added lines is an edit: line them up
                var index = 0
                while index < diff.count {
                    if diff[index].kind == .removed {
                        var removedEnd = index
                        while removedEnd < diff.count && diff[removedEnd].kind == .removed { removedEnd += 1 }
                        var addedEnd = removedEnd
                        while addedEnd < diff.count && diff[addedEnd].kind == .added { addedEnd += 1 }
                        let removedCount = removedEnd - index
                        let addedCount = addedEnd - removedEnd
                        let pairs = min(removedCount, addedCount)
                        for k in 0..<removedCount {
                            var row = make(diff[index + k], id: built.count)
                            if k < pairs {
                                let added = make(diff[removedEnd + k], id: 0)
                                row = Row(id: row.id, kind: .removed, oldNumber: row.oldNumber, newNumber: added.newNumber,
                                          oldText: row.oldText, newText: added.newText, paired: true)
                            }
                            built.append(row)
                        }
                        for k in pairs..<addedCount {
                            built.append(make(diff[removedEnd + k], id: built.count))
                        }
                        index = addedEnd
                    } else {
                        built.append(make(diff[index], id: built.count))
                        index += 1
                    }
                }
                return built
            }.value
            rows = result
            busy = false
        }
    }
}
