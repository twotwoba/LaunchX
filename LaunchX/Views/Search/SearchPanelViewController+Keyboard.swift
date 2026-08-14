import AppKit

// MARK: - Keyboard Handling

extension SearchPanelViewController {
    // MARK: - Keyboard Handling

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // 快捷操作模式下优先处理
        if isInQuickActionsMode {
            if let reminderView = reminderActionView {
                reminderView.keyDown(with: event)
                return nil
            }
            return handleQuickActionsKeyEvent(event)
        }

        // 检查输入法是否正在组合输入（如中文输入法）
        var isComposing = false
        if let fieldEditor = searchField.currentEditor() as? NSTextView {
            isComposing = fieldEditor.markedRange().length > 0
        }

        switch Int(event.keyCode) {
        case 51:  // Delete - IDE 项目模式、文件夹打开模式、网页直达 Query 模式、实用工具模式、书签模式、2FA 模式、表情包模式或收藏模式下，输入框为空时退出
            if isComposing { return event }
            // URL 模式和 Base64 模式使用独立文本框，delete 键由文本框处理，不退出
            if isInUtilityMode
                && (currentUtilityIdentifier == "url" || currentUtilityIdentifier == "base64")
            {
                return event
            }
            if (isInIDEProjectMode || isInFolderOpenMode || isInWebLinkQueryMode || isInUtilityMode
                || isInBookmarkMode || isIn2FAMode || isInClaudeCodeMode || isInCodexMode)
                && searchField.stringValue.isEmpty
            {
                if isInIDEProjectMode {
                    exitIDEProjectMode()
                } else if isInFolderOpenMode {
                    exitFolderOpenMode()
                } else if isInWebLinkQueryMode {
                    exitWebLinkQueryMode()
                } else if isInUtilityMode {
                    exitUtilityMode()
                } else if isInBookmarkMode {
                    exitBookmarkMode()
                } else if isIn2FAMode {
                    exit2FAMode()
                } else if isInClaudeCodeMode {
                    exitClaudeCodeMode()
                } else if isInCodexMode {
                    exitCodexMode()
                }
                return nil
            }
            return event
        case 48:  // Tab - 进入 IDE 项目模式、文件夹打开模式、网页直达 Query 模式或书签模式
            if isComposing { return event }
            if !isInIDEProjectMode && !isInFolderOpenMode && !isInWebLinkQueryMode
                && !isInBookmarkMode && !isIn2FAMode && !isInClaudeCodeMode && !isInCodexMode
            {
                // 检查当前选中项是否有扩展功能
                guard results.indices.contains(selectedIndex) else {
                    // 没有选中任何项目，忽略 Tab 键
                    return nil
                }
                let item = results[selectedIndex]

                // 检查是否为书签入口
                if item.isBookmarkEntry {
                    enterBookmarkMode()
                    return nil
                }

                // 检查是否为 2FA 入口
                if item.is2FAEntry {
                    enter2FAMode()
                    return nil
                }

                // 检查是否为 Claude Code 入口
                if item.isClaudeCodeEntry {
                    enterClaudeCodeMode()
                    return nil
                }

                // 检查是否为 Codex 入口
                if item.isCodexEntry {
                    enterCodexMode()
                    return nil
                }

                // 检查是否为股票面板入口
                if item.isStockEntry {
                    PanelManager.shared.hidePanel()
                    StockPanelManager.shared.showPanel()
                    return nil
                }

                // 检查是否为 IDE（有项目列表扩展）
                if let ideType = IDEType.detect(from: item.path) {
                    let projects = IDERecentProjectsService.shared.getRecentProjects(
                        for: ideType, limit: 20)
                    if !projects.isEmpty {
                        // 进入 IDE 项目模式
                        if tryEnterIDEProjectMode() {
                            return nil
                        }
                    }
                }

                // 检查是否为文件夹（有打开方式扩展）
                let isApp = item.path.hasSuffix(".app")
                if item.isDirectory && !isApp {
                    let openers = IDERecentProjectsService.shared.getAvailableFolderOpeners()
                    if !openers.isEmpty {
                        // 进入文件夹打开模式
                        if tryEnterFolderOpenMode() {
                            return nil
                        }
                    }
                }

                // 检查是否为网页直达且支持 query 扩展
                if item.isWebLink && item.supportsQueryExtension {
                    if tryEnterWebLinkQueryMode(for: item) {
                        return nil
                    }
                }

                // 检查是否为实用工具
                if item.isUtility {
                    if tryEnterUtilityMode(for: item) {
                        return nil
                    }
                }

                // 当前选中项没有扩展功能，忽略 Tab 键（阻止焦点切换）
                return nil
            }
            // 已经在扩展模式中，忽略 Tab 键
            return nil
        case 125:  // Down arrow
            if isComposing { return event }  // 让输入法处理
            moveSelectionDown()
            return nil
        case 126:  // Up arrow
            if isComposing { return event }  // 让输入法处理
            moveSelectionUp()
            return nil
        case 123:  // Left arrow
            if isComposing { return event }
            return event
        case 124:  // Right arrow
            if isComposing { return event }
            return event
        case 53:  // Escape
            if isComposing { return event }  // 让输入法取消
            // 如果在 IDE 项目模式或文件夹打开模式，先退出该模式
            if isInIDEProjectMode {
                exitIDEProjectMode()
                return nil
            }
            if isInFolderOpenMode {
                exitFolderOpenMode()
                return nil
            }
            if isInWebLinkQueryMode {
                exitWebLinkQueryMode()
                return nil
            }
            if isInUtilityMode {
                exitUtilityMode()
                return nil
            }
            if isInClaudeCodeMode {
                exitClaudeCodeMode()
                return nil
            }
            if isInCodexMode {
                exitCodexMode()
                return nil
            }
            PanelManager.shared.hidePanel()
            return nil
        case 36:  // Return
            if isComposing { return event }  // 让输入法确认输入

            // 如果计算器有结果，回车复制结果
            if let result = calculatorResult {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(result, forType: .string)

                // 复制后退出
                PanelManager.shared.hidePanel()
                return nil
            }

            openSelected()
            return nil
        default:
            // 检查是否输入了 '=' 号且计算器有结果
            if event.characters == "=" && calculatorResult != nil {
                if let result = calculatorResult {
                    searchField.stringValue = result
                    clearCalculatorResult()
                    performSearch(result)
                    return nil
                }
            }
            // Ctrl+N / Ctrl+P / Ctrl+F / Ctrl+B
            if event.modifierFlags.contains(.control) {
                if event.keyCode == 45 {  // N - 下
                    moveSelectionDown()
                    return nil
                } else if event.keyCode == 35 {  // P - 上
                    moveSelectionUp()
                    return nil
                } else if event.keyCode == 3 {  // F - 右
                    // 右移光标
                } else if event.keyCode == 11 {  // B - 左
                    // 左移光标
                }
            }
            // Cmd+K - 快捷操作面板
            if event.modifierFlags.contains(.command) && event.keyCode == 40 {
                if isInQuickActionsMode {
                    hideQuickActions()
                } else {
                    tryShowQuickActions()
                }
                return nil
            }
            // 检查是否输入了 '=' 号且计算器有结果
            if event.characters == "=" && calculatorResult != nil {
                if let result = calculatorResult {
                    searchField.stringValue = result
                    calculatorResult = nil
                    calculatorResultLabel.isHidden = true
                    // 触发一次搜索（如果是数字可能没有搜索结果，但逻辑保持一致）
                    performSearch(result)
                    return nil
                }
            }

            // 检查是否输入了 '=' 号且计算器有结果
            if event.characters == "=" && calculatorResult != nil {
                if let result = calculatorResult {
                    searchField.stringValue = result
                    clearCalculatorResult()
                    // 触发一次搜索
                    performSearch(result)
                    return nil
                }
            }
            return event
        }
    }

    func moveSelectionDown() {
        guard !results.isEmpty else { return }
        var newIndex = selectedIndex + 1
        // 跳过分组标题
        while newIndex < results.count && results[newIndex].isSectionHeader {
            newIndex += 1
        }
        if newIndex < results.count {
            let oldIndex = selectedIndex
            selectedIndex = newIndex
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            scrollToKeepSelectionCentered()
            // 只刷新变化的行而不是全量 reloadData
            let columnIndexes = IndexSet(integer: 0)
            tableView.reloadData(
                forRowIndexes: IndexSet([oldIndex, newIndex]), columnIndexes: columnIndexes)
            updateShortcutHint()
        }
    }

    func moveSelectionUp() {
        guard !results.isEmpty else { return }
        var newIndex = selectedIndex - 1
        // 跳过分组标题
        while newIndex >= 0 && results[newIndex].isSectionHeader {
            newIndex -= 1
        }
        if newIndex >= 0 {
            let oldIndex = selectedIndex
            selectedIndex = newIndex
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            scrollToKeepSelectionCentered()
            // 只刷新变化的行而不是全量 reloadData
            let columnIndexes = IndexSet(integer: 0)
            tableView.reloadData(
                forRowIndexes: IndexSet([oldIndex, newIndex]), columnIndexes: columnIndexes)
            updateShortcutHint()
        }
    }

}
