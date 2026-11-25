import Foundation

/// Objects.level.bin：TGCL 容器。字段类型只有 0..3，头部 44 字节 = magic + 10 × u32。
/// 逐条对应 src/core/objects.ts 的实现，不引入额外猜测。

enum FieldKind: String {
    case raw, u8, u16, bits32, bits64, vector, matrix4, string, reference, array, structValue
}

enum FieldValue {
    case none
    case byte(UInt8)
    case half(UInt16)
    case word(UInt32)
    case floats([Float])
    case text(String)
    case hex(String)
    case count(Int)
}

struct TGCLField {
    let name: String
    let kind: FieldKind
    let offset: Int
    let length: Int
    let value: FieldValue
    let children: [TGCLField]

    var displayValue: String {
        switch value {
        case .none: return ""
        case .byte(let v): return "\(v)"
        case .half(let v): return "\(v)"
        case .word(let v): return "\(v)"
        case .count(let v): return "\(v) 项"
        case .text(let v): return v
        case .hex(let v): return v.count > 32 ? String(v.prefix(32)) + "…" : v
        case .floats(let v):
            return v.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        }
    }
}

struct TGCLProperty {
    let name: String
    let type: Int
    let size: Int
    let classIndex: UInt32
}

struct TGCLClass {
    let name: String
    let properties: [TGCLProperty]
}

struct TGCLNode {
    let id: Int
    let name: String
    let classIndex: Int
    let className: String
    let fields: [TGCLField]

    func field(_ name: String) -> TGCLField? { fields.first { $0.name == name } }
}

struct TGCLDocument {
    let source: [UInt8]
    let header: [UInt32]
    let classes: [TGCLClass]
    let nodes: [TGCLNode]
    let end: Int

    init(_ data: [UInt8]) throws {
        source = data
        var reader = ByteReader(data, label: "Objects.level.bin")
        guard String(decoding: try reader.take(4), as: UTF8.self) == "TGCL" else {
            throw FormatError.invalid("Objects 不是 TGCL 格式")
        }
        var head: [UInt32] = []
        for _ in 0..<10 { head.append(try reader.u32()) }
        header = head
        let version = head[0]
        let classCount = Int(head[1])
        let propertyCount = Int(head[2])
        let nodeCount = Int(head[3])
        let classOffset = Int(head[5])
        let propertyOffset = Int(head[6])
        let nameOffset = Int(head[7])
        let nodeOffset = Int(head[8])
        let fileLength = Int(head[9])

        guard version == 1, fileLength == data.count,
              classCount <= 10000, propertyCount <= 100000, nodeCount <= 1000000,
              classOffset >= 44, classOffset + classCount * 12 <= propertyOffset,
              propertyOffset + propertyCount * 16 <= nameOffset,
              nameOffset <= nodeOffset, nodeOffset <= fileLength else {
            throw FormatError.invalid("TGCL 头部校验失败")
        }

        func name(at offset: Int) throws -> String {
            guard offset >= 0, nameOffset + offset < nodeOffset else { throw FormatError.invalid("名称池偏移无效") }
            let start = nameOffset + offset
            guard let end = data[start..<nodeOffset].firstIndex(of: 0) else { throw FormatError.invalid("名称池字符串截断") }
            return String(decoding: data[start..<end], as: UTF8.self)
        }

        var properties: [TGCLProperty] = []
        properties.reserveCapacity(propertyCount)
        reader.p = propertyOffset
        for _ in 0..<propertyCount {
            let type = Int(try reader.u32())
            let name = try name(at: Int(try reader.u32()))
            let bytes = Int(try reader.u32())
            let classIndex = try reader.u32()
            guard type <= 3 else { throw FormatError.invalid("未经确认的 TGCL 字段类型 \(type)") }
            properties.append(TGCLProperty(name: name, type: type, size: bytes, classIndex: classIndex))
        }

        var classList: [TGCLClass] = []
        classList.reserveCapacity(classCount)
        reader.p = classOffset
        for _ in 0..<classCount {
            let name = try name(at: Int(try reader.u32()))
            let start = Int(try reader.u32())
            let count = Int(try reader.u32())
            guard start >= 0, count >= 0, start + count <= properties.count else {
                throw FormatError.invalid("类字段范围无效")
            }
            classList.append(TGCLClass(name: name, properties: Array(properties[start..<start + count])))
        }

        var nodeList: [TGCLNode] = []
        nodeList.reserveCapacity(nodeCount)
        reader.p = nodeOffset
        for index in 0..<nodeCount {
            let classIndex = Int(try reader.u32())
            let nodeName = try reader.cstr()
            guard classIndex >= 0, classIndex < classList.count else {
                throw FormatError.invalid("无效类索引 \(classIndex)")
            }
            let fields = try TGCLDocument.readFields(&reader, classes: classList, classIndex: classIndex, depth: 0)
            nodeList.append(TGCLNode(id: index, name: nodeName, classIndex: classIndex,
                                     className: classList[classIndex].name, fields: fields))
        }
        end = reader.p
        guard reader.p == fileLength else {
            throw FormatError.invalid("TGCL 剩余 \(fileLength - reader.p) 字节，拒绝不完整解析")
        }
        classes = classList
        nodes = nodeList
    }

