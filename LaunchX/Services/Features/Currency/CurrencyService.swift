import Foundation

/// 汇率服务:腾讯财经盘中实时报价优先(约 15 个主要币对),
/// 其余币对回退 ExchangeRate-API 的 USD 基准日线表交叉计算;带内存 + 磁盘双层缓存。
/// 线程模型:对外状态与回调均在主线程(仿 AITranslateService 的 dataTask + 主线程回调模式)
final class CurrencyService {
    static let shared = CurrencyService()

    // MARK: - 错误

    enum QuoteError: Error {
        case network
        case parse
        case unsupportedPair
    }

    // MARK: - 腾讯直连币对(2026-11 实测 wh 前缀报价可用集合)

    /// 支持盘中实时报价的币对(以 from+to 拼接匹配,反向对自动取倒数)
    static let realtimePairs: Set<String> = [
        "USDCNY", "EURCNY", "GBPCNY", "EURUSD", "GBPUSD", "USDJPY", "USDCHF",
        "USDCAD", "AUDUSD", "NZDUSD", "USDSGD", "USDHKD", "USDTWD", "USDMYR", "CNYJPY",
    ]

    // MARK: - 缓存时效

    /// 腾讯实时报价缓存 60 秒(源本身约分钟级刷新)
    private static let realtimeTTL: TimeInterval = 60
    /// 日线参考表缓存 6 小时(源每日更新)
    private static let dailyTTL: TimeInterval = 6 * 3600

    // MARK: - 磁盘缓存

    private struct DiskCache: Codable {
        var quotes: [String: CurrencyQuote] = [:]  // "USD-CNY" -> 报价
        var erapiTable: ERAPITable?
    }

    /// er-api USD 基准全表(一次请求推导任意币对)
    private struct ERAPITable: Codable {
        var fetchedAt: Date
        var rates: [String: Double]
    }

    /// 腾讯响应解码用 GB18030(GBK 超集)
    private static let gbkEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    private let cacheURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = appSupport.appendingPathComponent("LaunchX/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("currency_rates.json")
    }()

    // 主线程访问的缓存状态
    private var diskCache = DiskCache()
    private var inFlightKeys: Set<String> = []
    private var pendingCompletions: [String: [(Result<CurrencyQuote, QuoteError>) -> Void]] = [:]

    private init() {
        loadDiskCache()
    }

    // MARK: - 对外接口

    /// 同步取缓存报价(可能过期,供预览即时显示;无缓存返回 nil)
    func cachedQuote(from: String, to: String) -> CurrencyQuote? {
        let key = quoteKey(from: from, to: to)
        if let quote = diskCache.quotes[key] { return quote }
        // 无该币对缓存但日线表可用时,现算一份(不落盘,避免写放大)
        if let table = diskCache.erapiTable,
            let rate = derivedRate(from: from, to: to, table: table)
        {
            return CurrencyQuote(
                rate: rate, fetchedAt: table.fetchedAt, source: "exchangerate-api",
                sourceDate: nil)
        }
        return nil
    }

    /// 判断缓存报价是否仍在时效内
    func isFresh(_ quote: CurrencyQuote) -> Bool {
        let ttl = quote.source == "tencent" ? CurrencyService.realtimeTTL : CurrencyService.dailyTTL
        return Date().timeIntervalSince(quote.fetchedAt) < ttl
    }

    /// 拉取报价,主线程回调;网络失败但有缓存时回退缓存(可能过期,调用方可用 fetchedAt 提示)
    func fetchQuote(
        from: String, to: String,
        completion: @escaping (Result<CurrencyQuote, QuoteError>) -> Void
    ) {
        let key = quoteKey(from: from, to: to)

        // 同键请求合并:在途时挂到 pending 列表,避免连打键盘重复请求
        if inFlightKeys.contains(key) {
            pendingCompletions[key, default: []].append(completion)
            return
        }
        inFlightKeys.insert(key)
        pendingCompletions[key, default: []].append(completion)

        let finish: (Result<CurrencyQuote, QuoteError>) -> Void = { [weak self] result in
            guard let self = self else { return }
            // 网络失败时回退缓存(即使过期),保证离线/断源时预览仍可用
            let finalResult: Result<CurrencyQuote, QuoteError>
            if case .failure = result, let cached = self.diskCache.quotes[key] {
                finalResult = .success(cached)
            } else {
                finalResult = result
            }
            let completions = self.pendingCompletions[key] ?? []
            self.pendingCompletions[key] = nil
            self.inFlightKeys.remove(key)
            for completion in completions {
                completion(finalResult)
            }
        }

        // 解析直连/反向直连/日线表交叉三条路径
        let forwardPair = from + to
        let reversePair = to + from
        if CurrencyService.realtimePairs.contains(forwardPair) {
            fetchTencentQuote(pair: forwardPair, invert: false, finish: finish)
        } else if CurrencyService.realtimePairs.contains(reversePair) {
            fetchTencentQuote(pair: reversePair, invert: true, finish: finish)
        } else {
            fetchERAPITable { result in
                switch result {
                case .success:
                    if let quote = self.cachedQuote(from: from, to: to) {
                        finish(.success(quote))
                    } else {
                        finish(.failure(.unsupportedPair))
                    }
                case .failure(let error):
                    finish(.failure(error))
                }
            }
        }
    }

    // MARK: - 腾讯财经

