import AppKit

// MARK: - Result Cell View

/// 文字（名称+路径）和右侧装饰均与左侧图标垂直居中对齐
/// 无路径时名称自身居中，有路径时名称上移让名称+路径整体居中
class ResultCellView: NSView {
    // MARK: - Subviews

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let aliasBadgeView = NSView()
    private let aliasLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let backgroundView = NSView()

    /// 右侧装饰元素（箭头/统计/链接），与图标垂直居中
    private let rightAccessoryStack = NSStackView()

    private let arrowIndicator = NSImageView()
    private let linkIndicator = NSImageView()
    private let portLabel = NSTextField(labelWithString: "")
    private let cpuIcon = NSImageView()
    private let cpuLabel = NSTextField(labelWithString: "")
    private let memoryIcon = NSImageView()
    private let memoryLabel = NSTextField(labelWithString: "")

    // 动态调整的约束
    private var nameCenterYConstraint: NSLayoutConstraint!
    private var pathTopConstraint: NSLayoutConstraint!

    // portLabel 的固定宽度约束：进程模式下固定 50pt 以与 CPU/内存列对齐；
    // 提醒模式下停用，让宽度按内容自适应，完整显示「列表名 • 日期」
    private var portLabelWidthConstraint: NSLayoutConstraint!

    var onIconClick: (() -> Void)?

    // COLORS: cached at init to avoid the extra compute on every cell configuration
    private let labelColor = NSColor.labelColor
    private let secondaryLabelColor = NSColor.secondaryLabelColor
    private let tertiaryLabelColor = NSColor.tertiaryLabelColor
    private let whiteColor = NSColor.white

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    @objc private func iconClicked() {
        onIconClick?()
    }

    // MARK: - Setup

