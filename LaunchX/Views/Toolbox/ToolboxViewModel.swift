import Combine
import SwiftUI

/// 百宝箱视图模型(模式照 ToolsViewModel:@Published + 委托 Store 持久化)
final class ToolboxViewModel: ObservableObject {
    /// 全部条目
    @Published var items: [ToolboxItem] = []

    /// brew 一键导入进行中
    @Published var isImportingBrew = false

    private let store: ToolboxStore

    init(store: ToolboxStore = .shared) {
        self.store = store
        reload()
    }

    // MARK: - 便捷访问

    var toolLinks: [ToolboxItem] {
        items.filter { $0.kind == .toolLink }
    }

    var brewPackages: [ToolboxItem] {
        items.filter { $0.kind == .brewPackage }
    }

    var configSnapshots: [ToolboxItem] {
        items.filter { $0.kind == .configSnapshot }
    }

    var licenses: [ToolboxItem] {
        items.filter { $0.kind == .license }
    }

    // MARK: - 加载与保存

    /// 重新加载清单(顺带清理孤儿快照目录)
    func reload() {
        store.performOrphanSweep()
        items = store.loadManifest().items
    }

    // MARK: - CRUD

    func add(_ item: ToolboxItem) throws {
        try store.upsert(item)
        reload()
    }

    func update(_ item: ToolboxItem) throws {
        var updated = item
        updated.updatedAt = Date()
        try store.upsert(updated)
        reload()
    }

    func delete(_ item: ToolboxItem) throws {
        try store.deleteItem(item.id)
        reload()
    }

    // MARK: - 工具收藏

    /// 打开链接(必须经 AppOpener,项目规约:禁止直接调 NSWorkspace.shared.open)
    func openLink(_ item: ToolboxItem) {
        guard let url = item.resolvedURL else { return }
        AppOpener.open(url)
    }

    // MARK: - 激活码

    /// 保存激活码明文到 Keychain
    @discardableResult
    func saveLicenseSecret(_ secret: String, for item: ToolboxItem) -> Bool {
        KeychainStore.saveSecret(secret, for: item.id)
    }

    /// 读取激活码明文(仅 UI 展示/复制用)
    func licenseSecret(for item: ToolboxItem) -> String? {
        KeychainStore.secret(for: item.id)
    }

    // MARK: - Homebrew 一键导入

    /// 从本机已装列表导入(去重后确认写入)
    func importInstalledBrewPackages() {
        guard !isImportingBrew else { return }
        isImportingBrew = true
        Task {
            defer { isImportingBrew = false }
            do {
                let result = try await BrewService.shared.importInstalled()
                // 过滤掉已有的(按身份键)
                let existingKeys = Set(brewPackages.compactMap(\.sourceIdentityKey))
                let newItems = result.items.filter { item in
                    guard let key = item.sourceIdentityKey else { return true }
                    return !existingKeys.contains(key)
                }
                if newItems.isEmpty {
                    ToolboxAlerts.showOnMain(
                        title: "没有新增",
                        message:
                            result.skippedMasCount > 0
                            ? "本机已装应用都已在百宝箱中。\n另有 \(result.skippedMasCount) 条 Mac App Store 应用暂不支持收录。"
                            : "本机已装应用都已在百宝箱中。")
                    return
                }
                var masNote = ""
                if result.skippedMasCount > 0 {
                    masNote = "\n另有 \(result.skippedMasCount) 条 Mac App Store 应用暂不支持收录。"
                }
                let confirmed = ToolboxAlerts.confirmOnMain(
                    title: "导入本机已装 brew 应用?",
                    message: "将新增 \(newItems.count) 条(formula/cask)。\(masNote)",
                    confirmTitle: "导入")
                guard confirmed else { return }
                for item in newItems {
                    try add(item)
                }
                ToolboxAlerts.showOnMain(
                    title: "导入完成",
                    message: "已新增 \(newItems.count) 条 brew 应用。")
            } catch {
                ToolboxAlerts.showOnMain(
                    title: "导入失败",
                    message: error.localizedDescription,
                    style: .warning)
            }
        }
    }
}
