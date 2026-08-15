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

    func appendAI(_ chunk: String, error: Bool = false, style: AIOutputStyle? = nil) {
        let resolved: AIOutputStyle = style ?? (error ? .error : .normal)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let tv = self.aiTextView else { return }
            let attrs: [NSAttributedString.Key: Any]
            switch resolved {
            case .error:
                attrs = [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 13)]
            case .reasoning:
                attrs = [
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 11),
                ]
            case .normal:
                attrs = [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13)]
            }
            let attr = NSAttributedString(string: chunk, attributes: attrs)
            tv.textStorage?.append(attr)
            tv.scrollToEndOfDocument(nil)
        }
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
