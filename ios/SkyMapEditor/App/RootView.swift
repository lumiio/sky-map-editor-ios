import SwiftUI
import UIKit
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder, .item]) { result in
            switch result {
            case .success(let url): model.importSource(url)
            case .failure(let error): model.actionError = "选择文件失败：\(error.localizedDescription)"
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
        .sheet(isPresented: $model.showLog) {
            NavigationStack {
                ScrollView {
                    Text(model.logText).font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle("日志")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("复制") { UIPasteboard.general.string = model.logText }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { model.showLog = false }
                    }
                }
            }
        }
        .alert("出错了", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("知道了", role: .cancel) { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private var levelList: some View {
        NavigationStack {
            Group {
                if model.levels.isEmpty {
                    emptyState
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.readLog()
                        model.showLog = true
                    } label: { Image(systemName: "doc.text.magnifyingglass") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(model.status).font(.caption2).opacity(0.6).padding(6)
            }
        }
        .onAppear { model.refreshInbox() }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox").font(.system(size: 42)).opacity(0.5)
                Text("还没有地图").font(.headline)
                Text("把 ipa / zip / apk 拷到「文件」App → 我的 iPhone → SkyMapEditor，\n回到这里点下面的「刷新文件列表」，然后点文件就能导入。\n也可以直接点「从文件里选」选它。")
                    .font(.callout).multilineTextAlignment(.center).opacity(0.75)

                if !model.inbox.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("App 里的包（\(model.inbox.count)）").font(.caption).opacity(0.6)
                        ForEach(model.inbox) { item in
                            Button {
                                model.importInboxFile(item)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "shippingbox.fill")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.footnote).lineLimit(2)
                                        Text(item.sizeText).font(.caption2).opacity(0.6)
                                    }
                                    Spacer()
                                    Image(systemName: "square.and.arrow.down")
                                }
                            }
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                VStack(spacing: 10) {
                    Button("刷新文件列表") { model.refreshInbox() }
                        .buttonStyle(.bordered)
                    Button("从「文件」里选 ipa / zip / apk") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 40)
        }
    }
}
