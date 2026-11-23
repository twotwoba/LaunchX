import Foundation

/// Brewfile 文本解析器(纯函数,重点单测对象)
///
/// 首选数据源 `brew bundle dump --file=-`(官方 Brewfile 格式,一次拿到 formula/cask/tap);
/// 回退数据源 `brew list --formula/--cask`(一行一个名字)。
/// mas(Mac App Store)条目 MVP 忽略,由 countMasEntries 计数供导入报告提示。
enum BrewfileParser {
    struct Entry: Equatable {
        let kind: BrewPackageKind
        let name: String
        let tap: String?  // 如 "rspm" 或 "user/repo";brew list 回退源无 tap 信息恒为 nil
    }

    // MARK: - Brewfile 文本解析

    /// 解析 Brewfile 文本:
    /// - `brew "name"` / `brew "tap/name"` → formula
    /// - `cask "name"` → cask
    /// - 注释行/空行忽略;`tap`/`mas` 等其他指令忽略
    /// - 带参数行(`brew "name", restart_service: true`)取第一个引号参数
    /// - 容忍无引号的裸 token(`brew wget`)
    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard let verb = firstBareToken(line)?.lowercased() else { continue }
            switch verb {
            case "brew":
                if let arg = firstArgument(after: verb, in: line) {
                    if let entry = makeEntry(kind: .formula, rawName: arg) {
                        entries.append(entry)
                    }
                }
            case "cask":
                if let arg = firstArgument(after: verb, in: line) {
                    if let entry = makeEntry(kind: .cask, rawName: arg) {
                        entries.append(entry)
                    }
                }
            default:
                continue  // tap / mas / vsco 等,忽略
            }
        }
        return entries
    }

    /// 统计 Brewfile 中 mas(App Store)条目数(导入报告用)
    static func countMasEntries(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("mas ") || $0.hasPrefix("mas\t") }
            .count
    }

    // MARK: - brew list 输出解析(回退源)

    /// 解析 `brew list --formula/--cask` 输出(一行一个名字)
    static func parseListOutput(_ text: String, kind: BrewPackageKind) -> [Entry] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .compactMap { line in
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
                return makeEntry(kind: kind, rawName: line)
            }
    }

    // MARK: - 内部实现

    /// 由原始名字构造条目;含 "/" 视为 tap 前缀;名字不合法返回 nil
    private static func makeEntry(kind: BrewPackageKind, rawName: String) -> Entry? {
        var tap: String?
        var name = rawName.trimmingCharacters(in: .whitespaces)

        if name.contains("/") {
            let components = name.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count >= 2, let last = components.last else { return nil }
            tap = components.dropLast().joined(separator: "/")
            name = String(last)
        }

        guard isValidName(name) else { return nil }
        return Entry(kind: kind, name: name, tap: tap)
    }

    /// 包名白名单:字母/数字/@/./_/+/-(同时防 shell 注入,提权命令拼接前必须过此校验)
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@/._+-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 提取行首第一个裸 token(动词)
    private static func firstBareToken(_ line: String) -> String? {
        let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.first.map(String.init)
    }

    /// 提取动词后的第一个参数:优先引号字符串,容忍裸 token(到空白/逗号为止)
    private static func firstArgument(after verb: String, in line: String) -> String? {
        // 跳过动词本体
        var rest = line.dropFirst(verb.count)
        // 跳过空白
        while let first = rest.first, first == " " || first == "\t" {
            rest = rest.dropFirst()
        }
        guard let quote = rest.first else { return nil }
        if quote == "\"" || quote == "'" {
            let inner = rest.dropFirst()
            if let end = inner.firstIndex(of: quote) {
                return String(inner[..<end])
            }
            // 引号未闭合:取到行尾
            return String(inner)
        }
        // 裸 token:到空白或逗号为止
        let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "," }) ?? rest.endIndex
        return String(rest[..<end])
    }
}
