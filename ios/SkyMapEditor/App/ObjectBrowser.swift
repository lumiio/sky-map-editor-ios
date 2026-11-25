import SwiftUI

/// 对象树：按类分组，点进去看字段并就地编辑。数据直接来自 TGCL 解析结果；
/// 改动进 ObjectsWriter 的补丁表，点“保存”才写回文件。
struct ObjectBrowser: View {
    let scene: LevelScene
    let onSave: ([UInt8]) -> Void

    @State private var query = ""
    @State private var writer: ObjectsWriter?
    @State private var dirty = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    init(scene: LevelScene, onSave: @escaping ([UInt8]) -> Void) {
        self.scene = scene
        self.onSave = onSave
        _writer = State(initialValue: scene.document.map { ObjectsWriter($0.source) })
    }

    private var nodes: [TGCLNode] {
        guard let document = scene.document else { return [] }
        let all = document.nodes
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return all.filter { $0.className.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
    }

    private struct ClassGroup: Identifiable {
        let id: String
        let nodes: [TGCLNode]
    }

    private var groups: [ClassGroup] {
        Dictionary(grouping: nodes, by: \.className)
            .map { ClassGroup(id: $0.key, nodes: $0.value) }
            .sorted { $0.nodes.count == $1.nodes.count ? $0.id < $1.id : $0.nodes.count > $1.nodes.count }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    NavigationLink {
                        nodeList(title: group.id, nodes: group.nodes)
                    } label: {
                        HStack {
                            Text(group.id)
                            Spacer()
                            Text("\(group.nodes.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索类名或节点名")
            .navigationTitle("对象 \(scene.objectCount)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(dirty ? "保存*" : "保存") { save() }
                        .disabled(!dirty)
                }
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("知道了", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func save() {
        guard let writer else { return }
        do {
            let bytes = try writer.serialize()
            onSave(bytes)
            dirty = false
            message = "已交给写回：\(bytes.count) 字节"
        } catch {
            message = "序列化失败：\(error)"
        }
    }

    private func nodeList(title: String, nodes: [TGCLNode]) -> some View {
        List(nodes) { node in
            NavigationLink {
                FieldList(node: node, writer: writer) { dirty = true }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.body)
                    Text("id \(node.id)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
    }
}

private struct FieldList: View {
    let node: TGCLNode
    let writer: ObjectsWriter?
    let onDirty: () -> Void

    @State private var editing: TGCLField?

    var body: some View {
        List(node.fields, id: \.offset) { field in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(field.name).font(.subheadline)
                    Spacer()
                    Text(field.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
                if !field.value.displayValue.isEmpty {
                    Text(field.value.displayValue).font(.caption).textSelection(.enabled)
                }
                if !field.children.isEmpty {
                    Text("\(field.children.count) 项").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if writer != nil, FieldCodec.editable(field.kind) { editing = field }
            }
        }
        .navigationTitle(node.name)
        .sheet(item: $editing) { field in
            FieldEditor(field: field, writer: writer) { onDirty() }
        }
    }
}

private struct FieldEditor: View {
    let field: TGCLField
    let writer: ObjectsWriter?
    let onSaved: () -> Void

    @State private var text = ""
    @State private var asFloat = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("\(field.name)（\(field.kind.rawValue)）") {
                    TextField("值", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if field.kind == .bits32 {
                    Toggle("按 float32 解释", isOn: $asFloat)
                }
                if field.kind == .vector || field.kind == .matrix4 {
                    Text("用逗号分隔 \(field.length / 4) 个浮点数").font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("编辑字段")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用") { apply() }
                }
            }
            .onAppear {
                if text.isEmpty { text = field.value.displayValue }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply() {
        guard let writer else { return }
        do {
            let bytes = try FieldCodec.bytes(for: field, text: text, asFloat: asFloat)
            try writer.set(field, bytes: bytes)
            onSaved()
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
