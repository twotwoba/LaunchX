import AppKit
import Foundation

extension StockPanelViewController {

    @objc func performAnalyze() {
        // 分析中或已有成功结果：按钮退化为「滚动定位到 AI 区」，不重复请求接口；
        // 上次失败则允许直接重试（重试路径会先清空 AI 区）。重新发起全新分析需先「查询」
        if isAnalyzing || (!(aiTextView?.string ?? "").isEmpty && !lastAnalysisFailed) {
            scrollToShowAI()
            return
        }
        guard let model = settings.defaultModel else {
            appendAI("\n⚠️ 请先在设置中配置 AI 模型（URL/Key/Model）", error: true)
            return
        }
        guard !bundles.isEmpty else {
            appendAI("\n⚠️ 请先「查询」获取数据后再分析", error: true)
            return
        }
        guard let template = currentTemplate else {
            appendAI("\n⚠️ 无可用提示词模板", error: true)
            return
        }

        analyzeTask?.cancel()
        scrollToShowAI()  // 滚动到下方 AI 分析区（图表宽高不变）
        setAIPlaceholder("")
        agentEventLabel?.stringValue = ""
        setLoading(true)
        analyzeButton?.isEnabled = false

        let mode = currentMode
        let copies = bundles

        analyzeTask = Task { [weak self] in
            guard let self = self else { return }
            self.isAnalyzing = true
            self.lastAnalysisFailed = false
            do {
                if mode == .agent {
                    try await StockAIAnalyzer.shared.analyzeAgent(
                        bundles: copies, template: template, model: model,
                        onDelta: { [weak self] chunk in self?.appendAI(chunk) },
                        onReasoning: { [weak self] chunk in self?.appendAI(chunk, style: .reasoning) },
                        onEvent: { [weak self] ev in self?.handleAgentEvent(ev) }
                    )
                } else {
                    try await StockAIAnalyzer.shared.analyzeQuick(
                        bundles: copies, template: template, model: model,
                        onDelta: { [weak self] chunk in self?.appendAI(chunk) },
                        onReasoning: { [weak self] chunk in self?.appendAI(chunk, style: .reasoning) }
                    )
                }
            } catch is CancellationError {
                // 被新分析/查询取消，静默
            } catch {
                self.lastAnalysisFailed = true
                self.appendAI("\n\n❌ 分析失败：\(error.localizedDescription)", error: true)
            }
            await MainActor.run {
                self.isAnalyzing = false
                self.scheduleAIRender(flush: true)  // 流结束：立即渲染最终版（含漏网 chunk）
                self.setLoading(false)
                self.analyzeButton?.isEnabled = true
                self.agentEventLabel?.stringValue = ""
            }
        }
    }

    // MARK: - 流式追加（主线程）

    enum AIOutputStyle {
        case normal
        case reasoning
        case error
    }

    /// 流式 chunk 先落分段缓冲（相邻同风格合并），节流后整体重渲：
    /// 正文段是 Markdown（半截标记会随后续 chunk 自愈），reasoning/错误段保持纯文本
    func appendAI(_ chunk: String, error: Bool = false, style: AIOutputStyle? = nil) {
        let resolved: AIOutputStyle = style ?? (error ? .error : .normal)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.aiTextView != nil, !chunk.isEmpty else { return }
            if !self.aiSegments.isEmpty && self.aiSegments[self.aiSegments.count - 1].style == resolved {
                self.aiSegments[self.aiSegments.count - 1].text += chunk
            } else {
                self.aiSegments.append((resolved, chunk))
            }
            self.scheduleAIRender(flush: false)
        }
    }

    /// 120ms 内的多个 chunk 合并为一次全文重渲（全文重排避免半行标记闪烁跳动）；
    /// flush 立即渲染（流结束/清空时）
    func scheduleAIRender(flush: Bool) {
        aiRenderTick?.cancel()
        aiRenderTick = nil
        if flush {
            renderAI()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.aiRenderTick = nil
            self.renderAI()
        }
        aiRenderTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// 全量重渲 AI 区：钉底跟随（用户上翻阅读时不打扰）
    private func renderAI() {
        guard let tv = aiTextView else { return }
        let pinned = tv.visibleRect.maxY >= tv.bounds.height - 40
        let out = NSMutableAttributedString()
        for seg in aiSegments {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            switch seg.style {
            case .reasoning:
                let ps = NSMutableParagraphStyle()
                ps.paragraphSpacingBefore = 4
                out.append(NSAttributedString(string: seg.text, attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 11),
                    .paragraphStyle: ps,
                ]))
            case .error:
                out.append(NSAttributedString(string: seg.text, attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: 13),
                ]))
            case .normal:
                out.append(MiniMarkdown.render(seg.text))
            }
        }
        tv.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: tv.textStorage?.length ?? 0), with: out)
        if pinned { tv.scrollToEndOfDocument(nil) }
    }

    func handleAgentEvent(_ ev: StockAgentEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch ev {
            case .toolStart(let name, _):
                self.agentEventLabel?.stringValue = "🔧 调用工具：\(name)…"
            case .toolDone(let name, let summary):
                self.agentEventLabel?.stringValue = "✓ \(name)：\(summary)"
            case .fallbackToQuick(let reason):
                self.agentEventLabel?.stringValue = reason
            }
        }
    }
}
