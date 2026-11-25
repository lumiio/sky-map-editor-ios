import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var showImporter = false

    var body: some View {
        ZStack {
            if let scene = model.scene {
                ViewportView(model: model, scene: scene)
                    .ignoresSafeArea()
                VStack {
                    HStack(spacing: 10) {
                        Button {
                            model.close()
                        } label: {
                            Image(systemName: "chevron.left").font(.headline)
                                .padding(10).background(.ultraThinMaterial, in: Circle())
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scene.name).font(.headline)
                            Text("\(scene.triangleCount) 三角形 · \(scene.objectCount) 对象")
                                .font(.caption2).opacity(0.8)
                        }
                        Spacer()
                    }
                    Spacer()
                    Text(model.status)
                        .font(.caption2)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(12)
            } else {
                levelList
            }

            if model.loading || model.importing {
                ProgressView(model.status).padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): model.importFolder(url)
            case .failure(let error): model.error = "\(error)"
            }
        }
        .alert("出错了", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var levelList: some View {
        NavigationStack {
            Group {
                if model.levels.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up.slash").font(.system(size: 44)).opacity(0.5)
                        Text("还没有导入地图").font(.headline)
                        Text("在「文件」App 里准备好 Sky 的\nData/Levels 目录，然后点下面的按钮选择它。\n只会复制 Levels，不会碰 Audio。")
                            .font(.callout).multilineTextAlignment(.center).opacity(0.7)
                        Button("导入 Data / Levels") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    List(model.levels) { level in
                        Button {
                            model.open(level)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(level.name).font(.body)
                                    Text("Objects \(level.objectBytes / 1024) KB · Meshes \(level.meshBytes / 1024) KB")
                                        .font(.caption2).opacity(0.6)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).opacity(0.4)
                            }
                        }
                    }
                    .refreshable { model.refresh() }
                }
            }
            .navigationTitle("Sky 地图编辑器")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(model.status).font(.caption2).opacity(0.6).padding(6)
            }
        }
    }
}
