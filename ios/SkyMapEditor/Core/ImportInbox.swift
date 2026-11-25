import Foundation

/// App 沙盒里待导入的包。因为 Info.plist 开了「文件共享」，
/// 用户在「文件」App 的 我的 iPhone → SkyMapEditor 里就能把 ipa/zip 拷进来，
/// 不用经过系统选择器。
struct ImportCandidate: Identifiable {
    let url: URL
    let name: String
    let bytes: Int
    var id: String { url.path }
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum ImportInbox {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func scan() -> [ImportCandidate] {
        let fm = FileManager.default
        let allowed = ["zip", "apk", "ipa", "7z", "rar"]
        guard let entries = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else {
            return []
        }
        var out: [ImportCandidate] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDirectory else { continue }
            let ext = entry.pathExtension.lowercased()
            guard allowed.contains(ext) else { continue }
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            out.append(ImportCandidate(url: entry, name: entry.lastPathComponent, bytes: size))
        }
        return out.sorted { $0.name < $1.name }
    }
}
