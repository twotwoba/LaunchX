import AppKit
import Foundation

/// 分时明细导出：TSV 无表头，粘贴进 Excel/Numbers 自动分列；列由设置勾选决定
enum StockExporter {

    /// 可导出的分钟列目录（设置面板据此生成勾选项）
    static let allColumns: [(key: String, title: String)] = [
        ("date", "时间"), ("open", "开盘"), ("high", "最高"), ("low", "最低"),
        ("close", "现价"), ("avgPrice", "均价"), ("volume", "成交量(万手)"), ("amount", "成交额(亿元)"),
        ("pctChange", "涨跌幅"), ("volumeRatio", "量比"), ("turnover", "换手率"),
    ]

    /// 某日分时汇总为一条（开高低收/均价/总量/总额/涨跌幅/量比/换手率），多天复制后可在 Excel 逐行堆叠比对
    static func intradayDayRow(
        points: [StockTrendPoint], day: String, columns: [String],
        context: StockIntradayContext = StockIntradayContext()
    ) -> String {
        let set = Set(columns)
        var effective = allColumns.filter { set.contains($0.key) }.map(\.key)
        if effective.isEmpty { effective = ["date", "open", "high", "low", "close", "volume"] }

        let open = points.first?.open ?? 0
        let close = points.last?.price ?? 0
        let high = points.map(\.high).max() ?? 0
        let low = points.map(\.low).min() ?? 0
        let volume = points.reduce(0) { $0 + $1.volume }  // 手
        let amount = points.reduce(0) { $0 + $1.amount }  // 元
        let avg = volume > 0 ? amount / (volume * 100) : close

        let row = effective.map { key -> String in
            switch key {
            case "date": return day
            case "open": return String(format: "%.2f", open)
            case "high": return String(format: "%.2f", high)
            case "low": return String(format: "%.2f", low)
            case "close": return String(format: "%.2f", close)
            case "avgPrice": return String(format: "%.2f", avg)
            case "volume": return String(format: "%.2f万", volume / 10000)  // 手 → 万手
            case "amount": return String(format: "%.2f亿", amount / 1e8)  // 元 → 亿元
            case "pctChange":
                guard let pre = context.preClose, pre > 0 else { return "" }
                return String(format: "%+.2f%%", (close - pre) / pre * 100)
            case "volumeRatio":
                // 量比 = 当日每分钟均量 / 前5日每分钟均量(240分钟)
                guard let avg5 = context.avg5Volume, avg5 > 0 else { return "" }
                let elapsed = elapsedMinutes(points)
                guard elapsed > 0 else { return "" }
                return String(format: "%.2f", (volume / elapsed) / (avg5 / 240))
            case "turnover":
                // 优先日K自带的当日换手率，缺失再用流通股本反推
                if let t = context.turnoverRate, t > 0 { return String(format: "%.2f%%", t) }
                guard let shares = context.circShares, shares > 0 else { return "" }
                return String(format: "%.2f%%", volume * 100 / shares * 100)
            default: return ""
            }
        }.joined(separator: "\t")
        return "\u{FEFF}" + row
    }

    /// 已成交分钟数：由首两点间隔推断 bar 周期，乘以点数（收盘满 240）
    private static func elapsedMinutes(_ points: [StockTrendPoint]) -> Double {
        guard points.count >= 2 else { return Double(points.count) }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let t0 = df.date(from: String(points[0].time.prefix(16))),
            let t1 = df.date(from: String(points[1].time.prefix(16)))
        else { return Double(points.count) }
        let interval = t1.timeIntervalSince(t0) / 60
        guard interval > 0, interval <= 120 else { return Double(points.count) }
        return interval * Double(points.count)
    }

    /// 分时窗口「复制 Excel」：按日一条
    static func copyIntradayDay(
        points: [StockTrendPoint], day: String, columns: [String],
        context: StockIntradayContext = StockIntradayContext()
    ) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(
            intradayDayRow(points: points, day: day, columns: columns, context: context),
            forType: .string)
    }
}
