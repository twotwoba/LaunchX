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
        setupControlBar()
        setupContentArea()
        setupDisclaimer()
        setupLoadingIndicator()

        handleLiquidGlassSettingDidChange()
    }

    // MARK: - 标题栏

    func setupTitleBar() {
        guard let containerView = containerView else { return }

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(bar)
        self.titleBar = bar

        let label = NSTextField(labelWithString: "📊 股票查询 · AI 分析")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(label)
        self.titleLabel = label

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
            bar.heightAnchor.constraint(equalToConstant: 44),

            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),

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
            labelWithString: "输入股票代码/名称 + 日期，回车查询；支持批量（逗号或换行分隔），如：600519、贵州茅台-20240115")
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .placeholderTextColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(placeholder)
        self.inputPlaceholder = placeholder

        let heightC = scroll.heightAnchor.constraint(equalToConstant: inputMinHeight)
        self.inputHeightConstraint = heightC

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            heightC,

            placeholder.topAnchor.constraint(equalTo: scroll.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 5),
        ])
    }

    // MARK: - 操作条

    func setupControlBar() {
        guard let containerView = containerView, let inputScrollView = inputScrollView else { return }

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(bar)

        // 模式切换
        let seg = NSSegmentedControl(
            labels: ["快速分析", "深度分析"], trackingMode: .selectOne, target: self,
            action: #selector(modeChanged))
        seg.selectedSegment = 0
        seg.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(seg)
        self.modeSegmented = seg

        // 模板下拉
        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self
        popup.action = #selector(templateChanged)
        bar.addSubview(popup)
        self.templatePopup = popup

        // 查询按钮
        let query = makeButton(title: "查询", symbol: "magnifyingglass", action: #selector(performQuery))
        bar.addSubview(query)
        self.queryButton = query

        // 分析按钮
        let analyze = makeButton(title: "AI 分析", symbol: "sparkles", action: #selector(performAnalyze))
        bar.addSubview(analyze)
        self.analyzeButton = analyze

        // 复制 JSON
        let copyJSON = makeButton(title: "复制 JSON", symbol: "doc.on.doc", action: #selector(copyJSON))
        bar.addSubview(copyJSON)
        self.copyJSONButton = copyJSON

        // 复制 CSV
        let copyCSV = makeButton(title: "复制 CSV", symbol: "tablecells", action: #selector(copyCSV))
        bar.addSubview(copyCSV)
        self.copyCSVButton = copyCSV

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: inputScrollView.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            bar.heightAnchor.constraint(equalToConstant: 30),

            seg.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            seg.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            seg.widthAnchor.constraint(equalToConstant: 150),

            popup.leadingAnchor.constraint(equalTo: seg.trailingAnchor, constant: 8),
            popup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 150),

            copyCSV.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            copyCSV.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            copyJSON.trailingAnchor.constraint(equalTo: copyCSV.leadingAnchor, constant: -8),
            copyJSON.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            analyze.trailingAnchor.constraint(equalTo: copyJSON.leadingAnchor, constant: -8),
            analyze.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            query.trailingAnchor.constraint(equalTo: analyze.leadingAnchor, constant: -8),
            query.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    // MARK: - 内容区（上：数据卡滚动，下：AI 分析）

    func setupContentArea() {
        guard let containerView = containerView, let controlBar = queryButton?.superview,
            let disclaimer = makeDisclaimerLabel()
        else { return }

        // —— 上：数据卡滚动区 ——
        let dataScroll = makeScrollView()
        containerView.addSubview(dataScroll)
        self.dataScrollView = dataScroll

        let dataFlipped = FlippedView()
        dataFlipped.translatesAutoresizingMaskIntoConstraints = false

        let dataStack = NSStackView()
        dataStack.orientation = .vertical
        dataStack.alignment = .leading
        dataStack.spacing = 0
        dataStack.setHuggingPriority(.required, for: .vertical)
        dataStack.translatesAutoresizingMaskIntoConstraints = false
        dataFlipped.addSubview(dataStack)
        dataScroll.documentView = dataFlipped
        self.dataStackView = dataStack

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

        // 免责声明（guard 中已解包为 disclaimer）
        disclaimer.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(disclaimer)
        self.disclaimerLabel = disclaimer

        NSLayoutConstraint.activate([
            // 数据区占上半（比例固定，避免 NSSplitView 无内在尺寸时塌缩）
            dataScroll.topAnchor.constraint(equalTo: controlBar.bottomAnchor, constant: 8),
            dataScroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            dataScroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            dataScroll.heightAnchor.constraint(
                equalTo: containerView.heightAnchor, multiplier: 0.5),

            divider.topAnchor.constraint(equalTo: dataScroll.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            divider.heightAnchor.constraint(equalToConstant: 1),

            aiContainer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            aiContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            aiContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            aiContainer.bottomAnchor.constraint(equalTo: disclaimer.topAnchor, constant: -4),

            eventLabel.topAnchor.constraint(equalTo: aiContainer.topAnchor, constant: 6),
            eventLabel.leadingAnchor.constraint(equalTo: aiContainer.leadingAnchor, constant: 12),
            eventLabel.trailingAnchor.constraint(equalTo: aiContainer.trailingAnchor, constant: -12),

            aiScroll.topAnchor.constraint(equalTo: eventLabel.bottomAnchor, constant: 4),
            aiScroll.leadingAnchor.constraint(equalTo: aiContainer.leadingAnchor),
            aiScroll.trailingAnchor.constraint(equalTo: aiContainer.trailingAnchor),
            aiScroll.bottomAnchor.constraint(equalTo: aiContainer.bottomAnchor),

            disclaimer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            disclaimer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            disclaimer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -6),

            // 数据卡文档视图：宽度跟随滚动区、高度由内容决定（照搬翻译面板已验证配方）
            dataStack.topAnchor.constraint(equalTo: dataFlipped.topAnchor),
            dataStack.leadingAnchor.constraint(equalTo: dataFlipped.leadingAnchor),
            dataStack.trailingAnchor.constraint(equalTo: dataFlipped.trailingAnchor),
            dataStack.bottomAnchor.constraint(equalTo: dataFlipped.bottomAnchor),
            dataStack.widthAnchor.constraint(equalTo: dataFlipped.widthAnchor),
            dataFlipped.widthAnchor.constraint(equalTo: dataScroll.widthAnchor),
        ])
    }

    func setupDisclaimer() {
        // disclaimer 已在 setupContentArea 内创建
    }

    func setupLoadingIndicator() {
        guard let containerView = containerView, let titleBar = titleBar, let pinButton = pinButton
        else { return }

        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isHidden = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(indicator)
        self.loadingIndicator = indicator

        NSLayoutConstraint.activate([
            indicator.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            indicator.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -8),
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

    /// 当前选择的模式
    var currentMode: StockAnalysisMode {
        (modeSegmented?.selectedSegment ?? 0) == 1 ? .agent : .quick
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

    @objc func modeChanged() {
        // 切换模式时无额外动作；模板的 defaultMode 仅作建议
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

    private func makeDisclaimerLabel() -> NSTextField? {
        let label = NSTextField(
            labelWithString: "数据来源：东方财富 · 仅供学习参考，不构成投资建议")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        return label
    }
}
