import SwiftUI

/// 百宝箱 - 工具收藏(官网/GitHub 链接)
struct ToolboxToolsSectionView: View {
    @ObservedObject var viewModel: ToolboxViewModel
    @State private var editingItem: ToolboxItem?
    @State private var showingAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if viewModel.toolLinks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.toolLinks) { item in
                        row(for: item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            ToolboxToolLinkEditor(item: nil) { newItem in
                try? viewModel.add(newItem)
            }
        }
        .sheet(item: $editingItem) { item in
            ToolboxToolLinkEditor(item: item) { updated in
                try? viewModel.update(updated)
            }
        }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack {
            Text("常用工具链接")
                .font(.headline)
            Spacer()
            Button {
                showingAddSheet = true
            } label: {
                Label("添加", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("还没有收藏工具")
                .foregroundStyle(.secondary)
            Text("点击右上角「添加」,记录常用工具的官网或 GitHub 链接")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for item: ToolboxItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            // 打开(经 AppOpener;单测红线:严禁真实调用)
            Button {
                viewModel.openLink(item)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("打开链接")

            Menu {
                Button("编辑…") { editingItem = item }
                Divider()
                Button("删除", role: .destructive) {
                    try? viewModel.delete(item)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 2)
    }
}

/// 工具收藏编辑器(新增/编辑共用)
struct ToolboxToolLinkEditor: View {
    let item: ToolboxItem?
    let onSave: (ToolboxItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var notes: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item == nil ? "添加工具" : "编辑工具")
                .font(.headline)

            HStack {
                Text("名称").frame(width: 60, alignment: .leading)
                TextField("如 Raycast", text: $name)
            }
            HStack {
                Text("链接").frame(width: 60, alignment: .leading)
                TextField("官网或 GitHub 链接(可省略 https://)", text: $url)
            }
            HStack(alignment: .top) {
                Text("备注").frame(width: 60, alignment: .leading)
                TextField("可选", text: $notes, axis: .vertical)
                    .lineLimit(2...3)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(item == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                        || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: fillFromItem)
    }

    private func fillFromItem() {
        guard let item else { return }
        name = item.name
        url = item.urlString ?? ""
        notes = item.notes ?? ""
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        // 录入容错校验:补全 scheme 后必须能解析
        let candidate = trimmedURL.contains("://") ? trimmedURL : "https://\(trimmedURL)"
        guard URL(string: candidate) != nil else {
            errorMessage = "链接格式不正确"
            return
        }
        var updated = item ?? ToolboxItem.toolLink(name: trimmedName, url: trimmedURL)
        updated.name = trimmedName
        updated.urlString = trimmedURL
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        onSave(updated)
        dismiss()
    }
}
