import Foundation

/// 解析用户输入为一批 StockQuery。
/// 支持格式：
///   600519            （代码，最新）
///   贵州茅台           （名称，最新）
///   600519-20240115   （代码 + 日期）
///   贵州茅台 2024-01-15（名称 + 日期）
///   600519,000858-20240115   （批量，逗号/中文逗号/换行分隔）
enum StockQueryParser {

    /// 将输入拆分为多个查询 token（每个 token 含股票 + 可选日期）
    static func parse(_ raw: String) -> [StockQuery] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 按中英文逗号 / 换行 / 分号切分
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: ",，\n;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return parts.compactMap { parseToken($0) }
    }

    private static func parseToken(_ token: String) -> StockQuery? {
        // 1) 尝试从尾部抽取日期
        let (date, remainder) = extractTrailingDate(token)
        // 2) remainder 作为股票主体（代码或名称）
        let subject = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }

        var q = StockQuery(input: token, code: nil, secid: nil, name: nil, targetDate: date)
        if let (code, secid) = parseCodeAndSecid(subject) {
            q.code = code
            q.secid = secid
        } else {
            q.code = nil  // 名称，待搜索
        }
        return q
    }

    // MARK: - 日期抽取

    /// 从 token 尾部匹配日期，返回 (yyyy-MM-dd 或 nil, 去掉日期后的剩余)
    private static func extractTrailingDate(_ token: String) -> (String?, String) {
        // 匹配：可选分隔符 + yyyy + 分隔 + mm + 分隔 + dd（含 yyyyMMdd 紧凑形式）
        let pattern =
            "(?:[-\\s/.年])?(20\\d{2})[-/.年]?(0?[1-9]|1[0-2])[-/.月]?(0?[1-9]|[12]\\d|3[01])日?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.firstMatch(
                in: token, options: [], range: NSRange(token.startIndex..., in: token))
        else {
            return (nil, token)
        }

        // 紧凑 8 位（yyyyMMdd）单独处理
        let compactPattern = "-?(20\\d{2})(0?[1-9]|1[0-2])(0?[1-9]|[12]\\d|3[01])$"
        if let compactRegex = try? NSRegularExpression(pattern: compactPattern, options: []),
            let compactMatch = compactRegex.firstMatch(
                in: token, options: [], range: NSRange(token.startIndex..., in: token))
        {
            let y = captured(token, compactMatch, at: 1)
            let m = captured(token, compactMatch, at: 2)
            let d = captured(token, compactMatch, at: 3)
            if let date = normalize(y: y, m: m, d: d) {
                let cutRange = compactMatch.range
                let remain = removing(range: cutRange, in: token)
                return (date, remain)
            }
        }

        let y = captured(token, match, at: 1)
        let m = captured(token, match, at: 2)
        let d = captured(token, match, at: 3)
        guard let date = normalize(y: y, m: m, d: d) else { return (nil, token) }
        let remain = removing(range: match.range, in: token)
        return (date, remain)
    }

    private static func captured(_ s: String, _ m: NSTextCheckingResult, at idx: Int) -> String {
        guard idx < m.numberOfRanges, m.range(at: idx).location != NSNotFound,
            let r = Range(m.range(at: idx), in: s)
        else { return "" }
        return String(s[r])
    }

    private static func removing(range: NSRange, in s: String) -> String {
        guard let r = Range(range, in: s) else { return s }
        var copy = s
        copy.removeSubrange(r)
        return copy
    }

    private static func normalize(y: String, m: String, d: String) -> String? {
        guard let yy = Int(y), let mm = Int(m), let dd = Int(d),
            (1...12).contains(mm), (1...31).contains(dd)
        else { return nil }
        return String(format: "%04d-%02d-%02d", yy, mm, dd)
    }

    // MARK: - 代码识别

    /// 若 subject 是 6 位 A 股代码或带市场前缀（sh/sz/1.600519），返回 (code, secid)
    private static func parseCodeAndSecid(_ subject: String) -> (String, String)? {
        let lower = subject.lowercased()

        // 1.600519 / 0.000001（secid 原样）
        if let dotIdx = lower.firstIndex(of: ".") {
            let after = String(lower[lower.index(after: dotIdx)...])
            if isAShareCode(after) {
                let market = String(lower[..<dotIdx])
                return (after, "\(market).\(after)")
            }
        }

        // sh600519 / sz000001
        if lower.hasPrefix("sh"), isAShareCode(String(lower.dropFirst(2))) {
            let code = String(lower.dropFirst(2))
            return (code, "1.\(code)")
        }
        if lower.hasPrefix("sz"), isAShareCode(String(lower.dropFirst(2))) {
            let code = String(lower.dropFirst(2))
            return (code, "0.\(code)")
        }
        if lower.hasPrefix("bj"), isAShareCode(String(lower.dropFirst(2))) {
            let code = String(lower.dropFirst(2))
            return (code, "0.\(code)")
        }

        // 纯 6 位代码：按首字符判市场
        if isAShareCode(lower) {
            return (lower, secid(forCode: lower))
        }
        return nil
    }

    static func isAShareCode(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy { $0.isNumber }
    }

    /// 6/9 开头沪市(1)，0/3 开头深市(0)，8/4 北交所(0，secid 也用 0)
    private static func secid(forCode code: String) -> String {
        let prefix = code.first.map(String.init) ?? ""
        switch prefix {
        case "6", "9": return "1.\(code)"
        default: return "0.\(code)"
        }
    }
}
