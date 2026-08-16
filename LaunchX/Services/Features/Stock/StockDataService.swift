import Foundation

// MARK: - 错误

enum StockError: LocalizedError {
    case noResult
    case invalidResponse
    case searchFailed(String)
    case multipleCandidates([StockSearchCandidate])
    case network(String)
    case intradayOutOfRange(String)

    var errorDescription: String? {
        switch self {
        case .noResult: return "未查询到该股票的数据"
        case .invalidResponse: return "数据源响应解析失败"
        case .searchFailed(let kw): return "未找到匹配「\(kw)」的股票"
        case .multipleCandidates: return "存在多个匹配，请用更精确的代码/名称"
        case .network(let msg): return "网络错误：\(msg)"
        case .intradayOutOfRange(let day): return "「\(day)」分时数据获取失败（zzshare 限流或超出覆盖范围，稍后重试或减少连开频率）"
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

    /// 某日历史分时内存缓存（key "secid|date"）。zzshare 匿名限频严格且 429 封禁窗口
    /// 远长于 Retry-After，重复打开同一天不应再发起网络请求。历史分时不可变，
    /// 进程内缓存即可；当日实时分时不缓存（盘中会更新）。超量整批清空防膨胀。
    private let intradayCacheLock = NSLock()
    private var intradayCache: [String: [StockTrendPoint]] = [:]

    /// 带重试的 GET：代理/网络抖动（-1005 连接重置等）时退避重试 2 次；HTTP 状态错误不重试
    private func get(_ urlString: String, referer: String = "https://gu.qq.com/")
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

    /// 名称→候选列表（腾讯 smartbox，GBK）。响应形如
    /// `v_hint="sh~600519~贵州茅台~gzmt~GP-A^sz~000589~贵州轮胎~gzlt~GP-A^..."`
    func search(name: String) async throws -> [StockSearchCandidate] {
        guard let enc = name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed)
        else { return [] }
        let url = "https://smartbox.gtimg.cn/s3/?v=2&q=\(enc)&t=all"
        let data = try await get(url)
        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: data, encoding: gbk) ?? String(data: data, encoding: .utf8),
            let quoted = text.split(separator: "\"").dropFirst().first
        else { return [] }
        return quoted.split(separator: "^").compactMap { entry -> StockSearchCandidate? in
            let f = entry.split(separator: "~").map(String.init)
            guard f.count >= 5 else { return nil }
            let (market, code, type) = (f[0], f[1], f[4])
            // 只保留 A 股（GP-A），过滤港美/指数/板块
            guard type == "GP-A", market == "sh" || market == "sz" else { return nil }
            return StockSearchCandidate(
                code: code, name: Self.unescapeUnicode(f[2]),
                secid: (market == "sh" ? "1." : "0.") + code,
                marketName: market == "sh" ? "沪A" : "深A")
        }
    }

    /// smartbox 的中文名是 `贵州` 形式的转义，解码为 UTF-8
    private static func unescapeUnicode(_ s: String) -> String {
        guard s.contains("\\u") else { return s }
        var result = ""
        var rest = Substring(s)
        while let r = rest.range(of: "\\u") {
            result += rest[..<r.lowerBound]
            let hex = rest[r.upperBound...].prefix(4)
            if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                result.unicodeScalars.append(scalar)
                rest = rest[r.upperBound...].dropFirst(4)
            } else {
                result += "\\u"
                rest = rest[r.upperBound...]
            }
        }
        return result + rest
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

    // MARK: - 实时快照（腾讯 qt）

