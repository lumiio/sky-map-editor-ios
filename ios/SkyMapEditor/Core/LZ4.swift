import Foundation

/// 裸 LZ4 块（不是 LZ4 frame）。TOC 只记录压缩后长度，解压长度靠流本身推进。
enum LZ4 {
    static func decode(_ source: [UInt8], limit: Int = 256 * 1024 * 1024) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(max(256, source.count * 4))
        var ip = 0

        func length(_ base: Int) throws -> Int {
            var n = base
            if n == 15 {
                while true {
                    guard ip < source.count else { throw FormatError.invalid("LZ4 长度截断") }
                    let x = Int(source[ip]); ip += 1
                    n += x
                    if x != 255 { break }
                }
            }
            return n
        }

        while ip < source.count {
            let token = Int(source[ip]); ip += 1
            let literal = try length(token >> 4)
            guard ip + literal <= source.count else { throw FormatError.invalid("LZ4 字面量截断") }
            guard out.count + literal <= limit else { throw FormatError.invalid("LZ4 解压大小超限") }
            out.append(contentsOf: source[ip..<ip + literal])
            ip += literal
            if ip == source.count { break }
            guard ip + 2 <= source.count else { throw FormatError.invalid("LZ4 偏移截断") }
            let offset = Int(source[ip]) | (Int(source[ip + 1]) << 8)
            ip += 2
            guard offset > 0, offset <= out.count else { throw FormatError.invalid("LZ4 无效匹配偏移") }
            let match = try length(token & 15) + 4
            guard out.count + match <= limit else { throw FormatError.invalid("LZ4 解压大小超限") }
            var cursor = out.count - offset
            for _ in 0..<match {
                out.append(out[cursor])
                cursor += 1
            }
        }
        return out
    }

    /// 只写字面量的合法块；解码结果与输入逐字节一致。
    static func encode(_ source: [UInt8]) -> [UInt8] {
        let n = source.count
        var out: [UInt8] = [UInt8(min(n, 15) << 4)]
        if n >= 15 {
            var extra = n - 15
            while extra >= 255 { out.append(255); extra -= 255 }
            out.append(UInt8(extra))
        }
        out.append(contentsOf: source)
        return out
    }
}
