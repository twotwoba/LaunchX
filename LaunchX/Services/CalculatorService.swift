import Foundation
import JavaScriptCore

// MARK: - 计算器求值服务

/// 计算器求值服务:JSContext 驱动,支持科学函数/常量/阶乘/百分号/ans 变量。
/// 安全靠 sanitize 的词元白名单转写(用户输入只可能映射到受限的 JS 函数集合),
/// JS 侧仅在初始化时预置固定函数,不暴露任何可注入的全局能力。
final class CalculatorService {
    static let shared = CalculatorService()

    private let context: JSContext = JSContext()
    /// JSContext 非线程安全,所有求值收敛到串行队列(主线程调用安全)
    private let evalQueue = DispatchQueue(label: "com.launchx.calculator.eval")

    private init() {
        // 求值异常统一按「无效表达式」处理,由调用方以占位符呈现
        context.exceptionHandler = { _, _ in }
        evalQueue.sync {
            context.evaluateScript(Self.jsPrelude)
        }
    }

    // MARK: - 求值入口

    /// 扩展求值:表达式 → sanitize 转写 → JS 求值 → 结果模型
    /// - Parameters:
    ///   - query: 用户输入的原始表达式
    ///   - angleMode: 三角/反三角函数的角度制(Rad/Deg)
    ///   - ans: 上一条结果的数值(输入含 ans 时必须提供,否则返回 nil)
    func evaluate(
        _ query: String, angleMode: CalculatorAngleMode = .radians, ans: Double? = nil
    ) -> CalculatorResult? {
        guard let expression = Self.sanitize(query, angleMode: angleMode, ans: ans) else {
            return nil
        }
        return evalQueue.sync {
            guard let result = context.evaluateScript(expression),
                !result.isUndefined,
                result.isNumber
            else { return nil }
            let value = result.toDouble()
            guard value.isFinite else { return nil }
            return CalculatorResult(value: value, copyText: Self.formatResult(value, grouped: false))
        }
    }

    /// 兼容旧调用方(ghost 预览):返回无分组的结果文本
    func evaluate(_ query: String) -> String? {
        evaluate(query, angleMode: .radians, ans: nil)?.copyText
    }

    // MARK: - 门控:是否像表达式(决定计算器面板显隐,轻量、不定型)

    /// 非空、字符集合法、字母词元全部可识别,且带求值信号(运算符/函数/常量/!/%/√/π)。
    /// 纯数字("123")返回 false,不触发面板,与旧行为一致。
    static func looksLikeExpression(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = trimmed.lowercased()

        // 字符集粗筛:数字/ASCII 字母/基础运算符 + √ π × ÷ −
        for ch in normalized {
            if ch.isASCII {
                if !(ch.isLetter || ch.isNumber || "+-*/().^!% \t".contains(ch)) { return false }
            } else if !("√π×÷−".contains(ch)) {
                return false
            }
        }

        // 词元白名单:任何不认识的字母词元(如 "c++教程" 的 "c"、"sqrtx" 的 "sqrtx")→ 交回搜索
        let words = wordTokens(in: normalized)
        for word in words where !allowedWords.contains(word) { return false }

        // 求值信号:显式运算符/后缀标记,或任何白名单词元(函数/ans/常量)
        if normalized.range(of: "[+\\-*/^!%√π]", options: .regularExpression) != nil { return true }
        return !words.isEmpty
    }

    // MARK: - 转写:用户输入 → 安全 JS 表达式

