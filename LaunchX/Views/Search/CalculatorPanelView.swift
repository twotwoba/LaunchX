import AppKit

// MARK: - 计算器函数 token 按钮

/// 科学函数 token 按钮:无边框胶囊形态(仿 CurrencyTagButton),refusesFirstResponder
/// 保证点击后输入框焦点不丢失,可继续输入表达式
final class CalculatorTokenButton: NSButton {
    /// 点击时回调携带的插入文本(如 "sin(")
    var insertText: String = ""

    /// 是否为强调样式(Rad/Deg 切换等独立按钮)
    var isEmphasized: Bool = false {
        didSet { refreshVisualState() }
    }

    init(title: String, insertText: String) {
        self.insertText = insertText
        super.init(frame: .zero)
        self.title = title
        toolTip = insertText
        isBordered = false
        refusesFirstResponder = true
        font = .systemFont(ofSize: 12, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        refreshVisualState()
    }

    required init?(coder: NSCoder) {
        fatalError("CalculatorTokenButton 仅支持代码初始化")
    }

    /// 胶囊内边距(左右各 10pt)
    private static let horizontalPadding: CGFloat = 10
    /// 胶囊固定高度
    private static let capsuleHeight: CGFloat = 26

    override var intrinsicContentSize: NSSize {
        let textSize = attributedTitle.size()
        return NSSize(
            width: ceil(textSize.width) + Self.horizontalPadding * 2,
            height: Self.capsuleHeight)
    }

    /// 刷新按钮视觉(普通/强调态;颜色按指定外观解析,明暗切换后重算)
    func refreshVisualState() {
        let background =
            isEmphasized
            ? NSColor.controlAccentColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.15)
        let foreground = isEmphasized ? NSColor.white : NSColor.labelColor
        layer?.backgroundColor = Self.cgColor(background, appearance: effectiveAppearance)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font as Any,
                .foregroundColor: foreground,
            ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshVisualState()
    }

    /// 按指定外观解析颜色(cgColor 转换依赖当前绘制外观)
    private static func cgColor(_ color: NSColor, appearance: NSAppearance?) -> CGColor {
        var resolved = color.cgColor
        appearance?.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}

// MARK: - 计算器 token 流式容器

/// 科学函数 token 流式布局容器:按钮按可用宽度自动换行,高度随行数自适应(仿 CurrencyTagFlowView)
final class CalculatorTokenFlowView: NSView {
    /// 点击 token 回调(带回插入文本)
    var onTokenClicked: ((String) -> Void)?
    /// 点击 Rad/Deg 切换按钮回调
    var onAngleUnitClicked: (() -> Void)?

    private var tokenButtons: [CalculatorTokenButton] = []
    private var angleUnitButton: CalculatorTokenButton?

    /// token 水平/行间距
    private static let hSpacing: CGFloat = 8
    private static let vSpacing: CGFloat = 8

