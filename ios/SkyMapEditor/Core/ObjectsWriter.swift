import Foundation

/// TGCL 补丁写回：只替换被编辑字段的字节，其余原样保留；
/// 字符串长度变化时按偏移重拼并更新头部文件长度。对应 src/core/objects.ts 的 edit/serialize。
struct TGCLPatch {
    let offset: Int
    let length: Int
    let data: [UInt8]
}

final class ObjectsWriter {
    let source: [UInt8]
    private(set) var patches: [String: TGCLPatch] = [:]

    init(_ source: [UInt8]) {
        self.source = source
    }

    var hasChanges: Bool { !patches.isEmpty }

    func set(_ field: TGCLField, bytes: [UInt8]) throws {
        switch field.kind {
        case .string:
            guard !bytes.contains(0) else { throw FormatError.invalid("字符串不能包含 NUL") }
        case .u8, .u16, .bits32, .reference, .bits64, .vector, .matrix4:
            guard bytes.count == field.length else {
                throw FormatError.invalid("字段 \(field.name) 需要 \(field.length) 字节，给了 \(bytes.count)")
            }
        default:
            throw FormatError.invalid("\(field.name)：数组结构暂不支持改变长度")
        }
        if Array(source[field.offset..<field.offset + field.length]) == bytes {
            patches.removeValue(forKey: field.id)
        } else {
            patches[field.id] = TGCLPatch(offset: field.offset, length: field.length, data: bytes)
        }
    }

    func serialize() throws -> [UInt8] {
        guard !patches.isEmpty else { return source }
        let ordered = patches.values.sorted { $0.offset < $1.offset }
        var out: [UInt8] = []
        out.reserveCapacity(source.count + 64)
        var cursor = 0
        for patch in ordered {
            guard patch.offset >= cursor, patch.offset + patch.length <= source.count else {
                throw FormatError.invalid("补丁重叠或越界")
            }
            out.append(contentsOf: source[cursor..<patch.offset])
            out.append(contentsOf: patch.data)
            cursor = patch.offset + patch.length
        }
        out.append(contentsOf: source[cursor...])
        // 头部第 10 个 u32（偏移 40）是文件长度，必须跟着新字节数走
        guard out.count >= 44 else { throw FormatError.invalid("TGCL 输出过短") }
        var length = UInt32(out.count).littleEndian
        withUnsafeBytes(of: &length) { for i in 0..<4 { out[40 + i] = $0[i] } }
        _ = try TGCLDocument(out)
        return out
    }
}

/// 字段值 → 字节
enum FieldCodec {
    static func bytes(for field: TGCLField, text: String, asFloat: Bool) throws -> [UInt8] {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        switch field.kind {
        case .string:
            return Array((text + "\u{0}").utf8)
        case .vector, .matrix4:
            guard parts.count * 4 == field.length else { throw FormatError.invalid("需要 \(field.length / 4) 个数") }
            var out: [UInt8] = []
            for part in parts {
                guard let value = Float(part) else { throw FormatError.invalid("不是数字：\(part)") }
                out.append(contentsOf: floatBytes(value))
            }
            return out
        case .bits32:
            if asFloat {
                guard let value = Float(text) else { throw FormatError.invalid("不是浮点数") }
                return floatBytes(value)
            }
            guard let value = Int64(text) else { throw FormatError.invalid("不是整数") }
            guard value >= 0, value <= UInt32.max else { throw FormatError.invalid("超出 uint32 范围") }
            return [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
        case .u8:
            guard let value = UInt8(text) else { throw FormatError.invalid("不是 0..255") }
            return [value]
        case .u16:
            guard let value = UInt16(text) else { throw FormatError.invalid("不是 0..65535") }
            return [UInt8(value & 0xff), UInt8(value >> 8)]
        case .reference:
            guard let value = UInt32(text) else { throw FormatError.invalid("不是引用编号") }
            return [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
        default:
            throw FormatError.invalid("该字段类型暂不支持编辑")
        }
    }

    static func floatBytes(_ value: Float) -> [UInt8] {
        var bits = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &bits) { Array($0) }
    }

    static func editable(_ kind: FieldKind) -> Bool {
        switch kind {
        case .string, .vector, .matrix4, .bits32, .u8, .u16, .reference: return true
        default: return false
        }
    }
}
