import Foundation

/// 材质分类与绘制批次。对应 src/core/mesh-surfaces.ts：
/// 顶点材质槽遇到 ID 0 或首个 weight >= stopWeight 时停止，只有 weight > minimumWeight 的材质进入掩码；
/// 三角形里序号最小的材质画不透明，其余画叠加层。

enum SurfacePass: String {
    case opaque, decal, skirt
}

struct SurfaceBatch {
    let surface: Int
    let materialIndex: Int
    let materialId: Int
    let pass: SurfacePass
    let start: Int
    let count: Int
}

struct SurfacePlan {
    let indices: [UInt32]
    let batches: [SurfaceBatch]
}

enum MeshSurfaces {
    struct MaterialVertices {
        let vertexCount: Int
        let indices: [UInt32]
        let materialIds: [UInt8]
        let weights: [UInt8]
    }

    static func materialVertices(_ bytes: ArraySlice<UInt8>, stride: Int, vertexCount: Int, indices: [UInt32]) -> MaterialVertices {
        var ids = [UInt8](repeating: 0, count: vertexCount * 4)
        var weights = [UInt8](repeating: 0, count: vertexCount * 4)
        let base = bytes.startIndex
        for vertex in 0..<vertexCount {
            let at = base + vertex * stride
            for slot in 0..<4 {
                ids[vertex * 4 + slot] = bytes[at + 16 + slot]
                weights[vertex * 4 + slot] = bytes[at + 20 + slot]
            }
        }
        return MaterialVertices(vertexCount: vertexCount, indices: indices, materialIds: ids, weights: weights)
    }

    private static func lookup(_ defs: [MaterialDef], _ vertices: MaterialVertices) throws -> [Int] {
        guard !defs.isEmpty, defs.count <= 32 else { throw FormatError.invalid("原版材质定义无效") }
        var table = [Int](repeating: -1, count: 256)
        for def in defs { table[def.materialId] = def.index }
        return table
    }

    private static func triangleMasks(_ vertices: MaterialVertices, _ defs: [MaterialDef]) throws -> [UInt32] {
        let table = try lookup(defs, vertices)
        var masks = [UInt32](repeating: 0, count: vertices.vertexCount)
        for vertex in 0..<vertices.vertexCount {
            var mask: UInt32 = 0
            for slot in 0..<4 {
                let at = vertex * 4 + slot
                let id = Int(vertices.materialIds[at])
                if id == 0 { break }
                let index = table[id]
                guard index >= 0 else { throw FormatError.invalid("顶点 \(vertex) 的材质 \(id) 没有原版定义") }
                let def = defs[index]
                let weight = Int(vertices.weights[at])
                if weight > def.minimumWeight { mask |= UInt32(1) << UInt32(index) }
                if weight >= def.stopWeight { break }
            }
            masks[vertex] = mask
        }
        let triangleCount = vertices.indices.count / 3
        var triangles = [UInt32](repeating: 0, count: triangleCount)
        for t in 0..<triangleCount {
            let a = Int(vertices.indices[t * 3]), b = Int(vertices.indices[t * 3 + 1]), c = Int(vertices.indices[t * 3 + 2])
            triangles[t] = masks[a] | masks[b] | masks[c]
        }
        return triangles
    }

    static func terrainBatch(_ defs: [MaterialDef], surface: Int, start: Int, count: Int) -> SurfaceBatch {
        let index = surface
        let def = defs[index]
        return SurfaceBatch(surface: surface, materialIndex: index, materialId: def.materialId,
                            pass: .opaque, start: start, count: count)
    }

    static func terrainSurfaces(_ vertices: MaterialVertices, defs: [MaterialDef]) throws -> SurfacePlan {
        let n = defs.count
        let triangles = try triangleMasks(vertices, defs)
        var counts = [Int](repeating: 0, count: n * 2 - 1)
        for t in 0..<triangles.count {
            var mask = triangles[t]
            if mask == 0 { continue }
            var first = true
            while mask != 0 {
                let bit = mask.trailingZeroBitCount
                mask &= mask &- 1
                counts[first ? bit : n + bit - 1] += 3
                first = false
            }
        }
        var cursor = [Int](repeating: 0, count: counts.count)
        var batches: [SurfaceBatch] = []
        var start = 0
        for surface in 0..<counts.count {
            cursor[surface] = start
            if counts[surface] > 0 {
                if surface < n {
                    let def = defs[surface]
                    batches.append(SurfaceBatch(surface: surface, materialIndex: surface, materialId: def.materialId,
                                                pass: .opaque, start: start, count: counts[surface]))
                } else {
                    let index = surface - n + 1
                    let def = defs[index]
                    batches.append(SurfaceBatch(surface: surface, materialIndex: index, materialId: def.materialId,
                                                pass: .decal, start: start, count: counts[surface]))
                }
            }
            start += counts[surface]
        }
        var indices = [UInt32](repeating: 0, count: start)
        for t in 0..<triangles.count {
            var mask = triangles[t]
            var first = true
            while mask != 0 {
                let bit = mask.trailingZeroBitCount
                let surface = first ? bit : n + bit - 1
                let at = cursor[surface]
                indices[at] = vertices.indices[t * 3]
                indices[at + 1] = vertices.indices[t * 3 + 1]
                indices[at + 2] = vertices.indices[t * 3 + 2]
                cursor[surface] += 3
                first = false
                mask &= mask &- 1
            }
        }
        return SurfacePlan(indices: indices, batches: batches)
    }

    static func skirtSurfaces(_ vertices: MaterialVertices, defs: [MaterialDef]) throws -> SurfacePlan {
        let table = try lookup(defs, vertices)
        var present = [Bool](repeating: false, count: defs.count)
        for id in vertices.materialIds where id != 0 {
            let index = table[Int(id)]
            if index >= 0 { present[index] = true }
        }
        var batches: [SurfaceBatch] = []
        if !vertices.indices.isEmpty {
            for index in 0..<present.count where present[index] {
                let def = defs[index]
                batches.append(SurfaceBatch(surface: index, materialIndex: index, materialId: def.materialId,
                                            pass: .skirt, start: 0, count: vertices.indices.count))
            }
        }
        return SurfacePlan(indices: vertices.indices, batches: batches)
    }

    /// 与 Terrain.vert 一致：字节按 UNORM8 进来，再 ivec4(value*256)。
    static func materialAlpha(ids: [UInt8], weights: [UInt8], materialId: Int) -> Float {
        var alpha: Float = 0
        for i in 0..<4 {
            let scaled = Int(Float(Int(ids[i])) / 255.0 * 256.0)
            if scaled == materialId { alpha += Float(Int(weights[i])) / 255.0 }
        }
        return alpha
    }
}
