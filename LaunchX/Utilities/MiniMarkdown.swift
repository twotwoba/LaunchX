import AppKit

/// 轻量 Markdown → NSAttributedString 渲染器，用于 AI 分析流式输出的富文本展示。
/// 覆盖 AI 输出常见子集：ATX 标题、分隔线、引用块、无序/有序列表（两级嵌套）、
/// 围栏代码块、管道表格（等宽对齐）；行内支持 粗体/斜体/删除线/行内代码/链接。
/// 整体渲染（非增量），配合上层节流（120ms）足够流式场景使用；
/// 增量渲染场景传 isContinuation: true（本段是文档中段，首块仍按非首块计间距）。
enum MiniMarkdown {

    // MARK: - 基础样式

    /// 渲染上下文：输出缓冲 + 首块标记（决定各块段首间距，替代 out.length == 0 判断，
    /// 使「稳定前缀 + 活跃尾部」的拼接渲染与全量渲染间距一致）。
    /// 用 struct：模块默认 MainActor 隔离下，Swift class 在同步非 task 上下文释放
    /// 会走隔离 deinit 的 back-deploy 路径触发运行时崩溃（XCTest 同步用例必崩）
    private struct RenderContext {
        let out = NSMutableAttributedString()
        var isFirstBlock = true
    }

    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let tableFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// 代码块/行内代码底色（深色玻璃面板与亮色模式各自适配）
    private static let codeBackground = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        return dark ? NSColor.white.withAlphaComponent(0.08)
                    : NSColor.black.withAlphaComponent(0.06)
    }

    /// 行内标记：行内代码 / 粗体 / 斜体* / 斜体_ / 删除线 / [文本](链接)
    private static let inlineRegex = try! NSRegularExpression(pattern:
        "(`[^`\\n]+`)"                        // 1 行内代码
        + "|(\\*\\*[^*\\n]+\\*\\*)"           // 2 粗体
        + "|(\\*[^*\\n]+\\*)"                 // 3 斜体 *
        + "|(__[^_\\n]+__)"                   // 4 斜体 _
        + "|(~~[^~\\n]+~~)"                   // 5 删除线
        + "|(\\[[^\\]\\n]+\\]\\([^)\\s]+\\))" // 6 链接
    )

    // MARK: - 入口

    /// - Parameter isContinuation: 本段文本在完整文档中位于其他内容之后（增量渲染的
    ///   稳定前缀/活跃尾部拼接场景）。影响首块的段首间距，使拼接结果与全量渲染一致。
    static func render(_ markdown: String, isContinuation: Bool = false) -> NSAttributedString {
        var ctx = RenderContext()
        ctx.isFirstBlock = !isContinuation
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // 围栏代码块（流式中未闭合的 ``` 视为延续到末尾，避免闪烁）
            if trimmed.hasPrefix("```") {
                i += 1
                var code: [String] = []
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }  // 跳过收尾 ```
                appendCodeBlock(code, into: &ctx)
                continue
            }
            if let (level, text) = parseHeading(trimmed) {
                appendHeading(text, level: level, into: &ctx)
                i += 1
                continue
            }
            if isHRule(trimmed) {
                appendHRule(into: &ctx)
                i += 1
                continue
            }
            // 表格：当前行含 | 且下一行是 |---|---| 分隔行
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                var rows: [[String]] = [tableCells(trimmed)]
                i += 2  // 表头 + 分隔行
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    rows.append(tableCells(t))
                    i += 1
                }
                appendTable(rows, into: &ctx)
                continue
            }
            // 引用块
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !t.hasPrefix(">") { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                appendQuote(quote.joined(separator: " "), into: &ctx)
                continue
            }
            // 列表（含缩进续行）
            if parseListItem(trimmed) != nil {
                var items: [(level: Int, marker: String, text: String)] = []
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if let item = parseListItem(t) {
                        let level = leadingSpaces(of: l) >= 2 ? 1 : 0
                        items.append((level, item.marker, item.text))
                        i += 1
                    } else if !t.isEmpty, leadingSpaces(of: l) >= 2 {
                        // 列表项折行：并入上一条，避免被拆成独立段落
                        items[items.count - 1].text += " " + t
                        i += 1
                    } else {
                        break
                    }
                }
                appendList(items, into: &ctx)
                continue
            }
            // 普通段落：连续普通行合并（软换行 → 空格）
            var para = [trimmed]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || isBlockStart(t) { break }
                para.append(t)
                i += 1
            }
            appendParagraph(para.joined(separator: " "), into: &ctx)
        }
        return ctx.out
    }

    // MARK: - 块级元素

    private static func appendHeading(_ text: String, level: Int, into ctx: inout RenderContext) {
        let out = ctx.out
        let size: CGFloat = [1: 16, 2: 15, 3: 14][min(level, 3)] ?? 13
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let ps = paraStyle(first: ctx.isFirstBlock)
        ps.paragraphSpacingBefore = ctx.isFirstBlock ? 0 : 10
        ps.paragraphSpacing = 4
        out.append(NSAttributedString(string: text + "\n", attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: ps,
        ]))
        ctx.isFirstBlock = false
    }

    private static func appendParagraph(_ text: String, into ctx: inout RenderContext) {
        let out = ctx.out
        let ps = paraStyle(first: ctx.isFirstBlock)
        ps.lineSpacing = 3
        ps.paragraphSpacing = 5
        inline(text, into: out, base: [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: ps,
        ])
        out.append(NSAttributedString(string: "\n"))
        ctx.isFirstBlock = false
    }

    private static func appendQuote(_ text: String, into ctx: inout RenderContext) {
        let out = ctx.out
        let ps = paraStyle(first: ctx.isFirstBlock)
        ps.firstLineHeadIndent = 10
        ps.headIndent = 10
        ps.lineSpacing = 2
        ps.paragraphSpacing = 6
        let font = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
        inline(text, into: out, base: [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: ps,
        ])
        out.append(NSAttributedString(string: "\n"))
        ctx.isFirstBlock = false
    }

    private static func appendHRule(into ctx: inout RenderContext) {
        let out = ctx.out
        let ps = paraStyle(first: ctx.isFirstBlock)
        ps.alignment = .center
        ps.paragraphSpacingBefore = 6
        ps.paragraphSpacing = 6
        out.append(NSAttributedString(string: "────────────\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.separatorColor,
            .paragraphStyle: ps,
        ]))
        ctx.isFirstBlock = false
    }

    private static func appendCodeBlock(_ lines: [String], into ctx: inout RenderContext) {
        let out = ctx.out
        // 单一段落内用 \n 换行：底色连续不断档
        let ps = paraStyle(first: ctx.isFirstBlock)
        ps.paragraphSpacingBefore = 6
        ps.paragraphSpacing = 6
        ps.firstLineHeadIndent = 6
        ps.headIndent = 6
        ps.lineSpacing = 2
        out.append(NSAttributedString(string: lines.joined(separator: "\n") + "\n", attributes: [
            .font: codeFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: codeBackground,
            .paragraphStyle: ps,
        ]))
        ctx.isFirstBlock = false
    }

    private static func appendList(
        _ items: [(level: Int, marker: String, text: String)], into ctx: inout RenderContext
    ) {
        let out = ctx.out
        for (idx, item) in items.enumerated() {
            let ps = paraStyle(first: ctx.isFirstBlock)
            let indent = CGFloat(4 + item.level * 16)
            ps.firstLineHeadIndent = indent
            ps.headIndent = indent + 16  // 折行对齐到正文，避开序号
            ps.lineSpacing = 2
            ps.paragraphSpacing = idx == items.count - 1 ? 6 : 3
            // 序号/圆点置灰，正文正常色；嵌套无序项换空心圆点区分层级
            let marker = item.level > 0 && item.marker == "•" ? "◦" : item.marker
            out.append(NSAttributedString(string: marker + " ", attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: ps,
            ]))
            inline(item.text, into: out, base: [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: ps,
            ])
            out.append(NSAttributedString(string: "\n"))
        }
        ctx.isFirstBlock = false
    }

    private static func appendTable(_ rows: [[String]], into ctx: inout RenderContext) {
        let out = ctx.out
        guard !rows.isEmpty else { return }
        let colCount = rows.map(\.count).max() ?? 0
        guard colCount > 0 else { return }
        // 补齐缺cell，逐列取显示宽（CJK 记 2）后等宽字体对齐
        let padded = rows.map { row -> [String] in
            var r = row
            while r.count < colCount { r.append("") }
            return r
        }
        let widths = (0..<colCount).map { c in padded.map { displayWidth($0[c]) }.max() ?? 0 }

        let ps = paraStyle(first: ctx.isFirstBlock)
        ps.paragraphSpacingBefore = 6
        ps.paragraphSpacing = 6
        ps.headIndent = 4

        for (r, row) in padded.enumerated() {
            let line = zip(row, widths).map { cell, w in pad(cell, to: w) }
                .joined(separator: " | ")
            var attrs: [NSAttributedString.Key: Any] = [
                .font: r == 0
                    ? NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
                    : tableFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: ps,
            ]
            if r == 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        ctx.isFirstBlock = false
    }

    // MARK: - 行内元素

    /// 从 base 属性出发扫描行内标记，嵌套标记（粗体内斜体等）递归处理
    private static func inline(
        _ text: String, into out: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any]
    ) {
        let ns = text as NSString
        var loc = 0
        while loc < ns.length {
            let rest = NSRange(location: loc, length: ns.length - loc)
            guard let m = inlineRegex.firstMatch(in: text, range: rest) else {
                out.append(NSAttributedString(string: ns.substring(from: loc), attributes: base))
                break
            }
            if m.range.location > loc {
                let plain = NSRange(location: loc, length: m.range.location - loc)
                out.append(NSAttributedString(string: ns.substring(with: plain), attributes: base))
            }
            applyInlineToken(ns.substring(with: m.range), into: out, base: base)
            loc = m.range.location + m.range.length
        }
    }

    private static func applyInlineToken(
        _ token: String, into out: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any]
    ) {
        var attrs = base
        if token.hasPrefix("`") {
            // 行内代码：等宽 + 底色，内容不再递归
            attrs[.font] = codeFont
            attrs[.backgroundColor] = codeBackground
            out.append(NSAttributedString(
                string: String(token.dropFirst().dropLast()), attributes: attrs))
            return
        }
        if token.hasPrefix("**") || token.hasPrefix("__") {
            let inner = String(token.dropFirst(2).dropLast(2))
            inline(inner, into: out, base: withTrait(base, trait: token.hasPrefix("**") ? .boldFontMask : .italicFontMask))
            return
        }
        if token.hasPrefix("*") {
            inline(String(token.dropFirst().dropLast()), into: out, base: withTrait(base, trait: .italicFontMask))
            return
        }
        if token.hasPrefix("~~") {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            inline(String(token.dropFirst(2).dropLast(2)), into: out, base: attrs)
            return
        }
        if token.hasPrefix("[") {
            // [文本](URL)：文本按链接样式渲染，可点击
            let inner = String(token.dropFirst().dropLast())  // 文本](URL
            let parts = inner.components(separatedBy: "](")
            if parts.count == 2, let url = URL(string: parts[1]) {
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor.controlAccentColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                inline(parts[0], into: out, base: attrs)
                return
            }
            out.append(NSAttributedString(string: token, attributes: base))
            return
        }
        out.append(NSAttributedString(string: token, attributes: base))
    }

    /// 在 base 的字体上叠加字形 trait（粗/斜），其余属性原样传递以支持嵌套
    private static func withTrait(
        _ base: [NSAttributedString.Key: Any], trait: NSFontTraitMask
    ) -> [NSAttributedString.Key: Any] {
        var attrs = base
        let font = (base[.font] as? NSFont) ?? bodyFont
        attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: trait)
        return attrs
    }

    // MARK: - 解析辅助

    private static func paraStyle(first: Bool) -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacingBefore = first ? 0 : 4
        return ps
    }

    /// #/##… 标题；要求 # 后跟空格（避免误伤 `#001` 这类文本）
    private static func parseHeading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.hasPrefix(" ") else { return nil }
        var text = rest.drop(while: { $0 == " " })
        while text.hasSuffix("#") { text = text.dropLast() }
        let clean = text.trimmingCharacters(in: .whitespaces)
        return (hashes, clean)
    }

    /// 分隔线：--- / *** / ___（≥3 个同类字符）
    private static func isHRule(_ line: String) -> Bool {
        guard line.count >= 3,
              let first = line.first,
              ["-", "*", "_"].contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    /// 表格分隔行：形如 | --- | :---: |，仅由 : | - 空格构成且含 |
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        return t.allSatisfy { ":|- ".contains($0) }
    }

    /// 行首列表项：`- ` / `* ` / `+ ` / `1. ` / `1) `，返回显示用序号与正文
    private static func parseListItem(_ line: String) -> (marker: String, text: String)? {
        for m in ["-", "*", "+"] where line == m {
            return ("•", "")
        }
        for m in ["- ", "* ", "+ "] where line.hasPrefix(m) {
            return ("•", String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (String(digits) + ".", String(rest.dropFirst(2)))
            }
            if rest == "." || rest == ")" {
                return (String(digits) + ".", "")
            }
        }
        return nil
    }

    /// 普通段落合并的终止条件：下一行是任一块级元素起点
    private static func isBlockStart(_ t: String) -> Bool {
        t.hasPrefix("```") || t.hasPrefix(">")
            || parseHeading(t) != nil || isHRule(t) || parseListItem(t) != nil
    }

    private static func leadingSpaces(of line: String) -> Int {
        line.count - line.drop(while: { $0 == " " }).count
    }

    /// CJK 与全角字符等宽占 2，其余占 1（Menlo 下对齐用）
    private static func displayWidth(_ s: String) -> Int {
        s.reduce(0) { sum, ch in sum + (isWide(ch) ? 2 : 1) }
    }

    private static func isWide(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }

    /// 右侧补空格到目标显示宽
    private static func pad(_ cell: String, to width: Int) -> String {
        var s = cell
        var w = displayWidth(s)
        while w < width { s += " "; w += 1 }
        return s
    }

    /// 去掉首尾表格线 | 后按 | 切列
    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|") { t = String(t.dropLast()) }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