    private func fetchTencentQuote(
        pair: String, invert: Bool,
        finish: @escaping (Result<CurrencyQuote, QuoteError>) -> Void
    ) {
        guard let url = URL(string: "https://qt.gtimg.cn/q=wh\(pair)") else {
            finish(.failure(.parse))
            return
        }
        let request = URLRequest(url: url, timeoutInterval: 5)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            // 解析放后台,回调回主线程
            let parsed: Result<CurrencyQuote, QuoteError>
            if error != nil {
                parsed = .failure(.network)
            } else if let data = data,
                let text = String(data: data, encoding: CurrencyService.gbkEncoding),
                let parsedQuote = CurrencyService.parseTencentQuote(text: text, pair: pair)
            {
                let quote: CurrencyQuote
                if invert {
                    quote = CurrencyQuote(
                        rate: 1.0 / parsedQuote.price, fetchedAt: Date(), source: "tencent",
                        sourceDate: parsedQuote.timeText)
                } else {
                    quote = CurrencyQuote(
                        rate: parsedQuote.price, fetchedAt: Date(), source: "tencent",
                        sourceDate: parsedQuote.timeText)
                }
                parsed = .success(quote)
            } else {
                parsed = .failure(.parse)
            }

            DispatchQueue.main.async {
                guard let self = self else {
                    finish(parsed)
                    return
                }
                if case .success(let quote) = parsed {
                    self.storeQuote(quote, key: self.quoteKeyForPair(pair: pair, invert: invert))
                }
                finish(parsed)
            }
        }.resume()
    }

    /// 报价存储键:反向对统一以 from-to 方向存,查询才能命中
    private func quoteKeyForPair(pair: String, invert: Bool) -> String {
        if invert {
            let from = String(pair.suffix(3))
            let to = String(pair.prefix(3))
            return quoteKey(from: from, to: to)
        }
        return quoteKey(from: String(pair.prefix(3)), to: String(pair.suffix(3)))
    }

    /// 解析腾讯行情文本(纯函数,便于测试):
    /// 形如 v_whUSDCNY="310~美元人民币~USDCNY~6.6656~0~20261117214601~...",字段以 ~ 分隔,
    /// 下标 3 为现价,下标 5 为北京时间 yyyMMddHHmmss
    static func parseTencentQuote(text: String, pair: String) -> (price: Double, timeText: String)?
    {
        guard let regex = try? NSRegularExpression(pattern: "v_wh\(pair)=\"([^\"]+)\"") else {
            return nil
        }
        let nsText = text as NSString
        guard
            let match = regex.firstMatch(
                in: text, range: NSRange(location: 0, length: nsText.length)),
            match.numberOfRanges >= 2
        else { return nil }

        let payload = nsText.substring(with: match.range(at: 1))
        let fields = payload.components(separatedBy: "~")
        guard fields.count > 5,
            let price = Double(fields[3]), price > 0
        else { return nil }

        // 时间戳 yyyMMddHHmmss -> "MM-dd HH:mm"
        let stamp = fields[5]
        var timeText: String?
        if stamp.count >= 12 {
            let month = String(stamp.dropFirst(4).prefix(2))
            let day = String(stamp.dropFirst(6).prefix(2))
            let hour = String(stamp.dropFirst(8).prefix(2))
            let minute = String(stamp.dropFirst(10).prefix(2))
            timeText = "\(month)-\(day) \(hour):\(minute)"
        }
        return (price, timeText ?? "")
    }

    // MARK: - ExchangeRate-API 日线表

    private func fetchERAPITable(
        completion: @escaping (Result<Void, QuoteError>) -> Void
    ) {
        // 表未过期直接复用,不再请求
        if let table = diskCache.erapiTable,
            Date().timeIntervalSince(table.fetchedAt) < CurrencyService.dailyTTL
        {
            completion(.success(()))
            return
        }

        guard
            let url = URL(string: "https://open.er-api.com/v6/latest/USD")
        else {
            completion(.failure(.parse))
            return
        }
        let request = URLRequest(url: url, timeoutInterval: 5)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            let result: Result<ERAPITable, QuoteError>
            if error != nil {
                result = .failure(.network)
            } else if let data = data,
                let decoded = try? JSONDecoder().decode(ERAPIResponse.self, from: data),
                decoded.result == "success"
            {
                result = .success(ERAPITable(fetchedAt: Date(), rates: decoded.rates))
            } else {
                result = .failure(.parse)
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let table):
                    self?.diskCache.erapiTable = table
                    self?.persistDiskCache()
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    /// er-api 响应模型(rates 数值为 1 USD 兑该币的数量)
    private struct ERAPIResponse: Codable {
        let result: String
        let rates: [String: Double]
    }

    /// 由 USD 基准表交叉推导 from→to 汇率
    private func derivedRate(from: String, to: String, table: ERAPITable) -> Double? {
        let upperFrom = from.uppercased()
        let upperTo = to.uppercased()
        guard
            let rateFrom = table.rates[upperFrom],
            let rateTo = table.rates[upperTo],
            rateFrom > 0
        else { return nil }
        return rateTo / rateFrom
    }

    // MARK: - 缓存持久化

    private func quoteKey(from: String, to: String) -> String {
        "\(from.uppercased())-\(to.uppercased())"
    }

    private func storeQuote(_ quote: CurrencyQuote, key: String) {
        diskCache.quotes[key] = quote
        persistDiskCache()
    }

    /// 原子写入磁盘缓存(临时文件 + 原子替换);失败静默,缓存仅影响预览时效
    private func persistDiskCache() {
        guard let data = try? JSONEncoder().encode(diskCache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadDiskCache() {
        guard let data = try? Data(contentsOf: cacheURL),
            let cache = try? JSONDecoder().decode(DiskCache.self, from: data)
        else { return }
        diskCache = cache
    }
}
