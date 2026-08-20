import XCTest
@testable import LaunchX

/// AI 流式增量渲染器：安全分割点（空行 + fence 闭合）与拼接等值测试。
/// 核心不变量：任意流式切分下，增量应用的结果与流结束后的全量渲染一致。
final class AIStreamRendererTests: XCTestCase {

    /// 模拟 textStorage 应用编辑指令
    private func apply(
        _ edits: [AIStreamRenderer.Edit], to storage: NSMutableAttributedString
    ) {
        for edit in edits {
            guard case .replaceTail(let from, let attr) = edit else { continue }
            let range = NSRange(location: from, length: max(0, storage.length - from))
            if range.length > 0 || attr.length > 0 {
                storage.replaceCharacters(in: range, with: attr)
            }
        }
    }

    /// 覆盖全部 markdown 元素的样本（含 fence 内空行、表格、引用、多级列表）
    private let sample = [
        "# 标题",
        "正文段落，含 **加粗**、*斜体*、`行内码`。",
        "",
        "- 列表项一",
        "- 列表项二",
        "",
        "```swift",
        "let code = \"fence 内空行\"",
        "",
        "print(code)",
        "```",
        "",
        "| 指标 | 数值 |",
        "| --- | --- |",
        "| 市盈率 | 12.3 |",
        "| 市净率 | 2.1 |",
        "",
        "> 引用块内容",
        "",
        "1. 有序一",
        "2. 有序二",
        "",
        "结尾段落。",
    ].joined(separator: "\n")

    /// 拼接等值：任意粒度流式喂入，最终结果 == 全量渲染（.string 级一致）
    func testIncrementalFeedsMatchFullRender() {
        let expected = MiniMarkdown.render(sample).string
        let total = sample.utf16.count
        for grain in [1, 3, 7, 31, 97] {
            var renderer = AIStreamRenderer()
            let storage = NSMutableAttributedString()
            var fed = 0
            while fed < total {
                fed = min(total, fed + grain)
                let idx = String.Index(utf16Offset: fed, in: sample)
                let snapshot = [(style: AIOutputStyle.normal, text: String(sample[..<idx]))]
                apply(renderer.computeEdits(for: snapshot), to: storage)
            }
            // 流结束：final 全量渲染路径（与应用后的 storage 等值）
            XCTAssertEqual(storage.string, expected, "grain=\(grain) 时增量结果与全量渲染不一致")
        }
    }

    /// reasoning 段先出、normal 段后出（推理模型典型流），分段推进等值
    func testReasoningThenNormalSegments() {
        let reasoning = "让我思考一下这段行情的走势…\n需要结合均线与量能。"
        var renderer = AIStreamRenderer()
        let storage = NSMutableAttributedString()

        // 阶段一：只有 reasoning 段
        apply(renderer.computeEdits(for: [(.reasoning, reasoning)]), to: storage)
        XCTAssertTrue(storage.string.contains("让我思考"))

        // 阶段二：normal 段开始（reasoning 段完结）
        var normal = "## 结论\n\n短期偏多。\n"
        apply(
            renderer.computeEdits(for: [(.reasoning, reasoning), (.normal, normal)]),
            to: storage)
        // 阶段三：normal 段继续增长
        normal += "\n- 关注 20 日线支撑\n"
        apply(
            renderer.computeEdits(for: [(.reasoning, reasoning), (.normal, normal)]),
            to: storage)

        let expected = NSMutableAttributedString()
        expected.append(AIOutputStyle.reasoning.attributed(reasoning, isContinuation: false))
        expected.append(NSAttributedString(string: "\n"))
        expected.append(AIOutputStyle.normal.attributed(normal, isContinuation: true))
        XCTAssertEqual(storage.string, expected.string)
    }

