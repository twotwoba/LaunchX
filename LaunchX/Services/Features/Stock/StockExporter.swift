import AppKit
import Foundation

/// 股票数据导出：JSON（中文友好）+ CSV（UTF-8 BOM，Excel/Numbers 直开）
enum StockExporter {

    // MARK: - JSON

    /// 生成中文友好的 JSON 字符串
    static func toJSON(bundles: [StockDataBundle]) -> String {
        var arr: [[String: Any]] = []
        for b in bundles { arr.append(bundleDictionary(b)) }
        let root: [String: Any] = [
            "数据来源": "东方财富",
            "免责声明": "仅供学习参考，不构成投资建议",
            "股票": arr,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func bundleDictionary(_ b: StockDataBundle) -> [String: Any] {
        var d: [String: Any] = [
            "输入": b.input,
            "代码": b.code,
            "名称": b.name,
            "目标日期": b.targetDate ?? "最新",
        ]
        if let s = b.snapshot {
            d["行情快照"] = [
                "日期": s.date,
                "最新价": s.price,
                "涨跌幅(%)": s.pctChange,
                "涨跌额": s.change,
                "今开": s.open,
                "最高": s.high,
                "最低": s.low,
                "昨收": s.preClose,
                "振幅(%)": s.amplitude,
                "换手率(%)": s.turnover,
                "量比": s.volumeRatio,
                "成交量(手)": s.volume,
                "成交额(元)": s.amount,
                "总市值(元)": s.totalMarketCap,
                "流通市值(元)": s.circMarketCap,
                "市盈率(动)": s.pe,
                "市净率": s.pb,
            ] as [String: Any]
        }
        if let ind = b.indicators {
            var indDict: [String: Any] = [:]
            if let m = ind.macd {
                indDict["MACD"] = ["DIF": m.dif, "DEA": m.dea, "MACD": m.macd] as [String: Any]
            }
            if let k = ind.kdj {
                indDict["KDJ"] = ["K": k.k, "D": k.d, "J": k.j] as [String: Any]
            }
            indDict["均线"] = [
                "MA5": ind.ma.ma5 as Any,
                "MA10": ind.ma.ma10 as Any,
                "MA20": ind.ma.ma20 as Any,
                "MA60": ind.ma.ma60 as Any,
                "BOLL上轨": ind.ma.bollUpper as Any,
                "BOLL中轨": ind.ma.bollMid as Any,
                "BOLL下轨": ind.ma.bollLower as Any,
            ] as [String: Any]
            d["技术指标"] = indDict
        }
        if !b.capitalFlows.isEmpty {
            d["资金流向(近\(min(b.capitalFlows.count, 5))日)"] = b.capitalFlows
                .suffix(5)
                .map { f in
                    [
                        "日期": f.date,
                        "主力净流入(元)": f.main,
                        "超大单(元)": f.superLarge,
                        "大单(元)": f.large,
                        "中单(元)": f.medium,
                        "小单(元)": f.small,
                        "主力净流入占比(%)": f.mainPct,
                    ] as [String: Any]
                }
        }
        if let f = b.fundamentals {
            var fdict: [String: Any] = [:]
            if let v = f.industry { fdict["行业"] = v }
            if let v = f.pe { fdict["市盈率"] = v }
            if let v = f.pb { fdict["市净率"] = v }
            if let v = f.totalMarketCap { fdict["总市值(元)"] = v }
            if let v = f.circMarketCap { fdict["流通市值(元)"] = v }
            if !fdict.isEmpty { d["基本面"] = fdict }
        }
        if let note = b.note { d["备注"] = note }
        return d
    }

    // MARK: - CSV（横截面，每行一只股票）

    private static let csvHeaders: [String] = [
        "代码", "名称", "日期", "最新价", "涨跌幅(%)", "涨跌额", "今开", "最高", "最低", "昨收",
        "振幅(%)", "换手率(%)", "量比", "成交量(手)", "成交额(元)", "总市值(元)", "流通市值(元)",
        "市盈率", "市净率", "MACD-DIF", "MACD-DEA", "MACD柱", "KDJ-K", "KDJ-D", "KDJ-J",
        "MA5", "MA10", "MA20", "MA60", "主力净流入(元)", "超大单(元)", "大单(元)", "中单(元)",
        "小单(元)", "行业",
    ]

    static func toCSV(bundles: [StockDataBundle]) -> String {
        var rows: [String] = [csvHeaders.joined(separator: ",")]
        for b in bundles {
            rows.append(csvRow(b))
        }
        let body = rows.joined(separator: "\r\n")
        // UTF-8 BOM，保证 Excel/Numbers 中文不乱码
        return "\u{FEFF}" + body
    }

    private static func csvRow(_ b: StockDataBundle) -> String {
        let s = b.snapshot
        let ind = b.indicators
        let m = ind?.macd
        let k = ind?.kdj
        let ma = ind?.ma
        let cf = b.capitalFlows.last
        let vals: [Any?] = [
            b.code, b.name, b.targetDate ?? "最新",
            s?.price, s?.pctChange, s?.change, s?.open, s?.high, s?.low, s?.preClose,
            s?.amplitude, s?.turnover, s?.volumeRatio, s?.volume, s?.amount,
            s?.totalMarketCap, s?.circMarketCap, s?.pe, s?.pb,
            m?.dif, m?.dea, m?.macd,
            k?.k, k?.d, k?.j,
            ma?.ma5, ma?.ma10, ma?.ma20, ma?.ma60,
            cf?.main, cf?.superLarge, cf?.large, cf?.medium, cf?.small,
            b.fundamentals?.industry,
        ]
        return vals.map { csvField($0) }.joined(separator: ",")
    }

    private static func csvField(_ v: Any?) -> String {
        guard let v = v else { return "" }
        let str = formatNumber(v)
        // 含逗号/引号/换行的字段需转义
        if str.contains(",") || str.contains("\"") || str.contains("\n") {
            return "\"" + str.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return str
    }

    private static func formatNumber(_ v: Any) -> String {
        if let d = v as? Double {
            if d == d.rounded() && abs(d) >= 100 { return String(Int64(d)) }
            return String(format: "%.4f", d)
        }
        if let i = v as? Int { return String(i) }
        return String(describing: v)
    }

    // MARK: - 剪贴板

    static func copyJSON(bundles: [StockDataBundle]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(toJSON(bundles: bundles), forType: .string)
    }

    static func copyCSV(bundles: [StockDataBundle]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(toCSV(bundles: bundles), forType: .string)
    }
}
