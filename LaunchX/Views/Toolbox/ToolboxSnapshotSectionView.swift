import AppKit
import SwiftUI

/// 百宝箱 - 配置文件快照(收录/刷新/对比/恢复)
struct ToolboxSnapshotSectionView: View {
    @ObservedObject var viewModel: ToolboxViewModel
    /// 各条目的对比结论(条目 id → Conflict)
    @State private var conflicts: [UUID: SnapshotService.Conflict] = [:]
    @State private var isRestoring: Set<UUID> = []
    @State private var isRefreshing: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if viewModel.configSnapshots.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.configSnapshots) { item in
                        row(for: item)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack {
            Text("配置文件快照")
                .font(.headline)
            Spacer()
            Button {
                pickFile()
            } label: {
                Label("收录配置文件", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("还没有收录配置文件")
                .foregroundStyle(.secondary)
            Text("收录 .zshrc、.gitconfig 等常用配置,新机上一键恢复(选文件时按 ⌘⇧. 可显示隐藏文件)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for item: ToolboxItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(.teal)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.sourcePath ?? item.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let meta = item.snapshotMeta {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(meta.byteSize), countStyle: .file))
                        Text(meta.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    conflictLabel(item)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            refreshButton(item)
            restoreButton(item)
            menu(item)
        }
        .padding(.vertical, 2)
        .task(id: item.id) {
            analyzeIfNeeded(item)
        }
    }

    /// 对比结论徽标
    @ViewBuilder
    private func conflictLabel(_ item: ToolboxItem) -> some View {
        switch conflicts[item.id] {
        case .targetMissing:
            Label("目标不存在", systemImage: "tray")
                .foregroundStyle(.blue)
        case .identical:
            Label("一致", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .differs:
            Label("有差异", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .snapshotMissing, .none:
            Label("快照缺失", systemImage: "questionmark.triangle")
                .foregroundStyle(.red)
        }
    }

    /// 从当前源文件刷新快照
    @ViewBuilder
    private func refreshButton(_ item: ToolboxItem) -> some View {
        if isRefreshing.contains(item.id) {
            ProgressView().controlSize(.small)
        } else {
            Button {
                refresh(item)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("从当前源文件刷新快照")
            .disabled(!FileManager.default.fileExists(atPath: item.resolvedSourceURL?.path ?? ""))
        }
    }

    /// 恢复到本机
    @ViewBuilder
    private func restoreButton(_ item: ToolboxItem) -> some View {
        if isRestoring.contains(item.id) {
            ProgressView().controlSize(.small)
        } else {
            Button("恢复") {
                restore(item)
            }
            .controlSize(.small)
            .disabled(conflicts[item.id] == .snapshotMissing)
        }
    }

    private func menu(_ item: ToolboxItem) -> some View {
        Menu {
            Button("删除", role: .destructive) {
                conflicts[item.id] = nil
                try? viewModel.delete(item)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
    }

    // MARK: - 动作

    /// NSOpenPanel 选文件收录(提示 ⌘⇧. 显示隐藏文件)
    private func pickFile() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.title = "收录配置文件"
        openPanel.message = "选择要收录的配置文件(如 ~/.zshrc;按 ⌘⇧. 显示隐藏文件)"
        openPanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        openPanel.begin { result in
            guard result == .OK, let url = openPanel.url else { return }
            Task { @MainActor in
                do {
                    let item = try await SnapshotService.shared.capture(sourceURL: url)
                    viewModel.reload()
                    conflicts[item.id] = SnapshotService.shared.analyze(item: item)
                } catch {
                    ToolboxAlerts.showOnMain(
                        title: "收录失败",
                        message: error.localizedDescription,
                        style: .warning)
                }
            }
        }
    }

    /// 后台分析对比结论(轻量 IO)
    private func analyzeIfNeeded(_ item: ToolboxItem) {
        conflicts[item.id] = SnapshotService.shared.analyze(item: item)
    }

    /// 刷新快照(源文件 → 快照)
    private func refresh(_ item: ToolboxItem) {
        isRefreshing.insert(item.id)
        Task {
            defer { isRefreshing.remove(item.id) }
            do {
                let updated = try await SnapshotService.shared.refresh(item: item)
                viewModel.reload()
                conflicts[updated.id] = SnapshotService.shared.analyze(item: updated)
                ToolboxAlerts.showOnMain(title: "已刷新", message: "「\(item.name)」快照已更新为当前源文件内容。")
            } catch {
                ToolboxAlerts.showOnMain(
                    title: "刷新失败",
                    message: error.localizedDescription,
                    style: .warning)
            }
        }
    }

    /// 恢复:differs 时先确认(覆盖前自动备份 .launchx.bak-*),其余直接执行
    private func restore(_ item: ToolboxItem) {
        let conflict = conflicts[item.id] ?? SnapshotService.shared.analyze(item: item)
        switch conflict {
        case .snapshotMissing:
            ToolboxAlerts.showOnMain(
                title: "快照缺失",
                message: "快照文件丢失,请删除后重新收录。",
                style: .warning)
            return
        case .differs:
            let targetPath = item.resolvedSourceURL?.path ?? item.sourcePath ?? ""
            let confirmed = ToolboxAlerts.confirmOnMain(
                title: "目标文件与快照不同",
                message:
                    "本机的 \(targetPath)\n与快照内容有差异。\n\n覆盖前会把当前文件备份为 *.launchx.bak-<时间戳>。",
                confirmTitle: "覆盖并备份")
            guard confirmed else { return }
        case .identical:
            // 内容一致,restore 会直接跳过并提示
            break
        case .targetMissing:
            break
        }

        isRestoring.insert(item.id)
        Task {
            defer { isRestoring.remove(item.id) }
            do {
                let outcome = try await SnapshotService.shared.restore(item: item)
                conflicts[item.id] = SnapshotService.shared.analyze(item: item)
                switch outcome {
                case .written:
                    ToolboxAlerts.showOnMain(
                        title: "恢复完成",
                        message: "已写入 \(item.resolvedSourceURL?.path ?? item.sourcePath ?? "")。")
                case .backupWritten(let backupPath):
                    ToolboxAlerts.showOnMain(
                        title: "恢复完成",
                        message:
                            "已覆盖 \(item.resolvedSourceURL?.path ?? item.sourcePath ?? "")。\n原文件已备份至:\n\(backupPath)"
                    )
                case .skippedIdentical:
                    ToolboxAlerts.showOnMain(title: "已是最新", message: "目标文件与快照内容一致,未做修改。")
                }
            } catch {
                ToolboxAlerts.showOnMain(
                    title: "恢复失败",
                    message: error.localizedDescription,
                    style: .critical)
            }
        }
    }
}
