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
            labelWithString: "数据来源：东方财富 · 仅供学习参考，不构成投资建议")
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
            scroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),

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

    // MARK: - 内容区（K 线图铺满 ⇄ 收缩给 AI 让位）

    func setupContentArea() {
        guard let containerView = containerView, let inputScrollView = inputScrollView else { return }

        // —— 上：K 线图（WKWebView + KLineChart）——
        let chart = StockChartView(frame: .zero)
        chart.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(chart)
        self.chartView = chart
        // 双击日K蜡烛 → 弹独立分时窗口（支持多天多开比对）
        chart.onDayDoubleClick = { [weak self] ts in self?.handleDayDoubleClick(tsMillis: ts) }

        // —— 分隔线 ——
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(divider)
        self.contentDivider = divider

        // —— 下：AI 分析（事件提示 + 文本滚动）——
        let aiContainer = NSView()
        aiContainer.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(aiContainer)

        let eventLabel = NSTextField(labelWithString: "")
        eventLabel.font = .systemFont(ofSize: 11)
        eventLabel.textColor = .tertiaryLabelColor
        eventLabel.translatesAutoresizingMaskIntoConstraints = false
        aiContainer.addSubview(eventLabel)
        self.agentEventLabel = eventLabel

        let aiScroll = makeScrollView()
        aiContainer.addSubview(aiScroll)

        let aiTV = makeTextView()
        aiTV.isEditable = false
        aiTV.font = .systemFont(ofSize: 13)
        aiScroll.documentView = aiTV
        self.aiScrollView = aiScroll
        self.aiTextView = aiTV

        // 铺满态：图表一直伸到面板底部（divider / AI 区隐藏）
        let expanded = [
            chart.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10)
        ]
        self.chartExpandedConstraints = expanded

        // 收缩态：图表下方露出 divider + AI 分析区（AI 区底部顶到面板底）
        let compact = [
            divider.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 4),
            aiContainer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            aiContainer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10),
        ]
        self.aiAreaConstraints = compact

        NSLayoutConstraint.activate([
            // 图表区：顶部接输入框，底部在两套约束间切换
            chart.topAnchor.constraint(equalTo: inputScrollView.bottomAnchor, constant: 6),
            chart.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            chart.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            divider.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            divider.heightAnchor.constraint(equalToConstant: 1),

            aiContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            aiContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            eventLabel.topAnchor.constraint(equalTo: aiContainer.topAnchor, constant: 6),
            eventLabel.leadingAnchor.constraint(equalTo: aiContainer.leadingAnchor, constant: 12),
            eventLabel.trailingAnchor.constraint(equalTo: aiContainer.trailingAnchor, constant: -12),

            aiScroll.topAnchor.constraint(equalTo: eventLabel.bottomAnchor, constant: 4),
            aiScroll.leadingAnchor.constraint(equalTo: aiContainer.leadingAnchor),
            aiScroll.trailingAnchor.constraint(equalTo: aiContainer.trailingAnchor),
            aiScroll.bottomAnchor.constraint(equalTo: aiContainer.bottomAnchor),
        ])

        // 初始铺满
        NSLayoutConstraint.activate(chartExpandedConstraints)
        divider.isHidden = true
        aiContainer.isHidden = true
    }

    // MARK: - 图表铺满 ⇄ 收缩（AI 分析时下方让位）

    /// true：图表铺满面板；false：图表上移，下方展示 AI 分析文字
    func setChartExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != chartExpanded else { return }
        chartExpanded = expanded

        let apply = { [weak self] in
            guard let self = self else { return }
            if expanded {
                NSLayoutConstraint.deactivate(self.aiAreaConstraints)
                NSLayoutConstraint.activate(self.chartExpandedConstraints)
            } else {
                NSLayoutConstraint.deactivate(self.chartExpandedConstraints)
                NSLayoutConstraint.activate(self.aiAreaConstraints)
            }
            self.contentDivider?.isHidden = expanded
            self.aiScrollView?.isHidden = expanded
            self.agentEventLabel?.isHidden = expanded
            self.view.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                apply()
            })
        } else {
            apply()
        }
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
        popup.selectItem(at: 0)
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

    @objc func templateChanged() {}

    // MARK: - UI 工厂

    private func makeTextView() -> NSTextView {
        let tv = NSTextView()
        tv.minSize = NSSize(width: 0, height: 30)
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
