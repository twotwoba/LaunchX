import Foundation

/// 解析用户输入为单个 StockQuery（一次只查一只）。
/// 支持格式：
///   600519            （代码）
///   贵州茅台           （名称）
enum StockQueryParser {

    /// 只取第一个非空 token（兼容旧批量输入，多余内容忽略）
    static func parse(_ raw: String) -> StockQuery? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let first = trimmed.components(separatedBy: CharacterSet(charactersIn: ",，\n;；"))
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return first.flatMap { parseToken($0) }
    }

    private static func parseToken(_ token: String) -> StockQuery? {
        let subject = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }

        var q = StockQuery(input: token, code: nil, secid: nil, name: nil, targetDate: nil)
        if let (code, secid) = parseCodeAndSecid(subject) {
            q.code = code
            q.secid = secid
        } else {
            q.code = nil  // 名称，待搜索
        }
        return q
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
