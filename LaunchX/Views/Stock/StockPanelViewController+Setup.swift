import AppKit

extension StockPanelViewController {

    // MARK: - 主入口

    func setupUI() {
        let container = NSView(frame: view.bounds)
        container.wantsLayer = true
        container.layer?.cornerRadius = 28
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        view.addSubview(container)
        self.containerView = container

        // 1. 传统毛玻璃层
        let vev = NSVisualEffectView(frame: container.bounds)
        vev.material = .hudWindow
        vev.autoresizingMask = [.width, .height]
        vev.blendingMode = .behindWindow
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = 28
        vev.layer?.cornerCurve = .continuous
        vev.layer?.masksToBounds = true
        container.addSubview(vev)
        self.visualEffectView = vev

        // 2. macOS 26+ 液态玻璃层
        if #available(macOS 26.0, *) {
            let gev = NSGlassEffectView(frame: container.bounds)
            gev.autoresizingMask = [.width, .height]
            gev.style = .clear
            gev.tintColor = NSColor(named: "PanelBackgroundColor")
            gev.wantsLayer = true
            gev.layer?.cornerRadius = 28
            gev.layer?.cornerCurve = .continuous
            gev.layer?.masksToBounds = true
            container.addSubview(gev)
            self.glassEffectView = gev
        }

        setupTitleBar()
        setupInputArea()
        setupContentArea()
        setupBackToChartButton()
        setupLoadingIndicator()

