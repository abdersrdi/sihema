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
                MetalCanvas(analysis: analysis, yaw: yaw, pitch: pitch, zoom: zoom)
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Metal view that draws the toolpath. It only reloads vertices when the analysis changes.
struct MetalCanvas {
    let analysis: Analysis?
    let yaw: Float
    let pitch: Float
    let zoom: Float

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
