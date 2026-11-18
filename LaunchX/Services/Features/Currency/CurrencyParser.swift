import Foundation

/// 汇率输入解析器:把 "$100"、"100usd"、"100美元"、"100usd>jpy" 等形态解析为金额 + 源币种( + 显式目标币种)
/// 支持格式:符号+数字($100 / 100￥)、代码+数字(usd100 / 100USD)、中文/拼音/俗称(美元100 / 100块 / 100rmb)
/// 目标货币分隔符:">" / "->" / " to " / "换" / "兑" / "换成" / "兑换成"
enum CurrencyParser {
    struct ParseResult: Equatable {
        let amount: Double
        let source: CurrencyDefinition
        let target: CurrencyDefinition?  // 显式目标(nil = 由设置决定默认目标)
    }

    /// 可识别的货币符号集合
    private static let symbols: Set<Character> = ["$", "￥", "¥", "€", "£", "₩", "₹"]

    /// 目标子句分隔符(多字优先,避免 "兑换成" 被 "兑" 抢先截断)
    private static let targetSeparators = ["->", "兑换成", "换成", "兑换", "换", "兑", ">", " to ", " to"]

    /// 解析入口:无法识别时返回 nil(输入继续走应用/文件搜索与计算器)
    static func parse(_ raw: String) -> ParseResult? {
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }

        // 1. 拆出目标子句(若有)
        let (head, targetToken) = splitTarget(query)

        // 2. 解析主体:金额 + 源币种
        guard let (amount, source) = parseHead(head) else { return nil }

        // 3. 解析显式目标(允许前缀联想;写了一半且无法唯一命中时整体不显示,避免闪错值)
        var target: CurrencyDefinition?
        if let token = targetToken {
            guard let resolved = CurrencyCatalog.lookupPrefix(token) else { return nil }
            target = resolved
        }

        return ParseResult(amount: amount, source: source, target: target)
    }

    // MARK: - 目标子句

    /// 返回 (主体, 目标token)。目标 token 为 nil 表示未携带分隔符;为空串表示分隔符已敲但目标未输入
    static func splitTarget(_ query: String) -> (head: String, target: String?) {
        var earliest: (range: Range<String.Index>, token: String)?

        for separator in targetSeparators {
            if let range = query.range(of: separator) {
                // 位置更靠前的分隔符优先(如 "100usd -> to"? 先按实际出现顺序)
                if earliest == nil || range.lowerBound < earliest!.range.lowerBound {
                    earliest = (range, separator)
                }
            }
        }

        guard let hit = earliest else {
            return (query, nil)
        }

        // " to " 命中时把尾部空格并入分隔符,目标侧不再带前导空格
        let head = String(query[query.startIndex..<hit.range.lowerBound]).trimmingCharacters(
            in: .whitespaces)
        let target = String(query[hit.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (head, target)
    }

    // MARK: - 主体解析

    /// 解析 "$100" / "100￥" / "100usd" / "usd100" / "100美元" 等主体
    private static func parseHead(_ headRaw: String) -> (Double, CurrencyDefinition)? {
        let head = headRaw.trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return nil }

        // 符号在前:$100 / $ 100
        if let first = head.first, symbols.contains(first) {
            let rest = String(head.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let amount = amount(from: rest) else { return nil }
            guard let currency = CurrencyCatalog.lookupSymbol(first) else { return nil }
            return (amount, currency)
        }

        // 符号在后:100$ / 100￥
        if let last = head.last, symbols.contains(last) {
            let rest = String(head.dropLast()).trimmingCharacters(in: .whitespaces)
            guard let amount = amount(from: rest) else { return nil }
            guard let currency = CurrencyCatalog.lookupSymbol(last) else { return nil }
            return (amount, currency)
        }

        // 数字在前:100usd / 100 美元 / 1,000.5rmb
        if let match = firstRegexMatch(in: head, pattern: #"^(\d[\d,]*(?:\.\d*)?)([\s\S]+)$"#) {
            guard let amount = amount(from: match.0) else { return nil }
            let residue = match.1.trimmingCharacters(in: .whitespaces)
            guard !residue.isEmpty, let currency = CurrencyCatalog.lookup(residue) else {
                return nil
            }
            return (amount, currency)
        }

        // 别名在前:usd100 / 美元100 / usd 100
        if let match = firstRegexMatch(
            in: head, pattern: #"^(\D[\s\S]*?)\s*(\d[\d,]*(?:\.\d*)?)$"#) {
            guard let amount = amount(from: match.1) else { return nil }
            let residue = match.0.trimmingCharacters(in: .whitespaces)
            guard let currency = CurrencyCatalog.lookup(residue) else { return nil }
            return (amount, currency)
        }

        return nil
    }

    /// 金额文本 → Double:支持千分位逗号与小数;非法形态返回 nil
    private static func amount(from literal: String) -> Double? {
        let cleaned = literal.replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, cleaned.range(of: #"^\d+(\.\d*)?$"#, options: .regularExpression)
            != nil
        else { return nil }
        return Double(cleaned)
    }

    /// 正则捕获组辅助:返回 (group1, group2)
    private static func firstRegexMatch(in text: String, pattern: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)),
            match.numberOfRanges >= 3
        else { return nil }
        return (nsText.substring(with: match.range(at: 1)), nsText.substring(with: match.range(at: 2)))
    }
}
