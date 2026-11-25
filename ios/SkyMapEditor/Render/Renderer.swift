import MetalKit
import simd

/// 地形 / 裙边渲染器。管线组合对应编辑器视口的 basic 材质：
/// 不透明按材质分批，其余按叠加层混合，顺序与 src/core/mesh-surfaces.ts 的批次一致。
final class Renderer: NSObject, MTKViewDelegate {
    static let sampleCount = 4

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var library: MTLLibrary?

    private var terrainOpaque: MTLRenderPipelineState?
    private var terrainBlend: MTLRenderPipelineState?
    private var skirtBlend: MTLRenderPipelineState?
    private var skyPipeline: MTLRenderPipelineState?
    private var modelPipeline: MTLRenderPipelineState?
    private var modelDraw: GPUDraw?
    private var depthWriteState: MTLDepthStencilState?
    private var depthReadState: MTLDepthStencilState?

    var camera = OrbitCamera()
    private var pendingScene: LevelScene?
    private var draws: [GPUDraw] = []
    private(set) var sceneName = ""
    private var loggedFirstFrame = false

    struct FragmentParams {
        var materialId: UInt32 = 0
        var alphaMode: UInt32 = 0
        var padding: SIMD2<UInt32> = .zero
    }

    final class GPUDraw {
        let vertexBuffer: MTLBuffer
        let indexBuffer: MTLBuffer
        let plan: SurfacePlan
        let defs: [MaterialDef]
        let isSkirt: Bool

