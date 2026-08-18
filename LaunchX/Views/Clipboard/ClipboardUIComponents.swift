import Cocoa

// MARK: - 剪贴板单元格视图

class ClipboardCellView: NSTableCellView {

    private let appIconView = NSImageView()  // 来源App图标
    private let contentLabel = NSTextField()  // 内容文字
    private let colorCircleView = NSView()  // 颜色圆形显示
    private let pinIndicator = NSImageView()
    private let previewImageView = NSImageView()  // 图片预览

    // 约束引用，用于动态调整
    private var contentLabelCenterYConstraint: NSLayoutConstraint?
    private var contentLabelTopConstraint: NSLayoutConstraint?

    // 图片预览尺寸约束（用于动态调整）
    private var previewImageWidthConstraint: NSLayoutConstraint?
    private var previewImageHeightConstraint: NSLayoutConstraint?

    /// 文字最大展示行数（多行/单行统一上限）
    static let maxLines = 5

    /// 逻辑行数阈值：超过该值（即 ≥3 行）改用「每行单行 + 尾部 … 截断」，
    /// 便于快速浏览多行内容（如日志）的头部；1~2 行则按词换行，尽量展示完整内容。
    static let perLineTruncationThreshold = 2

    /// 文本的逻辑行数（按换行分段，忽略首尾空白/换行；空文本算 1 行）。
    /// 只数换行符、不 split 全文：大文本（如上千行日志）在行高估算里
    /// 会被反复调用，全量拆行数组会造成明显卡顿。
    static func logicalLineCount(in text: String) -> Int {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 1 }
        var newlines = 0
        var searchStart = normalized.startIndex
        while let range = normalized.range(of: "\n", range: searchStart..<normalized.endIndex) {
            newlines += 1
            searchStart = range.upperBound
        }
        return newlines + 1
    }

    /// 是否采用「每行单行截断」展示（逻辑行数较多时，如日志）。
    static func usesPerLineTruncation(for text: String) -> Bool {
        logicalLineCount(in: text) > perLineTruncationThreshold
    }

    /// 列表预览文本：只保留前 maxLines 行、每行截到 maxCharsPerLine 字符，超出以「…」结尾。
    /// 大文本不再整段进入 NSTextField / 行高估算 —— maximumNumberOfLines 只影响绘制，
    /// 不阻止 Core Text 对全文排版测量，整段数 KB 文本即足以卡住主线程。
    /// 复制、粘贴仍使用 item.textContent 全文，不受影响。
    static func previewText(of text: String, maxLines: Int = 6, maxCharsPerLine: Int = 200) -> String {
        var lines: [String] = []
        var lineStart = text.startIndex
        var didTruncate = false
        while lineStart < text.endIndex && lines.count < maxLines {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let limit =
                text.index(lineStart, offsetBy: maxCharsPerLine, limitedBy: lineEnd) ?? lineEnd
            if limit < lineEnd { didTruncate = true }  // 行内截断（超长单行）
            lines.append(String(text[lineStart..<limit]))
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
        }
        if lineStart < text.endIndex { didTruncate = true }  // 行数超限
        let preview = lines.joined(separator: "\n")
        return didTruncate ? preview + "…" : preview
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // 来源App图标
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(appIconView)

        // 颜色圆形（用于颜色类型）
        colorCircleView.wantsLayer = true
        colorCircleView.layer?.cornerRadius = 12  // 24/2
        colorCircleView.layer?.borderColor = NSColor.white.cgColor
        colorCircleView.layer?.borderWidth = 2
        colorCircleView.layer?.masksToBounds = true
        colorCircleView.translatesAutoresizingMaskIntoConstraints = false
        colorCircleView.isHidden = true
        addSubview(colorCircleView)

        // 固定指示器
        pinIndicator.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "已固定")
        pinIndicator.contentTintColor = .systemOrange
        pinIndicator.translatesAutoresizingMaskIntoConstraints = false
        pinIndicator.isHidden = true
        addSubview(pinIndicator)

        // 内容文字
        contentLabel.isEditable = false
        contentLabel.isBordered = false
        contentLabel.backgroundColor = .clear
        contentLabel.font = .systemFont(ofSize: 13)
        contentLabel.lineBreakMode = .byWordWrapping
        contentLabel.maximumNumberOfLines = Self.maxLines
        contentLabel.cell?.wraps = true
        contentLabel.cell?.truncatesLastVisibleLine = true
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentLabel)

        // 图片预览
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 4
        previewImageView.layer?.masksToBounds = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.isHidden = true
        addSubview(previewImageView)

        // 创建可切换的约束
        contentLabelCenterYConstraint = contentLabel.centerYAnchor.constraint(
            equalTo: appIconView.centerYAnchor)
        // 文字距离顶部14pt，视觉上与图标垂直居中（图标顶部8pt + 图标高28pt/2 - 字体高度/2 ≈ 14pt）
        contentLabelTopConstraint = contentLabel.topAnchor.constraint(
            equalTo: topAnchor, constant: 14)

        // 图片预览尺寸约束（默认正方形）
        previewImageWidthConstraint = previewImageView.widthAnchor.constraint(equalToConstant: 85)
        previewImageHeightConstraint = previewImageView.heightAnchor.constraint(equalToConstant: 85)

        // 布局
        NSLayoutConstraint.activate([
            // App图标（左侧，顶部对齐）
            appIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            appIconView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            appIconView.widthAnchor.constraint(equalToConstant: 28),
            appIconView.heightAnchor.constraint(equalToConstant: 28),

            // 颜色圆形（替代App图标位置）
            colorCircleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            colorCircleView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            colorCircleView.widthAnchor.constraint(equalToConstant: 24),
            colorCircleView.heightAnchor.constraint(equalToConstant: 24),

            // 固定指示器（右侧，顶部对齐）
            pinIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pinIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            pinIndicator.widthAnchor.constraint(equalToConstant: 14),
            pinIndicator.heightAnchor.constraint(equalToConstant: 14),

            // 内容文字（水平位置固定，垂直位置动态调整）
            contentLabel.leadingAnchor.constraint(
                equalTo: appIconView.trailingAnchor, constant: 10),
            contentLabel.trailingAnchor.constraint(
                equalTo: pinIndicator.leadingAnchor, constant: -8),
            contentLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),

            // 图片预览（顶部对齐，与图标顶部对齐）
            previewImageView.leadingAnchor.constraint(
                equalTo: appIconView.trailingAnchor, constant: 10),
            previewImageView.topAnchor.constraint(equalTo: appIconView.topAnchor),
            previewImageWidthConstraint!,
            previewImageHeightConstraint!,
        ])
    }

    func configure(with item: ClipboardItem) {
        // 重置状态
        previewImageView.isHidden = true
        contentLabel.isHidden = false
        appIconView.isHidden = false
        colorCircleView.isHidden = true

        // 固定指示器
        pinIndicator.isHidden = !item.isPinned

        // 设置来源App图标
        if let bundleId = item.sourceAppBundleId,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        {
            appIconView.image = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            appIconView.image = item.icon
        }

        // 根据类型配置
        switch item.contentType {
        case .image:
            // 图片类型显示预览（按需懒加载，避免历史图片常驻内存）
            if let data = ClipboardService.shared.imageData(for: item), let image = NSImage(data: data) {
                previewImageView.image = image
                previewImageView.isHidden = false
                contentLabel.isHidden = true

                // 计算图片尺寸，根据实际比例自适应
                let maxPreviewWidth: CGFloat = 200
                let maxPreviewHeight: CGFloat = 85
                let aspectRatio = image.size.width / max(image.size.height, 1)

                let imageWidth: CGFloat
                let imageHeight: CGFloat

                if aspectRatio >= 1 {
                    // 宽图：宽度优先，高度按比例
                    imageWidth = min(maxPreviewHeight * aspectRatio, maxPreviewWidth)
                    imageHeight = imageWidth / aspectRatio
                } else {
                    // 高图：高度优先，宽度按比例
                    imageHeight = maxPreviewHeight
                    imageWidth = imageHeight * aspectRatio
                }

                previewImageWidthConstraint?.constant = max(imageWidth, 28)  // 最小宽度28（与图标同宽）
                previewImageHeightConstraint?.constant = max(imageHeight, 28)  // 最小高度28

                // 图片类型不需要文字约束
                contentLabelCenterYConstraint?.isActive = false
                contentLabelTopConstraint?.isActive = false
            } else {
                contentLabel.stringValue = "图片"
                // 文字和图标垂直居中
                contentLabelCenterYConstraint?.isActive = true
                contentLabelTopConstraint?.isActive = false
            }

        case .color:
            // 颜色类型显示圆形颜色块
            if let hex = item.colorHex, let color = NSColor(hex: hex) {
                colorCircleView.layer?.backgroundColor = color.cgColor
                colorCircleView.isHidden = false
                appIconView.isHidden = true
                contentLabel.stringValue = hex.uppercased()
            } else {
                contentLabel.stringValue = item.displayTitle
            }
            // 文字和图标垂直居中（单行）
            contentLabelCenterYConstraint?.isActive = true
            contentLabelTopConstraint?.isActive = false

        case .text, .link:
            let text = item.textContent ?? ""
            // 只把预览（前几行）交给 NSTextField，全文留给复制/粘贴用
            let preview = Self.previewText(of: text)
            contentLabel.stringValue = preview

            // 单行/少行文本：按词换行（byWordWrapping），尽量展示完整内容；
            // 多行文本（如日志）：每行单行 + 尾部 … 截断（byTruncatingTail），便于扫头部。
            // 注意：换行必须用 byWordWrapping，byTruncatingTail + wraps 会导致不换行。
            let usesTruncation = Self.usesPerLineTruncation(for: preview)
            contentLabel.cell?.wraps = !usesTruncation
            contentLabel.lineBreakMode = usesTruncation ? .byTruncatingTail : .byWordWrapping
            contentLabel.maximumNumberOfLines = Self.maxLines
            contentLabel.cell?.truncatesLastVisibleLine = true

            // 文字始终顶部对齐（固定距离顶部，视觉上与图标居中）
            contentLabelCenterYConstraint?.isActive = false
            contentLabelTopConstraint?.isActive = true

        case .file:
            if let paths = item.filePaths, let firstPath = paths.first {
                let fileName = (firstPath as NSString).lastPathComponent
                if paths.count > 1 {
                    contentLabel.stringValue = "\(fileName) 等 \(paths.count) 个文件"
                } else {
                    contentLabel.stringValue = fileName
                }
            } else {
                contentLabel.stringValue = item.displayTitle
            }
            // 文字和图标垂直居中
            contentLabelCenterYConstraint?.isActive = true
            contentLabelTopConstraint?.isActive = false
        }
    }
}

