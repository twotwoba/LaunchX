import AppKit
import Foundation
import UniformTypeIdentifiers

/// 百宝箱导出/导入服务
///
/// 跨机迁移载体:`.launchx-toolbox` 文件(JSON,内嵌快照 base64)。
/// - 激活码明文默认【不】导出(勾选包含时 UI 需警示明文落盘)
/// - 导入时快照只落 toolbox/snapshots 目录,【不】自动回写用户 home,
///   恢复动作由用户在快照模块手动触发(避免导入即覆盖配置文件的危险默认)
/// 面板与反馈照 BackupService 惯例(NSSavePanel/NSOpenPanel + NSAlert)。
final class ToolboxTransferService {
    static let shared = ToolboxTransferService()

    private let store: ToolboxStore
    /// Keychain 实现(默认真实实现;测试注入 InMemoryKeychain,绝不碰真实钥匙串)
    private let keychain: KeychainStoring

    init(store: ToolboxStore = .shared, keychain: KeychainStoring = SecItemKeychainStore()) {
        self.store = store
        self.keychain = keychain
    }

    // MARK: - 文件类型

    /// .launchx-toolbox UTI(Info.plist 已声明 exported;运行时构造兜底)
    static var toolboxUTType: UTType {
        UTType(exportedAs: "com.launchx.toolbox", conformingTo: .json)
    }

    // MARK: - 合并语义(纯函数,单测重点)

    struct MergeReport: Equatable {
        var added = 0  // 新增条目数
        var updated = 0  // 覆盖已有条目数
        var skipped = 0  // 按策略跳过的冲突条目数(内容完全一致的静默跳过,不计数)
        var idMap: [UUID: UUID] = [:]  // 导入条目 id → 最终落盘条目 id
    }

    enum MergePolicy: Equatable {
        case skipExisting  // 已存在的保持现状
        case overwriteExisting  // 已存在的被导入内容覆盖(保留本机 id/createdAt)
    }

    /// 按身份键(sourceIdentityKey)合并;返回报告与 id 映射(快照/激活码回填用)。
    /// 纯函数:只操作传入数组,不触盘。
    static func merge(
        into items: inout [ToolboxItem], incoming: [ToolboxItem], policy: MergePolicy
    ) -> MergeReport {
        var report = MergeReport()
        // 身份键 → 本机条目下标
        var keyIndex: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            if let key = item.sourceIdentityKey, keyIndex[key] == nil {
                keyIndex[key] = index
            }
        }
        // 本机 id → 下标(同 id 视为同一条目,直接更新)
        var idIndex: [UUID: Int] = [:]
        for (index, item) in items.enumerated() {
            idIndex[item.id] = index
        }

