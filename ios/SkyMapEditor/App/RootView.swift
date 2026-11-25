import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var showImporter = false
    @State private var showObjects = false

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
                        Button {
                            model.materialTint.toggle()
                        } label: {
                            Image(systemName: model.materialTint ? "paintpalette.fill" : "paintpalette")
                                .font(.headline)
                                .padding(10).background(.ultraThinMaterial, in: Circle())
                        }
                        Button {
                            showObjects = true
                        } label: {
                            Image(systemName: "list.bullet.indent").font(.headline)
                                .padding(10).background(.ultraThinMaterial, in: Circle())
                        }
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes) { result in
            switch result {
            case .success(let url): model.importSource(url)
            case .failure(let error): model.error = "\(error)"
            }
        }
        .sheet(isPresented: $showObjects) {
            if let scene = model.scene {
                ObjectBrowser(scene: scene) { bytes in
                    model.save(level: scene.name, bytes: bytes)
                }
            }
        }
        .sheet(isPresented: $model.showSelfTest) {
            NavigationStack {
                List(model.selfTest, id: \.self) { line in
                    Text(line).font(.footnote).textSelection(.enabled)
                }
                .navigationTitle("解析自检")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { model.showSelfTest = false } } }
            }
        }
        .alert("出错了", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var importTypes: [UTType] {
        var types: [UTType] = [.folder, .zip]
        if let apk = UTType(filenameExtension: "apk") { types.append(apk) }
        return types
    }

    private var levelList: some View {
        NavigationStack {
            Group {
                if model.levels.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up.slash").font(.system(size: 44)).opacity(0.5)
                        Text("还没有导入地图").font(.headline)
                        Text("把 Data 压成 zip（或者直接用编辑器 apk）传进「文件」App，\n点下面按钮选它就行，会自动解出 Levels 和 Meshes，\n不会碰 Audio。也可以选已经解压好的 Data 文件夹。")
                            .font(.callout).multilineTextAlignment(.center).opacity(0.7)
                        Button("导入 zip / apk / 文件夹") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                        Button("先看内置演示地形") { model.openDemo() }
                            .buttonStyle(.bordered)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.runSelfTest() } label: { Image(systemName: "checkmark.shield") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(model.status).font(.caption2).opacity(0.6).padding(6)
            }
        }
    }
}
