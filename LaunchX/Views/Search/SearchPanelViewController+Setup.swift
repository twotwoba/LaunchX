import AppKit

// MARK: - UI Setup

extension SearchPanelViewController {
    // MARK: - Setup

    func setupUI() {
        // IDE Tag View (用于 IDE 项目模式)
        ideTagView.wantsLayer = true
        ideTagView.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        ideTagView.layer?.cornerRadius = 6
        ideTagView.translatesAutoresizingMaskIntoConstraints = false
        ideTagView.setContentHuggingPriority(.required, for: .horizontal)
        ideTagView.isHidden = true
        contentView.addSubview(ideTagView)

        ideIconView.translatesAutoresizingMaskIntoConstraints = false
        ideTagView.addSubview(ideIconView)

        ideNameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        ideNameLabel.textColor = .labelColor
        ideNameLabel.translatesAutoresizingMaskIntoConstraints = false
        ideNameLabel.setContentHuggingPriority(.required, for: .horizontal)
        ideNameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        ideTagView.addSubview(ideNameLabel)

        // Search icon (隐藏，不再显示)
        searchIcon.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.isHidden = true
        contentView.addSubview(searchIcon)

        // Search field
        setPlaceholder("搜索应用或文档...")
        searchField.isBordered = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 22, weight: .regular)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(searchField)

        // Divider
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isHidden = true
        contentView.addSubview(divider)

        // Table view setup
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ResultColumn"))
        column.width = 610
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = rowHeight
        tableView.delegate = self
        tableView.dataSource = self
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.doubleAction = #selector(tableViewDoubleClicked)

        // Scroll view
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true
        contentView.addSubview(scrollView)

        // No results label
        noResultsLabel.textColor = .secondaryLabelColor
        noResultsLabel.alignment = .center
        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false
        noResultsLabel.isHidden = true
        contentView.addSubview(noResultsLabel)