        init(vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, plan: SurfacePlan, defs: [MaterialDef], isSkirt: Bool) {
            self.vertexBuffer = vertexBuffer
            self.indexBuffer = indexBuffer
            self.plan = plan
            self.defs = defs
            self.isSkirt = isSkirt
        }
    }

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = Renderer.sampleCount
        view.clearColor = MTLClearColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1)
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        buildPipelines(view: view)
        buildDepthStates()
    }

    private func vertexDescriptor(stride: Int) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .char4Normalized
        descriptor.attributes[1].offset = 12
        descriptor.attributes[1].bufferIndex = 0
        descriptor.attributes[2].format = .uchar4Normalized
        descriptor.attributes[2].offset = 16
        descriptor.attributes[2].bufferIndex = 0
        descriptor.attributes[3].format = .uchar4Normalized
        descriptor.attributes[3].offset = 20
        descriptor.attributes[3].bufferIndex = 0
        descriptor.layouts[0].stride = stride
        descriptor.layouts[0].stepFunction = .perVertex
        return descriptor
    }

    private func makeModelPipeline(_ view: MTKView) -> MTLRenderPipelineState? {
        guard let library else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vsModel")
        descriptor.fragmentFunction = library.makeFunction(name: "fsModel")
        let vertices = MTLVertexDescriptor()
        vertices.attributes[0].format = .float3
        vertices.attributes[0].offset = 0
        vertices.attributes[0].bufferIndex = 0
        vertices.attributes[1].format = .char4Normalized
        vertices.attributes[1].offset = 12
        vertices.attributes[1].bufferIndex = 0
        vertices.attributes[2].format = .uchar4Normalized
        vertices.attributes[2].offset = 16
        vertices.attributes[2].bufferIndex = 0
        vertices.layouts[0].stride = 20
        vertices.layouts[0].stepFunction = .perVertex
        descriptor.vertexDescriptor = vertices
        descriptor.rasterSampleCount = view.sampleCount
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func makePipeline(_ view: MTKView, fragment: String, stride: Int, blend: Bool) -> MTLRenderPipelineState? {
        guard let library else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vsTerrain")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.vertexDescriptor = vertexDescriptor(stride: stride)
        descriptor.rasterSampleCount = view.sampleCount
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        if blend {
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func buildPipelines(view: MTKView) {
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            library = nil
            Log.line("默认库不可用: \(error)")
        }
        guard let library else { return }
        let sky = MTLRenderPipelineDescriptor()
        sky.vertexFunction = library.makeFunction(name: "vsSky")
        sky.fragmentFunction = library.makeFunction(name: "fsSky")
        sky.rasterSampleCount = view.sampleCount
        sky.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        sky.colorAttachments[0].pixelFormat = view.colorPixelFormat
        skyPipeline = try? device.makeRenderPipelineState(descriptor: sky)

        terrainOpaque = makePipeline(view, fragment: "fsTerrain", stride: 36, blend: false)
        terrainBlend = makePipeline(view, fragment: "fsTerrain", stride: 36, blend: true)
        skirtBlend = makePipeline(view, fragment: "fsTerrain", stride: 40, blend: true)
        modelPipeline = makeModelPipeline(view)
        Log.line("管线 sky=\(skyPipeline != nil) terrain=\(terrainOpaque != nil) blend=\(terrainBlend != nil) skirt=\(skirtBlend != nil) model=\(modelPipeline != nil)")
    }

    private func buildDepthStates() {
        let write = MTLDepthStencilDescriptor()
        write.depthCompareFunction = .less
        write.isDepthWriteEnabled = true
        depthWriteState = device.makeDepthStencilState(descriptor: write)

        let read = MTLDepthStencilDescriptor()
        read.depthCompareFunction = .lessEqual
        read.isDepthWriteEnabled = false
        depthReadState = device.makeDepthStencilState(descriptor: read)
    }

    func setScene(_ scene: LevelScene) {
        pendingScene = scene
    }

    private func uploadIfNeeded() {
        guard let scene = pendingScene else { return }
        pendingScene = nil
        var built: [GPUDraw] = []
        var frameMin = scene.boundsMin
        var frameMax = scene.boundsMax
        if simd_length(frameMax - frameMin) < 0.001 {
            frameMin = SIMD3<Float>(repeating: -10)
            frameMax = SIMD3<Float>(repeating: 10)
        }
        for draw in scene.draws {
            guard !draw.plan.indices.isEmpty, draw.vertexCount > 0 else { continue }
            guard let vertexBuffer = device.makeBuffer(bytes: draw.vertices, length: draw.vertices.count, options: .storageModeShared),
                  let indexBuffer = device.makeBuffer(bytes: draw.plan.indices,
                                                      length: draw.plan.indices.count * MemoryLayout<UInt32>.stride,
                                                      options: .storageModeShared) else { continue }
            built.append(GPUDraw(vertexBuffer: vertexBuffer, indexBuffer: indexBuffer,
                                 plan: draw.plan, defs: MaterialTables.defs(for: scene.name),
                                 isSkirt: draw.isSkirt))
        }
        draws = built
        if let models = scene.models, !models.indices.isEmpty,
           let vertexBuffer = device.makeBuffer(bytes: models.vertices, length: models.vertices.count, options: .storageModeShared),
           let indexBuffer = device.makeBuffer(bytes: models.indices, length: models.indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared) {
            let plan = SurfacePlan(indices: models.indices, batches: [
                SurfaceBatch(surface: 0, materialIndex: 0, materialId: 0, pass: .opaque, start: 0, count: models.indices.count)
            ])
            modelDraw = GPUDraw(vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, plan: plan,
                                defs: [], isSkirt: false)
            Log.line("模型上传：\(models.modelCount) 个实例 / 顶点 \(models.vertexCount)")
        } else {
            modelDraw = nil
        }
        sceneName = scene.name
        camera.frame(min: frameMin, max: frameMax)
        Log.line("上传 \(scene.name)：\(built.count) 段 / 批次 \(built.reduce(0) { $0 + $1.plan.batches.count }) / 相机 \(camera.distance)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        uploadIfNeeded()
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = view.drawableSize
        let aspect = Float(max(size.width, 1) / max(size.height, 1))
        var viewProj = camera.viewProjection(aspect: aspect)

        if let skyPipeline {
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setDepthStencilState(depthReadState)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encode(draws.filter { !$0.isSkirt }, pass: .opaque, encoder: encoder, viewProj: &viewProj)
        if let modelDraw, let modelPipeline {
            encoder.setRenderPipelineState(modelPipeline)
            encoder.setDepthStencilState(depthWriteState)
            encoder.setVertexBuffer(modelDraw.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewProj, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            var color = SIMD4<Float>(1, 1, 1, 1)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: modelDraw.plan.indices.count, indexType: .uint32,
                                          indexBuffer: modelDraw.indexBuffer, indexBufferOffset: 0)
        }
        encode(draws.filter { !$0.isSkirt }, pass: .decal, encoder: encoder, viewProj: &viewProj)
        encode(draws.filter { $0.isSkirt }, pass: .skirt, encoder: encoder, viewProj: &viewProj)

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        if !loggedFirstFrame {
            loggedFirstFrame = true
            Log.line("首帧完成：vao=\(draws.count) 尺寸=\(Int(size.width))x\(Int(size.height))")
        }
    }

    private enum PassKind { case opaque, decal, skirt }

    private func encode(_ list: [GPUDraw], pass kind: PassKind, encoder: MTLRenderCommandEncoder, viewProj: inout simd_float4x4) {
        guard !list.isEmpty else { return }
        switch kind {
        case .opaque:
            guard let pipeline = terrainOpaque else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthWriteState)
        case .decal:
            guard let pipeline = terrainBlend else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthReadState)
            encoder.setDepthBias(0, slopeScale: 2, clamp: 0)
        case .skirt:
            guard let pipeline = skirtBlend else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthReadState)
        }

        for draw in list {
            encoder.setVertexBuffer(draw.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewProj, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            for batch in draw.plan.batches {
                guard batch.pass == (kind == .skirt ? .skirt : (kind == .decal ? .decal : .opaque)) else { continue }
                var color = SIMD4<Float>(draw.defs[batch.materialIndex].color, 1)
                var params = FragmentParams(materialId: UInt32(batch.materialId),
                                            alphaMode: kind == .opaque ? 0 : 1)
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setFragmentBytes(&params, length: MemoryLayout<FragmentParams>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.count, indexType: .uint32,
                                              indexBuffer: draw.indexBuffer,
                                              indexBufferOffset: batch.start * MemoryLayout<UInt32>.stride)
            }
        }
        if kind == .decal { encoder.setDepthBias(0, slopeScale: 0, clamp: 0) }
    }
}
