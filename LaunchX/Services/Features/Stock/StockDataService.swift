import Foundation

// MARK: - 错误

enum StockError: LocalizedError {
    case noResult
    case invalidResponse
    case searchFailed(String)
    case multipleCandidates([StockSearchCandidate])
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noResult: return "未查询到该股票的数据"
        case .invalidResponse: return "数据源响应解析失败"
        case .searchFailed(let kw): return "未找到匹配「\(kw)」的股票"
        case .multipleCandidates: return "存在多个匹配，请用更精确的代码/名称"
        case .network(let msg): return "网络错误：\(msg)"
        }
    }
}

// MARK: - 数据服务

/// 股票数据获取服务。东财为主、新浪兜底；无共享可变状态，async 方法线程安全。
final class StockDataService {
    static let shared = StockDataService()
    private init() {}

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    private let ut = "fa5fd1943c7b386f172d6893dbfba10b"

    /// 带重试的 GET：代理/网络抖动（-1005 连接重置等）时退避重试 2 次；HTTP 状态错误不重试
    private func get(_ urlString: String, referer: String = "https://quote.eastmoney.com/")
        async throws -> Data
    {
        guard let url = URL(string: urlString) else { throw StockError.invalidResponse }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")

        var lastError: Error = StockError.network("未知网络错误")
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw StockError.network("HTTP \(http.statusCode)")
                }
                return data
            } catch let e as StockError {
                throw e
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
                }
            }
        }
        throw StockError.network(lastError.localizedDescription)
    }

    // MARK: - 搜索 / 解析 secid

    /// 名称→候选列表（东财 suggest）
    func search(name: String) async throws -> [StockSearchCandidate] {
        guard let enc = name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed)
        else { return [] }
        let url =
            "https://searchapi.eastmoney.com/api/suggest/get?input=\(enc)&type=14&token=D43BF722C8E33BDC906B84DFFE44B28F&count=8"
        let data = try await get(url, referer: "https://www.eastmoney.com/")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let table = json["QuotationCodeTable"] as? [String: Any],
            let arr = table["Data"] as? [[String: Any]]
        else { return [] }
        return arr.compactMap { StockDataService.candidate(from: $0) }
    }

    private static func candidate(from row: [String: Any]) -> StockSearchCandidate? {
        guard let quoteId = row["QuoteID"] as? String,
            let code = row["Code"] as? String,
            let nm = row["Name"] as? String
        else { return nil }
        // 只保留 A 股（QuoteID 形如 1.600519 / 0.000001）
        guard quoteId.hasPrefix("1.") || quoteId.hasPrefix("0.") else { return nil }
        let marketName = (row["SecurityTypeName"] as? String) ?? ""
        return StockSearchCandidate(code: code, name: nm, secid: quoteId, marketName: marketName)
    }

    /// 补全 query 的 secid/name/code；名称多匹配时抛 .multipleCandidates
    func resolve(_ query: StockQuery) async throws -> StockQuery {
        var q = query
        if q.secid == nil {
            // 代码直接判定 secid
            if let code = q.code {
                q.secid = StockQueryParser.isAShareCode(code)
                    ? secid(forCode: code) : nil
                q.name = q.name ?? code
            }
            if q.secid == nil {
                let keyword = q.name ?? q.input
                let candidates = try await search(name: keyword)
                // 精确代码命中优先
                if let exact = candidates.first(where: {
                    $0.code == keyword || $0.name == keyword
                }) {
                    q.secid = exact.secid
                    q.code = exact.code
                    q.name = exact.name
                } else if candidates.count == 1 {
                    q.secid = candidates[0].secid
                    q.code = candidates[0].code
                    q.name = candidates[0].name
                } else if candidates.isEmpty {
                    throw StockError.searchFailed(keyword)
                } else {
                    throw StockError.multipleCandidates(candidates)
                }
            }
        }
        return q
    }

    // MARK: - 实时快照（东财）

    func fetchSnapshot(secid: String) async throws -> StockSnapshot {
        let fields =
            "f43,f44,f45,f46,f47,f48,f50,f57,f58,f60,f84,f85,f116,f117,f162,f167,f168,f169,f170,f171"
        let url =
            "https://push2.eastmoney.com/api/qt/stock/get?secid=\(secid)&ut=\(ut)&fields=\(fields)"
        let data = try await get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let d = json["data"] as? [String: Any]
        else { throw StockError.invalidResponse }
        return parseSnapshot(d)
    }

    private func parseSnapshot(_ d: [String: Any]) -> StockSnapshot {
        func num(_ key: String) -> Double {
            if let v = d[key] as? Double { return v }
            return Double(d[key] as? Int ?? 0)
        }
        let code = (d["f57"] as? String) ?? ""
        let name = (d["f58"] as? String) ?? ""
        let price = num("f43") / 100
        let preClose = num("f60") / 100
        let open = num("f46") / 100
        let high = num("f44") / 100
        let low = num("f45") / 100
        let volume = num("f47")
        let amount = num("f48")
        let volumeRatio = num("f50") / 100
        let amplitude = num("f171") / 100
        let pctChange = num("f170") / 100
        let change = num("f169") / 100
        let totalMarketCap = num("f116")
        let circMarketCap = num("f117")
        let pe = num("f162") / 100
        let pb = num("f167") / 100
        let totalShares = num("f84")
        let circShares = num("f85")
        return StockSnapshot(
            code: code, name: name, date: todayString(),
            price: price, preClose: preClose, open: open, high: high, low: low,
            volume: volume, amount: amount, volumeRatio: volumeRatio,
            turnover: 0,  // 实时接口不含换手率，由历史 bar 回填
            amplitude: amplitude, pctChange: pctChange, change: change,
            totalMarketCap: totalMarketCap, circMarketCap: circMarketCap,
            pe: pe, pb: pb, totalShares: totalShares, circShares: circShares)
    }

    // MARK: - 历史日K（东财 kline）

    /// 取截止 end(yyyyMMdd 或 20500101) 的最近 lmt 根日K，升序
    func fetchHistory(secid: String, endYYYYMMdd: String, lmt: Int = 130) async throws -> [StockDailyBar] {
        let fields2 = "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"
        let url =
            "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=\(secid)&ut=\(ut)&fields1=f1,f2,f3,f4,f5,f6&fields2=\(fields2)&klt=101&fqt=1&beg=20000101&end=\(endYYYYMMdd)&lmt=\(lmt)"
        let data = try await get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let d = json["data"] as? [String: Any],
            let klines = d["klines"] as? [String]
        else { throw StockError.invalidResponse }
        return klines.compactMap { parseBar($0) }
    }

    /// 解析 "date,open,close,high,low,vol,amount,amplitude,pct,change,turnover"
    private func parseBar(_ row: String) -> StockDailyBar? {
        let p = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 11 else { return nil }
        func d(_ s: String) -> Double { Double(s) ?? 0 }
        return StockDailyBar(
            date: p[0], open: d(p[1]), close: d(p[2]), high: d(p[3]), low: d(p[4]),
            volume: d(p[5]), amount: d(p[6]), amplitude: d(p[7]), pctChange: d(p[8]),
            change: d(p[9]), turnover: d(p[10]))
    }

    // MARK: - 实时快照（新浪兜底）

    /// 新浪实时兜底：东财 push2 被限流/掐断时使用。
    /// 响应为 GBK 编码的 JS 变量，字段较少（无市值/PE/量比/换手率）。
    private func fetchSnapshotViaSina(secid: String) async -> StockSnapshot? {
        let parts = secid.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let prefix = parts[0] == "1" ? "sh" : "sz"
        let url = "https://hq.sinajs.cn/list=\(prefix)\(parts[1])"
        guard let data = try? await get(url, referer: "https://finance.sina.com.cn/")
        else { return nil }
        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: data, encoding: gbk) ?? String(data: data, encoding: .utf8),
            let quoted = text.split(separator: "\"").dropFirst().first
        else { return nil }
        // [0]名称 [1]今开 [2]昨收 [3]最新 [4]最高 [5]最低 … [8]成交量(股) [9]成交额 … [30]日期 [31]时间
        let f = quoted.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 32,
            let open = Double(f[1]), let preClose = Double(f[2]),
            let price = Double(f[3]), let high = Double(f[4]), let low = Double(f[5])
        else { return nil }
        return StockSnapshot(
            code: String(parts[1]), name: f[0], date: f[30],
            price: price, preClose: preClose, open: open, high: high, low: low,
            volume: (Double(f[8]) ?? 0) / 100,  // 股→手
            amount: Double(f[9]) ?? 0,
            volumeRatio: 0, turnover: 0,
            amplitude: preClose != 0 ? (high - low) / preClose * 100 : 0,
            pctChange: preClose != 0 ? (price - preClose) / preClose * 100 : 0,
            change: price - preClose,
            totalMarketCap: 0, circMarketCap: 0, pe: 0, pb: 0,
            totalShares: 0, circShares: 0)
    }

    // MARK: - 历史日K（新浪兜底）

    /// 新浪日K兜底：东财 push2his 在代理环境下可能被间歇性掐断连接。
    /// 返回字段较少（无成交额/换手率），涨跌幅/振幅由相邻收盘价推算。
    private func fetchHistoryViaSina(secid: String, targetDate: String?) async -> [StockDailyBar] {
        // secid "1.600519"→"sh600519"，"0.000001"→"sz000001"
        let parts = secid.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return [] }
        let prefix = parts[0] == "1" ? "sh" : "sz"
        let symbol = "\(prefix)\(parts[1])"
        let url =
            "https://quotes.sina.cn/cn/api/json_v2.php/CN_MarketDataService.getKLineData?symbol=\(symbol)&scale=240&ma=no&datalen=250"
        guard let data = try? await get(url, referer: "https://finance.sina.com.cn/"),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var bars: [StockDailyBar] = []
        var prevClose: Double? = nil
        for row in arr {
            guard let day = row["day"] as? String,
                let closeStr = row["close"] as? String,
                let close = Double(closeStr)
            else { continue }
            let open = Double(row["open"] as? String ?? "") ?? close
            let high = Double(row["high"] as? String ?? "") ?? close
            let low = Double(row["low"] as? String ?? "") ?? close
            let volume = (Double(row["volume"] as? String ?? "") ?? 0) / 100  // 股→手
            let pc = prevClose
            bars.append(
                StockDailyBar(
                    date: String(day.prefix(10)), open: open, close: close, high: high, low: low,
                    volume: volume, amount: 0,
                    amplitude: pc.map { ($0 != 0) ? (high - low) / $0 * 100 : 0 } ?? 0,
                    pctChange: pc.map { ($0 != 0) ? (close - $0) / $0 * 100 : 0 } ?? 0,
                    change: pc.map { close - $0 } ?? 0,
                    turnover: 0))
            prevClose = close
        }
        // 历史日期：截取 ≤ target 的部分
        if let target = targetDate {
            bars = bars.filter { $0.date <= target }
        }
        return bars
    }

    // MARK: - 资金流（东财 fflow）

    /// 取最近 lmt 日资金流。字段顺序（实测 f51..f65）：
    /// [0]日期 [1]主力 [2]小单 [3]中单 [4]大单 [5]超大单 [6]主力占比 ...
    func fetchCapitalFlow(secid: String, lmt: Int = 30) async -> [StockCapitalFlow] {
        let fields2 = "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63,f64,f65"
        let url =
            "https://push2his.eastmoney.com/api/qt/stock/fflow/daykline/get?secid=\(secid)&lmt=\(lmt)&klt=101&fields1=f1,f2,f3,f7&fields2=\(fields2)"
        guard let data = try? await get(url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let d = json["data"] as? [String: Any],
            let klines = d["klines"] as? [String]
        else { return [] }
        return klines.compactMap { parseFlow($0) }
    }

    private func parseFlow(_ row: String) -> StockCapitalFlow? {
        let p = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 7 else { return nil }
        func d(_ s: String) -> Double { Double(s) ?? 0 }
        return StockCapitalFlow(
            date: p[0], main: d(p[1]), small: d(p[2]), medium: d(p[3]),
            large: d(p[4]), superLarge: d(p[5]), mainPct: d(p[6]))
    }

    // MARK: - 基本面（东财 F10，best-effort）

    func fetchFundamentals(code: String) async -> StockFundamentals? {
        // F10 资料接口字段较多且易变，这里做宽松解析；失败返回 nil 不影响主流程
        let prefix = code.first.map(String.init) ?? ""
        let market = (prefix == "6" || prefix == "9") ? "SH" : "SZ"
        let url =
            "https://emweb.securities.eastmoney.com/PC_HSF10/CompanySurvey/PageAjax?code=\(market)\(code)"
        guard let data = try? await get(url, referer: "https://emweb.securities.eastmoney.com/"),
            let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // F10 结构复杂，先返回空壳占位；后续按实际字段补全行业/股本/PE 等
        return StockFundamentals(
            industry: nil, listingDate: nil, totalShares: nil, circShares: nil,
            pe: nil, pb: nil, totalMarketCap: nil, circMarketCap: nil)
    }

    // MARK: - 聚合

    /// 一次查询聚合全部数据
    func fetchBundle(_ query: StockQuery) async throws -> StockDataBundle {
        let resolved = try await resolve(query)
        guard let secid = resolved.secid, let code = resolved.code else {
            throw StockError.noResult
        }

        let endStr: String
        if let date = resolved.targetDate {
            endStr = date.replacingOccurrences(of: "-", with: "")
        } else {
            endStr = "20500101"
        }

        async let flows = fetchCapitalFlow(secid: secid, lmt: 30)
        async let fundamentals = fetchFundamentals(code: code)

        // 历史：东财优先；push2his 在代理环境下可能被间歇性掐断，失败时用新浪兜底
        var bars: [StockDailyBar] = []
        var historyNote: String? = nil
        do {
            bars = try await fetchHistory(secid: secid, endYYYYMMdd: endStr, lmt: 250)
        } catch {
            bars = await fetchHistoryViaSina(secid: secid, targetDate: resolved.targetDate)
            if !bars.isEmpty {
                historyNote = "东财历史接口失败，已用新浪兜底（成交额/换手率缺失）"
            }
        }
        let capitalFlows = await flows
        let fundamentalsVal = await fundamentals

        // 双源都失败：若实时快照可用则降级展示（无技术指标），否则报错
        if bars.isEmpty {
            if resolved.targetDate == nil {
                var s = try? await fetchSnapshot(secid: secid)
                var degradeNote = "历史K线获取失败，技术指标不可用"
                if s == nil {
                    s = await fetchSnapshotViaSina(secid: secid)
                    degradeNote = "东财接口不可用，仅展示新浪实时行情，技术指标不可用"
                }
                if let s = s {
                    return StockDataBundle(
                        input: resolved.input, code: code, name: resolved.name ?? code,
                        secid: secid, targetDate: nil,
                        snapshot: s, indicators: nil, bars: [],
                        capitalFlows: capitalFlows, fundamentals: fundamentalsVal,
                        note: degradeNote)
                }
            }
            throw StockError.noResult
        }

        // 指标：基于回看窗口
        let indicators = StockIndicatorCalculator.compute(bars: bars)

        // 快照：目标日期为空或 ≥ 今天时按「最新」处理（走实时接口，可拿到量比/市值/PE）
        let snapshot: StockSnapshot?
        var note = historyNote
        let isLatest = resolved.targetDate.map { $0 >= todayString() } ?? true
        if isLatest {
            do {
                var s = try await fetchSnapshot(secid: secid)
                // 换手率：实时接口不含，优先用东财 bar 回填，其次用 流通股本 反推
                var turnover: Double? = nil
                if let todayBar = bars.last, todayBar.turnover > 0 {
                    turnover = todayBar.turnover
                } else if s.turnover == 0, s.circShares > 0, s.volume > 0 {
                    turnover = s.volume * 100 / s.circShares * 100  // volume 手→股
                }
                // 量比：缺失时用 当日量/前5日均量 近似
                let vr = s.volumeRatio == 0 ? approxVolumeRatio(bars: bars) : nil
                if turnover != nil || vr != nil {
                    s = snapshotWithTurnover(s, turnover: turnover ?? s.turnover, volumeRatio: vr)
                }
                snapshot = s
            } catch {
                if var s = await fetchSnapshotViaSina(secid: secid) {
                    let vr = s.volumeRatio == 0 ? approxVolumeRatio(bars: bars) : nil
                    if let vr = vr { s = snapshotWithTurnover(s, turnover: s.turnover, volumeRatio: vr) }
                    snapshot = s
                    note = (note.map { $0 + "；" } ?? "")
                        + "东财实时接口失败，已用新浪实时数据（市值/PE 不可用）"
                } else {
                    snapshot = bars.last.map {
                        snapshotFromBar($0, code: code, name: resolved.name ?? code,
                            volumeRatio: approxVolumeRatio(bars: bars))
                    }
                    note = (note.map { $0 + "；" } ?? "") + "实时接口失败，已用最近收盘数据"
                }
            }
        } else {
            // 历史日：取 ≤ target 的最后一根构造快照（盘中字段不可用，量比用近似值）
            let target = resolved.targetDate!
            let bar = bars.last(where: { $0.date <= target }) ?? bars.last
            snapshot = bar.map { b in
                snapshotFromBar(b, code: code, name: resolved.name ?? code,
                    volumeRatio: approxVolumeRatio(bars: bars))
            }
            if note == nil { note = "历史日期：实时市值等盘中字段不可用" }
        }

        return StockDataBundle(
            input: resolved.input, code: code, name: resolved.name ?? code,
            secid: secid, targetDate: resolved.targetDate,
            snapshot: snapshot, indicators: indicators,
            bars: Array(bars.suffix(20)),  // 仅保留近 20 日供 AI 看趋势，控制体积
            capitalFlows: capitalFlows, fundamentals: fundamentalsVal, note: note,
            chartBars: bars)
    }

    private func snapshotFromBar(
        _ b: StockDailyBar, code: String, name: String, volumeRatio: Double = 0
    ) -> StockSnapshot {
        StockSnapshot(
            code: code, name: name, date: b.date,
            price: b.close, preClose: b.close - b.change, open: b.open,
            high: b.high, low: b.low, volume: b.volume, amount: b.amount,
            volumeRatio: volumeRatio, turnover: b.turnover, amplitude: b.amplitude,
            pctChange: b.pctChange, change: b.change,
            totalMarketCap: 0, circMarketCap: 0, pe: 0, pb: 0,
            totalShares: 0, circShares: 0)
    }

    private func snapshotWithTurnover(
        _ s: StockSnapshot, turnover: Double, volumeRatio: Double? = nil
    ) -> StockSnapshot {
        StockSnapshot(
            code: s.code, name: s.name, date: s.date, price: s.price,
            preClose: s.preClose, open: s.open, high: s.high, low: s.low,
            volume: s.volume, amount: s.amount, volumeRatio: volumeRatio ?? s.volumeRatio,
            turnover: turnover, amplitude: s.amplitude, pctChange: s.pctChange,
            change: s.change, totalMarketCap: s.totalMarketCap,
            circMarketCap: s.circMarketCap, pe: s.pe, pb: s.pb,
            totalShares: s.totalShares, circShares: s.circShares)
    }

    /// 量比近似：当日成交量 / 前 5 日平均成交量。
    /// 真实量比按分钟级折算（盘中动态），收盘后两者基本一致。
    private func approxVolumeRatio(bars: [StockDailyBar]) -> Double {
        guard bars.count >= 6 else { return 0 }
        let prev = bars.suffix(6).dropLast()
        let avg = prev.reduce(0.0) { $0 + $1.volume } / Double(prev.count)
        guard avg > 0, let last = bars.last else { return 0 }
        return last.volume / avg
    }

    // MARK: - 辅助

    private func secid(forCode code: String) -> String {
        let prefix = code.first.map(String.init) ?? ""
        switch prefix {
        case "6", "9": return "1.\(code)"
        default: return "0.\(code)"
        }
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date())
    }
}
