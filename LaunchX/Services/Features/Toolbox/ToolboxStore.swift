import Foundation

/// 百宝箱主存储
///
/// 职责:manifest.json 读写(原子)、快照目录管理、删除条目时的 Keychain 清理。
/// 照 ClaudeDataStore 惯例:串行 queue 保护 + 复用其 readJSON/writeJSON 原子读写。
/// 目录与 Keychain 实现均可注入(单测传临时目录 + InMemoryKeychain,绝不碰真实数据)。
final class ToolboxStore {
    static let shared = ToolboxStore()

    /// 百宝箱根目录(默认 Application Support/LaunchX/toolbox)
    let toolboxDir: URL

    /// 配置文件快照根目录(toolbox/snapshots/<itemUUID>/<文件名>)
    let snapshotsDir: URL

    /// Keychain 实现(默认真实实现;测试注入 InMemoryKeychain)
    private let keychain: KeychainStoring

    private let queue = DispatchQueue(label: "com.launchx.toolbox.store", qos: .userInitiated)

    private var manifestFile: URL {
        toolboxDir.appendingPathComponent("manifest.json")
    }

    init(directory: URL? = nil, keychain: KeychainStoring = SecItemKeychainStore()) {
        if let directory {
            toolboxDir = directory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first!
            toolboxDir = appSupport.appendingPathComponent("LaunchX/toolbox", isDirectory: true)
        }
        snapshotsDir = toolboxDir.appendingPathComponent("snapshots", isDirectory: true)
        self.keychain = keychain
        try? FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
    }

    // MARK: - 清单读写

    /// 读取主清单(容错:文件缺失/损坏返回空清单,坏条目被跳过)
    func loadManifest() -> ToolboxManifest {
        queue.sync {
            guard let data = try? Data(contentsOf: manifestFile) else {
                return ToolboxManifest()
            }
            return ToolboxManifest.tolerantDecode(from: data) ?? ToolboxManifest()
        }
    }

    /// 保存主清单(原子写)
    func saveManifest(_ manifest: ToolboxManifest) throws {
        try queue.sync {
            try ClaudeDataStore.shared.writeJSON(manifest, to: manifestFile)
        }
    }

    /// 新增或更新条目(按 id 判定)
    func upsert(_ item: ToolboxItem) throws {
        var manifest = loadManifest()
        if let index = manifest.items.firstIndex(where: { $0.id == item.id }) {
            manifest.items[index] = item
        } else {
            manifest.items.append(item)
        }
        try saveManifest(manifest)
    }

    /// 按 id 取条目
    func item(withID id: UUID) -> ToolboxItem? {
        loadManifest().items.first { $0.id == id }
    }

    /// 删除条目。
    /// 顺序固定:①先删 Keychain secret(防清单已删但密钥残留泄漏)→ ②改清单 → ③清快照目录。
    func deleteItem(_ id: UUID) throws {
        keychain.delete(service: KeychainStore.service, account: KeychainStore.account(for: id))

        var manifest = loadManifest()
        let removed = manifest.items.first { $0.id == id }
        manifest.items.removeAll { $0.id == id }
        try saveManifest(manifest)

        if let removed {
            removeSnapshotDirectory(for: removed.id)
        }
    }

    /// 按类型过滤条目
    func items(of kind: ToolboxItemKind) -> [ToolboxItem] {
        loadManifest().items.filter { $0.kind == kind }
    }

    // MARK: - 快照文件管理

    /// 条目对应的快照目录
    func snapshotDirectory(for itemID: UUID) -> URL {
        snapshotsDir.appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    /// 条目对应的快照文件 URL
    func snapshotFileURL(itemID: UUID, fileNameOnDisk: String) -> URL {
        snapshotDirectory(for: itemID).appendingPathComponent(fileNameOnDisk)
    }

    /// 原子写入快照内容(导入/收录共用)
    func writeSnapshotData(_ data: Data, itemID: UUID, fileNameOnDisk: String) throws {
        let dir = snapshotDirectory(for: itemID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(fileNameOnDisk)
        // 原子写:临时文件 + moveItem(照 ClaudeDataStore 惯例)
        let tempURL = dir.appendingPathComponent(".tmp_\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: [])
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: tempURL, to: target)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// 读取快照内容
    func snapshotData(for item: ToolboxItem) -> Data? {
        guard let meta = item.snapshotMeta else { return nil }
        let url = snapshotFileURL(itemID: item.id, fileNameOnDisk: meta.fileNameOnDisk)
        return queue.sync {
            try? Data(contentsOf: url)
        }
    }

    /// 快照文件是否存在
    func snapshotFileExists(for item: ToolboxItem) -> Bool {
        guard let meta = item.snapshotMeta else { return false }
        let url = snapshotFileURL(itemID: item.id, fileNameOnDisk: meta.fileNameOnDisk)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 删除条目的快照目录
    private func removeSnapshotDirectory(for itemID: UUID) {
        try? FileManager.default.removeItem(at: snapshotDirectory(for: itemID))
    }

    /// 孤儿清扫:删除不在清单中的快照目录(load 后调用一次)
    func performOrphanSweep() {
        let validIDs = Set(loadManifest().items.map { $0.id.uuidString })
        guard
            let dirs = try? FileManager.default.contentsOfDirectory(
                at: snapshotsDir, includingPropertiesForKeys: nil)
        else { return }
        for dir in dirs where !validIDs.contains(dir.lastPathComponent) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - 文件名 sanitize

    /// 从用户路径提取安全文件名:取最后一级,替换路径分隔符与控制字符
    static func sanitizedFileName(from path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == ".." {
            name = "snapshot"
        }
        let invalid = CharacterSet(charactersIn: "/:\0").union(.controlCharacters)
        let replaced = name.unicodeScalars.map { invalid.contains($0) ? "_" : $0 }
        let result = String(String.UnicodeScalarView(replaced))
        return result.isEmpty ? "snapshot" : result
    }
}
