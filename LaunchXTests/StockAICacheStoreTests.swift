import XCTest
@testable import LaunchX

/// AI 分析缓存：key 语义（交易日语义 / 模板内容哈希 / 模型身份）、同 key 覆盖、
/// LRU 逐出、持久化往返（独立 testURL，不污染正式缓存）。
/// @MainActor + async：Store 是模块默认 MainActor 隔离的 class，同步测试方法里
/// 释放会走隔离 deinit back-deploy 崩溃路径；task 上下文中释放是安全常态。
@MainActor
final class StockAICacheStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockAICacheStoreTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    // MARK: - fixtures

    private func makeBundle(
        code: String, targetDate: String? = nil, snapshotDate: String? = nil
    ) -> StockDataBundle {
        let snap = snapshotDate.map { d in
            StockSnapshot(
                code: code, name: "股\(code)", date: d, price: 10, preClose: 10, open: 10,
                high: 10, low: 10, volume: 0, amount: 0, volumeRatio: 0, turnover: 0,
                amplitude: 0, pctChange: 0, change: 0, totalMarketCap: 0, circMarketCap: 0,
                pe: 0, pb: 0, totalShares: 0, circShares: 0)
        }
        return StockDataBundle(
            input: code, code: code, name: "股\(code)", secid: "1.\(code)",
            targetDate: targetDate, snapshot: snap, indicators: nil,
            bars: [], capitalFlows: [], fundamentals: nil)
    }

    private func makeTemplate(
        name: String = "默认", system: String = "你是证券分析师",
        user: String = "分析 {code}", tools: Bool = false
    ) -> StockPromptTemplate {
        StockPromptTemplate(
            name: name, systemPrompt: system, userPromptTemplate: user, needsTools: tools)
    }

    private func makeModel(
        display: String = "GPT", model: String = "gpt-4o",
        baseURL: String = "https://api.openai.com/v1"
    ) -> AIModelConfig {
        AIModelConfig(name: display, model: model, baseURL: baseURL)
    }

    private func makeEntry(key: String, text: String = "## 结论\n\n短期偏多，关注量能。") -> StockAICacheStore.Entry {
        StockAICacheStore.Entry.make(
            key: key,
            segments: [
                .init(style: AIOutputStyle.reasoning.rawValue, text: "思考过程…"),
                .init(style: AIOutputStyle.normal.rawValue, text: text),
            ],
            createdAt: Date(),
            stockName: "贵州茅台", templateName: "默认", modelName: "GPT · gpt-4o")
    }

    // MARK: - 读写 + 覆盖

    /// 写入→命中往返：segments 原样恢复；同 key 二次写入覆盖旧内容
    func testStoreLookupAndOverwrite() async {
        let store = StockAICacheStore(testURL: fileURL)
        let key = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519")],
            template: makeTemplate(), model: makeModel())

        store.store(makeEntry(key: key))
        let hit = store.entry(forKey: key)
        XCTAssertEqual(hit?.segments.count, 2)
        XCTAssertEqual(hit?.segments.first?.style, AIOutputStyle.reasoning.rawValue)
        XCTAssertEqual(hit?.segments.last?.text, "## 结论\n\n短期偏多，关注量能。")
        XCTAssertEqual(store.count, 1)

        store.store(makeEntry(key: key, text: "覆盖后的新分析"))
        XCTAssertEqual(store.count, 1, "同 key 写入应覆盖而非新增")
        XCTAssertEqual(store.entry(forKey: key)?.segments.last?.text, "覆盖后的新分析")
    }

    // MARK: - key 语义

    /// key 稳定性与敏感维度：代码序无关、交易日归并（周末查询→快照数据日）、
    /// 模板内容变化失效（改名不失效）、模型身份变化失效（改显示名不失效）
    func testMakeKeySemantics() async {
        let base = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519"), makeBundle(code: "300750")],
            template: makeTemplate(), model: makeModel())

        // 多股顺序无关（codes 排序后拼接）
        let swapped = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "300750"), makeBundle(code: "600519")],
            template: makeTemplate(), model: makeModel())
        XCTAssertEqual(base, swapped)

        // 交易日语义：targetDate 缺省时落到快照数据日——周六/周日查询都归到周五快照，key 一致
        let weekend = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519", snapshotDate: "2026-08-14")],
            template: makeTemplate(), model: makeModel())
        let explicitFriday = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519", targetDate: "2026-08-14")],
            template: makeTemplate(), model: makeModel())
        XCTAssertEqual(weekend, explicitFriday)

        // 模板内容变化 → 失效；仅改模板名 → 仍命中
        let editedTemplate = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519")],
            template: makeTemplate(system: "你是更严格的分析师"), model: makeModel())
        XCTAssertNotEqual(weekend, editedTemplate)
        let renamedTemplate = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519", snapshotDate: "2026-08-14")],
            template: makeTemplate(name: "改名后的模板"), model: makeModel())
        XCTAssertEqual(weekend, renamedTemplate)

        // 模型身份：换模型/换接口 → 失效；仅改显示名 → 仍命中
        let otherModel = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519", snapshotDate: "2026-08-14")],
            template: makeTemplate(), model: makeModel(model: "gpt-4o-mini"))
        XCTAssertNotEqual(weekend, otherModel)
        let renamedModel = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519", snapshotDate: "2026-08-14")],
            template: makeTemplate(), model: makeModel(display: "我的模型"))
        XCTAssertEqual(weekend, renamedModel)
    }

    // MARK: - LRU + 持久化

    /// 超上限逐出最旧；新实例从磁盘恢复（含末条内容）
    func testLRUEvictionAndPersistenceReload() async {
        let store = StockAICacheStore(testURL: fileURL)
        // 用循环外代码构造最旧条目（000001 会与 i=1 撞 key，被 LRU touch 后不再最旧）
        let firstKey = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519")],
            template: makeTemplate(), model: makeModel())
        var lastKey = ""
        for i in 0..<61 {  // 上限 60，首条应被逐出
            let key = StockAICacheStore.makeKey(
                bundles: [makeBundle(code: String(format: "%06d", i))],
                template: makeTemplate(), model: makeModel())
            store.store(makeEntry(key: key, text: "第 \(i) 份分析"))
            lastKey = key
        }
        XCTAssertEqual(store.count, 60)
        XCTAssertNil(store.entry(forKey: firstKey), "最旧条目应被 LRU 逐出")
        XCTAssertEqual(store.entry(forKey: lastKey)?.segments.last?.text, "第 60 份分析")

        // 新实例（模拟重启）从同一文件恢复
        let reloaded = StockAICacheStore(testURL: fileURL)
        XCTAssertEqual(reloaded.count, 60)
        XCTAssertNil(reloaded.entry(forKey: firstKey))
        XCTAssertEqual(reloaded.entry(forKey: lastKey)?.segments.last?.text, "第 60 份分析")
    }

    /// 清空：内存与磁盘一并移除
    func testRemoveAllPersists() async {
        let store = StockAICacheStore(testURL: fileURL)
        let key = StockAICacheStore.makeKey(
            bundles: [makeBundle(code: "600519")],
            template: makeTemplate(), model: makeModel())
        store.store(makeEntry(key: key))
        store.removeAll()

        XCTAssertNil(store.entry(forKey: key))
        let reloaded = StockAICacheStore(testURL: fileURL)
        XCTAssertEqual(reloaded.count, 0, "removeAll 应落盘，重启后仍为空")
    }
}
