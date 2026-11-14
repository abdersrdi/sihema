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

            MotionSection(analysis: analysis, settings: settings)
        }
    }
}

/// How the machine moves, which decides the cycle time, and a way to fit it to a time measured on the machine.
private struct MotionSection: View {
    let analysis: Analysis?
    @ObservedObject var settings: ToolSettings
    @State private var measuredText = ""
    @State private var message: String?
    @State private var fitting = false

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// h:mm:ss, m:ss or plain seconds.
    static func parseDuration(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return seconds > 0 ? seconds : nil
    }

    private func numberRow(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Text(unit).foregroundStyle(.secondary).frame(minWidth: 52, alignment: .leading)
        }
    }

    var body: some View {
        Section {
            numberRow("Rapid rate", $settings.rapidMMPerMin, "mm/min")
            numberRow("Acceleration", $settings.accelerationMMPerS2, "mm/s²")
            numberRow("Tool change", $settings.toolChangeSeconds, "s")
            numberRow("Corner speed step", $settings.cornerStepMMPerS, "mm/s")
            if let analysis {
                HStack {
                    Text("Estimate for this program")
                    Spacer()
                    Text(Self.format(analysis.toolpath.cycleTime(model: settings.motionModel)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Text("Measured on the machine")
                    Spacer()
                    TextField("h:mm:ss", text: $measuredText)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                }
                Button(fitting ? "Fitting..." : "Fit acceleration to the measured time") { fit(analysis) }
                    .disabled(fitting || analysis.toolpath.segments.isEmpty)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Machine motion (cycle time)")
        } footer: {
            Text("The starting values are typical for a small machining centre. A machine's real rapid rate and tool change time are in its manual; acceleration is hard to look up, so run this program once, time it, and let the app fit it.")
        }
    }

    private func fit(_ analysis: Analysis) {
        guard let measured = Self.parseDuration(measuredText) else {
            message = "Enter the measured time as h:mm:ss, m:ss or seconds."
            return
        }
        fitting = true
        message = nil
        let path = analysis.toolpath
        let model = settings.motionModel
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                path.fitAcceleration(toMeasuredSeconds: measured, model: model)
            }.value
            fitting = false
            switch result {
            case .fitted(let value):
                settings.accelerationMMPerS2 = value.rounded()
                message = "Acceleration set to \(Int(value.rounded())) mm/s², so this program now takes \(Self.format(measured))."
            case .tooFast(let shortest):
                message = "The measured time is shorter than this program can run in the model (\(Self.format(shortest))) even with a very high acceleration. Raise the rapid rate or lower the tool change time first."
            case .tooSlow(let longest):
                message = "The measured time is longer than the model gives even with a very low acceleration (\(Self.format(longest))). Slower feeds or pauses on the machine are not in the program, so the time cannot be matched."
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
