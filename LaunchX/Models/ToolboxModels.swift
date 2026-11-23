import Foundation

// MARK: - 百宝箱数据模型
//
// 百宝箱(Toolbox)收集用户常用工具与环境,用于重装系统/换新 Mac 后快速恢复:
// - toolLink       工具收藏(官网/GitHub 链接)
// - brewPackage    Homebrew 包(记录名字,支持一键安装)
// - configSnapshot 配置文件快照(如 ~/.zshrc)
// - license        软件激活码(明文【只】存 Keychain,模型与导出文件默认不含明文)
//
// 设计约束(为二期 iCloud 同步留余地):身份键(sourceIdentityKey)一律使用
// 机器无关信息(规范化 URL / brew 名 / home 相对路径 / 软件名),不含绝对路径。

/// 百宝箱条目类型
enum ToolboxItemKind: String, Codable, CaseIterable {
    case toolLink  // 工具收藏
    case brewPackage  // Homebrew 包
    case configSnapshot  // 配置文件快照
    case license  // 激活码

    /// 中文名称(设置页展示)
    var displayName: String {
        switch self {
        case .toolLink: return "工具收藏"
        case .brewPackage: return "Homebrew"
        case .configSnapshot: return "配置快照"
        case .license: return "激活码"
        }
    }

    /// SF Symbol 图标名
    var systemImage: String {
        switch self {
        case .toolLink: return "link"
        case .brewPackage: return "archivebox"
        case .configSnapshot: return "doc.text"
        case .license: return "key"
        }
    }
}

/// brew 包类别
enum BrewPackageKind: String, Codable, CaseIterable {
    case formula
    case cask

    /// 徽标文字
    var badge: String {
        switch self {
        case .formula: return "Formula"
        case .cask: return "Cask"
        }
    }
}

/// 快照元数据(内容本体存 snapshots/<itemUUID>/ 目录,模型只存元信息)
struct SnapshotMeta: Codable, Equatable, Hashable {
    /// 快照目录下的文件名(已 sanitize)
    var fileNameOnDisk: String
    /// 内容 SHA256 十六进制(CryptoKit)
    var sha256: String
    /// 字节大小
    var byteSize: Int
    /// 收录时间
    var capturedAt: Date
    /// 收录时源文件的修改时间(用于廉价对比,可能为 nil)
    var sourceMtime: Date?
}

