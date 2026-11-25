import Foundation

final class AppModel: ObservableObject {
    @Published var levels: [LevelInfo] = []
    @Published var scene: LevelScene?
    @Published var status: String = "正在扫描地图…"
    @Published var error: String?
    @Published var loading = false
    @Published var importing = false

    init() {
        refresh()
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

    func importFolder(_ url: URL) {
        importing = true
        status = "正在导入 Levels…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try LevelStore.importLevels(from: url) { message in
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

    func close() {
        scene = nil
        refresh()
    }
}
