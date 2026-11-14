import SwiftUI
import SihemaCore

/// The cutter radii behind G41/G42 and the units a program is read in. A radius comes from the program itself
/// (G10), from what the user types here, or from a guess at the tool comment, and each row says which.
struct ToolsView: View {
    let analysis: Analysis?
    @ObservedObject var settings: ToolSettings

    private var uses: [CompensationUse] {
        (analysis?.toolpath.compensationUse.values.sorted { $0.register < $1.register }) ?? []
    }

    var body: some View {
        List {
            Section {
                Toggle("Programs without G20 or G21 are in inches", isOn: $settings.defaultInches)
                Picker("Type sizes in", selection: $settings.entryInches) {
                    Text("Millimetres").tag(false)
                    Text("Inches").tag(true)
                }
            } header: {
                Text("Units")
            } footer: {
                Text("A program that says G20 or G21 always wins. This only decides programs that say neither.")
            }

            Section {
                if analysis == nil {
                    ProgressView()
                } else if uses.isEmpty {
                    Label("This program does not use cutter radius compensation (G41 or G42).",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(uses, id: \.register) { use in
                    ToolRow(use: use, settings: settings)
                }
            } header: {
                Text("Cutter radius compensation")
            } footer: {
                Text("Enter the cutter diameter for each offset register, the way the offset table of the machine holds it. A value you enter is used for every program on this device.")
            }
        }
    }
}

private struct ToolRow: View {
    let use: CompensationUse
    @ObservedObject var settings: ToolSettings
    @State private var text = ""
    @FocusState private var focused: Bool

    private var unit: String { settings.entryInches ? "in" : "mm" }

    /// Diameter in the units the user types in.
    private func shown(_ radiusMM: Double) -> String {
        let diameter = radiusMM * 2 / (settings.entryInches ? 25.4 : 1)
        return String(format: settings.entryInches ? "%.4f" : "%.3f", diameter)
    }

    private var sourceText: String {
        switch use.source {
        case .program: return "Set by the program (G10)"
        case .table: return "From your entry"
        case .comment(let line): return "Guessed from the tool comment on line \(line + 1)"
        case .missing: return "Unknown: compensation is skipped"
        }
    }

    private var sourceColor: Color {
        switch use.source {
        case .missing: return .orange
        case .comment: return .secondary
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("D\(use.register)").font(.headline)
                if use.tool > 0 { Text("T\(use.tool)").foregroundStyle(.secondary) }
                Spacer()
                Text("Line \(use.line + 1)").font(.caption).foregroundStyle(.secondary)
            }
            Text(sourceText).font(.caption).foregroundStyle(sourceColor)
            HStack {
                Text("Diameter (\(unit))")
                Spacer()
                TextField("unknown", text: $text)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .focused($focused)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
                if settings.radii[use.register] != nil {
                    Button("Automatic") {
                        settings.setRadius(use.register, radiusMM: nil)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear(perform: refresh)
        .onChange(of: use.radius) { _, _ in
            if !focused { refresh() }
        }
        .onChange(of: settings.entryInches) { _, _ in refresh() }
    }

    private func refresh() {
        text = use.radius.map(shown) ?? ""
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0, value.isFinite else {
            refresh()
            return
        }
        let diameterMM = value * (settings.entryInches ? 25.4 : 1)
        settings.setRadius(use.register, radiusMM: diameterMM / 2)
    }
}
