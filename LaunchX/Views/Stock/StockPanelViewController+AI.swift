import AppKit
import Foundation

extension StockPanelViewController {

    @objc func performAnalyze() {
        // 分析中或已有成功结果：按钮退化为「滚动定位到 AI 区」，不重复请求接口；
        // 上次失败则允许直接重试（重试路径会先清空 AI 区）。重新发起全新分析需先「查询」。
        // 缓存装载态例外：再次点击 = 清空并重新生成（走网络，成功后覆盖同 key）
        if isAnalyzing || (!(aiTextView?.string ?? "").isEmpty && !lastAnalysisFailed) {
            if aiLoadedFromCache, !isAnalyzing {
                startAnalyze()
            } else {
                scrollToShowAI()
            }
            return
        }
        // AI 区为空且未在分析：先查当天缓存（同股同模板同模型直接装载，省 token）
        if !bundles.isEmpty, let model = settings.defaultModel, let template = currentTemplate {
            let key = StockAICacheStore.makeKey(bundles: bundles, template: template, model: model)
            if let hit = StockAICacheStore.shared.entry(forKey: key), !hit.segments.isEmpty {
                loadCachedAnalysis(hit)
                return
            }
        }
        startAnalyze()
    }

    /// 发起网络分析（真实请求接口；缓存装载后的「重新生成」也走这里）
    private func startAnalyze() {
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
        let cacheKey = StockAICacheStore.makeKey(bundles: copies, template: template, model: model)

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
            let generation = self.aiGeneration
            await MainActor.run {
                self.isAnalyzing = false
                self.scheduleAIRender(flush: true)  // 流结束：立即渲染最终版（含漏网 chunk）
                self.setLoading(false)
                self.analyzeButton?.isEnabled = true
                self.agentEventLabel?.stringValue = ""
                // 写缓存再 hop 一跳：流式 chunk 经 DispatchQueue.main.async 落缓冲，
                // 此刻可能仍有挂起的 append（主队列 FIFO 保证它们先于本块执行完）。
                // 代际 + 失败标记双校验：被新查询/分析取代、或本次失败时不落盘
                DispatchQueue.main.async { [weak self] in
                    guard let self = self,
                        self.aiGeneration == generation,
                        !self.lastAnalysisFailed
                    else { return }
                    self.writeAnalysisToCache(
                        key: cacheKey, bundles: copies, template: template, model: model)
                }
            }
        }
    }

    // MARK: - 本地缓存

    /// 装载缓存命中：reasoning + 正文分段整段恢复，走 final 全量渲染对齐增量状态
    private func loadCachedAnalysis(_ hit: StockAICacheStore.Entry) {
        setAIPlaceholder("")  // 复用清空路径（重置渲染状态与装载位，随后置回）
        aiSegments = hit.segments.compactMap { seg in
            guard let style = AIOutputStyle(rawValue: seg.style) else { return nil }
            return (style, seg.text)
        }
        aiLoadedFromCache = true
        lastAnalysisFailed = false
        scrollToShowAI()
        renderAI(final: true)
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")
        df.dateFormat = "M月d日 HH:mm"
        agentEventLabel?.stringValue =
            "📥 已加载 \(df.string(from: hit.createdAt)) 的缓存分析 · 再次点击「AI 分析」重新生成"
    }

    /// 成功分析写入缓存。防线：无 error 段、正文 ≥ 50 字（拦「（模型未返回内容）」类空结果）
    private func writeAnalysisToCache(
        key: String, bundles: [StockDataBundle], template: StockPromptTemplate, model: AIModelConfig
    ) {
        guard !aiSegments.contains(where: { $0.style == .error }) else { return }
        let normalLength = aiSegments
            .filter { $0.style == .normal }
            .reduce(0) { $0 + $1.text.utf16.count }
        guard normalLength >= 50 else { return }
        StockAICacheStore.shared.store(.make(
            key: key,
            segments: aiSegments.map { .init(style: $0.style.rawValue, text: $0.text) },
            createdAt: Date(),
            stockName: bundles.map(\.name).joined(separator: "+"),
            templateName: template.name,
            modelName: "\(model.name) · \(model.model)"
        ))
    }

    // MARK: - 流式追加（主线程）

    /// 流式 chunk 先落分段缓冲（相邻同风格合并），节流后增量渲染：
    /// 正文段是 Markdown（半截标记会随后续 chunk 自愈），reasoning/错误段保持纯文本
    func appendAI(_ chunk: String, error: Bool = false, style: AIOutputStyle? = nil) {
        let resolved: AIOutputStyle = style ?? (error ? .error : .normal)
        // 归一换行：增量渲染的 utf16 偏移体系与 MiniMarkdown 归一后口径一致
        let normalized = chunk.replacingOccurrences(of: "\r\n", with: "\n")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.aiTextView != nil, !normalized.isEmpty else { return }
            if !self.aiSegments.isEmpty && self.aiSegments[self.aiSegments.count - 1].style == resolved {
                self.aiSegments[self.aiSegments.count - 1].text += normalized
            } else {
                self.aiSegments.append((resolved, normalized))
            }
            self.scheduleAIRender(flush: false)
        }
    }

    /// 节流渲染：每 120ms 必渲一次（trailing throttle）。
    /// 注意不能做成 debounce（每次 chunk 重置定时器）——SSE chunk 间隔小于周期时
    /// 渲染会被无限推迟，视觉上成块出现而非打字机式流出。
    /// flush 立即渲染并取消排队（流结束/清空时走 final 全量路径）。
    func scheduleAIRender(flush: Bool) {
        if flush {
            aiRenderTick?.cancel()
            aiRenderTick = nil
            renderAI(final: true)
            return
        }
        guard aiRenderTick == nil else { return }  // 已有排队 → 不重排
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.aiRenderTick = nil
            self.renderAI(final: false)
        }
        aiRenderTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// 渲染 AI 区：钉底跟随（用户上翻阅读时不打扰）。
    /// - final（流结束/缓存装载）：全量重渲一次，修正流中拼接的细微差异，
    ///   并对齐增量渲染器状态
    /// - 增量：稳定块 append（保留前缀布局缓存）+ 活跃尾部整体替换，O(新增)
    private func renderAI(final: Bool) {
        guard let tv = aiTextView else { return }
        let pinned = tv.visibleRect.maxY >= tv.bounds.height - 40

        if final {
            let out = NSMutableAttributedString()
            for seg in aiSegments {
                if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
                out.append(seg.style.attributed(seg.text, isContinuation: out.length > 0))
            }
            tv.textStorage?.replaceCharacters(
                in: NSRange(location: 0, length: tv.textStorage?.length ?? 0), with: out)
            var renderer = streamRenderer ?? AIStreamRenderer()
            renderer.align(to: aiSegments, totalLength: out.length)
            streamRenderer = renderer
            if pinned { tv.scrollToEndOfDocument(nil) }
            return
        }

        guard let ts = tv.textStorage else { return }
        var renderer = streamRenderer ?? AIStreamRenderer()
        let edits = renderer.computeEdits(for: aiSegments)
        streamRenderer = renderer  // 值语义：扫描状态变更必须写回
        guard !edits.isEmpty else { return }
        ts.beginEditing()
        for edit in edits {
            guard case .replaceTail(let from, let attr) = edit else { continue }
            let range = NSRange(location: from, length: max(0, ts.length - from))
            if range.length > 0 || attr.length > 0 {
                ts.replaceCharacters(in: range, with: attr)
            }
        }
        ts.endEditing()
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