    /// 批量设置 token(标签 + 插入文本)
    func setTokens(_ tokens: [(label: String, insert: String)]) {
        tokenButtons.forEach { $0.removeFromSuperview() }
        tokenButtons = tokens.map { token in
            let button = CalculatorTokenButton(title: token.label, insertText: token.insert)
            button.target = self
            button.action = #selector(tokenClicked(_:))
            addSubview(button)
            return button
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    /// 行尾 Rad/Deg 切换按钮(独立于 token 流,强调样式)
    func setAngleUnitButton(title: String) {
        if let existing = angleUnitButton {
            existing.title = title
            existing.refreshVisualState()
            return
        }
        let button = CalculatorTokenButton(title: title, insertText: "")
        button.isEmphasized = true
        button.target = self
        button.action = #selector(angleUnitClicked(_:))
        addSubview(button)
        angleUnitButton = button
    }

    override var intrinsicContentSize: NSSize {
        // 宽度交由外部约束决定,高度按当前宽度换行后自适应
        NSSize(width: NSView.noIntrinsicMetric, height: wrappedHeight(forWidth: bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        let totalHeight = layoutButtons(width: bounds.width)
        if abs(bounds.height - totalHeight) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }

    /// 换行布局:返回总高度,并把每个按钮放到正确位置(y 翻转为 AppKit 左下原点)
    @discardableResult
    private func layoutButtons(width available: CGFloat) -> CGFloat {
        var buttons = tokenButtons
        if let angleUnitButton = angleUnitButton { buttons.append(angleUnitButton) }

        var xOffset: CGFloat = 0
        var rowTop: CGFloat = 0
        var rowHeight: CGFloat = 0
        var placements: [(x: CGFloat, rowOffset: CGFloat, size: NSSize)] = []

        for button in buttons {
            let size = button.intrinsicContentSize
            if xOffset > 0, xOffset + size.width > available + 0.5 {
                xOffset = 0
                rowTop += rowHeight + Self.vSpacing
                rowHeight = 0
            }
            placements.append((xOffset, rowTop, size))
            xOffset += size.width + Self.hSpacing
            rowHeight = max(rowHeight, size.height)
        }

        let totalHeight = rowTop + rowHeight
        for (button, placement) in zip(buttons, placements) {
            button.frame = NSRect(
                x: placement.x,
                y: totalHeight - placement.rowOffset - placement.size.height,
                width: placement.size.width,
                height: placement.size.height)
        }
        return totalHeight
    }

    /// 不落子视图帧的纯高度计算(intrinsicContentSize 用)
    private func wrappedHeight(forWidth available: CGFloat) -> CGFloat {
        var buttons = tokenButtons
        if let angleUnitButton = angleUnitButton { buttons.append(angleUnitButton) }

        var xOffset: CGFloat = 0
        var rowTop: CGFloat = 0
        var rowHeight: CGFloat = 0
        for button in buttons {
            let size = button.intrinsicContentSize
            if xOffset > 0, xOffset + size.width > available + 0.5 {
                xOffset = 0
                rowTop += rowHeight + Self.vSpacing
                rowHeight = 0
            }
            xOffset += size.width + Self.hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return rowTop + rowHeight
    }

    @objc private func tokenClicked(_ sender: CalculatorTokenButton) {
        onTokenClicked?(sender.insertText)
    }

    @objc private func angleUnitClicked(_ sender: CalculatorTokenButton) {
        onAngleUnitClicked?()
    }
}

// MARK: - 计算历史行

/// 历史条目行:左侧表达式(点击回填)、右侧结果(点击复制);hover 高亮由 TrackingArea 驱动
final class CalculatorHistoryRowView: NSView {
    /// 点击表达式回调(回填输入框)
    var onExpressionClicked: ((String) -> Void)?
    /// 点击结果回调(复制)
    var onResultClicked: ((String) -> Void)?

    private let expressionLabel = NSTextField(labelWithString: "")
    private let equalsLabel = NSTextField(labelWithString: "=")
    private let resultLabel = NSTextField(labelWithString: "")

    /// 条目表达式(回填用)
    private(set) var expression: String = ""
    /// 结果文本(复制用)
    private(set) var result: String = ""

    private static let rowHeight: CGFloat = 28

    init(entry: CalculatorHistoryEntry) {
        super.init(frame: .zero)
        self.expression = entry.expression
        self.result = entry.result

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        expressionLabel.stringValue = entry.expression
        expressionLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        expressionLabel.textColor = .labelColor
        expressionLabel.lineBreakMode = .byTruncatingTail
        expressionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        expressionLabel.refusesFirstResponder = true

        equalsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        equalsLabel.textColor = .tertiaryLabelColor
        equalsLabel.refusesFirstResponder = true

        resultLabel.stringValue = entry.result
        resultLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.lineBreakMode = .byTruncatingHead
        resultLabel.setContentHuggingPriority(.required, for: .horizontal)
        resultLabel.refusesFirstResponder = true

        addSubview(expressionLabel)
        addSubview(equalsLabel)
        addSubview(resultLabel)

        // 分区点击(命中分区见 mouseDown):表达式回填,结果复制
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("CalculatorHistoryRowView 仅支持代码初始化")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        let equalsSize = equalsLabel.intrinsicContentSize
        let resultSize = resultLabel.intrinsicContentSize
        let spacing: CGFloat = 8

        // 右侧:结果
        let resultX = bounds.maxX - resultSize.width
        resultLabel.frame = NSRect(
            x: resultX, y: (bounds.height - resultSize.height) / 2,
            width: resultSize.width, height: resultSize.height)
        // 中间:=
        let equalsX = resultX - spacing - equalsSize.width
        equalsLabel.frame = NSRect(
            x: equalsX, y: (bounds.height - equalsSize.height) / 2,
            width: equalsSize.width, height: equalsSize.height)
        // 左侧:表达式(占满剩余空间)
        let expressionX = bounds.minX + 8
        let expressionWidth = max(0, equalsX - spacing - expressionX)
        expressionLabel.frame = NSRect(
            x: expressionX, y: (bounds.height - expressionLabel.intrinsicContentSize.height) / 2,
            width: expressionWidth, height: expressionLabel.intrinsicContentSize.height)
    }

    /// 点击命中分区:结果/等号区域 → 复制,其余 → 回填表达式
    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        let location = sender.location(in: self)
        if resultLabel.frame.contains(location) || equalsLabel.frame.contains(location) {
            onResultClicked?(result)
        } else {
            onExpressionClicked?(expression)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}

// MARK: - 计算器面板

/// 计算器面板:输入表达式时替换结果列表展示——结果大字行 + 科学函数 token 流 + 持久化历史列表。
/// 所有子控件 refusesFirstResponder,点击不夺走输入框焦点。
final class CalculatorPanelView: NSView {
    // MARK: 回调
    var onInsertToken: ((String) -> Void)?
    var onToggleAngleUnit: (() -> Void)?
    var onResultClick: (() -> Void)?
    var onHistoryExpressionClick: ((String) -> Void)?
    var onHistoryResultClick: ((String) -> Void)?
    var onClearHistory: (() -> Void)?

    // MARK: 子视图
    private let resultLabel = NSTextField(labelWithString: "")
    private let tokenFlowView = CalculatorTokenFlowView()
    private let historyHeaderLabel = NSTextField(labelWithString: "History")
    private let clearHistoryButton = NSButton(title: "Clear", target: nil, action: nil)
    private let historyEmptyLabel = NSTextField(labelWithString: "No calculations yet")
    private let historyScrollView = NSScrollView()
    private let historyStackView = NSStackView()

    /// 全部科学函数 token(标签 + 点击插入文本)
    private static let tokens: [(label: String, insert: String)] = [
        ("sin(", "sin("), ("cos(", "cos("), ("tan(", "tan("),
        ("asin(", "asin("), ("acos(", "acos("), ("atan(", "atan("),
        ("ln(", "ln("), ("log(", "log("), ("log₂(", "log2("),
        ("√(", "√("), ("^", "^"), ("π", "π"), ("e", "e"),
        ("!", "!"), ("%", "%"), ("ans", "ans"), ("(", "("), (")", ")"),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("CalculatorPanelView 仅支持代码初始化")
    }

    // MARK: 公开更新

    /// 更新结果行:nil 显示占位符(未完成/非法表达式)
    func setResult(displayText: String?) {
        if let text = displayText {
            resultLabel.attributedStringValue = NSAttributedString(
                string: "= \(text)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ])
        } else {
            resultLabel.attributedStringValue = NSAttributedString(
                string: "= …",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
        }
    }

    /// 更新 Rad/Deg 切换按钮文案
    func setAngleUnit(_ mode: CalculatorAngleMode) {
        tokenFlowView.setAngleUnitButton(title: mode == .radians ? "Rad" : "Deg")
    }

    /// 重建历史列表(仅消费时更新,低频重建可接受)
    func setHistory(_ entries: [CalculatorHistoryEntry]) {
        historyStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        historyEmptyLabel.isHidden = !entries.isEmpty
        for entry in entries {
            let row = CalculatorHistoryRowView(entry: entry)
            row.onExpressionClicked = { [weak self] expression in
                self?.onHistoryExpressionClick?(expression)
            }
            row.onResultClicked = { [weak self] result in
                self?.onHistoryResultClick?(result)
            }
            historyStackView.addArrangedSubview(row)
            // 行宽填满栈(行 intrinsic 宽度为 noIntrinsicMetric,不约束会被压成零宽)
            row.widthAnchor.constraint(equalTo: historyStackView.widthAnchor).isActive = true
        }
    }

    // MARK: 布局搭建

    private func setupSubviews() {
        wantsLayer = true

        // 结果大字行(点击复制)
        setResult(displayText: nil)
        resultLabel.refusesFirstResponder = true
        resultLabel.lineBreakMode = .byTruncatingTail
        addSubview(resultLabel)
        let resultClick = NSClickGestureRecognizer(
            target: self, action: #selector(resultClicked))
        resultLabel.addGestureRecognizer(resultClick)

        // 科学函数 token 流
        tokenFlowView.setTokens(Self.tokens)
        tokenFlowView.onTokenClicked = { [weak self] text in
            self?.onInsertToken?(text)
        }
        tokenFlowView.onAngleUnitClicked = { [weak self] in
            self?.onToggleAngleUnit?()
        }
        addSubview(tokenFlowView)

        // 历史区头部
        historyHeaderLabel.stringValue = "History"
        historyHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        historyHeaderLabel.textColor = .secondaryLabelColor
        historyHeaderLabel.refusesFirstResponder = true
        addSubview(historyHeaderLabel)

        clearHistoryButton.title = "Clear"
        clearHistoryButton.bezelStyle = .rounded
        clearHistoryButton.controlSize = .small
        clearHistoryButton.font = .systemFont(ofSize: 11, weight: .medium)
        clearHistoryButton.refusesFirstResponder = true
        clearHistoryButton.target = self
        clearHistoryButton.action = #selector(clearHistoryClicked)
        addSubview(clearHistoryButton)

        // 历史滚动区 + 竖向栈
        historyScrollView.hasVerticalScroller = false
        historyScrollView.drawsBackground = false
        historyScrollView.autohidesScrollers = true
        installHistoryStack()
        addSubview(historyScrollView)

        // 空历史占位
        historyEmptyLabel.stringValue = "No calculations yet"
        historyEmptyLabel.font = .systemFont(ofSize: 12, weight: .regular)
        historyEmptyLabel.textColor = .tertiaryLabelColor
        historyEmptyLabel.refusesFirstResponder = true
        addSubview(historyEmptyLabel)

        // 约束
        translatesAutoresizingMaskIntoConstraints = false
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        tokenFlowView.translatesAutoresizingMaskIntoConstraints = false
        historyHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        clearHistoryButton.translatesAutoresizingMaskIntoConstraints = false
        historyScrollView.translatesAutoresizingMaskIntoConstraints = false
        historyEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            resultLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            resultLabel.topAnchor.constraint(equalTo: topAnchor),
            resultLabel.heightAnchor.constraint(equalToConstant: 36),

            tokenFlowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tokenFlowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tokenFlowView.topAnchor.constraint(equalTo: resultLabel.bottomAnchor, constant: 6),
            // token 流高度由 intrinsicContentSize 自适应(1~2 行)

            historyHeaderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            historyHeaderLabel.topAnchor.constraint(
                equalTo: tokenFlowView.bottomAnchor, constant: 10),

            clearHistoryButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clearHistoryButton.centerYAnchor.constraint(equalTo: historyHeaderLabel.centerYAnchor),

            historyScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            historyScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            historyScrollView.topAnchor.constraint(
                equalTo: historyHeaderLabel.bottomAnchor, constant: 6),
            historyScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            historyEmptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            historyEmptyLabel.topAnchor.constraint(
                equalTo: historyHeaderLabel.bottomAnchor, constant: 20),
        ])
    }

    /// 安装历史栈为滚动区文档视图:宽度跟随滚动区,高度随内容自适应(不足时留白,超出时滚动)
    private func installHistoryStack() {
        historyStackView.orientation = .vertical
        historyStackView.spacing = 2
        historyStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        historyScrollView.documentView = historyStackView
        historyStackView.translatesAutoresizingMaskIntoConstraints = false

        let bottom = historyStackView.bottomAnchor.constraint(
            greaterThanOrEqualTo: historyScrollView.contentView.bottomAnchor)
        bottom.priority = .defaultLow  // 内容不足时允许留白,超出时产生滚动
        NSLayoutConstraint.activate([
            historyStackView.leadingAnchor.constraint(
                equalTo: historyScrollView.contentView.leadingAnchor),
            historyStackView.trailingAnchor.constraint(
                equalTo: historyScrollView.contentView.trailingAnchor),
            historyStackView.topAnchor.constraint(
                equalTo: historyScrollView.contentView.topAnchor),
            bottom,
        ])
    }

    // MARK: 动作

    @objc private func resultClicked() {
        onResultClick?()
    }

    @objc private func clearHistoryClicked() {
        onClearHistory?()
    }
}