        handleLiquidGlassSettingDidChange()
    }

    // MARK: - 标题栏（居中：数据来源声明；右：固定）

    func setupTitleBar() {
        guard let containerView = containerView else { return }

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(bar)
        self.titleBar = bar

        // 头部居中：数据来源声明
        let disclaimer = NSTextField(
            labelWithString: "数据来源：腾讯 · 新浪 · zzshare · 仅供学习参考，不构成投资建议")
        disclaimer.font = .systemFont(ofSize: 10)
        disclaimer.textColor = .tertiaryLabelColor
        disclaimer.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(disclaimer)
        self.disclaimerLabel = disclaimer

        let btn = NSButton()
        btn.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "固定")
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.target = self
        btn.action = #selector(togglePin)
        btn.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(btn)
        self.pinButton = btn

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: containerView.topAnchor),
            bar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),

            disclaimer.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            disclaimer.centerXAnchor.constraint(equalTo: bar.centerXAnchor),

            btn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            btn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            btn.widthAnchor.constraint(equalToConstant: 24),
            btn.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - 输入区

    func setupInputArea() {
        guard let containerView = containerView, let titleBar = titleBar else { return }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .clear
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(scroll)
        self.inputScrollView = scroll

        let tv = makeTextView()
        tv.delegate = self
        scroll.documentView = tv
        self.inputTextView = tv

        let placeholder = NSTextField(
            labelWithString: "输入股票代码/名称，回车查询，如：600519、贵州茅台")
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .placeholderTextColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(placeholder)
        self.inputPlaceholder = placeholder

        let heightC = scroll.heightAnchor.constraint(equalToConstant: inputMinHeight)
        self.inputHeightConstraint = heightC

        // 输入框左侧：历史查询下拉（点击弹出最近查过的股票，点击条目直接切换查询）
        let history = makeButton(title: "", symbol: "clock.arrow.circlepath", action: #selector(showHistoryMenu))
        history.toolTip = "查询历史"
        containerView.addSubview(history)
        self.historyButton = history

        // 输入框右侧：AI 上下文模板 + AI 分析（与输入框垂直居中）
        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self
        popup.action = #selector(templateChanged)
        containerView.addSubview(popup)
        self.templatePopup = popup

        let analyze = makeButton(title: "AI 分析", symbol: "sparkles", action: #selector(performAnalyze))
        containerView.addSubview(analyze)
        self.analyzeButton = analyze

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 4),

            history.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            history.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            history.widthAnchor.constraint(equalToConstant: 36),
            history.heightAnchor.constraint(equalToConstant: 26),

            scroll.leadingAnchor.constraint(equalTo: history.trailingAnchor, constant: 8),

            analyze.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            analyze.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            analyze.widthAnchor.constraint(equalToConstant: 96),

            popup.trailingAnchor.constraint(equalTo: analyze.leadingAnchor, constant: -8),
            popup.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 130),

            scroll.trailingAnchor.constraint(equalTo: popup.leadingAnchor, constant: -8),
            heightC,

            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 5),
        ])
    }

    // MARK: - 内容区（图表 + AI 分析同处一个纵向滚动视图）

    /// 结构：外层 NSScrollView 的 documentView 里依次放 K线图（高度=可视高度，永不压缩）
    /// → 分隔线 → AI 分析区（高度=可视高度）。初始停在顶部只见图表；
    /// 点「AI 分析」整体滚下去，用户可随时手动滚回看图表。
    func setupContentArea() {
        guard let containerView = containerView, let inputScrollView = inputScrollView else { return }

        // —— 外层滚动容器（图表与 AI 区共用）——
        let outerScroll = makeScrollView()
        outerScroll.hasVerticalScroller = true
        outerScroll.hasHorizontalScroller = false
        outerScroll.horizontalScrollElasticity = .none
        containerView.addSubview(outerScroll)
        self.contentScrollView = outerScroll

        let doc = StockFlippedContentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        outerScroll.documentView = doc
        self.contentDocView = doc

        // —— 上：K 线图（WKWebView + KLineChart）——
        let chart = StockChartView(frame: .zero)
        chart.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(chart)
        self.chartView = chart
        // 双击日K蜡烛 → 弹独立分时窗口（支持多天多开比对）
        chart.onDayDoubleClick = { [weak self] ts in self?.handleDayDoubleClick(tsMillis: ts) }

        // —— 分隔线 ——
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(divider)
        self.contentDivider = divider

        // —— 下：AI 分析（事件提示 + 文本滚动）——
        let aiContainer = NSView()
        aiContainer.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(aiContainer)
        self.aiContainerView = aiContainer

        let eventLabel = NSTextField(labelWithString: "")
        eventLabel.font = .systemFont(ofSize: 11)
        eventLabel.textColor = .tertiaryLabelColor
        eventLabel.translatesAutoresizingMaskIntoConstraints = false
        aiContainer.addSubview(eventLabel)
        self.agentEventLabel = eventLabel

        let aiScroll = makeScrollView()
        aiContainer.addSubview(aiScroll)
        self.aiScrollView = aiScroll

        let aiTV = makeTextView()
        aiTV.isEditable = false
        aiTV.font = .systemFont(ofSize: 13)
        aiScroll.documentView = aiTV
        self.aiTextView = aiTV

        let clip = outerScroll.contentView
        // 悬浮回图按钮的显隐由滚动位置驱动（手动滚动与程序化动画都会逐帧发此通知）
        clip.postsBoundsChangedNotifications = true
        NSLayoutConstraint.activate([
            // 外层滚动视图占据输入框以下整个内容区
            outerScroll.topAnchor.constraint(equalTo: inputScrollView.bottomAnchor, constant: 6),
            outerScroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            outerScroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            outerScroll.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10),

            // documentView 与滚动区等宽（无边框时 scrollView 边即可视区边）、高度由内容撑开
            doc.leadingAnchor.constraint(equalTo: outerScroll.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: outerScroll.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.bottomAnchor.constraint(greaterThanOrEqualTo: clip.bottomAnchor),

            // 图表：占满首屏可视高度（宽高不随 AI 区出现而变化）
            chart.topAnchor.constraint(equalTo: doc.topAnchor),
            chart.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            chart.heightAnchor.constraint(equalTo: outerScroll.heightAnchor, constant: -10),

            divider.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            // AI 区：同样占一屏高度，文本在其内部滚动
            aiContainer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            aiContainer.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            aiContainer.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            aiContainer.heightAnchor.constraint(equalTo: outerScroll.heightAnchor, constant: -10),
            aiContainer.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            eventLabel.topAnchor.constraint(equalTo: aiContainer.topAnchor, constant: 6),
            eventLabel.leadingAnchor.constraint(equalTo: aiContainer.leadingAnchor, constant: 12),
            eventLabel.trailingAnchor.constraint(equalTo: aiContainer.trailingAnchor, constant: -12),

            aiScroll.topAnchor.constraint(equalTo: eventLabel.bottomAnchor, constant: 4),
            aiScroll.leadingAnchor.constraint(equalTo: aiContainer.leadingAnchor),
            aiScroll.trailingAnchor.constraint(equalTo: aiContainer.trailingAnchor),
            aiScroll.bottomAnchor.constraint(equalTo: aiContainer.bottomAnchor),
        ])
    }

    // MARK: - 图表 ⇄ AI 区滚动切换（图表宽高不变，整体上下滚动）

    /// 滚到顶部：图表占满可视区
    func scrollToShowChart(animated: Bool = true) {
        scrollContentView(to: 0, animated: animated)
    }

    /// 滚到底部：露出图表下方的 AI 分析区
    func scrollToShowAI(animated: Bool = true) {
        guard let outer = contentScrollView, let doc = contentDocView else { return }
        view.layoutSubtreeIfNeeded()
        let y = max(0, doc.frame.height - outer.contentView.bounds.height)
        scrollContentView(to: y, animated: animated)
    }

    private func scrollContentView(to y: CGFloat, animated: Bool) {
        guard let outer = contentScrollView else { return }
        let clip = outer.contentView
        let target = NSPoint(x: 0, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: {
                outer.reflectScrolledClipView(clip)
                self.updateBackChartButton()
            })
        } else {
            clip.scroll(to: target)
            outer.reflectScrolledClipView(clip)
            updateBackChartButton()
        }
    }

    // MARK: - 悬浮回图按钮（滚到下方 AI 区时浮现在右下角）

    /// 在 setupContentArea 之后调用：add 顺序即 z-order，天然浮在内容滚动区之上
    func setupBackToChartButton() {
        guard let containerView = containerView,
            let clip = contentScrollView?.contentView
        else { return }

        let btn = NSButton()
        btn.bezelStyle = .inline
        btn.isBordered = false
        if let img = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "回到图表") {
            btn.image = img
            btn.imageScaling = .scaleProportionallyDown
        }
        btn.toolTip = "回到图表"
        btn.target = self
        btn.action = #selector(scrollBackToChart)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 18
        btn.layer?.cornerCurve = .continuous
        btn.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        btn.alphaValue = 0
        btn.isHidden = true
        containerView.addSubview(btn)
        self.backToChartButton = btn

        NSLayoutConstraint.activate([
            btn.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            btn.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),
            btn.widthAnchor.constraint(equalToConstant: 36),
            btn.heightAnchor.constraint(equalToConstant: 36),
        ])

        // object 显式传外层 clip：避免收到 AI 区内层 aiScrollView 的同名通知
        scrollObserverToken = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            self?.updateBackChartButton()
        }
    }

    /// 幂等切换按钮显隐（每帧回调只做一次比较）；
    /// completion 以状态收口，防快速来回滚动时 hide/isHidden 竞态
    func updateBackChartButton() {
        guard let btn = backToChartButton else { return }
        let y = contentScrollView?.contentView.bounds.origin.y ?? 0
        let show = y > 60
        guard show != backButtonShown else { return }
        backButtonShown = show
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            if show { btn.isHidden = false }
            btn.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.backButtonShown else { return }
            btn.isHidden = true
        })
    }

    @objc func scrollBackToChart() {
        scrollToShowChart()
    }

    func setupLoadingIndicator() {
        guard let titleBar = titleBar else { return }

        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isHidden = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(indicator)
        self.loadingIndicator = indicator

        // 左上角：标题栏左侧空位（来源声明居中、固定按钮在右，互不遮挡）
        NSLayoutConstraint.activate([
            indicator.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            indicator.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 12),
            indicator.widthAnchor.constraint(equalToConstant: 16),
            indicator.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    // MARK: - 模板下拉重建

    func rebuildTemplatePopup() {
        guard let popup = templatePopup else { return }
        popup.removeAllItems()
        let enabled = settings.promptTemplates.filter { $0.isEnabled }
        if enabled.isEmpty {
            popup.addItem(withTitle: "（未配置模板）")
            popup.isEnabled = false
            return
        }
        popup.isEnabled = true
        for t in enabled {
            let item = NSMenuItem(title: t.name, action: nil, keyEquivalent: "")
            item.representedObject = t.id
            popup.menu?.addItem(item)
        }
        // 恢复上次选中的模板；已删除/禁用的回落到第一个
        if let id = settings.selectedTemplateID,
            let item = popup.itemArray.first(where: { ($0.representedObject as? UUID) == id })
        {
            popup.select(item)
        } else {
            popup.selectItem(at: 0)
        }
    }

    // MARK: - 当前选择

    /// 分析模式：模板勾了「需要 Function Calling」→ 深度分析，否则快速分析
    var currentMode: StockAnalysisMode {
        (currentTemplate?.needsTools ?? false) ? .agent : .quick
    }

    /// 当前选择的提示词模板
    var currentTemplate: StockPromptTemplate? {
        guard let popup = templatePopup,
            let item = popup.selectedItem,
            let id = item.representedObject as? UUID
        else { return settings.promptTemplates.first }
        return settings.promptTemplates.first { $0.id == id }
    }

    // MARK: - 操作（@objc，实现在 +Data / +AI）

    @objc func togglePin() {
        StockPanelManager.shared.togglePinned()
    }

    @objc func templateChanged() {
        // 记住选择，重开面板时恢复
        if let id = templatePopup?.selectedItem?.representedObject as? UUID {
            settings.selectedTemplateID = id
            settings.save()
        }
    }

    // MARK: - UI 工厂

    private func makeTextView() -> NSTextView {
        let tv = NSTextView()
        // minSize 高度必须为 0：非 0 时首响应若 clip 高度小于该值，NSTextView 会自滚动
        // 保证插入点可见，把光标顶出输入框（首次打开光标偏高一截的根因）
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 4
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = .labelColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        return tv
    }

    private func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .clear
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func makeButton(title: String, symbol: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.title = title
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            btn.image = img
            btn.imagePosition = .imageLeading
        }
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 12)
        btn.target = self
        btn.action = action
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

}

// MARK: - 滚动内容容器

/// 外层滚动视图的 documentView：flipped（y=0 为顶部），
/// 使 scroll(to:) 的坐标方向与直觉一致（正 y 向下滚向 AI 区）。
/// 普通 NSView 非 flipped（y=0 为底部），滚动目标会上下颠倒。
final class StockFlippedContentView: NSView {
    override var isFlipped: Bool { true }
}