    /// fence 内的空行不是安全点：fence 未闭合前稳定前缀不推进
    func testBlankLineInsideFenceIsNotSafePoint() {
        var renderer = AIStreamRenderer()
        // fence 开启后内部空行
        let midFence = "```\ncode\n\nmore"
        _ = renderer.computeEdits(for: [(.normal, midFence)])
        XCTAssertEqual(renderer.committedPrefixLength, 0, "fence 内空行不应推进稳定点")

        // fence 闭合后的空行才是安全点
        let closed = midFence + "\n```\n\nfence 后的段落"
        let edits2 = renderer.computeEdits(for: [(.normal, closed)])
        XCTAssertGreaterThan(
            renderer.committedPrefixLength, 0, "fence 闭合后空行应产生稳定块")
        let storage = NSMutableAttributedString()
        apply(edits2, to: storage)
        XCTAssertTrue(storage.string.contains("code"))
        XCTAssertTrue(storage.string.contains("more"))
        XCTAssertTrue(storage.string.contains("fence 后的段落"))
    }

    /// 表格流出中途无安全点；表格后的空行推进稳定点
    func testTableBoundaries() {
        var renderer = AIStreamRenderer()
        // 表格行间无空行：稳定前缀不推进
        let midTable = "| a | b |\n| --- | --- |\n| 1 |"
        _ = renderer.computeEdits(for: [(.normal, midTable)])
        XCTAssertEqual(renderer.committedPrefixLength, 0, "表格中途不应推进稳定点")

        let done = midTable + "\n\n表格后的段落"
        let edits2 = renderer.computeEdits(for: [(.normal, done)])
        XCTAssertGreaterThan(renderer.committedPrefixLength, 0, "表格后空行应推进稳定点")
        let storage = NSMutableAttributedString()
        apply(edits2, to: storage)
        // 渲染后的表格剥掉首尾管线、按列宽补齐：表头行为 "a | b"
        XCTAssertTrue(storage.string.contains("a | b"), "表格应整体进入稳定渲染")
    }

    /// "``"（两个反引号）完整行永远不是 fence 开，其后空行仍安全
    func testTwoBackticksLineIsNotFence() {
        var renderer = AIStreamRenderer()
        let text = "段落\n\n``\n\n后续"
        let edits = renderer.computeEdits(for: [(.normal, text)])
        // "段落" 后的空行是安全点：应已提交
        XCTAssertGreaterThan(renderer.committedPrefixLength, 0)
        // 等值：最终 storage 与全量渲染一致
        let storage = NSMutableAttributedString()
        apply(edits, to: storage)
        XCTAssertEqual(storage.string, MiniMarkdown.render(text).string)
    }

    /// 无空行的长文本：安全点停留，全部内容留在活跃尾部（每次整体重渲该段）
    func testNoBlankLineKeepsEverythingInTail() {
        var renderer = AIStreamRenderer()
        let text = "很长的一行没有空行一直延续"
        let edits = renderer.computeEdits(for: [(.normal, text)])
        XCTAssertEqual(renderer.committedPrefixLength, 0, "无空行不应推进稳定点")
        guard case .replaceTail(let from, _)? = edits.first else {
            return XCTFail("应有尾部替换指令")
        }
        XCTAssertEqual(from, 0)
    }

    /// reset 后状态归零：行为应与全新渲染器完全一致（绝对偏移从头累计）
    func testResetRestartsFromZero() {
        var renderer = AIStreamRenderer()
        _ = renderer.computeEdits(for: [(.normal, "第一段\n\n第二段")])
        renderer.reset()
        let afterReset = renderer.computeEdits(for: [(.normal, "新内容\n\n新段落")])
        var fresh = AIStreamRenderer()
        let freshEdits = fresh.computeEdits(for: [(.normal, "新内容\n\n新段落")])
        XCTAssertEqual(
            afterReset.map(editSummary), freshEdits.map(editSummary),
            "reset 后应与全新渲染器行为一致")
    }

    /// 编辑指令的可比较摘要（replaceTail 偏移+内容）
    private func editSummary(_ e: AIStreamRenderer.Edit) -> String {
        guard case .replaceTail(let f, let a) = e else { return "?" }
        return "tail(\(f)):\(a.string)"
    }
}
