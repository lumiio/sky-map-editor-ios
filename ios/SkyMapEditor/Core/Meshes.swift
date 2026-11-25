import Foundation

/// BstBaked.meshes：LVL0 容器。TOC 里只有 LOD0 一段，压缩方式是裸 LZ4。
/// 记录顺序由序列化器决定：烘焙 → 地形（可多条）→ 云 → 裙边 → 遮挡体，必须恰好读完。
/// 对应 src/core/meshes.ts。

enum GeometryKind: String {
    case terrain, skirt, occluder, cloud
}

struct GeometryRecord {
    let id: String
    let kind: GeometryKind
    let vertexCount: Int
    let indexCount: Int
    let stride: Int
    let vertexOffset: Int
    var indices: [UInt32]
    var bounds: [Float] = []
    var linkedId: UInt32 = 0
    var flags: UInt8 = 0
    var recordOffset: Int = 0
    var recordEnd: Int = 0
}

struct BakeRecord {
    let name: String
    let guid: UInt32
    let uniform: Bool
    let vertexCount: Int
    let indexBytes: Int
}

struct LVL0Section {
    let tag: String
    let offset: Int
    let length: Int
}

struct MeshesDocument {
    let source: [UInt8]
    let version: UInt32
    let sections: [LVL0Section]
    let lod: [UInt8]
    var bakes: [BakeRecord] = []
    var geometries: [GeometryRecord] = []
    var hasCloud = false

    var terrain: [GeometryRecord] { geometries.filter { $0.kind == .terrain } }
    var skirts: [GeometryRecord] { geometries.filter { $0.kind == .skirt } }

    init(_ data: [UInt8]) throws {
        source = data
        var reader = ByteReader(data, label: "BstBaked.meshes")
        guard String(decoding: try reader.take(4), as: UTF8.self) == "LVL0" else {
            throw FormatError.invalid("Meshes 不是 LVL0 格式")
        }
        version = try reader.u32()
        guard version == 51 || version == 52 else {
            throw FormatError.invalid("当前核实版本为 51/52，输入 \(version)")
        }
        let count = Int(try reader.u8())
        _ = try reader.take(3)
        guard count <= 10, data.count >= 132 else { throw FormatError.invalid("LVL0 目录无效") }

        var toc: [LVL0Section] = []
        for _ in 0..<count {
            let tag = String(decoding: try reader.take(4), as: UTF8.self)
            let offset = Int(try reader.u32())
            let length = Int(try reader.u32())
            guard offset >= 132, offset + length <= data.count else { throw FormatError.invalid("LVL0 段越界") }
            toc.append(LVL0Section(tag: tag, offset: offset, length: length))
        }
        var tags = Set<String>()
        for section in toc {
            guard tags.insert(section.tag).inserted else { throw FormatError.invalid("LVL0 段重复：\(section.tag)") }
        }
        for a in toc {
            for b in toc where a.tag != b.tag && a.length > 0 && b.length > 0 {
                if a.offset < b.offset + b.length && b.offset < a.offset + a.length {
                    throw FormatError.invalid("LVL0 段重叠")
                }
            }
            if a.length == 0, toc.contains(where: { $0.length > 0 && $0.offset < a.offset && a.offset < $0.offset + $0.length }) {
                throw FormatError.invalid("LVL0 空段位于其他段内部")
            }
        }
        sections = toc

        guard let lodSection = toc.first(where: { $0.tag == "LOD0" }) else { throw FormatError.invalid("找不到 LOD0") }
        let compressed = Array(data[lodSection.offset..<lodSection.offset + lodSection.length])
        let lodBytes = try LZ4.decode(compressed)
        lod = lodBytes
        try parse()
    }

