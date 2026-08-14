import AppKit
import Foundation

extension StockPanelViewController {

    @objc func performAnalyze() {
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
        setChartExpanded(false)  // 图表上移，下方展示 AI 分析
        setAIPlaceholder("")
        agentEventLabel?.stringValue = ""
        setLoading(true)
        analyzeButton?.isEnabled = false

        let mode = currentMode
        let copies = bundles

        analyzeTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                if mode == .agent {
                    try await StockAIAnalyzer.shared.analyzeAgent(
                        bundles: copies, template: template, model: model,
                        onDelta: { [weak self] chunk in self?.appendAI(chunk) },
                        onEvent: { [weak self] ev in self?.handleAgentEvent(ev) }
                    )
                } else {
                    try await StockAIAnalyzer.shared.analyzeQuick(
                        bundles: copies, template: template, model: model,
                        onDelta: { [weak self] chunk in self?.appendAI(chunk) }
                    )
                }
            } catch is CancellationError {
                // 被新分析/查询取消，静默
            } catch {
                self.appendAI("\n\n❌ 分析失败：\(error.localizedDescription)", error: true)
            }
            await MainActor.run {
                self.setLoading(false)
                self.analyzeButton?.isEnabled = true
                self.agentEventLabel?.stringValue = ""
            }
        }
    }

    // MARK: - 流式追加（主线程）

    func appendAI(_ chunk: String, error: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let tv = self.aiTextView else { return }
            let attrs: [NSAttributedString.Key: Any]
            if error {
                attrs = [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 13)]
            } else {
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
