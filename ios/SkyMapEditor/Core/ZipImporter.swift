import Compression
import Foundation

/// 直接从 zip / apk 里抽 Levels 和 Meshes。
/// apk 本身就是 zip，所以选 apk 也能用；条目前缀无论是
/// `Data/Levels/...`、`assets/Data/Levels/...` 还是 `Levels/...` 都能认出来。
enum ZipImporter {
    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    private static let maxEntrySize = 512 * 1024 * 1024
    private static let maxTotalSize = 2 * 1024 * 1024 * 1024

    static func extract(_ url: URL, to root: URL, progress: (String) -> Void) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 22 else { throw FormatError.invalid("不是有效的 zip（文件太小）") }

        guard let eocd = findEndOfCentralDirectory(data) else {
            throw FormatError.invalid("不是有效的 zip（找不到目录）")
        }
        var directoryOffset = Int(u32(data, eocd + 16))
        if directoryOffset == 0xFFFF_FFFF || directoryOffset >= data.count {
            // ZIP64：目录位置落在 ZIP64 结束记录里
            if let zip64 = findZip64End(data, before: eocd) {
                directoryOffset = Int(u64(data, zip64 + 48))
            }
        }
        guard directoryOffset > 0, directoryOffset < data.count else {
            throw FormatError.invalid("zip 目录为空或损坏")
        }

        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        var cursor = directoryOffset
        var written = 0
        var totalBytes = 0
        var skipped = 0
        var entries = 0

        // 目录项数量不依赖 EOCD 的 16 位字段：apk 很容易超过 65535 项，
        // 这里一直读到签名不匹配为止。
        while cursor + 46 <= data.count, u32(data, cursor) == 0x0201_4b50, entries < 400_000 {
            entries += 1
            let method = u16(data, cursor + 10)
            var compressedSize = Int(u32(data, cursor + 20))
            var uncompressedSize = Int(u32(data, cursor + 24))
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            var localOffset = Int(u32(data, cursor + 42))
            guard cursor + 46 + nameLength <= data.count else { break }
            let name = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            let next = cursor + 46 + nameLength + extraLength + commentLength

            // Zip64：只处理尺寸/偏移被标记为 0xFFFFFFFF 的情况
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                if let zip64 = readZip64(data, extraStart: cursor + 46 + nameLength, extraLength: extraLength,
                                         needSizes: uncompressedSize == 0xFFFF_FFFF,
                                         needOffset: localOffset == 0xFFFF_FFFF) {
                    compressedSize = zip64.compressed
                    uncompressedSize = zip64.uncompressed
                    localOffset = zip64.offset
                }
            }
            cursor = next

            guard let destination = destination(for: name) else { continue }
            guard !name.hasSuffix("/") else { continue }
            guard uncompressedSize <= maxEntrySize, compressedSize <= maxEntrySize else {
                throw FormatError.invalid("\(name) 超出单个文件大小上限")
            }
            guard totalBytes + uncompressedSize <= maxTotalSize else {
                throw FormatError.invalid("解压总量超过 2GB，请只压缩 Levels 和 Meshes")
            }

            let target = root.appendingPathComponent(destination)
            if manager.fileExists(atPath: target.path) { skipped += 1; continue }

            guard localOffset + 30 <= data.count, u32(data, localOffset) == 0x0403_4b50 else {
                throw FormatError.invalid("\(name) 的本地头损坏")
            }
            let localNameLength = Int(u16(data, localOffset + 26))
            let localExtraLength = Int(u16(data, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= data.count else {
                throw FormatError.invalid("\(name) 数据越界")
            }
            let payload = data.subdata(in: dataStart..<(dataStart + compressedSize))

            let output: Data
            switch method {
            case 0:
                output = payload
            case 8:
                output = try inflate(payload, expected: uncompressedSize, name: name)
            default:
                throw FormatError.invalid("\(name)：不支持的压缩方式 \(method)")
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try output.write(to: target, options: .atomic)
            written += 1
            totalBytes += output.count
            if written % 10 == 0 {
                progress("已解出 \(written) 个文件（\(totalBytes / 1024 / 1024) MB）")
            }
        }

        if written == 0 && skipped == 0 {
            throw FormatError.invalid("压缩包里没有 Levels 或 Meshes")
        }
        progress("解压完成：新增 \(written) 个文件，跳过 \(skipped) 个已存在")
    }

    private static func destination(for name: String) -> String? {
        let parts = name.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(where: { $0 == "Levels" || $0 == "Meshes" }) else { return nil }
        let relative = parts[index...]
        guard !relative.isEmpty else { return nil }
        guard relative.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else { return nil }
        return "Data/" + relative.joined(separator: "/")
    }

    private static func findZip64End(_ data: Data, before eocd: Int) -> Int? {
        var offset = eocd - 20
        let limit = max(0, eocd - 4096)
        while offset >= limit {
            if u32(data, offset) == 0x0606_4b50 { return offset }
            offset -= 1
        }
        return nil
    }

    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        let limit = max(0, data.count - 66_000)
        var offset = data.count - 22
        while offset >= limit {
            if u32(data, offset) == 0x0605_4b50 { return offset }
            offset -= 1
        }
        return nil
    }

    private static func readZip64(_ data: Data, extraStart: Int, extraLength: Int,
                                  needSizes: Bool, needOffset: Bool) -> (compressed: Int, uncompressed: Int, offset: Int)? {
        var cursor = extraStart
        let end = extraStart + extraLength
        while cursor + 4 <= end {
            let id = u16(data, cursor)
            let size = Int(u16(data, cursor + 2))
            if id == 0x0001 {
                var at = cursor + 4
                var uncompressed = 0, compressed = 0, offset = 0
                if needSizes, at + 8 <= end {
                    uncompressed = Int(u64(data, at)); at += 8
                    compressed = Int(u64(data, at)); at += 8
                }
                if needOffset, at + 8 <= end {
                    offset = Int(u64(data, at)); at += 8
                }
                return (compressed, uncompressed, offset)
            }
            cursor += 4 + size
        }
        return nil
    }

    private static func inflate(_ payload: Data, expected: Int, name: String) throws -> Data {
        if expected == 0 { return Data() }
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let dst = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return payload.withUnsafeBytes { source -> Int in
                guard let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, expected, src, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else {
            throw FormatError.invalid("\(name) 解压长度不符（\(written)/\(expected)）")
        }
        return output
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(data, offset)) | (UInt64(u32(data, offset + 4)) << 32)
    }
}
