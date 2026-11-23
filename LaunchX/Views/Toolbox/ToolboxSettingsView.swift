import SwiftUI

/// 百宝箱设置页(设置窗口新增 tab)
/// 四模块侧边导航 + 底部导出/导入区;整体嵌在设置窗 700×520 TabView 内
struct ToolboxSettingsView: View {
    @StateObject private var viewModel = ToolboxViewModel()
    @State private var selection: ToolboxItemKind = .toolLink
    @State private var showingExportSheet = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(ToolboxItemKind.allCases, id: \.self) { kind in
                    NavigationLink(value: kind) {
                        Label {
                            HStack {
                                Text(kind.displayName)
                                Spacer()
                                Text("\(count(for: kind))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: kind.systemImage)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 150, max: 180)
        } detail: {
            detail
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showingExportSheet) {
            ToolboxExportSheet(export: { includeLicenses in
                ToolboxTransferService.shared.exportToolbox(includeLicenses: includeLicenses)
            })
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .toolLink:
            ToolboxToolsSectionView(viewModel: viewModel)
        case .brewPackage:
            ToolboxBrewSectionView(viewModel: viewModel)
        case .configSnapshot:
            ToolboxSnapshotSectionView(viewModel: viewModel)
        case .license:
            ToolboxLicenseSectionView(viewModel: viewModel)
        }
    }

    /// 底部导出/导入栏
    private var bottomBar: some View {
        HStack {
            Text("百宝箱数据可导出为文件,在新 Mac 上导入即可恢复环境")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("导入…") {
                ToolboxTransferService.shared.importToolbox()
            }
            Button("导出…") {
                showingExportSheet = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func count(for kind: ToolboxItemKind) -> Int {
        viewModel.items.filter { $0.kind == kind }.count
    }
}

/// 导出选项弹层(激活码是否包含)
struct ToolboxExportSheet: View {
    let export: (_ includeLicenses: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includeLicenses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出百宝箱")
                .font(.headline)
            Text("将当前工具收藏、brew 应用、配置快照导出为单个 .launchx-toolbox 文件。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle(isOn: $includeLicenses) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("包含激活码")
                    Text("默认不包含。勾选后激活码将以明文写入文件,请妥善保管。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导出…") {
                    dismiss()
                    export(includeLicenses)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
