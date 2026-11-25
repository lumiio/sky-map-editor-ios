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
