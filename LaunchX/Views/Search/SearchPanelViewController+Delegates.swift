import AppKit

// MARK: - Delegates

// MARK: - NSTextFieldDelegate

extension SearchPanelViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue

        // 只要是在非普通模式，或者输入为空，就彻底隐藏计算器预览
        if isInAnyExtensionMode || query.isEmpty {
            clearCalculatorResult()
        }

        // IDE 项目模式：搜索项目
        if isInIDEProjectMode {
            performIDEProjectSearch(query)
            return
        }

        // 文件夹打开模式：搜索打开方式
        if isInFolderOpenMode {
            performFolderOpenerSearch(query)
            return
        }

        // 网页直达 Query 模式：不进行搜索，只等待用户输入
        if isInWebLinkQueryMode {
            return
        }

        // 实用工具模式：根据类型处理
        if isInUtilityMode {
            // kill 模式支持搜索
            if currentUtilityIdentifier == "kill" {
                performKillModeSearch(query)
            } else if currentUtilityIdentifier == "uuid" {
                // UUID 模式：防抖处理数量变化
                uuidDebounceWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.generateUUIDs()
                }
                uuidDebounceWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
            }
            // 其他实用工具模式不进行搜索
            return
        }

        // 书签模式：搜索书签
        if isInBookmarkMode {
            performBookmarkSearch(query)
            return
        }

        // 2FA 模式：搜索验证码
        if isIn2FAMode {
            perform2FASearch(query)
            return
        }

        // Claude Code 模式：搜索过滤
        if isInClaudeCodeMode {
            filterClaudeCodeItems(query: query)
            return
        }

        // Codex 模式：搜索过滤
        if isInCodexMode {
            filterCodexItems(query: query)
            return
        }

        // 普通模式：搜索应用和文件
        performSearch(query)

        // 普通模式下更新计算器预览
        if !isInAnyExtensionMode {
            updateCalculatorPreview(query)
        }
    }
}

// MARK: - NSTextViewDelegate

extension SearchPanelViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        if textView == decodedURLTextView {
            // 解码输入框变化 -> 编码
            urlCoderDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.encodeURL()
            }
            urlCoderDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        } else if textView == encodedURLTextView {
            // 编码输入框变化 -> 解码
            urlCoderDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.decodeURL()
            }
            urlCoderDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        } else if textView == originalTextView {
            // 原始文本变化 -> Base64 编码
            base64CoderDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.encodeBase64()
            }
            base64CoderDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        } else if textView == base64TextView {
            // Base64 文本变化 -> 解码
            base64CoderDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.decodeBase64()
            }
            base64CoderDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }
    }
}

// MARK: - QuickActionsViewDelegate

extension SearchPanelViewController: QuickActionsViewDelegate {
    func quickActionsView(_ view: QuickActionsView, didSelectAction action: QuickActionType) {
        executeQuickAction(action)
        hideQuickActions()
    }

    func quickActionsViewDidRequestDismiss(_ view: QuickActionsView) {
        hideQuickActions()
    }
}

extension SearchPanelViewController: ReminderActionViewDelegate {
    func reminderActionViewDidRequestOpenURL(_ view: ReminderActionView) {
        if let url = currentQuickActionTarget?.reminderURL {
            AppOpener.open(url)
            PanelManager.shared.hidePanel()
        }
    }

    func reminderActionViewDidRequestOpenApp(_ view: ReminderActionView) {
        // 直接打开提醒事项 App，避免 deep link 尝试导致系统弹出“未设定应用程序”弹窗
        RemindersService.shared.openInReminders(identifier: nil)
        PanelManager.shared.hidePanel()
    }

    func reminderActionViewDidRequestDismiss(_ view: ReminderActionView) {
        hideQuickActions()
    }
}