    private mutating func parse() throws {
        var reader = ByteReader(lod, label: "LOD0")

        let meshCount = Int(try reader.count(100000))
        for _ in 0..<meshCount {
            let name = try reader.string()
            let guid = try reader.u32()
            let subCount = Int(try reader.count(10000))
            let uniform = try reader.u8()
            guard uniform <= 1 else { throw FormatError.invalid("烘焙标记无效") }
            var vertexCount = 0
            var indexBytes = 0
            for _ in 0..<subCount {
                let vc = Int(try reader.count())
                let ib = Int(try reader.count(20000000))
                _ = try reader.take(uniform == 1 ? 12 : vc * 12)
                _ = try reader.take(ib)
                vertexCount += vc
                indexBytes += ib
            }
            bakes.append(BakeRecord(name: name, guid: guid, uniform: uniform == 1,
                                    vertexCount: vertexCount, indexBytes: indexBytes))
        }

        Log.line("LOD0 烘焙 \(meshCount) 条，结束 @0x\(String(reader.p, radix: 16))")
        let terrainCount = Int(try reader.count(100000))
        for index in 0..<terrainCount {
            let start = reader.p
            let linkedId = try reader.u32()
            let flags = try reader.u8()
            let bounds = try reader.vec6()
            let vc = Int(try reader.count(65536))
            let ic = Int(try reader.count(10000000))
            guard vc <= 65536, ic <= 10000000, ic % 3 == 0 else {
                throw FormatError.invalid("terrain: 无效几何数量 \(vc)/\(ic)")
            }
            let vertexOffset = reader.p
            _ = try reader.take(vc * 36)
            let collisionBytes = Int(try reader.count(100000000))
            _ = try reader.take(collisionBytes)
            _ = try reader.vec6()          // gridBounds
            _ = try reader.f32()           // cellSize
            _ = try reader.u32(); _ = try reader.u32(); _ = try reader.u32()   // dimensions
            let patchCount = Int(try reader.count(1000000))
            var patchIndices: [UInt32] = []; patchIndices.reserveCapacity(patchCount)
            for _ in 0..<patchCount { patchIndices.append(try reader.u32()) }
            var patchFlags: [UInt32] = []; patchFlags.reserveCapacity(patchCount)
            for _ in 0..<patchCount { patchFlags.append(try reader.u32()) }
            let edgeCounts = Int(try reader.count(1000000))
            let edgePairs = Int(try reader.count(5000000))
            let indexRefs = Int(try reader.count(10000000))

            var record = GeometryRecord(id: "terrain\(index)", kind: .terrain, vertexCount: vc,
                                        indexCount: ic, stride: 36, vertexOffset: vertexOffset,
                                        indices: [], bounds: bounds, linkedId: linkedId,
                                        flags: flags, recordOffset: start, recordEnd: 0)

            if edgePairs > 0 {
                var edges: [(UInt16, UInt16)] = []; edges.reserveCapacity(edgePairs)
                for _ in 0..<edgePairs { edges.append((try reader.u16(), try reader.u16())) }
                var refs: [UInt16] = []; refs.reserveCapacity(indexRefs)
                for _ in 0..<indexRefs { refs.append(try reader.u16()) }
                var counts: [UInt32] = []; counts.reserveCapacity(edgeCounts)
                for _ in 0..<edgeCounts { counts.append(try reader.u32()) }
                guard indexRefs == ic, edgeCounts == patchCount,
                      patchIndices.reduce(0, { $0 + Int($1) }) == indexRefs else {
                    throw FormatError.invalid("地形边表计数不一致")
                }
                var indices = [UInt32](repeating: 0, count: ic)
                var edgeBase = 0
                var at = 0
                for patch in 0..<patchCount {
                    for _ in 0..<Int(patchIndices[patch]) {
                        let enc = Int(refs[at])
                        let edge = edges[edgeBase + (enc >> 1)]
                        let value = (enc & 1) == 0 ? edge.0 : edge.1
                        guard Int(value) < vc else { throw FormatError.invalid("地形边引用无效") }
                        indices[at] = UInt32(value)
                        at += 1
                    }
                    edgeBase += Int(counts[patch])
                }
                record.indices = indices
            } else {
                var indices = [UInt32](); indices.reserveCapacity(ic)
                for _ in 0..<ic {
                    let value = try reader.u16()
                    guard Int(value) < vc else { throw FormatError.invalid("几何索引越界") }
                    indices.append(UInt32(value))
                }
                record.indices = indices
            }
            record.recordEnd = reader.p
            geometries.append(record)
        }

        Log.line("LOD0 地形 \(terrainCount) 条，结束 @0x\(String(reader.p, radix: 16))")
        let present = try reader.u32()
        hasCloud = present != 0
        if present != 0 {
            _ = try reader.i32(); _ = try reader.i32(); _ = try reader.i32()   // origin
            let dx = try reader.i32(), dy = try reader.i32(), dz = try reader.i32()
            guard dx >= 0, dy >= 0, dz >= 0, Int(dx) * Int(dy) * Int(dz) <= 100000000 else {
                throw FormatError.invalid("云网格尺寸无效")
            }
            _ = try reader.take(Int(dx) * Int(dy) * Int(dz))
            let blocks = Int(try reader.count(10000000))
            _ = try reader.take(blocks * 6)
            for _ in 0..<3 {
                let size = Int(try reader.count(100000000))
                _ = try reader.take(size)
            }
            _ = try reader.f32()   // sunOcclusionScale
            _ = try reader.u32(); _ = try reader.u32()
            let vc = Int(try reader.count(65536))
            let ic = Int(try reader.count(10000000))
            _ = try reader.take(vc * 16)
            for _ in 0..<ic {
                let value = try reader.u16()
                guard Int(value) < vc else { throw FormatError.invalid("云代理索引越界") }
            }
        }

        Log.line("LOD0 云 present=\(present)，结束 @0x\(String(reader.p, radix: 16))")
        let skirtCount = Int(try reader.count(100000))
        for index in 0..<skirtCount {
            let start = reader.p
            let vc = Int(try reader.count(65536))
            guard vc <= 65536 else { throw FormatError.invalid("skirt: 顶点数无效") }
            let vertexOffset = reader.p
            _ = try reader.take(vc * 40)
            let ic = Int(try reader.count(10000000))
            guard ic % 3 == 0 else { throw FormatError.invalid("裙边三角形数量无效") }
            var indices = [UInt32](); indices.reserveCapacity(ic)
            for _ in 0..<ic {
                let value = try reader.u16()
                guard Int(value) < vc else { throw FormatError.invalid("裙边索引越界") }
                indices.append(UInt32(value))
            }
            geometries.append(GeometryRecord(id: "skirt\(index)", kind: .skirt, vertexCount: vc,
                                             indexCount: ic, stride: 40, vertexOffset: vertexOffset,
                                             indices: indices, recordOffset: start, recordEnd: reader.p))
        }

        let occluderCount = Int(try reader.count(100000))
        for _ in 0..<occluderCount {
            let vc = Int(try reader.count(65536))
            let ic = Int(try reader.count(10000000))
            _ = try reader.take(vc * 16)
            for _ in 0..<ic {
                let value = try reader.u16()
                guard Int(value) < vc else { throw FormatError.invalid("遮挡体索引越界") }
            }
        }

        guard reader.p == lod.count else {
            throw FormatError.invalid("LOD0 未解析数据 \(lod.count - reader.p) 字节 @\(reader.p)")
        }
    }

    func vertexBytes(_ geometry: GeometryRecord) -> ArraySlice<UInt8> {
        lod[geometry.vertexOffset..<geometry.vertexOffset + geometry.vertexCount * geometry.stride]
    }
}
