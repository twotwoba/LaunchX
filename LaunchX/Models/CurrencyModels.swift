import Foundation

// MARK: - 货币定义

/// 单个货币的定义:ISO 代码、常用符号、中文名与小写别名表(代码/中文/拼音/俗称)
struct CurrencyDefinition: Hashable {
    let code: String  // ISO 4217 代码,如 "USD"
    let symbol: String?  // 常用符号,如 "$";无通用符号时为 nil(显示时退回代码后缀)
    let chineseName: String  // 中文名,如 "美元"
    let aliases: [String]  // 全部小写别名,含代码、符号、中文名、拼音、俗称、国家名
}

// MARK: - 货币目录

/// 内置常见货币及多格式别名映射(HapiGo 式 6 种输入格式中的核心子集)
enum CurrencyCatalog {
    /// 内置货币表(覆盖约 28 个常见币种)
    static let currencies: [CurrencyDefinition] = [
        CurrencyDefinition(
            code: "USD", symbol: "$", chineseName: "美元",
            aliases: ["usd", "dollar", "dollars", "bucks", "美元", "美金", "美刀", "刀", "meiyuan", "meidao"]),
        CurrencyDefinition(
            code: "CNY", symbol: "¥", chineseName: "人民币",
            aliases: ["cny", "rmb", "renminbi", "元", "块", "kuai", "yuan", "人民币", "人民币元", "zhongguo", "中国", "china"]),
        CurrencyDefinition(
            code: "JPY", symbol: nil, chineseName: "日元",
            aliases: ["jpy", "yen", "日元", "日币", "円", "riyuan", "日本", "japan", "riben"]),
        CurrencyDefinition(
            code: "EUR", symbol: "€", chineseName: "欧元",
            aliases: ["eur", "euro", "euros", "欧元", "ouyuan", "欧盟", "eu"]),
        CurrencyDefinition(
            code: "GBP", symbol: "£", chineseName: "英镑",
            aliases: ["gbp", "pound", "pounds", "sterling", "英镑", "yingbang", "英国", "uk", "britain"]),
        CurrencyDefinition(
            code: "HKD", symbol: nil, chineseName: "港元",
            aliases: ["hkd", "港元", "港币", "港纸", "gangyuan", "香港", "hongkong", "hong kong"]),
        CurrencyDefinition(
            code: "KRW", symbol: "₩", chineseName: "韩元",
            aliases: ["krw", "won", "韩元", "韩币", "hanyuan", "韩国", "korea"]),
        CurrencyDefinition(
            code: "SGD", symbol: nil, chineseName: "新加坡元",
            aliases: ["sgd", "新加坡元", "新币", "坡币", "xinjiapoyuan", "新加坡", "singapore"]),
        CurrencyDefinition(
            code: "AUD", symbol: nil, chineseName: "澳元",
            aliases: ["aud", "澳元", "澳币", "aoyuan", "澳大利亚", "澳洲", "australia"]),
        CurrencyDefinition(
            code: "CAD", symbol: nil, chineseName: "加元",
            aliases: ["cad", "加元", "加币", "jiayuan", "加拿大", "canada"]),
        CurrencyDefinition(
            code: "CHF", symbol: nil, chineseName: "瑞士法郎",
            aliases: ["chf", "瑞郎", "瑞士法郎", "ruilang", "瑞士", "swiss", "franc"]),
        CurrencyDefinition(
            code: "NZD", symbol: nil, chineseName: "新西兰元",
            aliases: ["nzd", "纽元", "新西兰元", "纽币", "niuyuan", "新西兰", "new zealand"]),
        CurrencyDefinition(
            code: "TWD", symbol: nil, chineseName: "新台币",
            aliases: ["twd", "新台币", "台币", "xintaibi", "台湾", "taiwan"]),
        CurrencyDefinition(
            code: "THB", symbol: nil, chineseName: "泰铢",
            aliases: ["thb", "泰铢", "taizhu", "泰国", "thailand", "baht"]),
        CurrencyDefinition(
            code: "MYR", symbol: nil, chineseName: "马来西亚林吉特",
            aliases: ["myr", "马币", "林吉特", "linjite", "马来西亚", "malaysia", "ringgit"]),
        CurrencyDefinition(
            code: "VND", symbol: nil, chineseName: "越南盾",
            aliases: ["vnd", "越南盾", "yuenandun", "越南", "vietnam", "dong"]),
        CurrencyDefinition(
            code: "INR", symbol: "₹", chineseName: "印度卢比",
            aliases: ["inr", "卢比", "印度卢比", "lubi", "印度", "india", "rupee"]),
        CurrencyDefinition(
            code: "RUB", symbol: nil, chineseName: "俄罗斯卢布",
            aliases: ["rub", "卢布", "lubu", "俄罗斯", "russia", "rouble", "ruble"]),
        CurrencyDefinition(
            code: "PHP", symbol: nil, chineseName: "菲律宾比索",
            aliases: ["php", "菲律宾比索", "比索", "菲律宾", "philippines", "peso"]),
        CurrencyDefinition(
            code: "IDR", symbol: nil, chineseName: "印尼盾",
            aliases: ["idr", "印尼盾", "yinidun", "印尼", "indonesia", "rupiah"]),
        CurrencyDefinition(
            code: "TRY", symbol: nil, chineseName: "土耳其里拉",
            aliases: ["try", "里拉", "lila", "土耳其", "turkey", "lira"]),
        CurrencyDefinition(
            code: "AED", symbol: nil, chineseName: "阿联酋迪拉姆",
            aliases: ["aed", "迪拉姆", "dilamu", "阿联酋", "dirham"]),
        CurrencyDefinition(
            code: "BRL", symbol: nil, chineseName: "巴西雷亚尔",
            aliases: ["brl", "雷亚尔", "leiyaer", "巴西", "brazil", "real"]),
        CurrencyDefinition(
            code: "MXN", symbol: nil, chineseName: "墨西哥比索",
            aliases: ["mxn", "墨西哥比索", "墨西哥", "mexico"]),
        CurrencyDefinition(
            code: "ZAR", symbol: nil, chineseName: "南非兰特",
            aliases: ["zar", "兰特", "lante", "南非", "south africa", "rand"]),
        CurrencyDefinition(
            code: "SEK", symbol: nil, chineseName: "瑞典克朗",
            aliases: ["sek", "瑞典克朗", "瑞典", "sweden", "krona"]),
        CurrencyDefinition(
            code: "NOK", symbol: nil, chineseName: "挪威克朗",
            aliases: ["nok", "挪威克朗", "挪威", "norway"]),
        CurrencyDefinition(
            code: "DKK", symbol: nil, chineseName: "丹麦克朗",
            aliases: ["dkk", "丹麦克朗", "丹麦", "denmark", "krone"]),
    ]

