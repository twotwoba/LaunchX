import Foundation

// MARK: - 查询

/// 一次股票查询（代码/名称 + 可选日期）
struct StockQuery: Hashable {
    /// 用户输入的原始 token（可能是代码或名称）
    var input: String
    /// 解析出的 6 位代码（若可判定），否则为 nil 需走名称搜索
    var code: String?
    /// 已解析出的 secid（市场.代码，如 "1.600519"）
    var secid: String?
    /// 解析出的名称（搜索或快照后回填）
    var name: String?
    /// 目标日期 yyyy-MM-dd（nil 表示最新交易日）
    var targetDate: String?
}

// MARK: - 历史日K

/// 单根日K（前复权），单位：价格=元，volume=手，amount=元，百分比=%
struct StockDailyBar: Codable, Hashable {
    let date: String  // yyyy-MM-dd
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    let volume: Double  // 成交量(手)
    let amount: Double  // 成交额(元)
    let amplitude: Double  // 振幅(%)
    let pctChange: Double  // 涨跌幅(%)
    let change: Double  // 涨跌额(元)
    let turnover: Double  // 换手率(%)
}

// MARK: - 实时快照

/// 个股实时（或当日收盘）快照
struct StockSnapshot: Codable, Hashable {
    let code: String
    let name: String
    let date: String  // yyyy-MM-dd
    let price: Double  // 最新价(元)
    let preClose: Double  // 昨收(元)
    let open: Double  // 今开(元)
    let high: Double  // 最高(元)
    let low: Double  // 最低(元)
    let volume: Double  // 成交量(手)
    let amount: Double  // 成交额(元)
    let volumeRatio: Double  // 量比
    let turnover: Double  // 换手率(%)
    let amplitude: Double  // 振幅(%)
    let pctChange: Double  // 涨跌幅(%)
    let change: Double  // 涨跌额(元)
    let totalMarketCap: Double  // 总市值(元)
    let circMarketCap: Double  // 流通市值(元)
    let pe: Double  // 市盈率(动)
    let pb: Double  // 市净率
    let totalShares: Double  // 总股本(股)
    let circShares: Double  // 流通股本(股)
}

// MARK: - 资金流

/// 单日资金流向（主力/超大/大/中/小单净流入，单位：元）
struct StockCapitalFlow: Codable, Hashable {
    let date: String  // yyyy-MM-dd
    let main: Double  // 主力净流入(元)
    let small: Double  // 小单净流入(元)
    let medium: Double  // 中单净流入(元)
    let large: Double  // 大单净流入(元)
    let superLarge: Double  // 超大单净流入(元)
    let mainPct: Double  // 主力净流入占比(%)
}

// MARK: - 基本面

/// 个股基本面（字段宽松，缺失为 nil，随数据源字段对齐逐步完善）
struct StockFundamentals: Codable, Hashable {
    var industry: String?  // 所属行业
    var listingDate: String?  // 上市日期
    var totalShares: Double?  // 总股本(股)
    var circShares: Double?  // 流通股本(股)
    var pe: Double?  // 市盈率
    var pb: Double?  // 市净率
    var totalMarketCap: Double?  // 总市值(元)
    var circMarketCap: Double?  // 流通市值(元)
}

// MARK: - 技术指标（针对目标日期计算）

/// MACD 指标
struct StockMACD: Codable, Hashable {
    let dif: Double
    let dea: Double
    let macd: Double  // 柱状(=(DIF-DEA)*2)
}

/// KDJ 指标
struct StockKDJ: Codable, Hashable {
    let k: Double
    let d: Double
    let j: Double
}

/// 均线与布林带
struct StockMA: Codable, Hashable {
    let ma5: Double?
    let ma10: Double?
    let ma20: Double?
    let ma60: Double?
    let bollUpper: Double?
    let bollMid: Double?
    let bollLower: Double?
}

/// 单只股票在某目标日的全部技术指标
struct StockIndicators: Codable, Hashable {
    let macd: StockMACD?
    let kdj: StockKDJ?
    let ma: StockMA
}

// MARK: - 数据聚合包

/// 一次查询聚合到的全部数据（用于展示 / 导出 / 喂给 AI）
struct StockDataBundle: Codable, Hashable, Identifiable {
    let id: UUID
    let input: String  // 原始输入
    let code: String
    let name: String
    let secid: String
    let targetDate: String?  // nil=最新
    let snapshot: StockSnapshot?
    let indicators: StockIndicators?
    let bars: [StockDailyBar]  // 回看窗口（用于 AI 看趋势）
    let capitalFlows: [StockCapitalFlow]
    let fundamentals: StockFundamentals?
    let note: String?  // 缺失/降级提示

    init(
        id: UUID = UUID(), input: String, code: String, name: String, secid: String,
        targetDate: String?, snapshot: StockSnapshot?, indicators: StockIndicators?,
        bars: [StockDailyBar], capitalFlows: [StockCapitalFlow],
        fundamentals: StockFundamentals?, note: String? = nil
    ) {
        self.id = id
        self.input = input
        self.code = code
        self.name = name
        self.secid = secid
        self.targetDate = targetDate
        self.snapshot = snapshot
        self.indicators = indicators
        self.bars = bars
        self.capitalFlows = capitalFlows
        self.fundamentals = fundamentals
        self.note = note
    }
}

// MARK: - 搜索候选

/// 名称搜索的候选结果
struct StockSearchCandidate: Hashable {
    let code: String  // 6 位代码
    let name: String
    let secid: String  // 市场.代码
    let marketName: String  // 沪A/深A 等
}