        // Constraints
        NSLayoutConstraint.activate([
            // IDE Tag View - 与搜索框垂直居中对齐，微调 +3 补偿视觉偏差
            ideTagView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            ideTagView.centerYAnchor.constraint(equalTo: searchField.centerYAnchor, constant: -3),
            ideTagView.heightAnchor.constraint(equalToConstant: 28),

            ideIconView.leadingAnchor.constraint(equalTo: ideTagView.leadingAnchor, constant: 6),
            ideIconView.centerYAnchor.constraint(equalTo: ideTagView.centerYAnchor),
            ideIconView.widthAnchor.constraint(equalToConstant: 18),
            ideIconView.heightAnchor.constraint(equalToConstant: 18),

            ideNameLabel.leadingAnchor.constraint(equalTo: ideIconView.trailingAnchor, constant: 6),
            ideNameLabel.trailingAnchor.constraint(
                equalTo: ideTagView.trailingAnchor, constant: -8),
            ideNameLabel.centerYAnchor.constraint(equalTo: ideTagView.centerYAnchor),

            // Search icon
            searchIcon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            searchIcon.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            searchIcon.widthAnchor.constraint(equalToConstant: 22),
            searchIcon.heightAnchor.constraint(equalToConstant: 22),

            // Search field (leading 约束单独处理，用于 IDE 模式切换)
            searchField.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
            searchField.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            // Divider
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            // Scroll view
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),

            // No results label
            noResultsLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        ])

        // 为可能在简约模式下产生冲突的约束设置优先级
        let dividerTopConstraint = divider.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: headerHeight)
        dividerTopConstraint.priority = .init(999)  // 略低于强制约束，允许在 80px 高度时微调
        dividerTopConstraint.isActive = true

        let noResultsTopConstraint = noResultsLabel.topAnchor.constraint(
            equalTo: divider.bottomAnchor, constant: 20)
        noResultsTopConstraint.priority = .defaultLow
        noResultsTopConstraint.isActive = true

        // Define main height constraint
        contentHeightConstraint = contentView.heightAnchor.constraint(equalToConstant: headerHeight)
        contentHeightConstraint?.isActive = true

        // 为 ScrollView 设置低优先级的垂直约束，解决简约模式下的高度冲突
        let scrollBottomConstraint = scrollView.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor, constant: -10)
        scrollBottomConstraint.priority = .defaultLow
        scrollBottomConstraint.isActive = true

        // 创建并保存 searchField 的 leading 约束
        // 默认直接从左边开始（无搜索图标）
        searchFieldLeadingToIcon = searchField.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: 20)
        searchFieldLeadingToTag = searchField.leadingAnchor.constraint(
            equalTo: ideTagView.trailingAnchor, constant: 12)
        searchFieldLeadingToIcon?.isActive = true

        // UUID 生成器 UI 设置
        setupUUIDGeneratorUI()

        // URL 编码解码 UI 设置
        setupURLCoderUI()

        // Base64 编码解码 UI 设置
        setupBase64CoderUI()

        // 计算器结果预览设置
        calculatorResultLabel.textColor = .secondaryLabelColor
        calculatorResultLabel.font = searchField.font
        calculatorResultLabel.isEditable = false
        calculatorResultLabel.isSelectable = false
        calculatorResultLabel.isBordered = false
        calculatorResultLabel.lineBreakMode = .byTruncatingTail
        calculatorResultLabel.maximumNumberOfLines = 1
        calculatorResultLabel.drawsBackground = false
        calculatorResultLabel.translatesAutoresizingMaskIntoConstraints = false
        calculatorResultLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        calculatorResultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        calculatorResultLabel.refusesFirstResponder = true
        // 将计算器结果标签添加在 searchField 下层，确保不会遮挡 ideTagView
        contentView.addSubview(calculatorResultLabel, positioned: .below, relativeTo: searchField)

        NSLayoutConstraint.activate([
            calculatorResultLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            // 使用基线对齐 (firstBaselineAnchor) 确保不同字重的文字在视觉上完美对齐
            calculatorResultLabel.firstBaselineAnchor.constraint(
                equalTo: searchField.firstBaselineAnchor),
        ])

        let calcTrailing = calculatorResultLabel.trailingAnchor.constraint(
            equalTo: searchField.trailingAnchor)
        calcTrailing.priority = .defaultHigh
        calcTrailing.isActive = true

        // 币种胶囊选择行(汇率命中时替换结果列表展示)
        setupCurrencyTagView()

        // 计算器面板(表达式命中时替换结果列表展示)
        setupCalculatorPanelView()
    }

    /// 设置币种胶囊选择行 UI
    func setupCurrencyTagView() {
        currencyTagView.translatesAutoresizingMaskIntoConstraints = false
        currencyTagView.isHidden = true
        currencyTagView.onTagClicked = { [weak self] code in
            self?.currencyTagClicked(code)
        }
        contentView.addSubview(currencyTagView)

        NSLayoutConstraint.activate([
            currencyTagView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 20),
            currencyTagView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
            // 高度由 intrinsicContentSize(换行后行数)自适应
            currencyTagView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
        ])
    }

    /// 设置 UUID 生成器 UI
    func setupUUIDGeneratorUI() {
        // 选项容器
        uuidOptionsView.translatesAutoresizingMaskIntoConstraints = false
        uuidOptionsView.isHidden = true
        contentView.addSubview(uuidOptionsView)

        // 连字符复选框
        hyphenCheckbox.state = .on
        hyphenCheckbox.target = self
        hyphenCheckbox.action = #selector(uuidOptionChanged)
        hyphenCheckbox.translatesAutoresizingMaskIntoConstraints = false
        hyphenCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        hyphenCheckbox.refusesFirstResponder = true
        uuidOptionsView.addSubview(hyphenCheckbox)

        // 大写单选按钮
        uppercaseRadio.state = .on
        uppercaseRadio.target = self
        uppercaseRadio.action = #selector(uuidCaseChanged(_:))
        uppercaseRadio.translatesAutoresizingMaskIntoConstraints = false
        uppercaseRadio.setContentHuggingPriority(.required, for: .horizontal)
        uppercaseRadio.refusesFirstResponder = true
        uuidOptionsView.addSubview(uppercaseRadio)

        // 小写单选按钮
        lowercaseRadio.state = .off
        lowercaseRadio.target = self
        lowercaseRadio.action = #selector(uuidCaseChanged(_:))
        lowercaseRadio.translatesAutoresizingMaskIntoConstraints = false
        lowercaseRadio.setContentHuggingPriority(.required, for: .horizontal)
        lowercaseRadio.refusesFirstResponder = true
        uuidOptionsView.addSubview(lowercaseRadio)

        // 结果标签
        resultLabel.stringValue = "结果"
        resultLabel.font = .systemFont(ofSize: 12, weight: .medium)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        uuidOptionsView.addSubview(resultLabel)

        // UUID 结果滚动视图
        uuidResultView.hasVerticalScroller = true
        uuidResultView.hasHorizontalScroller = false
        uuidResultView.autohidesScrollers = true
        uuidResultView.borderType = .noBorder
        uuidResultView.drawsBackground = false
        uuidResultView.translatesAutoresizingMaskIntoConstraints = false
        uuidOptionsView.addSubview(uuidResultView)

        // UUID 结果文本视图
        uuidResultTextView.isEditable = false
        uuidResultTextView.isSelectable = true
        uuidResultTextView.isRichText = false
        uuidResultTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        uuidResultTextView.drawsBackground = false
        uuidResultTextView.textColor = .labelColor
        uuidResultTextView.textContainerInset = NSSize(width: 0, height: 4)
        uuidResultTextView.textContainer?.lineFragmentPadding = 0
        uuidResultTextView.autoresizingMask = [.width]
        uuidResultView.documentView = uuidResultTextView

        // UUID 选项约束
        NSLayoutConstraint.activate([
            uuidOptionsView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 20),
            uuidOptionsView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
            uuidOptionsView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),

            // 第一行：选项按钮（水平排列）
            hyphenCheckbox.leadingAnchor.constraint(equalTo: uuidOptionsView.leadingAnchor),
            hyphenCheckbox.topAnchor.constraint(equalTo: uuidOptionsView.topAnchor),

            uppercaseRadio.leadingAnchor.constraint(
                equalTo: hyphenCheckbox.trailingAnchor, constant: 16),
            uppercaseRadio.centerYAnchor.constraint(equalTo: hyphenCheckbox.centerYAnchor),

            lowercaseRadio.leadingAnchor.constraint(
                equalTo: uppercaseRadio.trailingAnchor, constant: 12),
            lowercaseRadio.centerYAnchor.constraint(equalTo: hyphenCheckbox.centerYAnchor),

            // 结果标签
            resultLabel.leadingAnchor.constraint(equalTo: uuidOptionsView.leadingAnchor),
            resultLabel.topAnchor.constraint(equalTo: hyphenCheckbox.bottomAnchor, constant: 12),

            // UUID 结果视图
            uuidResultView.leadingAnchor.constraint(equalTo: uuidOptionsView.leadingAnchor),
            uuidResultView.trailingAnchor.constraint(equalTo: uuidOptionsView.trailingAnchor),
            uuidResultView.topAnchor.constraint(equalTo: resultLabel.bottomAnchor, constant: 8),
            uuidResultView.bottomAnchor.constraint(equalTo: uuidOptionsView.bottomAnchor),
        ])

        uuidOptionsView.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor, constant: -12
        ).isActive = true
    }

    /// 设置 URL 编码解码 UI
    func setupURLCoderUI() {
        // URL 编码解码容器
        urlCoderView.translatesAutoresizingMaskIntoConstraints = false
        urlCoderView.isHidden = true
        contentView.addSubview(urlCoderView)

        // 解码的 URL 标签
        decodedURLLabel.font = .systemFont(ofSize: 12, weight: .medium)
        decodedURLLabel.textColor = .secondaryLabelColor
        decodedURLLabel.translatesAutoresizingMaskIntoConstraints = false
        urlCoderView.addSubview(decodedURLLabel)

        // 解码的 URL 复制按钮
        decodedURLCopyButton.image = NSImage(
            systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
        decodedURLCopyButton.bezelStyle = .inline
        decodedURLCopyButton.isBordered = false
        decodedURLCopyButton.target = self
        decodedURLCopyButton.action = #selector(copyDecodedURL)
        decodedURLCopyButton.translatesAutoresizingMaskIntoConstraints = false
        urlCoderView.addSubview(decodedURLCopyButton)

        // 解码的 URL 输入框背景
        let decodedFieldBg = NSView()
        decodedFieldBg.wantsLayer = true
        decodedFieldBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        decodedFieldBg.layer?.cornerRadius = 6
        decodedFieldBg.translatesAutoresizingMaskIntoConstraints = false
        urlCoderView.addSubview(decodedFieldBg)

        // 解码的 URL 滚动视图
        decodedURLScrollView.hasVerticalScroller = true
        decodedURLScrollView.hasHorizontalScroller = false
        decodedURLScrollView.autohidesScrollers = true
        decodedURLScrollView.borderType = .noBorder
        decodedURLScrollView.drawsBackground = false
        decodedURLScrollView.translatesAutoresizingMaskIntoConstraints = false
        urlCoderView.addSubview(decodedURLScrollView)

        // 解码的 URL 文本视图
        decodedURLTextView.isEditable = true
        decodedURLTextView.isSelectable = true
        decodedURLTextView.isRichText = false
        decodedURLTextView.font = .systemFont(ofSize: 13)
        decodedURLTextView.drawsBackground = false
        decodedURLTextView.textColor = .labelColor
        decodedURLTextView.textContainerInset = NSSize(width: 4, height: 4)
        decodedURLTextView.delegate = self
        decodedURLTextView.autoresizingMask = [.width]
        decodedURLScrollView.documentView = decodedURLTextView

        // 编码的 URL 标签
        encodedURLLabel.font = .systemFont(ofSize: 12, weight: .medium)
        encodedURLLabel.textColor = .secondaryLabelColor
        encodedURLLabel.translatesAutoresizingMaskIntoConstraints = false
        urlCoderView.addSubview(encodedURLLabel)

        // 编码的 URL 复制按钮
        encodedURLCopyButton.image = NSImage(
            systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
        encodedURLCopyButton.bezelStyle = .inline
        encodedURLCopyButton.isBordered = false
        encodedURLCopyButton.target = self
        encodedURLCopyButton.action = #selector(copyEncodedURL)
        encodedURLCopyButton.translatesAutoresizingMaskIntoConstraints = false
        urlCoderView.addSubview(encodedURLCopyButton)

        // 编码的 URL 输入框背景
        let encodedFieldBg = NSView()
        encodedFieldBg.wantsLayer = true
        encodedFieldBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        encodedFieldBg.layer?.cornerRadius = 6
        encodedFieldBg.translatesAutoresizingMaskIntoConstraints = false
        urlCoderView.addSubview(encodedFieldBg)

        // 编码的 URL 滚动视图
        encodedURLScrollView.hasVerticalScroller = true
        encodedURLScrollView.hasHorizontalScroller = false
        encodedURLScrollView.autohidesScrollers = true
        encodedURLScrollView.borderType = .noBorder
        encodedURLScrollView.drawsBackground = false
        encodedURLScrollView.translatesAutoresizingMaskIntoConstraints = false
        urlCoderView.addSubview(encodedURLScrollView)

        // 编码的 URL 文本视图
        encodedURLTextView.isEditable = true
        encodedURLTextView.isSelectable = true
        encodedURLTextView.isRichText = false
        encodedURLTextView.font = .systemFont(ofSize: 13)
        encodedURLTextView.drawsBackground = false
        encodedURLTextView.textColor = .labelColor
        encodedURLTextView.textContainerInset = NSSize(width: 4, height: 4)
        encodedURLTextView.delegate = self
        encodedURLTextView.autoresizingMask = [.width]
        encodedURLScrollView.documentView = encodedURLTextView

        // URL 编码解码约束
        NSLayoutConstraint.activate([
            urlCoderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlCoderView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
            urlCoderView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),

            // 解码的 URL 标签
            decodedURLLabel.leadingAnchor.constraint(equalTo: urlCoderView.leadingAnchor),
            decodedURLLabel.topAnchor.constraint(equalTo: urlCoderView.topAnchor),

            // 解码的 URL 复制按钮
            decodedURLCopyButton.trailingAnchor.constraint(equalTo: urlCoderView.trailingAnchor),
            decodedURLCopyButton.centerYAnchor.constraint(equalTo: decodedURLLabel.centerYAnchor),
            decodedURLCopyButton.widthAnchor.constraint(equalToConstant: 20),
            decodedURLCopyButton.heightAnchor.constraint(equalToConstant: 20),

            // 解码的 URL 输入框背景
            decodedFieldBg.leadingAnchor.constraint(equalTo: urlCoderView.leadingAnchor),
            decodedFieldBg.trailingAnchor.constraint(equalTo: urlCoderView.trailingAnchor),
            decodedFieldBg.topAnchor.constraint(equalTo: decodedURLLabel.bottomAnchor, constant: 6),
            decodedFieldBg.heightAnchor.constraint(equalToConstant: 150),

            // 解码的 URL 滚动视图
            decodedURLScrollView.leadingAnchor.constraint(
                equalTo: decodedFieldBg.leadingAnchor, constant: 4),
            decodedURLScrollView.trailingAnchor.constraint(
                equalTo: decodedFieldBg.trailingAnchor, constant: -4),
            decodedURLScrollView.topAnchor.constraint(
                equalTo: decodedFieldBg.topAnchor, constant: 4),
            decodedURLScrollView.bottomAnchor.constraint(
                equalTo: decodedFieldBg.bottomAnchor, constant: -4),

            // 编码的 URL 标签
            encodedURLLabel.leadingAnchor.constraint(equalTo: urlCoderView.leadingAnchor),
            encodedURLLabel.topAnchor.constraint(
                equalTo: decodedFieldBg.bottomAnchor, constant: 12),

            // 编码的 URL 复制按钮
            encodedURLCopyButton.trailingAnchor.constraint(equalTo: urlCoderView.trailingAnchor),
            encodedURLCopyButton.centerYAnchor.constraint(equalTo: encodedURLLabel.centerYAnchor),
            encodedURLCopyButton.widthAnchor.constraint(equalToConstant: 20),
            encodedURLCopyButton.heightAnchor.constraint(equalToConstant: 20),

            // 编码的 URL 输入框背景
            encodedFieldBg.leadingAnchor.constraint(equalTo: urlCoderView.leadingAnchor),
            encodedFieldBg.trailingAnchor.constraint(equalTo: urlCoderView.trailingAnchor),
            encodedFieldBg.topAnchor.constraint(equalTo: encodedURLLabel.bottomAnchor, constant: 6),
            encodedFieldBg.heightAnchor.constraint(equalToConstant: 150),

            // 编码的 URL 滚动视图
            encodedURLScrollView.leadingAnchor.constraint(
                equalTo: encodedFieldBg.leadingAnchor, constant: 4),
            encodedURLScrollView.trailingAnchor.constraint(
                equalTo: encodedFieldBg.trailingAnchor, constant: -4),
            encodedURLScrollView.topAnchor.constraint(
                equalTo: encodedFieldBg.topAnchor, constant: 4),
            encodedURLScrollView.bottomAnchor.constraint(
                equalTo: encodedFieldBg.bottomAnchor, constant: -4),
        ])

        urlCoderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
            .isActive = true
    }

    /// 设置 Base64 编码解码 UI
    func setupBase64CoderUI() {
        // Base64 编码解码容器
        base64CoderView.translatesAutoresizingMaskIntoConstraints = false
        base64CoderView.isHidden = true
        contentView.addSubview(base64CoderView)

        // 原始文本标签
        originalTextLabel.font = .systemFont(ofSize: 12, weight: .medium)
        originalTextLabel.textColor = .secondaryLabelColor
        originalTextLabel.translatesAutoresizingMaskIntoConstraints = false
        base64CoderView.addSubview(originalTextLabel)

        // 原始文本复制按钮
        originalTextCopyButton.image = NSImage(
            systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
        originalTextCopyButton.bezelStyle = .inline
        originalTextCopyButton.isBordered = false
        originalTextCopyButton.target = self
        originalTextCopyButton.action = #selector(copyOriginalText)
        originalTextCopyButton.translatesAutoresizingMaskIntoConstraints = false
        base64CoderView.addSubview(originalTextCopyButton)

        // 原始文本输入框背景
        let originalFieldBg = NSView()
        originalFieldBg.wantsLayer = true
        originalFieldBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        originalFieldBg.layer?.cornerRadius = 6
        originalFieldBg.translatesAutoresizingMaskIntoConstraints = false
        base64CoderView.addSubview(originalFieldBg)

        // 原始文本滚动视图
        originalTextScrollView.hasVerticalScroller = true
        originalTextScrollView.hasHorizontalScroller = false
        originalTextScrollView.autohidesScrollers = true
        originalTextScrollView.borderType = .noBorder
        originalTextScrollView.drawsBackground = false
        originalTextScrollView.translatesAutoresizingMaskIntoConstraints = false
        base64CoderView.addSubview(originalTextScrollView)

        // 原始文本视图
        originalTextView.isEditable = true
        originalTextView.isSelectable = true
        originalTextView.isRichText = false
        originalTextView.font = .systemFont(ofSize: 13)
        originalTextView.drawsBackground = false
        originalTextView.textColor = .labelColor
        originalTextView.textContainerInset = NSSize(width: 4, height: 4)
        originalTextView.delegate = self
        originalTextView.autoresizingMask = [.width]
        originalTextScrollView.documentView = originalTextView

        // Base64 文本标签
        base64TextLabel.font = .systemFont(ofSize: 12, weight: .medium)
        base64TextLabel.textColor = .secondaryLabelColor
        base64TextLabel.translatesAutoresizingMaskIntoConstraints = false
        base64CoderView.addSubview(base64TextLabel)

        // Base64 文本复制按钮
        base64TextCopyButton.image = NSImage(
            systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
        base64TextCopyButton.bezelStyle = .inline
        base64TextCopyButton.isBordered = false
        base64TextCopyButton.target = self
        base64TextCopyButton.action = #selector(copyBase64Text)
        base64TextCopyButton.translatesAutoresizingMaskIntoConstraints = false
        base64CoderView.addSubview(base64TextCopyButton)

        // Base64 文本输入框背景
        let base64FieldBg = NSView()
        base64FieldBg.wantsLayer = true
        base64FieldBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        base64FieldBg.layer?.cornerRadius = 6
        base64FieldBg.translatesAutoresizingMaskIntoConstraints = false
        base64CoderView.addSubview(base64FieldBg)

        // Base64 文本滚动视图
        base64TextScrollView.hasVerticalScroller = true
        base64TextScrollView.hasHorizontalScroller = false
        base64TextScrollView.autohidesScrollers = true
        base64TextScrollView.borderType = .noBorder
        base64TextScrollView.drawsBackground = false
        base64TextScrollView.translatesAutoresizingMaskIntoConstraints = false
        base64CoderView.addSubview(base64TextScrollView)

        // Base64 文本视图
        base64TextView.isEditable = true
        base64TextView.isSelectable = true
        base64TextView.isRichText = false
        base64TextView.font = .systemFont(ofSize: 13)
        base64TextView.drawsBackground = false
        base64TextView.textColor = .labelColor
        base64TextView.textContainerInset = NSSize(width: 4, height: 4)
        base64TextView.delegate = self
        base64TextView.autoresizingMask = [.width]
        base64TextScrollView.documentView = base64TextView

        // Base64 编码解码约束
        NSLayoutConstraint.activate([
            base64CoderView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 20),
            base64CoderView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
            base64CoderView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),

            // 原始文本标签
            originalTextLabel.leadingAnchor.constraint(equalTo: base64CoderView.leadingAnchor),
            originalTextLabel.topAnchor.constraint(equalTo: base64CoderView.topAnchor),

            // 原始文本复制按钮
            originalTextCopyButton.trailingAnchor.constraint(
                equalTo: base64CoderView.trailingAnchor),
            originalTextCopyButton.centerYAnchor.constraint(
                equalTo: originalTextLabel.centerYAnchor),
            originalTextCopyButton.widthAnchor.constraint(equalToConstant: 20),
            originalTextCopyButton.heightAnchor.constraint(equalToConstant: 20),

            // 原始文本输入框背景
            originalFieldBg.leadingAnchor.constraint(equalTo: base64CoderView.leadingAnchor),
            originalFieldBg.trailingAnchor.constraint(equalTo: base64CoderView.trailingAnchor),
            originalFieldBg.topAnchor.constraint(
                equalTo: originalTextLabel.bottomAnchor, constant: 6),
            originalFieldBg.heightAnchor.constraint(equalToConstant: 150),

            // 原始文本滚动视图
            originalTextScrollView.leadingAnchor.constraint(
                equalTo: originalFieldBg.leadingAnchor, constant: 4),
            originalTextScrollView.trailingAnchor.constraint(
                equalTo: originalFieldBg.trailingAnchor, constant: -4),
            originalTextScrollView.topAnchor.constraint(
                equalTo: originalFieldBg.topAnchor, constant: 4),
            originalTextScrollView.bottomAnchor.constraint(
                equalTo: originalFieldBg.bottomAnchor, constant: -4),

            // Base64 文本标签
            base64TextLabel.leadingAnchor.constraint(equalTo: base64CoderView.leadingAnchor),
            base64TextLabel.topAnchor.constraint(
                equalTo: originalFieldBg.bottomAnchor, constant: 12),

            // Base64 文本复制按钮
            base64TextCopyButton.trailingAnchor.constraint(equalTo: base64CoderView.trailingAnchor),
            base64TextCopyButton.centerYAnchor.constraint(equalTo: base64TextLabel.centerYAnchor),
            base64TextCopyButton.widthAnchor.constraint(equalToConstant: 20),
            base64TextCopyButton.heightAnchor.constraint(equalToConstant: 20),

            // Base64 文本输入框背景
            base64FieldBg.leadingAnchor.constraint(equalTo: base64CoderView.leadingAnchor),
            base64FieldBg.trailingAnchor.constraint(equalTo: base64CoderView.trailingAnchor),
            base64FieldBg.topAnchor.constraint(equalTo: base64TextLabel.bottomAnchor, constant: 6),
            base64FieldBg.heightAnchor.constraint(equalToConstant: 150),

            // Base64 文本滚动视图
            base64TextScrollView.leadingAnchor.constraint(
                equalTo: base64FieldBg.leadingAnchor, constant: 4),
            base64TextScrollView.trailingAnchor.constraint(
                equalTo: base64FieldBg.trailingAnchor, constant: -4),
            base64TextScrollView.topAnchor.constraint(
                equalTo: base64FieldBg.topAnchor, constant: 4),
            base64TextScrollView.bottomAnchor.constraint(
                equalTo: base64FieldBg.bottomAnchor, constant: -4),
        ])

        base64CoderView.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor, constant: -12
        ).isActive = true
    }

    @objc func copyOriginalText() {
        let text = originalTextView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func copyBase64Text() {
        let text = base64TextView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func copyDecodedURL() {
        let text = decodedURLTextView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func copyEncodedURL() {
        let text = encodedURLTextView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func uuidOptionChanged() {
        uuidUseHyphen = (hyphenCheckbox.state == .on)
        generateUUIDs()
    }

    @objc func uuidCaseChanged(_ sender: NSButton) {
        if sender == uppercaseRadio {
            uppercaseRadio.state = .on
            lowercaseRadio.state = .off
            uuidUppercase = true
        } else {
            uppercaseRadio.state = .off
            lowercaseRadio.state = .on
            uuidUppercase = false
        }
        generateUUIDs()
    }


    func setupKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self = self,
                let window = self.view.window,
                window.isVisible,
                window.isKeyWindow
            else {
                return event
            }
            return self.handleKeyEvent(event)
        }
    }

}
