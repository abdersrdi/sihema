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
    private var vertexCount = 0
    private var center = SIMD3<Float>(repeating: 0)
    private var extent: Float = 1
    private var boundsLow = SIMD3<Float>(repeating: 0)
    private var boundsHigh = SIMD3<Float>(repeating: 0)

    var yaw: Float = -0.6
    var pitch: Float = 0.6
    var zoom: Float = 1

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
            vertexCount = 0
            return
        }
        let low = Self.float3(toolpath.boundsMin)
        let high = Self.float3(toolpath.boundsMax)
        center = (low + high) / 2
        let size = high - low
        extent = max((size * size).sum().squareRoot(), 1)

        let rapidColor = SIMD4<Float>(0.45, 0.72, 0.93, 1)   // glacier blue
        let cutColor = SIMD4<Float>(0.96, 0.82, 0.86, 1)     // pale burgundy tint
        let tolerance = max(0.01, Double(extent) * 2e-4)

        var vertices: [Vertex] = []
        vertices.reserveCapacity(toolpath.segments.count * 2)
        for segment in toolpath.segments {
            let color = segment.kind == .rapid ? rapidColor : cutColor
            segment.forEachLine(tolerance: tolerance) { a, b in
                vertices.append(Vertex(position: Self.float3(a), color: color))
                vertices.append(Vertex(position: Self.float3(b), color: color))
            }
        }
        // centre on the cutting moves (a tall rapid retract would pull the view upwards), then fit every vertex
        var cutLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var cutHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for vertex in vertices where vertex.color == cutColor {
            cutLow = simd_min(cutLow, vertex.position)
            cutHigh = simd_max(cutHigh, vertex.position)
        }
        if cutLow.x <= cutHigh.x { center = (cutLow + cutHigh) / 2 }
        var radius: Float = 0.5
        var allLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var allHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for vertex in vertices {
            radius = max(radius, simd_length(vertex.position - center))
            allLow = simd_min(allLow, vertex.position)
            allHigh = simd_max(allHigh, vertex.position)
        }
        boundsLow = allLow
        boundsHigh = allHigh
        extent = radius * 2
        vertexCount = vertices.count
        buffer = vertices.withUnsafeBytes { raw in
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
        let distance = extent * 1.5 / min(1, max(aspect, 0.3))
        let direction = SIMD3<Float>(cosf(pitch) * sinf(yaw), -cosf(pitch) * cosf(yaw), sinf(pitch))
        let eye = center + direction * distance
        let view = lookAt(eye: eye, center: center, up: SIMD3<Float>(0, 0, 1))
        let projection = perspective(fovy: 0.8, aspect: aspect, near: max(distance * 0.01, 0.01), far: distance * 20)
        let base = projection * view

        // fit: project the corners of the path's bounding box and shift and scale the picture so it is
        // centred and fills the view, whatever the angle; zoom then multiplies on top
        var lowX = Float.greatestFiniteMagnitude, highX = -Float.greatestFiniteMagnitude
        var lowY = Float.greatestFiniteMagnitude, highY = -Float.greatestFiniteMagnitude
        for i in 0..<8 {
            let corner = SIMD4<Float>(i & 1 == 0 ? boundsLow.x : boundsHigh.x,
                                      i & 2 == 0 ? boundsLow.y : boundsHigh.y,
                                      i & 4 == 0 ? boundsLow.z : boundsHigh.z, 1)
            let p = base * corner
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
        if let buffer, vertexCount > 0 {
            var matrix = mvp(aspect: Float(view.drawableSize.width / max(view.drawableSize.height, 1)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertexCount)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
