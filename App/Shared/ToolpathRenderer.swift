import MetalKit
import simd
import SihemaCore

/// Draws a toolpath as coloured lines with Metal. Phase 0 proof that the toolpath can be shown on both
/// Mac and iPad with one renderer; picking, line links and shading come later.
final class ToolpathRenderer: NSObject, MTKViewDelegate {
    struct Vertex {
        var position: SIMD3<Float>
        var color: SIMD4<Float>
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex {
        float3 position;
        float4 color;
    };

    struct VOut {
        float4 position [[position]];
        float4 color;
    };

    vertex VOut vmain(uint vid [[vertex_id]],
                      const device Vertex* vertices [[buffer(0)]],
                      constant float4x4& mvp [[buffer(1)]]) {
        VOut out;
        Vertex v = vertices[vid];
        out.position = mvp * float4(v.position, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 fmain(VOut in [[stage_in]]) {
        return in.color;
    }
    """

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var buffer: MTLBuffer?
    private var cutCount = 0
    private var rapidCount = 0
    private var referenceBuffer: MTLBuffer?
    private var referenceCount = 0
    private var center = SIMD3<Float>(repeating: 0)
    private var extent: Float = 1
    private var extentCut: Float = 1
    private var fitAll: [SIMD3<Float>] = []
    private var fitCut: [SIMD3<Float>] = []

    var yaw: Float = -0.6
    var pitch: Float = 0.6
    var zoom: Float = 1
    var showRapids = true
    var showReference = true

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "vmain"),
              let fragmentFunction = library.makeFunction(name: "fmain") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        super.init()
    }

    private static func float3(_ v: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
    }

    func load(_ toolpath: Toolpath?) {
        guard let toolpath, !toolpath.segments.isEmpty else {
            buffer = nil
            referenceBuffer = nil
            cutCount = 0
            rapidCount = 0
            referenceCount = 0
            return
        }
        let rapidColor = SIMD4<Float>(0.45, 0.72, 0.93, 1)   // glacier blue
        let cutColor = SIMD4<Float>(0.96, 0.82, 0.86, 1)     // pale burgundy tint
        let low = Self.float3(toolpath.boundsMin)
        let high = Self.float3(toolpath.boundsMax)
        let tolerance = max(0.01, Double((high - low).max()) * 2e-4)

        var cuts: [Vertex] = []
        var rapids: [Vertex] = []
        cuts.reserveCapacity(toolpath.segments.count * 2)
        for segment in toolpath.segments {
            let isRapid = segment.kind == .rapid
            let color = isRapid ? rapidColor : cutColor
            segment.forEachLine(tolerance: tolerance) { a, b in
                let first = Vertex(position: Self.float3(a), color: color)
                let second = Vertex(position: Self.float3(b), color: color)
                if isRapid {
                    rapids.append(first); rapids.append(second)
                } else {
                    cuts.append(first); cuts.append(second)
                }
            }
        }
        let all = cuts + rapids
        if all.isEmpty {
            buffer = nil
            referenceBuffer = nil
            cutCount = 0; rapidCount = 0; referenceCount = 0
            return
        }

        func bounds(_ list: [Vertex]) -> (SIMD3<Float>, SIMD3<Float>) {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in list {
                lo = simd_min(lo, v.position)
                hi = simd_max(hi, v.position)
            }
            return (lo, hi)
        }
        // points used to fit the view: an even sample plus the vertex at each extreme of every axis
        // (a bounding box would over-estimate: its corners are not part of the path)
        func fitPoints(_ list: [Vertex]) -> [SIMD3<Float>] {
            var points: [SIMD3<Float>] = []
            let step = max(1, list.count / 4000)
            for i in Swift.stride(from: 0, to: list.count, by: step) { points.append(list[i].position) }
            for axis in 0..<3 {
                if let lo = list.min(by: { $0.position[axis] < $1.position[axis] }),
                   let hi = list.max(by: { $0.position[axis] < $1.position[axis] }) {
                    points.append(lo.position)
                    points.append(hi.position)
                }
            }
            return points
        }

        // centre on the cutting moves (a tall rapid retract would pull the view upwards), then fit every vertex
        let (cutLow, cutHigh) = cuts.isEmpty ? bounds(all) : bounds(cuts)
        center = (cutLow + cutHigh) / 2
        var radius: Float = 0.5
        for vertex in all { radius = max(radius, simd_length(vertex.position - center)) }
        var radiusCut: Float = 0.5
        for vertex in (cuts.isEmpty ? all : cuts) { radiusCut = max(radiusCut, simd_length(vertex.position - center)) }
        extent = radius * 2
        extentCut = radiusCut * 2
        fitAll = fitPoints(all)
        fitCut = cuts.isEmpty ? fitAll : fitPoints(cuts)

        cutCount = cuts.count
        rapidCount = rapids.count
        buffer = all.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }

        // reference lines: an axis triad at the low corner of the cut, and the cut's bounding box
        var reference: [Vertex] = []
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ color: SIMD4<Float>) {
            reference.append(Vertex(position: a, color: color))
            reference.append(Vertex(position: b, color: color))
        }
        let size = cutHigh - cutLow
        let boxColor = SIMD4<Float>(0.32, 0.32, 0.38, 1)
        let corners: [SIMD3<Float>] = (0..<8).map { i in
            SIMD3<Float>(i & 1 == 0 ? cutLow.x : cutHigh.x,
                         i & 2 == 0 ? cutLow.y : cutHigh.y,
                         i & 4 == 0 ? cutLow.z : cutHigh.z)
        }
        for i in 0..<8 {
            for bit in [1, 2, 4] where i & bit == 0 { line(corners[i], corners[i | bit], boxColor) }
        }
        let arm = max(size.max() * 0.25, 1)
        line(cutLow, cutLow + SIMD3<Float>(arm, 0, 0), SIMD4<Float>(0.95, 0.3, 0.3, 1))   // X
        line(cutLow, cutLow + SIMD3<Float>(0, arm, 0), SIMD4<Float>(0.4, 0.85, 0.4, 1))    // Y
        line(cutLow, cutLow + SIMD3<Float>(0, 0, arm), SIMD4<Float>(1, 0.75, 0.2, 1))      // Z
        referenceCount = reference.count
        referenceBuffer = reference.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }

    // MARK: Camera

    private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    private func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovy / 2)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    private func mvp(aspect: Float) -> simd_float4x4 {
        // a narrow (portrait) view sees less sideways, so back off further to keep the whole path in frame
        let ext = showRapids ? extent : extentCut
        let distance = ext * 1.5 / min(1, max(aspect, 0.3))
        let direction = SIMD3<Float>(cosf(pitch) * sinf(yaw), -cosf(pitch) * cosf(yaw), sinf(pitch))
        let eye = center + direction * distance
        let view = lookAt(eye: eye, center: center, up: SIMD3<Float>(0, 0, 1))
        let projection = perspective(fovy: 0.8, aspect: aspect, near: max(distance * 0.01, 0.01), far: distance * 20)
        let base = projection * view

        // fit: project the corners of the path's bounding box and shift and scale the picture so it is
        // centred and fills the view, whatever the angle; zoom then multiplies on top
        var lowX = Float.greatestFiniteMagnitude, highX = -Float.greatestFiniteMagnitude
        var lowY = Float.greatestFiniteMagnitude, highY = -Float.greatestFiniteMagnitude
        for point in (showRapids ? fitAll : fitCut) {
            let p = base * SIMD4<Float>(point.x, point.y, point.z, 1)
            guard p.w > 0.0001 else { return base }
            lowX = min(lowX, p.x / p.w); highX = max(highX, p.x / p.w)
            lowY = min(lowY, p.y / p.w); highY = max(highY, p.y / p.w)
        }
        let width = max(highX - lowX, 1e-4), height = max(highY - lowY, 1e-4)
        let scale = min(1.8 / width, 1.8 / height) * max(zoom, 0.05)
        let cx = (lowX + highX) / 2, cy = (lowY + highY) / 2
        let fit = simd_float4x4(columns: (
            SIMD4<Float>(scale, 0, 0, 0),
            SIMD4<Float>(0, scale, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-scale * cx, -scale * cy, 0, 1)
        ))
        return fit * base
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let buffer, cutCount + rapidCount > 0 {
            var matrix = mvp(aspect: Float(view.drawableSize.width / max(view.drawableSize.height, 1)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            if showReference, let referenceBuffer, referenceCount > 0 {
                encoder.setVertexBuffer(referenceBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: referenceCount)
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            if rapidCount > 0 && showRapids {
                encoder.drawPrimitives(type: .line, vertexStart: cutCount, vertexCount: rapidCount)
            }
            if cutCount > 0 {
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: cutCount)
            }
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
