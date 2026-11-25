import Foundation

enum FormatError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// 小端游标读取器，越界与数量上限都在这里拒绝，对应 src/core/binary.ts。
struct ByteReader {
    let data: [UInt8]
    var p: Int = 0
    let label: String

    init(_ data: [UInt8], label: String = "binary") {
        self.data = data
        self.label = label
    }

    @inline(__always)
    func check(_ n: Int) throws {
        guard n >= 0, p >= 0, p + n <= data.count, p + n >= p else {
            throw FormatError.invalid("\(label): 数据越界 @0x\(String(p, radix: 16)), size=\(n)")
        }
    }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        try check(n)
        let slice = data[p..<p + n]
        p += n
        return slice
    }

    mutating func u8() throws -> UInt8 {
        try check(1)
        defer { p += 1 }
        return data[p]
    }

    mutating func u16() throws -> UInt16 {
        let s = try take(2)
        let i = s.startIndex
        return UInt16(s[i]) | (UInt16(s[i + 1]) << 8)
    }

    mutating func u32() throws -> UInt32 {
        let s = try take(4)
        let i = s.startIndex
        return UInt32(s[i]) | (UInt32(s[i + 1]) << 8) | (UInt32(s[i + 2]) << 16) | (UInt32(s[i + 3]) << 24)
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    mutating func vec3() throws -> [Float] { [try f32(), try f32(), try f32()] }

    mutating func vec6() throws -> [Float] { [try f32(), try f32(), try f32(), try f32(), try f32(), try f32()] }

    mutating func cstr() throws -> String {
        guard let end = data[p...].firstIndex(of: 0) else {
            throw FormatError.invalid("\(label): 未终止字符串 @0x\(String(p, radix: 16))")
        }
        let text = String(decoding: data[p..<end], as: UTF8.self)
        p = end + 1
        return text
    }

    mutating func string() throws -> String {
        let n = Int(try count(1024 * 1024))
        return String(decoding: try take(n), as: UTF8.self)
    }

    mutating func count(_ maximum: Int = 2_000_000) throws -> UInt32 {
        let n = try u32()
        guard Int(n) <= maximum else {
            throw FormatError.invalid("\(label): 数量超限 \(n)")
        }
        return n
    }

    mutating func u16Values(_ n: Int) throws -> [UInt16] {
        var out = [UInt16](); out.reserveCapacity(n)
        for _ in 0..<n { out.append(try u16()) }
        return out
    }

    mutating func i32Values(_ n: Int) throws -> [Int32] {
        var out = [Int32](); out.reserveCapacity(n)
        for _ in 0..<n { out.append(try i32()) }
        return out
    }
}
