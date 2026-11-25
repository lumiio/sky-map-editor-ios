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
    let models: ModelGeometry?
    let document: TGCLDocument?
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

    /// 把用户选的文件夹里的 Levels 和 Meshes 复制进沙盒。Audio 之类的大目录不碰。
    static func importData(from url: URL, progress: (String) -> Void) throws {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var root = url
        if url.lastPathComponent == "Levels" { root = url.deletingLastPathComponent() }
        if !fm.fileExists(atPath: root.appendingPathComponent("Levels", isDirectory: true).path) {
            if fm.fileExists(atPath: url.appendingPathComponent("Objects.level.bin").path) {
                root = url.deletingLastPathComponent().deletingLastPathComponent()
            }
        }
        guard fm.fileExists(atPath: root.appendingPathComponent("Levels").path) else {
            throw FormatError.invalid("选中的文件夹里没有 Levels")
        }

        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        for folder in ["Levels", "Meshes"] {
            let source = root.appendingPathComponent(folder, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = dataRoot.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])
            var copied = 0
            for child in children {
                let destination = target.appendingPathComponent(child.lastPathComponent)
                if fm.fileExists(atPath: destination.path) { continue }
                try fm.copyItem(at: child, to: destination)
                copied += 1
                if copied % 5 == 0 { progress("已复制 \(folder)：\(copied)/\(children.count)") }
            }
            progress("\(folder) 完成：新增 \(copied) 项")
        }
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
        let models = demoCubes()
        Log.line("演示模型 \(models.modelCount) 个 / 顶点 \(models.vertexCount)")
        return LevelScene(name: "演示地形", draws: [draw],
                          boundsMin: SIMD3<Float>(-extent, -9, -extent),
                          boundsMax: SIMD3<Float>(extent, 9, extent),
                          objectCount: 0, classCounts: [], bakeCount: 0, models: models, document: nil)
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

    /// 写回 Objects.level.bin：先备份到 .sky-editor-backups，再原子替换，最后重解析校验。
    static func saveObjects(_ bytes: [UInt8], level: String) throws {
        let fm = FileManager.default
        let directory = levelDirectory(level)
        let target = directory.appendingPathComponent("Objects.level.bin")
        let backupDirectory = directory.appendingPathComponent(".sky-editor-backups", isDirectory: true)
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = backupDirectory.appendingPathComponent("Objects.level.bin.\(stamp)")
        try fm.copyItem(at: target, to: backup)
        try Data(bytes).write(to: target, options: .atomic)
        _ = try TGCLDocument([UInt8](try Data(contentsOf: target)))
        Log.line("写回 \(level)：\(bytes.count) 字节，备份 \(backup.lastPathComponent)")
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

        let models = try? loadModels(objects)
        if let models {
            boundsMin = simd_min(boundsMin, models.boundsMin)
            boundsMax = simd_max(boundsMax, models.boundsMax)
        }
        return LevelScene(name: name, draws: draws, boundsMin: boundsMin, boundsMax: boundsMax,
                          objectCount: objects.nodes.count, classCounts: objects.nodeCounts(),
                          bakeCount: meshes.bakes.count, models: models, document: objects)
    }

    /// LevelMesh 实例 → 一份合并几何。位置在 CPU 侧乘过各自的 transform，
    /// 渲染时一条 draw 就够；材质颜色暂时用白色 × 顶点色，和编辑器 basic 视口一致。
    static func loadModels(_ objects: TGCLDocument) throws -> ModelGeometry? {
        let meshesRoot = dataRoot.appendingPathComponent("Meshes", isDirectory: true)
            .appendingPathComponent("Bin", isDirectory: true)
        guard FileManager.default.fileExists(atPath: meshesRoot.path) else { return nil }

        var cache: [String: MeshResource] = [:]
        var vertices: [UInt8] = []
        var indices: [UInt32] = []
        var base: UInt32 = 0
        var models = 0
        var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let vertexLimit = 4_000_000

        func loadMesh(_ name: String) -> MeshResource? {
            if let hit = cache[name] { return hit }
            var candidates = ["\(name).mesh"]
            for suffix in ["_StripAnim", "_CompOcc", "_CompEdges"] {
                candidates.append("\(name)\(suffix).mesh")
            }
            for candidate in candidates {
                let url = meshesRoot.appendingPathComponent(candidate)
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let mesh = try? MeshResource([UInt8](data)) else { continue }
                cache[name] = mesh
                return mesh
            }
            return nil
        }

        for node in objects.nodes where node.className == "LevelMesh" {
            if let enabled = node.field("enabled")?.value, case .byte(let flag) = enabled, flag == 0 { continue }
            guard let nameField = node.field("resourceName"), case .text(let resource) = nameField.value,
                  !resource.isEmpty else { continue }
            guard let transform = node.field("transform"), case .floats(let matrix) = transform.value,
                  matrix.count == 16 else { continue }
            guard let mesh = loadMesh(resource) else { continue }
            let lod = mesh.lod
            if vertices.count / 20 + lod.vertexCount > vertexLimit { break }

            for i in 0..<lod.vertexCount {
                let p = SIMD3<Float>(lod.positions[i * 3], lod.positions[i * 3 + 1], lod.positions[i * 3 + 2])
                let n = SIMD3<Float>(lod.normals[i * 3], lod.normals[i * 3 + 1], lod.normals[i * 3 + 2])
                let world = transformPoint(matrix, p)
                let normal = transformNormal(matrix, n)
                appendFloat(&vertices, world.x); appendFloat(&vertices, world.y); appendFloat(&vertices, world.z)
                vertices.append(UInt8(bitPattern: Int8(clamping: Int(normal.x * 127))))
                vertices.append(UInt8(bitPattern: Int8(clamping: Int(normal.y * 127))))
                vertices.append(UInt8(bitPattern: Int8(clamping: Int(normal.z * 127))))
                vertices.append(0)
                for lane in 0..<4 {
                    vertices.append(UInt8(clamping: Int(lod.colors[i * 4 + lane] * 255)))
                }
                boundsMin = simd_min(boundsMin, world)
                boundsMax = simd_max(boundsMax, world)
            }
            for index in lod.indices { indices.append(index + base) }
            base += UInt32(lod.vertexCount)
            models += 1
        }
        guard models > 0 else { return nil }
        Log.line("LevelMesh 合并 \(models) 个 / 顶点 \(vertices.count / 20) / 索引 \(indices.count)")
        return ModelGeometry(vertices: vertices, vertexCount: vertices.count / 20, indices: indices,
                             modelCount: models, boundsMin: boundsMin, boundsMax: boundsMax)
    }

    /// 演示用方块：和三万多个 LevelMesh 顶点走同一条模型管线。
    private static func demoCubes() -> ModelGeometry {
        var vertices: [UInt8] = []
        var indices: [UInt32] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)),
            (SIMD3(-1,0,0), SIMD3(0,1,0), SIMD3(0,0,-1)),
            (SIMD3(0,1,0), SIMD3(0,0,1), SIMD3(1,0,0)),
            (SIMD3(0,-1,0), SIMD3(0,0,1), SIMD3(-1,0,0)),
            (SIMD3(0,0,1), SIMD3(1,0,0), SIMD3(0,1,0)),
            (SIMD3(0,0,-1), SIMD3(1,0,0), SIMD3(0,-1,0))
        ]
        let placements: [(SIMD3<Float>, Float)] = [(SIMD3(0, 2, 0), 2.4), (SIMD3(9, 1.4, -6), 1.6), (SIMD3(-8, 3, 7), 2.0)]
        var base: UInt32 = 0
        for (center, size) in placements {
            for (normal, tangent, bitangent) in faces {
                for corner in [(-1, -1), (1, -1), (1, 1), (-1, 1)] {
                    let p = center + (normal + tangent * Float(corner.0) + bitangent * Float(corner.1)) * (size * 0.5)
                    appendFloat(&vertices, p.x); appendFloat(&vertices, p.y); appendFloat(&vertices, p.z)
                    vertices.append(UInt8(bitPattern: Int8(clamping: Int(normal.x * 127))))
                    vertices.append(UInt8(bitPattern: Int8(clamping: Int(normal.y * 127))))
                    vertices.append(UInt8(bitPattern: Int8(clamping: Int(normal.z * 127))))
                    vertices.append(0)
                    vertices.append(230); vertices.append(210); vertices.append(180); vertices.append(255)
                }
                indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
                base += 4
            }
        }
        return ModelGeometry(vertices: vertices, vertexCount: vertices.count / 20, indices: indices,
                             modelCount: placements.count,
                             boundsMin: SIMD3<Float>(-11, -1, -9), boundsMax: SIMD3<Float>(11, 5, 9))
    }

    private static func appendFloat(_ out: inout [UInt8], _ value: Float) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
    }

    private static func transformPoint(_ m: [Float], _ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
                     m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
                     m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
    }

    private static func transformNormal(_ m: [Float], _ n: SIMD3<Float>) -> SIMD3<Float> {
        let world = SIMD3<Float>(m[0] * n.x + m[4] * n.y + m[8] * n.z,
                                 m[1] * n.x + m[5] * n.y + m[9] * n.z,
                                 m[2] * n.x + m[6] * n.y + m[10] * n.z)
        let length = simd_length(world)
        return length > 0.00001 ? world / length : SIMD3<Float>(0, 1, 0)
    }

    private static func bounds(_ vertices: MeshSurfaces.MaterialVertices, stride: Int, fallback: [Float]) -> (SIMD3<Float>, SIMD3<Float>) {
        _ = vertices
        guard fallback.count == 6 else { return (.zero, .zero) }
        return (SIMD3(fallback[0], fallback[1], fallback[2]), SIMD3(fallback[3], fallback[4], fallback[5]))
    }
}
