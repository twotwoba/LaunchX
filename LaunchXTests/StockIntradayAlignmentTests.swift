import XCTest
@testable import LaunchX

/// 分时 → 日K 前复权口径对齐（日K为前复权价、分时源为不复权价，
/// 除权除息后两套价格错位，需按「当日日K收盘 / 分时末点价」缩放）
final class StockIntradayAlignmentTests: XCTestCase {

    private func point(_ hhmm: String, price: Double, vol: Double = 100) -> StockTrendPoint {
        StockTrendPoint(
            time: "2026-03-09 \(hhmm)", open: price, high: price, low: price,
            price: price, avgPrice: price, volume: vol, amount: vol * price * 100)
    }

    /// 002941 实测案例：2026-07-09 除息后，3 月分时(不复权 16.69)对齐日K(前复权 16.49)
    func testAlignsRawIntradayToQfqDailyClose() {
        let context = StockIntradayContext(preClose: 16.35, close: 16.49)
        let raw = [point("09:30", price: 16.40), point("15:00", price: 16.69)]
        let out = context.alignedPoints(raw)
        XCTAssertEqual(out.last!.price, 16.49, accuracy: 0.001, "末点应精确对齐日K收盘")
        XCTAssertEqual(out.first!.price, 16.40 * 16.49 / 16.69, accuracy: 0.001)
        // 量、额不参与复权缩放
        XCTAssertEqual(out.first!.volume, raw[0].volume)
        XCTAssertEqual(out.first!.amount, raw[0].amount)
        // 对齐后涨跌幅与日K一致：(16.49-16.35)/16.35
        let pct = (out.last!.price - 16.35) / 16.35 * 100
        XCTAssertEqual(pct, 0.856, accuracy: 0.01)
    }

    /// 无锚点（当日未进日K）或末点无效：原样返回
    func testNoAnchorReturnsOriginal() {
        let noAnchor = StockIntradayContext(preClose: 10)
        let pts = [point("09:30", price: 10)]
        XCTAssertEqual(noAnchor.alignedPoints(pts), pts)

        let zeroLast = StockIntradayContext(preClose: 10, close: 10)
        let bad = [point("09:30", price: 0)]
        XCTAssertEqual(zeroLast.alignedPoints(bad), bad)
    }

    /// 复权因子数量级异常（数据对错日）不缩放，避免放大错误
    func testAbsurdFactorKeepsOriginal() {
        let context = StockIntradayContext(preClose: 10, close: 100)
        let pts = [point("09:30", price: 10)]
        XCTAssertEqual(context.alignedPoints(pts), pts)
    }

    /// 当日之后无除权（因子=1）：不产生缩放误差，量额不动
    func testAlreadyAlignedIsIdentity() {
        let context = StockIntradayContext(preClose: 16.35, close: 16.69)
        let pts = [point("09:30", price: 16.45), point("15:00", price: 16.69)]
        let out = context.alignedPoints(pts)
        XCTAssertEqual(out[0].price, 16.45, accuracy: 1e-9)
        XCTAssertEqual(out[1].price, 16.69, accuracy: 1e-9)
    }

    /// Excel 汇总行与图内口径一致：对齐后 pctChange 用同一 preClose 计算
    func testExporterRowUsesAlignedBasis() {
        let context = StockIntradayContext(preClose: 16.35, close: 16.49)
        let raw = [point("09:30", price: 16.40), point("15:00", price: 16.69)]
        let aligned = context.alignedPoints(raw)
        let row = StockExporter.intradayDayRow(
            points: aligned, day: "2026-03-09",
            columns: ["close", "pctChange"], context: context)
        XCTAssertTrue(row.contains("16.49"), row)
        XCTAssertTrue(row.contains("+0.86%"), row)
    }
}
