import Foundation

/// Meshes/Bin/<name>.mesh（v28）。只取 LOD0：位置 16 字节（xyz + RGBA 颜色）、
/// 法线 4 字节 int8、UV 8 个 half、索引 u32。对应 src/core/resources.ts 的 readResourceMesh。
struct MeshResource {
    struct LOD {
        let vertexCount: Int
        let positions: [Float]      // vc * 3
        let normals: [Float]        // vc * 3
        let colors: [Float]         // vc * 4
        let indices: [UInt32]
        let bounds: [Float]
        let lodDistance: Float
    }

    let name: String
    let animated: Bool
    let lod: LOD

    init(_ data: [UInt8]) throws {
        var reader = ByteReader(data, label: "Mesh")
        guard try reader.u32() == 28 else { throw FormatError.invalid("未经核实的资源 Mesh 版本") }
        let rawName = Array(try reader.take(64))
        name = String(decoding: rawName.prefix { $0 != 0 }, as: UTF8.self)
        let lodCount = Int(try reader.count(32))
        animated = try reader.u8() != 0
        let extra = try reader.u8()
        let compression = try reader.u32()
        guard compression <= 1, lodCount > 0 else { throw FormatError.invalid("资源 Mesh 头部无效") }

        var lodReader = reader
        if compression != 0 {
            let n = Int(try reader.count(100000000))
            let decodedSize = Int(try reader.count(256000000))
            let raw = try LZ4.decode(Array(try reader.take(n)))
            guard raw.count == decodedSize else { throw FormatError.invalid("资源 Mesh 解压长度不匹配") }
            lodReader = ByteReader(raw, label: "Mesh LOD")
        }

        let lodDistance = try lodReader.f32()
        let bounds = try lodReader.vec6()
        _ = try lodReader.vec6()                       // secondaryBounds
        let vertexCount = Int(try lodReader.count(1000000))
        let indexCount = Int(try lodReader.count(10000000))
        var counts: [Int] = []
        for _ in 0..<5 { counts.append(Int(try lodReader.count(10000000))) }
        var skinCounts: [Int] = []
        for _ in 0..<4 { skinCounts.append(Int(try lodReader.count(1000000))) }
        guard indexCount % 3 == 0 else { throw FormatError.invalid("资源三角形数量无效") }

        let positionBytes = Array(try lodReader.take(vertexCount * 16))
        let normalBytes = Array(try lodReader.take(vertexCount * 4))
        _ = try lodReader.take(vertexCount * 16)       // uv：half × 8
        if animated { _ = try lodReader.take(vertexCount * 8) }

        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount {
            let value = try lodReader.u32()
            guard Int(value) < vertexCount else { throw FormatError.invalid("资源网格索引越界") }
            indices.append(value)
        }

        var positions = [Float](repeating: 0, count: vertexCount * 3)
        var normals = [Float](repeating: 0, count: vertexCount * 3)
        var colors = [Float](repeating: 0, count: vertexCount * 4)
        for i in 0..<vertexCount {
            for lane in 0..<3 {
                positions[i * 3 + lane] = readFloat(positionBytes, i * 16 + lane * 4)
                let raw = Int8(bitPattern: normalBytes[i * 4 + lane])
                normals[i * 3 + lane] = max(-1, Float(raw) / 127)
            }
            for lane in 0..<4 {
                colors[i * 4 + lane] = Float(positionBytes[i * 16 + 12 + lane]) / 255
            }
        }
        _ = extra
        _ = skinCounts
        lod = LOD(vertexCount: vertexCount, positions: positions, normals: normals,
                  colors: colors, indices: indices, bounds: bounds, lodDistance: lodDistance)
    }

    private func readFloat(_ bytes: [UInt8], _ at: Int) -> Float {
        let bits = UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
        return Float(bitPattern: bits)
    }
}

/// LevelMesh 实例的合并几何：顶点 stride 20（位置 float3 + 法线 int8×4 + 颜色 u8×4），
/// 位置已经在 CPU 侧乘过各自的 transform。
struct ModelGeometry {
    let vertices: [UInt8]
    let vertexCount: Int
    let indices: [UInt32]
    let modelCount: Int
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
}
