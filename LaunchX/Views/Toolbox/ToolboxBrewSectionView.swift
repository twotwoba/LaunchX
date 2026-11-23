import SwiftUI

/// 百宝箱 - Homebrew 包管理(状态展示 + 一键安装 + 一键导入本机已装)
struct ToolboxBrewSectionView: View {
    @ObservedObject var viewModel: ToolboxViewModel
    @ObservedObject private var installService = BrewInstallService.shared
    @State private var showingAddSheet = false
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            brewMissingBanner
            if viewModel.brewPackages.isEmpty {
                emptyState
            } else {
                packageList
            }
            logArea
        }
        .onAppear {
            installService.refreshStates(items: viewModel.brewPackages)
        }
        .sheet(isPresented: $showingAddSheet) {
            ToolboxBrewEditor { newItem in
                try? viewModel.add(newItem)
                installService.refreshStates(items: [newItem])
            }
        }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack {
            Text("Homebrew 应用")
                .font(.headline)
            Spacer()
            if installService.currentItemID != nil || !installService.queueItems.isEmpty {
                // 批量进度
                let done = installService.states.values.filter { $0 == .installed }.count
                Text("安装中 \(installService.queueItems.count + 1) · 已完成 \(done)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.importInstalledBrewPackages()
            } label: {
                if viewModel.isImportingBrew {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("导入本机已装", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(viewModel.isImportingBrew)

            Button {
                showingAddSheet = true
            } label: {
                Label("添加", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 未安装 Homebrew 的引导横幅
    @ViewBuilder
    private var brewMissingBanner: some View {
        if BrewPathResolver.resolve() == nil {
            VStack(alignment: .leading, spacing: 4) {
                Label("未检测到 Homebrew", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("安装 Homebrew 后即可一键安装以下应用(https://brew.sh)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.08))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("还没有记录 brew 应用")
                .foregroundStyle(.secondary)
            Text("点「导入本机已装」一键收录,或手动添加 formula/cask")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var packageList: some View {
        List {
            ForEach(viewModel.brewPackages) { item in
                row(for: item)
            }
        }
        .listStyle(.inset)
    }

    private func row(for item: ToolboxItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(.brown)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(1)
                    if let brewKind = item.brewKind {
                        Text(brewKind.badge)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                if let tap = item.brewTap {
                    Text(tap)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            stateIndicator(for: item)
        }
        .padding(.vertical, 2)
    }

    /// 状态指示 + 安装/取消按钮
    @ViewBuilder
    private func stateIndicator(for item: ToolboxItem) -> some View {
        switch installService.states[item.id] ?? .unknown {
        case .unknown:
            Button {
                installService.refreshStates(items: [item])
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("检查安装状态")

        case .checking:
            ProgressView()
                .controlSize(.small)

        case .notInstalled:
            Button("Install") {
                installService.enqueue(item: item)
            }
            .controlSize(.small)

        case .installing:
            let isCurrent = installService.currentItemID == item.id
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(isCurrent ? "安装中" : "等待中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    installService.cancel(itemID: item.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("取消安装")
            }

        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("已安装")

        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(message)
                Button("重试") {
                    installService.enqueue(item: item)
                }
                .controlSize(.small)
            }
        }
    }

    /// 安装日志(等宽滚动区,自动跟随尾部)
    @ViewBuilder
    private var logArea: some View {
        if BrewPathResolver.resolve() != nil {
            Divider()
            DisclosureGroup(isExpanded: $showLog) {
                ScrollView {
                    ScrollViewReader { proxy in
                        Text(installService.currentLogTail.isEmpty ? "暂无日志" : installService.currentLogTail)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("logText")
                            .onChange(of: installService.currentLogTail) { _, _ in
                                proxy.scrollTo("logText", anchor: .bottom)
                            }
                    }
                }
                .frame(height: 110)
            } label: {
                Text("安装日志")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

/// brew 包手动添加编辑器
struct ToolboxBrewEditor: View {
    let onSave: (ToolboxItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var kind: BrewPackageKind = .formula
    @State private var tap: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加 brew 应用")
                .font(.headline)

            HStack {
                Text("包名").frame(width: 70, alignment: .leading)
                TextField("如 wget / google-chrome", text: $name)
            }
            Picker("类型", selection: $kind) {
                ForEach(BrewPackageKind.allCases, id: \.self) { kind in
                    Text(kind.badge).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Text("Tap(可选)").frame(width: 70, alignment: .leading)
                TextField("如 user/repo", text: $tap)
            }
            if let command = previewCommand {
                Text("将执行:\(command)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Button("添加") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var previewCommand: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let item = ToolboxItem.brewPackage(name: trimmed, kind: kind, tap: trimmedTap)
        return item.brewCommand
    }

    private var trimmedTap: String? {
        let trimmed = tap.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard BrewfileParser.isValidName(trimmed) else {
            errorMessage = "包名只能包含字母、数字、@/./_/+/-"
            return
        }
        if let tapValue = trimmedTap {
            guard BrewfileParser.isValidName(tapValue) else {
                errorMessage = "Tap 名只能包含字母、数字、@/./_/+/-"
                return
            }
        }
        let item = ToolboxItem.brewPackage(name: trimmed, kind: kind, tap: trimmedTap)
        onSave(item)
        dismiss()
    }
}
