import AppKit
import Foundation

extension StockPanelViewController: NSTextViewDelegate {

    // MARK: - 输入代理

    func textDidChange(_ notification: Notification) {
        guard let tv = inputTextView else { return }
        inputPlaceholder?.isHidden = !tv.string.isEmpty
        updateInputHeight()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Shift+回车换行，普通回车触发查询
            if NSEvent.modifierFlags.contains(.shift) { return false }
            performQuery()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            StockPanelManager.shared.forceHidePanel()
            return true
        }
        return false
    }

    // MARK: - 输入框高度自适应

    func updateInputHeight() {
        guard let tv = inputTextView,
            let layoutManager = tv.layoutManager,
            let textContainer = tv.textContainer
        else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
        let newHeight = min(max(textHeight + 8, inputMinHeight), inputMaxHeight)
        if let c = inputHeightConstraint, c.constant != newHeight {
            c.constant = newHeight
            view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - 查询

    @objc func performQuery() {
        guard let raw = inputTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return }

        guard let query = StockQueryParser.parse(raw) else {
            chartView?.showError("无法解析输入，示例：600519 或 贵州茅台")
            return
        }

        // 取消上一次查询；新查询时图表重新铺满面板（折叠 AI 区）
        queryTask?.cancel()
        setChartExpanded(true)
        setLoading(true)
        chartView?.showHint("正在查询…")
        setAIPlaceholder("")

        queryTask = Task { [weak self] in
            guard let self = self else { return }
            var bundle: StockDataBundle? = nil
            var errorMsg: String? = nil
            do {
                try Task.checkCancellation()
                bundle = try await StockDataService.shared.fetchBundle(query)
            } catch let e as StockError {
                if case .multipleCandidates(let cands) = e {
                    errorMsg = "「\(query.name ?? query.input)」匹配到多个：\n" +
                        cands.map { "  \($0.code) \($0.name)（\($0.marketName)）" }
                            .joined(separator: "\n") + "\n请用更精确的代码/名称。"
                } else {
                    errorMsg = "查询「\(query.name ?? query.input)」失败：\(e.localizedDescription)"
                }
            } catch is CancellationError {
                return
            } catch {
                errorMsg = "查询「\(query.name ?? query.input)」失败：\(error.localizedDescription)"
            }
            await MainActor.run {
                self.bundles = bundle.map { [$0] } ?? []
                self.renderChart(bundle: bundle, errorMsg: errorMsg)
                self.setLoading(false)
            }
        }
    }

    // MARK: - 渲染图表

    func renderChart(bundle: StockDataBundle?, errorMsg: String?) {
        guard let chart = chartView else { return }
        if let bundle = bundle {
            chart.update(bars: bundle.chartBars)
        } else if let m = errorMsg {
            chart.showError(m)
        }
    }

    // MARK: - 导出

    @objc func copyCSV() {
        guard !bundles.isEmpty else { return }
        StockExporter.copyCSV(bundles: bundles)
        flashButton(copyCSVButton)
    }

    // MARK: - 状态辅助

    func setLoading(_ loading: Bool) {
        guard let indicator = loadingIndicator else { return }
        indicator.isHidden = !loading
        if loading { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
    }

    func setAIPlaceholder(_ text: String) {
        guard let tv = aiTextView else { return }
        tv.string = text
    }

    func flashButton(_ button: NSButton?) {
        guard let button = button else { return }
        let original = button.title
        button.title = "已复制 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            button.title = original
        }
    }
}
