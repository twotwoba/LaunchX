import AppKit

// MARK: - 输出段样式

/// AI 输出段样式（正文 Markdown / 思考纯文本 / 错误提示）。
/// 顶层定义：流式渲染器、final 渲染与缓存 Store 共用。
enum AIOutputStyle: String {
    case normal
    case reasoning
    case error

    /// 段文本 → 富文本。final 全量路径与增量路径共用此入口，保证视觉一致。
    func attributed(_ text: String, isContinuation: Bool) -> NSAttributedString {
        switch self {
        case .normal:
            return MiniMarkdown.render(text, isContinuation: isContinuation)
        case .reasoning:
            let ps = NSMutableParagraphStyle()
            ps.paragraphSpacingBefore = 4
            return NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11),
                .paragraphStyle: ps,
            ])
        case .error:
            return NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: 13),
            ])
        }
    }
}

// MARK: - 增量渲染器

/// AI 流式输出的增量渲染器：textStorage = [已提交前缀] + [尾部区域]。
/// - 前缀（安全点之前）永不再改：布局缓存保留，成本 O(新增)
/// - 尾部区域每个 tick 整体替换一次（含新晋稳定块），只 invalidate 尾部
///
/// 稳定边界规则（与 MiniMarkdown 的逐行块解析语义精确对齐）：
/// 安全分割点 = 「空行」末尾换行符之后，且扫描至该处 ``` 围栏均闭合。
/// MiniMarkdown 的所有块类型（段落/列表/引用/表格/代码块）都被空行终止，
/// 行内标记不跨行——空行处切割后，已提交前缀的渲染与全量渲染永远一致。
/// 空行出现时其前所有行必已完整（文本 append-only），fence 状态是终态，
/// 无需为「半截 ```」做额外防御。
///
/// 纯值类型状态机：只产出编辑指令，不触碰 textStorage（可单测）。
/// 用 struct 而非 class：模块默认 MainActor 隔离下，Swift class 在同步非 task
/// 上下文释放会走隔离 deinit 的 back-deploy 路径触发运行时崩溃（XCTest 必崩）；
/// 值语义要求调用方在 computeEdits 后写回持有处。
struct AIStreamRenderer {

    /// 调用方应用到 textStorage 的编辑指令
    enum Edit {
        /// 尾部区域整体替换：from 之前是已提交前缀（永不再改、布局缓存保留）；
        /// 携带内容 = 本次新晋稳定的渲染块 + 段间分隔 + 活跃尾部渲染。
        /// 恒定单条指令：新稳定块随本条进入前缀，上个 tick 的旧尾部渲染被整体覆盖
        case replaceTail(from: Int, with: NSAttributedString)
    }

    /// 单段扫描状态（段文本 append-only，状态可增量推进）
    private struct SegmentState {
        /// 已 append 进 textStorage 的段内 utf16 偏移
        var committed = 0
        /// 已扫描到的段内 utf16 偏移（增量扫描，O(新增)）
        var scanned = 0
        var inFence = false
        /// 当前最大安全点（单调不回退）
        var safePoint = 0
        /// 段完结后补的段间 "\n" 是否已提交
        var separatorAppended = false
    }

    private var segmentStates: [SegmentState] = []
    /// 已提交前缀在 textStorage 中的绝对末尾偏移（跨 tick 累计，含段间 "\n"）。
    /// replaceTail 的 from 必须用这个绝对偏移——各 tick append 的稳定块都在
    /// 光标之前且不再修改，尾部替换若用本 tick 相对偏移会把历史前缀腰斩
    private var prefixEnd = 0