    /// 把输入表达式转写为仅含受限函数集合的 JS 表达式;非法/不完整/无求值信号返回 nil
    static func sanitize(_ raw: String, angleMode: CalculatorAngleMode, ans: Double?) -> String? {
        // 1. 归一:去空白、Unicode 运算符映射、小写
        var s = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .lowercased()
        if s.isEmpty { return nil }

        // 2. 字符集粗筛(转写前)
        for ch in s {
            if ch.isASCII {
                if !(ch.isLetter || ch.isNumber || "+-*/().^!%".contains(ch)) { return nil }
            } else if !("√π".contains(ch)) {
                return nil
            }
        }

        // 3. 词元白名单:挡掉 eval/constructor 等一切未知标识符
        for word in wordTokens(in: s) where !allowedWords.contains(word) { return nil }

        // 4. ans 变量:括号包裹避免数值拼接成新 token(如 ans=0.5 时 "ans2" ≠ "0.52" 的歧义)
        if wordTokens(in: s).contains("ans") {
            guard let ans = ans else { return nil }
            s = replaceRegex("(?<![a-z])ans(?![a-z])", in: s, with: "(\(String(ans)))")
        }

        // 5. 常量:π / pi / e(e 保持 JS 科学计数法字面量语义:数字相邻时不替换)
        s = s.replacingOccurrences(of: "π", with: "(3.141592653589793)")
        s = replaceRegex("(?<![a-z])pi(?![a-z])", in: s, with: "(3.141592653589793)")
        s = replaceRegex("(?<![0-9a-z.])e(?![0-9a-z.])", in: s, with: "(2.718281828459045)")

        // 6. 函数名翻译(按角度模式选择 JS 函数)
        s = replaceRegex(
            "(?<![a-z])(asin|acos|atan|log2|sqrt|sin|cos|tan|log|ln)(?![a-z])", in: s
        ) { word in
            Self.jsFunctionName(for: word, angleMode: angleMode)
        }

        // 7. 后缀阶乘 ! → fact(...)
        guard let factored = translateFactorial(s) else { return nil }
        s = factored

        // 8. 百分号消歧:中缀保留 %(JS 取余),后缀转写为 (x/100)
        guard let percented = translatePercent(s) else { return nil }
        s = percented

        // 9. 根号:√( → sqrtR( ;裸 √ 后跟数字串自动补括号;残余 √ 非法
        s = s.replacingOccurrences(of: "√(", with: "sqrtR(")
        s = replaceRegex("√([0-9.]+)", in: s, with: "sqrtR($1)")
        if s.contains("√") { return nil }

        // 10. 幂符号统一为 **
        s = s.replacingOccurrences(of: "^", with: "**")

        // 11. 终检:转写结果只允许安全字符集(字母仅剩函数名,含大写 R/D 后缀)
        guard s.range(of: "^[0-9a-zA-Z+\\-*/().,%!]+$", options: .regularExpression) != nil else {
            return nil
        }
        // 12. 必须有求值信号(运算符/函数调用/取余/科学计数法),纯数字不触发
        guard s.range(of: "[+\\-*/%(]|([0-9]e)", options: .regularExpression) != nil else {
            return nil
        }
        // 13. 未输入完的表达式不求值
        if let last = s.last, "+-*/(".contains(last) { return nil }

        return s
    }

    // MARK: - 格式化

