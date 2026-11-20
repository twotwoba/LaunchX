import XCTest

@testable import LaunchX

/// 计算历史服务:记录/去重/上限淘汰/持久化往返(注入临时目录,绝不触碰 shared 单例的真实数据)
final class CalculatorHistoryServiceTests: XCTestCase {
    /// 每个用例独立的临时目录,避免用例间与真实数据互相污染
    private func makeService() -> CalculatorHistoryService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchx-calc-history-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CalculatorHistoryService(directory: directory)
    }

    func testRecordInsertsNewestFirst() {
        let service = makeService()
        service.record(expression: "1+1", result: "2")
        service.record(expression: "2*3", result: "6")
        let entries = service.currentEntries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.expression, "2*3")
        XCTAssertEqual(entries.last?.expression, "1+1")
    }

    func testRecordDeduplicatesByExpressionAndMovesToFront() {
        let service = makeService()
        service.record(expression: "1+1", result: "2")
        service.record(expression: "2*3", result: "6")
        // 同表达式不同结果:覆盖旧值并置顶(如切换 Rad/Deg 后重新求值)
        service.record(expression: "1+1", result: "2")
        let entries = service.currentEntries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.expression, "1+1")
        XCTAssertEqual(entries.first?.result, "2")
    }

    func testRecordTrimsWhitespace() {
        let service = makeService()
        service.record(expression: "  1+1  ", result: " 2 ")
        XCTAssertEqual(service.currentEntries.first?.expression, "1+1")
        XCTAssertEqual(service.currentEntries.first?.result, "2")
    }

    func testRecordRejectsEmpty() {
        let service = makeService()
        service.record(expression: "", result: "2")
        service.record(expression: "1+1", result: "")
        service.record(expression: "   ", result: "2")
        XCTAssertTrue(service.currentEntries.isEmpty)
    }

    func testMaxEntriesEvictsOldest() {
        let service = makeService()
        for i in 0..<(CalculatorHistoryService.maxEntries + 10) {
            service.record(expression: "expr\(i)", result: "\(i)")
        }
        let entries = service.currentEntries
        XCTAssertEqual(entries.count, CalculatorHistoryService.maxEntries)
        // 最新在前:头是最后一条,尾部最旧的被淘汰
        XCTAssertEqual(entries.first?.expression, "expr\(CalculatorHistoryService.maxEntries + 9)")
        XCTAssertEqual(entries.last?.expression, "expr10")
        XCTAssertFalse(entries.contains { $0.expression == "expr0" })
    }

    func testPersistenceRoundTrip() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchx-calc-history-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let writer = CalculatorHistoryService(directory: directory)
        writer.record(expression: "5!", result: "120")
        writer.record(expression: "1/2", result: "0.5")
        // 防抖未到期,显式落盘模拟退出 flush
        writer.saveImmediately()

        let reader = CalculatorHistoryService(directory: directory)
        let entries = reader.currentEntries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.expression, "1/2")
        XCTAssertEqual(entries.map(\.result), ["0.5", "120"])
    }

    func testClearAllPersistsImmediately() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchx-calc-history-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let service = CalculatorHistoryService(directory: directory)
        service.record(expression: "1+1", result: "2")
        service.clearAll()

        let reloaded = CalculatorHistoryService(directory: directory)
        XCTAssertTrue(reloaded.currentEntries.isEmpty)
    }
}
