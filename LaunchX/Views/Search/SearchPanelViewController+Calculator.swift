import AppKit

// MARK: - 计算器面板模式

extension SearchPanelViewController {
    /// 是否处于计算器面板模式(输入表达式时下方展示结果/函数 token/历史,隐藏结果列表)
    var isCalculatorModeActive: Bool { !calculatorPanelView.isHidden }

    // MARK: 挂载(setupUI 调用)

    /// 挂载计算器面板:divider 下方,约束与币种胶囊行同款(leading/trailing 20、top=divider+14)
    func setupCalculatorPanelView() {
        calculatorPanelView.translatesAutoresizingMaskIntoConstraints = false
        calculatorPanelView.isHidden = true
        calculatorPanelView.onInsertToken = { [weak self] text in
            self?.insertCalculatorToken(text)
        }
        calculatorPanelView.onToggleAngleUnit = { [weak self] in
            self?.toggleCalculatorAngleUnit()
        }
        calculatorPanelView.onResultClick = { [weak self] in
            // 点击结果大字行:复制 + 记录历史,面板保持打开(ans 可继续引用)
            self?.consumeCalculatorResult()
        }
        calculatorPanelView.onHistoryExpressionClick = { [weak self] expression in
            self?.applyRecalledText(expression)
        }
        calculatorPanelView.onHistoryResultClick = { [weak self] result in
            // 点击历史条目结果:仅复制(不记录、不动 ans、不收面板)
            self?.copyToPasteboard(result)
        }
        calculatorPanelView.onClearHistory = { [weak self] in
            CalculatorHistoryService.shared.clearAll()
            self?.calculatorPanelView.setHistory([])
        }
        contentView.addSubview(calculatorPanelView)

        NSLayoutConstraint.activate([
            calculatorPanelView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 20),
            calculatorPanelView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
            calculatorPanelView.topAnchor.constraint(
                equalTo: divider.bottomAnchor, constant: 14),
            // 底部抬高避开右下角「⏎ 复制」提示(高 22 + 下边距 12)
            calculatorPanelView.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -40),
        ])
        calculatorPanelView.setAngleUnit(CalculatorSettings.load().angleUnit)
    }

    // MARK: 预览分发(自 +Search.swift 迁入重写)

    /// 计算器预览:表达式命中时切换到面板(结果大字行 + token + 历史),
    /// 未完成/非法表达式保持占位防闪烁;不像表达式时退面板恢复搜索列表
    func updateCalculatorPreview(_ query: String) {
        guard CalculatorService.looksLikeExpression(query) else {
            exitCalculatorPanelMode()
            return
        }
        let angleMode = CalculatorSettings.load().angleUnit
        if let result = CalculatorService.shared.evaluate(
            query, angleMode: angleMode, ans: lastCalculatorAnswer)
        {
            calculatorResult = result.copyText
            calculatorResultValue = result.value
            enterCalculatorPanelMode()
            calculatorPanelView.setResult(
                displayText: CalculatorService.formatResult(result.value, grouped: true))
        } else {
            calculatorResult = nil
            calculatorResultValue = nil
            // 面板进入/保持,占位提示(未完成如 "sin(" / 非法如 "ln(-1)")
            enterCalculatorPanelMode()
            calculatorPanelView.setResult(displayText: nil)
        }
    }

    /// 进入面板模式(幂等):显示面板、隐藏 ghost、刷新历史、首次进入联动可见性
    private func enterCalculatorPanelMode() {
        let firstEntry = calculatorPanelView.isHidden
        calculatorPanelView.isHidden = false
        calculatorResultLabel.isHidden = true  // ghost 退位,结果由面板大字行承担
        if firstEntry {
            calculatorPanelView.setHistory(CalculatorHistoryService.shared.currentEntries)
            updateVisibility()  // 收拢结果列表并展开窗口(与币种胶囊模式同款)
        }
    }

    /// 退出面板模式:隐藏面板并复位回溯状态(所有退出路径经 clearCalculatorResult 收敛到此)
    func exitCalculatorPanelMode() {
        guard !calculatorPanelView.isHidden else { return }
        calculatorPanelView.isHidden = true
        calculatorPanelView.setResult(displayText: nil)
        historyRecallIndex = nil
        preRecallText = ""
        updateVisibility()  // 恢复结果列表与窗口高度(搜索管线随后也会刷新,幂等)
    }

    // MARK: 交互动作

    /// Rad/Deg 切换:保存设置并即时重渲染当前表达式
    private func toggleCalculatorAngleUnit() {
        let current = CalculatorSettings.load()
        let next = CalculatorSettings(
            angleUnit: current.angleUnit == .radians ? .degrees : .radians)
        next.save()
        calculatorPanelView.setAngleUnit(next.angleUnit)
        updateInlinePreview(searchField.stringValue)
    }

    /// 把函数 token 插入输入框光标处(field editor 编辑会触发 controlTextDidChange,面板自动刷新)
    private func insertCalculatorToken(_ text: String) {
        if let editor = searchField.currentEditor() {
            editor.insertText(text)
        } else {
            // 无活动光标时追加到末尾(手动同步,赋值不触发 delegate)
            applyRecalledText(searchField.stringValue + text)
        }
    }

    /// 消费当前结果:复制 + 记录历史 + 更新 ans(回车 / 点击结果大字行)
    func consumeCalculatorResult() {
        guard let result = calculatorResult else { return }
        copyToPasteboard(result)
        let expression = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expression.isEmpty {
            CalculatorHistoryService.shared.record(expression: expression, result: result)
        }
        if let value = calculatorResultValue {
            lastCalculatorAnswer = value  // ans 取最近一次消费的数值(不随清理清零)
        }
        calculatorPanelView.setHistory(CalculatorHistoryService.shared.currentEntries)
    }

    /// 回填表达式(历史行点击 / ↑↓ 回溯):stringValue 赋值不触发 delegate,手动同步搜索与预览
    private func applyRecalledText(_ text: String) {
        searchField.stringValue = text
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        performSearch(text)
        updateInlinePreview(text)
    }

    /// ↑/↓ 终端式回溯历史表达式(↑ 更旧,↓ 更新;越过最新回到回溯前原文)
    func recallHistoryStep(older: Bool) {
        let entries = CalculatorHistoryService.shared.currentEntries
        guard !entries.isEmpty else { return }
        if historyRecallIndex == nil {
            preRecallText = searchField.stringValue
        }
        let currentIndex = historyRecallIndex ?? -1  // -1 = 回溯前原文态
        let nextIndex = older ? currentIndex + 1 : currentIndex - 1
        if nextIndex >= entries.count { return }  // 已是最旧
        if nextIndex < 0 {
            // ↓ 越过最新:回到回溯前原文
            historyRecallIndex = nil
            applyRecalledText(preRecallText)
            return
        }
        historyRecallIndex = nextIndex
        applyRecalledText(entries[nextIndex].expression)
    }

    /// 写剪贴板(纯文本)
    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