    private static func readFields(_ reader: inout ByteReader, classes: [TGCLClass], classIndex: Int, depth: Int) throws -> [TGCLField] {
        guard depth <= 64, classIndex >= 0, classIndex < classes.count else {
            throw FormatError.invalid("递归类结构无效")
        }
        var out: [TGCLField] = []
        for property in classes[classIndex].properties {
            let offset = reader.p
            var kind = FieldKind.raw
            var value = FieldValue.none
            var children: [TGCLField] = []

            switch property.type {
            case 0:
                let bytes = Array(try reader.take(property.size))
                switch property.size {
                case 1:
                    kind = .u8; value = .byte(bytes[0])
                case 2:
                    kind = .u16; value = .half(UInt16(bytes[0]) | (UInt16(bytes[1]) << 8))
                case 4:
                    kind = .bits32
                    let word = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
                    value = .word(word)
                case 8:
                    kind = .bits64; value = .hex(bytes.map { String(format: "%02x", $0) }.joined())
                case 12, 16, 64:
                    var floats: [Float] = []
                    floats.reserveCapacity(property.size / 4)
                    var finite = true
                    for i in stride(from: 0, to: property.size, by: 4) {
                        let word = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
                        let f = Float(bitPattern: word)
                        if !f.isFinite { finite = false }
                        floats.append(f)
                    }
                    if finite {
                        kind = property.size == 64 ? .matrix4 : .vector
                        value = .floats(floats)
                    } else {
                        value = .hex(bytes.map { String(format: "%02x", $0) }.joined())
                    }
                default:
                    value = .hex(bytes.map { String(format: "%02x", $0) }.joined())
                }
            case 1:
                kind = .string; value = .text(try reader.cstr())
            case 2:
                kind = .reference; value = .word(try reader.u32())
            default:
                kind = .array
                let count = Int(try reader.count())
                value = .count(count)
                children.reserveCapacity(count)
                if property.classIndex == 0xffff_ffff {
                    for index in 0..<count {
                        let at = reader.p
                        let word = try reader.u32()
                        children.append(TGCLField(name: "[\(index)]", kind: .reference, offset: at,
                                                  length: 4, value: .word(word), children: []))
                    }
                } else {
                    let nested = Int(property.classIndex)
                    for index in 0..<count {
                        let at = reader.p
                        let sub = try TGCLDocument.readFields(&reader, classes: classes, classIndex: nested, depth: depth + 1)
                        children.append(TGCLField(name: "[\(index)] \(classes[nested].name)", kind: .structValue,
                                                  offset: at, length: reader.p - at, value: .none, children: sub))
                    }
                }
            }

            out.append(TGCLField(name: property.name, kind: kind, offset: offset,
                                 length: reader.p - offset, value: value, children: children))
        }
        return out
    }

    func nodeCounts() -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for node in nodes { counts[node.className, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    }
}
