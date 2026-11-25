import Foundation

final class AppModel: ObservableObject {
    @Published var levels: [LevelInfo] = []
    @Published var scene: LevelScene?
    @Published var status: String = "正在扫描地图…"
    @Published var error: String?
    @Published var loading = false
    @Published var importing = false
    @Published var selfTest: [String] = []
    @Published var showSelfTest = false
    @Published var materialTint = false

    init() {
        refresh()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--extract"), index + 1 < arguments.count {
            let url = URL(fileURLWithPath: arguments[index + 1])
            do {
                try ZipImporter.extract(url, to: LevelStore.dataRoot) { Log.line("解压：\($0)") }
                Log.line("解压测试通过")
            } catch {
                Log.line("解压测试失败：\(error)")
            }
            refresh()
        }
        if arguments.contains("--demo") {
            scene = LevelStore.demoScene()
            Log.line("演示地形已装载 \(scene?.triangleCount ?? 0) 三角形")
        }
    }

    func refresh() {
        status = "正在扫描地图…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = LevelStore.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.levels = found
                self.status = found.isEmpty ? "还没有导入地图" : "\(found.count) 张地图"
            }
        }
    }

    /// 文件夹和 zip/apk 都走这里。
    func importSource(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            importFolder(url)
        } else {
            importArchive(url)
        }
    }

    func importArchive(_ url: URL) {
        importing = true
        error = nil
        status = "正在解压 \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try ZipImporter.extract(url, to: LevelStore.dataRoot) { message in
                    DispatchQueue.main.async { self?.status = message }
                }
                DispatchQueue.main.async {
                    self?.importing = false
                    self?.status = "导入完成"
                    self?.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.importing = false
                    self?.error = "导入失败：\(error)"
                }
            }
        }
    }

    func importFolder(_ url: URL) {
        importing = true
        status = "正在导入 Levels / Meshes…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try LevelStore.importData(from: url) { message in
                    DispatchQueue.main.async { self?.status = message }
                }
                DispatchQueue.main.async {
                    self?.importing = false
                    self?.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.importing = false
                    self?.error = "导入失败：\(error)"
                }
            }
        }
    }

    func open(_ level: LevelInfo) {
        loading = true
        error = nil
        status = "正在解析 \(level.name)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let scene = try LevelStore.buildScene(level.name)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.scene = scene
                    self.loading = false
                    self.status = "\(scene.name)：\(scene.draws.count) 段地形 / \(scene.triangleCount) 三角形 / \(scene.objectCount) 个对象"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.loading = false
                    self?.error = "\(level.name) 解析失败：\(error)"
                }
            }
        }
    }

    func openDemo() {
        scene = LevelStore.demoScene()
        status = "演示地形：\(scene?.triangleCount ?? 0) 三角形"
    }

    /// 逐张地图跑一遍解析，结果直接列出来。真机验证格式层最快的方式。
    func runSelfTest() {
        let snapshot = levels
        guard !snapshot.isEmpty else { return }
        loading = true
        status = "正在逐张解析 \(snapshot.count) 张地图…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lines: [String] = []
            for level in snapshot {
                do {
                    let scene = try LevelStore.buildScene(level.name)
                    lines.append("✅ \(level.name)：\(scene.objectCount) 对象 / \(scene.triangleCount) 三角形 / \(scene.models?.modelCount ?? 0) 模型")
                } catch {
                    lines.append("❌ \(level.name)：\(error)")
                }
            }
            DispatchQueue.main.async {
                self?.selfTest = lines
                self?.showSelfTest = true
                self?.loading = false
                self?.status = "自检完成：\(lines.filter { $0.hasPrefix("✅") }.count)/\(lines.count) 通过"
            }
        }
    }

    func save(level: String, bytes: [UInt8]) {
        loading = true
        status = "正在写回 \(level)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try LevelStore.saveObjects(bytes, level: level)
                DispatchQueue.main.async {
                    self?.loading = false
                    self?.status = "已写回 \(level)（原文件备份在 .sky-editor-backups）"
                    if let info = self?.levels.first(where: { $0.name == level }) {
                        self?.open(info)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.loading = false
                    self?.error = "写回失败：\(error)"
                }
            }
        }
    }

    func close() {
        scene = nil
        refresh()
    }
}
