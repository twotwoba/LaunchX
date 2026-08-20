import CryptoKit
import Foundation

/// AI 分析结果本地缓存：同日同股同模板同模型不重复请求接口，省 token。
///
/// - 命中即整段装载（reasoning + 正文分段原样恢复），切换股票再切回秒出结果
/// - key = `codes|targetDate|templateHash|modelID`：
///   - targetDate 用**交易日**语义（周末两天的「最新」查询都归到快照数据日），
///     自然日会让周六/周日的分析互相 miss
///   - templateHash 是模板内容（systemPrompt+userPromptTemplate+needsTools）的哈希——
///     防止改模板内容（ID 不变）后旧缓存误导
///   - modelID 用 baseURL host + model，用户改显示名不失效
/// - 内存字典 + LRU 上限 60 条；落盘 `…/Application Support/LaunchX/StockAICache/analyses.json`
///   （整文件 `.atomic` 重写，与 SnippetService 同惯例）
final class StockAICacheStore {
    static let shared = StockAICacheStore()

    // MARK: - 数据结构

    /// 存储层独立分段（不依赖 UI 层的 AIOutputStyle，style 用原始值字符串）
    struct CachedSegment: Codable, Hashable {
        let style: String  // AIOutputStyle.rawValue
        let text: String
    }

    struct Entry: Codable {
        let key: String
        let segments: [CachedSegment]
        let createdAt: Date
        let stockName: String
        let templateName: String
        let modelName: String
        let schemaVersion: Int

        /// 便捷构造：schemaVersion 由 Store 统一盖章，调用方不感知版本号
        static func make(
            key: String, segments: [CachedSegment], createdAt: Date,
            stockName: String, templateName: String, modelName: String
        ) -> Entry {
            Entry(
                key: key, segments: segments, createdAt: createdAt,
                stockName: stockName, templateName: templateName,
                modelName: modelName, schemaVersion: StockAICacheStore.currentSchemaVersion
            )
        }
    }

    // MARK: - 状态

    /// 供测试注入的存储文件 URL；nil = 仅内存（不落盘）
    private let fileURL: URL?
    private var entries: [String: Entry] = [:]
    /// LRU 顺序（尾为最近使用）；仅插拔时持久化，读触碰不落盘（重启后顺序丢失可接受）
    private var order: [String] = []
    private let maxEntries = 60
    static let currentSchemaVersion = 1

    // MARK: - 生命周期

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("LaunchX/StockAICache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("analyses.json")
        fileURL = url
        load(from: url)
    }

    /// 测试入口：独立存储位置，不污染正式缓存
    init(testURL: URL) {
        fileURL = testURL
        load(from: testURL)
    }

    // MARK: - 读写

    /// 查缓存（命中会推进 LRU 顺序，不触发落盘）
    func entry(forKey key: String) -> Entry? {
        guard let e = entries[key] else { return nil }
        touch(key)
        return e
    }

    /// 写入/覆盖同 key，超限逐出最旧条目
    func store(_ entry: Entry) {
        entries[entry.key] = entry
        touch(entry.key)
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        persist()
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        persist()
    }

    var count: Int { entries.count }

    // MARK: - Key 构造

    /// bundles 非空才有意义；template/model 任一为 nil 返回 nil（缺参不缓存）
    static func makeKey(
        bundles: [StockDataBundle], template: StockPromptTemplate, model: AIModelConfig
    ) -> String {
        let codes = bundles.map(\.code).sorted().joined(separator: "+")
        // 交易日语义：显式目标日优先，否则用快照数据日（周末查询归到上一交易日）
        let targetDate = bundles.first?.targetDate
            ?? bundles.first?.snapshot?.date
            ?? bundles.first?.chartBars.last?.date
            ?? "unknown"
        // 模板内容哈希必须跨进程稳定（Hasher 每次启动随机播种，不能用于持久 key）
        let content = template.systemPrompt + "\u{1}"
            + template.userPromptTemplate + "\u{1}" + String(template.needsTools)
        let digest = SHA256.hash(data: Data(content.utf8))
        let templateHash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        // baseURL host + model：改显示名不失效，换接口/换模型必失效
        let host = URL(string: model.baseURL)?.host ?? model.baseURL
        let modelID = "\(host)/\(model.model)"
        return [codes, targetDate, templateHash, modelID].joined(separator: "|")
    }

    // MARK: - 持久化

    private func touch(_ key: String) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }

    private func load(from url: URL) {
        guard let data = try? Data(contentsOf: url),
            let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        for e in list where e.schemaVersion == Self.currentSchemaVersion {
            entries[e.key] = e
            order.append(e.key)
        }
        // 文件里可能有被淘汰版本污染的重复顺序，截到上限
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    private func persist() {
        guard let url = fileURL else { return }
        let list = order.compactMap { entries[$0] }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
