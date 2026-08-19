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
            let textContainer = tv.textContainer,
            let scroll = inputScrollView
        else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
        let newHeight = min(max(textHeight + 8, inputMinHeight), inputMaxHeight)
        if let c = inputHeightConstraint, c.constant != newHeight {
            c.constant = newHeight
            view.layoutSubtreeIfNeeded()
        }
        // 文字在输入框内垂直居中（NSTextView 默认顶对齐，与右侧按钮组看起来错位）
        let inset = max(0, (scroll.bounds.height - textHeight) / 2)
        if tv.textContainerInset.height != inset {
            tv.textContainerInset = NSSize(width: 0, height: inset)
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

        // 取消上一次查询；新查询时滚回顶部图表区
        queryTask?.cancel()
        scrollToShowChart()
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

    // MARK: - 分时（双击日K某天 → 独立窗口展示，支持多开比对）

    /// 双击日K蜡烛：立即弹分时窗口（窗内显示查询中），数据到达后回填；不占用主面板 loading/提示
    func handleDayDoubleClick(tsMillis: Int) {
        guard let bundle = bundles.first else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let day = df.string(from: Date(timeIntervalSince1970: TimeInterval(tsMillis) / 1000))

        let intradayWindow = StockIntradayWindowManager.show(
            day: day, code: bundle.code, name: bundle.name,
            columns: settings.exportColumns, context: intradayContext(bundle: bundle, day: day),
            anchor: view.window?.frame)
        let secid = bundle.secid
        // 标题栏刷新按钮：丢弃缓存重走兜底链，重试 zzshare 1 分钟源
        intradayWindow.onRefresh = { [weak self, weak intradayWindow] in
            guard let self, let w = intradayWindow else { return }
            self.loadIntraday(secid: secid, day: day, into: w, forceRefresh: true)
        }
        loadIntraday(secid: secid, day: day, into: intradayWindow, forceRefresh: false)
    }

    /// 拉取某日分时并回填窗口；forceRefresh = true 丢弃缓存重走兜底链，
    /// 失败时保留窗口里已有的粗粒度图，仅短暂提示
    private func loadIntraday(
        secid: String, day: String, into window: StockIntradayWindow, forceRefresh: Bool
    ) {
        if forceRefresh { window.beginRefresh() }
        Task { [weak window] in
            var points: [StockTrendPoint]? = nil
            var err: String? = nil
            do {
                points = try await StockDataService.shared.fetchIntraday(
                    secid: secid, date: day, forceRefresh: forceRefresh)
            } catch { err = error.localizedDescription }
            await MainActor.run {
                guard let w = window else { return }
                if let points = points, !points.isEmpty {
                    w.render(points: points)
                } else if forceRefresh {
                    w.refreshFailed(message: err ?? "无数据")
                } else {
                    w.fail(message: err ?? "无数据")
                }
            }
        }
    }

    /// 分时上下文：昨收 = 前一根日K收盘，量比分母 = 前 5 日日均量，换手率分母 = 流通股本
    private func intradayContext(bundle: StockDataBundle, day: String) -> StockIntradayContext {
        let bars = bundle.chartBars
        // 快照的 circShares 为 0 表示来源缺失（新浪兜底），回退基本面
        let shares = (bundle.snapshot?.circShares ?? 0) > 0
            ? bundle.snapshot?.circShares
            : bundle.fundamentals?.circShares
        guard let idx = bars.firstIndex(where: { $0.date == day }) else {
            // 当日还没进日K（盘中查今天）：最后一根即昨日，量比窗口为含昨日的最后 5 根
            return StockIntradayContext(
                preClose: bars.last?.close,
                avg5Volume: avgVolume(bars, before: bars.count),
                circShares: shares,
                turnoverRate: nil)
        }
        return StockIntradayContext(
            preClose: idx > 0 ? bars[idx - 1].close : nil,
            avg5Volume: avgVolume(bars, before: idx),
            circShares: shares,
            turnoverRate: bars[idx].turnover > 0 ? bars[idx].turnover : nil)
    }

    /// endIdx 之前（不含）最多 5 根的日均量(手)
    private func avgVolume(_ bars: [StockDailyBar], before endIdx: Int) -> Double? {
        let from = max(0, endIdx - 5)
        guard endIdx > from else { return nil }
        let window = bars[from..<endIdx]
        let sum = window.reduce(0) { $0 + $1.volume }
        return sum / Double(window.count)
    }

    // MARK: - 状态辅助

    func setLoading(_ loading: Bool) {
        guard let indicator = loadingIndicator else { return }
        indicator.isHidden = !loading
        if loading { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
    }

    func setAIPlaceholder(_ text: String) {
        // 清空（新查询/新分析）时一并丢弃分段缓冲与挂起的渲染任务
        aiRenderTick?.cancel()
        aiRenderTick = nil
        aiSegments.removeAll()
        guard let tv = aiTextView else { return }
        tv.string = text
    }
}