// MARK: - 自定义 TableRowView（始终保持蓝色高亮）

class EmphasizedTableRowView: NSTableRowView {
    // 重写 isEmphasized 属性，始终返回 true
    // 这样即使窗口不是 key window，选中高亮也会保持蓝色
    override var isEmphasized: Bool {
        get { return true }
        set {}
    }
}

// MARK: - 可拖拽视图（用于窗口拖拽）

class DraggableView: NSView {

    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero
    private let handleView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHandle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHandle()
    }

    private func setupHandle() {
        // 小横杠视觉指示器
        handleView.wantsLayer = true
        updateHandleColor()
        handleView.layer?.cornerRadius = 2
        handleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handleView)

        NSLayoutConstraint.activate([
            handleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            handleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            handleView.widthAnchor.constraint(equalToConstant: 36),
            handleView.heightAnchor.constraint(equalToConstant: 4),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 确保系统主题切换时，Layer 的颜色也能同步更新
        updateHandleColor()
    }

    private func updateHandleColor() {
        // 使用比 separatorColor 更明显的 tertiaryLabelColor
        handleView.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }

        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - initialMouseLocation.x
        let deltaY = currentLocation.y - initialMouseLocation.y

        let newOrigin = NSPoint(
            x: initialWindowOrigin.x + deltaX,
            y: initialWindowOrigin.y + deltaY
        )

        window.setFrameOrigin(newOrigin)
    }
}