        for incomingItem in incoming {
            let existingIndex: Int? = {
                if let key = incomingItem.sourceIdentityKey, let index = keyIndex[key] {
                    return index
                }
                return idIndex[incomingItem.id]
            }()

            if let index = existingIndex {
                report.idMap[incomingItem.id] = items[index].id
                // 内容完全一致 → 静默跳过
                var normalizedIncoming = incomingItem
                normalizedIncoming.id = items[index].id
                normalizedIncoming.createdAt = items[index].createdAt
                normalizedIncoming.updatedAt = items[index].updatedAt
                if normalizedIncoming == items[index] {
                    continue
                }
                switch policy {
                case .skipExisting:
                    report.skipped += 1
                case .overwriteExisting:
                    var replaced = incomingItem
                    // 保留本机身份(id/createdAt),更新时间戳
                    replaced.id = items[index].id
                    replaced.createdAt = items[index].createdAt
                    replaced.updatedAt = Date()
                    items[index] = replaced
                    report.updated += 1
                }
            } else {
                var added = incomingItem
                added.updatedAt = Date()
                items.append(added)
                keyIndex[added.sourceIdentityKey ?? ""] = items.count - 1
                idIndex[added.id] = items.count - 1
                report.idMap[incomingItem.id] = added.id
                report.added += 1
            }
        }
        return report
    }

    // MARK: - 导出

    /// 组装导出文件结构(纯数据,单测覆盖;不触盘)
    static func buildExport(
        items: [ToolboxItem], includesLicenses: Bool, store: ToolboxStore,
        keychain: KeychainStoring, appVersion: String?
    ) -> ToolboxExportFile {
        var snapshots: [SnapshotPayload] = []
        var licenseSecrets: [LicenseSecretPayload] = []

        for item in items {
            switch item.kind {
            case .configSnapshot:
                // 快照内容 base64 内嵌(缺失则跳过并在导入时表现为 snapshotMissing)
                if let data = store.snapshotData(for: item), let meta = item.snapshotMeta {
                    snapshots.append(
                        SnapshotPayload(
                            itemId: item.id,
                            fileName: meta.fileNameOnDisk,
                            contentBase64: data.base64EncodedString()))
                }
            case .license:
                // 仅勾选包含时导出激活码明文(base64 转移)
                if includesLicenses,
                    let secret = keychain.get(
                        service: KeychainStore.service,
                        account: KeychainStore.account(for: item.id)),
                    let secretData = secret.data(using: .utf8)
                {
                    licenseSecrets.append(
                        LicenseSecretPayload(
                            itemId: item.id, secretBase64: secretData.base64EncodedString()))
                }
            default:
                break
            }
        }

        return ToolboxExportFile(
            exportedAt: Date(),
            appVersion: appVersion,
            includesLicenses: includesLicenses,
            items: items,
            snapshots: snapshots.isEmpty ? nil : snapshots,
            licenseSecrets: licenseSecrets.isEmpty ? nil : licenseSecrets)
    }

    /// 导出流程:勾选激活码时先明文警示 → SavePanel → 原子落盘 → 完成提示(含文件大小)
    func exportToolbox(includeLicenses: Bool) {
        // 明文警示(照计划:导出含激活码必须用户知情)
        if includeLicenses {
            let confirmed = ToolboxAlerts.confirmOnMain(
                title: "包含激活码明文?",
                message:
                    "激活码将以【明文】写入导出文件,请妥善保管该文件(不要发给他人/上传网盘公开目录)。",
                confirmTitle: "仍然导出")
            if !confirmed { return }
        }

        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let export = ToolboxTransferService.buildExport(
            items: store.loadManifest().items,
            includesLicenses: includeLicenses,
            store: store,
            keychain: keychain,
            appVersion: appVersion)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [Self.toolboxUTType]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue =
            "LaunchX_Toolbox_\(Self.timestampString()).launchx-toolbox"
        savePanel.title = "导出百宝箱"
        savePanel.message = "选择百宝箱文件的保存位置(可用于新 Mac 快速恢复)"

        savePanel.begin { result in
            guard result == .OK, let url = savePanel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(export)
                try data.write(to: url, options: .atomic)

                let sizeText = ByteCountFormatter.string(
                    fromByteCount: Int64(data.count), countStyle: .file)
                ToolboxAlerts.showOnMain(
                    title: "导出成功",
                    message:
                        "百宝箱已导出至:\n\(url.lastPathComponent)\n\n共 \(export.items.count) 条,文件大小 \(sizeText)。在新 Mac 上用「导入」即可恢复。"
                )
            } catch {
                ToolboxAlerts.showOnMain(
                    title: "导出失败",
                    message: "发生错误:\(error.localizedDescription)",
                    style: .critical)
            }
        }
    }

    // MARK: - 导入

    /// 导入流程:OpenPanel → 解析 → 统计预览 → 用户选合并策略 → 落盘(清单+快照+激活码)→ 报告
    func importToolbox() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [Self.toolboxUTType, .json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "导入百宝箱"
        openPanel.message = "选择要导入的 LaunchX 百宝箱文件 (.launchx-toolbox)"

        openPanel.begin { [weak self] result in
            guard result == .OK, let url = openPanel.url, let self else { return }
            guard let data = try? Data(contentsOf: url),
                let file = ToolboxExportFile.decode(from: data)
            else {
                ToolboxAlerts.showOnMain(
                    title: "导入失败",
                    message: "无效的百宝箱文件或读取错误。",
                    style: .critical)
                return
            }
            self.importFromFile(file)
        }
    }

    /// 对已解析的导出文件执行导入(公开便于测试预览逻辑复用)
    func importFromFile(_ file: ToolboxExportFile) {
        let current = store.loadManifest().items

        // 预览统计:身份键冲突数
        let existingKeys = Set(current.compactMap(\.sourceIdentityKey))
        let existingIDs = Set(current.map(\.id))
        var conflictCount = 0
        for item in file.items {
            if let key = item.sourceIdentityKey, existingKeys.contains(key) {
                conflictCount += 1
            } else if existingIDs.contains(item.id) {
                conflictCount += 1
            }
        }
        let licenseCount = file.items.filter { $0.kind == .license }.count
        let secretCount = file.licenseSecrets?.count ?? 0

        // 策略选择(照 BackupService 导入确认惯例)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "导入百宝箱文件?"
        alert.informativeText =
            "文件包含 \(file.items.count) 条(其中激活码 \(licenseCount) 条、快照 \(file.snapshots?.count ?? 0) 份)。\n与现有条目冲突 \(conflictCount) 条。\n\n快照只会收录进百宝箱,不会自动覆盖本机文件;恢复需在「配置快照」中手动执行。"
        alert.addButton(withTitle: "覆盖冲突条目")
        alert.addButton(withTitle: "跳过已存在")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let policy: MergePolicy =
            response == .alertFirstButtonReturn ? .overwriteExisting : .skipExisting

        // 合并清单
        var items = current
        let report = ToolboxTransferService.merge(
            into: &items, incoming: file.items, policy: policy)

        do {
            var manifest = store.loadManifest()
            manifest.items = items
            try store.saveManifest(manifest)
        } catch {
            ToolboxAlerts.showOnMain(
                title: "导入失败",
                message: "保存清单失败:\(error.localizedDescription)",
                style: .critical)
            return
        }

        // 回填快照内容(只落 snapshots 目录,不碰用户 home)
        var snapshotsRestored = 0
        if let payloads = file.snapshots {
            for payload in payloads {
                // 未进合并映射的条目(静默跳过的重复项)按原 id 落盘
                let finalID = report.idMap[payload.itemId] ?? payload.itemId
                guard let content = Data(base64Encoded: payload.contentBase64),
                    content.count <= SnapshotService.maxSnapshotBytes
                else { continue }
                // 文件名取条目 meta 优先,回退 payload 自带
                let fileName =
                    store.item(withID: finalID)?.snapshotMeta?.fileNameOnDisk
                    ?? ToolboxStore.sanitizedFileName(from: payload.fileName)
                do {
                    try store.writeSnapshotData(
                        content, itemID: finalID, fileNameOnDisk: fileName)
                    snapshotsRestored += 1
                } catch {
                    // 单份快照失败不阻断整体导入
                }
            }
        }

        // 回填激活码明文(仅文件携带时)
        var secretsRestored = 0
        if let secrets = file.licenseSecrets {
            for secretPayload in secrets {
                guard let finalID = report.idMap[secretPayload.itemId],
                    let secretData = Data(base64Encoded: secretPayload.secretBase64),
                    let secret = String(data: secretData, encoding: .utf8)
                else { continue }
                if keychain.set(
                    secret,
                    service: KeychainStore.service,
                    account: KeychainStore.account(for: finalID))
                {
                    secretsRestored += 1
                }
            }
        }

        // 报告
        var lines = ["新增 \(report.added) 条,覆盖 \(report.updated) 条,跳过 \(report.skipped) 条。"]
        if snapshotsRestored > 0 {
            lines.append("已收录快照 \(snapshotsRestored) 份(可在「配置快照」中执行恢复)。")
        }
        if licenseCount > 0 {
            if secretsRestored > 0 {
                lines.append("已恢复激活码 \(secretsRestored)/\(licenseCount) 条。")
            } else {
                lines.append("激活码未随文件携带,导入后需重新录入。")
            }
        }
        ToolboxAlerts.showOnMain(title: "导入完成", message: lines.joined(separator: "\n"))
    }

    // MARK: - 辅助

    static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