    /// 结果格式化:`grouped = true` 千分位分组(面板大字行),false 保持无分组(ghost/剪贴板);
    /// 极大/极小值统一科学计数法防 UI 溢出
    static func formatResult(_ value: Double, grouped: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 10
        if abs(value) >= 1e12 || (abs(value) > 0 && abs(value) < 1e-7) {
            formatter.numberStyle = .scientific
            formatter.exponentSymbol = "e"
            formatter.maximumSignificantDigits = 8
        } else {
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = grouped
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - 转写辅助

    /// 词元白名单(sqrt 为 √ 的文本别名;log2 转写时由 log2 分支优先命中)
    private static let allowedWords: Set<String> = [
        "sin", "cos", "tan", "asin", "acos", "atan",
        "ln", "log", "sqrt", "ans", "e", "pi",
    ]

    /// 提取全部小写字母词元(连续 [a-z]+ 段)
    private static func wordTokens(in string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[a-z]+") else { return [] }
        let ns = string as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: string, range: range).map { ns.substring(with: $0.range).lowercased() }
    }

    /// 正则全文替换(模板版,支持 $1 捕获组)
    private static func replaceRegex(_ pattern: String, in string: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        let ns = string as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    /// 正则全文替换(闭包版,按命中词元动态生成替换文本)
    private static func replaceRegex(
        _ pattern: String, in string: String, transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        let ns = string as NSString
        var result = ""
        var cursor = 0  // 已拼接到 result 的 UTF-16 偏移
        let full = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: string, range: full) { match, _, _ in
            guard let match = match else { return }
            let word = ns.substring(with: match.range)
            let replacement = transform(word)
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replacement
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// 函数名 → JS 预置函数:三角/反三角按角度模式选 R/D 变体,对数无角度语义
    private static func jsFunctionName(for word: String, angleMode: CalculatorAngleMode) -> String {
        let degrees = angleMode == .degrees
        switch word {
        case "sin": return degrees ? "sinD" : "sinR"
        case "cos": return degrees ? "cosD" : "cosR"
        case "tan": return degrees ? "tanD" : "tanR"
        case "asin": return degrees ? "asinD" : "asinR"
        case "acos": return degrees ? "acosD" : "acosR"
        case "atan": return degrees ? "atanD" : "atanR"
        case "ln": return "lnR"
        case "log": return "logR"
        case "log2": return "log2R"
        case "sqrt": return "sqrtR"
        default: return word
        }
    }

    /// 后缀阶乘转写:操作数为数字字面量或括号组(含函数名前缀),逐个替换为 fact(...)
    private static func translateFactorial(_ input: String) -> String? {
        var s = input
        while let bang = s.firstIndex(of: "!") {
            // "!=" 不是数学输入
            let after = s.index(after: bang)
            if after < s.endIndex, s[after] == "=" { return nil }
            guard let operand = leftOperandRange(in: s, before: bang) else { return nil }
            let text = String(s[operand])
            s.replaceSubrange(operand.lowerBound...bang, with: "fact(\(text))")
        }
        return s
    }

    /// 百分号消歧转写:后继是操作数起始字符 → 中缀取余保留;否则按后缀百分号转写为 ((x)/100)
    private static func translatePercent(_ input: String) -> String? {
        var s = input
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "%" else {
                i = s.index(after: i)
                continue
            }
            let next = s.index(after: i)
            let nextIsOperandStart =
                next < s.endIndex
                && (s[next].isNumber || s[next] == "." || s[next] == "(" || s[next].isLetter
                    || s[next] == "√")
            if nextIsOperandStart {
                // 中缀取余:保留 %,跳过(消费 % 的替换总会推进扫描,不会死循环)
                i = next
                continue
            }
            // 后缀百分号:操作数转写为 ((x)/100),从头再扫(替换后索引失效,% 数量少,代价可忽略)
            guard let operand = leftOperandRange(in: s, before: i) else { return nil }
            let text = String(s[operand])
            s.replaceSubrange(operand.lowerBound..<next, with: "((\(text))/100)")
            i = s.startIndex
        }
        return s
    }

    /// 从 index 左侧扫描后缀运算符(! %)的操作数:连续数字字面量,或括号组(向前吞紧邻函数名)
    static func leftOperandRange(in s: String, before index: String.Index) -> Range<String.Index>? {
        guard index > s.startIndex else { return nil }
        let prev = s.index(before: index)
        let prevChar = s[prev]

        // 数字字面量(含小数点)
        if prevChar.isNumber || prevChar == "." {
            var start = prev
            while start > s.startIndex {
                let p = s.index(before: start)
                if s[p].isNumber || s[p] == "." { start = p } else { break }
            }
            return start..<index
        }

        // 括号组:回扫配对,再向前吞函数名(如 sinR(...) 的 sinR)
        if prevChar == ")" {
            var depth = 0
            var i = prev
            while true {
                if s[i] == ")" { depth += 1 }
                if s[i] == "(" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if i == s.startIndex { return nil }
                i = s.index(before: i)
            }
            var start = i
            while start > s.startIndex, s[s.index(before: start)].isLetter {
                start = s.index(before: start)
            }
            return start..<index
        }

        return nil
    }

    // MARK: - JS 预置函数(仅初始化时注入一次)

    /// fact 越界返回 NaN 由求值侧兜底;三角函数 D 变体按角度换算
    private static let jsPrelude = """
    function fact(n){ if(n<0||n%1!==0||n>170) return NaN; var r=1; for(var i=2;i<=n;i++){r*=i} return r }
    function sinR(x){return Math.sin(x)}
    function sinD(x){return Math.sin(x*Math.PI/180)}
    function cosR(x){return Math.cos(x)}
    function cosD(x){return Math.cos(x*Math.PI/180)}
    function tanR(x){return Math.tan(x)}
    function tanD(x){return Math.tan(x*Math.PI/180)}
    function asinR(x){return Math.asin(x)}
    function asinD(x){return Math.asin(x)*180/Math.PI}
    function acosR(x){return Math.acos(x)}
    function acosD(x){return Math.acos(x)*180/Math.PI}
    function atanR(x){return Math.atan(x)}
    function atanD(x){return Math.atan(x)*180/Math.PI}
    function lnR(x){return Math.log(x)}
    function logR(x){return Math.log10(x)}
    function log2R(x){return Math.log2(x)}
    function sqrtR(x){return Math.sqrt(x)}
    """
}