    /// 腾讯实时行情：`v_sh600519="1~贵州茅台~600519~最新价~昨收~今开~量(手)~…"`
    /// 字段索引（按 ~ 分割后）：1名称 2代码 3价 4昨收 5今开 6量(手) 30时间
    /// 31涨跌 32涨跌% 33高 34低 36量(手) 37额(万) 38换手% 39PE 43振幅%
    /// 44流通市值(亿) 45总市值(亿) 46PB 49量比。GBK 编码
    func fetchSnapshot(secid: String) async throws -> StockSnapshot {
        guard let symbol = marketSymbol(secid: secid) else { throw StockError.invalidResponse }
        let url = "https://qt.gtimg.cn/q=\(symbol)"
        let data = try await get(url)
        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: data, encoding: gbk) ?? String(data: data, encoding: .utf8),
            let start = text.firstIndex(of: "~")
        else { throw StockError.invalidResponse }
        let f = text[start...].split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        func d(_ i: Int) -> Double { i < f.count ? (Double(f[i]) ?? 0) : 0 }
        guard f.count > 49, d(3) > 0 else { throw StockError.invalidResponse }
        let price = d(3)
        let rawDate = f.count > 30 ? f[30] : ""  // "20260814161500"
        var date = todayString()
        if rawDate.count >= 8 {
            let s = rawDate.prefix(8)
            date = "\(s.prefix(4))-\(s.dropFirst(4).prefix(2))-\(s.dropFirst(6).prefix(2))"
        }
        let circCap = d(44) * 1e8, totalCap = d(45) * 1e8
        return StockSnapshot(
            code: f.count > 2 ? f[2] : "", name: f.count > 1 ? f[1] : "", date: date,
            price: price, preClose: d(4), open: d(5), high: d(33), low: d(34),
            volume: d(36), amount: d(37) * 1e4,  // 万→元
            volumeRatio: d(49),
            turnover: d(38),
            amplitude: d(43), pctChange: d(32), change: d(31),
            totalMarketCap: totalCap, circMarketCap: circCap,
            pe: d(39), pb: d(46),
            totalShares: price > 0 ? totalCap / price : 0,
            circShares: price > 0 ? circCap / price : 0)
    }

    // MARK: - 历史日K（腾讯 fqkline）

    /// 取截止 end(yyyyMMdd 或 20500101) 的最近 lmt 根日K（前复权），升序。
    /// 腾讯行格式 [日期,开,收,高,低,量(手)]，无成交额/换手率，涨跌幅/振幅由昨收推算
    func fetchHistory(secid: String, endYYYYMMdd: String, lmt: Int = 130) async throws -> [StockDailyBar] {
        guard let symbol = marketSymbol(secid: secid) else { throw StockError.invalidResponse }
        let count = min(max(lmt, 5), 800)  // 腾讯单次上限 800 根（约 3.3 年）
        // 带日期查询必须把截止日传给服务端（横杠格式），否则只返回最近 N 根，
        // 历史日双击分时时会因当天不在日K窗口里而丢失昨收（涨跌幅/零轴消失）
        let endParam: String
        if endYYYYMMdd < "20500101", endYYYYMMdd.count == 8 {
            endParam = "\(endYYYYMMdd.prefix(4))-\(endYYYYMMdd.dropFirst(4).prefix(2))-\(endYYYYMMdd.dropFirst(6).prefix(2))"
        } else {
            endParam = ""
        }
        let url = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(symbol),day,,\(endParam),\(count),qfq"
        let data = try await get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let node = (json["data"] as? [String: Any])?[symbol] as? [String: Any],
            let rows = (node["qfqday"] as? [[Any]]) ?? (node["day"] as? [[Any]])
        else { throw StockError.invalidResponse }

        let endDate = endParam.isEmpty ? nil : endParam
        var bars: [StockDailyBar] = []
        var prevClose: Double? = nil
        for row in rows {
            guard row.count >= 6,
                let date = row[0] as? String,
                let open = Double(row[1] as? String ?? ""),
                let close = Double(row[2] as? String ?? ""),
                let high = Double(row[3] as? String ?? ""),
                let low = Double(row[4] as? String ?? ""),
                let volume = Double(row[5] as? String ?? "")
            else { continue }
            if let end = endDate, date > end { continue }
            let pc = prevClose
            bars.append(
                StockDailyBar(
                    date: date, open: open, close: close, high: high, low: low,
                    volume: volume, amount: 0,
                    amplitude: pc.map { $0 != 0 ? (high - low) / $0 * 100 : 0 } ?? 0,
                    pctChange: pc.map { $0 != 0 ? (close - $0) / $0 * 100 : 0 } ?? 0,
                    change: pc.map { close - $0 } ?? 0,
                    turnover: 0))
            prevClose = close
        }
        guard !bars.isEmpty else { throw StockError.invalidResponse }
        return Array(bars.suffix(lmt))
    }

    // MARK: - 某日分时（多源逐级兜底）

    /// 某日分时：先查内存缓存（历史分时不可变），未命中走多源兜底链，
    /// 成功且非当日的结果写入缓存。forceRefresh = true 时丢弃缓存重走兜底链
    /// （用于兜底拿到粗粒度分时后手动刷新，重试 zzshare 1 分钟源）。
    func fetchIntraday(secid: String, date: String, forceRefresh: Bool = false) async throws
        -> [StockTrendPoint]
    {
        let key = "\(secid)|\(date)"
        intradayCacheLock.lock()
        let cached = forceRefresh ? nil : intradayCache[key]
        if forceRefresh { intradayCache.removeValue(forKey: key) }
        intradayCacheLock.unlock()
        if let cached { return cached }

        let points = try await fetchIntradayRemote(secid: secid, date: date)

        let isToday = Self.dayFormatter.string(from: Date()) == date
        if !isToday {
            intradayCacheLock.lock()
            if intradayCache.count >= 64 { intradayCache.removeAll(keepingCapacity: true) }
            intradayCache[key] = points
            intradayCacheLock.unlock()
        }
        return points
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 某日分时（多源逐级兜底，越靠前粒度越细）：
    /// 腾讯 minute/query（当日1分钟）→ 新浪 scale=1（1分钟，约9个交易日，不耗 zzshare 配额）→
    /// zzshare 1分钟（历史回溯约2015年，匿名限频 30 次/分钟）→
    /// 新浪分钟K阶梯 scale=5/15/30（约42/124/247个交易日）→
    /// 腾讯 mkline m5/m15/m30/m60（以上全挂时兜底，最远约200个交易日）
    private func fetchIntradayRemote(secid: String, date: String) async throws -> [StockTrendPoint] {
        do {
            let points = try await fetchTencentMinute(secid: secid, date: date)
            if !points.isEmpty { return points }
        } catch {
            logIntradayFallback("腾讯minute", error)
        }
        // 近 9 个交易日用新浪 1 分钟（与 zzshare 同粒度且无限频），省下 zzshare 配额给更早的历史日
        do {
            let points = try await fetchIntradayViaSina(secid: secid, date: date, scale: 1)
            if !points.isEmpty { return points }
        } catch {
            logIntradayFallback("新浪scale=1", error)
        }
        do {
            let points = try await fetchIntradayViaZZShare(secid: secid, date: date)
            if !points.isEmpty { return points }
        } catch {
            logIntradayFallback("zzshare", error)
        }
        for scale in [5, 15, 30] {
            do {
                let points = try await fetchIntradayViaSina(secid: secid, date: date, scale: scale)
                if !points.isEmpty { return points }
            } catch {
                logIntradayFallback("新浪scale=\(scale)", error)
            }
        }
        for scale in ["m5", "m15", "m30", "m60"] {
            do {
                let points = try await fetchMinuteBarsViaTencent(secid: secid, date: date, scale: scale)
                if !points.isEmpty { return points }
            } catch {
                logIntradayFallback("腾讯mkline \(scale)", error)
            }
        }
        throw StockError.intradayOutOfRange(date)
    }

    /// 兜底链每级的失败原因打到控制台：静默吞错会让「某天分时粒度突然变粗」无从排查
    private func logIntradayFallback(_ source: String, _ error: Error) {
        print("[Stock] 分时兜底 \(source) 失败: \(error.localizedDescription)")
    }

    /// "1.600519" → "sh600519"（新浪/腾讯通用行情代码）
    private func marketSymbol(secid: String) -> String? {
        let parts = secid.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let prefix = parts[0] == "1" ? "sh" : "sz"
        return "\(prefix)\(parts[1])"
    }

    /// 是否连续竞价时段（含收盘 11:30/15:00）：腾讯 minute/query 会带出
    /// 盘后固定价格交易（如 15:06–15:30），不过滤会导致分时图时间轴延伸到 15:30
    private static func isRegularTradingMinute(_ hhmm: Int) -> Bool {
        (930...1130).contains(hhmm) || (1300...1500).contains(hhmm)
    }

    /// 腾讯 minute/query：当日 1 分钟分时。"0930 1355.00 227 30758500.00" = HHmm 价 累计量(手) 累计额(元)
    private func fetchTencentMinute(secid: String, date: String) async throws -> [StockTrendPoint] {
        guard let symbol = marketSymbol(secid: secid) else { throw StockError.invalidResponse }
        let compact = date.replacingOccurrences(of: "-", with: "")
        let url = "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(symbol)"
        let data = try await get(url, referer: "https://gu.qq.com/")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let node = (json["data"] as? [String: Any])?[symbol] as? [String: Any],
            let dayNode = node["data"] as? [String: Any],
            let rows = dayNode["data"] as? [String],
            let dayRaw = dayNode["date"] as? String,
            dayRaw == compact
        else { throw StockError.invalidResponse }

        var out: [StockTrendPoint] = []
        var prevPrice: Double? = nil
        var prevCumVol = 0.0, prevCumAmt = 0.0
        var high = -Double.greatestFiniteMagnitude, low = Double.greatestFiniteMagnitude
        for row in rows {
            let p = row.split(separator: " ").map(String.init)
            guard p.count >= 4, let hhmm = Int(p[0]),
                Self.isRegularTradingMinute(hhmm),
                let price = Double(p[1]),
                let cumVol = Double(p[2]), let cumAmt = Double(p[3])
            else { continue }
            let minuteVol = max(0, cumVol - prevCumVol)  // 手
            let minuteAmt = max(0, cumAmt - prevCumAmt)  // 元
            prevCumVol = cumVol
            prevCumAmt = cumAmt
            high = max(high, price)
            low = min(low, price)
            let avg = cumVol > 0 ? cumAmt / (cumVol * 100) : price  // 累计额 / 累计股数
            out.append(
                StockTrendPoint(
                    time: "\(date) \(p[0].prefix(2)):\(p[0].suffix(2))",
                    open: prevPrice ?? price, high: high, low: low,
                    price: price, avgPrice: avg,
                    volume: minuteVol, amount: minuteAmt))
            prevPrice = price
        }
        return out
    }

    /// 首点为 09:31（bar 结束打戳）时，在最前补一个 09:30 集合竞价点（价格=首点开盘价，
    /// 量额 0 不影响均价/总量），让横轴从 9:30 起，与当日分时口径一致
    private static func prependingOpenAuctionPoint(_ points: [StockTrendPoint]) -> [StockTrendPoint] {
        guard let first = points.first, first.time.count >= 16 else { return points }
        let hm = String(first.time.dropFirst(11).prefix(5))  // "yyyy-MM-dd " 后的 HH:mm
        guard hm == "09:31" else { return points }
        let open = first.open
        let t0 = String(first.time.prefix(11)) + "09:30"
            + (first.time.count > 16 ? ":00" : "")  // 保留 "yyyy-MM-dd " 前缀与秒位格式
        return [StockTrendPoint(
            time: t0, open: open, high: open, low: open,
            price: open, avgPrice: open, volume: 0, amount: 0)] + points
    }

    /// zzshare（自在量化）1 分钟K → 当日分时点。匿名即可调（限频 30 次/分钟），
    /// 历史回溯约 2015 年起。行格式 {trade_time:"YYYYMMDDHHmm", open, high, low, close, vol(股), amount(元)}
    private func fetchIntradayViaZZShare(secid: String, date: String) async throws -> [StockTrendPoint] {
        let parts = secid.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { throw StockError.invalidResponse }
        let suffix = parts[0] == "1" ? "SH" : "SZ"
        let compact = date.replacingOccurrences(of: "-", with: "")
        let url =
            "https://api.zizizaizai.com/v3/market/kline/minute/\(parts[1]).\(suffix)?freq=1min&trade_time=\(compact)"
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // 默认匿名（限频 30 次/分钟）；注册免费 token 后可写入 UserDefaults 提额：
        // defaults write <bundleid> zzshare_sdk_key <token>（token 见 quant.zizizaizai.com/me/profile）
        req.setValue(
            UserDefaults.standard.string(forKey: "zzshare_sdk_key") ?? "anonymous",
            forHTTPHeaderField: "sdk-key")

        // 匿名限频 30 次/分钟，超限返回 429 + Retry-After(秒)。连续开多个分时窗口
        // 很容易触发，等待后重试最多两轮；其余失败快速重试一次
        var data: Data? = nil
        for attempt in 0..<3 {
            do {
                let (d, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                if http?.statusCode == 429, attempt < 2 {
                    let wait = min(Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10, 12)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                guard let h = http, (200...299).contains(h.statusCode) else { throw StockError.invalidResponse }
                data = d
                break
            } catch {
                if attempt >= 1 { throw error }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard let payload = data,
            let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            (json["code"] as? Int) == 200,
            let list = (json["data"] as? [String: Any])?["list"] as? [[String: Any]]
        else { throw StockError.invalidResponse }

        var sumVolShares = 0.0, sumAmount = 0.0
        var out: [StockTrendPoint] = []
        for row in list {
            guard let ts = row["trade_time"] as? String, ts.count == 12,
                let close = row["close"] as? Double
            else { continue }
            let open = row["open"] as? Double ?? close
            let high = row["high"] as? Double ?? close
            let low = row["low"] as? Double ?? close
            let volShares = row["vol"] as? Double ?? 0  // 股
            let amount = row["amount"] as? Double ?? 0  // 元
            sumVolShares += volShares
            sumAmount += amount
            let avg = sumVolShares > 0 ? sumAmount / sumVolShares : close
            out.append(
                StockTrendPoint(
                    time: "\(ts.prefix(4))-\(ts.dropFirst(4).prefix(2))-\(ts.dropFirst(6).prefix(2)) "
                        + "\(ts.dropFirst(8).prefix(2)):\(ts.dropFirst(10).prefix(2))",
                    open: open, high: high, low: low,
                    price: close, avgPrice: avg,
                    volume: volShares / 100, amount: amount))
        }
        return Self.prependingOpenAuctionPoint(out)
    }

    /// 新浪分钟K → 当日分时点（datalen=1970，scale=1/5/15/30 约覆盖 9/42/124/247 个交易日；
    /// 含成交额 → 真实均价；目标日超出覆盖返回空数组，由调用方降级到下一档）
    private func fetchIntradayViaSina(secid: String, date: String, scale: Int) async throws -> [StockTrendPoint] {
        guard let symbol = marketSymbol(secid: secid) else { throw StockError.invalidResponse }
        let url =
            "https://quotes.sina.cn/cn/api/json_v2.php/CN_MarketDataService.getKLineData?symbol=\(symbol)&scale=\(scale)&ma=no&datalen=1970"
        let data = try await get(url, referer: "https://finance.sina.com.cn/")
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw StockError.invalidResponse }
        var sumAmount = 0.0, sumVolShares = 0.0
        var out: [StockTrendPoint] = []
        for row in arr {
            guard let day = row["day"] as? String, String(day.prefix(10)) == date,
                let closeStr = row["close"] as? String,
                let close = Double(closeStr)
            else { continue }
            let open = Double(row["open"] as? String ?? "") ?? close
            let high = Double(row["high"] as? String ?? "") ?? close
            let low = Double(row["low"] as? String ?? "") ?? close
            let volShares = Double(row["volume"] as? String ?? "") ?? 0  // 股
            let amount = Double(row["amount"] as? String ?? "") ?? 0  // 元
            sumVolShares += volShares
            sumAmount += amount
            let avg = sumVolShares > 0 ? sumAmount / sumVolShares : close
            out.append(
                StockTrendPoint(
                    time: day, open: open, high: high, low: low,
                    price: close, avgPrice: avg,
                    volume: volShares / 100, amount: amount))
        }
        // 新浪 1 分钟K按 bar 结束时间打戳（首根 09:31 覆盖 09:30–09:31 的成交），
        // 补一个 09:30 集合竞价点让横轴与当日分时一致从 9:30 起
        return scale == 1 ? Self.prependingOpenAuctionPoint(out) : out
    }

    /// 腾讯 mkline：5/15/30/60 分钟K（[时间,开,收,高,低,量(手)]，无额 → 均价用典型价近似）
    private func fetchMinuteBarsViaTencent(secid: String, date: String, scale: String) async throws
        -> [StockTrendPoint]
    {
        guard let symbol = marketSymbol(secid: secid) else { throw StockError.invalidResponse }
        let url = "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(symbol),\(scale),,800"
        let data = try await get(url, referer: "https://gu.qq.com/")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let node = (json["data"] as? [String: Any])?[symbol] as? [String: Any],
            let bars = node[scale] as? [[Any]]
        else { throw StockError.invalidResponse }
        let compact = date.replacingOccurrences(of: "-", with: "")
        var sumPV = 0.0, sumV = 0.0
        var out: [StockTrendPoint] = []
        for bar in bars {
            guard let ts = bar[0] as? String, String(ts.prefix(8)) == compact, bar.count >= 6,
                let open = Double(bar[1] as? String ?? ""),
                let close = Double(bar[2] as? String ?? ""),
                let high = Double(bar[3] as? String ?? ""),
                let low = Double(bar[4] as? String ?? ""),
                let volume = Double(bar[5] as? String ?? "")  // 手
            else { continue }
            let typical = (high + low + close) / 3
            sumPV += typical * volume * 100
            sumV += volume * 100
            let avg = sumV > 0 ? sumPV / sumV : close
            out.append(
                StockTrendPoint(
                    time: "\(date) \(ts.dropFirst(8).prefix(2)):\(ts.dropFirst(10).prefix(2))",
                    open: open, high: high, low: low,
                    price: close, avgPrice: avg,
                    volume: volume, amount: typical * volume * 100))
        }
        return out
    }

    // MARK: - 实时快照（新浪兜底）

    /// 新浪实时兜底：腾讯 qt 不可达时使用。
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

    /// 新浪日K兜底：腾讯 fqkline 不可达时使用。
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

    /// 腾讯实时行情取流通股本：`v_sh600519="1~贵州茅台~600519~最新价~…~流通市值(亿)~总市值(亿)~…"`
    /// 索引 3=最新价、44=流通市值(亿) → 股本 = 流通市值×1e8 / 最新价。历史K无换手率时的推算来源。
    /// 注意返回是 GBK 编码，UTF-8 解码会失败
    private func fetchCircSharesViaTencent(secid: String) async -> Double? {
        guard let symbol = marketSymbol(secid: secid) else { return nil }
        let url = "https://qt.gtimg.cn/q=\(symbol)"
        guard let data = try? await get(url, referer: "https://gu.qq.com/") else { return nil }
        let gbk = CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString))
        let text = String(data: data, encoding: String.Encoding(rawValue: gbk))
            ?? String(data: data, encoding: .utf8)
        guard let text = text, let start = text.firstIndex(of: "~") else { return nil }
        let fields = text[start...].split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        guard fields.count > 45,
            let price = Double(fields[3]), price > 0,
            let circCapYi = Double(fields[44]), circCapYi > 0
        else { return nil }
        return circCapYi * 1e8 / price
    }

    // MARK: - 聚合
    // （原东财资金流 fflow / F10 基本面已随东财源一并移除：push2his 封 IP 后仅剩超时重试的空转）



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

        // 历史：腾讯 fqkline 优先（约3.3年，无成交额），失败时用新浪兜底（250根）
        var bars: [StockDailyBar] = []
        var historyNote: String? = nil
        do {
            bars = try await fetchHistory(secid: secid, endYYYYMMdd: endStr, lmt: 250)
        } catch {
            bars = await fetchHistoryViaSina(secid: secid, targetDate: resolved.targetDate)
            if !bars.isEmpty {
                historyNote = "腾讯历史接口失败，已用新浪兜底（成交额/换手率缺失）"
            }
        }

        // 换手率回填：新浪兜底的 bar 无 f61 → 用腾讯流通股本反推（近似：近一年股本视为不变）
        if bars.contains(where: { $0.turnover == 0 }),
            let shares = await fetchCircSharesViaTencent(secid: secid), shares > 0
        {
            bars = bars.map { bar in
                bar.turnover > 0 || bar.volume <= 0 ? bar
                    : StockDailyBar(
                        date: bar.date, open: bar.open, close: bar.close, high: bar.high,
                        low: bar.low, volume: bar.volume, amount: bar.amount,
                        amplitude: bar.amplitude, pctChange: bar.pctChange, change: bar.change,
                        turnover: bar.volume * 100 / shares * 100)
            }
        }

        // 双源都失败：若实时快照可用则降级展示（无技术指标），否则报错
        if bars.isEmpty {
            if resolved.targetDate == nil {
                var s = try? await fetchSnapshot(secid: secid)
                var degradeNote = "历史K线获取失败，技术指标不可用"
                if s == nil {
                    s = await fetchSnapshotViaSina(secid: secid)
                    degradeNote = "腾讯接口不可用，仅展示新浪实时行情，技术指标不可用"
                }
                if let s = s {
                    return StockDataBundle(
                        input: resolved.input, code: code, name: resolved.name ?? code,
                        secid: secid, targetDate: nil,
                        snapshot: s, indicators: nil, bars: [],
                        capitalFlows: [], fundamentals: nil,
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
                        + "腾讯实时接口失败，已用新浪实时数据（市值/PE 不可用）"
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

        // 直接输代码查询时 resolve 只回填 code 当名字；快照接口能拿到真实名称，兜底替换
        var displayName = resolved.name ?? code
        if displayName == code, let sn = snapshot?.name, !sn.isEmpty, sn != code {
            displayName = sn
        }

        return StockDataBundle(
            input: resolved.input, code: code, name: displayName,
            secid: secid, targetDate: resolved.targetDate,
            snapshot: snapshot, indicators: indicators,
            bars: Array(bars.suffix(20)),  // 仅保留近 20 日供 AI 看趋势，控制体积
            capitalFlows: [], fundamentals: nil, note: note,
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