/// 百宝箱条目
/// 照 ToolItem 惯例:单 struct + kind 判别 + 可选字段;以 id 判等。
/// 注意:id 为 var —— 仅限导出导入「覆盖已存在」合并时改写为本机已有条目的 id
/// (保留 Keychain/快照目录与本机条目的对应关系);常规流程不得改 id。
struct ToolboxItem: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var kind: ToolboxItemKind
    var name: String
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    // toolLink 专用
    var urlString: String?

    // brewPackage 专用
    var brewKind: BrewPackageKind?
    var brewTap: String?  // 如 "homebrew/cask" 之外的自定义 tap

    // configSnapshot 专用
    /// 源路径,存 home 相对形式(如 "~/.zshrc"),跨机可移植
    var sourcePath: String?
    var snapshotMeta: SnapshotMeta?

    // license 专用
    /// 账户/邮箱等非敏感补充信息(激活码明文绝不入模型,只存 Keychain)
    var account: String?

    // MARK: - 初始化

    init(
        id: UUID = UUID(),
        kind: ToolboxItemKind,
        name: String,
        notes: String? = nil,
        urlString: String? = nil,
        brewKind: BrewPackageKind? = nil,
        brewTap: String? = nil,
        sourcePath: String? = nil,
        snapshotMeta: SnapshotMeta? = nil,
        account: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.notes = notes
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        self.urlString = urlString
        self.brewKind = brewKind
        self.brewTap = brewTap
        self.sourcePath = sourcePath
        self.snapshotMeta = snapshotMeta
        self.account = account
    }

    // MARK: - 工厂方法

    /// 工具收藏
    static func toolLink(name: String, url: String, notes: String? = nil) -> ToolboxItem {
        ToolboxItem(kind: .toolLink, name: name, notes: notes, urlString: url)
    }

    /// Homebrew 包
    static func brewPackage(
        name: String, kind: BrewPackageKind, tap: String? = nil, notes: String? = nil
    ) -> ToolboxItem {
        ToolboxItem(kind: .brewPackage, name: name, notes: notes, brewKind: kind, brewTap: tap)
    }

    /// 配置文件快照
    static func configSnapshot(
        name: String, sourcePath: String, meta: SnapshotMeta, notes: String? = nil
    ) -> ToolboxItem {
        ToolboxItem(
            kind: .configSnapshot, name: name, notes: notes, sourcePath: sourcePath,
            snapshotMeta: meta)
    }

    /// 激活码(明文另存 Keychain)
    static func license(name: String, account: String? = nil, notes: String? = nil) -> ToolboxItem {
        ToolboxItem(kind: .license, name: name, notes: notes, account: account)
    }

    // MARK: - 身份键(合并/去重,机器无关)

    /// 跨机合并时判定"同一条目"的键;无法计算时返回 nil(视为唯一,不参与去重)
    var sourceIdentityKey: String? {
        switch kind {
        case .toolLink:
            return normalizedURLString.map { "link:\($0)" }
        case .brewPackage:
            let kind = brewKind?.rawValue ?? ""
            return "brew:\(kind):\(name.lowercased())"
        case .configSnapshot:
            guard let sourcePath else { return nil }
            return "snapshot:\(sourcePath)"
        case .license:
            return "license:\(name.lowercased())"
        }
    }

    /// 规范化 URL(scheme/host 小写、去根路径尾斜杠),用于链接去重
    /// 无 scheme 的录入(如 "raycast.com")按 https:// 参与归一,与 resolvedURL 展示语义一致
    var normalizedURLString: String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        let candidate = urlString.contains("://") ? urlString : "https://\(urlString)"
        guard var comps = URLComponents(string: candidate) else { return urlString }
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        guard let normalized = comps.url?.absoluteString else { return urlString }
        // 去掉纯根路径的尾斜杠(https://a.com/ → https://a.com)
        if normalized.hasSuffix("/") {
            let withoutSlash = String(normalized.dropLast())
            if let url = URL(string: withoutSlash), url.path.isEmpty {
                return withoutSlash
            }
        }
        return normalized
    }

    // MARK: - 展示与操作辅助

    /// 解析后的链接(点击"打开"用,经 AppOpener 打开)
    var resolvedURL: URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        // 无 scheme 时补 https://,提升录入容错
        if urlString.contains("://") {
            return URL(string: urlString)
        }
        return URL(string: "https://\(urlString)")
    }

    /// brew 安装命令(展示与执行用)
    var brewCommand: String? {
        guard kind == .brewPackage, let brewKind else { return nil }
        let fullName = brewTap.map { "\($0)/\(name)" } ?? name
        switch brewKind {
        case .formula: return "brew install \(fullName)"
        case .cask: return "brew install --cask \(fullName)"
        }
    }

    /// 副标题(列表展示)
    var subtitle: String? {
        switch kind {
        case .toolLink: return urlString
        case .brewPackage: return brewCommand
        case .configSnapshot: return sourcePath
        case .license: return account
        }
    }

    /// 把 home 相对路径(如 "~/.zshrc")解析为当前机器的绝对 URL
    var resolvedSourceURL: URL? {
        guard let sourcePath, !sourcePath.isEmpty else { return nil }
        let expanded = (sourcePath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// 绝对路径 → home 相对形式(收录时存储用)
    static func homeRelativePath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

// MARK: - 主清单(落盘结构)

/// 百宝箱主清单,落盘为 manifest.json(经 ClaudeDataStore 原子写)
struct ToolboxManifest: Codable {
    var schemaVersion: Int = 1
    var items: [ToolboxItem] = []

    /// 容错解码:整体失败时逐条 try? 解码,跳过无法识别的条目(前向兼容)
    static func tolerantDecode(from data: Data) -> ToolboxManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let manifest = try? decoder.decode(ToolboxManifest.self, from: data) {
            return manifest
        }
        // 回退:JSONSerialization 拆出 items 数组逐条解码
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawItems = object["items"] as? [[String: Any]]
        else { return nil }
        var items: [ToolboxItem] = []
        for raw in rawItems {
            guard let itemData = try? JSONSerialization.data(withJSONObject: raw),
                let item = try? decoder.decode(ToolboxItem.self, from: itemData)
            else { continue }
            items.append(item)
        }
        return ToolboxManifest(schemaVersion: 1, items: items)
    }
}

// MARK: - 导出文件格式(.launchx-toolbox,本质 JSON)

/// 导出文件中的单个快照内容(base64 内嵌)
struct SnapshotPayload: Codable, Equatable {
    let itemId: UUID
    let fileName: String
    let contentBase64: String
}

/// 导出文件中的单个激活码明文(仅 includesLicenses=true 时出现;base64 转移,不改变存储语义)
struct LicenseSecretPayload: Codable, Equatable {
    let itemId: UUID
    let secretBase64: String
}

/// .launchx-toolbox 导出文件顶层结构
struct ToolboxExportFile: Codable {
    var schemaVersion: Int = 1
    var exportedAt: Date
    var appVersion: String?
    /// 激活码是否内嵌(默认 false;开启时明文落盘,UI 需警示)
    var includesLicenses: Bool = false
    var items: [ToolboxItem]
    var snapshots: [SnapshotPayload]?
    var licenseSecrets: [LicenseSecretPayload]?

    /// 导入解码:严格失败时逐条容错(同 tolerantDecode 思路)
    static func decode(from data: Data) -> ToolboxExportFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(ToolboxExportFile.self, from: data) {
            return file
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawItems = object["items"] as? [[String: Any]]
        else { return nil }
        var items: [ToolboxItem] = []
        for raw in rawItems {
            guard let itemData = try? JSONSerialization.data(withJSONObject: raw),
                let item = try? decoder.decode(ToolboxItem.self, from: itemData)
            else { continue }
            items.append(item)
        }
        // snapshots 整体可选,失败即忽略
        let snapshots: [SnapshotPayload]?
        if let rawSnapshots = object["snapshots"] as? [[String: Any]],
            let snapshotsData = try? JSONSerialization.data(withJSONObject: rawSnapshots),
            let decoded = try? decoder.decode([SnapshotPayload].self, from: snapshotsData)
        {
            snapshots = decoded
        } else {
            snapshots = nil
        }
        // 元信息尽力恢复(兼容旧版本/损坏文件)
        let includesLicenses = (object["includesLicenses"] as? Bool) ?? false
        return ToolboxExportFile(
            exportedAt: Date(), appVersion: nil, includesLicenses: includesLicenses,
            items: items, snapshots: snapshots)
    }
}