    /// "usd" -> 定义 的精确别名映射(含代码)
    static let exactAliases: [String: CurrencyDefinition] = {
        var map: [String: CurrencyDefinition] = [:]
        for currency in currencies {
            map[currency.code.lowercased()] = currency
            for alias in currency.aliases where map[alias] == nil {
                map[alias] = currency
            }
        }
        return map
    }()

    /// 符号映射(¥ 优先映射为人民币,日元请用代码或"日元")
    static let symbolMap: [String: CurrencyDefinition] = {
        var map: [String: CurrencyDefinition] = [:]
        for currency in currencies {
            if let symbol = currency.symbol, map[symbol] == nil {
                map[symbol] = currency
            }
        }
        // 全角"￥"与半角"¥"统一映射为人民币(日元用代码 jpy 或"日元"输入)
        if let cny = map["¥"], map["￥"] == nil {
            map["￥"] = cny
        }
        return map
    }()

    /// 精确查找别名
    static func lookup(_ token: String) -> CurrencyDefinition? {
        exactAliases[token.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    /// 按符号查找
    static func lookupSymbol(_ symbol: Character) -> CurrencyDefinition? {
        symbolMap[String(symbol)]
    }

    /// 前缀查找(用于输入目标货币时的即时联想):所有别名按前缀匹配后按币种去重,唯一命中才返回
    static func lookupPrefix(_ token: String) -> CurrencyDefinition? {
        let key = token.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var hits = Set<String>()
        var firstMatch: CurrencyDefinition?
        for currency in currencies {
            let allKeys = [currency.code.lowercased()] + currency.aliases
            if allKeys.contains(where: { $0.hasPrefix(key) }), hits.insert(currency.code).inserted {
                if firstMatch == nil { firstMatch = currency }
            }
        }
        return hits.count == 1 ? firstMatch : nil
    }
}

// MARK: - 汇率报价

/// 一次换算可用的报价:汇率、取数时间、来源与来源侧数据日期
struct CurrencyQuote: Codable, Equatable {
    let rate: Double
    let fetchedAt: Date
    let source: String  // "tencent"(腾讯财经盘中实时) / "exchangerate-api"(日线参考)
    let sourceDate: String?  // 来源侧的数据日期展示,如 "11-17 21:46" 或 "2026-11-17"
}

// MARK: - 预览值

/// 回车复制 / `=` 回填所需的两个字符串形态
struct CurrencyPreviewConversion: Equatable {
    let copyText: String  // 复制用,如 "¥666.57"
    let fillValue: String  // 回填输入框用,纯数值,如 "666.57"
}

// MARK: - 数字格式化

enum CurrencyFormatter {
    /// 按数值大小自适应小数位:≥1000 取整带分组;≥1 固定 2 位;更小保留至多 4 位
    static func amountString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        let magnitude = abs(value)
        if magnitude >= 1000 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
        } else if magnitude >= 1 {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        } else {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 4
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 预览/复制用的完整金额文案:有符号前缀显示,无符号用代码后缀
    static func displayString(_ value: Double, currency: CurrencyDefinition) -> String {
        let amount = amountString(value)
        if let symbol = currency.symbol {
            return "\(symbol)\(amount)"
        }
        return "\(amount) \(currency.code)"
    }
}

// MARK: - 设置

/// 汇率换算功能设置:开关 + 默认目标货币
struct CurrencySettings: Codable {
    var isEnabled: Bool
    var defaultTargetCode: String

    static let `default` = CurrencySettings(isEnabled: true, defaultTargetCode: "CNY")

    private static let storageKey = "launchx.currencySettings"
    private static var cached: CurrencySettings?

    /// 读取设置(带进程内缓存,输入框每键触发,避免反复解码)
    static func load() -> CurrencySettings {
        if let cached = cached { return cached }
        if let data = UserDefaults.standard.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(CurrencySettings.self, from: data)
        {
            cached = settings
            return settings
        }
        cached = .default
        return .default
    }

    /// 保存设置并刷新进程内缓存
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        CurrencySettings.cached = self
    }

    /// 解析默认目标货币:源币种即默认目标时,按 CNY⇄USD 经典对回转
    func resolvedTargetCode(forSource sourceCode: String) -> String {
        if sourceCode == defaultTargetCode {
            return sourceCode == "CNY" ? "USD" : "CNY"
        }
        return defaultTargetCode
    }
}
