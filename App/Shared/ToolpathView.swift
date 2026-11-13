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
                            showRapids: showRapids, showReference: showReference)
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
                    .overlay(alignment: .bottomLeading) { legend }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            ForEach(Self.presets) { preset in
                Button(preset.name) { look(preset.yaw, preset.pitch) }
                    .accessibilityLabel("\(preset.name) view")
            }
            Divider().frame(height: 16)
            Toggle("Rapids", isOn: $showRapids)
            Toggle("Axes", isOn: $showReference)
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 8)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            legendRow(Color(red: 0.96, green: 0.82, blue: 0.86), "Cutting")
            if showRapids { legendRow(Color(red: 0.45, green: 0.72, blue: 0.93), "Rapid") }
            if showReference {
                Text("X  Y  Z from the low corner of the cut")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
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
