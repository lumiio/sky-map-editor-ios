import Foundation
import simd

struct LevelInfo: Identifiable, Hashable {
    let name: String
    let objectBytes: Int
    let meshBytes: Int
    var id: String { name }
    var totalBytes: Int { objectBytes + meshBytes }
}

/// 一条已装配好、可以直接上传 GPU 的地形或裙边。
struct TerrainDraw {
    let name: String
    let vertices: [UInt8]
    let stride: Int
    let vertexCount: Int
    let plan: SurfacePlan
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let isSkirt: Bool
}

struct LevelScene {
    let name: String
    let draws: [TerrainDraw]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let objectCount: Int
    let classCounts: [(String, Int)]
    let bakeCount: Int
    var triangleCount: Int {
        draws.reduce(0) { $0 + $1.plan.indices.count / 3 }
    }
}

enum LevelStore {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var dataRoot: URL { documents.appendingPathComponent("Data", isDirectory: true) }
    static var levelsRoot: URL { dataRoot.appendingPathComponent("Levels", isDirectory: true) }

    static func levelDirectory(_ name: String) -> URL {
        levelsRoot.appendingPathComponent(name, isDirectory: true)
    }

    static func scan() -> [LevelInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: levelsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [LevelInfo] = []
        for entry in entries {
            let objects = entry.appendingPathComponent("Objects.level.bin")
            let meshes = entry.appendingPathComponent("BstBaked.meshes")
            guard fm.fileExists(atPath: objects.path), fm.fileExists(atPath: meshes.path) else { continue }
            let objectBytes = (try? fm.attributesOfItem(atPath: objects.path))?[.size] as? Int ?? 0
            let meshBytes = (try? fm.attributesOfItem(atPath: meshes.path))?[.size] as? Int ?? 0
            out.append(LevelInfo(name: entry.lastPathComponent, objectBytes: objectBytes, meshBytes: meshBytes))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// 把用户选的文件夹里的 Levels 复制进沙盒。只复制地图目录，不碰 Audio。
    static func importLevels(from url: URL, progress: (String) -> Void) throws {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var source = url
        if !fm.fileExists(atPath: source.appendingPathComponent("Objects.level.bin").path) {
            let nested = source.appendingPathComponent("Levels", isDirectory: true)
            if fm.fileExists(atPath: nested.path) { source = nested }
        }
        let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])
        try fm.createDirectory(at: levelsRoot, withIntermediateDirectories: true)

        var copied = 0
        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let target = levelsRoot.appendingPathComponent(child.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: target.path) { continue }
            try fm.copyItem(at: child, to: target)
            copied += 1
            progress("已导入 \(copied) 张地图：\(child.lastPathComponent)")
        }
        if copied == 0 { progress("没有新的地图目录（可能已经导入过）") }
    }

    /// 不用真实 Data 也能跑通的演示地形：同一套 36 字节顶点、同一套材质分类与绘制批次。
    /// CI 的模拟器自测靠它验证“管线真的画出东西”。
    static func demoScene() -> LevelScene {
        let defs = MaterialTables.defaultDefs
        let cells = 56
        let extent: Float = 34
        let step = extent * 2 / Float(cells)
        var vertices: [UInt8] = []
        vertices.reserveCapacity(cells * cells * 4 * 36)
        var indices: [UInt32] = []
        indices.reserveCapacity(cells * cells * 6)

        func height(_ x: Float, _ z: Float) -> Float {
            sin(x * 0.22) * cos(z * 0.19) * 3.4 + sin(x * 0.07 + z * 0.11) * 4.2
        }

        func normal(_ x: Float, _ z: Float) -> SIMD3<Float> {
            let d: Float = 0.35
            let dx = height(x + d, z) - height(x - d, z)
            let dz = height(x, z + d) - height(x, z - d)
            return simd_normalize(SIMD3<Float>(-dx, 2 * d, -dz))
        }

        func push(_ x: Float, _ z: Float) {
            let y = height(x, z)
            let n = normal(x, z)
            func append(_ value: Float) {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { vertices.append(contentsOf: $0) }
            }
            append(x); append(y); append(z)
            vertices.append(UInt8(bitPattern: Int8(clamping: Int(n.x * 127))))
            vertices.append(UInt8(bitPattern: Int8(clamping: Int(n.y * 127))))
            vertices.append(UInt8(bitPattern: Int8(clamping: Int(n.z * 127))))
            vertices.append(0)
            let stripe = (sin(x * 0.30) + cos(z * 0.26)) > 0.35
            vertices.append(1)                       // 材质 id 1：不透明基础层
            vertices.append(16)                      // 材质 id 16：叠加层
            vertices.append(0)
            vertices.append(0)
            vertices.append(255)
            vertices.append(stripe ? 170 : 0)
            vertices.append(0)
            vertices.append(0)
            for _ in 0..<12 { vertices.append(0) }    // light0..light2
        }

        for z in 0...cells {
            for x in 0...cells {
                push(-extent + Float(x) * step, -extent + Float(z) * step)
            }
        }
        for z in 0..<cells {
            for x in 0..<cells {
                let a = UInt32(z * (cells + 1) + x)
                let b = a + 1
                let c = a + UInt32(cells + 1)
                let d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        let material = MeshSurfaces.MaterialVertices(vertexCount: (cells + 1) * (cells + 1),
                                                     indices: indices,
                                                     materialIds: strideIds(vertices, stride: 36, count: (cells + 1) * (cells + 1)),
                                                     weights: strideWeights(vertices, stride: 36, count: (cells + 1) * (cells + 1)))
        let plan = (try? MeshSurfaces.terrainSurfaces(material, defs: defs))
            ?? SurfacePlan(indices: indices, batches: [])
        Log.line("演示地形批次 \(plan.batches.count) 个 / 索引 \(plan.indices.count)")
        let draw = TerrainDraw(name: "demo", vertices: vertices, stride: 36,
                               vertexCount: (cells + 1) * (cells + 1), plan: plan,
                               boundsMin: SIMD3<Float>(-extent, -9, -extent),
                               boundsMax: SIMD3<Float>(extent, 9, extent), isSkirt: false)
        return LevelScene(name: "演示地形", draws: [draw],
                          boundsMin: SIMD3<Float>(-extent, -9, -extent),
                          boundsMax: SIMD3<Float>(extent, 9, extent),
                          objectCount: 0, classCounts: [], bakeCount: 0)
    }

    private static func strideIds(_ vertices: [UInt8], stride: Int, count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count { for s in 0..<4 { out[i * 4 + s] = vertices[i * stride + 16 + s] } }
        return out
    }

    private static func strideWeights(_ vertices: [UInt8], stride: Int, count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count { for s in 0..<4 { out[i * 4 + s] = vertices[i * stride + 20 + s] } }
        return out
    }

    static func loadDocuments(_ name: String) throws -> (TGCLDocument, MeshesDocument) {
        let directory = levelDirectory(name)
        let objectData = try Data(contentsOf: directory.appendingPathComponent("Objects.level.bin"))
        let meshData = try Data(contentsOf: directory.appendingPathComponent("BstBaked.meshes"))
        let objects = try TGCLDocument([UInt8](objectData))
        let meshes = try MeshesDocument([UInt8](meshData))
        return (objects, meshes)
    }

    static func buildScene(_ name: String) throws -> LevelScene {
        let (objects, meshes) = try loadDocuments(name)
        let defs = MaterialTables.defs(for: name)
        var draws: [TerrainDraw] = []
        var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for geometry in meshes.terrain {
            let bytes = meshes.vertexBytes(geometry)
            let vertices = MeshSurfaces.materialVertices(bytes, stride: geometry.stride,
                                                         vertexCount: geometry.vertexCount,
                                                         indices: geometry.indices)
            let plan = try MeshSurfaces.terrainSurfaces(vertices, defs: defs)
            let (lo, hi) = bounds(vertices, stride: geometry.stride, fallback: geometry.bounds)
            boundsMin = simd_min(boundsMin, lo)
            boundsMax = simd_max(boundsMax, hi)
            draws.append(TerrainDraw(name: geometry.id, vertices: Array(bytes), stride: geometry.stride,
                                     vertexCount: geometry.vertexCount, plan: plan,
                                     boundsMin: lo, boundsMax: hi, isSkirt: false))
        }

        for geometry in meshes.skirts {
            let bytes = meshes.vertexBytes(geometry)
            let vertices = MeshSurfaces.materialVertices(bytes, stride: geometry.stride,
                                                         vertexCount: geometry.vertexCount,
                                                         indices: geometry.indices)
            let plan = try MeshSurfaces.skirtSurfaces(vertices, defs: defs)
            draws.append(TerrainDraw(name: geometry.id, vertices: Array(bytes), stride: geometry.stride,
                                     vertexCount: geometry.vertexCount, plan: plan,
                                     boundsMin: .zero, boundsMax: .zero, isSkirt: true))
        }

        if boundsMin.x > boundsMax.x { boundsMin = .zero; boundsMax = .zero }

        return LevelScene(name: name, draws: draws, boundsMin: boundsMin, boundsMax: boundsMax,
                          objectCount: objects.nodes.count, classCounts: objects.nodeCounts(),
                          bakeCount: meshes.bakes.count)
    }

    private static func bounds(_ vertices: MeshSurfaces.MaterialVertices, stride: Int, fallback: [Float]) -> (SIMD3<Float>, SIMD3<Float>) {
        _ = vertices
        guard fallback.count == 6 else { return (.zero, .zero) }
        return (SIMD3(fallback[0], fallback[1], fallback[2]), SIMD3(fallback[3], fallback[4], fallback[5]))
    }
}
