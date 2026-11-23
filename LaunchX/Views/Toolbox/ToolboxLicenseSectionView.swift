import AppKit
import SwiftUI

/// 百宝箱 - 激活码(明文只存 Keychain,模型与导出默认不含明文)
struct ToolboxLicenseSectionView: View {
    @ObservedObject var viewModel: ToolboxViewModel
    @State private var editingItem: ToolboxItem?
    @State private var showingAddSheet = false
    /// 行内展开明文展示的条目
    @State private var revealedIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if viewModel.licenses.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.licenses) { item in
                        row(for: item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            ToolboxLicenseEditor(item: nil, viewModel: viewModel) { newItem in
                try? viewModel.add(newItem)
            }
        }
        .sheet(item: $editingItem) { item in
            ToolboxLicenseEditor(item: item, viewModel: viewModel) { updated in
                try? viewModel.update(updated)
            }
        }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack {
            Text("软件激活码")
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
            Image(systemName: "key")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("还没有记录激活码")
                .foregroundStyle(.secondary)
            Text("激活码保存在 macOS 钥匙串中,加密存储,不会随导出文件明文外泄")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for item: ToolboxItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                if let account = item.account, !account.isEmpty {
                    Text(account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            // 明文展示(按需展开)
            if revealedIDs.contains(item.id), let secret = viewModel.licenseSecret(for: item) {
                Text(secret)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(secret)
            }
            // 复制激活码
            Button {
                copySecret(item)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制激活码")

            // 显示/隐藏明文
            Button {
                toggleReveal(item)
            } label: {
                Image(systemName: revealedIDs.contains(item.id) ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealedIDs.contains(item.id) ? "隐藏" : "显示激活码")

            Menu {
                Button("编辑…") { editingItem = item }
                Divider()
                Button("删除", role: .destructive) {
                    revealedIDs.remove(item.id)
                    // deleteItem 会先清 Keychain 再删清单(见 ToolboxStore.deleteItem)
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

    // MARK: - 动作

    private func copySecret(_ item: ToolboxItem) {
        guard let secret = viewModel.licenseSecret(for: item) else {
            ToolboxAlerts.showOnMain(
                title: "尚未录入激活码",
                message: "「\(item.name)」还没有激活码,点「编辑…」录入。",
                style: .warning)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
    }

    private func toggleReveal(_ item: ToolboxItem) {
        if revealedIDs.contains(item.id) {
            revealedIDs.remove(item.id)
        } else {
            if viewModel.licenseSecret(for: item) == nil {
                ToolboxAlerts.showOnMain(
                    title: "尚未录入激活码",
                    message: "「\(item.name)」还没有激活码,点「编辑…」录入。",
                    style: .warning)
                return
            }
            revealedIDs.insert(item.id)
        }
    }
}

/// 激活码编辑器(新增/编辑共用;明文经 Keychain 存储)
struct ToolboxLicenseEditor: View {
    let item: ToolboxItem?
    let viewModel: ToolboxViewModel
    let onSave: (ToolboxItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var account: String = ""
    @State private var notes: String = ""
    @State private var secret: String = ""
    @State private var showSecret = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item == nil ? "添加激活码" : "编辑激活码")
                .font(.headline)

            HStack {
                Text("软件名称").frame(width: 70, alignment: .leading)
                TextField("如 Parallels Desktop", text: $name)
            }
            HStack {
                Text("账户/邮箱").frame(width: 70, alignment: .leading)
                TextField("可选,激活时使用的账户", text: $account)
            }
            HStack(alignment: .top) {
                Text("备注").frame(width: 70, alignment: .leading)
                TextField("可选", text: $notes, axis: .vertical)
                    .lineLimit(1...2)
            }
            HStack(alignment: .top) {
                Text("激活码").frame(width: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    if showSecret {
                        TextField("激活码/许可证密钥", text: $secret)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("激活码/许可证密钥", text: $secret)
                            .font(.system(.body, design: .monospaced))
                    }
                    Toggle("显示明文", isOn: $showSecret)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Text("激活码保存在 macOS 钥匙串,加密存储;导出文件默认不携带。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: fillFromItem)
    }

    private func fillFromItem() {
        guard let item else { return }
        name = item.name
        account = item.account ?? ""
        notes = item.notes ?? ""
        secret = viewModel.licenseSecret(for: item) ?? ""
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            errorMessage = "软件名称不能为空"
            return
        }
        var updated = item ?? ToolboxItem.license(name: trimmedName)
        updated.name = trimmedName
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.account = trimmedAccount.isEmpty ? nil : trimmedAccount
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        // 激活码:非空则写 Keychain;清空则删除 Keychain 项
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSecret.isEmpty {
            KeychainStore.deleteSecret(for: updated.id)
        } else {
            guard viewModel.saveLicenseSecret(trimmedSecret, for: updated) else {
                errorMessage = "保存到钥匙串失败,请重试"
                return
            }
        }
        onSave(updated)
        dismiss()
    }
}
