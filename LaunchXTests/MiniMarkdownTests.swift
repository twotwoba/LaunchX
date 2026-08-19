import XCTest
@testable import LaunchX

final class MiniMarkdownTests: XCTestCase {

    // MARK: - 行内元素

    func testBoldItalicRenderedAsFontTraits() {
        let out = MiniMarkdown.render("**重点** 正文 *斜体*")
        let str = out.string
        XCTAssertFalse(str.contains("**"), "粗体标记应被剥离: \(str)")
        XCTAssertFalse(str.contains("*"), "斜体标记应被剥离: \(str)")
        XCTAssertTrue(str.contains("重点"))
        // 粗体段字号仍是 13，但 trait 应为粗体
        var boldRange = NSRange(location: 0, length: 0)
        var foundBold = false
        out.enumerateAttribute(.font, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            if let f = value as? NSFont, f.fontDescriptor.symbolicTraits.contains(.bold) {
                foundBold = true
                boldRange = range
            }
        }
        XCTAssertTrue(foundBold, "应存在粗体 run")
        let boldText = (out.string as NSString).substring(with: boldRange)
        XCTAssertEqual(boldText, "重点")
    }

    func testInlineCode() {
        let out = MiniMarkdown.render("参数 `MA5` 保持默认")
        XCTAssertFalse(out.string.contains("`"))
        XCTAssertTrue(out.string.contains("MA5"))
        var hasBg = false
        out.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: out.length)) { v, _, stop in
            if v != nil { hasBg = true; stop.pointee = true }
        }
        XCTAssertTrue(hasBg, "行内代码应有底色")
    }

    func testLink() {
        let out = MiniMarkdown.render("参见 [文档](https://example.com/a) 说明")
        var link: URL?
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { v, _, stop in
            if let u = v as? URL { link = u; stop.pointee = true }
        }
        XCTAssertEqual(link?.absoluteString, "https://example.com/a")
        XCTAssertFalse(out.string.contains("["))
        XCTAssertTrue(out.string.contains("文档"))
    }

    // MARK: - 块级元素

    func testHeadingAndList() {
        let out = MiniMarkdown.render("""
        ### 一、大盘走势
        - 上证指数放量上攻
        - 创业板指缩量整理
          - 尾盘回拉
        1. 第一支撑 3200
        2. 第二支撑 3150
        """)
        let s = out.string
        XCTAssertTrue(s.contains("一、大盘走势"))
        XCTAssertFalse(s.contains("###"))
        XCTAssertTrue(s.contains("• 上证指数放量上攻"))
        XCTAssertTrue(s.contains("1. 第一支撑 3200"))
        // 嵌套列表有二级圆点
        XCTAssertTrue(s.contains("◦"), "二级列表应用不同圆点")
    }

    func testCodeBlockMonospacedBackground() {
        let out = MiniMarkdown.render("正文\n```\nlet a = 1\nlet b = 2\n```\n结尾")
        XCTAssertFalse(out.string.contains("```"))
        XCTAssertTrue(out.string.contains("let a = 1"))
        var mono = false, bg = false
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { attrs, _, _ in
            if let f = attrs[.font] as? NSFont, f.fontDescriptor.symbolicTraits.contains(.monoSpace) { mono = true }
            if attrs[.backgroundColor] != nil { bg = true }
        }
        XCTAssertTrue(mono, "代码块应用等宽字体")
        XCTAssertTrue(bg, "代码块应有底色")
    }

    func testTableAlignmentDropsSeparatorRow() {
        let out = MiniMarkdown.render("""
        | 指标 | 数值 | 评价 |
        | --- | ---: | :--- |
        | 换手率 | 2.4% | 偏高 |
        | 量比 | 1.30 | 正常 |
        """)
        let s = out.string
        XCTAssertFalse(s.contains("---"), "分隔行应被吃掉")
        XCTAssertTrue(s.contains("换手率"))
        XCTAssertTrue(s.contains("1.30"))
        // 各行按列对齐：两行的「换手率/量比」列起始位置一致（等宽填充）
        let lines = s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("指标"), "首列不应有多余前导空格: \(lines[0])")
        XCTAssertTrue(lines[1].hasPrefix("换手率"), "数据行首列应与表头同宽对齐: \(lines[1])")
        // 等宽对齐：各行竖线数量一致（3 列 → 2 个 |）
        XCTAssertEqual(Set(lines.map { $0.filter { $0 == "|" }.count }), [2], "各行竖线数量应一致: \(lines)")
    }

    func testUnterminatedFenceRendersAsCode() {
        // 流式中间态：``` 已到但内容/收尾未到
        let out = MiniMarkdown.render("分析中\n```\n部分代码")
        XCTAssertTrue(out.string.contains("部分代码"))
        var mono = false
        out.enumerateAttribute(.font, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if let f = v as? NSFont, f.fontDescriptor.symbolicTraits.contains(.monoSpace) { mono = true }
        }
        XCTAssertTrue(mono, "未闭合围栏也应按代码块渲染")
    }

    func testQuoteAndHRule() {
        let out = MiniMarkdown.render("> 免责：仅供参考\n---\n正文")
        XCTAssertTrue(out.string.contains("免责：仅供参考"))
        XCTAssertFalse(out.string.contains("> "))
        XCTAssertFalse(out.string.contains("---"))
    }

    func testPlainChineseTextUnchanged() {
        let text = "今日市场震荡上行，成交额 1.2 万亿。"
        let out = MiniMarkdown.render(text)
        XCTAssertEqual(out.string.trimmingCharacters(in: .whitespacesAndNewlines), text)
    }

    func testIncrementalRenderIdempotent() {
        // 模拟流式：半截标记先渲染，补齐后重渲应得到最终形态
        let partial = MiniMarkdown.render("## 结论\n支撑位 **32")
        let full = MiniMarkdown.render("## 结论\n支撑位 **3200**，压力位 3300")
        // 半截时 ** 原样保留（无法配对），补齐后剥离
        XCTAssertTrue(partial.string.contains("**"))
        XCTAssertFalse(full.string.contains("**"))
        XCTAssertTrue(full.string.contains("3200"))
    }
}