    private func setupViews() {
        // Background
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconClickGesture = NSClickGestureRecognizer(target: self, action: #selector(iconClicked))
        iconView.addGestureRecognizer(iconClickGesture)
        addSubview(iconView)

        // Name label
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(nameLabel)

        // Path label
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.isHidden = true
        addSubview(pathLabel)

        // Alias badge
        aliasBadgeView.wantsLayer = true
        aliasBadgeView.layer?.cornerRadius = 6
        aliasBadgeView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.25).cgColor
        aliasBadgeView.translatesAutoresizingMaskIntoConstraints = false
        aliasBadgeView.isHidden = true
        addSubview(aliasBadgeView)

        aliasLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        aliasLabel.textColor = secondaryLabelColor
        aliasLabel.translatesAutoresizingMaskIntoConstraints = false
        aliasLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        aliasBadgeView.addSubview(aliasLabel)

        // Right accessory stack
        rightAccessoryStack.translatesAutoresizingMaskIntoConstraints = false
        rightAccessoryStack.isHidden = true
        rightAccessoryStack.orientation = .horizontal
        rightAccessoryStack.spacing = 6
        rightAccessoryStack.alignment = .centerY
        rightAccessoryStack.distribution = .fill
        addSubview(rightAccessoryStack)

        setupRightAccessoryViews()

        // 动态约束（后续通过 constant 调整，不切换 isActive）
        nameCenterYConstraint = nameLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor)
        pathTopConstraint = pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2)

        NSLayoutConstraint.activate([
            // Background
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            // Icon
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            // Name label — dynamic centerY (adjusted for path presence)
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameCenterYConstraint,
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: rightAccessoryStack.leadingAnchor, constant: -12),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -20),

            // Path label — below name, same leading
            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathTopConstraint,
            pathLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -20),

            // Alias badge
            aliasBadgeView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            aliasBadgeView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            aliasLabel.leadingAnchor.constraint(equalTo: aliasBadgeView.leadingAnchor, constant: 6),
            aliasLabel.trailingAnchor.constraint(equalTo: aliasBadgeView.trailingAnchor, constant: -6),
            aliasLabel.topAnchor.constraint(equalTo: aliasBadgeView.topAnchor, constant: 2),
            aliasLabel.bottomAnchor.constraint(equalTo: aliasBadgeView.bottomAnchor, constant: -2),

            // Right accessory stack — centered with icon
            rightAccessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            rightAccessoryStack.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])
    }

    private func setupRightAccessoryViews() {
        arrowIndicator.image = NSImage(
            systemSymbolName: "arrow.right.to.line",
            accessibilityDescription: "Tab to open")
        arrowIndicator.contentTintColor = secondaryLabelColor
        arrowIndicator.translatesAutoresizingMaskIntoConstraints = false
        arrowIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        arrowIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        rightAccessoryStack.addArrangedSubview(arrowIndicator)

        linkIndicator.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Has URL")
        linkIndicator.contentTintColor = .systemBlue
        linkIndicator.translatesAutoresizingMaskIntoConstraints = false
        linkIndicator.widthAnchor.constraint(equalToConstant: 13).isActive = true
        linkIndicator.heightAnchor.constraint(equalToConstant: 13).isActive = true
        rightAccessoryStack.addArrangedSubview(linkIndicator)

        portLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        portLabel.textColor = secondaryLabelColor
        portLabel.translatesAutoresizingMaskIntoConstraints = false
        portLabel.setContentHuggingPriority(.required, for: .horizontal)
        portLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        portLabelWidthConstraint = portLabel.widthAnchor.constraint(equalToConstant: 50)
        portLabelWidthConstraint.isActive = true
        rightAccessoryStack.addArrangedSubview(portLabel)

        cpuIcon.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU")
        cpuIcon.contentTintColor = secondaryLabelColor
        cpuIcon.translatesAutoresizingMaskIntoConstraints = false
        cpuIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        cpuIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        rightAccessoryStack.addArrangedSubview(cpuIcon)

        cpuLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cpuLabel.textColor = secondaryLabelColor
        cpuLabel.translatesAutoresizingMaskIntoConstraints = false
        cpuLabel.widthAnchor.constraint(equalToConstant: 45).isActive = true
        rightAccessoryStack.addArrangedSubview(cpuLabel)

        memoryIcon.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Memory")
        memoryIcon.contentTintColor = secondaryLabelColor
        memoryIcon.translatesAutoresizingMaskIntoConstraints = false
        memoryIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        memoryIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        rightAccessoryStack.addArrangedSubview(memoryIcon)

        memoryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        memoryLabel.textColor = secondaryLabelColor
        memoryLabel.translatesAutoresizingMaskIntoConstraints = false
        memoryLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        rightAccessoryStack.addArrangedSubview(memoryLabel)
    }

    // MARK: - Configure

    func configure(with item: SearchResult, isSelected: Bool, hideArrow: Bool = false) {
        if item.isSectionHeader {
            configureSectionHeader(with: item)
            return
        }

        iconView.isHidden = false
        nameLabel.isHidden = false

        // ---- 名称 ----
        nameLabel.stringValue = item.name

        // ---- Alias badge ----
        if let alias = item.displayAlias, !alias.isEmpty {
            aliasLabel.stringValue = alias
            aliasBadgeView.isHidden = false
        } else {
            aliasLabel.stringValue = ""
            aliasBadgeView.isHidden = true
        }

        // ---- 图标 ----
        configureIcon(for: item, isSelected: isSelected)

        // ---- 路径/副标题 + 垂直对齐 ----
        let isApp = item.path.hasSuffix(".app")
        let isEntry = item.isBookmarkEntry || item.is2FAEntry || item.isMemeEntry
            || item.isFavoriteEntry || item.isClaudeCodeEntry || item.isCodexEntry
        let hasProcessStats = item.processStats != nil && !item.processStats!.isEmpty
        let isReminder = item.isReminder

        let showPath =
            !isApp && !item.isWebLink && !item.isUtility && !item.isSystemCommand
            && !isEntry && !hasProcessStats && !isReminder && !item.isClaudeCodeItem

        pathLabel.isHidden = !showPath
        if showPath {
            pathLabel.stringValue = item.path
            // 有副标题：名称上移使名称+路径整体与图标居中
            // pathLabel 高度 ≈ 13pt (11pt font), spacing = 2, 总偏移 = (13+2)/2 ≈ 7.5
            nameCenterYConstraint.constant = -7
        } else {
            nameCenterYConstraint.constant = 0
        }

        let isPremiumItem =
            isApp || item.isWebLink || item.isUtility || item.isSystemCommand
            || isEntry || hasProcessStats || isReminder || item.isClaudeCodeItem
        nameLabel.font = isPremiumItem
            ? .systemFont(ofSize: 14, weight: .medium)
            : .systemFont(ofSize: 13, weight: .medium)

        // ---- 右侧装饰 ----
        configureRightAccessories(
            item: item, isSelected: isSelected, hideArrow: hideArrow,
            hasProcessStats: hasProcessStats, isReminder: isReminder)

        // ---- 选中样式 ----
        applySelectionStyle(isSelected: isSelected, isReminder: isReminder)
    }

    // MARK: - Private helpers

    private func configureIcon(for item: SearchResult, isSelected: Bool) {
        if item.isReminder {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            iconView.image = item.icon.withSymbolConfiguration(config)
            let color: NSColor = item.reminderColor ?? .systemOrange
            iconView.contentTintColor = isSelected ? whiteColor : color
        } else {
            iconView.image = item.icon
            if item.isClaudeCodeItem && item.path == "active" {
                iconView.contentTintColor = isSelected ? whiteColor : nil
            } else {
                iconView.contentTintColor = nil
            }
        }
    }

    private func configureRightAccessories(
        item: SearchResult, isSelected: Bool, hideArrow: Bool,
        hasProcessStats: Bool, isReminder: Bool
    ) {
        guard !item.isSectionHeader else {
            rightAccessoryStack.isHidden = true
            return
        }

        let isIDE = IDEType.detect(from: item.path) != nil
        let isFolder = item.isDirectory && !item.path.hasSuffix(".app")
        let isQueryWebLink = item.isWebLink && item.supportsQueryExtension
        // Claude Code / Codex 子项不再显示右侧箭头（两个面板的子项均用 isClaudeCodeItem 标记）
        let isEntry = item.isBookmarkEntry || item.is2FAEntry || item.isMemeEntry
            || item.isFavoriteEntry

        let showArrow =
            !hideArrow && !hasProcessStats
            && (isIDE || isFolder || isQueryWebLink || item.isUtility || isEntry)

        arrowIndicator.isHidden = !showArrow

        if isReminder {
            linkIndicator.isHidden = item.reminderURL == nil
            linkIndicator.contentTintColor = isSelected
                ? whiteColor.withAlphaComponent(0.9) : .systemBlue
        } else {
            linkIndicator.isHidden = true
        }

        if hasProcessStats && !isReminder {
            let stats = item.processStats!
            let parts = stats.components(separatedBy: "|")
            if parts.count >= 3 {
                portLabel.stringValue = parts[0]
                cpuLabel.stringValue = parts[1]
                memoryLabel.stringValue = parts[2]
            } else if parts.count == 2 {
                portLabel.stringValue = ""
                cpuLabel.stringValue = parts[0]
                memoryLabel.stringValue = parts[1]
            }
            portLabel.isHidden = false
            // 进程模式：固定 50pt 宽，与 CPU/内存列对齐
            portLabelWidthConstraint.isActive = true
            cpuIcon.isHidden = false
            cpuLabel.isHidden = false
            memoryIcon.isHidden = false
            memoryLabel.isHidden = false
        } else if isReminder, let stats = item.processStats {
            portLabel.isHidden = false
            portLabel.stringValue = stats
            portLabel.alignment = .right
            portLabel.lineBreakMode = .byTruncatingTail
            // 提醒模式：停用固定宽度，按内容自适应，完整显示「列表名 • 日期」
            portLabelWidthConstraint.isActive = false
            portLabel.textColor = isSelected
                ? whiteColor.withAlphaComponent(0.9) : secondaryLabelColor
            portLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            portLabel.setContentHuggingPriority(.required, for: .horizontal)
            cpuIcon.isHidden = true
            cpuLabel.isHidden = true
            memoryIcon.isHidden = true
            memoryLabel.isHidden = true
        } else {
            portLabel.isHidden = true
            portLabelWidthConstraint.isActive = true
            cpuIcon.isHidden = true
            cpuLabel.isHidden = true
            memoryIcon.isHidden = true
            memoryLabel.isHidden = true
        }

        let anyAccessoryVisible = !arrowIndicator.isHidden || !linkIndicator.isHidden
            || !portLabel.isHidden || !cpuLabel.isHidden || !memoryLabel.isHidden
        rightAccessoryStack.isHidden = !anyAccessoryVisible
    }

    private func applySelectionStyle(isSelected: Bool, isReminder: Bool) {
        if isSelected {
            backgroundView.layer?.backgroundColor =
                NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            nameLabel.textColor = whiteColor
            pathLabel.textColor = whiteColor.withAlphaComponent(0.8)
            arrowIndicator.contentTintColor = whiteColor.withAlphaComponent(0.8)
            linkIndicator.contentTintColor = whiteColor.withAlphaComponent(0.9)
            portLabel.textColor = isReminder
                ? whiteColor.withAlphaComponent(0.8) : whiteColor.withAlphaComponent(0.9)
            cpuIcon.contentTintColor = whiteColor.withAlphaComponent(0.7)
            cpuLabel.textColor = whiteColor.withAlphaComponent(0.8)
            memoryIcon.contentTintColor = whiteColor.withAlphaComponent(0.7)
            memoryLabel.textColor = whiteColor.withAlphaComponent(0.8)
            aliasLabel.textColor = whiteColor.withAlphaComponent(0.9)
            aliasBadgeView.layer?.backgroundColor = whiteColor.withAlphaComponent(0.2).cgColor
        } else {
            backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
            nameLabel.textColor = labelColor
            pathLabel.textColor = secondaryLabelColor
            arrowIndicator.contentTintColor = secondaryLabelColor
            linkIndicator.contentTintColor = .systemBlue
            portLabel.textColor = secondaryLabelColor
            cpuIcon.contentTintColor = tertiaryLabelColor
            cpuLabel.textColor = secondaryLabelColor
            memoryIcon.contentTintColor = tertiaryLabelColor
            memoryLabel.textColor = secondaryLabelColor
            aliasLabel.textColor = secondaryLabelColor
            aliasBadgeView.layer?.backgroundColor =
                NSColor.systemGray.withAlphaComponent(0.25).cgColor
        }
    }

    private func configureSectionHeader(with item: SearchResult) {
        iconView.isHidden = true
        aliasBadgeView.isHidden = true
        aliasLabel.stringValue = ""
        pathLabel.isHidden = true
        rightAccessoryStack.isHidden = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        nameCenterYConstraint.constant = 0

        nameLabel.stringValue = item.name
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = secondaryLabelColor
    }
}
