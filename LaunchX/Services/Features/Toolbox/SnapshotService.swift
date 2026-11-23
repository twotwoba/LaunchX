import CryptoKit
import Foundation

/// 配置文件快照服务
///
/// 收录用户自选文件(如 ~/.zshrc)为快照,供换机后比对/恢复。
/// 语义参考 mackup:恢复目标存在且不同时,先备份 .launchx.bak-<时间戳> 再原子写入。
/// 安全限制:仅单文件、上限 10MB、symlink 解析为真实路径。
/// 单测红线:所有测试文件操作必须发生在 temporaryDirectory,严禁触真实 ~。
final class SnapshotService {
    static let shared = SnapshotService()

    /// 单快照大小上限(10MB;导出需 base64 内嵌,过大文件不适合)
    static let maxSnapshotBytes = 10 * 1024 * 1024

    private let store: ToolboxStore

    init(store: ToolboxStore = .shared) {
        self.store = store
    }

    // MARK: - 错误

    enum SnapshotError: LocalizedError {
        case isDirectory  // 不支持目录收录(MVP 仅单文件)
        case unreadable
        case tooLarge(size: Int)
        case sourceMissing  // 刷新时源文件不存在
        case targetMissing  // 条目缺少可解析的目标路径
        case snapshotMissing  // 快照文件缺失
        case nameEmpty

        var errorDescription: String? {
            switch self {
            case .isDirectory: return "暂不支持收录文件夹,请选择单个文件"
            case .unreadable: return "文件不可读"
            case .tooLarge(let size):
                return "文件过大(\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))),上限 10MB"
            case .sourceMissing: return "源文件不存在,无法刷新快照"
            case .targetMissing: return "配置路径无效,无法定位目标文件"
            case .snapshotMissing: return "快照文件缺失,请重新收录"
            case .nameEmpty: return "文件名为空"
            }
        }
    }

    // MARK: - 对比与恢复语义

    /// 快照与目标机当前文件的对比结论
    enum Conflict: Equatable {
        case targetMissing  // 目标机还没有这个文件(直接写入)
        case identical  // 内容一致(无需恢复)
        case differs  // 有差异(恢复前需用户确认,覆盖前备份)
        case snapshotMissing  // 快照本体丢失(需重新收录)
    }

    /// 恢复结果
    enum RestoreOutcome: Equatable {
        case written  // 直接写入(目标原本不存在)
        case backupWritten(String)  // 覆盖完成,原文件已备份到此路径
        case skippedIdentical  // 目标与快照一致,未动
    }

    // MARK: - 收录

    /// 收录一个文件为快照(后台复制+hash,完成后 upsert 条目)
    func capture(sourceURL: URL) async throws -> ToolboxItem {
        let store = self.store
        return try await runInBackground {
            try SnapshotService.captureBlocking(sourceURL: sourceURL, store: store)
        }
    }

    /// 从当前源文件刷新快照(覆盖快照内容与元数据,条目 id/创建时间不变)
    func refresh(item: ToolboxItem) async throws -> ToolboxItem {
        guard let sourceURL = item.resolvedSourceURL else {
            throw SnapshotError.sourceMissing
        }
        let store = self.store
        return try await runInBackground {
            try SnapshotService.refreshBlocking(item: item, sourceURL: sourceURL, store: store)
        }
    }

    // MARK: - 对比(廉价路径:size+mtime,一致再算 hash)

    /// 分析目标机当前文件与快照的差异(文件 IO 很轻,可直接调用)
    func analyze(item: ToolboxItem) -> Conflict {
        guard let meta = item.snapshotMeta,
            store.snapshotFileExists(for: item)
        else {
            return .snapshotMissing
        }
        guard let target = item.resolvedSourceURL else {
            return .targetMissing
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            return .targetMissing
        }
        guard
            let attributes = try? fm.attributesOfItem(atPath: target.path),
            let targetSize = attributes[.size] as? Int
        else {
            return .differs
        }
        // 大小不同 → 必然不同(廉价过滤)
        if targetSize != meta.byteSize {
            return .differs
        }
        // 大小相同 → 直接比 hash(≤10MB 的 SHA256 仅几十毫秒,可靠优先;
        // 不用 mtime 快捷路径:同一秒内改写会被误判为一致,风险大于收益)
        guard let targetData = try? Data(contentsOf: target) else {
            return .differs
        }
        return Self.sha256Hex(of: targetData) == meta.sha256 ? .identical : .differs
    }

    // MARK: - 恢复

