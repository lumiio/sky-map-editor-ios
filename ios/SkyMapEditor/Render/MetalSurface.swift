import MetalKit
import SwiftUI

final class SurfaceRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1)
        buildPipeline(view: view)
    }

    private func buildPipeline(view: MTKView) {
        guard let library = try? device.makeDefaultLibrary(bundle: .main) else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vsGradient")
        desc.fragmentFunction = library.makeFunction(name: "fsGradient")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

struct MetalSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        guard let renderer = SurfaceRenderer(view: view) else { return view }
        view.delegate = renderer
        objc_setAssociatedObject(view, "renderer", renderer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