// MARK: - 可调整大小的容器视图（处理左右边缘拖拽）

class ResizableContainerView: NSView {

    private let resizeEdgeWidth: CGFloat = 10
    private let panelMinWidth: CGFloat = 430
    private let panelMaxWidth: CGFloat = 800

    private var isResizing = false
    private var resizeEdge: ResizeEdge = .none
    private var initialFrame: NSRect = .zero
    private var initialMouseLocation: NSPoint = .zero

    enum ResizeEdge {
        case none, left, right
    }

    // 重写 hitTest 让边缘区域的事件由自己处理
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 如果不在窗口内，不处理
        guard let window = window else { return super.hitTest(point) }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)

        // 检查是否在视图范围内
        guard bounds.contains(localPoint) else { return nil }

        // 如果在左右边缘，返回自己来处理事件
        if localPoint.x < resizeEdgeWidth || localPoint.x > bounds.width - resizeEdgeWidth {
            return self
        }

        // 否则正常传递给子视图
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // 移除旧的追踪区域
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        // 左边缘追踪区域
        let leftEdgeRect = NSRect(x: 0, y: 0, width: resizeEdgeWidth, height: bounds.height)
        let leftOptions: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .activeAlways, .cursorUpdate,
        ]
        let leftTrackingArea = NSTrackingArea(
            rect: leftEdgeRect, options: leftOptions, owner: self, userInfo: ["edge": "left"])
        addTrackingArea(leftTrackingArea)

        // 右边缘追踪区域
        let rightEdgeRect = NSRect(
            x: bounds.width - resizeEdgeWidth, y: 0, width: resizeEdgeWidth, height: bounds.height)
        let rightTrackingArea = NSTrackingArea(
            rect: rightEdgeRect, options: leftOptions, owner: self, userInfo: ["edge": "right"])
        addTrackingArea(rightTrackingArea)
    }

    override func cursorUpdate(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if location.x < resizeEdgeWidth || location.x > bounds.width - resizeEdgeWidth {
            NSCursor.resizeLeftRight.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        if !isResizing {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if location.x < resizeEdgeWidth {
            resizeEdge = .left
            isResizing = true
        } else if location.x > bounds.width - resizeEdgeWidth {
            resizeEdge = .right
            isResizing = true
        } else {
            resizeEdge = .none
            isResizing = false
            super.mouseDown(with: event)
            return
        }

        if isResizing {
            initialFrame = window?.frame ?? .zero
            initialMouseLocation = NSEvent.mouseLocation
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing, let window = window else {
            super.mouseDragged(with: event)
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - initialMouseLocation.x

        var newFrame = initialFrame

        switch resizeEdge {
        case .left:
            var newWidth = initialFrame.width - deltaX
            // 限制在边界内
            newWidth = max(panelMinWidth, min(panelMaxWidth, newWidth))
            let actualDelta = initialFrame.width - newWidth
            newFrame.origin.x = initialFrame.origin.x + actualDelta
            newFrame.size.width = newWidth
        case .right:
            var newWidth = initialFrame.width + deltaX
            // 限制在边界内
            newWidth = max(panelMinWidth, min(panelMaxWidth, newWidth))
            newFrame.size.width = newWidth
        case .none:
            break
        }

        window.setFrame(newFrame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            isResizing = false
            resizeEdge = .none

            // 保存新尺寸
            if let window = window {
                var settings = ClipboardSettings.load()
                settings.panelWidth = window.frame.width
                settings.panelHeight = window.frame.height
                settings.save()
            }

            NSCursor.arrow.set()
        } else {
            super.mouseUp(with: event)
        }
    }
}

// MARK: - 快捷键提示视图

class ShortcutHintView: NSView {

    private let stackView = NSStackView()
    private let keySize: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // 改为水平布局，一行显示
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // 粘贴选中行: ↵
        let pasteHint = createHintGroup(text: "粘贴", keys: ["↵"])
        stackView.addArrangedSubview(pasteHint)

        // 粘贴为纯文本: ⌘ ↵
        let plainTextHint = createHintGroup(text: "纯文本", keys: ["⌘", "↵"])
        stackView.addArrangedSubview(plainTextHint)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func createHintGroup(text: String, keys: [String]) -> NSView {
        let groupStack = NSStackView()
        groupStack.orientation = .horizontal
        groupStack.spacing = 3
        groupStack.alignment = .centerY

        // 文字标签
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        groupStack.addArrangedSubview(label)

        // 按键图标
        for key in keys {
            let keyView = createKeyView(key)
            groupStack.addArrangedSubview(keyView)
        }

        return groupStack
    }

    private func createKeyView(_ key: String) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        container.layer?.cornerRadius = 3

        let label = NSTextField(labelWithString: key)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: keySize),
            container.heightAnchor.constraint(equalToConstant: keySize),
        ])

        return container
    }
}