    /// 恢复快照到目标路径。differs 时调用方需先经用户确认;覆盖前自动备份 .launchx.bak-<时间戳>
    func restore(item: ToolboxItem) async throws -> RestoreOutcome {
        let store = self.store
        return try await runInBackground {
            try SnapshotService.restoreBlocking(item: item, store: store)
        }
    }

    // MARK: - 后台执行核心(nonisolated)

    nonisolated private static func captureBlocking(sourceURL: URL, store: ToolboxStore) throws
        -> ToolboxItem
    {
        let fm = FileManager.default
        // symlink 解析为真实路径,避免快照指向临时链接
        let resolved = sourceURL.resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw SnapshotError.unreadable
        }
        if isDirectory.boolValue {
            throw SnapshotError.isDirectory
        }
        let attributes = try fm.attributesOfItem(atPath: resolved.path)
        let byteSize = (attributes[.size] as? Int) ?? 0
        guard byteSize <= maxSnapshotBytes else {
            throw SnapshotError.tooLarge(size: byteSize)
        }
        let data: Data
        do {
            data = try Data(contentsOf: resolved)
        } catch {
            throw SnapshotError.unreadable
        }

        let fileName = ToolboxStore.sanitizedFileName(from: resolved.path)
        guard !fileName.isEmpty else {
            throw SnapshotError.nameEmpty
        }
        let meta = SnapshotMeta(
            fileNameOnDisk: fileName,
            sha256: sha256Hex(of: data),
            byteSize: data.count,
            capturedAt: Date(),
            sourceMtime: attributes[.modificationDate] as? Date)
        // 源路径存 home 相对形式,跨机可移植
        let item = ToolboxItem.configSnapshot(
            name: fileName,
            sourcePath: ToolboxItem.homeRelativePath(for: resolved),
            meta: meta)
        try store.writeSnapshotData(data, itemID: item.id, fileNameOnDisk: fileName)
        try store.upsert(item)
        return item
    }

    nonisolated private static func refreshBlocking(
        item: ToolboxItem, sourceURL: URL, store: ToolboxStore
    ) throws -> ToolboxItem {
        let fm = FileManager.default
        let resolved = sourceURL.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: resolved.path) else {
            throw SnapshotError.sourceMissing
        }
        let attributes = try fm.attributesOfItem(atPath: resolved.path)
        let byteSize = (attributes[.size] as? Int) ?? 0
        guard byteSize <= maxSnapshotBytes else {
            throw SnapshotError.tooLarge(size: byteSize)
        }
        let data = try Data(contentsOf: resolved)
        let fileName = ToolboxStore.sanitizedFileName(from: resolved.path)

        var updated = item
        updated.snapshotMeta = SnapshotMeta(
            fileNameOnDisk: fileName,
            sha256: sha256Hex(of: data),
            byteSize: data.count,
            capturedAt: Date(),
            sourceMtime: attributes[.modificationDate] as? Date)
        updated.updatedAt = Date()
        try store.writeSnapshotData(data, itemID: item.id, fileNameOnDisk: fileName)
        try store.upsert(updated)
        return updated
    }

    nonisolated private static func restoreBlocking(item: ToolboxItem, store: ToolboxStore) throws
        -> RestoreOutcome
    {
        guard let meta = item.snapshotMeta else {
            throw SnapshotError.snapshotMissing
        }
        guard let data = store.snapshotData(for: item) else {
            throw SnapshotError.snapshotMissing
        }
        guard let target = item.resolvedSourceURL else {
            throw SnapshotError.targetMissing
        }
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()

        // 目标不存在:建父目录后直接写
        guard fm.fileExists(atPath: target.path) else {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try atomicWrite(data, to: target)
            return .written
        }

        // 目标存在:先确认是否一致(以内容 hash 为准)
        if let targetData = try? Data(contentsOf: target),
            sha256Hex(of: targetData) == meta.sha256
        {
            return .skippedIdentical
        }

        // 有差异:备份原文件为 <名>.launchx.bak-<时间戳>(与用户自己的 .bak 不冲突)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let backupURL = parent.appendingPathComponent(
            "\(target.lastPathComponent).launchx.bak-\(timestamp)")
        try? fm.removeItem(at: backupURL)
        try fm.copyItem(at: target, to: backupURL)

        try atomicWrite(data, to: target)
        return .backupWritten(backupURL.path)
    }

    /// 原子写入:临时文件 + replaceItemAt(存在)/ moveItem(不存在)
    nonisolated private static func atomicWrite(_ data: Data, to target: URL) throws {
        let parent = target.deletingLastPathComponent()
        let tempURL = parent.appendingPathComponent(".tmp_\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: [])
            if fmExists(target) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    nonisolated private static func fmExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Hash

    /// SHA256 十六进制(CryptoKit)
    nonisolated static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
