import AppKit

// MARK: - 币种胶囊按钮

/// 币种胶囊按钮:无边框圆角胶囊形态,选中态以控制色高亮;
/// refusesFirstResponder 保证点击后输入框焦点不丢失,可继续输入金额
final class CurrencyTagButton: NSButton {
    let currencyCode: String

    init(currency: CurrencyDefinition) {
        self.currencyCode = currency.code
        super.init(frame: .zero)
        title = currency.code
        // 悬停提示:中文名 + 符号(无符号时仅中文名)
        toolTip = currency.symbol.map { "\(currency.chineseName) \($0)" } ?? currency.chineseName
        isBordered = false
        refusesFirstResponder = true
        font = .systemFont(ofSize: 12, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        setSelected(false)
    }

    required init?(coder: NSCoder) {
        fatalError("CurrencyTagButton 仅支持代码初始化")
    }

    /// 胶囊内边距(左右各 12pt)
    private static let horizontalPadding: CGFloat = 12
    /// 胶囊固定高度
    private static let capsuleHeight: CGFloat = 26

    override var intrinsicContentSize: NSSize {
        let textSize = attributedTitle.size()
        return NSSize(
            width: ceil(textSize.width) + Self.horizontalPadding * 2,
            height: Self.capsuleHeight)
    }

    /// 切换选中态视觉
    func setSelected(_ selected: Bool) {
        let background =
            selected
            ? NSColor.controlAccentColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.15)
        let foreground = selected ? NSColor.white : NSColor.labelColor
        layer?.backgroundColor = Self.cgColor(background, appearance: effectiveAppearance)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font as Any,
                .foregroundColor: foreground,
            ])
    }

    /// 按指定外观解析颜色(cgColor 转换依赖当前绘制外观,明暗切换后需显式指定)
    private static func cgColor(_ color: NSColor, appearance: NSAppearance?) -> CGColor {
        var resolved = color.cgColor
        appearance?.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}

// MARK: - 币种胶囊流式容器

/// 币种胶囊流式布局容器:按钮按可用宽度自动换行,高度随行数自适应
/// (intrinsicContentSize 驱动,宽度由外部约束固定)
final class CurrencyTagFlowView: NSView {
    /// 点击胶囊回调(带回币种 ISO 代码)
    var onTagClicked: ((String) -> Void)?

    /// 当前选中(高亮)的目标币种代码
    var selectedCode: String? {
        didSet { refreshSelectionStates() }
    }

    private var tagButtons: [CurrencyTagButton] = []

    /// 胶囊水平/行间距
    private static let hSpacing: CGFloat = 8
    private static let vSpacing: CGFloat = 8

    /// 批量设置胶囊;与当前列表一致时跳过重建,避免逐键重排
    func setTags(_ currencies: [CurrencyDefinition]) {
        let newCodes = currencies.map(\.code)
        if newCodes == tagButtons.map(\.currencyCode) { return }

        tagButtons.forEach { $0.removeFromSuperview() }
        tagButtons = currencies.map { currency in
            let button = CurrencyTagButton(currency: currency)
            button.target = self
            button.action = #selector(tagClicked(_:))
            addSubview(button)
            return button
        }
        refreshSelectionStates()
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        // 宽度交由外部约束决定,高度按当前宽度换行后自适应
        NSSize(width: NSView.noIntrinsicMetric, height: wrappedHeight(forWidth: bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 高度依赖宽度,宽度变化后需重新计算
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        let totalHeight = layoutButtons(width: bounds.width)
        if abs(bounds.height - totalHeight) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }

    /// 换行布局:返回总高度,并把每行放到容器顶部起算的正确位置
    private func layoutButtons(width available: CGFloat) -> CGFloat {
        var xOffset: CGFloat = 0
        var rowTop: CGFloat = 0  // 已累计的行高(自顶部起算)
        var rowHeight: CGFloat = 0
        // 先按行收集各按钮的 (x, 行顶偏移),再统一翻转 y(AppKit 原点在左下)
        var placements: [(x: CGFloat, rowOffset: CGFloat, size: NSSize)] = []

        for button in tagButtons {
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
        for (button, placement) in zip(tagButtons, placements) {
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
        var xOffset: CGFloat = 0
        var rowTop: CGFloat = 0
        var rowHeight: CGFloat = 0
        for button in tagButtons {
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

    private func refreshSelectionStates() {
        for button in tagButtons {
            button.setSelected(button.currencyCode == selectedCode)
        }
    }

    @objc private func tagClicked(_ sender: CurrencyTagButton) {
        onTagClicked?(sender.currencyCode)
    }
}
