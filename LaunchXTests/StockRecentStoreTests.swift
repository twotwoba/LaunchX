import XCTest
@testable import LaunchX

/// 面板历史查询记录：去重置顶、上限裁剪、删除/清空（独立 UserDefaults suite，不污染真实数据）
final class StockRecentStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "StockRecentStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// 同代码再次查询：去重并置顶，不产生重复项
    func testRecordDeduplicatesAndMovesToFront() {
        StockRecentStore.record(code: "600519", name: "贵州茅台", defaults: defaults)
        StockRecentStore.record(code: "300750", name: "宁德时代", defaults: defaults)
        StockRecentStore.record(code: "600519", name: "贵州茅台", defaults: defaults)

        let list = StockRecentStore.load(defaults: defaults)
        XCTAssertEqual(list.map(\.code), ["600519", "300750"])
    }

    /// 超过上限：保留最新的 limit 条
    func testRecordTrimsToLimit() {
        for i in 0..<(StockRecentStore.limit + 5) {
            StockRecentStore.record(
                code: String(format: "%06d", i), name: "股票\(i)", defaults: defaults)
        }
        let list = StockRecentStore.load(defaults: defaults)
        XCTAssertEqual(list.count, StockRecentStore.limit)
        // 最新查询在前：第一条是最后 record 的，最老的四条被裁掉
        XCTAssertEqual(list.first?.code, String(format: "%06d", StockRecentStore.limit + 4))
        XCTAssertFalse(list.contains { $0.code == "000000" })
    }

    /// 删除单条与清空
    func testRemoveAndRemoveAll() {
        StockRecentStore.record(code: "600519", name: "贵州茅台", defaults: defaults)
        StockRecentStore.record(code: "300750", name: "宁德时代", defaults: defaults)

        let afterRemove = StockRecentStore.remove(code: "600519", defaults: defaults)
        XCTAssertEqual(afterRemove.map(\.code), ["300750"])
        XCTAssertEqual(StockRecentStore.load(defaults: defaults).map(\.code), ["300750"])

        StockRecentStore.removeAll(defaults: defaults)
        XCTAssertTrue(StockRecentStore.load(defaults: defaults).isEmpty)
    }
}
