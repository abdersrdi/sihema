import SwiftUI
import MetalKit
import SihemaCore

/// 3D toolpath with orbit (drag) and zoom (pinch or trackpad magnify).
struct ToolpathView: View {
    let analysis: Analysis?

    @State private var yaw: Float = -0.6
    @State private var pitch: Float = 0.6
    @State private var zoom: Float = 1
    @State private var baseYaw: Float = -0.6
    @State private var basePitch: Float = 0.6
    @State private var baseZoom: Float = 1
    @State private var showRapids = true
    @State private var showReference = true
    // playback: 0...1 along the length of the path; 1 with nothing playing shows the whole path
    @State private var progress = 1.0
    @State private var playing = false
    @State private var speed = 1.0
    @State private var segmentEnds: [Double] = []

    private var playbackActive: Bool { playing || progress < 1 }

    private func look(_ newYaw: Float, _ newPitch: Float) {
        yaw = newYaw; baseYaw = newYaw
        pitch = newPitch; basePitch = newPitch
        zoom = 1; baseZoom = 1
    }

    var body: some View {
        Group {
            if MTLCreateSystemDefaultDevice() == nil {
                Text("Metal is not available on this device.")
                    .foregroundStyle(.secondary)
            } else if analysis == nil {
                ProgressView()
            } else if analysis?.toolpath.segments.isEmpty == true {
                Text("No moves in this program.")
                    .foregroundStyle(.secondary)
            } else {
                MetalCanvas(analysis: analysis, yaw: yaw, pitch: pitch, zoom: zoom,
                            showRapids: showRapids, showReference: showReference,
                            playback: playbackActive, progress: Float(progress))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                yaw = baseYaw - Float(value.translation.width) * 0.01
                                pitch = min(1.5, max(-1.5, basePitch + Float(value.translation.height) * 0.01))
                            }
                            .onEnded { _ in
                                baseYaw = yaw
                                basePitch = pitch
                            }
                    )
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                zoom = min(50, max(0.1, baseZoom * Float(value.magnification)))
                            }
                            .onEnded { _ in baseZoom = zoom }
                    )
                    .onTapGesture(count: 2) { look(-0.6, 0.6) }
                    .overlay(alignment: .top) { controls }
                    .overlay(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            legend
                            playbackBar
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: analysis?.id) {
            playing = false
            progress = UITestSupport.playbackProgress ?? 1
            var total = 0.0
            segmentEnds = (analysis?.toolpath.segments ?? []).map { segment in
                total += segment.length
                return total
            }
        }
        .task(id: playing) {
            // one full run takes about 20 seconds at 1x
            while playing && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                progress = min(1, progress + 0.033 * speed / 20)
                if progress >= 1 { playing = false }
            }
        }
    }

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Button {
                if !playing && progress >= 1 { progress = 0 }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .accessibilityLabel(playing ? "Pause" : "Play")
            Slider(value: $progress, in: 0...1) { editing in
                if editing { playing = false }
            }
            .accessibilityLabel("Position along the path")
            Button("\(speedLabel)x") {
                let steps = [0.5, 1.0, 2.0, 5.0, 10.0]
                let next = (steps.firstIndex(of: speed) ?? 1) + 1
                speed = steps[next % steps.count]
            }
            .accessibilityLabel("Playback speed")
            .frame(minWidth: 34)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 8).padding(.bottom, 8)
        .environment(\.colorScheme, .dark)
    }

    private var speedLabel: String {
        speed == speed.rounded() ? String(Int(speed)) : String(speed)
    }

    /// The line, kind of move and feed at the playback position.
    private var readout: String {
        guard let segments = analysis?.toolpath.segments, !segmentEnds.isEmpty,
              let total = segmentEnds.last, total > 0, segments.count == segmentEnds.count else { return "" }
        let target = progress * total
        var low = 0, high = segmentEnds.count - 1
        while low < high {
            let mid = (low + high) / 2
            if segmentEnds[mid] >= target { high = mid } else { low = mid + 1 }
        }
        let segment = segments[low]
        var text = "Line \(Int(segment.line) + 1)  \(segment.kind == .rapid ? "Rapid" : "Feed")"
        if segment.feed > 0 { text += "  F\(Int(segment.feed.rounded()))" }
        if segment.tool > 0 { text += "  T\(segment.tool)" }
        return text
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.presets) { preset in
                    Button(preset.name) { look(preset.yaw, preset.pitch) }
                        .accessibilityLabel("\(preset.name) view")
                }
                Divider().frame(height: 16)
                switchButton("Rapids", $showRapids)
                switchButton("Axes", $showReference)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())

            if playbackActive {
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.top, 8)
        .environment(\.colorScheme, .dark) // the canvas is dark, so the overlays are too
    }

    /// A button that is visibly on or off: a check mark and the accent colour when on.
    private func switchButton(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(isOn.wrappedValue ? "\u{2713} \(title)" : title)
        }
        .tint(isOn.wrappedValue ? Color.accentColor : Color.gray)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "on" : "off")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            legendRow(Color(red: 0.96, green: 0.82, blue: 0.86), "Cutting")
            if showRapids { legendRow(Color(red: 0.45, green: 0.72, blue: 0.93), "Rapid") }
            if showReference {
                HStack(spacing: 6) {
                    Text("X").foregroundColor(Color(red: 0.95, green: 0.3, blue: 0.3))
                    Text("Y").foregroundColor(Color(red: 0.4, green: 0.85, blue: 0.4))
                    Text("Z").foregroundColor(Color(red: 1, green: 0.75, blue: 0.2))
                    Text("from the low corner of the cut").foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
        .font(.caption)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    private func legendRow(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(name)
        }
    }

    private struct Preset: Identifiable {
        let name: String
        let yaw: Float
        let pitch: Float
        var id: String { name }
    }

    private static let presets: [Preset] = [
        Preset(name: "Iso", yaw: -0.6, pitch: 0.6),
        Preset(name: "Top", yaw: 0, pitch: 1.5),
        Preset(name: "Front", yaw: 0, pitch: 0),
        Preset(name: "Right", yaw: Float.pi / 2, pitch: 0)
    ]
}

/// The Metal view that draws the toolpath. It only reloads vertices when the analysis changes.
struct MetalCanvas {
    let analysis: Analysis?
    let yaw: Float
    let pitch: Float
    let zoom: Float
    var showRapids = true
    var showReference = true
    var playback = false
    var progress: Float = 1

    final class Coordinator {
        var renderer: ToolpathRenderer?
        var loadedID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    fileprivate func configure(_ view: MTKView, _ coordinator: Coordinator) {
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.07, green: 0.03, blue: 0.05, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        coordinator.renderer = ToolpathRenderer(view: view)
        view.delegate = coordinator.renderer
    }

    fileprivate func refresh(_ view: MTKView, _ coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        if coordinator.loadedID != analysis?.id {
            renderer.load(analysis?.toolpath)
            coordinator.loadedID = analysis?.id
        }
        renderer.yaw = yaw
        renderer.pitch = pitch
        renderer.zoom = zoom
        renderer.showRapids = showRapids
        renderer.showReference = showReference
        renderer.playback = playback
        renderer.progress = progress
    }
}

#if os(macOS)
extension MetalCanvas: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        refresh(view, context.coordinator)
        view.needsDisplay = true
    }
}
#else
extension MetalCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, context.coordinator)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        refresh(view, context.coordinator)
        view.setNeedsDisplay()
    }
}
#endif