    /// 由 segments 快照计算增量编辑。每次调用恒产出一条尾部替换指令：
    /// [prefixEnd 之前的已提交前缀不动] + [from: prefixEnd 起整体替换为新内容]。
    /// 新晋稳定块不能单独 append——上个 tick 它还是尾部、旧渲染仍躺在 storage 里，
    /// append 会接在旧尾部后面且清不到它，产生残留与重复。
    mutating func computeEdits(for segments: [(style: AIOutputStyle, text: String)]) -> [Edit] {
        // 段数回缩说明外部清空了 aiSegments（正常应走 reset()）；
        // 防御性重建状态，此时 replaceTail(from: 0) 等效全量重渲
        if segmentStates.count > segments.count {
            segmentStates.removeAll()
            prefixEnd = 0
        }
        while segmentStates.count < segments.count {
            segmentStates.append(SegmentState())
        }

        let startPrefix = prefixEnd
        let combined = NSMutableAttributedString()
        var cursor = prefixEnd

        for (idx, seg) in segments.enumerated() {
            var st = segmentStates[idx]
            let text = seg.text
            let isLast = idx == segments.count - 1

            if !isLast {
                // 已完结段：剩余文本一次性提交（段不再增长）
                let utf16Count = text.utf16.count
                if st.committed < utf16Count {
                    let sub = substring(text, from: st.committed, to: utf16Count)
                    let attr = seg.style.attributed(sub, isContinuation: cursor > 0)
                    combined.append(attr)
                    cursor += attr.length
                    st.committed = utf16Count
                }
                // 段间分隔 "\n"（与全量渲染约定一致）
                if !st.separatorAppended {
                    combined.append(NSAttributedString(string: "\n"))
                    cursor += 1
                    st.separatorAppended = true
                }
                segmentStates[idx] = st
                continue
            }

            // 活跃段（最后一段）：推进安全点 → 新稳定块 + 尾部渲染都并入本次替换
            st = advanceScan(text, st: st, plain: seg.style != .normal)
            if st.safePoint > st.committed {
                let sub = substring(text, from: st.committed, to: st.safePoint)
                let attr = seg.style.attributed(sub, isContinuation: cursor > 0)
                combined.append(attr)
                cursor += attr.length
                st.committed = st.safePoint
            }
            segmentStates[idx] = st
            let tailText = substring(text, from: st.safePoint, to: text.utf16.count)
            combined.append(seg.style.attributed(tailText, isContinuation: cursor > 0))
        }

        prefixEnd = cursor
        return [.replaceTail(from: startPrefix, with: combined)]
    }

    /// 已提交前缀长度（测试/调试用：安全点是否推进的可观测信号）
    var committedPrefixLength: Int { prefixEnd }

    /// final 全量渲染后调用：把全部内容对齐为「已提交」状态
    /// （后续即使再有增量 chunk 到达，也从正确前缀继续）
    mutating func align(to segments: [(style: AIOutputStyle, text: String)], totalLength: Int) {
        reset()
        while segmentStates.count < segments.count {
            segmentStates.append(SegmentState())
        }
        for (idx, seg) in segments.enumerated() {
            let utf16Count = seg.text.utf16.count
            segmentStates[idx].committed = utf16Count
            segmentStates[idx].safePoint = utf16Count
            segmentStates[idx].scanned = utf16Count
            segmentStates[idx].separatorAppended = true
        }
        _ = totalLength
        prefixEnd = totalLength  // 对齐为「全部已提交」：后续增量从正确绝对偏移继续
    }

    /// 清空重置（新查询/新分析清空 AI 区时必须调用，否则 offset 错乱）
    mutating func reset() {
        segmentStates.removeAll()
        prefixEnd = 0
    }

    // MARK: - 安全点扫描

    /// 从上次扫描位置增量推进 safePoint（值传入/值传出）。
    /// 不变量：scanned 始终停在行边界（文本起点或某个 \n 之后）——只处理「完整行」
    /// （有终结 \n）；未完结行回退到行首等下个 chunk 重扫。否则流式切断点恰好
    /// 落在行尾 \n 时，恢复位置会被误判为空行，把段落软换行/表格逐行切碎。
    /// plain 段（reasoning/error）无 markdown 解析，任意切点安全，直接推进到段尾。
    private func advanceScan(_ text: String, st: SegmentState, plain: Bool) -> SegmentState {
        var st = st
        if plain {
            st.safePoint = text.utf16.count
            return st
        }
        var idx = String.Index(utf16Offset: st.scanned, in: text)
        while idx < text.endIndex {
            var lineEnd = idx
            while lineEnd < text.endIndex, text[lineEnd] != "\n" {
                lineEnd = text.index(after: lineEnd)
            }
            if lineEnd == text.endIndex {
                // 行未完结（无 \n）：回退到本行行首，内容到齐后重扫整行
                st.scanned = text.utf16.distance(from: text.startIndex, to: idx)
                return st
            }
            let line = String(text[idx..<lineEnd])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if st.inFence {
                if trimmed.hasPrefix("```") { st.inFence = false }
            } else if trimmed.hasPrefix("```") {
                st.inFence = true
            } else if trimmed.isEmpty {
                // 完整空行（两侧都有 \n 或位于文本起点）：末换行符之后即安全点
                let after = text.index(after: lineEnd)
                st.safePoint = text.utf16.distance(from: text.startIndex, to: after)
            }
            idx = text.index(after: lineEnd)
        }
        st.scanned = text.utf16.distance(from: text.startIndex, to: idx)
        return st
    }

    /// utf16 偏移取子串（段文本已归一 \n，无 \r\n 跨界风险）
    private func substring(_ text: String, from: Int, to: Int) -> String {
        guard from < to, from >= 0, to <= text.utf16.count else { return "" }
        let start = String.Index(utf16Offset: from, in: text)
        let end = String.Index(utf16Offset: to, in: text)
        return String(text[start..<end])
    }
}
